import Foundation

/// Smoothed frame timings (s), written from Metal's completion thread.
public final class FrameTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var gpuTime = 0.0, encodeTime = 0.0

    public var gpu: Double { lock.withLock { gpuTime } }
    public var encode: Double { lock.withLock { encodeTime } }

    func addGPU(_ t: Double) { lock.withLock { gpuTime = gpuTime == 0 ? t : gpuTime + 0.05 * (t - gpuTime) } }
    func addEncode(_ t: Double) { lock.withLock { encodeTime = encodeTime == 0 ? t : encodeTime + 0.05 * (t - encodeTime) } }
}
