import Foundation
import OrbitCore

/// An exhaust's family as the plume's look sees it.
public enum PlumeFamily: Int, CaseIterable {
    /// LOX/RP-1 (the F-1): sooty, an afterburning flame in air, the dark
    /// turbine-exhaust sheath under the exit.
    case kerosene
    /// LOX/LH2 (the J-2): clear gas; a Mach disk only where one forms, a
    /// faint condensate cone in sunlight.
    case hydrogen
    /// N2O4 and a hydrazine (SPS, SM and CM RCS, the S-IVB's APS): nearly
    /// invisible in vacuum.
    case hypergolic
    /// Solid motors (the LES's, the retros, the ullage motors): an
    /// incandescent aluminium-oxide core in white smoke.
    case solid
    /// Cold gas: nothing visible.
    case coldGas

    public init(_ f: ExhaustSpec.Family) {
        switch f {
        case .keroseneLOX: self = .kerosene
        case .hydrogenLOX: self = .hydrogen
        case .hypergolic: self = .hypergolic
        case .solidAluminized, .solidOther: self = .solid
        case .coldGas: self = .coldGas
        }
    }

    public init(_ s: PlumeStyle) {
        switch s {
        case .kerosene: self = .kerosene
        case .hydrogen: self = .hydrogen
        case .hypergolic: self = .hypergolic
        case .solid: self = .solid
        }
    }
}

/// One engine's plume as the ray march draws it: where it is, and the
/// parameters of its field of absorption, scattering and temperature in
/// its own coordinates, x along the exhaust from the exit plane and r off
/// the axis (m). Everything comes from P1's `PlumeState` where P1 gives the
/// number (the boundary's angle, the jet's diameter, the potential core,
/// the far field, afterburning, the flame front, shock cells, the Mach
/// disk); the optical constants are visual grade (L), in one place
/// (`PlumeLook.Optics`). The shader (PlumeShaders) evaluates the same field
/// as `sample(x:r:)`.
public struct PlumeMember: Equatable {
    // Placement.
    /// Camera-relative centre of the exit, m, and the unit exhaust direction.
    public var exit: Vec3
    public var axis: Vec3
    /// The drawn exit's radius, m.
    public var exitRadius: Double
    public var family: PlumeFamily
    /// An attitude or ullage jet (impostor unless the camera is close).
    public var isJet = false
    /// The scene vessel it belongs to (nil for look-dev engines).
    public var vesselID: UUID?
    /// How far it reaches downstream and upstream of the exit (the base
    /// glow), m: the proxy's extent.
    public var length = 0.0
    public var upstream = 0.0

    // Shape: R(x) = re + growth (1 - e^(-x/ℓ)) + spread max(0, x - xc).
    public var radiusGrowth = 0.0
    public var shapeLength = 1.0
    public var farSpread = 0.0
    /// The potential core's length (m); effectively infinite without
    /// mixing (vacuum).
    public var coreLength = 1e9
    /// 0 a continuum jet in its boundary, 1 Simons' free expansion.
    public var vacuumBlend = 0.0
    /// Simons' exponent 2/(γ-1), the limiting angle (rad) and the virtual
    /// source's distance upstream of the exit (m).
    public var simonsExponent = 8.0
    public var limitingAngle = 1.5
    public var sourceOffset = 1.0
    /// How far the air confines the free expansion to the jet's boundary
    /// (P1's structure visibility in air, 0 in vacuum): the Simons field
    /// is cut beyond R(x) as much.
    public var confinement = 0.0

    // The gas (soot in it): absorption at the exit (1/m), scattering albedo.
    public var gasExtinction = 0.0
    public var gasAlbedo = 0.0
    /// Where the afterburning flame has burnt the soot out (m; 0 never):
    /// the gas thins to `Optics.burntSoot` of itself over half that again,
    /// leaving the condensate's white trail.
    public var sootBurnout = 0.0
    /// The core's temperature at the exit (K) and the exponent of its
    /// cooling on the free expansion's dilution (γ - 1 in vacuum, 0 bounded).
    public var coreTemperature = 0.0
    public var expansionCooling = 0.0
    /// The afterburning flame's temperature (0 for none), where it starts
    /// (m), the ambient temperature (K) and its strength (0-1).
    public var flameTemperature = 0.0
    public var flameStart = 0.0
    public var ambientTemperature = 250.0
    public var afterburning = 0.0
    /// The afterburning flame's own decay length (m): it holds its
    /// temperature as Ta + (Tf - Ta) min(1, ℓ / x), longer than the inert
    /// jet's core (`Optics.flameHold`).
    public var flameHold = 0.0
    /// The flame brush's spread, dR/dx from the flame's start.
    public var flameSpread = 0.0

    // The fuel-rich film (the F-1's turbine exhaust): absorption (1/m), its
    // thickness over R, how far it runs (m), its temperature (K).
    public var sheathExtinction = 0.0
    public var sheathThickness = 0.15
    public var sheathLength = 0.0
    public var sheathTemperature = 0.0

    // Particles (alumina in solids, condensate in hydrogen and hypergols):
    // extinction at the exit (1/m), albedo, temperature at the exit (K, 0
    // cold), the radiative cooling length (m), their cone's half-angle
    // (rad) and virtual source (m), where they appear (m).
    public var particleExtinction = 0.0
    public var particleAlbedo = 0.9
    public var particleTemperature = 0.0
    public var particleCooling = 1e9
    public var particleAngle = 0.3
    public var particleOffset = 1.0
    public var particleOnset = 0.0
    /// Henyey-Greenstein asymmetry of the scattering.
    public var phaseG = 0.4

