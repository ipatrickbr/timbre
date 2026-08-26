import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

struct Err: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func fourCC(_ s: OSStatus) -> String {
    let v = UInt32(bitPattern: s)
    let b = [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]
    return b.allSatisfy { $0 >= 32 && $0 < 127 } ? "'\(String(bytes: b, encoding: .ascii)!)'" : "\(s)"
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw Err("\(what) failed — \(fourCC(status))") }
}

/// Not generic on purpose: a generic `T` here makes the compiler warn about
/// forming a raw pointer to a value that might hold an object reference.
private func systemAudioObject(_ selector: AudioObjectPropertySelector) throws -> AudioObjectID {
    var addr = AudioObjectPropertyAddress(mSelector: selector,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var value = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &value), "reading system property")
    return value
}

private func deviceUID(_ device: AudioObjectID) throws -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var uid: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    try withUnsafeMutablePointer(to: &uid) { ptr in
        try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr), "reading device UID")
    }
    return uid as String
}

private func tapStreamFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd), "reading tap format")
    return asbd
}

/// Audio object for the current process, used to keep Timbre's own sound cues
/// out of the recording.
private func currentProcessAudioObject() -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var pid = getpid()
    var objectID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &objectID)
    return status == noErr && objectID != kAudioObjectUnknown ? objectID : nil
}

/// Records the system audio mix through a Core Audio process tap.
/// With `mute` on, audio is captured without playing through the speakers.
final class TapRecorder: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var audioFile: AVAudioFile?
    private var frames: Int64 = 0
    private var sampleRate: Double = 48000
    private var writeFailure: Error?
    private let lock = NSLock()

    private(set) var isRecording = false
    private var paused = false

    /// While paused the IOProc keeps running but nothing is written: the paused
    /// stretch stays out of the file and recording resumes into the same MP3.
    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    func pause() {
        lock.lock(); paused = true; lock.unlock()
    }

    func resume() {
        lock.lock(); paused = false; lock.unlock()
    }

    var recordedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(frames) / sampleRate
    }

    func start(outputURL: URL, mute: Bool) throws {
        guard !isRecording else { return }

        let outputDevice = try systemAudioObject(kAudioHardwarePropertyDefaultOutputDevice)
        guard outputDevice != kAudioObjectUnknown else {
            throw Err("no default output device found")
        }
        let outputUID = try deviceUID(outputDevice)

        // Exclude our own process so the start cue never lands in the recording.
        // The exclusion is per process and does not affect other apps.
        let excluded: [AudioObjectID] = currentProcessAudioObject().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "timbre"
        description.isPrivate = true
        description.muteBehavior = mute ? .mutedWhenTapped : .unmuted
        let tapUUID = description.uuid.uuidString

        try check(AudioHardwareCreateProcessTap(description, &tapID), "creating the process tap")

        // The tap has no clock of its own: it must live inside an aggregate
        // device anchored to the current output device.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "timbre-aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  "creating the aggregate device")

        var asbd = try tapStreamFormat(tapID)
        guard let inputFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw Err("unsupported tap audio format")
        }

        frames = 0
        paused = false
        writeFailure = nil
        sampleRate = inputFormat.sampleRate
        audioFile = try AVAudioFile(forWriting: outputURL,
                                    settings: [
                                        AVFormatIDKey: kAudioFormatLinearPCM,
                                        AVSampleRateKey: inputFormat.sampleRate,
                                        AVNumberOfChannelsKey: Int(inputFormat.channelCount),
                                        AVLinearPCMBitDepthKey: 16,
                                        AVLinearPCMIsFloatKey: false,
                                        AVLinearPCMIsBigEndianKey: false,
                                        AVLinearPCMIsNonInterleaved: false,
                                    ],
                                    commonFormat: inputFormat.commonFormat,
                                    interleaved: inputFormat.isInterleaved)

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID,
                                                     DispatchQueue(label: "timbre.write")) {
            [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.writeFailure == nil, !self.paused, let file = self.audioFile,
                  let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: inInputData)
            else { return }
            do {
                try file.write(from: buffer)
                self.frames += Int64(buffer.frameLength)
            } catch { self.writeFailure = error }
        }, "registering the IOProc")

        try check(AudioDeviceStart(aggregateID, procID), "starting capture")
        isRecording = true
    }

    /// Stops capture and returns the recorded duration. The WAV header is only
    /// written when the AVAudioFile is released, so we drop the reference here.
    @discardableResult
    func stop() throws -> Double {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRecording = false

        lock.lock()
        defer { lock.unlock() }
        audioFile = nil
        if let writeFailure { throw writeFailure }
        return Double(frames) / sampleRate
    }
}
