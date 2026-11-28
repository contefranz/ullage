import Foundation
import OrbitCore

/// The S-IC's exhaust trail below 40 km (P4, look round 2's LR5): the
/// path of the window's start where P2's plume hands its exhaust over
/// (`PlumeAirflow.trailHandover`), along the vehicle's climb in LC-39A's
/// body-fixed anchor, from which `TrailChain` lays its Gaussian nodes
/// (`TrailColumn.Node`), each carrying on P2's far field there: its column
/// (width, depth, soot), the jet's coflow and its heat. PR1's puffs are
/// retired.
///
/// The path between two frames is the cubic through both frames' positions
/// and velocities (Hermite): at warp a frame's path is still a curve, and
/// the nodes laid along it have lived as long as their ages say, every
/// node's state closed form in its age.
///
/// The first frame after a reset rebuilds the path from the pad at first
/// motion: straight up at `LiftoffRise`'s acceleration until the pitch
/// program starts, then on to the vehicle now with its height a cubic kept
/// monotone (Fritsch and Carlson) and its ground track a straight line
/// along which the distance grows as a power of the time since the pitch
/// program, the power the vehicle's velocity now gives (k = v t / x). On
/// AS-506's postflight trajectory (Boeing D5-15560-6, Table B-II) that
/// power is 3.9 at T+60 s, 3.75 at T+130 s and 3.1 at T+170 s; a cubic
/// through the two ends' velocities would swing the line uprange.
/// Along it nodes are laid at the S-IC's flow then, from the journal's
/// cutoffs, so a rebuild after CECO or OECO has the trail the frames laid;
/// their hand-over is the model's at the node's height, airspeed and flow
/// (`modelHead`), as the frames' own is near the vehicle. Nodes are laid
/// only below `ceiling` and above the ML deck.
public final class ExhaustTrail {
    /// The design's 40 km.
    public static let ceiling = 40_000.0
    /// How far behind the nozzle exits the path runs where P2's plume gives
    /// no hand-over (no stream: the pad's first instants), m (L).
    public static let offset = 50.0

    /// A point of the path: the window's start in the pad's anchor, its
    /// velocity there and the epoch.
    struct Point {
        var epoch: Epoch
        var position: Vec3
        var velocity: Vec3
    }

    private var last: Point?
    /// A firing F-1's flow over its rated flow (`RenderScene.Emitter
    /// .flowFraction`): AS-506's engines ran some 2 % over it. The scene's
    /// strongest while one fires, else the last seen, else 1.
    private var fullFlow = 1.0
    /// The last hand-over the frames had.
    private var lastHead: PlumeAirflow.Handover?
    /// The trail's Gaussian column, laid along the path.
    public let chain = TrailChain()

    public init() {}

    func reset() {
        last = nil
        lastHead = nil
        fullFlow = 1
        chain.reset()
    }

    /// The S-IC's nozzle exits' centroid, the vehicle's body axes from its
    /// centre of mass.
    static func exitCentroid(_ v: RenderScene.Vessel) -> Vec3? {
        var sum = Vec3.zero, n = 0
        for p in v.geometry.parts where p.name == "S-IC" {
            for t in p.thrusters where t.name.hasPrefix("S-IC engine") {
                guard let nozzle = v.geometry.nozzles[t.key] else { continue }
                sum += v.structureOrigin + nozzle.exit
                n += 1
            }
        }
        return n > 0 ? sum * (1 / Double(n)) : nil
    }

    // MARK: The modelled hand-over

    /// The height bins the modelled column is kept in, m.
    public static let modelBin = 250.0
    /// A frame's own column carries its pieces within this height of the
    /// vehicle, m; the model the rest (warp).
    public static let liveReach = 500.0

    /// An F-1's flow at `t` over its full flow: 1 until its cutoff in
    /// `cutoffs` (by name), tailing off linearly over `LaunchEffects.tailOff`,
    /// none after (or ever, for one cut off at −∞).
    static func engineFlow(_ name: String, at t: Epoch, cutoffs: [String: Epoch]) -> Double {
        guard let cut = cutoffs[name] else { return 1 }
        guard cut.tdb.isFinite else { return 0 }
        return min(1, max(0, 1 - (t - cut) / LaunchEffects.tailOff))
    }

    /// The hand-over's column for the S-IC of `vessel`, each F-1 at the
    /// flow over its rated `flow` gives for its name
    /// (`RenderScene.Emitter.flowFraction`; none at 0), in air of
    /// `density`, `temperature` and `pressure`, at `airspeed` (at least
    /// 1 m/s) along its engines' axes (no angle of attack): its F-1s as the
    /// scene would give them, through `PlumeAirflow.trailHandover`. For the
    /// paths a frame did not see.
    public static func modelColumn(_ vessel: RenderScene.Vessel, flow: (String) -> Double, density: Double,
                                   temperature: Double, pressure: Double, airspeed: Double,
                                   settings: PlumeSettings = PlumeSettings()) -> PlumeAirflow.Column? {
        modelHead(vessel, flow: flow, density: density, temperature: temperature, pressure: pressure, airspeed: airspeed,
                  settings: settings)?.column
    }

