import Foundation

/// One engine's plume at one moment, derived from its exhaust
/// (`ExhaustSpec`), its flow and the air around it: what the plume and
/// particle renderers shape and light it from. Lengths in m from the
/// nozzle's exit plane, along its axis; angles in rad from the axis. In
/// vacuum the pressure ratio, the Knudsen number and the fully expanded jet
/// are infinite. Visual grade apart from the exit state; none of it feeds
/// the physics.
public struct PlumeState: Equatable {
    public enum Regime: String, Equatable {
        /// No flow.
        case off
        /// Overexpanded beyond Schmucker's criterion: the flow leaves the
        /// wall inside the nozzle.
        case separated
        /// Continuum, pe < pa, the flow attached to the exit.
        case overexpanded
        /// Continuum, pe ≥ pa.
        case underexpanded
        /// The ambient air too thin for sharp shocks (Knudsen 0.01 to 1):
        /// the shock structure fades.
        case transitional
        /// No ambient interaction worth the name (Knudsen above 1): the
        /// plume expands as into vacuum.
        case freeMolecular
    }

    /// The normal shock that ends the first cell of a strongly
    /// underexpanded jet.
    public struct MachDisk: Equatable {
        /// Lewis and Carlson's 0.69 De Me √(γ n).
        public var distance: Double
        /// Ashkenas and Sherman's 0.67 D* √(p0/pa) for the same chamber and
        /// throat, as a cross-check.
        public var sonicEstimate: Double
        /// Addy's sonic correlation, D_M = D* (0.36 √(p0/pa) - 1.17), halved
        /// (visual grade).
        public var radius: Double
        /// The shocked gas's column against a Mach disk at sea level, √(pa/p0),
        /// times `structureVisibility`: a disk far downstream in thin air is
        /// there but faint.
        public var luminosity: Double
    }

    public var regime: Regime
    /// The flow over the spec's rated flow.
    public var flowFraction: Double
    /// Nozzle stagnation pressure, Pa: the spec's times the flow fraction.
    public var chamberPressure: Double
    /// The exit plane: Mach number, pressure (Pa), temperature (K), density
    /// (kg/m³) and velocity (m/s).
    public var exitMach: Double
    public var exitPressure: Double
    public var exitTemperature: Double
    public var exitDensity: Double
    public var exitVelocity: Double
    /// The flow through the exit plane, kg/s: CEA's ideal flow at
    /// `chamberPressure`.
    public var massFlow: Double
    public var ambientPressure: Double
    /// n = pe/pa.
    public var pressureRatio: Double
    /// Schmucker's separation limit on pe/pa, (1.88 Me - 1)^-0.64.
    public var separationLimit: Double
    /// The ambient mean free path over the exit diameter.
    public var knudsen: Double
    /// 1 in continuum (Kn ≤ 0.01) falling to 0 in free-molecular flow (Kn
    /// ≥ 1), log-linear between: how sharp the shock cells and the Mach
    /// disk are.
    public var structureVisibility: Double
    /// The boundary's Mach number once the exit flow has expanded to the
    /// ambient pressure, the fully expanded jet's (Mj), and its diameter
    /// by mass conservation (Dj).
    public var jetMach: Double
    public var jetDiameter: Double
    /// The boundary's initial angle, ν(Mj) - ν(Me) + θ_lip, and its vacuum
    /// limit, ν_max - ν(Me) + θ_lip (Prandtl-Meyer).
    public var boundaryAngle: Double
    public var limitingAngle: Double
    /// Shock-cell length, 1.306 Dj √(Mj² - 1) (Pack; Tam and Tanna), and the
    /// number of cells along the potential core; 0 outside n = 0.3...5.
    public var shockCellLength: Double
    public var shockCellCount: Double
    /// Present for n > 2 while the structure is visible at all.
    public var machDisk: MachDisk?
    /// The far field (Simons): density A_p ρ* (r*/r)² cos^(2/(γ-1))(πθ / 2θ_lim)
    /// moving radially at the limiting velocity √(2γ/(γ-1) R T0/M), r* and
    /// ρ* the one-γ throat's; A_p carries `massFlow`.
    public var simonsCoefficient: Double
    public var limitingVelocity: Double
    public var throatRadius: Double
    public var throatDensity: Double
    /// 0 to the spec's fuel-rich fraction: the CO and H2 that burn with the
    /// air's oxygen, fading from 28 to 40 km (the ambient pressures there)
    /// as AS-501 to 503's plumes did.
    public var afterburning: Double
    /// Where the turbine-exhaust film ignites in air, behind its dark
    /// sheath: three-fourths of an exit diameter (AS-501 to 503's films);
    /// nil without a film or afterburning.
    public var flameFrontDistance: Double?
    /// The supersonic core's length in air (Lau's 4.2 + 1.1 Mj² jet
    /// diameters, on Thring and Newby's density-scaled diameter); 0 where
    /// there is no mixing layer (free-molecular, vacuum).
    public var potentialCoreLength: Double
    /// How far the plume glows, for the visual calibration: the longer of
    /// the free expansion's, to where Simons' axial density has cooled the
    /// gas isentropically to 1,000 K (0 for an exhaust already cooler at
    /// the exit), and, in air, the mixing jet's, to where its centreline,
    /// decaying as 1/x beyond the core, falls to 1,000 K from the
    /// afterburning flame's 2,300 K or the expanded jet's temperature (times
    /// `structureVisibility`).
    public var luminousLength: Double
    /// The exhaust's ratio of specific heats, for the far field.
    public var gamma: Double

