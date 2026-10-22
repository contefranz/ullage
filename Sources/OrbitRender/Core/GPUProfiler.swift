import Foundation
import Metal

/// GPU time per pass, from timestamp counters sampled at the stage
/// boundaries of each encoder. While it runs, the frame graph gives every
/// render pass an encoder of its own (Apple GPUs sample only at encoder
/// boundaries), so timing costs some bandwidth and changes no pixel. A
/// render pass's time is its vertex stage's plus its fragment stage's: on a
/// tile-based GPU the encoders' vertex stages run ahead, so the span from
/// the first vertex to the last fragment would count the waits too.
@MainActor
public final class GPUProfiler {
    public let isSupported: Bool
    private let device: MTLDevice
    private let counterSet: MTLCounterSet?
    /// Samples per frame: four per encoder.
    nonisolated static let capacity = 256

    init(device: MTLDevice) {
        self.device = device
        counterSet = device.counterSets?.first { $0.name == MTLCommonCounterSet.timestamp.rawValue }
        isSupported = counterSet != nil && device.supportsCounterSampling(.atStageBoundary)
    }

    /// A profile for one frame, nil when the device cannot sample timestamps.
    func beginFrame() -> FrameProfile? {
        guard isSupported, let counterSet else { return nil }
        let d = MTLCounterSampleBufferDescriptor()
        d.counterSet = counterSet
        d.storageMode = .shared
        d.sampleCount = Self.capacity
        guard let buffer = try? device.makeCounterSampleBuffer(descriptor: d) else { return nil }
        return FrameProfile(device: device, buffer: buffer)
    }
}

/// The encoders of one frame and their timestamp samples.
public final class FrameProfile: @unchecked Sendable {
    /// The label of the empty encoder that measures what splitting costs.
    public static let splitOverhead = "(split overhead)"

    private let device: MTLDevice
    private let buffer: MTLCounterSampleBuffer
    private(set) var labels: [String] = []
    private(set) var kinds: [EncoderKind] = []

    /// What an encoder is, for its samples and the split overhead.
    enum EncoderKind {
        /// A continuation of the split scene: it loads and stores the
        /// targets only because the frame is split, so the overhead comes off.
        case sceneContinuation
        /// Any other render encoder (the scene's first, a pass's own): four samples.
        case render
        /// Compute or blit: its start and end only.
        case other
    }
    private var start: (cpu: MTLTimestamp, gpu: MTLTimestamp) = (0, 0)

    init(device: MTLDevice, buffer: MTLCounterSampleBuffer) {
        self.device = device
        self.buffer = buffer
        let t = device.sampleTimestamps()
        start = (t.cpu, t.gpu)
    }

    /// The first of the next encoder's four sample indices, nil when the
    /// buffer is full.
    private func next(_ pass: String, _ kind: EncoderKind) -> Int? {
        guard 4 * (labels.count + 1) <= GPUProfiler.capacity else { return nil }
        labels.append(pass)
        kinds.append(kind)
        return 4 * (labels.count - 1)
    }

    /// Times a render encoder; `continuation` for the split scene's encoders
    /// after its first (`SceneTargetPlan.continuation`). The scene's resume
    /// after a break (`FrameContext.breaksScene`) is not one: the plain frame
    /// pays for it too.
    func attach(_ d: MTLRenderPassDescriptor, pass: String, continuation: Bool = false) {
        guard let i = next(pass, continuation ? .sceneContinuation : .render),
              let a = d.sampleBufferAttachments[0] else { return }
        a.sampleBuffer = buffer
        a.startOfVertexSampleIndex = i
        a.endOfVertexSampleIndex = i + 1
        a.startOfFragmentSampleIndex = i + 2
        a.endOfFragmentSampleIndex = i + 3
    }

    func attach(_ d: MTLComputePassDescriptor, pass: String) {
        guard let i = next(pass, .other), let a = d.sampleBufferAttachments[0] else { return }
        a.sampleBuffer = buffer
        a.startOfEncoderSampleIndex = i
        a.endOfEncoderSampleIndex = i + 1
    }

    func attach(_ d: MTLBlitPassDescriptor, pass: String) {
        guard let i = next(pass, .other), let a = d.sampleBufferAttachments[0] else { return }
        a.sampleBuffer = buffer
        a.startOfEncoderSampleIndex = i
        a.endOfEncoderSampleIndex = i + 1
    }

    /// Seconds of GPU time per pass, in encoding order (a pass's encoders
    /// summed), once the command buffer has completed.
    func resolve() -> [PassTiming] {
        guard !labels.isEmpty, let data = try? buffer.resolveCounterRange(0..<(4 * labels.count)) else { return [] }
        let end = device.sampleTimestamps()
        // GPU ticks to seconds, from the CPU clock (ns) over the frame.
        let ratio = end.gpu > start.gpu ? Double(end.cpu - start.cpu) / Double(end.gpu - start.gpu) : 1
        let stamps = data.withUnsafeBytes { Array($0.bindMemory(to: MTLCounterResultTimestamp.self)) }
        return Self.timings(labels: labels, kinds: kinds, stamps: stamps.map(\.timestamp), secondsPerTick: ratio * 1e-9)
    }

    /// Each encoder's time from its samples (four per encoder): a render
    /// encoder's vertex span plus its fragment span, a compute or blit
    /// encoder's start to end; a span not sampled reads 0. The scene's
    /// continuations lose the split overhead (the empty encoder's time,
    /// reported last), which only splitting makes them pay; a pass's own
    /// encoders and the scene's first keep their time. Summed by pass.
    static func timings(labels: [String], kinds: [EncoderKind], stamps: [UInt64],
                        secondsPerTick: Double) -> [PassTiming] {
        func span(_ i: Int) -> Double {
            let a = stamps[i], b = stamps[i + 1]
            let valid = a != MTLCounterErrorValue && b != MTLCounterErrorValue && a != 0 && b >= a
            return valid ? Double(b - a) * secondsPerTick : 0
        }
        func time(_ k: Int) -> Double { span(4 * k) + (kinds[k] == .other ? 0 : span(4 * k + 2)) }
        let overhead = labels.indices.first { labels[$0] == splitOverhead }.map(time) ?? 0
        var out: [PassTiming] = []
        for (k, label) in labels.enumerated() {
            var seconds = time(k)
            if kinds[k] == .sceneContinuation, label != splitOverhead { seconds = max(0, seconds - overhead) }
            if let j = out.firstIndex(where: { $0.pass == label }) {
                out[j].seconds += seconds
            } else {
                out.append(PassTiming(pass: label, seconds: seconds))
            }
        }
        return out
    }
}

/// One pass's GPU time in a frame.
public struct PassTiming: Equatable, Codable {
    public var pass: String
    public var seconds: Double

    public init(pass: String, seconds: Double) {
        self.pass = pass
        self.seconds = seconds
    }
}

/// What the frames took: the GPU time of each pass in the latest timed
/// (split) frame while profiling, and the latest unsplit frame's, s.
public struct FrameReport: Equatable {
    public var passes: [PassTiming]
    public var gpu: Double

    public init(passes: [PassTiming], gpu: Double) {
        self.passes = passes
        self.gpu = gpu
    }
}