    /// The whole modelled hand-over (`modelColumn`'s): its window, column
    /// and jet.
    public static func modelHead(_ vessel: RenderScene.Vessel, flow: (String) -> Double, density: Double,
                                 temperature: Double, pressure: Double, airspeed: Double,
                                 settings: PlumeSettings = PlumeSettings()) -> PlumeAirflow.Handover? {
        guard density > 0 else { return nil }
        var air = AtmosphereState.vacuum
        air.temperature = temperature
        air.pressure = pressure
        air.density = density
        air.speedOfSound = (1.4 * 287.05 * max(temperature, 100)).squareRoot()
        var emitters: [RenderScene.Emitter] = []
        for p in vessel.geometry.parts where p.name == "S-IC" {
            for t in p.thrusters where t.name.hasPrefix("S-IC engine") {
                let f = flow(t.name)
                guard f > 0.005, let n = vessel.geometry.nozzles[t.key] else { continue }
                emitters.append(RenderScene.Emitter(
                    vesselID: vessel.id, thruster: t.key, name: t.name, exit: vessel.structureOrigin + n.exit,
                    axis: n.exhaust, exitRadius: n.radius, style: .kerosene, thrustFraction: f,
                    pressureRatio: pressure / 101_325, isSolid: false, isJet: false, part: p.name, flowFraction: f,
                    ambient: air, relativeWind: n.exhaust * max(airspeed, 1)))
            }
        }
        return PlumeAirflow.trailHandover(emitters, settings: settings)
    }

    // MARK: Curves

    /// A path from `start` over `duration` s, its position at `u` in 0...1
    /// (time-linear), in the pad's anchor.
    struct Curve {
        var start: Epoch
        var duration: Double
        var position: (Double) -> Vec3

        /// The cubic from (p0, v0) to (p1, v1) (Hermite).
        static func hermite(start: Epoch, duration d: Double, p0: Vec3, v0: Vec3, p1: Vec3, v1: Vec3) -> Curve {
            Curve(start: start, duration: d) { u in
                let u2 = u * u, u3 = u2 * u
                return p0 * (2 * u3 - 3 * u2 + 1) + v0 * (d * (u3 - 2 * u2 + u)) + p1 * (-2 * u3 + 3 * u2)
                    + v1 * (d * (u3 - u2))
            }
        }

        /// Its length, sampled.
        var length: Double {
            var sum = 0.0, previous = position(0)
            for k in 1...32 {
                let p = position(Double(k) / 32)
                sum += (p - previous).length
                previous = p
            }
            return sum
        }
    }

    /// Fritsch and Carlson's limit on a cubic's end slopes along one axis:
    /// with the chord's slope `dp`/`d`, slopes against it go to zero and the
    /// two are scaled into the circle of radius 3, so the axis is monotone.
    static func monotone(_ dp: Double, _ v0: Double, _ v1: Double, duration d: Double) -> (Double, Double) {
        let slope = dp / d
        guard abs(slope) > 1e-9 else { return (0, 0) }
        var a = max(0, v0 / slope), b = max(0, v1 / slope)
        let r = a * a + b * b
        if r > 9 {
            let k = 3 / r.squareRoot()
            a *= k
            b *= k
        }
        return (a * slope, b * slope)
    }

    /// The powers the ground track's distance may grow as.
    static let powers = 1.0...8.0

    /// The climb from `p` (the pitch program's start) to `q`, `axes` the
    /// site's in the anchor (columns: north, west, up): the height a
    /// monotone cubic; the ground track straight, its distance growing as
    /// (t / d)^k with k from `q`'s velocity along it.
    static func climb(from p: Point, to q: Point, axes: Mat3) -> Curve {
        let d = q.epoch - p.epoch, back = axes.transposed
        let dp = back * (q.position - p.position), v0 = back * p.velocity, v1 = back * q.velocity
        let z = monotone(dp.z, v0.z, v1.z, duration: d)
        let ground = Vec3(dp.x, dp.y, 0), along = Vec3(v1.x, v1.y, 0).dot(ground)
        var k = 3.0
        if ground.lengthSquared > 1, along > 0 { k = min(powers.upperBound, max(powers.lowerBound, along * d / ground.lengthSquared)) }
        let p0 = p.position
        return Curve(start: p.epoch, duration: d) { u in
            let u2 = u * u, u3 = u2 * u
            let height = dp.z * (-2 * u3 + 3 * u2) + z.0 * d * (u3 - 2 * u2 + u) + z.1 * d * (u3 - u2)
            return p0 + axes * (ground * pow(u, k) + Vec3(0, 0, height))
        }
    }

