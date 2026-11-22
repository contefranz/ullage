import Foundation
import OrbitCore

/// The SPS's radiation-cooled nozzle extension glowing while it fires and
/// for a while after (track P2): the physical cue that the engine runs,
/// since its hypergolic plume is nearly invisible in vacuum. Visual grade
/// (L), from the AOH's description of the extension (columbium from the 6:1
/// chamber exit, titanium below; radiation-cooled):
///
/// - In a long burn the wall at the extension's top reaches about 1,480 K
///   (the columbium's coating's "2,200 °F" class), and a radiation-cooled
///   wall's equilibrium temperature falls along the bell as the heat flux
///   does, about as the area ratio to the -0.9 (T ∝ ε^-0.225 ∝ r^-0.45):
///   about 870 K at the 62.5:1 exit, dark there.
/// - The wall heats and cools exponentially in simulation time. A thin
///   radiation-cooled sheet holds little heat: 0.5 mm of columbium, ρct
///   about 1,160 J/(m² K), radiating from both faces, relaxes in
///   ρct / (8εσT³), about 1 s at 1,400 K and 6 s at 800 K; 4 s heating
///   and 12 s cooling here (L).
/// - It radiates as a grey body of emissivity 0.8 (the silicide coating).
public enum NozzleGlow {
    public static let topTemperature = 1_480.0
    public static let exponent = 0.45
    public static let emissivity = 0.8
    public static let heating = 4.0, cooling = 12.0
    /// The cold wall's temperature, K.
    public static let ambient = 300.0
    /// The thrusters that glow, by name.
    public static let thrusters: Set<String> = ["SPS"]

    /// The wall temperature (K) at local radius `r` (m) of a bell whose
    /// chamber exit (the extension's top) has radius `top`, at a heat
    /// fraction `heat` (0 cold, 1 steady at the rated flow): a radiating
    /// wall's T⁴ moves with the heat it takes.
    public static func temperature(radius r: Double, top: Double, heat: Double) -> Double {
        let steady = topTemperature * pow(max(r, top) / max(top, 1e-6), -exponent)
        let a4 = pow(ambient, 4)
        return pow(a4 + max(heat, 0) * (pow(steady, 4) - a4), 0.25)
    }

    /// The heat fraction `dt` s on, firing at flow fraction `flow` (0 off):
    /// exact for the exponential lag, whatever the step.
    public static func advance(_ heat: Double, flow: Double, dt: Double) -> Double {
        let target = min(max(flow, 0), 1.2)
        let tau = target > heat ? heating : cooling
        return target + (heat - target) * exp(-max(dt, 0) / tau)
    }

    /// The heat fraction now from the engine's last ignition and cutoff
    /// epochs (s before now; nil if none): cold before the ignition, as for
    /// a scenario that opens with the engine about to start.
    public static func heat(sinceIgnition ignition: Double?, sinceCutoff cutoff: Double?) -> Double {
        guard let ignition, ignition >= 0 else { return 0 }
        guard let cutoff, cutoff < ignition, cutoff >= 0 else { return advance(0, flow: 1, dt: ignition) }
        return advance(advance(0, flow: 1, dt: ignition - cutoff), flow: 0, dt: cutoff)
    }
}

/// The chamber's gas seen through a liquid engine's throat (the J-2's):
/// the cue that it fires from any view into its nozzle, since its plume is
/// dark in vacuum. Drawn on the engine's own chamber surfaces (the
/// convergent section, the chamber wall and the injector face the dresser
/// draws behind the throat), which only show through the throat: each
/// fragment gives the light of the hot gas between the throat and it,
/// optically thin, the water's visible emission at the chamber's pressure
/// and temperature (`PlumeLook.Optics.waterVisibleAbsorption`). It follows
/// the flow at once: the chamber's pressure is the flow's (a choked throat).
/// The water's blue continuum, chemiluminescent, scales with the pressure
/// squared and is not counted (no absolute measure found).
public enum ChamberGlow {
    /// The water's visible bands as the eye sees them, luminance 1: some
    /// 70 % of the light in the band near 590 nm, 15 % near 650 nm and 15 %
    /// in 500-560 nm (HITRAN 2020 at 3,373 K), Rec. 709 linear, clipped.
    public static let color: Photometry.RGB = {
        var x = 0.0, y = 0.0, z = 0.0
        for (nm, share) in [(590.0, 0.70), (650.0, 0.15), (530.0, 0.15)] {
            let c = Photometry.colorMatching(nm)
            x += share * c.x / c.y
            y += share
            z += share * c.z / c.y
        }
        let rgb = Photometry.rec709((x, y, z))
        let clipped = Photometry.RGB(max(rgb.r, 0), max(rgb.g, 0), max(rgb.b, 0))
        return clipped.scaled(by: 1 / clipped.luminance)
    }()

