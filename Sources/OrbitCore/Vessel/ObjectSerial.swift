import Foundation

/// An object's identity for the life of the process. `ObjectIdentifier` is
/// the object's address, which a later object takes once the first is
/// freed: a cache that outlives the objects it is keyed by (the renderer's
/// part meshes, from one scenario or snapshot to the next) would then serve
/// a new part another's mesh, and which one depended on the allocator's
/// timing. No two objects ever get the same serial.
public struct ObjectSerial: Hashable, Comparable, CustomStringConvertible {
    public let value: UInt64

    /// The next serial, from any thread.
    public static func next() -> ObjectSerial {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return ObjectSerial(value: counter)
    }

    public static func < (a: ObjectSerial, b: ObjectSerial) -> Bool { a.value < b.value }
    public var description: String { "#\(value)" }

    private static let lock = NSLock()
    private static var counter: UInt64 = 0
}
