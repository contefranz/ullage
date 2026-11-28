import Foundation
import OrbitCore

/// Track LR4: an effect's medium as the renderer marches it (look round 2,
/// decision 3): the launch cloud's primitives (`GroundCloudField`) packed in
/// Float records for the GPU, the box its far field's density grid and
/// light volume cover, the air's humidity by `AirProfile` level for the
/// GPU's saturation adjustment, and each tier's grids and steps.
/// OrbitScene holds what only the renderer reads; OrbitRender's
/// LaunchCloudPass uploads it. `density(_:at:)` is the shader's evaluation
/// in Float, line by line, so the GPU can be checked against the field.
public struct EffectMedium: Equatable {
    /// Floats a primitive's record takes, and its layout:
    ///  0 shape (0 thermal, 1 round jet, 2 wall jet, 3 stem),
    ///  1-3 origin (site frame, m), 4-6 axis,
    ///  7 start, 8 end, 9 radius, 10 growth (m, m/m), 11 ground (site z, or
    ///  `noGround`), 12 norm (1/m of along-density, 1 for a thermal),
    ///  13 taper (m: the along-density's fade at its end),
    ///  14 source, 15 all its water (the deluge's and the exhaust's), 16
    ///  soot (kg), 17 heat (J),
    ///  18 the air's specific humidity, 19 flux (m⁴/s² a jet's, m⁴/s³ a
    ///  stem's, m/s a thermal's), 20 the seed's bits, 21-23 reserved.
    public static let stride = 24
    public static let noGround: Float = -1e30

    /// The primitives' records, `stride` floats each, at most
    /// `GroundCloudField.maximum`.
    public var records: [Float]
    public var count: Int { records.count / Self.stride }
    /// The box the far field's grids cover, site frame (m): the primitives'
    /// out to `reach` of their size, at least `minimumSize` across.
    public var lower: Vec3
    public var upper: Vec3
    /// The air's specific humidity at `AirProfile`'s 64 levels, kg/kg.
    public var humidity: [Float]

    /// A primitive's extent beyond its size, in sizes (a Gaussian's 3.2
    /// e-folds hold all but 1e-4 of it, and the turbulence's displacement).
    public static let reach = 3.5
    public static let minimumSize = 64.0

    public init(_ f: GroundCloudField) {
        var r: [Float] = []
        var lo = Vec3(Double.infinity, .infinity, .infinity), hi = -lo
        for p in f.primitives {
            r += Self.record(p)
            let (a, b) = Self.box(p)
            lo = Vec3(min(lo.x, a.x), min(lo.y, a.y), min(lo.z, a.z))
            hi = Vec3(max(hi.x, b.x), max(hi.y, b.y), max(hi.z, b.z))
        }
        if r.isEmpty { (lo, hi) = (.zero, .zero) }
        // At least `minimumSize` across on each axis, about its middle.
        let mid = (lo + hi) * 0.5, half = (hi - lo) * 0.5
        let grow = Vec3(max(half.x, Self.minimumSize / 2), max(half.y, Self.minimumSize / 2),
                        max(half.z, Self.minimumSize / 2))
        records = r
        lower = mid - grow
        upper = mid + grow
        humidity = (0..<AirProfile.count).map { i in
            let h = AirProfile.altitude(i) - f.deckHeight
            return Float(f.ambient(height: h).humidity)
        }
    }

    /// `p`'s record.
    static func record(_ p: GroundCloudField.Primitive) -> [Float] {
        var r = [Float](repeating: 0, count: stride)
        switch p.shape {
        case .thermal: r[0] = 0
        case .roundJet: r[0] = 1
        case .wallJet: r[0] = 2
        case .stem: r[0] = 3
        }
        (r[1], r[2], r[3]) = (Float(p.origin.x), Float(p.origin.y), Float(p.origin.z))
        (r[4], r[5], r[6]) = (Float(p.axis.x), Float(p.axis.y), Float(p.axis.z))
        r[7] = Float(p.start)
        r[8] = Float(p.end)
        r[9] = Float(p.radius)
        r[10] = Float(p.growth)
        r[11] = p.ground.isFinite ? Float(p.ground) : noGround
        r[12] = Float(p.norm)
        r[13] = Float(p.taper)
        r[14] = Float(p.source)
        r[15] = Float(p.totalWater)
        r[16] = Float(p.soot)
        r[17] = Float(p.heat)
        r[18] = Float(p.airHumidity)
        r[19] = Float(p.flux)
        r[20] = Float(bitPattern: p.seed)
        return r
    }

