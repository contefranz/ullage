import Foundation
import OrbitCore

/// One texel of a bordered tile, located on the body: its figure direction
/// and the geodetic latitude and longitude there, with its footprint.
public struct TileTexel {
    /// Column i (along u) and row j (along v), counted from the border's outer edge.
    public var column: Int
    public var row: Int
    /// Unit figure direction of its centre.
    public var direction: Vec3
    /// Geodetic latitude and longitude of its centre, rad.
    public var latitude: Double
    public var longitude: Double
    /// The span of its corners in latitude and longitude, rad.
    public var dLatitude: Double
    public var dLongitude: Double

    public init(column: Int, row: Int, direction: Vec3, latitude: Double, longitude: Double, dLatitude: Double,
                dLongitude: Double) {
        self.column = column; self.row = row; self.direction = direction
        self.latitude = latitude; self.longitude = longitude; self.dLatitude = dLatitude; self.dLongitude = dLongitude
    }
}

/// A box of latitude and longitude, degrees (west may exceed east across
/// the antimeridian).
public struct GeoRegion: Equatable, Codable {
    public var south: Double, north: Double, west: Double, east: Double

    public init(south: Double, north: Double, west: Double, east: Double) {
        self.south = south; self.north = north; self.west = west; self.east = east
    }

    /// Whether the point (degrees) lies in the box.
    public func contains(latitude: Double, longitude: Double) -> Bool {
        guard latitude >= south && latitude <= north else { return false }
        func wrap(_ x: Double) -> Double { (x.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
        let width = east - west >= 360 ? 360 : wrap(east - west)
        return wrap(longitude - west) <= width
    }
}

/// Builds a layer's tiles from functions of position (M1.6 track E1): each
/// texel of a bordered tile, borders included, is sampled where it lies on
/// the body, through `Ellipsoid.geodeticCoordinates(figureDirection:)`, so
/// sources on a latitude-longitude grid fill the cube sphere directly.
/// Borders are sampled along the tile's own face's projection, past its
/// edges (`TileKey.direction(localU:localV:)`), as OSTILES1 asks: within a
/// face they repeat the neighbour's texels exactly, across a face edge they
/// are a resample of the same source.
public enum PlanetTileBuilder {
    /// Texel centre (i, j) in tile-local coordinates: ((i - b + ½)/n, (j - b + ½)/n).
    @inlinable public static func localCoordinate(_ i: Int, tileSize n: Int, border b: Int) -> Double {
        (Double(i - b) + 0.5) / Double(n)
    }

    /// The tile's (n + 2b)² texels, row by row (row j along u, rows going
    /// up in v), each with its footprint from its corners.
    public static func texels(of key: TileKey, tileSize n: Int, border b: Int, figure: Ellipsoid) -> [TileTexel] {
        let m = n + 2 * b
        // Geodetic coordinates of the texel corners, (m + 1)² of them.
        var cornerLat = [Double](repeating: 0, count: (m + 1) * (m + 1)), cornerLon = cornerLat
        for j in 0 ... m {
            let lv = Double(j - b) / Double(n)
            for i in 0 ... m {
                let lu = Double(i - b) / Double(n)
                let g = figure.geodeticCoordinates(figureDirection: key.direction(localU: lu, localV: lv))
                cornerLat[j * (m + 1) + i] = g.latitude
                cornerLon[j * (m + 1) + i] = g.longitude
            }
        }
        var out: [TileTexel] = []
        out.reserveCapacity(m * m)
        for j in 0 ..< m {
            let lv = localCoordinate(j, tileSize: n, border: b)
            for i in 0 ..< m {
                let lu = localCoordinate(i, tileSize: n, border: b)
                let d = key.direction(localU: lu, localV: lv)
                let g = figure.geodeticCoordinates(figureDirection: d)
                var la0 = Double.infinity, la1 = -Double.infinity, lo0 = Double.infinity, lo1 = -Double.infinity
                for (di, dj) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    let k = (j + dj) * (m + 1) + i + di
                    la0 = min(la0, cornerLat[k]); la1 = max(la1, cornerLat[k])
                    // Longitudes relative to the centre's, across the antimeridian too.
                    let dl = remainder(cornerLon[k] - g.longitude, 2 * Double.pi)
                    lo0 = min(lo0, dl); lo1 = max(lo1, dl)
                }
                out.append(TileTexel(column: i, row: j, direction: d, latitude: g.latitude, longitude: g.longitude,
                                     dLatitude: la1 - la0, dLongitude: lo1 - lo0))
            }
        }
        return out
    }

    /// The tile's samples: `channels` values per texel (at most 4), row by
    /// row with channels interleaved, from `sample` at each texel.
    public static func sample(_ key: TileKey, tileSize n: Int, border b: Int, figure: Ellipsoid, channels: Int,
                              _ sample: (TileTexel) -> SIMD4<Float>) -> [Float] {
        let texels = texels(of: key, tileSize: n, border: b, figure: figure)
        var out = [Float](repeating: 0, count: texels.count * channels)
        for (k, t) in texels.enumerated() {
            let v = sample(t)
            for c in 0 ..< channels { out[k * channels + c] = v[c] }
        }
        return out
    }

    /// The pyramid's tiles at `levels`, by ascending id; with a `region`,
    /// only those that touch it.
    public static func keys(levels: ClosedRange<Int>, region: GeoRegion? = nil, figure: Ellipsoid) -> [TileKey] {
        var out: [TileKey] = []
        for face in CubeSphere.Face.allCases {
            var frontier = [TileKey.root(face)].filter { touches($0, region, figure) }
            for level in 0 ... levels.upperBound {
                if levels.contains(level) { out.append(contentsOf: frontier) }
                guard level < levels.upperBound else { break }
                frontier = frontier.flatMap(\.children).filter { touches($0, region, figure) }
            }
        }
        return out.sorted()
    }

    /// Whether `key` may touch `region`: a 9 × 9 grid of its points, or
    /// the region's centre and corners inside the tile.
    static func touches(_ key: TileKey, _ region: GeoRegion?, _ figure: Ellipsoid) -> Bool {
        guard let region else { return true }
        for j in 0 ... 8 {
            for i in 0 ... 8 {
                let g = figure.geodeticCoordinates(figureDirection: key.direction(localU: Double(i) / 8,
                                                                                   localV: Double(j) / 8))
                if region.contains(latitude: g.latitude * 180 / .pi, longitude: g.longitude * 180 / .pi) { return true }
            }
        }
        let east = region.east < region.west ? region.east + 360 : region.east
        for (la, lo) in [((region.south + region.north) / 2, (region.west + east) / 2), (region.south, region.west),
                         (region.south, east), (region.north, region.west), (region.north, east)] {
            let d = figure.figureDirection(latitude: la * .pi / 180, longitude: lo * .pi / 180)
            if key.level == 0 ? CubeSphere.faceCoordinates(d).face == key.face
                : TileKey.containing(d, level: key.level) == key { return true }
        }
        return false
    }

    /// Makes the tiles of `keys` in parallel, `batch` at a time, and hands
    /// each to `write` in the order given, on the calling thread. `make`
    /// returning nil skips a tile.
    public static func build<T>(_ keys: [TileKey], batch: Int = 64, make: (TileKey) throws -> T?,
                                write: (TileKey, T) throws -> Void) throws {
        var start = 0
        while start < keys.count {
            let chunk = Array(keys[start ..< min(keys.count, start + batch)])
            var results = [Result<T?, Error>](repeating: .success(nil), count: chunk.count)
            results.withUnsafeMutableBufferPointer { slots in
                let base = slots.baseAddress!
                DispatchQueue.concurrentPerform(iterations: chunk.count) { k in
                    base[k] = Result { try make(chunk[k]) }
                }
            }
            for (k, r) in results.enumerated() {
                if let t = try r.get() { try write(chunk[k], t) }
            }
            start += batch
        }
    }

    /// 8-bit samples of fractions 0...1 (rounded, clamped; NaN reads 0).
    public static func bytes(_ values: [Float]) -> [UInt8] {
        values.map { v in v.isFinite ? UInt8(min(255, max(0, (v * 255).rounded()))) : 0 }
    }
}
