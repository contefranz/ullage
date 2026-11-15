import Foundation

/// A polygon on the globe as GeoJSON gives it: rings of (longitude,
/// latitude) in degrees, the first the outer boundary and the rest holes.
public struct GeoPolygon: Equatable {
    public var rings: [[GeoPoint]]
    /// The feature's properties that came with it (strings only).
    public var properties: [String: String]

    public init(rings: [[GeoPoint]], properties: [String: String] = [:]) {
        self.rings = rings
        self.properties = properties
    }

    public var bounds: (west: Double, south: Double, east: Double, north: Double) {
        var w = Double.infinity, s = Double.infinity, e = -Double.infinity, n = -Double.infinity
        for ring in rings {
            for p in ring {
                w = min(w, p.longitude); e = max(e, p.longitude)
                s = min(s, p.latitude); n = max(n, p.latitude)
            }
        }
        return (w, s, e, n)
    }
}

public struct GeoPoint: Equatable {
    public var longitude: Double
    public var latitude: Double

    public init(longitude: Double, latitude: Double) {
        self.longitude = longitude
        self.latitude = latitude
    }
}

public enum GeoJSON {
    public enum Failure: Error { case notAFeatureCollection, badGeometry(String) }

    /// The polygons of a FeatureCollection (Polygon and MultiPolygon
    /// geometries; others are skipped) whose string properties pass
    /// `include`.
    public static func polygons(_ data: Data, include: ([String: String]) -> Bool = { _ in true }) throws -> [GeoPolygon] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { throw Failure.notAFeatureCollection }
        var out: [GeoPolygon] = []
        for f in features {
            var props: [String: String] = [:]
            for (k, v) in f["properties"] as? [String: Any] ?? [:] {
                if let s = v as? String { props[k] = s } else if let n = number(v) { props[k] = n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n) }
            }
            guard include(props), let g = f["geometry"] as? [String: Any], let type = g["type"] as? String else { continue }
            let coords = g["coordinates"]
            switch type {
            case "Polygon":
                out.append(GeoPolygon(rings: try rings(coords), properties: props))
            case "MultiPolygon":
                guard let polys = coords as? [Any] else { throw Failure.badGeometry("MultiPolygon") }
                for p in polys { out.append(GeoPolygon(rings: try rings(p), properties: props)) }
            default:
                continue
            }
        }
        return out
    }

    /// A JSON number, however Foundation hands it over (NSNumber on
    /// Darwin, Swift numbers on Linux).
    static func number(_ x: Any) -> Double? {
        if let d = x as? Double { return d }
        if let i = x as? Int { return Double(i) }
        if let n = x as? NSNumber { return n.doubleValue }
        return nil
    }

    static func rings(_ any: Any?) throws -> [[GeoPoint]] {
        guard let rings = any as? [[Any]] else { throw Failure.badGeometry("rings") }
        return try rings.map { ring in
            try ring.map { p in
                guard let c = p as? [Any], c.count >= 2, let lon = number(c[0]), let lat = number(c[1]) else {
                    throw Failure.badGeometry("position")
                }
                return GeoPoint(longitude: lon, latitude: lat)
            }
        }
    }
}

/// Fills polygons on a `GeoGrid` with antialiased coverage, by the even-odd
/// rule over all their rings together: holes are outside, an island in a
/// hole inside again. Polygons that do not overlap (Natural Earth's land, or
/// its lakes) are therefore filled as their union. Coverage is exact along
/// each scanline and taken on `subRows` scanlines per pixel row.
public enum PolygonRasterizer {
    struct Edge {
        var x0: Double, y0: Double, x1: Double, y1: Double
    }