    /// The box `p` fills, site frame.
    static func box(_ p: GroundCloudField.Primitive) -> (Vec3, Vec3) {
        func around(_ points: [Vec3], _ r: Double) -> (Vec3, Vec3) {
            var lo = points[0], hi = points[0]
            for q in points {
                lo = Vec3(min(lo.x, q.x), min(lo.y, q.y), min(lo.z, q.z))
                hi = Vec3(max(hi.x, q.x), max(hi.y, q.y), max(hi.z, q.z))
            }
            let e = Vec3(r, r, r)
            var a = lo - e
            if p.ground.isFinite { a.z = max(a.z, p.ground) }
            return (a, hi + e)
        }
        switch p.shape {
        case .thermal:
            let r = reach * p.radius
            return around([p.origin], r)
        case .roundJet:
            return around([p.origin + p.axis * p.start, p.origin + p.axis * p.end], reach * p.jetRadius(p.end))
        case .wallJet:
            let r = p.end, t = reach * p.thickness(p.end)
            return (Vec3(p.origin.x - r, p.origin.y - r, p.origin.z), Vec3(p.origin.x + r, p.origin.y + r, p.origin.z + t))
        case .stem:
            return around([p.origin, p.origin + p.axis * p.end], reach * p.stemRadius(p.end))
        }
    }

    // MARK: The shader's evaluation, in Float

    /// Record `i`'s density at site point `p` (1/m³), its level sets
    /// displaced by `eta` m of rms `spread` m: `GroundCloudField.Primitive
    /// .density(at:displacement:spread:)` in Float, as LaunchCloudShaders
    /// evaluates it, the gains from `gains`.
    public func density(_ i: Int, at p: SIMD3<Float>, displacement eta: Float = 0, spread: Float = 0) -> Float {
        let r = Array(records[(i * Self.stride)..<((i + 1) * Self.stride)])
        guard r[12] > 0 else { return 0 }
        var (d, scale) = Self.unmirrored(r, p, eta)
        if r[11] > Self.noGround {
            guard p.z >= r[11] else { return 0 }
            d += Self.unmirrored(r, SIMD3(p.x, p.y, 2 * r[11] - p.z), eta).density
        }
        guard spread > 0 else { return d * r[12] }
        return d * r[12] / Self.gain(shape: Int(r[0]), spread: spread / max(scale, 1e-9))
    }

    /// The displacement's gains (`GroundCloudField.DisplacementGain`), three
    /// tables of `DisplacementGain.count` (thermal, round, wall), every
    /// `DisplacementGain.step` of σ: the shader's constants.
    public static let gains: [Float] = {
        let g = GroundCloudField.DisplacementGain.self
        return (g.thermal + g.round + g.wall).map(Float.init)
    }()

