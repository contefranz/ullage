import Foundation
import OrbitCore

// MARK: - Moist air

/// Water in air, for the launch cloud's condensate: saturation over liquid
/// water and the saturation adjustment of a mixture.
public enum MoistAir {
    /// Water's molar mass over dry air's, and their gas constants, J/(kg K).
    public static let epsilon = 0.018015 / 0.028965
    public static let dryGasConstant = 287.05, vapourGasConstant = 461.52
    /// Dry air's specific heat, as `GroundCloud`'s.
    public static var specificHeat: Double { GroundCloud.airHeat }

    /// Water's saturation vapour pressure over its liquid at `t` K, Pa.
    /// From its triple point to its critical point, Wagner and Pruss's
    /// (2002, J. Phys. Chem. Ref. Data 31, 387, eq. 2.5: IAPWS-95's
    /// saturation line within 0.03 %, H); below the triple point, over
    /// supercooled water, Murphy and Koop's (2005, QJRMS 131, 1539, eq. 10:
    /// H).
    public static func saturationPressure(_ t: Double) -> Double {
        let tc = 647.096, pc = 22.064e6
        guard t >= 273.16 else {
            let t = max(t, 123)
            let ln = 54.842763 - 6_763.22 / t - 4.210 * log(t) + 0.000367 * t
                + tanh(0.0415 * (t - 218.8)) * (53.878 - 1_331.22 / t - 9.44523 * log(t) + 0.014025 * t)
            return exp(ln)
        }
        guard t < tc else { return pc }
        let v = 1 - t / tc
        let sum = -7.85951783 * v + 1.84408259 * pow(v, 1.5) - 11.7866497 * v * v * v + 22.6807411 * pow(v, 3.5)
            - 15.9618719 * v * v * v * v + 1.80122502 * pow(v, 7.5)
        return pc * exp(tc / t * sum)
    }

    /// The latent heat of vaporisation at `t` K, J/kg: 2.501 MJ/kg at 0 °C
    /// falling 2,370 J/kg a kelvin (Rogers and Yau 1989, M; 2.264 MJ/kg at
    /// 100 °C against IAPWS's 2.257).
    public static func latentHeat(_ t: Double) -> Double { 2.501e6 - 2_370 * (t - 273.15) }

    /// The specific humidity of saturated air at `t` K and `p` Pa, kg of
    /// vapour a kilogram of moist air: ε e_s / (p − (1 − ε) e_s), 1 where
    /// water boils.
    public static func saturationHumidity(_ t: Double, pressure p: Double) -> Double {
        let e = saturationPressure(t)
        guard e < p else { return 1 }
        return epsilon * e / (p - (1 - epsilon) * e)
    }

    /// The specific humidity of air at `p` Pa whose vapour has partial
    /// pressure `e` Pa.
    public static func specificHumidity(vapourPressure e: Double, pressure p: Double) -> Double {
        epsilon * e / max(p - (1 - epsilon) * e, 1e-9)
    }

    /// The vapour's partial pressure in air at `p` Pa of specific humidity `q`.
    public static func vapourPressure(specificHumidity q: Double, pressure p: Double) -> Double {
        q * p / (epsilon + (1 - epsilon) * q)
    }

    /// A mixture's saturation adjustment: a parcel whose water is `water`
    /// kg a kilogram of it (vapour and condensate) at `p` Pa, at `t` K were
    /// all its water vapour. Whatever vapour exceeds saturation condenses,
    /// warming it by its latent heat: c_p (T − t) = L(T) q_c, q_c = q_t −
    /// q_s(T, p) ≥ 0 (the condensate's own heat capacity left out, M). Its
    /// temperature and condensate (kg a kilogram), by Newton's method from
    /// the unsaturated state.
    public static func adjust(temperature t: Double, water qt: Double, pressure p: Double)
        -> (temperature: Double, condensate: Double) {
        guard qt > 0, p > 0, qt > saturationHumidity(t, pressure: p) else { return (t, 0) }
        let cp = specificHeat
        var x = t
        for _ in 0..<30 {
            let qs = saturationHumidity(x, pressure: p), l = latentHeat(x)
            let g = cp * (x - t) - l * (qt - qs)
            // dq_s/dT by Clausius-Clapeyron: q_s L / (R_v T²) (to first order).
            let dqs = qs * l / (vapourGasConstant * x * x)
            let dg = cp + 2_370 * (qt - qs) + l * dqs
            let step = g / dg
            x -= step
            if abs(step) < 1e-10 { break }
        }
        return (x, max(0, qt - saturationHumidity(x, pressure: p)))
    }
}

// MARK: - The launch day's humidity

/// The water vapour in the air round the pad (look round 2, decision 6),
/// until a measured dew-point profile for 16 July 1969 is chosen (IGRA v2
/// station 74794 has soundings for 1950-2026; FER-506's Appendix A gives
/// dew points at the surface only: Franz decides on data):
/// - **The surface** is the launch's own observation: NASA TM X-64796
///   Table 1, AS-506's row (seq. 145, 13:32 UT, LC-39A): 10.203 N/cm²,
///   29.4 °C, 73 % relative humidity (tools/data/tmx64796_table1_saturn.csv,
///   M as the row is graded): a mixing ratio of 18.8 g/kg, dew point
///   24.0 °C. Lifted, that air saturates at about 0.7 km, the base FER-506
///   (Appendix A) gives the launch's 1/10 cumulus.
/// - **Aloft** it is July's at Cape Canaveral: the 1983 Range Reference
///   Atmosphere's means for station 74794 over 1957-1979, its 12-18Z window
///   (Apollo 11's 13:32 UT within it), Table II-7's temperature and Table
///   III-7's vapour pressure every kilometre (NASA, NTRS 19830021664, H for
///   the tables, L for the day): the relative humidity of the means, 72 %
///   at 1 km, 65 % at 2 km, 58 % at 3 km. The 5 km vapour pressure's digit
///   is blurred in the scan and is left out (4 to 6 km interpolated).
/// - **Between** the relative humidity is linear in height; above 6 km
///   it holds 6 km's. The sounding (`AirProfile`) gives the temperature
///   and pressure everywhere.
public struct LaunchHumidity: Equatable {
    /// The surface observation: K, 0-1, Pa.
    public var temperature: Double
    public var relativeHumidity: Double
    public var pressure: Double
    /// The relative humidity aloft: heights above the deck (m) and values,
    /// rising.
    public var aloft: [(height: Double, humidity: Double)]

