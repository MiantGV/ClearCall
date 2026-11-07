import AVFoundation
import Foundation

/// Captures the default microphone, raw (no Apple voice processing, which would
/// turn down other apps' audio).
final class MicCapture {
    private let engine = AVAudioEngine()

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default: completion(false)
        }
    }

    func start(handler: @escaping ChunkHandler) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.message("No microphone is available.")
        }
        let sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
            guard let mono = downmixToMono(buffer) else { return }
            let host = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
            handler(mono, sampleRate, host)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.message("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
