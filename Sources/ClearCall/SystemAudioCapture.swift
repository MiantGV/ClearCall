import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum CaptureError: LocalizedError {
    case coreAudio(String, OSStatus)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let step, let status): return "\(step) failed (Core Audio error \(status))."
        case .message(let text): return text
        }
    }
}

/// Mono chunk of audio from one source, with the host time of its first sample.
typealias ChunkHandler = (_ samples: [Float], _ sampleRate: Double, _ hostTime: UInt64) -> Void

/// Captures everything your Mac plays (the call audio) with a Core Audio process tap.
/// Uses only the "System Audio Recording" permission (macOS 14.4+), not screen recording.
final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "clearcall.system-audio", qos: .userInteractive)

    func start(handler: @escaping ChunkHandler) throws {
        // 1. A global tap of every app's audio (we play nothing ourselves).
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tap)
        guard err == noErr else { throw CaptureError.coreAudio("Creating the system audio tap", err) }
        tapID = tap

        // 2. A private aggregate device that hosts the tap, clocked by the current output device.
        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ClearCall Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard err == noErr else {
            stop()
            throw CaptureError.coreAudio("Creating the capture device", err)
        }
        aggregateID = agg

        // 3. The tap's audio format.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw CaptureError.coreAudio("Reading the system audio format", err)
        }
        let sampleRate = format.sampleRate

        // 4. Receive audio.
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            _, inInputData, inInputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil),
                  let mono = downmixToMono(buffer) else { return }
            let time = inInputTime.pointee
            let host = (time.mFlags.contains(.hostTimeValid) && time.mHostTime != 0) ? time.mHostTime : mach_absolute_time()
            handler(mono, sampleRate, host)
        }
        guard err == noErr else {
            stop()
            throw CaptureError.coreAudio("Starting system audio capture", err)
        }
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else {
            stop()
            throw CaptureError.coreAudio("Starting system audio capture", err)
        }
    }

    func stop() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard err == noErr else { throw CaptureError.coreAudio("Finding the output device", err) }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        err = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard err == noErr else { throw CaptureError.coreAudio("Reading the output device", err) }
        return uid as String
    }
}

/// Averages all channels of a float buffer into one mono array.
func downmixToMono(_ buffer: AVAudioPCMBuffer) -> [Float]? {
    guard let data = buffer.floatChannelData else { return nil }
    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    guard frames > 0, channels > 0 else { return nil }
    let stride = buffer.stride
    let interleaved = buffer.format.isInterleaved
    var out = [Float](repeating: 0, count: frames)
    let scale = 1 / Float(channels)
    for c in 0..<channels {
        let base = interleaved ? data[0] : data[c]
        let offset = interleaved ? c : 0
        for i in 0..<frames {
            out[i] += base[i * stride + offset] * scale
        }
    }
    return out
}