    public init(temperature: Double, relativeHumidity: Double, pressure: Double,
                aloft: [(height: Double, humidity: Double)] = LaunchHumidity.julyAloft) {
        self.temperature = temperature
        self.relativeHumidity = relativeHumidity
        self.pressure = pressure
        self.aloft = aloft
    }

    public static func == (a: LaunchHumidity, b: LaunchHumidity) -> Bool {
        a.temperature == b.temperature && a.relativeHumidity == b.relativeHumidity && a.pressure == b.pressure
            && a.aloft.map(\.height) == b.aloft.map(\.height) && a.aloft.map(\.humidity) == b.aloft.map(\.humidity)
    }

    /// The 1983 Cape Canaveral RRA's July means (12-18Z, 1957-1979): height
    /// (km), temperature (K, Table II-7) and vapour pressure (hPa, Table
    /// III-7).
    public static let rraJuly: [(height: Double, temperature: Double, vapourPressure: Double)] = [
        (1, 293.86, 17.705), (2, 287.88, 10.911), (3, 282.22, 6.630), (4, 276.50, 4.133), (6, 265.10, 1.519),
    ]
    /// Their relative humidity, over water.
    public static let julyAloft: [(height: Double, humidity: Double)] = rraJuly.map {
        ($0.height * 1_000, $0.vapourPressure * 100 / MoistAir.saturationPressure($0.temperature))
    }

    /// AS-506's launch (TM X-64796), July's aloft (the RRA).
    public static let as506 = LaunchHumidity(temperature: 273.15 + 29.4, relativeHumidity: 0.73, pressure: 102_030)

    /// The surface air's vapour pressure (Pa) and mixing ratio (kg/kg of dry air).
    public var vapourPressure: Double { relativeHumidity * MoistAir.saturationPressure(temperature) }
    public var mixingRatio: Double { MoistAir.epsilon * vapourPressure / (pressure - vapourPressure) }

    /// The relative humidity `z` m above the deck.
    public func relativeHumidity(height z: Double) -> Double {
        var a = (height: 0.0, humidity: relativeHumidity)
        for b in aloft {
            if z <= b.height {
                let w = (z - a.height) / max(b.height - a.height, 1e-9)
                return a.humidity + (b.humidity - a.humidity) * min(max(w, 0), 1)
            }
            a = b
        }
        return a.humidity
    }

    /// The height (m above the deck) at which the surface air, lifted dry
    /// adiabatically with its mixing ratio, saturates: its lifting
    /// condensation level, in the sounding `air` (nil: the standard).
    public func condensationLevel(_ air: AirProfile?, surfaceHeight: Double) -> Double {
        let r = mixingRatio, kappa = 0.2857
        func excess(_ z: Double) -> Double {
            let p = Self.state(air, height: z, surfaceHeight: surfaceHeight).pressure
            let t = temperature * pow(p / pressure, kappa)
            let e = r * p / (MoistAir.epsilon + r)
            return MoistAir.saturationPressure(t) - e
        }
        var lo = 0.0, hi = 5_000.0
        for _ in 0..<60 {
            let mid = 0.5 * (lo + hi)
            if excess(mid) > 0 { lo = mid } else { hi = mid }
        }
        return 0.5 * (lo + hi)
    }

    /// The profile in the sounding `air`, the deck `surfaceHeight` m above
    /// sea level.
    public func profile(_ air: AirProfile?, surfaceHeight: Double) -> Profile { Profile(humidity: self) }

    /// The sounding's temperature and pressure `z` m above the deck (nil:
    /// the standard 288 K and 101,325 Pa at the deck, 6.5 K/km).
    static func state(_ air: AirProfile?, height z: Double, surfaceHeight: Double)
        -> (temperature: Double, pressure: Double) {
        if let a = air {
            let s = a.sample(altitude: surfaceHeight + max(z, 0))
            return (s.temperature, s.pressure)
        }
        let t = 288.15 - 0.0065 * max(z, 0)
        return (t, 101_325 * pow(t / 288.15, 9.80665 / (287.05 * 0.0065)))
    }

    /// The humidity with height.
    public struct Profile: Equatable {
        public var humidity: LaunchHumidity

        /// The air's specific humidity (kg of vapour a kilogram of moist
        /// air) `z` m above the deck, where it is at `t` K and `p` Pa.
        public func specificHumidity(height z: Double, temperature t: Double, pressure p: Double) -> Double {
            let e = humidity.relativeHumidity(height: z) * MoistAir.saturationPressure(t)
            return MoistAir.specificHumidity(vapourPressure: min(e, 0.99 * p), pressure: p)
        }
    }
}

// MARK: - The field

