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
/// - It radiates as a grey body (`Photometry.blackbody`) at the exit
///   temperature, or at the afterburning flame's 2,300 K where the
///   fuel-rich exhaust burns in air (`PlumeState.afterburning`), with an
///   emissivity by propellant family:
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
        let body = Photometry.blackbody(temperature)
        let luminance = eps * body.luminance
        let radius = max(e.exitRadius, spec.exitRadius)
        let length = min(max(state.luminousLength, 2 * radius), lengthCap * 2 * radius)
        let intensity = luminance * 2 * radius * length
        guard intensity > 0, intensity.isFinite else { return nil }
        let c = body.color
        return PlumeLight(centre: e.exit + e.axis * (0.5 * length), axis: e.axis, length: length, radius: radius,
                          intensity: RenderScene.RGB(Float(c.r * intensity), Float(c.g * intensity),
                                                     Float(c.b * intensity)),
                          range: (intensity / cutoffIlluminance).squareRoot(), luminousIntensity: intensity)
    }

    /// The scene's brightest plume lights at the camera, at most `maximum`,
    /// each engine cluster's merged into one (`merged`).
    public static func lights(_ scene: RenderScene, maximum: Int = PlumeLights.maximum) -> [PlumeLight] {
        let all = merged(scene.emitters.compactMap(light))
        func weight(_ l: PlumeLight) -> Double {
            l.luminousIntensity / max(l.centre.lengthSquared, l.length * l.length)
        }
        return Array(all.sorted { weight($0) > weight($1) }.prefix(maximum))
    }

    /// Plumes side by side (axes within 10°, centres closer than three
    /// columns' widths) lit as one column: the cluster's centre and axis
    /// weighted by intensity, wide enough to hold every member, as long as
    /// the longest, with their summed intensity. Five F-1s light the pad
    /// as one line light, a fifth of the cost per pixel.
    public static func merged(_ lights: [PlumeLight]) -> [PlumeLight] {
        var clusters: [[PlumeLight]] = []
        for l in lights {
            if let k = clusters.firstIndex(where: { c in
                c.contains { m in
                    m.axis.dot(l.axis) > cos(10 * Double.pi / 180)
                        && (m.centre - l.centre).length < 3 * (m.radius + l.radius)
                }
            }) {
                clusters[k].append(l)
            } else {
                clusters.append([l])
            }
        }
        return clusters.map { c in
            guard c.count > 1 else { return c[0] }
            let total = c.reduce(0) { $0 + $1.luminousIntensity }
            var centre = Vec3.zero, axis = Vec3.zero
            var r: Float = 0, g: Float = 0, b: Float = 0
            for m in c {
                let w = m.luminousIntensity / total
                centre = centre + m.centre * w
                axis = axis + m.axis * w
                r += m.intensity.r
                g += m.intensity.g
                b += m.intensity.b
            }
            let radius = c.map { ($0.centre - centre).length + $0.radius }.max() ?? 0
            return PlumeLight(centre: centre, axis: axis.normalized, length: c.map(\.length).max() ?? 0,
                              radius: radius, intensity: RenderScene.RGB(r, g, b),
                              range: (total / cutoffIlluminance).squareRoot(), luminousIntensity: total)
        }
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
}