    static func gain(shape: Int, spread sigma: Float) -> Float {
        let n = GroundCloudField.DisplacementGain.count
        let table = shape == 0 ? 0 : shape == 2 ? 2 : 1
        let u = min(max(sigma / Float(GroundCloudField.DisplacementGain.step), 0), Float(n - 1) - 1e-4)
        let k = Int(u), f = u - Float(k)
        return gains[table * n + k] + (gains[table * n + k + 1] - gains[table * n + k]) * f
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func displaced(_ q: Float, _ eta: Float, _ scale: Float) -> Float {
        eta == 0 ? q : max(q - smoothstep(0, 1, q) * eta / max(scale, 1e-9), 0)
    }

    static func along(_ r: [Float], _ s: Float) -> Float {
        let start = r[7], end = r[8], taper = r[13]
        guard s >= start, s <= end else { return 0 }
        let fade = taper > 0 ? 1 - smoothstep(end - taper, end, s) : 1
        switch r[0] {
        case 1: return s * fade
        case 2: return (s * (r[9] + r[10] * max(s - start, 0))).squareRoot() * fade
        case 3: return powf(s + (r[10] > 0 ? r[9] / r[10] : 0), 1.0 / 3) * fade
        default: return 1
        }
    }

    /// The density before `norm` and the level-set coordinate's scale (m).
    static func unmirrored(_ r: [Float], _ p: SIMD3<Float>, _ eta: Float) -> (density: Float, scale: Float) {
        let origin = SIMD3(r[1], r[2], r[3]), axis = SIMD3(r[4], r[5], r[6])
        let d = p - origin
        let pi = Float.pi
        switch r[0] {
        case 0:
            let radius = r[9]
            let s = (d.x * d.x + d.y * d.y).squareRoot()
            let a = Float(GroundCloudField.ringRadius) * radius, sigma = Float(GroundCloudField.coreRadius) * radius
            let z = d.z / Float(GroundCloudField.capStretch)
            let q = displaced(((s - a) * (s - a) + z * z).squareRoot() / max(sigma, 1e-9), eta, sigma)
            return (expf(-q * q) / Float(GroundCloudField.ringVolume(Double(radius))), sigma)
        case 1, 3:
            let x = (d * axis).sum()
            let b = r[0] == 1 ? Float(GroundCloudField.concentrationSpread * GroundCloud.jetSpread) * max(x, r[7], 1e-6)
                : r[9] + r[10] * max(x, 0)
            let m = along(r, x)
            guard m > 0 else { return (0, b) }
            let across = d - axis * x
            let rr = (across * across).sum().squareRoot()
            let q = displaced(rr / b, eta, b)
            return (m * expf(-q * q) / (pi * b * b), b)
        default:
            let rho = (d.x * d.x + d.y * d.y).squareRoot()
            let delta = r[9] + r[10] * max(rho - r[7], 0)
            guard d.z >= 0, rho > 0 else { return (0, delta) }
            let m = along(r, rho)
            guard m > 0 else { return (0, delta) }
            let q = displaced(d.z / delta, eta, delta)
            return (m * (1 - smoothstep(0.5, 1.5, q)) / (Float(GroundCloudField.wallProfileIntegral) * delta)
                / (2 * pi * rho), delta)
        }
    }

    // MARK: Tiers

    /// A tier's medium (look round 2: Medium lands with High; Low draws
    /// sprite v2): the far field's density grid and light volume (cells),
    /// the distance within which the march evaluates the primitives
    /// directly (m), the march's steps and its resolution over the frame's.
    public struct Quality: Equatable {
        public var grid: (Int, Int, Int)
        public var light: (Int, Int, Int)
        public var nearField: Double
        public var steps: Int
        public var resolution: Double
        public var octaves: Int

        public static func == (a: Quality, b: Quality) -> Bool {
            a.grid == b.grid && a.light == b.light && a.nearField == b.nearField && a.steps == b.steps
                && a.resolution == b.resolution && a.octaves == b.octaves
        }

        /// High: a 128×128×64 grid (8-16 m) and a 64×64×32 light volume,
        /// the primitives directly within 300 m, at half resolution.
        public static let high = Quality(grid: (128, 128, 64), light: (64, 64, 32), nearField: 300, steps: 64,
                                         resolution: 0.5, octaves: LaunchTurbulence.maximumOctaves)
        /// Medium: the same grids, quarter resolution and 32 steps (decision
        /// 2: the pad's tier when the measured frame has no room for High).
        public static let medium = Quality(grid: (128, 128, 64), light: (64, 64, 32), nearField: 300, steps: 32,
                                           resolution: 0.25, octaves: 4)
    }

    /// The grid's cell on each axis (m) at `quality`.
    public func cell(_ quality: Quality) -> Vec3 {
        let s = upper - lower
        return Vec3(s.x / Double(quality.grid.0), s.y / Double(quality.grid.1), s.z / Double(quality.grid.2))
    }
}

extension GroundCloudField.Primitive {
    /// The along-density's fade at its end, m (`along`).
    public var taper: Double {
        switch shape {
        case .thermal: return 0
        case .roundJet: return min(0.5 * (end - start), GroundCloudField.concentrationSpread * GroundCloud.jetSpread * end)
        case .wallJet: return min(0.5 * (end - start), 2 * thickness(end))
        case .stem: return 0.25 * (end - start)
        }
    }
}