/// Track LR4: the launch cloud as a medium of similarity primitives (look
/// round 2, decision 3: the pad's cloud is a medium, not sprites), built
/// from `GroundCloud`'s state alone, so that a rebuilt field is the frames'
/// to the bit. At most 12 primitives (`maximum`), each a flow's similarity
/// solution with a closed-form shape whose integral is one:
/// - the two trench jets, round momentum jets from the deflector (Fischer
///   et al. 1979, Table 9.1: the concentration's e-folding radius λ b, λ =
///   1.19, b = 0.107 x), from the exits to their fronts, along the ground
///   at the exits' mid-depth and mirrored in the grade;
/// - the deck's wall jet, P2's continued (`PlumeImpingement`): half-
///   thickness δ growing 0.087 a metre (Poreh, Tsuei and Cermak 1967), its
///   profile across P2's, from where P2's ends (`WallJetHandover`) out to
///   its front; the speed that keeps all its momentum in that layer;
/// - the clouds as ring thermals: a vortex ring's Gaussian torus about the
///   cloud's vertical axis (`ringRadius`, `coreRadius`, `capStretch` of its
///   radius, L), mirrored in the ground it rests on;
/// - the stems, buoyant plumes from each trench jet's end up into its
///   cloud while the jet feeds it, faded in as the cloud lifts and as the
///   jet's buoyancy rises (Morton, Taylor and Turner 1956, top-hat α 0.117
///   as List 1982 compiles it: M);
/// - the start smoke's three small thermals until the trench's jets run,
///   then all of it inside the trench's clouds (the exits' through them,
///   the chimney's taken in down the opening, half to each).
///
/// What each carries is GroundCloud's: a lobe's exhaust, water, start
/// smoke, soot and heat are shared between its jet and stem (what flows in
/// them at their steady flow, at most what the lobe has) and its cloud (the
/// rest), so the field's totals are the cloud's (`GroundCloudFieldTests`:
/// within 1 %). The deck's wall jet as far as P2 draws it is P2's
/// (`inPlume`); past that it carries P2's own flux on, within 1 %.
///
/// The condensate is not carried: at each point the mixture of what the
/// primitives bring there and the air (the cloud's own, entrained with its
/// humidity, blended to the ambient's at its edge) is saturation-adjusted
/// (`MoistAir.adjust`), with the air's humidity from `LaunchHumidity`. This
/// replaces P4's "all of the water condensed" (L).
///
/// Site frame (`LC39A`): x north, y west, z up from the ML deck, m.
public struct GroundCloudField: Equatable {
    public static let maximum = 12

    // MARK: Constants

    /// The round jet's concentration over its velocity spread (Fischer et
    /// al. 1979, Table 9.1: H).
    public static let concentrationSpread = 1.19
    /// A buoyant plume's top-hat entrainment (List 1982: M) and its
    /// Gaussian radius's growth, (6/5) α / √2.
    public static let plumeEntrainment = 0.117
    public static var stemSpread: Double { 1.2 * plumeEntrainment / 2.0.squareRoot() }
    /// A thermal's ring vortex, over the thermal's radius R: the ring's
    /// radius, its core's Gaussian radius, and the core's vertical stretch
    /// (L: the look of Scorer's laboratory thermals, a cap over a ring).
    public static let ringRadius = 0.35, coreRadius = 0.5, capStretch = 1.2
    /// The wall jet's profile across it, P2's at large distances from the
    /// exit (`PlumeMember.sample`'s top hat): 1 − smoothstep(0.5, 1.5, z/δ),
    /// and its integrals ∫ p and ∫ p² over z/δ.
    public static let wallProfileIntegral = 1.0, wallProfileSquare = 0.871_428_571_428_571_4
    /// Where the trench's jets run: the exits' mid-depth, and the grade
    /// they run over and are mirrored in.
    public static var jetHeight: Double { PadExhaust.trenchExits[0].position.z }
    public static var grade: Double { LC39A.gradeHeight }
    /// A stem fades in as its cloud lifts off the ground (over this share of
    /// its radius) and as its jet's buoyancy flux rises past this share of
    /// a trench jet's at full thrust (L, so that neither switches it on).
    public static let stemLiftOff = 0.5, stemBuoyancy = 0.05
    /// Without P2's wall jet: its half-thickness where it starts, half an
    /// F-1 jet's radius at the deck (P2's R(h)/2, the overexpanded jet
    /// barely wider than its exit at sea level: L).
    public static var defaultWallThickness: Double { 0.5 * ApolloExhaust.f1.spec.exitRadius }

    // MARK: Primitives

    public enum Shape: Equatable {
        /// A ring thermal about the vertical through `origin`, of radius
        /// `radius` (its equal sphere's).
        case thermal
        /// A round jet from its virtual origin `origin` along `axis`, from
        /// x = `start` to `end`.
        case roundJet
        /// The deck's radial wall jet about `origin` on the deck, from ρ =
        /// `start` to `end`, its half-thickness `radius` at `start`, growing
        /// `growth` a metre.
        case wallJet
        /// A stem from `origin` along `axis` for `end` m, its Gaussian radius
        /// `radius` at its base, growing `growth` a metre.
        case stem
    }

    /// One primitive: its shape, what it carries and its flow.
    public struct Primitive: Equatable {
        public var shape: Shape
        /// The lobe it belongs to.
        public var lobe: GroundCloud.Lobe.Kind
        public var origin: Vec3
        public var axis: Vec3
        public var start = 0.0, end = 0.0
        public var radius = 0.0, growth = 0.0
        /// The plane it rests on and is mirrored in (site z); −∞ for none.
        public var ground = -Double.infinity
        /// What it carries: kg of exhaust (its own water in it), the deluge's
        /// water it boiled, start smoke and soot, and its heat above the air
        /// (J).
        public var exhaust = 0.0, water = 0.0, smoke = 0.0, soot = 0.0, heat = 0.0
        /// The specific humidity of the air it carries (its lobe's
        /// entrained air's, or the ground's for a jet).
        public var airHumidity = 0.0
        /// Its flow: a jet's kinematic momentum flux (m⁴/s²), a stem's
        /// buoyancy flux (m⁴/s³), a thermal's rise (m/s).
        public var flux = 0.0
        /// The shape's normalisation: one over the integral of its
        /// along-axis density (`along`), so that `density(at:)` integrates
        /// to one.
        public var norm = 0.0

        /// Everything it carries from the pad, kg: the exhaust, the water
        /// and the start smoke (the soot is in them).
        public var source: Double { exhaust + water + smoke }
        /// All the water it brings, kg: the deluge's, the exhaust's own and
        /// what the exhaust's hydrogen makes burning (`LaunchCloudOptics.exhaustWater`).
        public var totalWater: Double { water + LaunchCloudOptics.exhaustWater * exhaust }

        // MARK: Shape