    /// Simons' far-field density (kg/m³) at `r` m from the exit and `theta`
    /// rad off the axis; 0 beyond the limiting angle. Valid where r ≫ r*.
    public func density(atDistance r: Double, angle theta: Double) -> Double {
        guard simonsCoefficient > 0, r > 0, abs(theta) < limitingAngle else { return 0 }
        let k = 2 / (gamma - 1), q = throatRadius / r
        let c = cos(0.5 * Double.pi * abs(theta) / limitingAngle)
        return simonsCoefficient * throatDensity * q * q * pow(c, k)
    }
}

/// The structure of rocket plumes: the exit state from the chamber pressure
/// (which follows the flow), the flow regime, the boundary's angle, shock
/// cells, the Mach disk, the far field and afterburning. Sources and grades
/// in docs/exhaust-datasheet.md §3.
public enum PlumeModel {
    /// Molar gas constant, J/(mol K), and Boltzmann's constant, J/K.
    static let gasConstant = 8.314462618
    static let boltzmann = 1.380649e-23
    /// US 1976's effective collision diameter of air, m.
    static let collisionDiameter = 3.65e-10
    /// Sea-level pressure, Pa, the Mach disk's luminosity reference.
    static let seaLevel = 101_325.0
    /// Afterburning in full at and above the pressure of 28 km, gone at and
    /// below that of 40 km (US 1976): D5-15796-1 §4.1.1's films, luminous
    /// to 25-28 km, greying from 28 to 40 km, grey above.
    static let afterburningFull = 1_616.1, afterburningGone = 287.14   // Pa
    /// The afterburning flame's temperature and the visible limit, K (L).
    static let flameTemperature = 2_300.0, visibleTemperature = 1_000.0
    /// Knudsen numbers bounding the transitional regime.
    static let continuumKnudsen = 0.01, freeMolecularKnudsen = 1.0