    // Structure.
    public var shockCellLength = 0.0
    public var shockCellCount = 0.0
    public var shockStrength = 0.0
    /// The base's recirculating gas (absorption, 1/m) and its temperature (K).
    public var baseExtinction = 0.0
    public var baseTemperature = 0.0
    public var machDiskDistance = 0.0
    public var machDiskRadius = 0.0
    public var machDiskExtinction = 0.0
    public var machDiskTemperature = 0.0

    // Turbulence: eddy size at the exit (m), the eddies' visual speed (m/s),
    // the noise's depth (0-1).
    public var noiseScale = 1.0
    public var eddySpeed = 10.0
    public var turbulence = 0.0

    /// An emission-only glow, cd/m² seen through the axis (the readable
    /// floor, the legacy look, the near-exit light), fading to nothing at
    /// `glowLength` m.
    public var glow = Photometry.RGB(0, 0, 0)
    public var glowLength = 0.0

    public init(exit: Vec3, axis: Vec3, exitRadius: Double, family: PlumeFamily) {
        self.exit = exit
        self.axis = axis
        self.exitRadius = exitRadius
        self.family = family
    }

    public var exitDiameter: Double { 2 * exitRadius }

    /// The jet's radius at x (m).
    public func radius(atX x: Double) -> Double {
        let xp = max(x, 0)
        let r = exitRadius + radiusGrowth * (1 - exp(-xp / max(shapeLength, 1e-6)))
            + farSpread * max(0, xp - coreLength) + flameSpread * max(0, xp - flameStart)
        return max(r, 0.2 * exitRadius)
    }

    /// The half-angle (rad) about the virtual source where Simons' profile
    /// cos^k(πθ / 2θ_lim) falls to `fraction` of the axis's.
    public func simonsAngle(fraction: Double) -> Double {
        let c = pow(fraction, 1 / max(simonsExponent, 1e-3))
        return min(limitingAngle, 2 * limitingAngle / Double.pi * acos(min(1, c)))
    }

    /// The radius (m) beyond which the field is negligible at x: what the
    /// proxy holds and the shader rejects beyond.
    public func extent(atX x: Double) -> Double {
        if x < 0 { return baseExtinction > 0 && x >= -upstream ? 1.6 * exitRadius : exitRadius }
        var e = 1.55 * radius(atX: x)
        if vacuumBlend > 0.02 && confinement < 0.98 {
            let theta = min(simonsAngle(fraction: 0.01), 85 * Double.pi / 180)
            e = max(e, (x + sourceOffset) * tan(theta))
        }
        if particleExtinction > 0 && vacuumBlend > 0.02 && confinement < 0.98 {
            e = max(e, (x + particleOffset) * tan(min(particleAngle, 85 * Double.pi / 180)))
        }
        if machDiskExtinction > 0 && abs(x - machDiskDistance) < machDiskRadius + exitDiameter {
            e = max(e, 1.1 * machDiskRadius)
        }
        return e
    }

    /// What the field holds at one point.
    public struct Sample: Equatable {
        /// Absorption and scattering coefficients, 1/m.
        public var absorption = 0.0
        public var scattering = 0.0
        /// Emitted luminance per metre of path, cd/m³ (absorption times
        /// the blackbody's at each phase's temperature, plus the glow).
        public var emission = Photometry.RGB(0, 0, 0)

        public var extinction: Double { absorption + scattering }

