import AppKit
import AVFoundation

private func t(_ key: String) -> String { NSLocalizedString(key, comment: "") }

/// "3 minutes", "45 seconds": used by both the progress panel and the prompt.
private func humanDuration(_ seconds: TimeInterval) -> String {
    let s = max(Int(seconds.rounded()), 1)
    if s < 60 { return String(format: t(s == 1 ? "time.second" : "time.seconds"), s) }
    let m = max(s / 60, 1)
    return String(format: t(m == 1 ? "time.minute" : "time.minutes"), m)
}

// South China Morning Post palette. Gold alone disappears against a light menu
// bar and navy alone disappears against a dark one, so the accent swaps with
// the appearance — both halves of the masthead pairing.
extension NSColor {
    static let scmpGold = NSColor(srgbRed: 1.0, green: 0.78, blue: 0.0, alpha: 1)
    static let scmpNavy = NSColor(srgbRed: 0.04, green: 0.14, blue: 0.32, alpha: 1)

    static let scmpAccent = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .scmpGold : .scmpNavy
    }
}

/// Progress bar painted in the SCMP accent instead of the system blue.
final class AccentProgressBar: NSView {
    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let filled = bounds.width * min(max(fraction, 0), 1)
        guard filled > 0 else { return }
        NSColor.scmpAccent.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: max(filled, bounds.height), height: bounds.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}

// MARK: - Conversion progress panel

/// Floating panel, macOS style, showing conversion progress. A long talk takes
/// tens of seconds to become an MP3, and without feedback the wait looks like
/// a freeze.
final class ConversionPanel {
    private var panel: NSPanel?
    private var bar: AccentProgressBar?
    private var status: NSTextField?
    private var title: NSTextField?

    func show(fileName: String) {
        let size = NSSize(width: 400, height: 132)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        panel.contentView = blur

        let title = NSTextField(labelWithString: t("convert.title"))
        self.title = title
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 20, y: 92, width: 360, height: 18)
        blur.addSubview(title)

        let name = NSTextField(labelWithString: fileName)
        name.font = .systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.frame = NSRect(x: 20, y: 72, width: 360, height: 16)
        blur.addSubview(name)

        let bar = AccentProgressBar(frame: NSRect(x: 20, y: 46, width: 360, height: 8))
        blur.addSubview(bar)

        let status = NSTextField(labelWithString: t("convert.preparing"))
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 20, y: 20, width: 360, height: 16)
        blur.addSubview(status)

        panel.center()
        panel.orderFrontRegardless()

        self.panel = panel
        self.bar = bar
        self.status = status
    }

    func startTranscription() {
        title?.stringValue = t("transcribe.title")
        bar?.fraction = 0
        status?.stringValue = t("transcribe.starting")
    }

    func update(fraction: Double, remaining: TimeInterval?) {
        bar?.fraction = fraction
        let pct = Int((fraction * 100).rounded())
        if let remaining, remaining > 1 {
            status?.stringValue = String(format: t("convert.remaining"), pct, humanDuration(remaining))
        } else {
            status?.stringValue = "\(pct)%"
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        bar = nil
        status = nil
        title = nil
    }

}

// MARK: - Menu bar icon

