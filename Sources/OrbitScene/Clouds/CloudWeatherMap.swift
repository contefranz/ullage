import Foundation
import OrbitCore

// Track C2: C1's weather (CloudWeather) as the global map the cloud march
// samples, assembled on the GPU each frame at ERA5's 0.25° grid points from
// the two snapshots around the time, the zonal climatology and the pad's
// observed sky, then the layer model's heights (CloudLayerModel). This file
// holds the parameters the assembly kernel gets and its mirror in Swift
// (`texel`), which the tests check against `CloudWeather.sample` and the
// render tests check the GPU against.

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

        public static func == (a: Parameters, b: Parameters) -> Bool {
            a.snapshots?.first == b.snapshots?.first && a.snapshots?.second == b.snapshots?.second
                && a.snapshots?.weight == b.snapshots?.weight && a.fieldWeight == b.fieldWeight
                && a.overrides == b.overrides && a.climatology.count == b.climatology.count
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
        return Parameters(snapshots: snapshots, fieldWeight: fieldWeight, climatology: climate, overrides: overrides)
    }

    /// One assembled texel: the three covers, and the low layer's base and
    /// top (m above the surface) from the layer model.
    public struct Texel: Equatable {
        public var low: Double
        public var mid: Double
        public var high: Double
        public var lowBase: Double
        public var lowTop: Double
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
    /// values, a value one snapshot lacks taken from the other, the field
    /// mixed into the climatology beyond its span, then each override), then
    /// the layer model's heights.
    public static func texel(column c: Int, row r: Int, first: [UInt8]?, second: [UInt8]?,
                             parameters p: Parameters, scales: [Double] = [1 / 254, 1 / 254, 1 / 254, 60]) -> Texel {
        let climate = p.climatology[r]
        var low = climate.low, mid = climate.mid, high = climate.high
        var base: Double?
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
                let f = p.fieldWeight, x = 1 - f
                func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
                low = clamp(l) + x * (climate.low - clamp(l))
                mid = clamp(m) + x * (climate.mid - clamp(m))
                high = clamp(h) + x * (climate.high - clamp(h))
                base = x < 0.5 ? value(3) : nil
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
        var lowBase = CloudLayerModel.defaultLowBase
        if let b = base, b < CloudLayerModel.midBase { lowBase = max(b, 0) }
        let lowTop = convective ? CloudLayerModel.cumulonimbusTop : lowBase + CloudLayerModel.lowDepth
        return Texel(low: low, mid: mid, high: high, lowBase: lowBase, lowTop: lowTop)
    }

    /// The mission whose weather covers `epoch`: the launch nearest it within
    /// `window` (s, 16 days, longer than any of the flights), nil for none.
    public static func mission(at epoch: Epoch, window: Double = 16 * 86_400) -> String? {
        CloudOverride.launches.filter { epoch - $0.value.time >= -86_400 && epoch - $0.value.time <= window }
            .min { abs(epoch - $0.value.time) < abs(epoch - $1.value.time) }?.key
    }
}
