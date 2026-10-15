import Foundation

public struct Star {
    /// Unit direction, ICRF.
    public var direction: Vec3
    public var magnitude: Double
    public var colorIndex: Double   // B-V
}

/// Hipparcos stars down to V = 7, built by `tools/make_stars.py`.
public enum StarCatalog {
    public static func bundled() throws -> [Star] {
        guard let url = Bundle.module.url(forResource: "stars", withExtension: "bin") else {
            throw EphemerisError.resourceMissing("stars.bin")
        }
        return try parse(Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> [Star] {
        guard data.count >= 16, String(decoding: data.prefix(8), as: UTF8.self) == "OSSTAR01" else {
            throw EphemerisError.badFormat("star catalogue header")
        }
        let count = Int(data.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: Int32.self)) })
        guard data.count >= 16 + count * 20 else { throw EphemerisError.badFormat("star catalogue truncated") }
        var stars: [Star] = []
        stars.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            func f(_ off: Int) -> Double {
                Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self))))
            }
            for i in 0..<count {
                let o = 16 + i * 20
                stars.append(Star(direction: Vec3(f(o), f(o + 4), f(o + 8)), magnitude: f(o + 12), colorIndex: f(o + 16)))
            }
        }
        return stars
    }
}