/// One click asks how to record; the next one stops and saves the MP3.
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = TapRecorder()
    private let conversion = ConversionPanel()
    private var ticker: Timer?
    private var startedAt = Date()
    private var currentWAV: URL?
    private var busy = false
    private var startSound: AVAudioPlayer?
    private var transcriptionTicker: Timer?
    private var reportedProgress: Double = 0
    private var stopSound: AVAudioPlayer?

    private var destinationFolder: URL {
        let base = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Timbre", isDirectory: true)
    }

    /// Dock icon click while the app runs: same effect as the menu bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        primaryAction()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.action = #selector(handleClick)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        loadSounds()
        showIdle()
    }

    // MARK: Sound cues

    private func loadSounds() {
        startSound = loadSound("start")
        stopSound = loadSound("stop")
    }

    private func loadSound(_ name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        return player
    }

    private func play(_ player: AVAudioPlayer?) {
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    // MARK: Appearance

    private func symbol(_ name: String, _ fallback: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: fallback)
        image?.isTemplate = true
        return image
    }

    private func showIdle() {
        guard let button = statusItem.button else { return }
        button.image = symbol("waveform", "record")
        button.contentTintColor = nil
        button.title = ""
        button.toolTip = t("tooltip.idle")
    }

    private func showRecording() {
        guard let button = statusItem.button else { return }
        button.image = symbol("record.circle", "recording")
        button.contentTintColor = .scmpAccent
        button.toolTip = t("tooltip.recording")
    }

    private func showPaused() {
        guard let button = statusItem.button else { return }
        button.image = symbol("pause.circle", "paused")
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = t("tooltip.paused")
    }

    private func showSaving() {
        guard let button = statusItem.button else { return }
        button.image = symbol("arrow.down.circle", "saving")
        button.contentTintColor = nil
        button.title = " " + t("status.saving")
        button.toolTip = t("tooltip.saving")
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let recorded = recorder.recordedSeconds
        let tempo = String(format: "%02d:%02d", Int(recorded) / 60, Int(recorded) % 60)
        if recorder.isPaused {
            button.title = " \(tempo) " + t("status.paused")
        } else if recorded <= 0 {
            // The tap idles while nothing plays: better to say so than to run
            // a stopwatch that is recording nothing.
            button.title = Date().timeIntervalSince(startedAt) > 2.5 ? " " + t("status.nosound") : " 00:00"
        } else {
            button.title = " \(tempo)"
        }
    }

    // MARK: Clicks

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            openMenu()
        } else {
            primaryAction()
        }
    }

    private func primaryAction() {
        guard !busy else { return }
        if recorder.isRecording {
            openMenu()          // recording: offers Pause / Finish
        } else {
            startRecording()
        }
    }

    private func openMenu() {
        let menu = NSMenu()

        if recorder.isRecording {
            let pausar = NSMenuItem(title: t(recorder.isPaused ? "menu.resume" : "menu.pause"),
                                    action: #selector(togglePause), keyEquivalent: "")
            pausar.target = self
            menu.addItem(pausar)

            let finalizar = NSMenuItem(title: t("menu.finish"),
                                       action: #selector(finishRecording), keyEquivalent: "")
            finalizar.target = self
            menu.addItem(finalizar)
        } else {
            let iniciar = NSMenuItem(title: t("menu.start"),
                                     action: #selector(beginRecording), keyEquivalent: "")
            iniciar.target = self
            iniciar.isEnabled = !busy
            menu.addItem(iniciar)
        }

        menu.addItem(.separator())

        let folder = NSMenuItem(title: t("menu.folder"), action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: t("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // Menu actions open dialogs, so they leave the menu stack before running.
    @objc private func beginRecording() {
        DispatchQueue.main.async { [weak self] in self?.startRecording() }
    }

    @objc private func finishRecording() {
        DispatchQueue.main.async { [weak self] in self?.stopRecording() }
    }

    @objc private func togglePause() {
        if recorder.isPaused {
            recorder.resume()
            showRecording()
        } else {
            recorder.pause()
            showPaused()
        }
        updateTitle()
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(destinationFolder)
    }

    @objc private func quit() {
        if recorder.isRecording { stopRecording() }
        NSApp.terminate(nil)
    }

    // MARK: Recording

    /// Returns `true` to record muted, `false` to keep the audio audible,
    /// `nil` if the person backs out.
    func askRecordingMode() -> Bool? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = t("ask.title")
        alert.informativeText = t("ask.body")
        alert.alertStyle = .informational
        if let icon = NSApp.applicationIconImage { alert.icon = icon }
        alert.addButton(withTitle: t("ask.listen"))
        alert.addButton(withTitle: t("ask.mute"))
        alert.addButton(withTitle: t("ask.cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return false
        case .alertSecondButtonReturn: return true
        default: return nil
        }
    }

    private func startRecording() {
        guard let mute = askRecordingMode() else { return }
        do {
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            let stamp = DateFormatter()
            stamp.dateFormat = t("filename.dateformat")
            let wav = destinationFolder
                .appendingPathComponent("\(t("filename.prefix")) \(stamp.string(from: Date())).wav")
            try recorder.start(outputURL: wav, mute: mute)
            // The tap excludes Timbre's own process, so this cue never lands
            // in the recording.
            play(startSound)
            currentWAV = wav
            startedAt = Date()
            showRecording()
            updateTitle()
            ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.updateTitle()
            }
        } catch {
            showError(t("error.start.title"), "\(error)\n\n" + t("error.permission"))
        }
    }

    private func stopRecording() {
        ticker?.invalidate()
        ticker = nil

        let seconds: Double
        do { seconds = try recorder.stop(); play(stopSound) } catch {
            showIdle()
            showError(t("error.failed"), "\(error)")
            return
        }
        guard let wav = currentWAV else { showIdle(); return }
        currentWAV = nil

        guard seconds > 0 else {
            showIdle()
            try? FileManager.default.removeItem(at: wav)
            showError(t("error.nothing.title"), t("error.nothing.body"))
            return
        }

        busy = true
        showSaving()
        let mp3 = wav.deletingPathExtension().appendingPathExtension("mp3")
        conversion.show(fileName: mp3.lastPathComponent)
        let startedConversion = Date()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = Self.encodeMP3(from: wav, to: mp3) { fraction in
                let elapsed = Date().timeIntervalSince(startedConversion)
                let remaining = fraction > 0.02 ? elapsed / fraction - elapsed : nil
                DispatchQueue.main.async { self?.conversion.update(fraction: fraction, remaining: remaining) }
            }
            DispatchQueue.main.async {
                self?.conversion.close()
                guard let self else { return }
                guard ok else {
                    // With no encoder the WAV is still intact, so we keep it.
                    self.busy = false
                    self.showIdle()
                    NSWorkspace.shared.activateFileViewerSelecting([wav])
                    self.showError(t("error.mp3.title"),
                                   String(format: t("error.mp3.body"), wav.lastPathComponent))
                    return
                }
                self.offerTranscription(wav: wav, mp3: mp3, seconds: seconds)
            }
        }
    }

    /// Asks whether to transcribe, then finishes up. Transcription reads the
    /// untouched WAV, which is better input than the MP3 we just encoded, so
    /// the file is only discarded afterwards.
    private func offerTranscription(wav: URL, mp3: URL, seconds: Double) {
        guard Transcriber.isInstalled, askTranscribe(seconds: seconds) else {
            busy = false
            showIdle()
            try? FileManager.default.removeItem(at: wav)
            NSWorkspace.shared.activateFileViewerSelecting([mp3])
            return
        }
        runTranscription(wav: wav, mp3: mp3, seconds: seconds)
    }

    /// Kept separate from the prompt so the progress behaviour can be exercised
    /// without a modal in the way.
    func runTranscription(wav: URL, mp3: URL, seconds: Double) {
        conversion.show(fileName: mp3.lastPathComponent)
        conversion.startTranscription()
        let started = Date()
        reportedProgress = 0

        // whisper.cpp only reports after each 30-second chunk of audio, which
        // leaves the bar frozen in between. We move it along on the clock and
        // snap to the real figure whenever one arrives.
        let estimate = max(seconds / 8, 4)
        transcriptionTicker = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(started)
            let byClock = min(elapsed / estimate, 0.97)
            let shown = max(self.reportedProgress, byClock)
            let remaining = shown > 0.02 ? elapsed / shown - elapsed : estimate
            self.conversion.update(fraction: shown, remaining: remaining)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = Transcriber.run(audio: wav, outputBase: mp3.deletingPathExtension()) { fraction in
                DispatchQueue.main.async { self?.reportedProgress = fraction }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.transcriptionTicker?.invalidate()
                self.transcriptionTicker = nil
                self.conversion.update(fraction: 1, remaining: nil)
                self.conversion.close()
                self.busy = false
                self.showIdle()
                try? FileManager.default.removeItem(at: wav)

                // Reveal the audio together with its transcript, so the pair is
                // visible at once in the same folder.
                let transcript = mp3.deletingPathExtension().appendingPathExtension("txt")
                var reveal = [mp3]
                if ok, FileManager.default.fileExists(atPath: transcript.path) {
                    reveal.append(transcript)
                }
                NSWorkspace.shared.activateFileViewerSelecting(reveal)
                if !ok { self.showError(t("error.transcribe.title"), t("error.transcribe.body")) }
            }
        }
    }

    /// Transcription runs at roughly eight times real time on Apple Silicon,
    /// which is close enough to set an expectation before the person commits.
    private func askTranscribe(seconds: Double) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = t("ask.transcribe.title")
        alert.informativeText = String(format: t("ask.transcribe.body"),
                                       humanDuration(seconds / 8))
        alert.alertStyle = .informational
        if let icon = NSApp.applicationIconImage { alert.icon = icon }
        alert.addButton(withTitle: t("ask.transcribe.yes"))
        alert.addButton(withTitle: t("ask.transcribe.no"))
        return alert.runModal() == .alertFirstButtonReturn
    }


    /// Encodes with the bundled LAME, reporting progress. LAME writes lines
    /// like "1234/5678 ( 22%)" to stderr, which become the bar's fraction.
    static func encodeMP3(from wav: URL, to mp3: URL,
                                  progress: @escaping (Double) -> Void) -> Bool {
        guard let lame = Bundle.main.url(forResource: "lame", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: lame.path) else { return false }

        let task = Process()
        task.executableURL = lame
        task.arguments = ["-b", "192", wav.path, mp3.path]

        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = FileHandle.nullDevice

        let pattern = try? NSRegularExpression(pattern: #"(\d+)/(\d+)\s*\(\s*\d+%\)"#)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8),
                  let pattern else { return }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern.matches(in: text, range: range).last,
                  let doneRange = Range(match.range(at: 1), in: text),
                  let totalRange = Range(match.range(at: 2), in: text),
                  let done = Double(text[doneRange]),
                  let total = Double(text[totalRange]), total > 0 else { return }
            progress(done / total)
        }

        do { try task.run() } catch { return false }
        task.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        if task.terminationStatus == 0 { progress(1) }
        return task.terminationStatus == 0
    }

    private func showError(_ title: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}

func runMenuBar() -> Never {
    let app = NSApplication.shared
    let controller = MenuBarController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}
