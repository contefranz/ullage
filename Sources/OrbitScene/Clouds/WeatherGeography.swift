import Foundation
import OrbitCore

/// What the procedural weather (`ProceduralWeather`) knows of the Earth's
/// surface, on its own grid (720 × 361 nodes: row j at latitude 90° − 0.5° j,
/// column c at 0.5° c east), made once from OrbitCore's land mask
/// (`landmask.bin`, Natural Earth's 1:10m land, `tools/make_landmask.py`).
/// Two planes of four bytes a node, which the GPU uploads as two rgba8Unorm
/// textures and the Swift mirror reads as the same bytes:
///
/// - `a`: land (the node's four mask cells, smoothed over about 100 km); the
///   continents (land smoothed over about 500 km: the monsoon's reach); how
///   far inland (the distance to the sea, 0 at the coast, 1 at 1,500 km or
///   more); the ice sheets (the land south of 60° S and Greenland's, smoothed as
///   the land is).
/// - `b`, along the node's parallel: over the sea, a continent close to the
///   east (e^(−d / 2,500 km): an ocean's eastern boundary, where the trades
///   drive the cold upwelling currents under the stratocumulus decks) and to
///   the west (e^(−d / 800 km): the warm western boundary currents); over
///   land, the sea close to the east (e^(−d / 600 km): the humid east coasts)
///   and to the west (e^(−d / 500 km): the dry west coasts of the
///   subtropics). A continent is land of at least `continentArea` in one
///   piece: an island has no boundary currents (no deck in Hawaii's lee).
public struct WeatherGeography: Equatable {
    public static let columns = 720
    public static let rows = 361

    /// Plane a, node by node from the north, four bytes each.
    public let a: [UInt8]
    /// Plane b.
    public let b: [UInt8]

    /// One node's values, 0...1.
    public struct Texel: Equatable {
        public var land = 0.0
        public var continental = 0.0
        public var inland = 0.0
        /// Antarctica's and Greenland's ice.
        public var iceSheet = 0.0
        /// Over the sea: a continent to the east, to the west.
        public var seaEastLand = 0.0
        public var seaWestLand = 0.0
        /// Over land: sea to the east, to the west.
        public var landEastSea = 0.0
        public var landWestSea = 0.0

        public init() {}
    }

    /// The Earth's, made from `SurfaceMask.earth`; all sea without it.
    public static let earth: WeatherGeography = WeatherGeography(mask: SurfaceMask.earth)

    public init(a: [UInt8], b: [UInt8]) {
        self.a = a
        self.b = b
    }

    /// Node (row j, column c).
    public func texel(row j: Int, column c: Int) -> Texel {
        let k = 4 * (j * Self.columns + c)
        var t = Texel()
        t.land = Double(a[k]) / 255
        t.continental = Double(a[k + 1]) / 255
        t.inland = Double(a[k + 2]) / 255
        t.iceSheet = Double(a[k + 3]) / 255
        t.seaEastLand = Double(b[k]) / 255
        t.seaWestLand = Double(b[k + 1]) / 255
        t.landEastSea = Double(b[k + 2]) / 255
        t.landWestSea = Double(b[k + 3]) / 255
        return t
    }

    /// Bilinear between the nodes around a latitude and longitude (rad).
    public func texel(latitude: Double, longitude: Double) -> Texel {
        let y = min(max((90 - latitude * 180 / .pi) * 2, 0), Double(Self.rows - 1))
        var x = longitude * 180 / .pi * 2
        x -= (x / Double(Self.columns)).rounded(.down) * Double(Self.columns)
        let j0 = min(Int(y), Self.rows - 2), fy = y - Double(j0)
        let c0 = Int(x) % Self.columns, c1 = (c0 + 1) % Self.columns, fx = x - x.rounded(.down)
        let t00 = texel(row: j0, column: c0), t01 = texel(row: j0, column: c1)
        let t10 = texel(row: j0 + 1, column: c0), t11 = texel(row: j0 + 1, column: c1)
        func mix(_ k: KeyPath<Texel, Double>) -> Double {
            let top = t00[keyPath: k] + fx * (t01[keyPath: k] - t00[keyPath: k])
            let bottom = t10[keyPath: k] + fx * (t11[keyPath: k] - t10[keyPath: k])
            return top + fy * (bottom - top)
        }
        var t = Texel()
        t.land = mix(\.land)
        t.continental = mix(\.continental)
        t.inland = mix(\.inland)
        t.iceSheet = mix(\.iceSheet)
        t.seaEastLand = mix(\.seaEastLand)
        t.seaWestLand = mix(\.seaWestLand)
        t.landEastSea = mix(\.landEastSea)
        t.landWestSea = mix(\.landWestSea)
        return t
    }

    // MARK: Making it