        /// The density along a linear primitive at s (x, ρ or ℓ), before
        /// `norm`: its mass per unit length at its steady flow, tapered at
        /// its end.
        public func along(_ s: Double) -> Double {
            guard s >= start, s <= end else { return 0 }
            let taper: Double
            switch shape {
            case .thermal: return 1
            case .roundJet: taper = min(0.5 * (end - start), GroundCloudField.concentrationSpread * GroundCloud.jetSpread * end)
            case .wallJet: taper = min(0.5 * (end - start), 2 * thickness(end))
            case .stem: taper = 0.25 * (end - start)
            }
            let fade = taper > 0 ? 1 - PlumeMember.smoothstep(end - taper, end, s) : 1
            switch shape {
            case .roundJet: return s * fade
            case .wallJet: return (s * thickness(s)).squareRoot() * fade
            case .stem: return pow(s + virtualOrigin, 1.0 / 3) * fade
            case .thermal: return 1
            }
        }

        /// The wall jet's half-thickness at ρ.
        public func thickness(_ rho: Double) -> Double { radius + growth * max(rho - start, 0) }
        /// The stem's Gaussian radius at ℓ, and its virtual origin below its
        /// base (where a pure plume of its base's radius would start).
        public func stemRadius(_ l: Double) -> Double { radius + growth * max(l, 0) }
        public var virtualOrigin: Double { growth > 0 ? radius / growth : 0 }
        /// The round jet's concentration e-folding radius at x.
        public func jetRadius(_ x: Double) -> Double {
            GroundCloudField.concentrationSpread * GroundCloud.jetSpread * max(x, 1e-6)
        }

        /// The integral of `along` over the primitive (Gauss-Legendre, 64
        /// nodes in two halves either side of the taper's start).
        public func alongIntegral() -> Double {
            guard shape != .thermal else { return 1 }
            guard end > start else { return 0 }
            return GroundCloudField.gauss(start, end, along)
        }

        /// The shape's density at `p` (1/m³), its integral over the half-
        /// space above `ground` one: the shape and its image in the ground.
        /// With `displacement` (m, `LaunchTurbulence`) its level sets across
        /// the flow are moved out by that much (in by a negative one), the
        /// more the further from its core: its boundary turbulent.
        ///
        /// Moving the level sets of a convex profile by a zero-mean amount
        /// raises its integral on average. With the displacement's rms
        /// `spread` (m) the density is divided by that expected gain
        /// (`DisplacementGain`), so that the medium holds its mass however
        /// many octaves the pixel draws.
        public func density(at p: Vec3, displacement eta: Double = 0, spread: Double = 0) -> Double {
            guard norm > 0 else { return 0 }
            var d = unmirrored(p, eta)
            if ground.isFinite {
                guard p.z >= ground else { return 0 }
                d += unmirrored(Vec3(p.x, p.y, 2 * ground - p.z), eta)
            }
            guard spread > 0 else { return d * norm }
            return d * norm / DisplacementGain.gain(shape, spread: spread / levelScale(at: p))
        }

        /// The level-set coordinate q, displaced by `eta` m on a scale of
        /// `scale` m a unit of q: q − smoothstep(0, 1, q) η / scale, at least 0.
        static func displaced(_ q: Double, _ eta: Double, scale: Double) -> Double {
            guard eta != 0 else { return q }
            return max(q - PlumeMember.smoothstep(0, 1, q) * eta / max(scale, 1e-9), 0)
        }

        /// The length a unit of the level-set coordinate spans at `p` (m):
        /// the ring's core radius, the jet's or stem's e-folding radius, the
        /// wall jet's thickness.
        public func levelScale(at p: Vec3) -> Double {
            switch shape {
            case .thermal: return GroundCloudField.coreRadius * radius
            case .roundJet: return jetRadius(max(axial(p).x, start))
            case .wallJet: return thickness(max(radial(p).rho, start))
            case .stem: return stemRadius(max(axial(p).x, 0))
            }
        }

        /// The shape's peak density over its local maximum there, 0-1: how
        /// much of the air at `p` is the primitive's own (1 in its core).
        public func share(at p: Vec3) -> Double {
            switch shape {
            case .thermal:
                let q = ringCoordinate(p)
                return exp(-q * q)
            case .roundJet:
                let (x, r) = axial(p)
                guard x >= start, x <= end else { return 0 }
                let b = jetRadius(x)
                return exp(-r * r / (b * b))
            case .wallJet:
                let (rho, z) = radial(p)
                guard rho >= start, rho <= end, z >= 0 else { return 0 }
                return GroundCloudField.wallProfile(z / thickness(rho))
            case .stem:
                let (l, r) = axial(p)
                guard l >= 0, l <= end else { return 0 }
                let b = stemRadius(l)
                return exp(-r * r / (b * b))
            }
        }

        /// The thermal's distance from its ring's core, over the core's
        /// radius (its level-set coordinate).
        public func ringCoordinate(_ p: Vec3) -> Double {
            let d = p - origin
            let s = (d.x * d.x + d.y * d.y).squareRoot()
            let a = GroundCloudField.ringRadius * radius, sigma = GroundCloudField.coreRadius * radius
            let z = d.z / GroundCloudField.capStretch
            return ((s - a) * (s - a) + z * z).squareRoot() / max(sigma, 1e-9)
        }

        /// x along the axis and r off it.
        public func axial(_ p: Vec3) -> (x: Double, r: Double) {
            let d = p - origin, x = d.dot(axis)
            return (x, (d - axis * x).length)
        }

        /// ρ along the deck from the axis and z above it.
        public func radial(_ p: Vec3) -> (rho: Double, z: Double) {
            let d = p - origin
            return ((d.x * d.x + d.y * d.y).squareRoot(), d.z)
        }

        func unmirrored(_ p: Vec3, _ eta: Double = 0) -> Double {
            switch shape {
            case .thermal:
                let q = Self.displaced(ringCoordinate(p), eta, scale: GroundCloudField.coreRadius * radius)
                return exp(-q * q) / GroundCloudField.ringVolume(radius)
            case .roundJet:
                let (x, r) = axial(p)
                let m = along(x)
                guard m > 0 else { return 0 }
                let b = jetRadius(x), q = Self.displaced(r / b, eta, scale: b)
                return m * exp(-q * q) / (.pi * b * b)
            case .wallJet:
                let (rho, z) = radial(p)
                guard z >= 0, rho > 0 else { return 0 }
                let m = along(rho)
                guard m > 0 else { return 0 }
                let delta = thickness(rho), q = Self.displaced(z / delta, eta, scale: delta)
                return m * GroundCloudField.wallProfile(q) / (GroundCloudField.wallProfileIntegral * delta)
                    / (2 * .pi * rho)
            case .stem:
                let (l, r) = axial(p)
                let m = along(l)
                guard m > 0 else { return 0 }
                let b = stemRadius(l), q = Self.displaced(r / b, eta, scale: b)
                return m * exp(-q * q) / (.pi * b * b)
            }
        }