    // MARK: The frame

    func update(_ c: inout LaunchEffects.Context, owner: LaunchEffects) {
        let v = c.vehicle.vessel
        let firing = c.vehicle.flow > 0.05 || c.now <= c.firstMotion
        guard c.now > c.firstMotion || c.rebuilt, firing || c.rebuilt,
              let exits = Self.exitCentroid(v), let a = owner.anchor(&c), let frame = c.frame.anchorFrame(a),
              let centre = c.frame.place(exits, of: v, in: a)
        else {
            last = nil
            return
        }
        // Where P2's plume hands the exhaust over (on its path bent into the
        // relative wind, slowed to the air): the path runs through its
        // window's start, where the nodes begin to fade in; else the fixed
        // offset behind.
        let head = c.vehicle.trailHead
        if let h = head, h.column != nil { lastHead = h }
        chain.retire(at: c.now)
        if let f = c.frame.scene.emitters.filter({ $0.vesselID == v.id && $0.name.hasPrefix("S-IC engine") && !$0.isJet })
            .map(\.flowFraction).max(), f > 0.5 { fullFlow = f }
        let joint = head?.start
        let behind = head.map { $0.x - $0.window } ?? Self.offset
        let here: Point
        if c.rebuilt {
            // Behind along the path, from the vehicle now while the S-IC
            // fires; once it has stopped, from the vehicle's state at its
            // last cutoff (the journal's), where it stopped laying the
            // trail: the spent stage now coasts on another path.
            var at = (position: centre.position, velocity: centre.velocity, epoch: c.now)
            if !firing {
                guard let e = owner.lastCutoff, e.epoch > c.firstMotion,
                      let p = c.frame.place(e.point, of: e, in: a) else {
                    last = nil
                    return
                }
                at = (p.position, p.velocity, e.epoch)
            }
            let along = at.velocity.length > 1 ? at.velocity.normalized : c.toAnchor * .unitZ
            here = Point(epoch: at.epoch, position: at.position - along * behind, velocity: at.velocity)
        } else {
            let point = joint.map { exits + v.attitude.inverseRotate($0) } ?? exits - Vec3.unitX * behind
            guard let p = c.frame.place(point, of: v, in: a) else { return }
            here = Point(epoch: c.now, position: p.position, velocity: p.velocity)
        }
        defer { last = firing ? here : nil }
        // The frame's own hand-over near the vehicle (not on a rebuilt path:
        // the vehicle now is not where it laid it).
        let liveHead = c.rebuilt ? nil : (head?.column != nil ? head : lastHead).map { (head: $0, altitude: frame.altitude(of: here.position)) }
        if let l = last, l.epoch < c.now, !c.rebuilt {
            let curve = Curve.hermite(start: l.epoch, duration: c.now - l.epoch, p0: l.position, v0: l.velocity,
                                      p1: here.position, v1: here.velocity)
            chain.lay(curve, c, frame: frame, owner: owner, live: liveHead, fullFlow: fullFlow)
        } else if c.rebuilt, c.now > c.firstMotion {
            rebuild(to: here, &c, frame: frame, owner: owner)
        }
    }

    /// The path from the pad at first motion to `here`: the vertical climb
    /// to the pitch program, then `climb`.
    func rebuild(to here: Point, _ c: inout LaunchEffects.Context, frame: AnchorFrame, owner: LaunchEffects) {
        let up = c.toAnchor * .unitZ
        let base = PadExhaust.exitHeightOnPad - Self.offset
        let pad = Point(epoch: c.firstMotion, position: c.toAnchor * Vec3(0, 0, base), velocity: .zero)
        let d = here.epoch - c.firstMotion, tp = c.programStart
        var curves: [Curve] = []
        if d <= tp {
            curves.append(Self.climb(from: pad, to: here, axes: c.toAnchor))
        } else {
            let pitch = Point(epoch: c.firstMotion + tp,
                              position: pad.position + up * LiftoffRise.rise(after: tp, release: c.release),
                              velocity: up * LiftoffRise.speed(after: tp, release: c.release))
            curves.append(.hermite(start: pad.epoch, duration: tp, p0: pad.position, v0: .zero, p1: pitch.position,
                                   v1: pitch.velocity))
            curves.append(Self.climb(from: pitch, to: here, axes: c.toAnchor))
        }
        for curve in curves { chain.lay(curve, c, frame: frame, owner: owner, live: nil, fullFlow: fullFlow) }
    }
}