        public static func + (a: Sample, b: Sample) -> Sample {
            Sample(absorption: a.absorption + b.absorption, scattering: a.scattering + b.scattering,
                   emission: Photometry.RGB(a.emission.r + b.emission.r, a.emission.g + b.emission.g,
                                            a.emission.b + b.emission.b))
        }
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The field at x along the axis and r off it (m), its turbulence
    /// left out (the noise's mean): the shader's `plume_sample`, line by line.
    public func sample(x: Double, r: Double) -> Sample {
        var s = Sample()
        let de = exitDiameter, re = exitRadius
        func add(_ sigma: Double, albedo: Double, temperature: Double) {
            guard sigma > 0 else { return }
            let a = sigma * (1 - albedo)
            s.absorption += a
            s.scattering += sigma * albedo
            if temperature > 0 {
                let b = PlumeLook.blackbody(temperature)
                s.emission = Photometry.RGB(s.emission.r + a * b.r, s.emission.g + a * b.g, s.emission.b + a * b.b)
            }
        }
        // The base's recirculation, upstream of the exit too.
        if baseExtinction > 0 && x > -upstream && x < 0.4 * de {
            let m = (1 - Self.smoothstep(0.6, 1.0, r / (1.6 * re))) * Self.smoothstep(-upstream, -0.5 * upstream, x)
                * (1 - Self.smoothstep(0, 0.4 * de, x))
            add(baseExtinction * m, albedo: 0, temperature: baseTemperature)
        }
        guard x >= 0, x <= length else { return s }
        let rx = radius(atX: x), q = r / rx
        let w = min(max(0.06 + 0.45 * x / (x + 6 * de), 0.06), 0.5)
        let pc = 1 - Self.smoothstep(1 - w, 1 + w, q)
        let theta = atan2(r, x + sourceOffset)
        let confine = 1 - confinement * Self.smoothstep(1, 1.5, q)
        let pv = theta < limitingAngle ? pow(cos(0.5 * Double.pi * theta / limitingAngle), simonsExponent) * confine : 0
        let v = vacuumBlend
        let profile = pc + (pv - pc) * v
        let d2 = (x + sourceOffset) * (x + sourceOffset) + r * r
        let dilution = (re / rx) * (re / rx) * (1 - v) + sourceOffset * sourceOffset / max(d2, 1e-9) * v
        // Everything fades out over the last 30 % of the length.
        let fade = 1 - Self.smoothstep(0.7 * length, length, x)
        let rho = profile * dilution * fade
        let mixing = x > coreLength ? coreLength / x : 1
        var cells = 1.0
        if shockCellLength > 0 && x < shockCellCount * shockCellLength {
            cells += shockStrength * cos(2 * Double.pi * x / shockCellLength)
                * exp(-x / max(shockCellCount * shockCellLength, 1e-6))
        }
        // The gas: the core, and the afterburning flame in the mixing
        // layer, which eats into the core down to its end.
        if gasExtinction > 0 {
            let tCore = ambientTemperature + (coreTemperature - ambientTemperature) * mixing
                * pow(max(dilution, 1e-12), expansionCooling)
            var t = tCore * cells
            if flameTemperature > 0 && afterburning > 0 {
                let fx = Self.smoothstep(flameStart - 0.25 * de, flameStart + 0.25 * de, x)
                let qf = 0.85 * max(0, 1 - x / max(coreLength, de))
                let fr = Self.smoothstep(qf - 0.15, qf + 0.05, q)
                let hold = x > flameHold ? flameHold / x : 1
                let tFlame = ambientTemperature + (flameTemperature - ambientTemperature) * hold
                t += (max(t, tFlame) - t) * afterburning * fx * fr
            }
            var burnt = 1.0
            if sootBurnout > 0 {
                burnt -= (1 - PlumeLook.Optics.burntSoot) * Self.smoothstep(sootBurnout, 1.5 * sootBurnout, x)
            }
            add(gasExtinction * rho * cells * burnt, albedo: gasAlbedo, temperature: t)
        }
        // The film, a dark band at the edge until it burns.
        if sheathExtinction > 0 && x < sheathLength + 0.5 * de {
            let t = sheathThickness
            let band = Self.smoothstep(1 - t - 0.06, 1 - t + 0.04, q) * (1 - Self.smoothstep(1 + 0.4 * t, 1 + t, q))
            let along = 1 - Self.smoothstep(sheathLength - 0.3 * de, sheathLength + 0.3 * de, x)
            add(sheathExtinction * band * along * min(1, dilution) * fade, albedo: gasAlbedo,
                temperature: sheathTemperature)
        }
        // Particles: alumina, or condensate.
        if particleExtinction > 0 {
            let tp = atan2(r, x + particleOffset)
            let ppv = tp < particleAngle ? pow(cos(0.5 * Double.pi * tp / particleAngle), 2) * confine : 0
            let pp = pc + (ppv - pc) * v
            let dp2 = (x + particleOffset) * (x + particleOffset) + r * r
            let dil = (re / rx) * (re / rx) * (1 - v) + particleOffset * particleOffset / max(dp2, 1e-9) * v
            let on = particleOnset > 0 ? Self.smoothstep(0.5 * particleOnset, particleOnset, x) : 1
            let temp = particleTemperature > 0 ? particleTemperature * pow(1 + 3 * x / particleCooling, -1.0 / 3) : 0
            // Hot alumina absorbs (and so glows) more than its white smoke.
            let albedo = particleAlbedo + (PlumeLook.Optics.hotAluminaAlbedo - particleAlbedo)
                * Self.smoothstep(1_400, 2_000, temp)
            add(particleExtinction * pp * dil * on * fade, albedo: albedo, temperature: temp)
        }
        // The Mach disk: a lens of shocked, hot gas.
        if machDiskExtinction > 0 {
            let dx = (x - machDiskDistance) / (0.25 * machDiskRadius + 0.05 * de)
            let m = exp(-dx * dx) * (1 - Self.smoothstep(0.8, 1.1, r / max(machDiskRadius, 1e-6)))
            add(machDiskExtinction * m, albedo: 0, temperature: machDiskTemperature)
        }
        // The glow, emission only.
        if glowLength > 0 {
            let along = pow(max(1 - x / glowLength, 0), 1.6) * Self.smoothstep(0, 0.03 * glowLength, x)
            let k = along * (1 - Self.smoothstep(0.7, 1.0, q)) / (2 * rx)
            s.emission = Photometry.RGB(s.emission.r + glow.r * k, s.emission.g + glow.g * k,
                                        s.emission.b + glow.b * k)
        }
        return s
    }

