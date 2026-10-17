import Foundation

public struct AtmosphereState: Equatable {
    public var temperature: Double   // K
    public var pressure: Double      // Pa
    public var density: Double       // kg/m^3
    public var speedOfSound: Double  // m/s

    public static let vacuum = AtmosphereState(temperature: 0, pressure: 0, density: 0, speedOfSound: 1)
}

public protocol Atmosphere: AnyObject {
    /// Properties at geometric altitude `h` (m) above the reference radius.
    func state(altitude h: Double) -> AtmosphereState
    /// Altitude above which the atmosphere is treated as vacuum.
    var ceiling: Double { get }
    /// Sea-level pressure (Pa), used to interpolate engine performance.
    var seaLevelPressure: Double { get }
    /// Wind at altitude `h` (m/s, towards local east and north).
    func wind(altitude h: Double) -> (east: Double, north: Double)
}

extension Atmosphere {
    public func wind(altitude h: Double) -> (east: Double, north: Double) { (0, 0) }
}

/// A measured atmosphere: one sounding of temperature, pressure, density,
/// speed of sound and wind against geometric altitude (a launch day's air),
/// horizontally uniform, over a standard model. Above the sounding's top the
/// ratios of each quantity to the standard model, and the wind, fade out
/// linearly over `blend` metres. Pressure and density interpolate
/// log-linearly between levels, the rest linearly.
public final class SoundingAtmosphere: Atmosphere {
    public struct Level {
        public var altitude: Double
        public var state: AtmosphereState
        public init(altitude: Double, state: AtmosphereState) {
            self.altitude = altitude
            self.state = state
        }
    }

    public let levels: [Level]
    public let winds: [(altitude: Double, east: Double, north: Double)]
    public let standard: Atmosphere
    public let blend: Double
    public var ceiling: Double { standard.ceiling }
    public var seaLevelPressure: Double { standard.seaLevelPressure }

    public init(levels: [Level], winds: [(altitude: Double, east: Double, north: Double)],
                standard: Atmosphere = USStandardAtmosphere1976(), blend: Double = 10_000) {
        self.levels = levels.sorted { $0.altitude < $1.altitude }
        self.winds = winds.sorted { $0.altitude < $1.altitude }
        self.standard = standard
        self.blend = blend
    }

    public func state(altitude h: Double) -> AtmosphereState {
        guard let first = levels.first, let top = levels.last else { return standard.state(altitude: h) }
        if h <= first.altitude { return first.state }
        if h >= top.altitude {
            let f = min(1, (h - top.altitude) / blend)
            if f >= 1 { return standard.state(altitude: h) }
            // The sounding's ratios to the standard model at its top, fading to 1.
            let s = standard.state(altitude: h), ref = standard.state(altitude: top.altitude)
            func r(_ day: Double, _ std: Double) -> Double { std > 0 ? 1 + (day / std - 1) * (1 - f) : 1 }
            return AtmosphereState(temperature: s.temperature * r(top.state.temperature, ref.temperature),
                                   pressure: s.pressure * r(top.state.pressure, ref.pressure),
                                   density: s.density * r(top.state.density, ref.density),
                                   speedOfSound: s.speedOfSound * r(top.state.speedOfSound, ref.speedOfSound))
        }
        var i = 0
        while levels[i + 1].altitude < h { i += 1 }
        let a = levels[i], b = levels[i + 1]
        let t = (h - a.altitude) / (b.altitude - a.altitude)
        func lin(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        func geo(_ x: Double, _ y: Double) -> Double { x > 0 && y > 0 ? x * pow(y / x, t) : lin(x, y) }
        return AtmosphereState(temperature: lin(a.state.temperature, b.state.temperature),
                               pressure: geo(a.state.pressure, b.state.pressure),
                               density: geo(a.state.density, b.state.density),
                               speedOfSound: lin(a.state.speedOfSound, b.state.speedOfSound))
    }

    public func wind(altitude h: Double) -> (east: Double, north: Double) {
        guard let first = winds.first, let top = winds.last else { return (0, 0) }
        if h <= first.altitude { return (first.east, first.north) }
        if h >= top.altitude {
            let f = max(0, 1 - (h - top.altitude) / blend)
            return (top.east * f, top.north * f)
        }
        var i = 0
        while winds[i + 1].altitude < h { i += 1 }
        let a = winds[i], b = winds[i + 1]
        let t = (h - a.altitude) / (b.altitude - a.altitude)
        return (a.east + (b.east - a.east) * t, a.north + (b.north - a.north) * t)
    }
}

/// U.S. Standard Atmosphere 1976 up to 86 km geometric, then an exponential
/// density model (Vallado, Table 8-4) up to 1000 km. Above 86 km temperature and
/// pressure are held at nominal values; only density matters there (drag).
public final class USStandardAtmosphere1976: Atmosphere {
    public init() {}