    /// Calls `row(r, coverage)` for every pixel row the polygons reach, with
    /// each column's coverage in 0...1 (a row of `grid.width`), possibly
    /// from several threads at once (different rows). Longitudes are taken
    /// as given: rings must not cross the grid's west or east edge (Natural
    /// Earth's are cut at ±180°).
    public static func rasterize(_ polygons: [GeoPolygon], on grid: GeoGrid, subRows: Int = 4,
                                 row: (Int, [Float]) -> Void) {
        let w = grid.width, h = grid.height
        // Edges in pixel units, the y axis down.
        var edges: [Edge] = []
        for p in polygons {
            for ring in p.rings where ring.count >= 3 {
                for k in 0 ..< ring.count {
                    let a = ring[k], b = ring[(k + 1) % ring.count]
                    let pa = grid.position(latitudeDegrees: a.latitude, longitudeDegrees: a.longitude)
                    let pb = grid.position(latitudeDegrees: b.latitude, longitudeDegrees: b.longitude)
                    if pa.y == pb.y { continue }
                    edges.append(Edge(x0: pa.x, y0: pa.y, x1: pb.x, y1: pb.y))
                }
            }
        }
        guard !edges.isEmpty else { return }
        // Bands of rows, each with the edges that reach it.
        let bandRows = 32
        let bands = (h + bandRows - 1) / bandRows
        var byBand = [[Int]](repeating: [], count: bands)
        for (i, e) in edges.enumerated() {
            let top = max(0, Int(min(e.y0, e.y1).rounded(.down)) / bandRows)
            let bottom = min(bands - 1, Int(max(e.y0, e.y1).rounded(.down)) / bandRows)
            guard top <= bottom, max(e.y0, e.y1) >= 0, min(e.y0, e.y1) < Double(h) else { continue }
            for b in top ... bottom { byBand[b].append(i) }
        }
        let step = 1 / Double(subRows), weight = Float(step)
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let mine = byBand[band]
            guard !mine.isEmpty else { return }
            var crossings: [Double] = []
            var cover = [Float](repeating: 0, count: w)
            for r in band * bandRows ..< min(h, (band + 1) * bandRows) {
                var touched = false
                for s in 0 ..< subRows {
                    let y = Double(r) + (Double(s) + 0.5) * step
                    crossings.removeAll(keepingCapacity: true)
                    for i in mine {
                        let e = edges[i]
                        let lo = min(e.y0, e.y1), hi = max(e.y0, e.y1)
                        guard y >= lo && y < hi else { continue }
                        crossings.append(e.x0 + (y - e.y0) / (e.y1 - e.y0) * (e.x1 - e.x0))
                    }
                    guard crossings.count >= 2 else { continue }
                    crossings.sort()
                    var k = 0
                    while k + 1 < crossings.count {
                        let xa = max(0, min(Double(w), crossings[k])), xb = max(0, min(Double(w), crossings[k + 1]))
                        k += 2
                        guard xb > xa else { continue }
                        touched = true
                        let ca = Int(xa), cb = min(Int(xb), w - 1)
                        if ca == cb {
                            cover[ca] += Float(xb - xa) * weight
                        } else {
                            cover[ca] += Float(Double(ca + 1) - xa) * weight
                            if cb > ca + 1 { for c in ca + 1 ..< cb { cover[c] += weight } }
                            if cb < w { cover[cb] += Float(xb - Double(cb)) * weight }
                        }
                    }
                }
                if touched {
                    for c in 0 ..< w { cover[c] = min(1, cover[c]) }
                    row(r, cover)
                    for c in 0 ..< w { cover[c] = 0 }
                }
            }
        }
    }

    /// The polygons' coverage as an 8-bit raster on `grid` (255 inside),
    /// read as fractions (scale 1/255).
    public static func coverage(_ polygons: [GeoPolygon], on grid: GeoGrid, subRows: Int = 4,
                                storage: RasterStorage? = nil) -> GeoRaster {
        let out = GeoRaster(grid: grid, channels: 1, type: .uint8, storage: storage)
        out.scale = 1 / 255
        let base = out.storage.bytes
        rasterize(polygons, on: grid, subRows: subRows) { r, cover in
            let p = base + r * grid.width
            for c in 0 ..< grid.width where cover[c] > 0 {
                p.storeBytes(of: UInt8(min(255, (cover[c] * 255).rounded())), toByteOffset: c, as: UInt8.self)
            }
        }
        return out
    }
}
