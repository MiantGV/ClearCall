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
    /// nil if the recording couldn't be saved anywhere (the raw audio is kept for the next launch).
    let file: URL?
    let duration: TimeInterval
    let systemAudioWasSilent: Bool
    /// true if the chosen folder couldn't be written and the default folder was used instead.
    let usedFallbackFolder: Bool
}

/// Records the microphone and the Mac's audio into one file.
///
/// While recording, audio is written as plain uncompressed samples to a local working file,
/// which stays readable if the app crashes or the Mac loses power. On Stop it is converted
/// to M4A and moved to the chosen folder. Anything left over is recovered at the next launch.
final class Recorder {
    private let mic = MicCapture()
    private let system = SystemAudioCapture()
    private let queue = DispatchQueue(label: "clearcall.process", qos: .userInitiated)
    private let finishQueue = DispatchQueue(label: "clearcall.finish", qos: .userInitiated)

    // Everything below is only touched on `queue`.
    private var startHost: UInt64 = 0
    private var micTrack = Track()
    private var systemTrack = Track()
    private var micResampler: MonoResampler?
    private var systemResampler: MonoResampler?
    private var outFrame: Int64 = 0
    private var canceller: EchoCanceller = PassthroughCanceller()
    private var rawHandle: FileHandle?
    private var rawURL: URL?
    private var recordingName = ""
    private var destination: URL?
    private var writeFailed = false
    private var testFiles: (micRaw: AVAudioFile, micClean: AVAudioFile, system: AVAudioFile)?
    private var systemPeak: Float = 0
    private var lastMicChunk: UInt64 = 0
    private var lastSystemChunk: UInt64 = 0
    private var levelFrames = 0
    private var micPeak: Float = 0
    private var callPeak: Float = 0

    // Main thread only.
    private(set) var isRecording = false
    private var watchdog: Timer?
    private var lastMicRestart: UInt64 = 0
    private var lastSystemRestart: UInt64 = 0
    private var warnedMic = false
    private var warnedSystem = false

    /// Called on the main thread about 20 times a second with peak levels (0…1) of your voice and the call.
    var onLevels: ((Float, Float) -> Void)?
    /// Called on the main thread when something goes wrong during a recording (title, explanation).
    var onProblem: ((String, String) -> Void)?