    /// The field at a camera-relative point.
    public func sample(at p: Vec3) -> Sample {
        let d = p - exit, x = d.dot(axis)
        let r = (d - axis * x).length
        return sample(x: x, r: r)
    }
}

/// The plumes' look (track P2): `PlumeMember`s from the scene's emitters
/// and P1's plume model, the legacy look, the readable floor, the
/// blackbody the shader uses and a reference march for the tests.
public enum PlumeLook {
    /// The visual constants (L, calibrated to photographs; see
    /// docs/look/plumes.md): optical depths across the exit at the rated
    /// flow, albedos, phase asymmetries.
    public enum Optics {
        /// Soot's optical depth straight across an F-1's exit at the rated
        /// flow, per unit of the spec's soot index: thick, as the photos'
        /// opaque yellow flame.
        public static let sootDepth = 8.0
        /// Soot's single-scattering albedo, and the clear gases' (none).
        public static let sootAlbedo = 0.25
        /// The film's optical depth through its thickness (0.15 of the
        /// jet's radius), and that thickness.
        public static let sheathDepth = 1.5, sheathThickness = 0.15
        /// A solid's alumina: optical depth across the exit per unit of
        /// alumina mass fraction, albedo; its gas phase's depth (HCl, soot).
        public static let aluminaDepth = 80.0, aluminaAlbedo = 0.9, solidGasDepth = 0.4
        /// The F-1's exhaust condensing (water ice in the expansion, water in
        /// the humid air beyond the flame): optical depth across the exit,
        /// albedo (greyed by soot). The white cloud of the ALOTS frames at
        /// staging (S69-39957) and the white column below the flame at
        /// liftoff (S68-56050).
        public static let keroseneCondensate = 3.0, keroseneCondensateAlbedo = 0.8
        /// What is left of the soot once the afterburning flame has burnt it.
        public static let burntSoot = 0.25
        /// The afterburning flame's decay length over P1's potential core:
        /// burning on, the F-1's flame stays above about 1,900 K (blown out
        /// white against sunlit paint) for some 35-40 m at the pad
        /// (S68-56050, Apollo 8 at T+10 s), twice the inert jet's.
        public static let flameHold = 2.0
        /// The turbulent flame brush's spread from the flame front, dR/dx:
        /// the five F-1 flames merge into one column within 15-20 m.
        public static let flameSpread = 0.035
        /// Alumina's albedo while incandescent (above about 2,000 K).
        public static let hotAluminaAlbedo = 0.5
        /// Condensate (ice, droplets) far downstream of a clear exhaust:
        /// optical depth across the exit, albedo, onset in exit diameters.
        public static let hydrogenCondensate = 0.01, hypergolicCondensate = 0.005
        public static let condensateAlbedo = 0.95
        public static let hydrogenOnset = 4.0, hypergolicOnset = 2.0
        /// The clear gases' own depths: a trace that keeps their core's
        /// light physical (nearly nothing).
        public static let hydrogenGasDepth = 0.002, hypergolicGasDepth = 0.004
        /// The near-exit light of a clear exhaust, cd/m² through the axis,
        /// over 1.5 exit diameters: OH and NH bands (L, about invisible in
        /// daylight).
        public static let hydrogenGlow = Photometry.RGB(18, 22, 40)
        public static let hypergolicGlow = Photometry.RGB(60, 34, 26)
        /// Henyey-Greenstein g by family.
        public static func phaseG(_ f: PlumeFamily) -> Double {
            switch f {
            case .kerosene: 0.35
            case .solid: 0.6
            case .hydrogen, .hypergolic: 0.6
            case .coldGas: 0.5
            }
        }
        /// The base's recirculation, kerosene at high n: optical depth over
        /// an exit diameter and temperature (L).
        public static let baseDepth = 1.5, baseTemperature = 1_750.0
        /// The Mach disk's emissivity by family.
        public static func machDiskEmissivity(_ f: PlumeFamily) -> Double {
            switch f {
            case .kerosene, .solid: 0.5
            case .hydrogen: 0.02
            case .hypergolic: 0.05
            case .coldGas: 0
            }
        }
        /// A supersonic jet's far-field spread, dR/dx beyond the core.
        public static let farSpread = 0.06
        /// The shock cells' modulation of the core's temperature and density.
        public static let shockStrength = 0.3
    }

    /// M1.5's readable floor (decision 19): 0.3 of a white surface facing
    /// the Sun at 1 AU, cd/m² (E⊙/π).
    public static let readableFloor = 0.3 * Photometry.solarIlluminanceAt1AU / Double.pi

    /// The family's colour at a luminance of 1 (M1.5's look table).
    public static func color(_ f: PlumeFamily) -> Photometry.RGB {
        let c: Photometry.RGB
        switch f {
        case .kerosene: c = Photometry.RGB(1.0, 0.52, 0.16)
        case .hydrogen: c = Photometry.RGB(0.55, 0.62, 1.0)
        case .solid: c = Photometry.RGB(1.0, 0.82, 0.58)
        case .hypergolic, .coldGas: c = Photometry.RGB(1.0, 0.5, 0.4)
        }
        return c.scaled(by: 1 / c.luminance)
    }

    // MARK: Members

    /// The member of one emitter: from P1's model for an engine the exhaust
    /// library knows (`physical`), else M1.5's look (`legacy`); nil when it
    /// gives no flow.
    public static func member(_ e: RenderScene.Emitter, settings: PlumeSettings) -> PlumeMember? {
        guard e.thrustFraction > 0.005 || e.flowFraction > 0.005, e.exitRadius > 0 else { return nil }
        var m: PlumeMember
        if settings.model == .physical, let engine = ApolloExhaust.engine(thruster: e.name, part: e.part) {
            let state = PlumeModel.state(engine.spec, flowFraction: e.flowFraction, ambient: e.ambient)
            guard state.regime != .off else { return nil }
            m = member(engine.spec, state: state, exit: e.exit, axis: e.axis, exitRadius: e.exitRadius,
                       ambient: e.ambient)
        } else {
            m = legacy(exit: e.exit, axis: e.axis, radius: e.exitRadius, family: PlumeFamily(e.style),
                       fraction: e.thrustFraction, pressureRatio: e.pressureRatio, jet: e.isJet)
        }
        m.isJet = e.isJet
        m.vesselID = e.vesselID
        if settings.readable { applyReadableFloor(&m) }
        return m
    }

