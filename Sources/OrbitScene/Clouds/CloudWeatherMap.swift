import Foundation
import OrbitCore

// Track C2: C1's weather (CloudWeather) as the global map the cloud march
// samples, assembled on the GPU at ERA5's 0.25° grid points from the two
// snapshots around the time, the weather elsewhere (the procedural weather's
// nodes and row offsets, or the zonal climatology) and the pad's observed
// sky, then the low layer's heights. This file holds the parameters the
// assembly kernel gets and its mirror in Swift (`texel`), which the tests
// check against `CloudWeather.sample` and the render tests check the GPU
// against.

/// The assembled weather map and what makes it.
public enum CloudWeatherMap {
    /// ERA5's grid (C1's OSCLOUD1 planes): row r at latitude 90° − 180° r/720,
    /// column c at 360° c/1440 east.
    public static let columns = 1440
    public static let rows = 721

    public static func latitude(row r: Int) -> Double { (90 - 180 * Double(r) / Double(rows - 1)) * .pi / 180 }
    public static func longitude(column c: Int) -> Double { 2 * .pi * Double(c) / Double(columns) }

    /// One override as the kernel gets it.
    public struct Override: Equatable {
        public var latitude: Double
        public var longitude: Double
        public var radius: Double
        /// The override's weight in time at this epoch (its space weight is
        /// the kernel's).
        public var timeWeight: Double
        public var observation: CloudObservation
    }

    /// What the assembly kernel gets each frame.
    public struct Parameters: Equatable {
        /// The snapshots around the time and the second's weight; nil when
        /// there is no field.
        public var snapshots: (first: Int, second: Int, weight: Double)?
        /// The field's weight against the climatology: 1 within its span,
        /// falling to 0 over `CloudWeather.fade` beyond it.
        public var fieldWeight: Double
        /// The climatology's low, mid and high cover at each row.
        public var climatology: [(low: Double, mid: Double, high: Double)]
        public var overrides: [Override]
        /// The procedural weather, when it is the weather elsewhere and shows
        /// (the field's weight below 1); nil for the climatology.
        public var procedural: ProceduralWeather?

        public static func == (a: Parameters, b: Parameters) -> Bool {
            a.snapshots?.first == b.snapshots?.first && a.snapshots?.second == b.snapshots?.second
                && a.snapshots?.weight == b.snapshots?.weight && a.fieldWeight == b.fieldWeight
                && a.overrides == b.overrides && a.procedural == b.procedural && a.climatology.count == b.climatology.count
                && zip(a.climatology, b.climatology).allSatisfy { $0 == $1 }
        }
    }

    /// The parameters for `weather` at `epoch`, as CloudWeather.sample
    /// weighs its parts.
    public static func parameters(_ weather: CloudWeather, at epoch: Epoch) -> Parameters {
        let year = CloudClimatology.yearFraction(epoch)
        let climate = (0..<rows).map { r -> (low: Double, mid: Double, high: Double) in
            CloudClimatology.cover(latitude: latitude(row: r), yearFraction: year)
        }
        var snapshots: (Int, Int, Double)?
        var fieldWeight = 0.0
        if let field = weather.field, let first = field.times.first, let last = field.times.last {
            let edge = epoch < first ? first : (epoch > last ? last : epoch)
            if let b = field.bracket(edge) {
                snapshots = b
                let away = abs(epoch - edge)
                fieldWeight = away == 0 ? 1 : (away >= weather.fade ? 0 : 1 - away / weather.fade)
            }
        }
        let overrides = weather.overrides.map { o in
            Override(latitude: o.latitude, longitude: o.longitude, radius: o.radius,
                     timeWeight: 1 - CloudOverride.smoothstep(o.hold, o.hold + o.fade, abs(epoch - o.time)),
                     observation: o.observation)
        }
        return Parameters(snapshots: snapshots, fieldWeight: fieldWeight, climatology: climate, overrides: overrides,
                          procedural: fieldWeight < 1 ? weather.procedural : nil)
    }

