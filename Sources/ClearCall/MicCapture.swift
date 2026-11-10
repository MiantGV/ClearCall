import AVFoundation
import Foundation

/// Captures the default microphone, raw (no Apple voice processing, which would
/// turn down other apps' audio). Rebuilds itself when the microphone changes
/// (headphones plugged in, AirPods connecting).
final class MicCapture {
    private var engine = AVAudioEngine()
    private var handler: ChunkHandler?
    private var observer: NSObjectProtocol?
    private var running = false

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
        self.handler = handler
        running = true
        do {
            try startEngine()
        } catch {
            running = false
            self.handler = nil
            throw error
        }
    }

    /// Rebuilds the capture on the current default microphone. Main thread.
    func restart() {
        guard running else { return }
        teardown()
        do { try startEngine() } catch { NSLog("ClearCall: microphone restart failed: \(error.localizedDescription)") }
    }

    func stop() {
        running = false
        teardown()
        handler = nil
    }

    private func startEngine() throws {
        guard let handler else { return }
        engine = AVAudioEngine()          // a fresh engine picks up the current default input
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
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardown()
            throw CaptureError.message("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    private func teardown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
