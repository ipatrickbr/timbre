import Foundation
import AVFoundation

/// Records the microphone alongside the system audio tap. The tap only ever
/// hears what plays through the Mac's own output, so on a call the other
/// side is captured but the person's own voice never is — this fills that
/// gap for interviews, kept as a second, independent recording that gets
/// mixed into the system audio once both stop.
final class MicRecorder {
    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var frames: Int64 = 0
    private var sampleRate: Double = 48000
    private var writeFailure: Error?
    private let lock = NSLock()

    private(set) var isRecording = false
    private var paused = false

    /// When the first real frame landed. The microphone's hardware clock
    /// runs continuously from the moment capture starts — unlike the system
    /// tap, which idles until something actually plays — so this is what
    /// the two get lined up against when mixing.
    private(set) var firstFrameAt: Date?

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    /// Skips writing for the paused stretch, exactly like `TapRecorder`, so
    /// the two files stay aligned once mixed together.
    func pause() {
        lock.lock(); paused = true; lock.unlock()
    }

    func resume() {
        lock.lock(); paused = false; lock.unlock()
    }

    static func hasPermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Triggers the system prompt the first time; macOS remembers the answer
    /// after that and this returns immediately.
    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func start(outputURL: URL) throws {
        guard !isRecording else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw Err("no microphone input available")
        }

        frames = 0
        paused = false
        writeFailure = nil
        firstFrameAt = nil
        sampleRate = format.sampleRate
        audioFile = try AVAudioFile(forWriting: outputURL,
                                    settings: [
                                        AVFormatIDKey: kAudioFormatLinearPCM,
                                        AVSampleRateKey: format.sampleRate,
                                        AVNumberOfChannelsKey: Int(format.channelCount),
                                        AVLinearPCMBitDepthKey: 16,
                                        AVLinearPCMIsFloatKey: false,
                                        AVLinearPCMIsBigEndianKey: false,
                                        AVLinearPCMIsNonInterleaved: false,
                                    ],
                                    commonFormat: format.commonFormat,
                                    interleaved: format.isInterleaved)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.writeFailure == nil, !self.paused, let file = self.audioFile else { return }
            do {
                try file.write(from: buffer)
                if self.firstFrameAt == nil { self.firstFrameAt = Date() }
                self.frames += Int64(buffer.frameLength)
            } catch { self.writeFailure = error }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            audioFile = nil
            throw error
        }
        isRecording = true
    }

    /// Stops capture and returns the recorded duration. The WAV header is
    /// only written when the AVAudioFile is released, so we drop it here.
    @discardableResult
    func stop() throws -> Double {
        guard isRecording else { return 0 }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false

        lock.lock()
        defer { lock.unlock() }
        audioFile = nil
        if let writeFailure { throw writeFailure }
        return Double(frames) / sampleRate
    }

    // MARK: - Mixing

    /// Combines the system audio recording with the separate microphone
    /// recording into one file. Offline, non-realtime rendering through an
    /// `AVAudioEngine` mixer — it converts sample rate and channel count
    /// differences between the two sources on its own, so neither recorder
    /// needs to know or care what format the other used. `systemFirstFrame`
    /// and `micFirstFrame` are each recorder's `firstFrameAt`: the system
    /// tap idles until something actually plays, while the microphone's
    /// hardware clock runs from the moment it opens, so on a recording that
    /// begins before a call connects the two can start their real content
    /// several seconds apart. Whichever side's content started later gets
    /// delayed by the gap so the two line back up.
    static func mix(system: URL, mic: URL, into output: URL,
                    systemFirstFrame: Date?, micFirstFrame: Date?) throws {
        let systemFile = try AVAudioFile(forReading: system)
        let micFile = try AVAudioFile(forReading: mic)
        let outputFormat = systemFile.processingFormat

        let engine = AVAudioEngine()
        let systemPlayer = AVAudioPlayerNode()
        let micPlayer = AVAudioPlayerNode()
        engine.attach(systemPlayer)
        engine.attach(micPlayer)
        engine.connect(systemPlayer, to: engine.mainMixerNode, format: systemFile.processingFormat)
        engine.connect(micPlayer, to: engine.mainMixerNode, format: micFile.processingFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)

        try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 4096)
        try engine.start()

        var systemDelay: TimeInterval = 0
        var micDelay: TimeInterval = 0
        if let systemFirstFrame, let micFirstFrame {
            let gap = systemFirstFrame.timeIntervalSince(micFirstFrame)
            if gap > 0 { systemDelay = gap } else { micDelay = -gap }
        }
        let systemDelayFrames = framePosition(systemDelay, outputFormat)
        let micDelayFrames = framePosition(micDelay, outputFormat)

        systemPlayer.scheduleFile(systemFile, at: startTime(systemDelayFrames, outputFormat))
        micPlayer.scheduleFile(micFile, at: startTime(micDelayFrames, outputFormat))
        systemPlayer.play()
        micPlayer.play()

        let outFile = try AVAudioFile(forWriting: output, settings: outputFormat.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { throw Err("could not allocate a render buffer") }

        // Render out to the later of the two once their delays are folded
        // in, rather than trimming anything.
        let totalFrames = max(systemDelayFrames + systemFile.length, micDelayFrames + micFile.length)
        var rendered: AVAudioFramePosition = 0
        while rendered < totalFrames {
            let toRender = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity),
                                                  totalFrames - rendered))
            buffer.frameLength = toRender
            switch try engine.renderOffline(toRender, to: buffer) {
            case .success:
                try outFile.write(from: buffer)
                rendered += AVAudioFramePosition(toRender)
            case .insufficientDataFromInputNode:
                continue
            case .cannotDoInCurrentContext:
                continue
            case .error:
                throw Err("offline render failed while mixing in the microphone")
            @unknown default:
                throw Err("offline render failed while mixing in the microphone")
            }
        }
    }

    private static func framePosition(_ seconds: TimeInterval, _ format: AVAudioFormat) -> AVAudioFramePosition {
        AVAudioFramePosition((max(seconds, 0) * format.sampleRate).rounded())
    }

    /// `nil` schedules the file to start the moment its player is told to
    /// play, matching `AVAudioPlayerNode.scheduleFile`'s own default.
    private static func startTime(_ delayFrames: AVAudioFramePosition, _ format: AVAudioFormat) -> AVAudioTime? {
        delayFrames > 0 ? AVAudioTime(sampleTime: delayFrames, atRate: format.sampleRate) : nil
    }
}