    /// The plume of `spec` at `flowFraction` of its rated flow in `ambient`.
    public static func state(_ spec: ExhaustSpec, flowFraction: Double, ambient: AtmosphereState) -> PlumeState {
        let g = spec.exitGamma, f = max(0, flowFraction)
        let molar = spec.molarMass, R = gasConstant
        let me = NozzleFlow.supersonicMach(areaRatio: spec.areaRatio, gamma: g)
        let pc = spec.chamberPressure * f
        let pe = pc * NozzleFlow.pressureRatio(mach: me, gamma: g)
        let te = spec.exitTemperature
        let rhoE = pe * molar / (R * te)
        let ue = me * (g * R * te / molar).squareRoot()
        // The throat, sonic, on the same γ.
        let rStar = spec.exitRadius / spec.areaRatio.squareRoot()
        let tStar = spec.chamberTemperature * 2 / (g + 1)
        let pStar = pc * pow(2 / (g + 1), g / (g - 1))
        let rhoStar = pStar * molar / (R * tStar)
        // The flow through the exit: CEA's pe and Te make it CEA's ideal
        // flow at pc (the one-γ throat would overstate it by a few %).
        let mdot = rhoE * ue * Double.pi * spec.exitRadius * spec.exitRadius
        let pa = max(0, ambient.pressure), de = 2 * spec.exitRadius
        let n = pa > 0 ? pe / pa : .infinity
        let kn = knudsen(ambient, exitDiameter: de)
        let w = structureVisibility(knudsen: kn)
        let limit = separationLimit(exitMach: me)

        let nuE = NozzleFlow.prandtlMeyer(mach: me, gamma: g)
        let thetaLim = min(Double.pi, NozzleFlow.maximumTurning(gamma: g) - nuE + spec.lipHalfAngle)
        var mj = Double.infinity, dj = Double.infinity, delta0 = thetaLim
        if pa > 0 && pc > 0 {
            mj = max(1, NozzleFlow.mach(pressureRatio: min(1, pa / pc), gamma: g))
            dj = de * (NozzleFlow.areaRatio(mach: mj, gamma: g) / spec.areaRatio).squareRoot()
            delta0 = min(thetaLim, NozzleFlow.prandtlMeyer(mach: mj, gamma: g) - nuE + spec.lipHalfAngle)
        }

        let uLim = (2 * g / (g - 1) * R * spec.chamberTemperature / molar).squareRoot()
        let spread = 2 * Double.pi * simonsIntegral(gamma: g, limitingAngle: thetaLim)
        let ap = f > 0 ? mdot / (rhoStar * rStar * rStar * uLim * spread) : 0

        let regime: PlumeState.Regime
        if f == 0 || pc == 0 {
            regime = .off
        } else if kn >= freeMolecularKnudsen {
            regime = .freeMolecular
        } else if kn > continuumKnudsen {
            regime = .transitional
        } else if n < limit {
            regime = .separated
        } else if n < 1 {
            regime = .overexpanded
        } else {
            regime = .underexpanded
        }
        let continuum = regime == .separated || regime == .overexpanded || regime == .underexpanded

        let ab = f > 0 ? spec.fuelRichFraction * afterburningFade(pressure: pa) : 0
        var core = 0.0, lumAir = 0.0
        if w > 0 && regime != .off && dj.isFinite && ambient.density > 0 {
            // Thring and Newby's effective diameter scales the jet by the
            // square root of its density over the air's.
            let tj = spec.chamberTemperature * NozzleFlow.temperatureRatio(mach: mj, gamma: g)
            let rhoJ = pa * molar / (R * tj)
            let lau = 4.2 + 1.1 * mj * mj
            core = lau * dj * (rhoJ / ambient.density).squareRoot()
            let hot = ab > 0 ? max(tj, flameTemperature) : tj
            let ta = ambient.temperature
            if hot > visibleTemperature {
                lumAir = core * (hot - ta) / max(1, visibleTemperature - ta)
            }
        }
        // The free expansion cools as ρ^(γ-1): the density at 1,000 K.
        var lumFree = 0.0
        if te > visibleTemperature && ap > 0 {
            let rhoC = pc * molar / (R * spec.chamberTemperature)
            let rhoVisible = rhoC * pow(visibleTemperature / spec.chamberTemperature, 1 / (g - 1))
            lumFree = rStar * (ap * rhoStar / rhoVisible).squareRoot()
        }
        let luminous = max(lumFree, w * lumAir)

        var cell = 0.0, cells = 0.0
        if core > 0 && n >= 0.3 && n <= 5 && mj > 1 {
            cell = shockCellLength(jetMach: mj, jetDiameter: dj)
            cells = core / cell
        }
        var disk: PlumeState.MachDisk?
        if n > 2 && n.isFinite && w > 0 && pa > 0 {
            let throat = 2 * rStar, ratio = pc / pa
            disk = PlumeState.MachDisk(
                distance: machDiskDistance(exitDiameter: de, exitMach: me, gamma: g, pressureRatio: n),
                sonicEstimate: ashkenasSherman(throatDiameter: throat, pressureRatio: ratio),
                radius: max(0, 0.5 * throat * (0.36 * ratio.squareRoot() - 1.17)),
                luminosity: w * min(1, (pa / seaLevel).squareRoot()))
        }

        return PlumeState(
            regime: regime, flowFraction: f, chamberPressure: pc, exitMach: me, exitPressure: pe,
            exitTemperature: te, exitDensity: rhoE, exitVelocity: ue, massFlow: mdot, ambientPressure: pa,
            pressureRatio: n, separationLimit: limit, knudsen: kn, structureVisibility: w, jetMach: mj,
            jetDiameter: dj, boundaryAngle: delta0, limitingAngle: thetaLim, shockCellLength: cell,
            shockCellCount: cells, machDisk: disk, simonsCoefficient: ap, limitingVelocity: uLim,
            throatRadius: rStar, throatDensity: rhoStar, afterburning: ab,
            flameFrontDistance: spec.film != nil && ab > 0 && continuum ? 0.75 * de : nil,
            potentialCoreLength: core, luminousLength: luminous, gamma: g)
    }

