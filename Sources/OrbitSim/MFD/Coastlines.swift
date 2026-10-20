import Foundation
import OrbitInstruments

/// The Earth's coastlines for the MAP display: Natural Earth's 1:110m
/// coastline (public domain), packed by tools/make_coastlines.py into
/// Resources/coastlines.bin.
enum Coastlines {
    /// Each line's points, geodetic latitude and longitude in radians; empty
    /// if the resource is missing or malformed.
    static let earth: [[GeoPoint]] = {
        guard let url = Bundle.module.url(forResource: "coastlines", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return [] }
        return parse(data) ?? []
    }()

    /// The resource's lines: magic "OSCOAST1", a uint32 line count, then per
    /// line a uint32 point count and int16 latitude, longitude pairs in
    /// hundredths of a degree, little endian.
    static func parse(_ data: Data) -> [[GeoPoint]]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, String(decoding: bytes[0..<8], as: UTF8.self) == "OSCOAST1" else { return nil }
        var i = 8
        func u32() -> Int? {
            guard i + 4 <= bytes.count else { return nil }
            defer { i += 4 }
            return Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
        }
        func i16() -> Double {
            defer { i += 2 }
            return Double(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8))
        }
        let radians = Double.pi / 180 / 100
        guard let count = u32() else { return nil }
        var lines: [[GeoPoint]] = []
        lines.reserveCapacity(count)
        for _ in 0..<count {
            guard let n = u32(), i + 4 * n <= bytes.count else { return nil }
            lines.append((0..<n).map { _ in
                let lat = i16(), lon = i16()
                return GeoPoint(latitude: lat * radians, longitude: lon * radians)
            })
        }
        return lines
    }
}