        /// A stable seed for its turbulence, from its shape and lobe.
        public var seed: UInt32 { PlumeTurbulence.seed("LR4 \(shape) \(lobe)") }

        // MARK: Flow

        /// The mean speed carrying the field at `p` (m/s): a jet's
        /// centreline speed there, the wall jet's layer's, a stem's rise, a
        /// thermal's.
        public func speed(at p: Vec3) -> Double {
            switch shape {
            case .thermal: return abs(flux)
            case .roundJet:
                let x = max(axial(p).x, start)
                return GroundCloud.jetVelocity * flux.squareRoot() / x
            case .wallJet:
                let rho = max(radial(p).rho, start)
                return GroundCloudField.wallSpeed(momentum: flux, rho: rho, thickness: thickness(rho))
            case .stem:
                let l = max(axial(p).x, 0)
                return GroundCloudField.plumeSpeed(buoyancy: flux, height: l + virtualOrigin)
            }
        }

        /// The flow's own size at `p` (m): a thermal's radius, a jet's or a
        /// stem's radius, the wall jet's thickness.
        public func size(at p: Vec3) -> Double {
            switch shape {
            case .thermal: return radius
            case .roundJet: return jetRadius(max(axial(p).x, start))
            case .wallJet: return thickness(max(radial(p).rho, start))
            case .stem: return stemRadius(max(axial(p).x, 0))
            }
        }
    }

    /// The expected gain in a shape's integral when its level sets are
    /// displaced by a zero-mean Gaussian amount of rms σ (in units of its
    /// level-set coordinate q): E[f(q′)], q′ = max(q − smoothstep(0, 1, q) x,
    /// 0), x ~ N(0, σ²), integrated over the shape's measure in q, over the
    /// undisplaced integral. Tabled every 0.05 of σ to 2 (linear between),
    /// by quadrature: q every 0.01 to 6, x over ±5σ in 61 points.
    /// - a thermal's ring torus: dV = 2π ε σc² q (a + σc q cos θ) dq dθ over
    ///   the half-plane s ≥ 0 (ring a = 0.35, core σc = 0.5, stretch ε = 1.2);
    /// - a round jet's or a stem's Gaussian disc: 2π q dq;
    /// - the wall jet's one-sided layer: dq.
    public enum DisplacementGain {
        public static let step = 0.05, count = 41

        public static func gain(_ shape: Shape, spread sigma: Double) -> Double {
            let table: [Double]
            switch shape {
            case .thermal: table = thermal
            case .roundJet, .stem: table = round
            case .wallJet: table = wall
            }
            let u = min(max(sigma / step, 0), Double(count - 1) - 1e-9)
            let i = Int(u), f = u - Double(i)
            return table[i] + (table[i + 1] - table[i]) * f
        }

        /// The torus's measure per unit q (R = 1).
        public static func ringMeasure(_ q: Double) -> Double {
            let a = ringRadius, sc = coreRadius, e = capStretch
            let around: Double
            if sc * q <= a {
                around = 2 * .pi * a
            } else {
                let t = acos(-a / (sc * q))
                around = 2 * a * t + 2 * sc * q * sin(t)
            }
            return 2 * .pi * e * sc * sc * q * around
        }

        static func table(profile: (Double) -> Double, measure: (Double) -> Double) -> [Double] {
            let dq = 0.01, n = 600
            let qs = (0..<n).map { (Double($0) + 0.5) * dq }
            let base = qs.reduce(0.0) { $0 + profile($1) * measure($1) }
            return (0..<count).map { j in
                let sigma = Double(j) * step
                guard sigma > 0 else { return 1 }
                let m = 61, span = 5 * sigma, dx = 2 * span / Double(m - 1)
                var total = 0.0, weights = 0.0
                for k in 0..<m {
                    let x = -span + Double(k) * dx
                    let w = exp(-0.5 * x * x / (sigma * sigma)) * (k == 0 || k == m - 1 ? 0.5 : 1)
                    weights += w
                    var sum = 0.0
                    for q in qs {
                        let qd = max(q - PlumeMember.smoothstep(0, 1, q) * x, 0)
                        sum += profile(qd) * measure(q)
                    }
                    total += w * sum
                }
                return total / weights / base
            }
        }

        public static let thermal = table(profile: { exp(-$0 * $0) }, measure: ringMeasure)
        public static let round = table(profile: { exp(-$0 * $0) }, measure: { 2 * .pi * $0 })
        public static let wall = table(profile: wallProfile, measure: { _ in 1 })
    }

    /// The wall jet's profile across it: P2's top hat at large distances,
    /// 1 − smoothstep(0.5, 1.5, q).
    public static func wallProfile(_ q: Double) -> Double { 1 - PlumeMember.smoothstep(0.5, 1.5, q) }

    /// The ring thermal's volume integral, ∫ exp(−q²) dV: 2π ε σ √π J, J =
    /// σ²/2 exp(−a²/σ²) + a σ √π/2 (1 + erf(a/σ)), a and σ its ring's and
    /// core's radii, ε the core's stretch.
    public static func ringVolume(_ r: Double) -> Double {
        let a = ringRadius * r, s = coreRadius * r
        let j = s * s / 2 * exp(-a * a / (s * s)) + a * s * Double.pi.squareRoot() / 2 * (1 + erf(a / s))
        return 2 * .pi * capStretch * s * Double.pi.squareRoot() * j
    }

