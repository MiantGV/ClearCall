import AVFoundation
import CoreAudio
import Foundation

/// The pipeline runs at 48 kHz mono in 10 ms frames (what WebRTC's echo canceller expects).
enum Pipeline {
    static let sampleRate: Double = 48_000
    static let frameSize = 480                       // 10 ms
    static let jitterTolerance: Int64 = 960          // 20 ms: smaller timing errors are ignored
    static let maxLag: Int64 = 24_000                // 0.5 s: a stalled source is filled with silence
}

/// Converts one source's mono audio to 48 kHz.
final class MonoResampler {
    let inputRate: Double
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    init(inputRate: Double) {
        self.inputRate = inputRate
        inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!
        outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Pipeline.sampleRate, channels: 1, interleaved: false)!
        if inputRate == Pipeline.sampleRate {
            converter = nil
        } else {
            converter = AVAudioConverter(from: inFormat, to: outFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        }
    }

    func process(_ samples: [Float]) -> [Float] {
        guard let converter else { return samples }
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let capacity = AVAudioFrameCount(Double(samples.count) * Pipeline.sampleRate / inputRate) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return inBuffer
        }
        guard error == nil, outBuffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
    }
}

/// One source placed on the shared recording timeline (frame 0 = moment Record was pressed).
final class Track {
    private(set) var started = false
    private var base: Int64 = 0          // timeline frame of buf[0]
    private var buf: [Float] = []
    var end: Int64 { base + Int64(buf.count) }

    /// Adds samples whose first sample belongs at timeline frame `frame`.
    func append(_ samples: [Float], at frame: Int64) {
        guard !samples.isEmpty else { return }
        var samples = samples
        var frame = frame
        if frame < 0 {                                   // started before Record was pressed
            let drop = Int(min(Int64(samples.count), -frame))
            samples.removeFirst(drop)
            frame = 0
            if samples.isEmpty { return }
        }
        if !started {
            started = true
            base = frame
            buf = samples
            return
        }
        let diff = frame - end
        if diff > Pipeline.jitterTolerance {             // a gap: fill with silence
            buf.append(contentsOf: [Float](repeating: 0, count: Int(diff)))
        } else if diff < -Pipeline.jitterTolerance {     // overlap: drop what we already have
            let drop = Int(min(Int64(samples.count), -diff))
            samples.removeFirst(drop)
        }
        buf.append(contentsOf: samples)
    }

    /// Makes sure the track reaches at least `frame` (silence where nothing arrived).
    func pad(to frame: Int64) {
        let frame = max(0, frame)
        if !started {
            started = true
            base = frame
            return
        }
        if end < frame { buf.append(contentsOf: [Float](repeating: 0, count: Int(frame - end))) }
    }

    /// Returns `count` samples starting at timeline frame `start` and forgets everything before the end of them.
    func take(from start: Int64, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let idx = start + Int64(i) - base
            if idx >= 0 && idx < Int64(buf.count) { out[i] = buf[Int(idx)] }
        }
        let consumedUpTo = start + Int64(count)
        if consumedUpTo > base {
            let drop = Int(min(Int64(buf.count), consumedUpTo - base))
            buf.removeFirst(drop)
            base += Int64(drop)
            if buf.isEmpty { base = max(base, consumedUpTo) }
        }
        return out
    }
}

enum HostClock {
    static func seconds(from start: UInt64, to time: UInt64) -> Double {
        let a = AudioConvertHostTimeToNanos(start)
        let b = AudioConvertHostTimeToNanos(time)
        return (Double(b) - Double(a)) / 1_000_000_000
    }
}
