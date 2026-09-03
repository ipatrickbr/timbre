import Foundation

/// Offline speech-to-text with whisper.cpp. The engine and the language model
/// live in Application Support and are installed by vendor/build-whisper.sh —
/// audio never leaves the machine.
enum Transcriber {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Timbre/whisper", isDirectory: true)
    }

    /// The engine ships inside the app. A copy installed by the build script is
    /// still honoured, so machines set up the old way keep working.
    static var binary: URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/whisper/whisper-cli")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return supportDirectory.appendingPathComponent("whisper-cli")
    }

    static var modelsDirectory: URL {
        supportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    /// Speech models only. The voice-activity model shares the naming scheme but
    /// is not something we can transcribe with, so it is filtered out here —
    /// otherwise a machine holding just that file would look ready to work.
    private static var installedModels: [URL] {
        let found = (try? FileManager.default.contentsOfDirectory(
            at: modelsDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return found.filter {
            $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin"
                && !$0.lastPathComponent.contains("silero")
        }
    }

    private static func largest(_ urls: [URL]) -> URL? {
        urls.max { a, b in
            let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sa < sb
        }
    }

    /// Model used for transcription: turbo specifically, not just "the
    /// largest installed" — that stopped being the same thing once a bigger
    /// model was added for translation, and turbo is both faster and tuned
    /// against by the voice-activity and repetition fixes.
    static var model: URL? {
        installedModels.first { $0.lastPathComponent.contains("turbo") } ?? largest(installedModels)
    }

    /// Model used for translating into English. The turbo models are trained
    /// for transcription only and quietly return the original language when
    /// asked to translate, so they are excluded here.
    static var translationModel: URL? {
        largest(installedModels.filter { !$0.lastPathComponent.contains("turbo") })
    }

    /// Working out which language is being spoken is a far easier job than
    /// transcribing it, so the smaller model does it — it loads in a fraction
    /// of the time, and this runs before the person has been asked anything.
    static var detectionModel: URL? {
        installedModels.filter { !$0.lastPathComponent.contains("turbo") }.min {
            let sa = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sb = (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sa < sb
        } ?? model
    }

    /// Voice activity detection. Without it whisper is handed the silent
    /// stretches too, and invents speech to fill them — the single worst defect
    /// in the transcripts this produced before.
    static var vadModel: URL? {
        let file = modelsDirectory.appendingPathComponent("ggml-silero-v5.1.2.bin")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    static var canTranslate: Bool { translationModel != nil }

    /// The engine ships with the app; the models are downloaded on first use.
    static var hasEngine: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    static var isInstalled: Bool { hasEngine && model != nil }

    // MARK: - Preparing the audio

    /// whisper.cpp wants 16 kHz mono. The recording is converted once and the
    /// result is handed to every pass that follows, so a transcribe-and-
    /// translate run no longer decodes the same hour of audio twice.
    static func prepare(audio: URL) -> URL? {
        let prepared = FileManager.default.temporaryDirectory
            .appendingPathComponent("timbre-\(UUID().uuidString).wav")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audio.path, prepared.path]
        convert.standardOutput = FileHandle.nullDevice
        convert.standardError = FileHandle.nullDevice
        do { try convert.run() } catch { return nil }
        convert.waitUntilExit()
        guard convert.terminationStatus == 0 else { return nil }
        return prepared
    }

    // MARK: - Language

    /// Samples the recording in four places and asks whisper what it is
    /// hearing. Listening to the opening alone is not enough: a hearing that
    /// starts with silence, a jingle or an English introduction would pin the
    /// wrong language for the whole file, and every later pass would inherit
    /// the mistake.
    ///
    /// The slices have to be written out as real files. whisper-cli ignores
    /// `-ot` when it is only being asked to name the language, so pointing it
    /// at an offset in the original would silently reread the first thirty
    /// seconds four times over.
    static func detectLanguage(prepared: URL, seconds: Double) -> String? {
        guard let engine = detectionModel else { return nil }

        let positions: [Double] = seconds < 120 ? [0] : [0.15, 0.4, 0.65, 0.85].map { $0 * seconds }
        var score: [String: Double] = [:]
        for position in positions {
            guard let slice = sample(from: prepared, start: position, seconds: 30) else { continue }
            defer { try? FileManager.default.removeItem(at: slice) }
            guard let guess = detectOnce(engine: engine, audio: slice) else { continue }
            // A confident answer counts for more than a hesitant one, which is
            // how an odd sample gets quietly outvoted.
            guard guess.probability > 0.4 else { continue }
            score[guess.code, default: 0] += guess.probability
        }

        if let winner = score.max(by: { $0.value < $1.value })?.key { return winner }
        // Every sample was silent or unreadable. Fall back to the opening,
        // which is better than telling the caller nothing.
        return detectOnce(engine: engine, audio: prepared)?.code
    }

    /// Copies `seconds` of audio out of a 16 kHz mono PCM file into a new one.
    /// Returns nil for a stretch too quiet to be speech, so a sample that lands
    /// in a pause does not get a vote.
    private static func sample(from wav: URL, start: Double, seconds: Double) -> URL? {
        guard let data = try? Data(contentsOf: wav, options: .mappedIfSafe),
              let audio = dataChunk(of: data) else { return nil }

        let bytesPerSecond = 16_000 * 2
        let begin = audio.lowerBound + Int(start) * bytesPerSecond
        let end = min(begin + Int(seconds) * bytesPerSecond, audio.upperBound)
        guard begin >= audio.lowerBound, end - begin > bytesPerSecond else { return nil }

        let pcm = data[begin..<end]
        guard isLoudEnough(pcm) else { return nil }

        var out = Data()
        let payload = UInt32(pcm.count)
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + payload)
        out.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))                    // PCM, mono
        append(UInt32(16_000)); append(UInt32(bytesPerSecond))
        append(UInt16(2)); append(UInt16(16))                   // block align, bit depth
        out.append(contentsOf: Array("data".utf8)); append(payload)
        out.append(pcm)

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("timbre-sample-\(UUID().uuidString).wav")
        guard (try? out.write(to: file)) != nil else { return nil }
        return file
    }

    /// Walks the RIFF chunks rather than assuming a 44 byte header, because
    /// afconvert does not always write one.
    private static func dataChunk(of file: Data) -> Range<Int>? {
        guard file.count > 12 else { return nil }
        var cursor = file.startIndex + 12
        while cursor + 8 <= file.endIndex {
            let name = String(decoding: file[cursor..<cursor + 4], as: UTF8.self)
            let size = file[(cursor + 4)..<(cursor + 8)].withUnsafeBytes {
                Int($0.loadUnaligned(as: UInt32.self).littleEndian)
            }
            let body = cursor + 8
            if name == "data" { return body..<min(body + size, file.endIndex) }
            cursor = body + size + (size % 2)          // chunks are word aligned
        }
        return nil
    }

    /// Roughly -47 dBFS. Speech in these recordings sits around -20; a pause
    /// between speakers measures below -50.
    private static func isLoudEnough(_ pcm: Data) -> Bool {
        var sum = 0.0
        var counted = 0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            // Every eighth sample is plenty to tell speech from a pause.
            for index in stride(from: 0, to: samples.count, by: 8) {
                let value = Double(Int16(littleEndian: samples[index]))
                sum += value * value
                counted += 1
            }
        }
        guard counted > 0 else { return false }
        return (sum / Double(counted)).squareRoot() > 150
    }

    private static func detectOnce(engine: URL, audio: URL) -> (code: String, probability: Double)? {
        let task = Process()
        task.executableURL = binary
        task.arguments = [
            "-m", engine.path,
            "-f", audio.path,
            "-l", "auto",
            "-dl",                     // stop as soon as the language is known
            "-t", String(threadCount),
        ]
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let pattern = try? NSRegularExpression(
            pattern: #"auto-detected language:\s*(\w+)\s*\(p\s*=\s*([0-9.]+)"#)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern?.matches(in: text, range: range).last,
              let codeRange = Range(match.range(at: 1), in: text),
              let probabilityRange = Range(match.range(at: 2), in: text),
              let probability = Double(text[probabilityRange]) else { return nil }
        return (String(text[codeRange]), probability)
    }

    // MARK: - Transcribing

    private static var threadCount: Int {
        max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
    }

    /// Translation runs on the much larger large-v3 model. At the full thread
    /// count above, translating a real interview visibly slowed the whole
    /// Mac down while it ran in the background — this leaves it more room,
    /// at the cost of some speed.
    private static var translationThreadCount: Int {
        max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    /// Writes `<outputBase>.txt` and `<outputBase>.srt`. With `translate` the
    /// output is English regardless of what was spoken.
    @discardableResult
    static func run(prepared: URL, outputBase: URL, language: String?,
                    translate: Bool = false,
                    progress: @escaping (Double) -> Void) -> Bool {
        let engine = translate ? translationModel : model
        guard hasEngine, let engine else { return false }

        let task = Process()
        task.executableURL = binary
        var arguments = [
            "-m", engine.path,
            "-f", prepared.path,
            "-l", language ?? "auto",
            "-t", String(translate ? translationThreadCount : threadCount),
            "-otxt", "-osrt",
            "-of", outputBase.path,
            "-sns",                    // drop [music], [applause] and friends
            // Whisper feeds its own previous output back in as context. Left
            // unbounded, a stumble compounds: the decoder starts quoting
            // itself, and segments collapse into fragments. Capping the
            // carry-over ends the runaway and, measured over a 54 minute
            // interview, is 15% quicker into the bargain.
            "-mc", "64",
            "-pp",
        ]
        // Silence is where whisper hallucinates: handed a quiet stretch it will
        // repeat the last thing it heard, sometimes for minutes. Voice activity
        // detection hides those stretches from it entirely.
        if let vad = vadModel {
            arguments += ["--vad", "-vm", vad.path]
        }
        if translate { arguments.append("-tr") }
        task.arguments = arguments

        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = FileHandle.nullDevice

        // whisper.cpp reports "progress = 42%" as it goes.
        let progressPattern = try? NSRegularExpression(pattern: #"progress\s*=\s*(\d+)%"#)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8),
                  let progressPattern else { return }
            let range = NSRange(text.startIndex..., in: text)
            if let match = progressPattern.matches(in: text, range: range).last,
               let percentRange = Range(match.range(at: 1), in: text),
               let percent = Double(text[percentRange]) {
                progress(percent / 100)
            }
        }

        do { try task.run() } catch { return false }
        // Translating with large-v3 is heavy enough to make the whole Mac
        // feel sluggish while it runs. Backgrounding it asks the system to
        // favour whatever the person is actually doing over this — it just
        // takes a little longer to finish.
        if translate { lowerPriority(of: task.processIdentifier) }
        task.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        if task.terminationStatus == 0 { progress(1) }
        return task.terminationStatus == 0
    }

    /// Best-effort: asks the kernel scheduler to treat a running process as
    /// background work, so it stops competing with whatever is in front of
    /// the person. Silently does nothing if `taskpolicy` is missing.
    private static func lowerPriority(of pid: Int32) {
        let tool = "/usr/sbin/taskpolicy"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let nice = Process()
        nice.executableURL = URL(fileURLWithPath: tool)
        nice.arguments = ["-b", "-p", String(pid)]
        nice.standardOutput = FileHandle.nullDevice
        nice.standardError = FileHandle.nullDevice
        try? nice.run()
    }
}
