import Foundation

/// What a vessel touching a body's surface meets.
public enum SurfaceKind: Equatable {
    case land, water
}

/// A land/water grid on geodetic latitude and longitude: the Earth's, built
/// by `tools/make_landmask.py` from Natural Earth's 1:10m land polygons
/// (public domain). 0.25° cells, each land when its centre is inside a land
/// polygon; Natural Earth's land counts lakes as land, but not the Caspian.
public struct SurfaceMask {
    public let columns: Int
    public let rows: Int
    /// One bit per cell, rows from the south, each from longitude -180°
    /// eastwards, least significant bit first; set bits are land.
    let bits: [UInt8]

    /// The Earth's mask, bundled as `landmask.bin`; nil if it is missing.
    public static let earth: SurfaceMask? = try? bundled()

    public static func bundled() throws -> SurfaceMask {
        guard let url = Bundle.module.url(forResource: "landmask", withExtension: "bin") else {
            throw EphemerisError.resourceMissing("landmask.bin")
        }
        return try parse(Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> SurfaceMask {
        guard data.count >= 16, String(decoding: data.prefix(8), as: UTF8.self) == "OSLAND01" else {
            throw EphemerisError.badFormat("land mask header")
        }
        let (columns, rows) = data.withUnsafeBytes {
            (Int(Int32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: Int32.self))),
             Int(Int32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: Int32.self))))
        }
        guard columns > 0, rows > 0, data.count == 16 + (columns * rows + 7) / 8 else {
            throw EphemerisError.badFormat("land mask size")
        }
        return SurfaceMask(columns: columns, rows: rows, bits: [UInt8](data.dropFirst(16)))
    }

    /// The surface at geodetic `latitude` and `longitude` (radians).
    public func kind(latitude: Double, longitude: Double) -> SurfaceKind {
        let deg = 180 / Double.pi
        let row = min(rows - 1, max(0, Int(((latitude * deg + 90) / 180 * Double(rows)).rounded(.down))))
        var lon = (longitude * deg + 180).truncatingRemainder(dividingBy: 360)
        if lon < 0 { lon += 360 }
        let column = min(columns - 1, Int((lon / 360 * Double(columns)).rounded(.down)))
        let k = row * columns + column
        return bits[k / 8] >> (k % 8) & 1 == 1 ? .land : .water
    }
}