    static var inProgressFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClearCall/InProgress", isDirectory: true)
    }

    func start(in folder: URL, keepTestTracks: Bool, echoCancellation: Bool) throws {
        guard !isRecording else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let name = "Recording \(Self.timestamp())"
        let work = Self.inProgressFolder
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let raw = Self.uniqueURL(in: work, name: name, ext: "pcm")
        guard FileManager.default.createFile(atPath: raw.path, contents: nil) else {
            throw CaptureError.message("ClearCall couldn't create its working file. Your disk may be full.")
        }
        let handle = try FileHandle(forWritingTo: raw)

        var tests: (AVAudioFile, AVAudioFile, AVAudioFile)?
        do {
            if keepTestTracks {
                let dir = folder.appendingPathComponent("\(name) (test tracks)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                tests = (try Self.makeWAVFile(dir.appendingPathComponent("mic-raw.wav")),
                         try Self.makeWAVFile(dir.appendingPathComponent("mic-cleaned.wav")),
                         try Self.makeWAVFile(dir.appendingPathComponent("system.wav")))
            }
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: raw)
            throw error
        }

        let now = DispatchTime.now().uptimeNanoseconds
        queue.sync {
            startHost = mach_absolute_time()
            micTrack = Track()
            systemTrack = Track()
            micResampler = nil
            systemResampler = nil
            outFrame = 0
            canceller = WebRTCCanceller(echoCancel: echoCancellation, autoGain: true) ?? PassthroughCanceller()
            rawHandle = handle
            rawURL = raw
            recordingName = name
            destination = folder
            writeFailed = false
            testFiles = tests.map { (micRaw: $0.0, micClean: $0.1, system: $0.2) }
            systemPeak = 0
            lastMicChunk = now
            lastSystemChunk = now
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
            queue.sync { rawHandle = nil; rawURL = nil; testFiles = nil }
            try? handle.close()
            try? FileManager.default.removeItem(at: raw)
            throw error
        }
        isRecording = true
        lastMicRestart = 0
        lastSystemRestart = 0
        warnedMic = false
        warnedSystem = false
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkSources() }
    }

    func stop(completion: @escaping (RecordingResult?) -> Void) {
        stop(completion: completion, finished: nil)
    }

    /// Stops and waits (up to `timeout` seconds) for the file to be saved. For quitting.
    func stopAndWait(timeout: TimeInterval) {
        guard isRecording else { return }
        let done = DispatchSemaphore(value: 0)
        stop(completion: { _ in }, finished: { done.signal() })
        _ = done.wait(timeout: .now() + timeout)
    }

    private func stop(completion: @escaping (RecordingResult?) -> Void, finished: (() -> Void)?) {
        guard isRecording else { completion(nil); finished?(); return }
        isRecording = false
        watchdog?.invalidate()
        watchdog = nil
        mic.stop()
        system.stop()
        queue.async { [self] in
            // Flush what's left.
            let last = max(micTrack.end, systemTrack.end)
            micTrack.pad(to: last)
            systemTrack.pad(to: last)
            pump()
            let duration = Double(outFrame) / Pipeline.sampleRate
            let silent = systemPeak < 0.0005
            try? rawHandle?.close()
            rawHandle = nil
            testFiles = nil          // closing the files finalises them
            let raw = rawURL
            let name = recordingName
            let folders = Self.saveFolders(destination)
            rawURL = nil
            // Converting can take a few seconds for a long call; keep it off the recording queue.
            finishQueue.async {
                var saved: (URL?, Bool) = (nil, false)
                if let raw { saved = Self.finalize(raw: raw, name: name, folders: folders) }
                finished?()
                DispatchQueue.main.async {
                    completion(RecordingResult(file: saved.0, duration: duration,
                                               systemAudioWasSilent: silent, usedFallbackFolder: saved.1))
                }
            }
        }
    }

    /// Converts recordings left behind by a crash or power loss. Call at launch (main thread).
    func recoverInterrupted(into folder: URL, completion: @escaping ([URL]) -> Void) {
        guard !isRecording else { completion([]); return }
        let all = (try? FileManager.default.contentsOfDirectory(at: Self.inProgressFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let leftovers = all.filter { $0.pathExtension == "pcm" }
        guard !leftovers.isEmpty else { completion([]); return }
        finishQueue.async {
            var recovered: [URL] = []
            for raw in leftovers {
                let size = (try? raw.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size < 96_000 {                       // under a second: nothing worth keeping
                    try? FileManager.default.removeItem(at: raw)
                    continue
                }
                let name = raw.deletingPathExtension().lastPathComponent + " (recovered)"
                if let url = Self.finalize(raw: raw, name: name, folders: Self.saveFolders(folder)).0 {
                    recovered.append(url)
                }
            }
            DispatchQueue.main.async { completion(recovered) }
        }
    }

    // MARK: - Watchdog (main thread)

    /// Both sources deliver audio continuously (silence included), so a gap means a source
    /// has stalled, usually because the microphone or speakers changed. Restart it, and warn if that doesn't help.
    private func checkSources() {
        guard isRecording else { return }
        let (micSeen, systemSeen) = queue.sync { (lastMicChunk, lastSystemChunk) }
        let now = DispatchTime.now().uptimeNanoseconds
        func seconds(since t: UInt64) -> Double { now > t ? Double(now - t) / 1_000_000_000 : 0 }

        if seconds(since: micSeen) > 3 {
            if seconds(since: lastMicRestart) > 4 {
                lastMicRestart = now
                mic.restart()
            }
            if seconds(since: micSeen) > 10, !warnedMic {
                warnedMic = true
                onProblem?("Your microphone isn't being recorded",
                           "ClearCall stopped receiving your voice. Check your microphone, then stop and restart the recording.")
            }
        }
        if seconds(since: systemSeen) > 3 {
            if seconds(since: lastSystemRestart) > 4 {
                lastSystemRestart = now
                system.restart()
            }
            if seconds(since: systemSeen) > 10, !warnedSystem {
                warnedSystem = true
                onProblem?("The call audio isn't being recorded",
                           "ClearCall stopped receiving the other person's voice. Stop and restart the recording.")
            }
        }
    }

    // MARK: - Processing (on `queue`)

    private func receive(_ samples: [Float], rate: Double, host: UInt64, isMic: Bool) {
        guard rawHandle != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let resampler: MonoResampler
        if isMic {
            lastMicChunk = now
            if micResampler?.inputRate != rate { micResampler = MonoResampler(inputRate: rate) }
            resampler = micResampler!
        } else {
            lastSystemChunk = now
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
            writeRaw(mixed)
            if let tests = testFiles {
                write(micRaw, to: tests.micRaw)
                write(cleaned, to: tests.micClean)
                write(reference, to: tests.system)
            }
            outFrame += Int64(n)
        }
    }

    /// Appends 16-bit samples to the working file. Tells the user once if writing fails.
    private func writeRaw(_ samples: [Float]) {
        guard let rawHandle, !writeFailed else { return }
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let s = samples[i]
            pcm[i] = s.isFinite ? Int16(max(-1, min(1, s)) * 32767) : 0
        }
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try rawHandle.write(contentsOf: data)
        } catch {
            writeFailed = true
            NSLog("ClearCall: recording write failed: \(error)")
            let onProblem = self.onProblem
            DispatchQueue.main.async {
                onProblem?("ClearCall can't keep saving this recording",
                           "Your disk may be full. Everything recorded up to now is kept. Free some space, then start a new recording.")
            }
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
        do { try file.write(from: buffer) } catch { NSLog("ClearCall: test track write failed: \(error)") }
    }

    private func softClip(_ x: Float) -> Float {
        let threshold: Float = 0.9
        if abs(x) <= threshold { return x }
        let sign: Float = x < 0 ? -1 : 1
        let excess = abs(x) - threshold
        return sign * (threshold + (1 - threshold) * tanh(excess / (1 - threshold)))
    }

    // MARK: - Saving

    /// The chosen folder first, then the default folder as a fallback.
    private static func saveFolders(_ chosen: URL?) -> [URL] {
        var folders: [URL] = []
        if let chosen { folders.append(chosen) }
        if !folders.contains(AppSettings.defaultFolder) { folders.append(AppSettings.defaultFolder) }
        return folders
    }

    /// Converts the working file to M4A (locally), then moves it into the first folder that accepts it.
    /// Returns the saved file and whether the fallback folder had to be used. The working file is
    /// only deleted once the M4A is safely in place.
    static func finalize(raw: URL, name: String, folders: [URL]) -> (URL?, Bool) {
        let local = raw.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: local)
        do {
            try convert(raw: raw, to: local)
        } catch {
            NSLog("ClearCall: converting \(raw.lastPathComponent) failed: \(error)")
            return (nil, false)
        }
        for (index, folder) in folders.enumerated() {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = uniqueURL(in: folder, name: name, ext: "m4a")
                try FileManager.default.moveItem(at: local, to: url)
                try? FileManager.default.removeItem(at: raw)
                return (url, index > 0)
            } catch {
                NSLog("ClearCall: saving into \(folder.path) failed: \(error)")
            }
        }
        return (nil, false)
    }

    private static func convert(raw: URL, to m4a: URL) throws {
        let input = try FileHandle(forReadingFrom: raw)
        defer { try? input.close() }
        let output = try makeAACFile(m4a)
        let chunkFrames = 48_000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: AVAudioFrameCount(chunkFrames)) else {
            throw CaptureError.message("Couldn't prepare the audio file.")
        }
        while true {
            guard let data = try input.read(upToCount: chunkFrames * 2), data.count >= 2 else { break }
            let frames = data.count / 2
            let dst = buffer.floatChannelData![0]
            data.withUnsafeBytes { bytes in
                for i in 0..<frames {
                    dst[i] = Float(bytes.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)) / 32768
                }
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            try output.write(from: buffer)
        }
    }

    /// `ClearCall --test-save <folder>`: build-time check that a working file converts and lands in a folder,
    /// and that an unwritable folder falls back to the next one.
    static func runSelfTestIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--test-save"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        let work = dir.appendingPathComponent("work", isDirectory: true)
        let good = dir.appendingPathComponent("good", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        func makeRaw(_ name: String, seconds: Int) -> URL {
            var pcm = [Int16](repeating: 0, count: 48_000 * seconds)
            for n in 0..<pcm.count { pcm[n] = Int16(8000 * sin(2 * Double.pi * 440 * Double(n) / 48_000)) }
            let url = work.appendingPathComponent(name + ".pcm")
            try? pcm.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: url)
            return url
        }
        func seconds(_ url: URL?) -> Double {
            guard let url, let file = try? AVAudioFile(forReading: url) else { return -1 }
            return Double(file.length) / file.processingFormat.sampleRate
        }

        let first = makeRaw("one", seconds: 3)
        let a = finalize(raw: first, name: "Test", folders: [good])
        let aOK = abs(seconds(a.0) - 3) < 0.2 && !a.1 && !FileManager.default.fileExists(atPath: first.path)
        print("SAVE-CHECK normal: \(aOK ? "OK" : "FAILED") (\(seconds(a.0)) s)")

        let second = makeRaw("two", seconds: 2)
        let blocked = URL(fileURLWithPath: "/System/ClearCallCannotWriteHere", isDirectory: true)
        let b = finalize(raw: second, name: "Test", folders: [blocked, good])
        let bOK = abs(seconds(b.0) - 2) < 0.2 && b.1
        print("SAVE-CHECK fallback: \(bOK ? "OK" : "FAILED") (\(seconds(b.0)) s)")

        let third = makeRaw("three", seconds: 1)
        let c = finalize(raw: third, name: "Test", folders: [blocked])
        let cOK = c.0 == nil && FileManager.default.fileExists(atPath: third.path)
        print("SAVE-CHECK nowhere-to-save keeps the audio: \(cOK ? "OK" : "FAILED")")
        return true
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
