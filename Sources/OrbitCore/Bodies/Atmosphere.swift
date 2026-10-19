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

/// U.S. Standard Atmosphere 1976 to 1,000 km geometric.
///
/// - Up to 86 km: the standard's seven geopotential layers, hydrostatic with
///   linear molecular-scale temperature T_M and M0 = 28.9644 kg/kmol. The
///   temperature given is T_M, which is the kinetic temperature below 80 km
///   and within 0.08 K of it at 86 km.
/// - From 86 to 1,000 km: rows of Part 4 Table I (`upper`), every 0.5 km to
///   100 km, 1 km to 150 km, then 5 to 50 km apart, with pressure and
///   density log-linear between them. The kinetic temperature is the
///   standard's own profile (isothermal, elliptical, linear, then
///   exponential to T∞ = 1,000 K; `upperTemperature`).
///
/// The speed of sound is sqrt(γ p / ρ) with γ = 1.4 throughout: the
/// standard's sqrt(γ R* T_M / M0), continuous at 86 km. Above about 120 km
/// the air is mostly atomic and the value is only nominal.
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

    /// U.S. Standard Atmosphere 1976 (NOAA-S/T 76-1562), Part 4 Table I,
    /// geometric altitude, from 86 to 1,000 km: altitude (km), pressure
    /// (mbar) and density (kg/m^3) as printed. Every printed row to 149 km,
    /// then every 5 km to 225 km, 10 km to 500 km and 25-50 km above; the
    /// rows between lie log-linear on these. Read from the page images by
    /// two readers, with the gas law and the temperature profile checked on
    /// every row (tools/data/us76_table1_86_1000km.csv, H).
    static let upper: [(km: Double, pressure: Double, density: Double)] = [
        (86, 3.7338e-3, 6.958e-6), (86.5, 3.4163e-3, 6.366e-6), (87, 3.1259e-3, 5.824e-6),
        (87.5, 2.8602e-3, 5.328e-6), (88, 2.6173e-3, 4.875e-6), (88.5, 2.3951e-3, 4.460e-6),
        (89, 2.1919e-3, 4.081e-6), (89.5, 2.0060e-3, 3.734e-6), (90, 1.8359e-3, 3.416e-6),
        (90.5, 1.6804e-3, 3.126e-6), (91, 1.5381e-3, 2.860e-6), (91.5, 1.4078e-3, 2.616e-6),
        (92, 1.2887e-3, 2.393e-6), (92.5, 1.1798e-3, 2.188e-6), (93, 1.0801e-3, 2.000e-6),
        (93.5, 9.8896e-4, 1.828e-6), (94, 9.0560e-4, 1.670e-6), (94.5, 8.2937e-4, 1.526e-6),
        (95, 7.5966e-4, 1.393e-6), (95.5, 6.9592e-4, 1.273e-6), (96, 6.3765e-4, 1.162e-6),
        (96.5, 5.8439e-4, 1.061e-6), (97, 5.3571e-4, 9.685e-7), (97.5, 4.9122e-4, 8.842e-7),
        (98, 4.5057e-4, 8.071e-7), (98.5, 4.1342e-4, 7.367e-7), (99, 3.7948e-4, 6.725e-7),
        (99.5, 3.4846e-4, 6.139e-7), (100, 3.2011e-4, 5.604e-7), (101, 2.7192e-4, 4.695e-7),
        (102, 2.3144e-4, 3.935e-7), (103, 1.9742e-4, 3.300e-7), (104, 1.6882e-4, 2.769e-7),
        (105, 1.4477e-4, 2.325e-7), (106, 1.2454e-4, 1.954e-7), (107, 1.0751e-4, 1.643e-7),
        (108, 9.3188e-5, 1.381e-7), (109, 8.1142e-5, 1.161e-7), (110, 7.1042e-5, 9.708e-8),
        (111, 6.2614e-5, 8.111e-8), (112, 5.5547e-5, 6.838e-8), (113, 4.9570e-5, 5.811e-8),
        (114, 4.4473e-5, 4.975e-8), (115, 4.0096e-5, 4.289e-8), (116, 3.6312e-5, 3.720e-8),
        (117, 3.3022e-5, 3.246e-8), (118, 3.0144e-5, 2.847e-8), (119, 2.7615e-5, 2.509e-8),
        (120, 2.5382e-5, 2.222e-8), (121, 2.3401e-5, 1.977e-8), (122, 2.1635e-5, 1.767e-8),
        (123, 2.0055e-5, 1.585e-8), (124, 1.8635e-5, 1.428e-8), (125, 1.7354e-5, 1.291e-8),
        (126, 1.6194e-5, 1.171e-8), (127, 1.5141e-5, 1.065e-8), (128, 1.4183e-5, 9.717e-9),
        (129, 1.3307e-5, 8.889e-9), (130, 1.2505e-5, 8.152e-9), (131, 1.1769e-5, 7.494e-9),
        (132, 1.1092e-5, 6.904e-9), (133, 1.0468e-5, 6.374e-9), (134, 9.8907e-6, 5.897e-9),
        (135, 9.3568e-6, 5.465e-9), (136, 8.8617e-6, 5.074e-9), (137, 8.4018e-6, 4.719e-9),
        (138, 7.9739e-6, 4.396e-9), (139, 7.5751e-6, 4.101e-9), (140, 7.2028e-6, 3.831e-9),
        (141, 6.8550e-6, 3.584e-9), (142, 6.5294e-6, 3.358e-9), (143, 6.2243e-6, 3.150e-9),
        (144, 5.9380e-6, 2.958e-9), (145, 5.6691e-6, 2.781e-9), (146, 5.4162e-6, 2.618e-9),
        (147, 5.1781e-6, 2.466e-9), (148, 4.9538e-6, 2.326e-9), (149, 4.7421e-6, 2.196e-9),
        (150, 4.5422e-6, 2.076e-9), (155, 3.6930e-6, 1.585e-9), (160, 3.0395e-6, 1.233e-9),
        (165, 2.5278e-6, 9.750e-10), (170, 2.1210e-6, 7.815e-10), (175, 1.7936e-6, 6.339e-10),
        (180, 1.5271e-6, 5.194e-10), (185, 1.3081e-6, 4.295e-10), (190, 1.1266e-6, 3.581e-10),
        (195, 9.7491e-7, 3.006e-10), (200, 8.4736e-7, 2.541e-10), (205, 7.3942e-7, 2.160e-10),
        (210, 6.4756e-7, 1.846e-10), (215, 5.6900e-7, 1.585e-10), (220, 5.0149e-7, 1.367e-10),
        (225, 4.4324e-7, 1.184e-10), (230, 3.9276e-7, 1.029e-10), (240, 3.1059e-7, 7.858e-11),
        (250, 2.4767e-7, 6.073e-11), (260, 1.9894e-7, 4.742e-11), (270, 1.6083e-7, 3.738e-11),
        (280, 1.3076e-7, 2.971e-11), (290, 1.0685e-7, 2.378e-11), (300, 8.7704e-8, 1.916e-11),
        (310, 7.2285e-8, 1.552e-11), (320, 5.9796e-8, 1.264e-11), (330, 4.9630e-8, 1.035e-11),
        (340, 4.1320e-8, 8.503e-12), (350, 3.4498e-8, 7.014e-12), (360, 2.8878e-8, 5.805e-12),
        (370, 2.4234e-8, 4.820e-12), (380, 2.0384e-8, 4.013e-12), (390, 1.7184e-8, 3.350e-12),
        (400, 1.4518e-8, 2.803e-12), (410, 1.2291e-8, 2.350e-12), (420, 1.0427e-8, 1.975e-12),
        (430, 8.8645e-9, 1.662e-12), (440, 7.5517e-9, 1.402e-12), (450, 6.4468e-9, 1.184e-12),
        (460, 5.5155e-9, 1.002e-12), (470, 4.7292e-9, 8.492e-13), (480, 4.0642e-9, 7.208e-13),
        (490, 3.5011e-9, 6.127e-13), (500, 3.0236e-9, 5.215e-13), (525, 2.1200e-9, 3.509e-13),
        (550, 1.5137e-9, 2.384e-13), (575, 1.1028e-9, 1.637e-13), (600, 8.2130e-10, 1.137e-13),
        (625, 6.2601e-10, 7.998e-14), (650, 4.8865e-10, 5.712e-14), (700, 3.1908e-10, 3.070e-14),
        (750, 2.2599e-10, 1.788e-14), (800, 1.7036e-10, 1.136e-14), (845, 1.3719e-10, 8.094e-15),
        (850, 1.3415e-10, 7.824e-15), (900, 1.0873e-10, 5.759e-15), (950, 8.9816e-11, 4.453e-15),
        (1000, 7.5138e-11, 3.561e-15)
    ]

    /// The standard's kinetic temperature above 86 km (K) at geometric
    /// altitude `km`: 186.8673 K to 91 km; an ellipse to 240 K at 110 km;
    /// +12 K/km to 360 K at 120 km; then 1000 - 640 exp(-0.01875 ξ), with
    /// ξ = (z - 120)(r0 + 120)/(r0 + z) the geopotential distance from 120 km.
    static func upperTemperature(km z: Double) -> Double {
        if z <= 91 { return 186.8673 }
        if z <= 110 {
            let s = (z - 91) / -19.9429
            return 263.1905 - 76.3232 * max(0, 1 - s * s).squareRoot()
        }
        if z <= 120 { return 240 + 12 * (z - 110) }
        let r = r0 / 1000, xi = (z - 120) * (r + 120) / (r + z)
        return 1000 - 640 * exp(-0.01875 * xi)
    }

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
        let km = min(h / 1000, 1000), rows = Self.upper
        var lo = 0, hi = rows.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if rows[mid].km <= km { lo = mid } else { hi = mid }
        }
        let a = rows[lo], b = rows[hi], f = (km - a.km) / (b.km - a.km)
        let p = 100 * a.pressure * pow(b.pressure / a.pressure, f)
        let rho = a.density * pow(b.density / a.density, f)
        return AtmosphereState(temperature: Self.upperTemperature(km: km), pressure: p, density: rho,
                               speedOfSound: (Self.gamma * p / rho).squareRoot())
    }
}