    /// The wall jet's speed in a layer of half-thickness `thickness` at ρ
    /// that keeps all of the kinematic momentum flux `momentum`: M = 2πρ δ
    /// ∫p² u0² (a top hat's profile for the speed as for the concentration).
    public static func wallSpeed(momentum: Double, rho: Double, thickness: Double) -> Double {
        (max(momentum, 0) / (2 * .pi * max(rho, 1e-6) * max(thickness, 1e-6) * wallProfileSquare)).squareRoot()
    }

    /// A pure plume's top-hat speed `height` m above its virtual origin,
    /// of buoyancy flux `buoyancy` (m⁴/s³, π included): (5/6α)(9α F/10π)^⅓
    /// z^−⅓ (Morton, Taylor and Turner 1956).
    public static func plumeSpeed(buoyancy: Double, height: Double) -> Double {
        let a = plumeEntrainment
        return 5 / (6 * a) * pow(0.9 * a * max(buoyancy, 0) / .pi, 1.0 / 3) * pow(max(height, 1e-3), -1.0 / 3)
    }

    /// Gauss-Legendre over [a, b], 32 nodes in each half.
    static func gauss(_ a: Double, _ b: Double, _ f: (Double) -> Double) -> Double {
        let m = 0.5 * (a + b)
        return gauss32(a, m, f) + gauss32(m, b, f)
    }

    static func gauss32(_ a: Double, _ b: Double, _ f: (Double) -> Double) -> Double {
        let h = 0.5 * (b - a), c = 0.5 * (a + b)
        var sum = 0.0
        for (x, w) in legendre32 { sum += w * (f(c + h * x) + f(c - h * x)) }
        return sum * h
    }

    /// The 32-point rule's positive nodes and weights (computed once by
    /// Newton's method on P32).
    static let legendre32: [(Double, Double)] = {
        let n = 32
        var out: [(Double, Double)] = []
        for i in 1...(n / 2) {
            var x = cos(Double.pi * (Double(i) - 0.25) / (Double(n) + 0.5))
            var dp = 0.0
            for _ in 0..<100 {
                var p0 = 1.0, p1 = x
                for k in 2...n {
                    let p2 = ((2 * Double(k) - 1) * x * p1 - (Double(k) - 1) * p0) / Double(k)
                    p0 = p1
                    p1 = p2
                }
                dp = Double(n) * (x * p1 - p0) / (x * x - 1)
                let dx = p1 / dp
                x -= dx
                if abs(dx) < 1e-15 { break }
            }
            out.append((x, 2 / ((1 - x * x) * dp * dp)))
        }
        return out
    }()

    // MARK: The field

    /// Where P2's wall jet ends on the deck (`PlumeImpingement`): its radius
    /// from the pad's axis and its half-thickness there. The field's wall
    /// jet carries on from it.
    public struct WallJetHandover: Equatable {
        public var radius: Double
        public var thickness: Double

        public init(radius: Double, thickness: Double) {
            self.radius = radius
            self.thickness = thickness
        }

        /// P2's, from the members meeting `deck` (camera-relative, as P2
        /// has them): each one's reach from where its axis meets the deck
        /// and its thickness there, weighted by its share of the flow on
        /// the deck. Nil where none meets it.
        public static func p2(_ members: [PlumeMember], deck: PlumeImpingement) -> WallJetHandover? {
            var weight = 0.0, radius = 0.0, thickness = 0.0
            for m in members {
                guard let i = deck.meeting(m), let h = deck.distance(m) else { continue }
                let hit = m.exit + m.axis * h
                var d = hit - deck.centre
                d = d - deck.normal * d.dot(deck.normal)
                let w = max(m.flowFraction, 1e-6) * i.deckShare
                weight += w
                radius += w * (d.length + i.reach)
                thickness += w * i.thickness(m, h: h, rho: i.reach)
            }
            guard weight > 0 else { return nil }
            return WallJetHandover(radius: radius / weight, thickness: thickness / weight)
        }
    }

    public private(set) var primitives: [Primitive] = []
    /// The deck's wall jet's contents where P2 draws it (ahead of the
    /// handover): kg of exhaust, water, smoke and soot, and J.
    public private(set) var inPlume = Primitive(shape: .wallJet, lobe: .deck, origin: .zero, axis: .unitZ)
    /// The epoch the field is at.
    public let epoch: Epoch
    /// The air round it: the sounding, the deck's height and the humidity.
    public let air: AirProfile?
    public let deckHeight: Double
    public let humidity: LaunchHumidity.Profile

    /// The field of `cloud` at `epoch`: its state then (`GroundCloud.state
    /// (at:)`), each cloud carried on to `epoch` along its last velocity
    /// (at most one grid step, or a sample's interval in the past), in
    /// `air` with `humidity`; the deck's wall jet from P2's `handover` when
    /// P2 draws one.
    public init(_ cloud: GroundCloud, at epoch: Epoch, air: AirProfile?, deckHeight: Double,
                humidity: LaunchHumidity = .as506, handover: WallJetHandover? = nil) {
        self.epoch = epoch
        self.air = air
        self.deckHeight = deckHeight
        self.humidity = humidity.profile(air, surfaceHeight: deckHeight)
        let state = cloud.state(at: epoch)
        let dt = max(0, epoch - state.time)
        let ground = ambient(height: 0)
        // The start smoke is drawn inside the trench's clouds once their jets
        // run: the exits' through them, the chimney's (round the vehicle,
        // over the opening) taken in by the jets down it, half to each.
        // GroundCloud integrates it apart, so that P4's sprites stay as they
        // were.
        let running = state.lobes.contains { if case .trench = $0.kind { $0.exhaust > 0 } else { false } }
        func swept(_ l: GroundCloud.Lobe) -> [(side: Double, share: Double)]? {
            guard running, case .startSmoke(let side) = l.kind else { return nil }
            return side == 0 ? [(1, 0.5), (-1, 0.5)] : [(side, 1)]
        }
        for lobe in state.lobes where swept(lobe) == nil {
            build(lobe, dt: dt, ground: ground, handover: handover)
        }
        for lobe in state.lobes {
            guard let into = swept(lobe) else { continue }
            let a = ambient(height: lobe.centre.z)
            let heat = lobe.heat(density: a.rho, ambient: a.temperature)
            for (side, share) in into {
                guard let k = primitives.firstIndex(where: { $0.shape == .thermal && $0.lobe == .trench(side) })
                else { continue }
                primitives[k].exhaust += share * lobe.exhaust
                primitives[k].water += share * lobe.water
                primitives[k].smoke += share * lobe.smoke
                primitives[k].soot += share * lobe.soot
                primitives[k].heat += share * heat
            }
        }
        precondition(primitives.count <= Self.maximum)
    }

