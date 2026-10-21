import Foundation
import Metal

/// One frame's vertex and uniform data in a buffer reused every
/// `SceneRenderer.framesInFlight` frames, grown when a frame needs more.
final class FrameArena {
    private let device: MTLDevice
    private var buffer: MTLBuffer
    private var offset = 0

    init?(device: MTLDevice, capacity: Int) {
        guard let b = device.makeBuffer(length: capacity, options: .storageModeShared) else { return nil }
        self.device = device
        buffer = b
    }

    func reset() { offset = 0 }

    /// Copies `items` in, 256-byte aligned; the buffer and offset to bind,
    /// nil when there is nothing to draw.
    func push<T>(_ items: [T]) -> (buffer: MTLBuffer, offset: Int)? {
        guard !items.isEmpty else { return nil }
        return items.withUnsafeBytes { copy($0) }
    }

    /// One value, as `push` does an array.
    func push<T>(value: T) -> (buffer: MTLBuffer, offset: Int)? {
        withUnsafeBytes(of: value) { copy($0) }
    }

    private func copy(_ bytes: UnsafeRawBufferPointer) -> (buffer: MTLBuffer, offset: Int)? {
        guard let source = bytes.baseAddress else { return nil }
        let length = bytes.count
        var start = (offset + 255) & ~255
        if start + length > buffer.length {
            // The frame's earlier draws keep the old buffer alive.
            guard let b = device.makeBuffer(length: max(2 * buffer.length, 2 * length), options: .storageModeShared)
            else { return nil }
            buffer = b
            start = 0
        }
        buffer.contents().advanced(by: start).copyMemory(from: source, byteCount: length)
        offset = start + length
        return (buffer, start)
    }
}
