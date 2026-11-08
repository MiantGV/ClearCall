import CEchoCancel
import Foundation

/// WebRTC audio processing: echo cancellation (AEC3), light noise suppression and
/// automatic gain control on the microphone, using the call audio as the echo reference.
final class WebRTCCanceller: EchoCanceller {
    private let handle: OpaquePointer
    private var output = [Float](repeating: 0, count: Pipeline.frameSize)

    init?(echoCancel: Bool, autoGain: Bool) {
        guard let h = ec_create(Int32(Pipeline.sampleRate), echoCancel ? 1 : 0, 1, autoGain ? 1 : 0) else { return nil }
        handle = h
    }

    deinit { ec_destroy(handle) }

    func process(mic: inout [Float], reference: [Float]) {
        let n = Int32(mic.count)
        let status = reference.withUnsafeBufferPointer { ref in
            mic.withUnsafeBufferPointer { m in
                output.withUnsafeMutableBufferPointer { out in
                    ec_process(handle, ref.baseAddress, m.baseAddress, out.baseAddress, n, 0)
                }
            }
        }
        if status == 0 { mic = output }
    }
}