    /// The air `z` m above the deck: density, temperature, pressure and
    /// specific humidity.
    public func ambient(height z: Double) -> (rho: Double, temperature: Double, pressure: Double, humidity: Double) {
        if let a = air {
            let s = a.sample(altitude: deckHeight + z)
            return (s.density, s.temperature, s.pressure,
                    humidity.specificHumidity(height: z, temperature: s.temperature, pressure: s.pressure))
        }
        let s = LaunchHumidity.state(nil, height: z, surfaceHeight: deckHeight)
        return (s.pressure / (MoistAir.dryGasConstant * s.temperature), s.temperature, s.pressure,
                humidity.specificHumidity(height: z, temperature: s.temperature, pressure: s.pressure))
    }

    /// A trench jet's buoyancy flux at full thrust, all of it down the
    /// opening, in air of 1.17 kg/m³ at 300 K: the stem's fade's scale.
    static let fullBuoyancy: Double = {
        let s = GroundCloud.Sources(exhaust: LiftoffRise.flow, thrust: LiftoffRise.thrust, trench: 1, deck: 0,
                                    trenchWater: 0, deckWater: 0)
        return GroundCloud.side(s, density: 1.17, ambient: 300).buoyancy
    }()

    /// Lobe `l`'s primitives: its jet and stem (or the deck's wall jet),
    /// holding what flows in them at its last feed, and its cloud, holding
    /// the rest; carried on `dt` s along its velocity.
    ///
    /// A jet holds its steady flow's content, the flow over the speed that
    /// carries it, out to its front. GroundCloud's fronts run at half their
    /// jets' speeds (a starting jet's, Turner 1962), the deck's at its own
    /// layer's (`wallSpeed`), so the steady content is less than what the
    /// jet has carried; only while a flow rises faster than its jet fills is
    /// it more, and then the jet takes what the lobe has, one share for
    /// everything it carries.
    mutating func build(_ l: GroundCloud.Lobe, dt: Double, ground: (rho: Double, temperature: Double, pressure: Double,
                                                                   humidity: Double),
                        handover: WallJetHandover?) {
        let centreAir = ambient(height: l.centre.z)
        var cloud = Primitive(shape: .thermal, lobe: l.kind, origin: l.centre + l.velocity * dt, axis: .unitZ)
        cloud.radius = l.radius
        cloud.ground = 0
        cloud.exhaust = l.exhaust
        cloud.water = l.water
        cloud.smoke = l.smoke
        cloud.soot = l.soot
        cloud.heat = l.heat(density: centreAir.rho, ambient: centreAir.temperature)
        cloud.airHumidity = l.air > 0 ? l.vapour / l.air : centreAir.humidity
        cloud.flux = l.rise
        let f = l.feed

        // The share of `time` s of the feed's flow the lobe can give its
        // jet and stem: all of it, or what the lobe has, the same share of
        // everything it carries (so their mixture is the feed's).
        func share(time: Double) -> Double {
            guard time > 0 else { return 0 }
            var s = 1.0
            for (rate, held) in [(f.exhaust, cloud.exhaust), (f.water, cloud.water), (f.smoke, cloud.smoke),
                                 (f.soot, cloud.soot), (f.heat, max(cloud.heat, 0))] where rate > 0 {
                s = min(s, held / (rate * time))
            }
            return max(s, 0)
        }
        // Moves `time` s of the feed's flow from the cloud into `p`.
        func carry(_ p: inout Primitive, time t: Double) {
            p.exhaust = f.exhaust * t
            p.water = f.water * t
            p.smoke = f.smoke * t
            p.soot = f.soot * t
            p.heat = f.heat * t
            cloud.exhaust -= p.exhaust
            cloud.water -= p.water
            cloud.smoke -= p.smoke
            cloud.soot -= p.soot
            cloud.heat -= p.heat
        }

        switch l.kind {
        case .trench(let side) where f.momentum > 0 && f.exhaust > 0 && l.front > l.start:
            // The jet, from its exit to its front, its flow's mass per unit
            // length (1 + λ²) x / (7.0 √M) per kg/s carried.
            var jet = Primitive(shape: .roundJet, lobe: l.kind, origin: Vec3(0, 0, Self.jetHeight),
                                axis: Vec3(side, 0, 0))
            jet.start = l.start
            jet.end = l.front
            jet.ground = Self.grade
            jet.airHumidity = ground.humidity
            jet.flux = f.momentum
            let lambda = Self.concentrationSpread
            let k = (1 + lambda * lambda) / (GroundCloud.jetVelocity * f.momentum.squareRoot())
            let integral = jet.alongIntegral()
            jet.norm = 1 / integral
            let jetTime = k * integral
            // The stem, from the jet's end up into its cloud: its mass per
            // unit length the flow over its rise there, faded in as the cloud
            // lifts off and as the jet's buoyancy flux rises (so that neither
            // switches it on with its whole steady content).
            let base = Vec3(side * l.front, 0, Self.jetHeight)
            let top = cloud.origin - Vec3(0, 0, 0.5 * cloud.radius)
            let lift = PlumeMember.smoothstep(0, Self.stemLiftOff, (l.centre.z - l.radius) / max(l.radius, 1e-6))
            let buoyant = PlumeMember.smoothstep(0, Self.stemBuoyancy, f.buoyancy / Self.fullBuoyancy)
            var stem: Primitive?
            var stemTime = 0.0
            if lift * buoyant > 0, (top - base).length > 1 {
                var p = Primitive(shape: .stem, lobe: l.kind, origin: base, axis: (top - base).normalized)
                p.end = (top - base).length
                p.radius = jet.jetRadius(l.front)
                p.growth = Self.stemSpread
                p.ground = Self.grade
                p.airHumidity = ground.humidity
                p.flux = f.buoyancy
                p.norm = 1 / p.alongIntegral()
                let v = p.virtualOrigin
                stemTime = lift * buoyant * Self.gauss(0, p.end) { s in
                    p.along(s) / pow(s + v, 1.0 / 3) / Self.plumeSpeed(buoyancy: f.buoyancy, height: s + v)
                }
                stem = p
            }
            let s = share(time: jetTime + stemTime)
            carry(&jet, time: jetTime * s)
            primitives.append(jet)
            if var p = stem {
                carry(&p, time: stemTime * s)
                primitives.append(p)
            }
        case .deck where f.momentum > 0 && f.exhaust > 0 && l.front > l.start:
            // The wall jet: P2's as far as it draws it, then the field's.
            // Its mass per unit radius is the flow over its speed there
            // (∫p / ∫p²), the speed that keeps its momentum in its layer.
            let from = min(max(l.start, handover?.radius ?? l.start), l.front)
            var wall = Primitive(shape: .wallJet, lobe: l.kind, origin: .zero, axis: .unitZ)
            wall.start = from
            wall.end = l.front
            // P2's thickness where its wall jet ends, carried on at its growth
            // to where the field's starts (the jets' footprint, if beyond).
            wall.radius = handover.map { $0.thickness + PlumeImpingement.wallGrowth * (from - $0.radius) }
                ?? PadExhaust.wallThickness(rho: from, height: f.exitHeight)
            wall.growth = PlumeImpingement.wallGrowth
            wall.airHumidity = ground.humidity
            wall.flux = f.momentum
            func time(_ a: Double, _ b: Double, fade: (Double) -> Double) -> Double {
                guard b > a else { return 0 }
                return Self.gauss(a, b) { rho in
                    let d = wall.radius + wall.growth * (rho - from)
                    return Self.wallProfileIntegral / Self.wallProfileSquare * fade(rho)
                        / Self.wallSpeed(momentum: f.momentum, rho: rho, thickness: max(d, 1e-3))
                }
            }
            // What P2 draws, ahead of the handover: the same thickness law
            // run back from there.
            let p2Time = time(l.start, from) { _ in 1 }
            var wallTime = 0.0
            if wall.end > wall.start {
                wall.norm = 1 / wall.alongIntegral()
                wallTime = time(wall.start, wall.end) { rho in wall.along(rho) / (rho * wall.thickness(rho)).squareRoot() }
            }
            let s = share(time: p2Time + wallTime)
            if p2Time > 0 {
                var p2 = Primitive(shape: .wallJet, lobe: .deck, origin: .zero, axis: .unitZ)
                p2.start = l.start
                p2.end = from
                p2.growth = PlumeImpingement.wallGrowth
                carry(&p2, time: p2Time * s)
                inPlume = p2
            }
            if wallTime > 0 {
                carry(&wall, time: wallTime * s)
                primitives.append(wall)
            }
        default:
            break
        }
        guard cloud.source > 0 || cloud.heat > 0, cloud.radius > 0 else { return }
        cloud.norm = 1
        primitives.append(cloud)
    }