    /// A look-dev engine's members (one, or a ring and its centre).
    public static func members(_ t: PlumeTestEngine, in frame: EffectTargetFrame,
                               settings: PlumeSettings) -> [PlumeMember] {
        guard let engine = ApolloExhaust.byTableRow[t.engine] else { return [] }
        var air = USStandardAtmosphere1976().state(altitude: t.altitude)
        if let p = t.pressure {
            air = p > 0 ? RenderScene.Emitter.air(pressureRatio: p / 101_325) : .vacuum
        }
        let state = PlumeModel.state(engine.spec, flowFraction: t.flowFraction, ambient: air)
        guard state.regime != .off else { return [] }
        let axis = frame.direction(t.axis), centre = frame.point(t.position)
        var exits: [Vec3] = t.centre || t.ring == 0 ? [centre] : []
        if t.ring > 0 {
            let u = VisualShape.defaultReference(for: axis).normalized, v = axis.cross(u).normalized
            let w = u.cross(axis).normalized
            for i in 0..<t.ring {
                let a = 2 * Double.pi * (Double(i) + 0.5) / Double(t.ring)
                exits.append(centre + w * (t.ringRadius * cos(a)) + v * (t.ringRadius * sin(a)))
            }
        }
        return exits.map { exit in
            var m = settings.model == .physical
                ? member(engine.spec, state: state, exit: exit, axis: axis, exitRadius: engine.spec.exitRadius,
                         ambient: air)
                : legacy(exit: exit, axis: axis, radius: engine.spec.exitRadius,
                         family: PlumeFamily(engine.spec.family), fraction: t.flowFraction,
                         pressureRatio: air.pressure / 101_325, jet: false)
            if settings.readable { applyReadableFloor(&m) }
            return m
        }
    }

