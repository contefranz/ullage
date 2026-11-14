import Foundation
import OrbitCore

/// A1's tables (`AtmosphereLUT`), built once per process for each optics
/// (the settings' aerosol and ground albedo) on a background queue: 0.33 s
/// in Release on the M3 Pro, 25 s in Debug. The renderer's atmosphere pass
/// and the tests share them.
public final class AtmosphereTables: @unchecked Sendable {
    public static let shared = AtmosphereTables()

    public struct Key: Hashable {
        public var aerosolOpticalDepth: Double
        public var groundAlbedo: Double

        public init(_ s: AtmosphereSettings = AtmosphereSettings()) {
            aerosolOpticalDepth = s.aerosolOpticalDepth
            groundAlbedo = s.groundAlbedo
        }
    }

    private final class Entry {
        let done = DispatchSemaphore(value: 0)
        var tables: AtmosphereLUT?
        var seconds = 0.0
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    /// Starts building the tables for `key` if nobody has.
    public func request(_ key: Key) {
        lock.lock()
        defer { lock.unlock() }
        guard entries[key] == nil else { return }
        let entry = Entry()
        entries[key] = entry
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            let optics = OpticalAtmosphere(aerosol: OpticalAtmosphere.Aerosol(opticalDepth550: key.aerosolOpticalDepth))
            let tables = AtmosphereLUT(optics: optics, groundAlbedo: Spectrum3(repeating: key.groundAlbedo))
            self.lock.lock()
            entry.tables = tables
            entry.seconds = Date().timeIntervalSince(start)
            self.lock.unlock()
            entry.done.signal()
        }
    }

    /// The tables for `key`, waiting for them when `wait` is set; nil while
    /// they are being built.
    public func tables(_ key: Key = Key(), wait: Bool) -> AtmosphereLUT? {
        request(key)
        lock.lock()
        let entry = entries[key]!
        let tables = entry.tables
        lock.unlock()
        if let tables { return tables }
        guard wait else { return nil }
        entry.done.wait()
        entry.done.signal()
        lock.lock()
        defer { lock.unlock() }
        return entry.tables
    }

    /// How long the build took, s (0 until it is done).
    public func buildSeconds(_ key: Key = Key()) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.seconds ?? 0
    }
}
