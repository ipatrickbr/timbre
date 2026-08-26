import Foundation
import ScreenCaptureKit
import AVFoundation

// ScreenCaptureKit backend: captures the system audio mix. It uses the
// screen-and-system-audio permission, which has an official authorization
// flow — unlike Core Audio process taps.
final class SystemAudioCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let outputURL: URL
    private var file: AVAudioFile?
    private var stream: SCStream?
    private(set) var frames: Int64 = 0
    private(set) var sampleRate: Double = 48000
    private(set) var failure: Error?
    private let lock = NSLock()

    init(outputURL: URL) { self.outputURL = outputURL }

    func start() async throws {
        // This call is what triggers the macOS permission prompt.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw Err("no display available to anchor the capture")
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        // Excluding the "current process" also drops sibling processes launched
        // by the same responsible app, which would silence valid captures.
        config.excludesCurrentProcessAudio = false
        config.sampleRate = 48000
        config.channelCount = 2
        // Video is mandatory in the filter, so we keep it minimal.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "timbre.sck"))
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let formatDescription = sampleBuffer.formatDescription,
              var asbd = formatDescription.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return }

        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        do {
            if file == nil {
                sampleRate = format.sampleRate
                file = try AVAudioFile(forWriting: outputURL,
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
            }
            guard let file else { return }
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                    bufferListNoCopy: audioBufferList.unsafePointer)
                else { return }
                try file.write(from: buffer)
                frames += Int64(buffer.frameLength)
            }
        } catch { failure = error }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); failure = error; lock.unlock()
    }

    /// Stops capture and closes the file. The WAV header is only written when
    /// the AVAudioFile is released, so we drop the reference here.
    func finish() async -> (seconds: Double, error: Error?) {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        lock.lock()
        defer { lock.unlock() }
        file = nil
        return (Double(frames) / sampleRate, failure)
    }
}