    /// The member of an engine of `spec` in `state`, its exit (drawn) at
    /// `exit` of `exitRadius`, exhausting along `axis`, in `ambient`.
    public static func member(_ spec: ExhaustSpec, state s: PlumeState, exit: Vec3, axis: Vec3, exitRadius re: Double,
                              ambient: AtmosphereState) -> PlumeMember {
        let family = PlumeFamily(spec.family)
        var m = PlumeMember(exit: exit, axis: axis, exitRadius: re, family: family)
        let de = 2 * re, f = min(max(s.flowFraction, 0), 1.25)
        let n = s.pressureRatio, w = s.structureVisibility
        let inAir = s.ambientPressure > 0 && n.isFinite
        // How far the plume is from a bounded jet: by the pressure ratio,
        // and wholly free where the air is too thin for a boundary.
        var v = inAir ? min(max(log10(max(n, 1)) / 3.5, 0), 1) : 1
        v = max(v, 1 - w)
        m.vacuumBlend = v
        m.confinement = inAir ? w : 0
        m.simonsExponent = 2 / (s.gamma - 1)
        m.limitingAngle = max(0.2, s.limitingAngle)
        let half = m.simonsAngle(fraction: 0.5)
        m.sourceOffset = re / tan(max(half, 0.05))
        m.ambientTemperature = inAir ? max(ambient.temperature, 150) : 0

        // The boundary: from the lip at δ0 towards the fully expanded jet,
        // which a strongly underexpanded jet overshoots.
        let slope = tan(min(max(s.boundaryAngle, -0.5), 80 * Double.pi / 180))
        if inAir && s.jetDiameter.isFinite {
            let overshoot = n > 1 ? 1 + 0.2 * min(1, log10(n) / 2) : 1
            let growth = 0.5 * s.jetDiameter * overshoot - re
            m.radiusGrowth = abs(growth) < 1e-3 * re ? 0 : growth
            m.shapeLength = m.radiusGrowth * slope > 0 ? min(max(m.radiusGrowth / slope, 0.2 * re), 200 * de) : de
        } else {
            // Free expansion: the half-mass cone.
            m.radiusGrowth = 1e5
            m.shapeLength = 1e5 / tan(max(half, 0.05))
        }
        // Beyond the potential core the jet spreads as it mixes; a strongly
        // underexpanded one, whose core runs kilometres, from a few of its
        // boundary's lengths on (the billowing plume of S69-39957).
        m.coreLength = s.potentialCoreLength > 0 ? min(s.potentialCoreLength, max(3 * m.shapeLength, 10 * de))
            : 1e9
        m.farSpread = s.potentialCoreLength > 0 ? Optics.farSpread * w : 0

        // The gas.
        let tj = inAir && s.jetMach.isFinite
            ? spec.chamberTemperature * NozzleFlow.temperatureRatio(mach: s.jetMach, gamma: s.gamma) : 0
        m.coreTemperature = n < 1 ? max(s.exitTemperature, tj) : s.exitTemperature
        m.expansionCooling = v * (s.gamma - 1)
        m.gasAlbedo = family == .kerosene ? Optics.sootAlbedo : (family == .solid ? 0.5 : 0)
        let gasDepth: Double
        switch family {
        case .kerosene: gasDepth = Optics.sootDepth * spec.sootIndex
        case .solid: gasDepth = Optics.solidGasDepth
        case .hydrogen: gasDepth = Optics.hydrogenGasDepth
        case .hypergolic: gasDepth = Optics.hypergolicGasDepth
        case .coldGas: gasDepth = 0
        }
        m.gasExtinction = gasDepth / de * f
        if s.afterburning > 0 && spec.fuelRichFraction > 0 {
            m.afterburning = min(1, s.afterburning / spec.fuelRichFraction)
            m.flameTemperature = PlumeModel.flameTemperature
            m.flameStart = s.flameFrontDistance ?? (family == .kerosene ? 0.75 * de : 0.25 * de)
            m.flameHold = Optics.flameHold * max(s.potentialCoreLength, de)
            m.flameSpread = Optics.flameSpread * m.afterburning * w * (1 - v)
        }
        // The film.
        if let film = spec.film {
            m.sheathExtinction = Optics.sheathDepth / (Optics.sheathThickness * re) * f * (1 - 0.7 * v)
            m.sheathThickness = Optics.sheathThickness
            m.sheathLength = s.flameFrontDistance ?? 3 * de
            m.sheathTemperature = film.temperature
        }
        // Particles.
        switch family {
        case .solid where spec.aluminaFraction > 0:
            m.particleExtinction = Optics.aluminaDepth * spec.aluminaFraction / de * f
            m.particleAlbedo = Optics.aluminaAlbedo
            // They leave hotter than the gas (thermal lag), and cool by
            // radiation: τ = ρ c d / (6 ε σ T³) for 3 µm alumina at ε 0.3.
            let tp = s.exitTemperature + 0.5 * (spec.chamberTemperature - s.exitTemperature)
            m.particleTemperature = tp
            let tau = 3_950.0 * 1_300 * 3e-6 / (6 * 0.3 * 5.670374e-8 * tp * tp * tp)
            m.particleCooling = max(s.exitVelocity * tau, de)
            m.particleAngle = spec.lipHalfAngle + 5 * Double.pi / 180
        case .hydrogen:
            m.particleExtinction = Optics.hydrogenCondensate / de * f
            m.particleAlbedo = Optics.condensateAlbedo
            m.particleOnset = Optics.hydrogenOnset * de
            m.particleAngle = half
        case .hypergolic:
            m.particleExtinction = Optics.hypergolicCondensate / de * f
            m.particleAlbedo = Optics.condensateAlbedo
            m.particleOnset = Optics.hypergolicOnset * de
            m.particleAngle = half
        case .kerosene:
            m.particleExtinction = Optics.keroseneCondensate / de * f
            m.particleAlbedo = Optics.keroseneCondensateAlbedo
            m.particleAngle = half
            // In the expansion it condenses a few diameters out; in dense
            // air beyond the flame, as the exhaust mixes and cools.
            let flameEnd = s.luminousLength > 0 ? Optics.flameHold * s.luminousLength : 10 * de
            m.particleOnset = 3 * de + (max(0.5 * flameEnd, 3 * de) - 3 * de) * (1 - v)
        default:
            break
        }
        if family == .kerosene && m.afterburning > 0 && s.luminousLength > 0 {
            m.sootBurnout = 0.6 * Optics.flameHold * s.luminousLength
        }
        m.particleOffset = re / tan(max(m.particleAngle * 0.5, 0.05))
        m.phaseG = Optics.phaseG(family)

        // Structure.
        if s.shockCellLength > 0 {
            m.shockCellLength = s.shockCellLength
            m.shockCellCount = s.shockCellCount
            m.shockStrength = Optics.shockStrength * w
        }
        if family == .kerosene && inAir {
            let b = PlumeMember.smoothstep(0.5, 2, log10(max(n, 1)))
            if b > 0 {
                m.baseExtinction = b * Optics.baseDepth / de * f
                m.baseTemperature = Optics.baseTemperature + 250 * m.afterburning
                m.upstream = 1.0 * de
            }
        }
        if let disk = s.machDisk, disk.luminosity > 0 {
            m.machDiskDistance = disk.distance
            m.machDiskRadius = max(disk.radius, 0.3 * re)
            // The shocked gas is as dense as the expanded jet there: a disk
            // far downstream in thin air is there but faint.
            let dilution = min(1, 4 * pow(m.sourceOffset / (disk.distance + m.sourceOffset), 2))
            m.machDiskExtinction = Optics.machDiskEmissivity(family) * disk.luminosity * dilution
                / (0.3 * m.machDiskRadius)
            m.machDiskTemperature = 0.85 * spec.chamberTemperature
        }

        // Turbulence: mottled in air, nearly still in vacuum.
        m.turbulence = 0.15 + 0.7 * w * (1 - v)
        m.noiseScale = 0.8 * re
        m.eddySpeed = min(max(10 * re, 2), 40)

        // The clear exhausts' near-exit light.
        switch family {
        case .hydrogen:
            m.glow = Optics.hydrogenGlow.scaled(by: f)
            m.glowLength = 1.5 * de
        case .hypergolic:
            m.glow = Optics.hypergolicGlow.scaled(by: f)
            m.glowLength = 1.5 * de
        default:
            break
        }
        // In air the bright flame and a stretch of its smoke (P4's trail
        // carries the rest); in vacuum what still shows, within 150
        // diameters.
        var length = visibleLength(m)
        if inAir && v < 0.5 && s.luminousLength > 0 {
            length = min(length, max(1.5 * Optics.flameHold * s.luminousLength, 30 * de))
        } else {
            length = min(length, 150 * de)
        }
        m.length = min(length, 1_500)
        return m
    }

