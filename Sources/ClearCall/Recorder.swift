import AVFoundation
import Foundation

/// Removes the call audio (reference) from the microphone, 10 ms at a time.
protocol EchoCanceller: AnyObject {
    func process(mic: inout [Float], reference: [Float])
}

/// Placeholder until WebRTC's echo canceller is added.
final class PassthroughCanceller: EchoCanceller {
    func process(mic: inout [Float], reference: [Float]) {}
}

struct RecordingResult {
    let file: URL
    let duration: TimeInterval
    let systemAudioWasSilent: Bool
}

/// Records the microphone and the Mac's audio into one file.
final class Recorder {
    private let mic = MicCapture()
    private let system = SystemAudioCapture()
    private let queue = DispatchQueue(label: "clearcall.process", qos: .userInitiated)

    // Everything below is only touched on `queue`.
    private var startHost: UInt64 = 0
    private var micTrack = Track()
    private var systemTrack = Track()
    private var micResampler: MonoResampler?
    private var systemResampler: MonoResampler?
    private var outFrame: Int64 = 0
    private var canceller: EchoCanceller = PassthroughCanceller()
    private var mixFile: AVAudioFile?
    private var testFiles: (micRaw: AVAudioFile, micClean: AVAudioFile, system: AVAudioFile)?
    private var systemPeak: Float = 0
    private var outputURL: URL?

    private(set) var isRecording = false

    /// Called on the main thread about 20 times a second with peak levels (0…1) of your voice and the call.
    var onLevels: ((Float, Float) -> Void)?
    private var levelFrames = 0
    private var micPeak: Float = 0
    private var callPeak: Float = 0

    func start(in folder: URL, keepTestTracks: Bool, echoCancellation: Bool) throws {
        guard !isRecording else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let name = "Recording \(Self.timestamp())"
        let url = Self.uniqueURL(in: folder, name: name, ext: "m4a")
        let mix = try Self.makeAACFile(url)
        var tests: (AVAudioFile, AVAudioFile, AVAudioFile)?
        if keepTestTracks {
            let dir = folder.appendingPathComponent("\(name) (test tracks)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            tests = (try Self.makeWAVFile(dir.appendingPathComponent("mic-raw.wav")),
                     try Self.makeWAVFile(dir.appendingPathComponent("mic-cleaned.wav")),
                     try Self.makeWAVFile(dir.appendingPathComponent("system.wav")))
        }

        queue.sync {
            startHost = mach_absolute_time()
            micTrack = Track()
            systemTrack = Track()
            micResampler = nil
            systemResampler = nil
            outFrame = 0
            canceller = WebRTCCanceller(echoCancel: echoCancellation, autoGain: true) ?? PassthroughCanceller()
            mixFile = mix
            testFiles = tests.map { (micRaw: $0.0, micClean: $0.1, system: $0.2) }
            systemPeak = 0
            outputURL = url
        }

        do {
            try system.start { [weak self] samples, rate, host in
                self?.queue.async { self?.receive(samples, rate: rate, host: host, isMic: false) }
            }
            try mic.start { [weak self] samples, rate, host in
                self?.queue.async { self?.receive(samples, rate: rate, host: host, isMic: true) }
            }
        } catch {
            system.stop()
            mic.stop()
            queue.sync { mixFile = nil; testFiles = nil }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        isRecording = true
    }

    func stop(completion: @escaping (RecordingResult?) -> Void) {
        guard isRecording else { completion(nil); return }
        isRecording = false
        mic.stop()
        system.stop()
        queue.async { [self] in
            // Flush what's left.
            let last = max(micTrack.end, systemTrack.end)
            micTrack.pad(to: last)
            systemTrack.pad(to: last)
            pump()
            let duration = Double(outFrame) / Pipeline.sampleRate
            let result = outputURL.map {
                RecordingResult(file: $0, duration: duration, systemAudioWasSilent: systemPeak < 0.0005)
            }
            mixFile = nil          // closing the files finalises them
            testFiles = nil
            outputURL = nil
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Processing (on `queue`)

    private func receive(_ samples: [Float], rate: Double, host: UInt64, isMic: Bool) {
        guard mixFile != nil else { return }
        let resampler: MonoResampler
        if isMic {
            if micResampler?.inputRate != rate { micResampler = MonoResampler(inputRate: rate) }
            resampler = micResampler!
        } else {
            if systemResampler?.inputRate != rate { systemResampler = MonoResampler(inputRate: rate) }
            resampler = systemResampler!
        }
        let converted = resampler.process(samples)
        let frame = Int64((HostClock.seconds(from: startHost, to: host) * Pipeline.sampleRate).rounded())
        (isMic ? micTrack : systemTrack).append(converted, at: frame)
        pump()
    }

    private func pump() {
        // If one source stalls (device change, no permission), don't hold the other back.
        let ends = [micTrack, systemTrack].filter(\.started).map(\.end)
        guard let newest = ends.max() else { return }
        for track in [micTrack, systemTrack] where !track.started || track.end < newest - Pipeline.maxLag {
            track.pad(to: newest - Pipeline.maxLag)
        }

        let n = Pipeline.frameSize
        while min(micTrack.end, systemTrack.end) >= outFrame + Int64(n) {
            let micRaw = micTrack.take(from: outFrame, count: n)
            let reference = systemTrack.take(from: outFrame, count: n)
            var cleaned = micRaw
            canceller.process(mic: &cleaned, reference: reference)

            var mixed = [Float](repeating: 0, count: n)
            for i in 0..<n {
                mixed[i] = softClip(cleaned[i] + reference[i])
                systemPeak = max(systemPeak, abs(reference[i]))
                micPeak = max(micPeak, abs(cleaned[i]))
                callPeak = max(callPeak, abs(reference[i]))
            }
            levelFrames += 1
            if levelFrames >= 5, let onLevels {
                let m = micPeak, c = callPeak
                DispatchQueue.main.async { onLevels(m, c) }
                levelFrames = 0
                micPeak = 0
                callPeak = 0
            }
            write(mixed, to: mixFile)
            if let tests = testFiles {
                write(micRaw, to: tests.micRaw)
                write(cleaned, to: tests.micClean)
                write(reference, to: tests.system)
            }
            outFrame += Int64(n)
        }
    }

    private func write(_ samples: [Float], to file: AVAudioFile?) {
        guard let file,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        do { try file.write(from: buffer) } catch { NSLog("ClearCall: write failed: \(error)") }
    }

    private func softClip(_ x: Float) -> Float {
        let threshold: Float = 0.9
        if abs(x) <= threshold { return x }
        let sign: Float = x < 0 ? -1 : 1
        let excess = abs(x) - threshold
        return sign * (threshold + (1 - threshold) * tanh(excess / (1 - threshold)))
    }

    // MARK: - Files

    private static func makeAACFile(_ url: URL) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Pipeline.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private static func makeWAVFile(_ url: URL) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Pipeline.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }

    private static func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
        var url = folder.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n).\(ext)")
            n += 1
        }
        return url
    }
}
