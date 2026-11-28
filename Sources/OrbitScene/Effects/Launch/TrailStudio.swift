import Foundation
import OrbitCore

/// LR5's trail in the look-dev studio (`ParticleSettings.testTrail`), drawn
/// as the launch's is (TrailPass), in the studio anchor's axes (east, north
/// and up of the camera's target):
/// - **a tube:** a straight line of nodes `TrailChain.spacing` apart, σ
///   `TrailChain.jointAlong` along it and the given width across, its
///   depth through the axis the given one: what a stretch of trail is once
///   it has stopped changing, to hold its smoothness (no beads);
/// - **the plume's:** the chain the plume's test engines (`PlumeSettings
///   .testEngines`) hand their exhaust over to, laid in their stream as a
///   vehicle flying steadily through still air would lay it: a node every
///   `TrailChain.spacing` of jet at the joint, each at its age with P2's
///   column, jet and heat there (`TrailColumn.Node`), the young ones faded
///   in about P2's window (`TrailChain.fade`), as P2 fades out about it.
public enum TrailStudio {
    /// The trail's media in the studio anchor's axes, and where it joins
    /// the plume (the window's middle; nil for the tube).
    public static func media(_ t: ParticleTestTrail, scene: RenderScene, plumes: PlumeSettings, at now: Epoch)
        -> (media: [TrailChain.Drawn], joint: Vec3?) {
        switch t.kind {
        case .tube: return (tube(t), nil)
        case .plume: return plume(t, scene: scene, plumes: plumes, at: now)
        }
    }

    static func vector(_ a: [Double]) -> Vec3 { a.count == 3 ? Vec3(a[0], a[1], a[2]) : .zero }

    /// The tube's nodes.
    public static func tube(_ t: ParticleTestTrail) -> [TrailChain.Drawn] {
        let start = vector(t.start), d = vector(t.direction).length > 0 ? vector(t.direction).normalized : .unitX
        let up = abs(d.z) < 0.99 ? Vec3.unitZ : .unitX
        let across = d.cross(up).normalized
        let sigma = Vec3(TrailChain.jointAlong, t.width, t.width)
        // Its extinction per metre C = τ √(2π) σ; a node's C × spacing.
        let c = t.depth * (2 * Double.pi).squareRoot() * t.width
        let peak = c * TrailChain.spacing / (pow(2 * Double.pi, 1.5) * sigma.x * sigma.y * sigma.z)
        let line = c / (2 * Double.pi * t.width * t.width)
        let n = max(1, Int((t.length / TrailChain.spacing).rounded()))
        return (0...n).map { k in
            let g = GaussianMedium(centre: start + d * (Double(k) * TrailChain.spacing), axisU: d, axisV: across,
                                   sigma: sigma, peakExtinction: peak, albedo: Spectrum3(repeating: t.albedo),
                                   asymmetry: t.asymmetry)
            return TrailChain.Drawn(medium: g, linePeak: line)
        }
    }

    /// The plume's chain.
    public static func plume(_ t: ParticleTestTrail, scene: RenderScene, plumes: PlumeSettings, at now: Epoch)
        -> (media: [TrailChain.Drawn], joint: Vec3?) {
        let frame = EffectTargetFrame(scene: scene)
        let members = plumes.testEngines.flatMap { PlumeLook.members($0, in: frame, settings: plumes) }
        guard let engine = plumes.testEngines.first, !members.isEmpty else { return ([], nil) }
        let cluster = PlumeClusters.cluster(members)
        guard let h = cluster.handover, let jet = h.jet, let merged = cluster.merged ?? members.first else { return ([], nil) }
        let stream = TrailStudio.vector(engine.stream)
        let v = max(stream.length, 1)
        // P2's column at the joint, λ the engines' flow over the airspeed.
        let flow = plumes.testEngines.reduce(0.0) { s, e in
            let count = Double((e.centre || e.ring == 0 ? 1 : 0) + e.ring)
            return s + count * e.flowFraction * (ApolloExhaust.byTableRow[e.engine]?.ratedFlow ?? 0)
        }
        let column = PlumeAirflow.column(merged, atX: h.x - (merged.exit - cluster.origin).dot(cluster.axis),
                                         lineDensity: flow / v)
        // The studio anchor's axes from the world's.
        let back = Mat3(columns: frame.east, frame.north, frame.up).transposed
        func local(_ p: Vec3) -> Vec3 { back * (p - frame.origin) }
        let wind = back * (frame.direction(engine.stream) * v)
        let tangent = wind * (-1 / v), up = Vec3.unitZ
        // The air at the engines' altitude: US76, its lapse for N.
        let atmosphere = USStandardAtmosphere1976()
        let air0 = atmosphere.state(altitude: engine.altitude)
        let lo = atmosphere.state(altitude: max(engine.altitude - 100, 0)), hi = atmosphere.state(altitude: engine.altitude + 100)
        let g = 9.806_65
        let n2 = g / air0.temperature * ((hi.temperature - lo.temperature) / (engine.altitude + 100 - max(engine.altitude - 100, 0))
                                         + g / 1_004.7)
        let air = TrailColumn.Air(height: engine.altitude, mixedLayerTop: TrailChain.mixedLayerTop,
                                  convective: TrailChain.convective, frequency: max(n2, 0).squareRoot(), normalShear: 0,
                                  totalShear: 0, density: air0.density, temperature: air0.temperature)
        let heat = column.lineDensity * GroundCloud.exhaustHeat(ambient: air0.temperature) * (1 - GroundCloud.radiantFraction)
        let start = local(cluster.origin + h.start)
        // A node every spacing of jet at the joint: Δt = spacing / (V + u).
        let dt = TrailChain.spacing / (v + max(jet.excess, 0))
        let probe = TrailColumn.Node(laid: now, position: start, tangent: tangent, up: up, wind: wind,
                                     spacing: TrailChain.spacing, column: column,
                                     coflow: TrailColumn.Coflow(halfWidth: jet.halfWidth, excess: jet.excess, stream: v),
                                     heat: heat, air: air, window: 2 * h.window)
        var nodes: [TrailColumn.Node] = []
        var k = 0
        while true {
            var n = probe
            n.laid = now + -(Double(k) + 0.5) * dt
            if n.travelled(age: now - n.laid) > t.length + 2 * h.window { break }
            nodes.append(n)
            k += 1
        }
        nodes.reverse()
        let window = TrailChain.Window(origin: local(cluster.origin), axis: back * cluster.axis, range: h.fadeWindow)
        return (TrailChain.drawn(nodes, first: 0, at: now, window: window).map(\.drawn),
                local(cluster.origin) + back * cluster.axis * h.x)
    }
}