    /// How far downstream the member's field still shows (m): where its
    /// column across has an optical depth under 3e-3 and the light it
    /// gives is under 3 cd/m², searched outward in 4 % steps, at most 3 km.
    public static func visibleLength(_ m: PlumeMember) -> Double {
        var probe = m
        probe.length = 1e9
        let de = m.exitDiameter
        var x = 0.5 * de, last = x
        while x < 3_000 {
            let s = probe.sample(x: x, r: 0)
            let chord = 2 * probe.radius(atX: x)
            let tau = s.extinction * chord
            let light = s.emission.luminance * chord
            let disk = m.machDiskExtinction > 0 && x < m.machDiskDistance + m.machDiskRadius
            if tau > 3e-3 || light > 3 || disk || x < (m.glowLength > 0 ? m.glowLength : 0) { last = x }
            else if x > 4 * last + 10 * de { break }
            x *= 1.04
        }
        return max(last * 1.15, 2 * de)
    }

    /// M1.5's look, through the march: today's colour, intensity, length and
    /// half-angle (Plumes.Look in M1.5), mixed from sea level to vacuum by
    /// √(p/p0), as an emission-only glow in today's units (E⊙/π cd/m²),
    /// with kerosene's dark core. The stub the switch-over was checked
    /// against, and the look of engines the exhaust library does not know.
    public static func legacy(exit: Vec3, axis: Vec3, radius re: Double, family: PlumeFamily, fraction: Double,
                              pressureRatio: Double, jet: Bool) -> PlumeMember {
        let table: (sl: (Double, Double, Double), vac: (Double, Double, Double), core: Double)
        switch family {
        case .kerosene: table = ((0.75, 24, 3), (0.5, 10, 28), 0.75)
        case .hydrogen: table = ((0.5, 14, 3), (0.35, 12, 30), 0)
        case .solid: table = ((1.0, 20, 4), (0.85, 24, 14), 0)
        case .hypergolic, .coldGas: table = ((0.55, 8, 8), (0.4, 8, 32), 0)
        }
        let k = min(max(pressureRatio, 0), 1).squareRoot()
        func mix(_ vac: Double, _ sl: Double) -> Double { vac + (sl - vac) * k }
        let intensity = max(0.3, mix(table.vac.0, table.sl.0)) * min(1, fraction)
        var length = mix(table.vac.1, table.sl.1) * re * (0.5 + 0.5 * min(1, fraction))
        if jet { length = max(0.6, length) }
        let halfAngle = mix(table.vac.2, table.sl.2) * Double.pi / 180
        var m = PlumeMember(exit: exit, axis: axis, exitRadius: re, family: family)
        // The cone's tail reached over a length of 2ℓ.
        let tail = re + length * tan(halfAngle)
        m.radiusGrowth = (tail - re) / (1 - exp(-2))
        m.shapeLength = length / 2
        m.glow = color(family).scaled(by: intensity * Photometry.solarIlluminanceAt1AU / Double.pi)
        m.glowLength = length
        m.length = length
        if table.core > 0 {
            m.sheathExtinction = table.core * 2 / re
            m.sheathThickness = 0.6
            m.sheathLength = 0.15 * length
        }
        m.turbulence = 0.2
        m.noiseScale = re
        return m
    }

    /// Readable plumes: a member whose light through its axis near the exit
    /// is under `readableFloor` gets a glow making up the difference, in its
    /// family's colour, over M1.5's vacuum length.
    public static func applyReadableFloor(_ m: inout PlumeMember) {
        let x = min(m.exitRadius, 0.25 * m.length)
        let seen = march([m], from: m.exit + m.axis * x - perpendicular(m.axis) * (4 * m.radius(atX: x)),
                         direction: perpendicular(m.axis), range: 0...(8 * m.radius(atX: x)), steps: 64)
        let missing = readableFloor - seen.radiance.luminance
        guard missing > 0 else { return }
        let vacuumLength: Double
        switch m.family {
        case .kerosene: vacuumLength = 10
        case .hydrogen: vacuumLength = 12
        case .solid: vacuumLength = 24
        case .hypergolic, .coldGas: vacuumLength = 8
        }
        // The glow's own response there per unit of it (its profile across
        // and its fall along), so the floor is met where it is measured.
        var unit = m
        unit.glow = Photometry.RGB(1, 1, 1)
        unit.glowLength = max(m.glowLength, vacuumLength * m.exitRadius, m.isJet ? 0.6 : 0)
        unit.length = max(m.length, unit.glowLength)
        var bare = unit
        bare.glow = Photometry.RGB(0, 0, 0)
        let probe = (from: m.exit + m.axis * x - perpendicular(m.axis) * (4 * m.radius(atX: x)),
                     direction: perpendicular(m.axis), range: 0...(8 * m.radius(atX: x)))
        let response = march([unit], from: probe.from, direction: probe.direction, range: probe.range, steps: 64)
            .radiance.luminance
            - march([bare], from: probe.from, direction: probe.direction, range: probe.range, steps: 64)
            .radiance.luminance
        let extra = color(m.family).scaled(by: missing / max(response, 1e-6))
        m.glow = Photometry.RGB(m.glow.r + extra.r, m.glow.g + extra.g, m.glow.b + extra.b)
        m.glowLength = unit.glowLength
        m.length = unit.length
    }