    /// The procedural weather's inputs at one time, as the GPU gets them:
    /// the state (noise phases, systems), and each of its rows' band (with
    /// the row's climatology for the calibration).
    public struct ProceduralFrame {
        public var state: ProceduralWeather.State
        public var bands: [ProceduralWeather.Band]
        public var climatology: [(low: Double, mid: Double, high: Double)]
    }

    public static func proceduralFrame(_ w: ProceduralWeather, at epoch: Epoch,
                                       geography: WeatherGeography = .earth) -> ProceduralFrame {
        let state = w.state(at: epoch, geography: geography)
        let lats = (0..<ProceduralWeather.rows).map { ProceduralWeather.latitude(row: $0) }
        return ProceduralFrame(state: state, bands: lats.map { ProceduralWeather.band(latitude: $0, sky: state.sky) },
                               climatology: lats.map {
                                   CloudClimatology.cover(latitude: $0, yearFraction: state.sky.yearFraction)
                               })
    }

    /// The procedural nodes and rows a texel is assembled from: each node
    /// (row j, column c of ProceduralWeather's grid) and each row's offsets
    /// before smoothing (`ProceduralWeather.smoothed`).
    public struct ProceduralNodes {
        public var node: (Int, Int) -> ProceduralWeather.Node
        public var offsets: [(low: Double, mid: Double, high: Double)]

        public init(node: @escaping (Int, Int) -> ProceduralWeather.Node, offsets: [(low: Double, mid: Double, high: Double)]) {
            self.node = node
            self.offsets = offsets
        }

        /// Grid point (c, r) of the map: bilinear between the procedural
        /// nodes (every other grid point is one), the covers from the
        /// latent values with the rows' smoothed offsets.
        public func at(column c: Int, row r: Int) -> (low: Double, mid: Double, high: Double, base: Double, top: Double,
                                                      cumuliform: Double) {
            let j0 = r / 2, c0 = c / 2
            let j1 = min(j0 + 1, ProceduralWeather.rows - 1), c1 = (c0 + 1) % ProceduralWeather.columns
            let fy = r % 2 == 1 ? 0.5 : 0, fx = c % 2 == 1 ? 0.5 : 0
            let n00 = node(j0, c0), n01 = node(j0, c1), n10 = node(j1, c0), n11 = node(j1, c1)
            func mix(_ k: KeyPath<ProceduralWeather.Node, Double>) -> Double {
                let a = n00[keyPath: k] + fx * (n01[keyPath: k] - n00[keyPath: k])
                let b = n10[keyPath: k] + fx * (n11[keyPath: k] - n10[keyPath: k])
                return a + fy * (b - a)
            }
            func offset(_ k: KeyPath<(low: Double, mid: Double, high: Double), Double>) -> Double {
                let column = offsets.map { $0[keyPath: k] }
                let a = ProceduralWeather.smoothed(column, row: j0), b = ProceduralWeather.smoothed(column, row: j1)
                return a + fy * (b - a)
            }
            let g = ProceduralWeather.gains
            return (ProceduralWeather.cover(mix(\.low) + offset(\.low), gain: g.low),
                    ProceduralWeather.cover(mix(\.mid) + offset(\.mid), gain: g.mid),
                    ProceduralWeather.cover(mix(\.high) + offset(\.high), gain: g.high), mix(\.base), mix(\.top), mix(\.cumuliform))
        }
    }

    /// One assembled texel: the three covers, the low layer's base and top
    /// (m above the surface), and how cumuliform it is (0.5 unknown).
    public struct Texel: Equatable {
        public var low: Double
        public var mid: Double
        public var high: Double
        public var lowBase: Double
        public var lowTop: Double
        public var cumuliform = 0.5
    }

    /// The four bytes of grid point (c, r) of a snapshot, in the order the
    /// GPU's rgba8 snapshot texture holds them: lcc, mcc, hcc, cbh.
    public static let snapshotPlanes = ["lcc", "mcc", "hcc", "cbh"]