    /// From a land mask (0.25° cells); all sea for nil.
    public init(mask: SurfaceMask?) {
        let n = Self.columns * Self.rows
        let fine = Self.landFraction(mask)
        let land = Self.blur(fine, radius: 2, latitudeScaled: false)
        let continental = Self.blur(fine, radius: 9, passes: 3, latitudeScaled: true)
        let inland = Self.distanceToSea(fine)
        let pieces = Self.pieces(fine)
        let continent = pieces.area.map { $0 >= Self.continentArea }
        // The ice sheets: every piece with land south of 60° S (Antarctica,
        // and the ice-covered islands in its shelves, which Natural Earth's
        // land leaves as sea: Berkner, Alexander, Roosevelt, Siple, Ross),
        // and the piece under Greenland's summit (72.5° N, 38.5° W).
        let south = (Self.rows - 60)...(Self.rows - 1)
        var sheets: Set<Int> = [pieces.label[35 * Self.columns + 643]]
        for j in south {
            for c in 0..<Self.columns where pieces.label[j * Self.columns + c] >= 0 {
                sheets.insert(pieces.label[j * Self.columns + c])
            }
        }
        sheets.remove(-1)
        let ice = Self.blur(pieces.label.map { sheets.contains($0) ? 1 : 0 }, radius: 2, latitudeScaled: false)
        var along = [[Double]](repeating: [Double](repeating: 0, count: n), count: 4)
        let earth = 6_371.0, step = 0.5 * .pi / 180
        let m = Self.columns
        for j in 0..<Self.rows {
            let km = max(earth * cos(Self.latitude(row: j)) * step, 1)
            // Each node's kind: 0 sea, 1 an island's land, 2 a continent's.
            let kinds = (0..<m).map { c -> Int in
                let l = pieces.label[j * m + c]
                return l < 0 ? 0 : (continent[l] ? 2 : 1)
            }
            // The nearest node of each kind east and west along the parallel
            // (nodes away, within the whole circle; nil for none), from two
            // sweeps over the row twice over.
            var eastOf = [[Int?]](repeating: [Int?](repeating: nil, count: m), count: 3)
            var westOf = eastOf
            var next: [Int?] = [nil, nil, nil]
            for i in stride(from: 2 * m - 1, through: 0, by: -1) {
                if i < m { for k in 0..<3 { eastOf[k][i] = next[k].map { $0 - i } } }
                next[kinds[i % m]] = i
            }
            var last: [Int?] = [nil, nil, nil]
            for i in 0..<(2 * m) {
                if i >= m { for k in 0..<3 { westOf[k][i - m] = last[k].map { i - $0 } } }
                last[kinds[i % m]] = i
            }
            for c in 0..<m {
                // Land looks for the sea, the sea for a continent.
                let isLand = kinds[c] > 0, other = isLand ? 0 : 2
                let east = eastOf[other][c].map { Double($0) * km } ?? .infinity
                let west = westOf[other][c].map { Double($0) * km } ?? .infinity
                let k = j * m + c
                if isLand {
                    along[2][k] = exp(-east / 600)
                    along[3][k] = exp(-west / 500)
                } else {
                    along[0][k] = exp(-east / 2_500)
                    along[1][k] = exp(-west / 800)
                }
            }
        }
        along = along.map { Self.blur($0, radius: 2, latitudeScaled: false) }
        // A pole's row is one place: its mean.
        let planes = [land, continental, inland, ice] + along
        let poled = planes.map { v -> [Double] in
            var v = v
            for j in [0, Self.rows - 1] {
                let row = (j * m)..<(j * m + m)
                let mean = v[row].reduce(0, +) / Double(m)
                for k in row { v[k] = mean }
            }
            return v
        }
        func byte(_ v: Double) -> UInt8 { UInt8(min(max(v, 0), 1) * 255 + 0.5) }
        var a = [UInt8](repeating: 0, count: 4 * n), b = [UInt8](repeating: 0, count: 4 * n)
        for k in 0..<n {
            for i in 0..<4 {
                a[4 * k + i] = byte(poled[i][k])
                b[4 * k + i] = byte(poled[4 + i][k])
            }
        }
        self.init(a: a, b: b)
    }

    static func latitude(row j: Int) -> Double { (90 - 0.5 * Double(j)) * .pi / 180 }

    /// The least area of a continent, km²: Greenland (2.2 million km²) and
    /// the six continents are; New Guinea (0.79), Borneo (0.74) and
    /// Madagascar (0.59) are not.
    public static let continentArea = 1.5e6