    // MARK: Totals

    /// The field's totals: kg of exhaust, water, smoke and soot, and J.
    public var totals: (exhaust: Double, water: Double, smoke: Double, soot: Double, heat: Double) {
        var t = (inPlume.exhaust, inPlume.water, inPlume.smoke, inPlume.soot, inPlume.heat)
        for p in primitives {
            t.0 += p.exhaust
            t.1 += p.water
            t.2 += p.smoke
            t.3 += p.soot
            t.4 += p.heat
        }
        return t
    }

    // MARK: Sampling

    /// What the field holds at `p` (site frame), its turbulence left out
    /// (the mean field): kg/m³ of what came from the pad, its water and
    /// soot, J/m³ of heat; the air's humidity there; and, saturation-
    /// adjusted, its temperature and condensate (kg/m³).
    public struct Sample: Equatable {
        public var source = 0.0, water = 0.0, soot = 0.0, heat = 0.0
        public var airHumidity = 0.0
        public var temperature = 0.0
        public var condensate = 0.0

        /// For `LaunchCloudOptics`.
        public var content: LaunchCloudOptics.Content {
            LaunchCloudOptics.Content(condensate: condensate, soot: soot, temperature: temperature)
        }
    }

    /// The mean field at `p`; with `density` the primitives' densities
    /// there (their turbulence's level sets displaced, `LaunchTurbulence`).
    public func sample(at p: Vec3, density: ((Primitive) -> Double)? = nil) -> Sample {
        var s = Sample()
        var shares = 0.0, humid = 0.0
        for prim in primitives {
            let d = density?(prim) ?? prim.density(at: p)
            s.source += prim.source * d
            s.water += prim.totalWater * d
            s.soot += prim.soot * d
            s.heat += prim.heat * d
            let w = prim.share(at: p)
            shares += w
            humid += w * prim.airHumidity
        }
        return Self.mixed(s, shares: shares, humidity: humid, ambient: ambient(height: p.z))
    }

    /// The mixture of `s` with the air: the primitives' own air (their
    /// shares, at most all of it) and the ambient's, at its temperature
    /// plus the heat, saturation-adjusted.
    static func mixed(_ s: Sample, shares: Double, humidity: Double,
                      ambient a: (rho: Double, temperature: Double, pressure: Double, humidity: Double)) -> Sample {
        var s = s
        let own = min(shares, 1), q = shares > 0 ? humidity / shares : a.humidity
        s.airHumidity = own * q + (1 - own) * a.humidity
        let mass = a.rho + s.source
        let qt = (s.water + s.airHumidity * a.rho) / mass
        let dry = a.temperature + s.heat / (mass * MoistAir.specificHeat)
        let adjusted = MoistAir.adjust(temperature: dry, water: qt, pressure: a.pressure)
        s.temperature = adjusted.temperature
        s.condensate = adjusted.condensate * mass
        return s
    }
}