    /// A snapshot's planes interleaved for its texture, rows from the north.
    public static func interleaved(_ field: CloudField, snapshot: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: 4 * columns * rows)
        for (k, name) in snapshotPlanes.enumerated() {
            guard let p = field.plane(name), field.planes[p].columns == columns, field.planes[p].rows == rows else {
                continue
            }
            let bytes = field.bytes(plane: p, snapshot: snapshot)
            var i = bytes.startIndex
            for j in 0..<(columns * rows) {
                out[4 * j + k] = bytes[i]
                i += 1
            }
        }
        return out
    }

    /// The kernel's arithmetic for grid point (c, r), from the snapshots'
    /// interleaved bytes (`first`, `second`): C1's semantics (time-linear
    /// values, a value one snapshot lacks taken from the other), the field
    /// mixed beyond its span into the weather elsewhere (the procedural
    /// weather's nodes, or the climatology), then each override; then the
    /// low layer's heights: the procedural weather's, mixed with the field's
    /// base (and the layer model's depth) by the field's weight, or without
    /// it the field's base while its weight is over a half.
    public static func texel(column c: Int, row r: Int, first: [UInt8]?, second: [UInt8]?,
                             parameters p: Parameters, procedural: ProceduralNodes? = nil,
                             scales: [Double] = [1 / 254, 1 / 254, 1 / 254, 60]) -> Texel {
        let climate = p.climatology[r]
        var low = climate.low, mid = climate.mid, high = climate.high
        let proc = p.procedural != nil ? procedural?.at(column: c, row: r) : nil
        if let proc {
            low = proc.low
            mid = proc.mid
            high = proc.high
        }
        // The weather elsewhere's weight, and the field's base.
        var x = 1.0
        var fieldBase: Double?
        if let s = p.snapshots, let first, let second {
            let at = 4 * (r * columns + c)
            func value(_ k: Int) -> Double? {
                let a = first[at + k], b = second[at + k]
                let va: Double? = a == 255 ? nil : Double(a) * scales[k]
                let vb: Double? = b == 255 ? nil : Double(b) * scales[k]
                if let va, let vb { return s.weight > 0 && s.first != s.second ? va + s.weight * (vb - va) : va }
                return s.weight < 0.5 ? va : vb
            }
            if let l = value(0), let m = value(1), let h = value(2) {
                let f = p.fieldWeight
                x = 1 - f
                func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
                low = clamp(l) + x * (low - clamp(l))
                mid = clamp(m) + x * (mid - clamp(m))
                high = clamp(h) + x * (high - clamp(h))
                fieldBase = value(3)
            }
        }
        var convective = false
        let lat = latitude(row: r), lon = longitude(column: c)
        for o in p.overrides {
            let d = CloudOverride.distance(lat, lon, o.latitude, o.longitude)
            let w = (1 - CloudOverride.smoothstep(o.radius / 2, o.radius, d)) * o.timeWeight
            guard w > 0 else { continue }
            low += w * (o.observation.low - low)
            mid += w * (o.observation.mid - mid)
            high += w * (o.observation.high - high)
            if w >= 0.5 { convective = o.observation.convective }
        }
        var lowBase = CloudLayerModel.defaultLowBase, lowTop: Double, cumuliform = 0.5
        if let proc {
            if let b = fieldBase, b < CloudLayerModel.midBase { lowBase = max(b, 0) }
            let fieldTop = lowBase + CloudLayerModel.lowDepth
            lowTop = fieldTop + x * (proc.top - fieldTop)
            lowBase += x * (proc.base - lowBase)
            cumuliform += x * (proc.cumuliform - cumuliform)
        } else {
            if x < 0.5, let b = fieldBase, b < CloudLayerModel.midBase { lowBase = max(b, 0) }
            lowTop = lowBase + CloudLayerModel.lowDepth
        }
        if convective { lowTop = CloudLayerModel.cumulonimbusTop }
        return Texel(low: low, mid: mid, high: high, lowBase: lowBase, lowTop: lowTop, cumuliform: cumuliform)
    }

    /// The mission whose weather covers `epoch`: the launch nearest it within
    /// `window` (s, 16 days, longer than any of the flights), nil for none.
    public static func mission(at epoch: Epoch, window: Double = 16 * 86_400) -> String? {
        CloudOverride.launches.filter { epoch - $0.value.time >= -86_400 && epoch - $0.value.time <= window }
            .min { abs(epoch - $0.value.time) < abs(epoch - $1.value.time) }?.key
    }
}
