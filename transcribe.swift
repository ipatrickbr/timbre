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

    private static var installedModels: [URL] {
        let models = modelsDirectory
        let found = (try? FileManager.default.contentsOfDirectory(
            at: models, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return found.filter { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" }
    }

    private static func largest(_ urls: [URL]) -> URL? {
        urls.max { a, b in
            let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sa < sb
        }
    }

    /// Model used for transcription: the largest installed, which is the most
    /// accurate.
    static var model: URL? { largest(installedModels) }

    /// Model used for translating into English. The turbo models are trained
    /// for transcription only and quietly return the original language when
    /// asked to translate, so they are excluded here.
    static var translationModel: URL? {
        largest(installedModels.filter { !$0.lastPathComponent.contains("turbo") })
    }

    static var canTranslate: Bool { translationModel != nil }

    /// The engine ships with the app; the models are downloaded on first use.
    static var hasEngine: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    static var isInstalled: Bool { hasEngine && model != nil }

    struct Outcome {
        let succeeded: Bool
        /// Language whisper detected, as a two-letter code. Nil when it did not
        /// report one, which happens if the run failed early.
        let language: String?
    }

    /// Writes `<outputBase>.txt` and `<outputBase>.srt` next to the recording.
    /// With `translate` the output is English regardless of what was spoken.
    @discardableResult
    static func run(audio: URL, outputBase: URL, translate: Bool = false,
                    progress: @escaping (Double) -> Void) -> Outcome {
        let engine = translate ? translationModel : model
        guard isInstalled, let engine else { return Outcome(succeeded: false, language: nil) }

        // whisper.cpp wants 16 kHz mono; afconvert ships with macOS.
        let prepared = FileManager.default.temporaryDirectory
            .appendingPathComponent("timbre-\(UUID().uuidString).wav")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audio.path, prepared.path]
        convert.standardOutput = FileHandle.nullDevice
        convert.standardError = FileHandle.nullDevice
        do { try convert.run() } catch { return Outcome(succeeded: false, language: nil) }
        convert.waitUntilExit()
        guard convert.terminationStatus == 0 else {
            return Outcome(succeeded: false, language: nil)
        }
        defer { try? FileManager.default.removeItem(at: prepared) }

        let task = Process()
        task.executableURL = binary
        task.arguments = [
            "-m", engine.path,
            "-f", prepared.path,
            "-l", "auto",              // detect the language rather than assume it
            "-t", String(max(4, ProcessInfo.processInfo.activeProcessorCount - 2)),
            "-otxt", "-osrt",
            "-of", outputBase.path,
            "-pp",
        ]
        if translate { task.arguments?.append("-tr") }

        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = FileHandle.nullDevice

        // whisper.cpp reports "progress = 42%" and, once, the language it
        // settled on: "auto-detected language: pt (p = 0.99)".
        let progressPattern = try? NSRegularExpression(pattern: #"progress\s*=\s*(\d+)%"#)
        let languagePattern = try? NSRegularExpression(pattern: #"auto-detected language:\s*(\w+)"#)
        let detected = LanguageBox()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let range = NSRange(text.startIndex..., in: text)

            if let languagePattern, detected.code == nil,
               let match = languagePattern.matches(in: text, range: range).first,
               let codeRange = Range(match.range(at: 1), in: text) {
                detected.code = String(text[codeRange])
            }
            if let progressPattern,
               let match = progressPattern.matches(in: text, range: range).last,
               let percentRange = Range(match.range(at: 1), in: text),
               let percent = Double(text[percentRange]) {
                progress(percent / 100)
            }
        }

        do { try task.run() } catch { return Outcome(succeeded: false, language: nil) }
        task.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        if task.terminationStatus == 0 { progress(1) }
        return Outcome(succeeded: task.terminationStatus == 0, language: detected.code)
    }
}

/// Small reference box so the stderr handler, which runs on its own queue, can
/// hand the detected language back to the caller.
private final class LanguageBox: @unchecked Sendable {
    var code: String?
}
