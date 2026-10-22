import Foundation
import OrbitCore

/// A plume as a light on the vehicle and the pad: a line light along the
/// exhaust's axis (LightingCommon's `LocalLight`).
public struct PlumeLight: Equatable {
    /// Camera-relative centre of the luminous segment, m.
    public var centre: Vec3
    /// Unit exhaust direction (world).
    public var axis: Vec3
    /// The segment's length and the column's radius, m.
    public var length: Double
    public var radius: Double
    /// Luminous intensity seen broadside, cd, as linear Rec. 709 whose
    /// luminance (0.2126, 0.7152, 0.0722) is the intensity.
    public var intensity: RenderScene.RGB
    /// Beyond this distance its illuminance is negligible (m).
    public var range: Double
    /// Broadside intensity, cd.
    public var luminousIntensity: Double
}

/// The scene's plume lights, at most `maximum`, from its emitters and P1's
/// exhaust specs (track R2; P2 may write its own into LightingUniforms,
/// which the vessel pass then prefers). Visual grade (L):
///
/// - The luminous gas is a column of the exit's radius and the length the
///   plume model gives (`PlumeState.luminousLength`), capped at ten exit
///   diameters, the bright near field.
/// - It radiates as a grey body at the exit temperature, or at the
///   afterburning flame's 2,300 K where the fuel-rich exhaust burns in air
///   (`PlumeState.afterburning`), with an emissivity by propellant family:
///   kerosene's soot near black, alumina in solids, little from hydrogen or
///   hypergols, nothing from cold gas.
/// - Its intensity broadside is that luminance times the column's
///   projected area, 2 r ℓ; the strongest at the camera are kept.
public enum PlumeLights {
    public static let maximum = 8

    /// Emissivity of the luminous column by propellant family (L).
    public static func emissivity(_ family: ExhaustSpec.Family, sootIndex: Double) -> Double {
        switch family {
        case .keroseneLOX: return 0.2 + 0.6 * sootIndex
        case .solidAluminized: return 0.5
        case .solidOther: return 0.2
        case .hypergolic: return 0.05
        case .hydrogenLOX: return 0.02
        case .coldGas: return 0
        }
    }

    /// The column's length cap, in exit diameters.
    public static let lengthCap = 10.0
    /// Lights dimmer than this at their range are cut, lux.
    public static let cutoffIlluminance = 1.0

    /// The plume light of one emitter, nil when it gives none (an engine
    /// the exhaust library does not know, or no flow).
    public static func light(_ e: RenderScene.Emitter) -> PlumeLight? {
        guard let engine = ApolloExhaust.engine(thruster: e.name, part: ""), e.thrustFraction > 0 else { return nil }
        let spec = engine.spec
        let ambient = atmosphere(pressureRatio: e.pressureRatio)
        let state = PlumeModel.state(spec, flowFraction: e.thrustFraction, ambient: ambient)
        let burning = spec.fuelRichFraction > 0 ? min(1, state.afterburning / spec.fuelRichFraction) : 0
        let temperature = max(spec.exitTemperature, burning > 0 ? 2_300 * burning + spec.exitTemperature * (1 - burning)
                                                                  : spec.exitTemperature)
        let eps = emissivity(spec.family, sootIndex: spec.sootIndex)
        guard eps > 0 else { return nil }
        let luminance = eps * blackbodyLuminance(temperature)
        let radius = max(e.exitRadius, spec.exitRadius)
        let length = min(max(state.luminousLength, 2 * radius), lengthCap * 2 * radius)
        let intensity = luminance * 2 * radius * length
        guard intensity > 0, intensity.isFinite else { return nil }
        let c = chromaticity(temperature)
        return PlumeLight(centre: e.exit + e.axis * (0.5 * length), axis: e.axis, length: length, radius: radius,
                          intensity: RenderScene.RGB(c.r * Float(intensity), c.g * Float(intensity),
                                                     c.b * Float(intensity)),
                          range: (intensity / cutoffIlluminance).squareRoot(), luminousIntensity: intensity)
    }

    /// The scene's brightest plume lights at the camera, at most `maximum`.
    public static func lights(_ scene: RenderScene, maximum: Int = PlumeLights.maximum) -> [PlumeLight] {
        let all = scene.emitters.compactMap(light)
        func weight(_ l: PlumeLight) -> Double {
            l.luminousIntensity / max(l.centre.lengthSquared, l.length * l.length)
        }
        return Array(all.sorted { weight($0) > weight($1) }.prefix(maximum))
    }

    /// Air at `pressureRatio` of sea level's for the plume model: the
    /// pressure, with a 250 K mean temperature for the rest (the light
    /// depends on the pressure through the afterburning and the length).
    static func atmosphere(pressureRatio: Double) -> AtmosphereState {
        let p = max(0, pressureRatio) * 101_325
        guard p > 0 else { return .vacuum }
        let t = 250.0
        var air = AtmosphereState.vacuum
        air.temperature = t
        air.pressure = p
        air.density = p / (287.05 * t)
        air.speedOfSound = (1.4 * 287.05 * t).squareRoot()
        return air
    }

    // MARK: Blackbody (until R1's Photometry)

    /// A blackbody's luminance at `kelvin`, cd/m²: 683 lm/W times Planck's
    /// spectral radiance weighted by the photopic curve, 360-830 nm in 1 nm
    /// steps, the curve as Wyman, Sloan and Shirley's (2013) two-lobe fit
    /// of ȳ. R1's `Photometry` replaces it when it lands.
    public static func blackbodyLuminance(_ kelvin: Double) -> Double {
        guard kelvin > 0 else { return 0 }
        let h = 6.62607015e-34, c = 299_792_458.0, k = 1.380649e-23
        var sum = 0.0
        for nm in 360...830 {
            let lambda = Double(nm) * 1e-9
            let planck = 2 * h * c * c / pow(lambda, 5) / (exp(h * c / (lambda * k * kelvin)) - 1)
            sum += planck * photopic(Double(nm)) * 1e-9
        }
        return 683 * sum
    }

    /// Wyman, Sloan and Shirley's (2013) fit of the CIE 1931 ȳ.
    static func photopic(_ nm: Double) -> Double {
        func g(_ x: Double, _ mu: Double, _ s1: Double, _ s2: Double) -> Double {
            let t = (x - mu) / (x < mu ? s1 : s2)
            return exp(-0.5 * t * t)
        }
        return 0.821 * g(nm, 568.8, 46.9, 40.5) + 0.286 * g(nm, 530.9, 16.3, 31.1)
    }

    /// Linear Rec. 709 of a blackbody at `kelvin` with unit luminance
    /// (`LegacyLighting.blackbody`'s colour, rescaled), until R1's.
    static func chromaticity(_ kelvin: Double) -> RenderScene.RGB {
        let c = LegacyLighting.blackbody(kelvin)
        let y = max(0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b, 1e-6)
        return RenderScene.RGB(c.r / y, c.g / y, c.b / y)
    }
}
