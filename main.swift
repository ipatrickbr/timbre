import Foundation
import AVFoundation
import CoreGraphics

// timbre — records the audio playing inside your Mac.
// Launched with no arguments and no terminal (double-clicked in Finder) it
// opens as a menu bar app instead of a command line tool.

private func t(_ key: String) -> String { NSLocalizedString(key, comment: "") }

// MARK: - Permission

// System-audio taps are not covered by the microphone TCC service: they rely
// on screen-and-system-audio recording. Without it Core Audio hands back
// silence instead of an error, so we check before recording anything.
func ensureAudioPermission() {
    if CGPreflightScreenCaptureAccess() { return }
    if CGRequestScreenCaptureAccess() { return }
    FileHandle.standardError.write((t("error.permission") + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - Arguments

var outputPath = "recording.wav"
var duration: Double = 0          // 0 = until Ctrl+C
var mute = false                  // audible by default
var useTap = true                 // process tap, or ScreenCaptureKit
var forceMenuBar = false

// LaunchServices appends -psn_… when the app is opened from Finder.
var args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
var i = 0
while i < args.count {
    switch args[i] {
    case "-o", "--output":
        i += 1; outputPath = i < args.count ? args[i] : outputPath
    case "-d", "--duration":
        i += 1; duration = i < args.count ? (Double(args[i]) ?? 0) : 0
    case "--sck":
        useTap = false
    case "--mute", "--mudo":
        mute = true
    case "--monitor":
        break   // kept for compatibility: audible is already the default
    case "--menubar":
        forceMenuBar = true
    case "--transcribe":
        // Replays the post-recording flow against an existing file, so the
        // dialogs and passes can be checked without recording anything.
        i += 1
        guard i < args.count else { exit(2) }
        runMenuBar(transcribing: URL(fileURLWithPath: args[i]).standardizedFileURL)
    case "--check":
        let granted = CGPreflightScreenCaptureAccess()
        print(t("check.permission"), granted ? t("check.granted") : t("check.missing"))
        exit(granted ? 0 : 1)
    case "-h", "--help":
        print(t("cli.help"))
        exit(0)
    default:
        FileHandle.standardError.write("\(t("cli.unknown")) \(args[i])\n".data(using: .utf8)!)
        exit(2)
    }
    i += 1
}

// Double-clicked in Finder: no arguments and no terminal attached to stdout.
let launchedFromFinder = args.isEmpty && isatty(STDOUT_FILENO) == 0
if forceMenuBar || launchedFromFinder { runMenuBar() }

let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(t("cli.error")) \(message)\n".data(using: .utf8)!)
    exit(1)
}

private func progressLine(_ elapsed: TimeInterval) -> Data {
    String(format: "\r  %02d:%02d ", Int(elapsed) / 60, Int(elapsed) % 60).data(using: .utf8)!
}

// MARK: - Terminal recording

func runTapCLI() -> Never {
    ensureAudioPermission()
    let recorder = TapRecorder()
    let started = Date()

    func finish() -> Never {
        let seconds: Double
        do { seconds = try recorder.stop() } catch { fail("\(error)") }
        FileHandle.standardError.write("\n".data(using: .utf8)!)
        if seconds <= 0 {
            // The tap idles while nothing plays, so an empty file means the
            // Mac stayed silent for the whole session.
            try? FileManager.default.removeItem(at: outputURL)
            FileHandle.standardError.write((t("cli.nothing") + "\n").data(using: .utf8)!)
            exit(3)
        }
        print(String(format: t("cli.saved"), seconds, outputURL.path))
        exit(0)
    }

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigint.setEventHandler { finish() }
    sigterm.setEventHandler { finish() }
    sigint.resume()
    sigterm.resume()

    do { try recorder.start(outputURL: outputURL, mute: mute) } catch { fail("\(error)") }

    let mode = mute ? t("cli.mode.muted") : t("cli.mode.audible")
    let limit = duration > 0 ? String(format: t("cli.limit"), duration) : t("cli.until.ctrlc")
    FileHandle.standardError.write("\(mode)\(limit)\n".data(using: .utf8)!)

    let ticker = DispatchSource.makeTimerSource(queue: .main)
    ticker.schedule(deadline: .now() + 0.5, repeating: 0.5)
    ticker.setEventHandler {
        let elapsed = Date().timeIntervalSince(started)
        FileHandle.standardError.write(progressLine(elapsed))
        if duration > 0 && elapsed >= duration { finish() }
    }
    ticker.resume()

    dispatchMain()
}

// MARK: - ScreenCaptureKit fallback

func runScreenCaptureKit() -> Never {
    let capturer = SystemAudioCapturer(outputURL: outputURL)
    let started = Date()
    var finishing = false

    func finish() {
        guard !finishing else { return }
        finishing = true
        Task {
            let (seconds, error) = await capturer.finish()
            if let error {
                FileHandle.standardError.write("\n\(t("cli.error")) \(error)\n".data(using: .utf8)!)
                exit(1)
            }
            FileHandle.standardError.write("\n".data(using: .utf8)!)
            if seconds <= 0 {
                try? FileManager.default.removeItem(at: outputURL)
                FileHandle.standardError.write((t("cli.nothing") + "\n").data(using: .utf8)!)
                exit(3)
            }
            print(String(format: t("cli.saved"), seconds, outputURL.path))
            exit(0)
        }
    }

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigint.setEventHandler { finish() }
    sigterm.setEventHandler { finish() }
    sigint.resume()
    sigterm.resume()

    Task {
        do {
            try await capturer.start()
            let limit = duration > 0 ? String(format: t("cli.limit"), duration) : t("cli.until.ctrlc")
            FileHandle.standardError.write("\(t("cli.mode.audible"))\(limit)\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("\(t("error.permission"))\n".data(using: .utf8)!)
            exit(1)
        }
    }

    let ticker = DispatchSource.makeTimerSource(queue: .main)
    ticker.schedule(deadline: .now() + 0.5, repeating: 0.5)
    ticker.setEventHandler {
        let elapsed = Date().timeIntervalSince(started)
        FileHandle.standardError.write(progressLine(elapsed))
        if duration > 0 && elapsed >= duration { finish() }
    }
    ticker.resume()

    dispatchMain()
}

if useTap { runTapCLI() } else { runScreenCaptureKit() }