    public let ceiling = 1_000_000.0
    public let seaLevelPressure = 101_325.0

    static let r0 = 6_356_766.0          // effective Earth radius for geopotential altitude, m
    static let g0 = 9.80665
    static let molarMass = 0.0289644     // kg/mol
    static let gasConstant = 8.31432     // J/(mol K), value used by the 1976 standard
    static let gamma = 1.4

    /// Layer bases: geopotential altitude (m), temperature (K), lapse rate (K/m), pressure (Pa).
    static let layers: [(h: Double, t: Double, lapse: Double, p: Double)] = {
        let defs: [(Double, Double)] = [
            (0, -0.0065), (11_000, 0), (20_000, 0.001), (32_000, 0.0028),
            (47_000, 0), (51_000, -0.0028), (71_000, -0.002),
        ]
        var out: [(h: Double, t: Double, lapse: Double, p: Double)] = []
        var t = 288.15, p = 101_325.0
        for (i, d) in defs.enumerated() {
            out.append((d.0, t, d.1, p))
            let top = i + 1 < defs.count ? defs[i + 1].0 : 84_852
            let dh = top - d.0
            let k = g0 * molarMass / gasConstant
            if d.1 == 0 {
                p *= exp(-k * dh / t)
            } else {
                let t2 = t + d.1 * dh
                p *= pow(t / t2, k / d.1)
                t = t2
            }
        }
        return out
    }()

    /// Exponential model rows: base altitude (km), base density (kg/m^3), scale height (km).
    static let exponential: [(Double, Double, Double)] = [
        (0, 1.225, 7.249), (25, 3.899e-2, 6.349), (30, 1.774e-2, 6.682), (40, 3.972e-3, 7.554),
        (50, 1.057e-3, 8.382), (60, 3.206e-4, 7.714), (70, 8.770e-5, 6.549), (80, 1.905e-5, 5.799),
        (90, 3.396e-6, 5.382), (100, 5.297e-7, 5.877), (110, 9.661e-8, 7.263), (120, 2.438e-8, 9.473),
        (130, 8.484e-9, 12.636), (140, 3.845e-9, 16.149), (150, 2.070e-9, 22.523), (180, 5.464e-10, 29.740),
        (200, 2.789e-10, 37.105), (250, 7.248e-11, 45.546), (300, 2.418e-11, 53.628), (350, 9.518e-12, 53.298),
        (400, 3.725e-12, 58.515), (450, 1.585e-12, 60.828), (500, 6.967e-13, 63.822), (600, 1.454e-13, 71.835),
        (700, 3.614e-14, 88.667), (800, 1.170e-14, 124.64), (900, 5.245e-15, 181.05), (1000, 3.019e-15, 268.00),
    ]

    public func state(altitude z: Double) -> AtmosphereState {
        if z > ceiling { return .vacuum }
        let h = max(z, -5000)
        if h <= 86_000 {
            let H = Self.r0 * h / (Self.r0 + h)   // geopotential altitude
            var layer = Self.layers[0]
            for l in Self.layers where H >= l.h { layer = l }
            let dh = H - layer.h
            let k = Self.g0 * Self.molarMass / Self.gasConstant
            let t: Double, p: Double
            if layer.lapse == 0 {
                t = layer.t
                p = layer.p * exp(-k * dh / layer.t)
            } else {
                t = layer.t + layer.lapse * dh
                p = layer.p * pow(layer.t / t, k / layer.lapse)
            }
            let rho = p * Self.molarMass / (Self.gasConstant * t)
            let a = (Self.gamma * Self.gasConstant * t / Self.molarMass).squareRoot()
            return AtmosphereState(temperature: t, pressure: p, density: rho, speedOfSound: a)
        }
        let km = h / 1000
        var row = Self.exponential[0]
        for r in Self.exponential where km >= r.0 { row = r }
        let rho = row.1 * exp(-(km - row.0) / row.2)
        let t = 186.87
        let p = rho * Self.gasConstant * t / Self.molarMass
        return AtmosphereState(temperature: t, pressure: p, density: rho,
                               speedOfSound: (Self.gamma * Self.gasConstant * t / Self.molarMass).squareRoot())
    }
}