    /// The land's pieces: each land node's (`fine` at least one half) piece,
    /// −1 for the sea, land nodes side by side being one piece (the parallels
    /// wrapping). Not corner to corner, which would join Greenland through
    /// the Arctic Archipelago to North America (42 million km²); side by side
    /// it takes in Ellesmere and Axel Heiberg across the Nares Strait, which
    /// are ice-capped too. Each piece's area, km².
    static func pieces(_ fine: [Double]) -> (label: [Int], area: [Double]) {
        var label = [Int](repeating: -1, count: columns * rows)
        var area: [Double] = []
        let side = 6_371.0 * 0.5 * Double.pi / 180, cell = side * side
        // A pole's node: a quarter of a row's spacing in latitude.
        let polar = 0.25 * 0.5 * Double.pi / 180
        for start in 0..<label.count where fine[start] >= 0.5 && label[start] < 0 {
            let id = area.count
            var sum = 0.0
            var stack = [start]
            label[start] = id
            while let k = stack.popLast() {
                let j = k / columns, c = k % columns
                let width: Double = max(cos(latitude(row: j)), polar)
                sum += cell * width
                for dj in -1...1 {
                    let jj = j + dj
                    guard jj >= 0, jj < rows else { continue }
                    for dc in -1...1 where (dc == 0) != (dj == 0) {
                        let kk = jj * columns + (c + dc + columns) % columns
                        if fine[kk] >= 0.5 && label[kk] < 0 {
                            label[kk] = id
                            stack.append(kk)
                        }
                    }
                }
            }
            area.append(sum)
        }
        return (label, area)
    }

    /// Each node's land fraction: the four 0.25° mask cells it is a corner of.
    static func landFraction(_ mask: SurfaceMask?) -> [Double] {
        var out = [Double](repeating: 0, count: columns * rows)
        guard let mask else { return out }
        for j in 0..<rows {
            let lat = 90 - 0.5 * Double(j)
            for c in 0..<columns {
                let lon = 0.5 * Double(c)
                var sum = 0.0
                for dy in [-0.125, 0.125] {
                    for dx in [-0.125, 0.125] {
                        let la = min(max(lat + dy, -89.99), 89.99)
                        if mask.kind(latitude: la * .pi / 180, longitude: (lon + dx) * .pi / 180) == .land { sum += 0.25 }
                    }
                }
                out[j * columns + c] = sum
            }
        }
        return out
    }

    /// A box blur over ±`radius` nodes, `passes` times (near Gaussian), along
    /// the parallels (wrapping; widened by 1 / cos latitude when
    /// `latitudeScaled`, up to a quarter of the circle) and the meridians.
    static func blur(_ v: [Double], radius: Int, passes: Int = 1, latitudeScaled: Bool) -> [Double] {
        var cur = v
        for _ in 0..<passes {
            var next = cur
            for j in 0..<rows {
                let scale = latitudeScaled ? 1 / max(cos(latitude(row: j)), 0.05) : 1
                let r = min(Int((Double(radius) * scale).rounded()), columns / 4)
                var sum = 0.0
                for d in -r...r { sum += cur[j * columns + (d + columns) % columns] }
                let n = Double(2 * r + 1)
                for c in 0..<columns {
                    next[j * columns + c] = sum / n
                    sum += cur[j * columns + (c + r + 1) % columns] - cur[j * columns + (c - r + columns) % columns]
                }
            }
            cur = next
            for c in 0..<columns {
                for j in 0..<rows {
                    var sum = 0.0, n = 0.0
                    for d in -radius...radius {
                        let jj = j + d
                        guard jj >= 0, jj < rows else { continue }
                        sum += next[jj * columns + c]
                        n += 1
                    }
                    cur[j * columns + c] = sum / n
                }
            }
        }
        return cur
    }

    /// Over land, the distance to the nearest sea node (two chamfer passes
    /// on the sphere's grid), as a fraction of 1,500 km; 0 over the sea.
    static func distanceToSea(_ fine: [Double]) -> [Double] {
        let big = 1e9
        var d = fine.map { $0 >= 0.5 ? big : 0 }
        let ns = 6_371.0 * 0.5 * .pi / 180
        func ew(_ j: Int) -> Double { max(ns * cos(latitude(row: j)), 1) }
        func at(_ j: Int, _ c: Int) -> Int { j * columns + (c + columns) % columns }
        for _ in 0..<2 {
            for j in 0..<rows {
                let e = ew(j), diag = (e * e + ns * ns).squareRoot()
                for c in 0..<columns {
                    var v = d[at(j, c)]
                    guard v > 0 else { continue }
                    v = min(v, d[at(j, c - 1)] + e)
                    if j > 0 {
                        v = min(v, d[at(j - 1, c)] + ns, d[at(j - 1, c - 1)] + diag, d[at(j - 1, c + 1)] + diag)
                    }
                    d[at(j, c)] = v
                }
            }
            for j in stride(from: rows - 1, through: 0, by: -1) {
                let e = ew(j), diag = (e * e + ns * ns).squareRoot()
                for c in stride(from: columns - 1, through: 0, by: -1) {
                    var v = d[at(j, c)]
                    guard v > 0 else { continue }
                    v = min(v, d[at(j, c + 1)] + e)
                    if j < rows - 1 {
                        v = min(v, d[at(j + 1, c)] + ns, d[at(j + 1, c - 1)] + diag, d[at(j + 1, c + 1)] + diag)
                    }
                    d[at(j, c)] = v
                }
            }
        }
        return d.map { min($0 / 1_500, 1) }
    }
}