    /// A unit vector across `axis`.
    public static func perpendicular(_ axis: Vec3) -> Vec3 {
        axis.cross(VisualShape.defaultReference(for: axis)).normalized
    }

    // MARK: Blackbody

    /// A full radiator's luminance in linear Rec. 709, cd/m², as the shader
    /// evaluates it: per channel exp(c0 + c1/T + c2/T²), Wien's law with a
    /// correction, fitted by least squares in log to `Photometry.blackbody`
    /// over 1,100-3,600 K (blue over 1,950-3,600 K, below which Rec. 709
    /// clips it): luminance within a few per cent (PlumeLookTests).
    public static func blackbody(_ kelvin: Double) -> Photometry.RGB {
        guard kelvin > 300 else { return Photometry.RGB(0, 0, 0) }
        let c = wien, u = 1 / kelvin
        func ch(_ i: Int) -> Double { exp(c[i].0 + c[i].1 * u + c[i].2 * u * u) }
        return Photometry.RGB(ch(0), ch(1), ch(2))
    }

    /// The fit's coefficients (c0, c1, c2) for red, green and blue.
    public static let wien: [(Double, Double, Double)] = {
        func rgb(_ t: Double) -> Photometry.RGB {
            let b = Photometry.blackbody(t)
            return b.color.scaled(by: b.luminance)
        }
        /// Least squares of log y against (1, u, u²).
        func fit(_ samples: [(u: Double, y: Double)]) -> (Double, Double, Double) {
            var a = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3), b = [0.0, 0, 0]
            for s in samples where s.y > 0 {
                let x = [1, s.u, s.u * s.u], l = log(s.y)
                for i in 0..<3 {
                    for k in 0..<3 { a[i][k] += x[i] * x[k] }
                    b[i] += x[i] * l
                }
            }
            // Gaussian elimination, 3 × 3.
            for i in 0..<3 {
                let p = a[i][i]
                for k in 0..<3 { a[i][k] /= p }
                b[i] /= p
                for r in 0..<3 where r != i {
                    let f = a[r][i]
                    for k in 0..<3 { a[r][k] -= f * a[i][k] }
                    b[r] -= f * b[i]
                }
            }
            return (b[0], b[1], b[2])
        }
        let warm = stride(from: 1_100.0, through: 3_600, by: 50).map { ($0, rgb($0)) }
        let blue = warm.filter { $0.0 >= 1_950 }
        return [fit(warm.map { (1 / $0.0, $0.1.r) }), fit(warm.map { (1 / $0.0, $0.1.g) }),
                fit(blue.map { (1 / $0.0, $0.1.b) })]
    }()

    // MARK: Reference march

    /// The light a ray picks up through `members` (no turbulence): from
    /// `origin` along unit `direction` over `range` (m), in `steps` equal
    /// steps at their middles, with Hillaire's energy-conserving step; the
    /// scattering lit by `sun` (lux, the unit direction to it, unshadowed)
    /// and an isotropic `ambient` (lux). The shader's march without its
    /// jitter, noise and shadows.
    public static func march(_ members: [PlumeMember], from origin: Vec3, direction: Vec3,
                             range: ClosedRange<Double>, steps: Int,
                             sun: (direction: Vec3, illuminance: Photometry.RGB)? = nil,
                             ambient: Photometry.RGB = Photometry.RGB(0, 0, 0))
        -> (radiance: Photometry.RGB, transmittance: Double) {
        let ds = (range.upperBound - range.lowerBound) / Double(max(steps, 1))
        var t = 1.0, l = Photometry.RGB(0, 0, 0)
        for i in 0..<max(steps, 1) {
            let p = origin + direction * (range.lowerBound + (Double(i) + 0.5) * ds)
            var s = PlumeMember.Sample(), phase = 0.0, weight = 0.0
            for m in members {
                let x = m.sample(at: p)
                s = s + x
                weight += x.scattering
                if let sun { phase += x.scattering * henyeyGreenstein(direction.dot(sun.direction), m.phaseG) }
            }
            let sigma = s.extinction
            guard sigma > 0 || s.emission.luminance > 0 else { continue }
            var source = s.emission
            if weight > 0 {
                let p = phase / weight
                if let sun {
                    source = Photometry.RGB(source.r + s.scattering * sun.illuminance.r * p,
                                            source.g + s.scattering * sun.illuminance.g * p,
                                            source.b + s.scattering * sun.illuminance.b * p)
                }
                let a = s.scattering / (4 * Double.pi)
                source = Photometry.RGB(source.r + a * ambient.r, source.g + a * ambient.g, source.b + a * ambient.b)
            }
            let step = exp(-sigma * ds)
            let k = sigma > 1e-9 ? (1 - step) / sigma : ds
            l = Photometry.RGB(l.r + t * source.r * k, l.g + t * source.g * k, l.b + t * source.b * k)
            t *= step
        }
        return (l, t)
    }

    /// Henyey-Greenstein's phase, normalised over the sphere (1/sr).
    public static func henyeyGreenstein(_ cosTheta: Double, _ g: Double) -> Double {
        let d = 1 + g * g - 2 * g * cosTheta
        return (1 - g * g) / (4 * Double.pi * d * d.squareRoot())
    }
}