    /// The plume of `thruster` on `part` in `ambient`, at its flow this step
    /// over its engine's rated flow; nil for a thruster `ApolloExhaust`
    /// does not know.
    public static func state(of thruster: Thruster, in part: VesselPart, ambient: AtmosphereState) -> PlumeState? {
        guard let engine = ApolloExhaust.engine(for: thruster, in: part) else { return nil }
        return state(engine.spec, flowFraction: thruster.massFlow / engine.ratedFlow, ambient: ambient)
    }

    /// Schmucker's criterion (1973, as Stark reviews it): the flow separates
    /// inside the nozzle when pe/pa falls below (1.88 Me - 1)^-0.64.
    public static func separationLimit(exitMach me: Double) -> Double {
        pow(max(1e-9, 1.88 * me - 1), -0.64)
    }

    /// The ambient mean free path (US 1976's hard spheres, kT/(√2 π σ² p))
    /// over the exit diameter; infinite in vacuum.
    public static func knudsen(_ ambient: AtmosphereState, exitDiameter de: Double) -> Double {
        guard ambient.pressure > 0 else { return .infinity }
        let area = 2.squareRoot() * Double.pi * collisionDiameter * collisionDiameter
        let lambda = boltzmann * max(ambient.temperature, 1) / (area * ambient.pressure)
        return lambda / de
    }

    /// 1 at Kn ≤ 0.01, 0 at Kn ≥ 1, linear in log Kn between.
    static func structureVisibility(knudsen kn: Double) -> Double {
        guard kn > continuumKnudsen else { return 1 }
        guard kn < freeMolecularKnudsen else { return 0 }
        return 1 - log(kn / continuumKnudsen) / log(freeMolecularKnudsen / continuumKnudsen)
    }

    /// Pack's shock-cell length as Tam and Tanna give it, 1.306 Dj √(Mj² - 1).
    public static func shockCellLength(jetMach mj: Double, jetDiameter dj: Double) -> Double {
        1.306 * dj * (mj * mj - 1).squareRoot()
    }

    /// Lewis and Carlson's (1964) Mach disk distance for a supersonic nozzle,
    /// 0.69 De Me √(γ n).
    public static func machDiskDistance(exitDiameter de: Double, exitMach me: Double, gamma g: Double,
                                        pressureRatio n: Double) -> Double {
        0.69 * de * me * (g * n).squareRoot()
    }

    /// Ashkenas and Sherman's (1966) sonic-orifice Mach disk distance,
    /// 0.67 D* √(p0/pa).
    public static func ashkenasSherman(throatDiameter d: Double, pressureRatio ratio: Double) -> Double {
        0.67 * d * ratio.squareRoot()
    }

    /// 1 at and above the pressure of 28 km, 0 at and below that of 40 km,
    /// linear in log p between.
    public static func afterburningFade(pressure p: Double) -> Double {
        guard p > afterburningGone else { return 0 }
        guard p < afterburningFull else { return 1 }
        return log(p / afterburningGone) / log(afterburningFull / afterburningGone)
    }

    /// ∫₀^θlim cos^(2/(γ-1))(πθ / 2θ_lim) sin θ dθ, by Simpson's rule: the
    /// far field's angular integral, which sets A_p.
    static func simonsIntegral(gamma g: Double, limitingAngle t: Double) -> Double {
        let k = 2 / (g - 1), n = 256, h = t / Double(n)
        var sum = 0.0
        for i in 0...n {
            let theta = Double(i) * h
            let c = max(0, cos(0.5 * Double.pi * theta / t))
            let weight: Double = i == 0 || i == n ? 1 : (i % 2 == 1 ? 4 : 2)
            sum += weight * pow(c, k) * sin(theta)
        }
        return sum * h / 3
    }
}
