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

    static var binary: URL { supportDirectory.appendingPathComponent("whisper-cli") }

    /// The installed ggml model. If more than one is present we take the
    /// largest, which is the most accurate of them.
    static var model: URL? {
        let models = supportDirectory.appendingPathComponent("models", isDirectory: true)
        let found = (try? FileManager.default.contentsOfDirectory(
            at: models, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return found
            .filter { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" }
            .max { a, b in
                let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return sa < sb
            }
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binary.path) && model != nil
    }

    /// Writes `<outputBase>.txt` and `<outputBase>.srt` next to the recording.
    @discardableResult
    static func run(audio: URL, outputBase: URL, progress: @escaping (Double) -> Void) -> Bool {
        guard isInstalled, let model else { return false }

        // whisper.cpp wants 16 kHz mono; afconvert ships with macOS.
        let prepared = FileManager.default.temporaryDirectory
            .appendingPathComponent("timbre-\(UUID().uuidString).wav")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audio.path, prepared.path]
        convert.standardOutput = FileHandle.nullDevice
        convert.standardError = FileHandle.nullDevice
        do { try convert.run() } catch { return false }
        convert.waitUntilExit()
        guard convert.terminationStatus == 0 else { return false }
        defer { try? FileManager.default.removeItem(at: prepared) }

        let task = Process()
        task.executableURL = binary
        task.arguments = [
            "-m", model.path,
            "-f", prepared.path,
            "-l", "auto",              // detect the language rather than assume it
            "-t", String(max(4, ProcessInfo.processInfo.activeProcessorCount - 2)),
            "-otxt", "-osrt",
            "-of", outputBase.path,
            "-pp",
        ]

        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = FileHandle.nullDevice

        // whisper.cpp reports "progress = 42%" on stderr.
        let pattern = try? NSRegularExpression(pattern: #"progress\s*=\s*(\d+)%"#)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8), let pattern else { return }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern.matches(in: text, range: range).last,
                  let percentRange = Range(match.range(at: 1), in: text),
                  let percent = Double(text[percentRange]) else { return }
            progress(percent / 100)
        }

        do { try task.run() } catch { return false }
        task.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        if task.terminationStatus == 0 { progress(1) }
        return task.terminationStatus == 0
    }
}