    /// The light the chamber's gas gives per metre of path, cd/m² per m,
    /// at `flowFraction` of the engine's rated flow: κ x_w p_c B(T_c).
    public static func emission(_ spec: ExhaustSpec, flowFraction f: Double) -> Photometry.RGB {
        let water = spec.waterFraction * spec.chamberPressure * max(f, 0) / 101_325
        let luminance = PlumeLook.Optics.waterVisibleAbsorption * water
            * Photometry.blackbody(spec.chamberTemperature).luminance
        return color.scaled(by: luminance)
    }

    /// The light (cd/m²) a surface `depth` m into a nozzle (from its exit
    /// plane) shows, seen along a ray at `cosine` of the axis: the gas
    /// between the throat and it, at most twice the chamber's length; none
    /// in front of the throat.
    public static func luminance(_ e: Photometry.RGB, chamber c: ApolloExhaust.Chamber, depth: Double,
                                 cosine: Double) -> Photometry.RGB {
        let path = min(max(depth - c.throatDepth, 0) / max(abs(cosine), 0.2),
                       2 * (c.injectorDepth - c.throatDepth) + 2 * c.radius)
        return e.scaled(by: path)
    }
}

/// Each glowing thruster's heat from frame to frame, in simulation time; on
/// a scenario's first frame or after a jump, rebuilt from the journal's
/// ignition and cutoff records the scene carries.
public final class NozzleGlowTracker {
    private struct Key: Hashable {
        let vessel: UUID
        let thruster: String
    }

    private var heat: [Key: Double] = [:]
    private var last: (time: Epoch, frame: Int)?
    /// The journal's ignitions and cutoffs seen, by thruster (epochs).
    private var ignitions: [Key: Epoch] = [:], cutoffs: [Key: Epoch] = [:]

    public init() {}

    /// The heat of every glowing thruster of the scene's vessels, by its
    /// key, after this frame.
    public func update(_ scene: RenderScene) -> [RenderScene.ThrusterKey: Double] {
        let now = scene.clock.simTime
        var jumped = true
        var dt = 0.0
        if let last, scene.clock.frameIndex >= last.frame {
            dt = now - last.time
            jumped = dt < 0 || dt > 600
        }
        if jumped {
            heat = [:]
            ignitions = [:]
            cutoffs = [:]
        }
        for t in scene.transitions {
            guard case .event(let e) = t else { continue }
            switch e.kind {
            case .ignition(let thruster, _) where NozzleGlow.thrusters.contains(thruster):
                ignitions[Key(vessel: e.vessel, thruster: thruster)] = e.epoch
            case .cutoff(let thruster, _) where NozzleGlow.thrusters.contains(thruster):
                cutoffs[Key(vessel: e.vessel, thruster: thruster)] = e.epoch
            default:
                break
            }
        }
        var flows: [RenderScene.ThrusterKey: (flow: Double, burnTime: Double)] = [:]
        for e in scene.emitters where NozzleGlow.thrusters.contains(e.name) {
            flows[e.thruster] = (e.flowFraction, e.burnTime)
        }
        var out: [RenderScene.ThrusterKey: Double] = [:]
        var seen = Set<Key>()
        for v in scene.vessels {
            for part in v.geometry.parts {
                for t in part.thrusters where NozzleGlow.thrusters.contains(t.name) {
                    let key = Key(vessel: v.id, thruster: t.name)
                    seen.insert(key)
                    let firing = flows[t.key]
                    let flow = firing?.flow ?? 0
                    var h: Double
                    if let before = heat[key] {
                        h = NozzleGlow.advance(before, flow: flow, dt: dt)
                    } else if let firing, ignitions[key] == nil {
                        // Firing with no record of its start: the engine's
                        // own burn time.
                        h = NozzleGlow.heat(sinceIgnition: firing.burnTime, sinceCutoff: nil) * min(firing.flow, 1.2)
                    } else {
                        h = NozzleGlow.heat(sinceIgnition: ignitions[key].map { now - $0 },
                                            sinceCutoff: cutoffs[key].map { now - $0 })
                    }
                    heat[key] = h
                    if h > 1e-4 { out[t.key] = h }
                }
            }
        }
        heat = heat.filter { seen.contains($0.key) }
        last = (now, scene.clock.frameIndex)
        return out
    }
}
