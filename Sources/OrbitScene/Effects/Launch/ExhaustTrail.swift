import Foundation
import OrbitCore

/// The S-IC's exhaust trail below 40 km (P4, look round 2's LR5 PR1): a
/// line of smoke puffs laid along the vehicle's path in LC-39A's body-fixed
/// anchor, at rest in the air they were left in, carrying on P2's far field
/// where the plume hands its exhaust over (`PlumeAirflow.trailHandover`):
/// - **its column:** the puffs' size, optical depth and albedo give the line
///   P2's projected far field's depth, cross-section and soot there
///   (`Column`, `puffs`);
/// - **its fade:** the line fades in as P2's plume fades out, both
///   linearly over the same window, on the airspeed's clock, so the two sum
///   to one along it (`fadeIn`);
/// - **stratified:** each piece's puffs are spread evenly along it, each
///   where it was laid at its age, not at random (no beads).
///
/// P3's particles then carry every puff on the wind at its own height in
/// the launch day's sounding (`AirProfile`, from `sim.atmosphere(of:)`), so
/// AS-506's measured shear bends and twists the line over the minutes it
/// lives, while each puff spreads (the material's `spreadRate`). PR2
/// replaces the puffs with `TrailColumn`'s Gaussians.
///
/// The path between two frames is the cubic through both frames' positions
/// and velocities (Hermite), laid in pieces of equal length, each one
/// request with its true ages: at warp a frame's path is still a curve, and
/// its puffs have drifted as long as they have lived. Pieces are at most a
/// second and `pieceLength` long while `maxPieces` suffice (about 12 km of
/// path a frame); beyond, they are longer.
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
/// Along it puffs are laid at the S-IC's flow then, from the journal's
/// cutoffs, so a rebuild after CECO or OECO has the trail the frames laid;
/// their column is the hand-over's at the piece's height, airspeed and flow
/// (`modelColumn`), as the frames' own is near the vehicle. Puffs are laid
/// only below `ceiling` and above the ML deck.
public final class ExhaustTrail {
    /// The design's 40 km.
    public static let ceiling = 40_000.0
    /// How long a puff lives, s (L: Apollo's trails hung for minutes): one
    /// value, so that a puff's fade-in, a share of its life, keeps the
    /// plume's clock.
    public static let lifetime = 480.0...480.0
    /// How far behind the nozzle exits the puffs are laid where P2's plume
    /// gives no hand-over (no stream: the pad's first instants), m (L).
    public static let offset = 50.0

    // MARK: The column

    /// The puffs' profile: a puff's optical depth across it falls as
    /// (1 − ρ²/R²)² (P3's smoke), so a line of them `spacing` apart has the
    /// column τ(y) = (16/15)(R/s) τ0 (1 − y²/R²)^(5/2), whose cross-section
    /// ∫ τ dy is its depth times (5π/16) R.
    public static let lineDepthFactor = 16.0 / 15.0
    public static let lineWidthFactor = 5 * Double.pi / 16
    /// The puffs are this far apart in radii, or nearer (`puffs`).
    public static let spacingRadii = 0.5
    /// Their radii spread ±10 % about the column's.
    public static let radiusSpread = 0.1

    /// The puffs' optical depths through the centre, the trail palette's
    /// rows: each a factor of two, the column's depth reached by spacing.
    public static let depthLevels = [0.1, 0.2, 0.4, 0.8, 1.6, 3.2]
    /// The palette's albedos: a column's is laid as the two either side of
    /// it, by weight.
    public static let albedoLevels = [0.2, 0.35, 0.5, 0.65, 0.8, 0.95]

    /// How a piece of trail carries on a column: the puffs' radius, their
    /// palette row (`depthLevels`) and spacing, and the two albedo columns
    /// (`albedoLevels`) with their weights.
    public struct Puffs: Equatable {
        public var radius: Double
        public var depthLevel: Int
        public var spacing: Double
        public var albedo: [(level: Int, weight: Double)]

        public static func == (a: Puffs, b: Puffs) -> Bool {
            a.radius == b.radius && a.depthLevel == b.depthLevel && a.spacing == b.spacing
                && a.albedo.map(\.level) == b.albedo.map(\.level) && a.albedo.map(\.weight) == b.albedo.map(\.weight)
        }
    }

    /// The puffs that carry `column` on: the radius whose line has its
    /// depth and cross-section, R = C / ((5π/16) τ); the deepest palette
    /// row at most (15/32) of its depth (a line half a radius apart), at
    /// least the first, spaced to give its depth, s = (16/15) R τ0 / τ (at
    /// most R, for a column too faint for the first row); its albedo between
    /// the two palette columns either side of it.
    public static func puffs(_ column: PlumeAirflow.Column) -> Puffs? {
        guard column.depth > 1e-6, column.crossSection > 0 else { return nil }
        let radius = column.crossSection / (lineWidthFactor * column.depth)
        let want = column.depth * spacingRadii / lineDepthFactor
        let level = depthLevels.lastIndex { $0 <= want } ?? 0
        let spacing = min(lineDepthFactor * radius * depthLevels[level] / column.depth, radius)
        let a = min(max(column.albedo, albedoLevels[0]), albedoLevels[albedoLevels.count - 1])
        let i = min(albedoLevels.lastIndex { $0 <= a } ?? 0, albedoLevels.count - 2)
        let w = (a - albedoLevels[i]) / (albedoLevels[i + 1] - albedoLevels[i])
        return Puffs(radius: radius, depthLevel: level, spacing: spacing, albedo: [(i, 1 - w), (i + 1, w)])
    }

    // MARK: The fade

    /// The puffs fade in linearly with age (P3's fade) as P2's plume fades
    /// out linearly over the hand-over's window [x − w, x + w]: laid at its
    /// start, at rest in the air, a puff lies ∫V dt past it at age a, so the
    /// two sum to one along it where the airspeed is steady and the puffs
    /// are points. They are not: a puff's billboard spreads its depth ±R
    /// along the axis (R 0.65-0.84 of the window), and the airspeed rises
    /// while it crosses, so the sum strays from one by up to about 13 % at
    /// the window's ends (`ExhaustTrailTests.testJointsAxialProfile`). PR2's
    /// Gaussian nodes, fading by the distance each has gone, make it exact.
    /// (The ramp spans the whole window: its half-width in w.)
    public static let rampHalfWidth = 1.0
    /// The fade-in never takes longer than this, s (the pad's slowest
    /// first metres; L).
    public static let longestFadeIn = 20.0

    /// The puffs' fade-in as a share of their life (the trail materials'
    /// `fadeIn`): the time T in which a puff, at rest in the air, recedes
    /// the window's 2w from the joint while the airspeed V grows at A, so
    /// that the one crossing it now is wholly in: V T − ½ A T² = 2w, T =
    /// 4w / (V + √(V² − 4Aw)) (2w/V when steady); at most `longestFadeIn`.
    /// Without a hand-over, 0.0002 (a tenth of a second). Quantised to
    /// 0.5 %, so the materials change seldom.
    public static func fadeIn(window: Double?, airspeed: Double, acceleration: Double = 0) -> Double {
        guard let w = window, w > 0 else { return 0.0002 }
        let half = rampHalfWidth * w, v = max(airspeed, 1), d = v * v - 4 * max(acceleration, 0) * half
        let seconds = d > 0 ? min(4 * half / (v + d.squareRoot()), longestFadeIn) : longestFadeIn
        let share = max(seconds / lifetime.upperBound, 1e-7)
        return exp((log(share) / 0.005).rounded() * 0.005)
    }

    /// The longest piece of path one request lays, s and m (one request
    /// has one velocity: the wind at the piece's middle), while the pieces
    /// a frame may lay suffice: `maxPieces`, or `maxRebuiltPieces` on a
    /// rebuilt path (about 38 km of it).
    public static let pieceTime = 1.0
    public static let pieceLength = 100.0
    public static let maxPieces = 128
    public static let maxRebuiltPieces = 384

    /// A point of the path: where the puffs leave, in the pad's anchor, its
    /// velocity there and the epoch.
    struct Point {
        var epoch: Epoch
        var position: Vec3
        var velocity: Vec3
    }

    private var last: Point?
    /// Where the next stratum of puffs starts, m from the next piece's
    /// start (at or before it), and the first albedo's share of a puff
    /// left over, carried from piece to piece.
    private var ahead = 0.0
    private var carry = 0.0
    /// The hand-over's column modelled along the path, by `modelBin` of
    /// height: a rebuilt history's, and a frame's at warp away from the
    /// vehicle.
    private var models: [Int: PlumeAirflow.Column] = [:]
    /// The last column the frames had (where the hand-over gives none: no
    /// stream for an instant).
    private var lastColumn: PlumeAirflow.Column?
    /// A firing F-1's flow over its rated flow (`RenderScene.Emitter
    /// .flowFraction`): AS-506's engines ran some 2 % over it. The scene's
    /// strongest while one fires, else the last seen, else 1.
    private var fullFlow = 1.0
    /// Puffs laid since the reset (for the tests and the log).
    public private(set) var laid = 0

    public init() {}

    func reset() {
        last = nil
        ahead = 0
        carry = 0
        models = [:]
        lastColumn = nil
        fullFlow = 1
        laid = 0
    }

    /// The trail palette's size (`LaunchMaterials.trail(depth:albedo:)`),
    /// row-major: material `depth × albedoLevels.count + albedo`.
    public static let palette = depthLevels.count * albedoLevels.count

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
        return PlumeAirflow.trailHandover(emitters, settings: settings)?.column
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

        /// The parameters cutting it into `n` pieces of equal length.
        func equalLengths(_ n: Int) -> [Double] {
            let m = max(8, 8 * n)
            var lengths = [0.0], previous = position(0)
            for k in 1...m {
                let p = position(Double(k) / Double(m))
                lengths.append(lengths[k - 1] + (p - previous).length)
                previous = p
            }
            let total = lengths[m]
            guard total > 0 else { return (0...n).map { Double($0) / Double(n) } }
            var cuts = [0.0], k = 1
            for i in 1..<n {
                let want = total * Double(i) / Double(n)
                while k < m && lengths[k] < want { k += 1 }
                let w = (want - lengths[k - 1]) / max(lengths[k] - lengths[k - 1], 1e-12)
                cuts.append((Double(k - 1) + w) / Double(m))
            }
            cuts.append(1)
            return cuts
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

    func update(_ c: inout LaunchEffects.Context, materials: [ParticleMaterialID], owner: LaunchEffects) {
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
        // relative wind, slowed to the air), the puffs laid at the start of
        // the ramp that fades them in as the plume fades out, at this
        // airspeed; else the fixed offset behind.
        let head = c.vehicle.trailHead
        // The airspeed's growth: the vehicle's acceleration along its motion.
        let along = centre.velocity.length > 1 ? centre.acceleration.dot(centre.velocity.normalized) : 0
        let share = Self.fadeIn(window: head?.window, airspeed: c.vehicle.airspeed, acceleration: along)
        for id in materials where c.frame.materials[id].fadeIn != share {
            var m = c.frame.materials[id]
            m.fadeIn = share
            c.frame.materials.register(m)
        }
        if let column = head?.column { lastColumn = column }
        if let f = c.frame.scene.emitters.filter({ $0.vesselID == v.id && $0.name.hasPrefix("S-IC engine") && !$0.isJet })
            .map(\.flowFraction).max(), f > 0.5 { fullFlow = f }
        let joint = head.map { $0.start + ($0.point - $0.start) * (1 - Self.rampHalfWidth) }
        let behind = head.map { $0.x - Self.rampHalfWidth * $0.window } ?? Self.offset
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
        // The frame's own column near the vehicle (not on a rebuilt path:
        // the vehicle now is not where it laid it).
        let live = c.rebuilt ? nil : (head?.column ?? lastColumn).map { (column: $0, altitude: frame.altitude(of: here.position)) }
        if let l = last, l.epoch < c.now, !c.rebuilt {
            let curve = Curve.hermite(start: l.epoch, duration: c.now - l.epoch, p0: l.position, v0: l.velocity,
                                      p1: here.position, v1: here.velocity)
            lay(curve, &c, anchor: a, frame: frame, materials: materials, owner: owner, maxPieces: Self.maxPieces,
                live: live)
        } else if c.rebuilt, c.now > c.firstMotion {
            rebuild(to: here, &c, anchor: a, frame: frame, materials: materials, owner: owner)
        }
    }

    /// The path from the pad at first motion to `here`: the vertical climb
    /// to the pitch program (in pieces of at most a second), then `climb`
    /// (in the pieces left).
    func rebuild(to here: Point, _ c: inout LaunchEffects.Context, anchor a: EffectAnchorID, frame: AnchorFrame,
                 materials: [ParticleMaterialID], owner: LaunchEffects) {
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
        var left = Self.maxRebuiltPieces
        for (i, curve) in curves.enumerated() {
            let pieces = i == curves.count - 1 ? left : Int((curve.duration / Self.pieceTime).rounded(.up))
            lay(curve, &c, anchor: a, frame: frame, materials: materials, owner: owner, maxPieces: max(1, pieces),
                live: nil)
            left = max(1, left - pieces)
        }
    }

    /// Lays `curve` in pieces of equal length: each piece's puffs carry on
    /// its column (`live`'s within `liveReach` of its height, else the
    /// model's at the piece's height, airspeed and flow), spread evenly
    /// along it by their ages (the emit sampler's stratified ages, each
    /// started where the piece was at its age: a `sourceVelocity` along the
    /// chord, its own velocity the wind less that), at rest in the air.
    func lay(_ curve: Curve, _ c: inout LaunchEffects.Context, anchor a: EffectAnchorID, frame: AnchorFrame,
             materials: [ParticleMaterialID], owner: LaunchEffects, maxPieces: Int,
             live: (column: PlumeAirflow.Column, altitude: Double)?) {
        // How long a puff takes to fade in now (the materials' share).
        let fadeSeconds = c.frame.materials[materials[0]].fadeIn * Self.lifetime.upperBound
        let d = curve.duration
        guard d > 0 else { return }
        let n = min(maxPieces, max(1, Int((d / Self.pieceTime).rounded(.up)), Int((curve.length / Self.pieceLength).rounded(.up))))
        let cuts = curve.equalLengths(n)
        let up = c.toAnchor * .unitZ
        let air = c.body.air
        for i in 0..<n {
            var p0 = curve.position(cuts[i]), p1 = curve.position(cuts[i + 1])
            var t0 = curve.start + d * cuts[i], t1 = curve.start + d * cuts[i + 1]
            // Clipped at the deck: the pad's exhaust is below it.
            let s0 = p0.dot(up), s1 = p1.dot(up)
            guard s0 > 0 || s1 > 0 else {
                ahead = 0
                continue
            }
            if s0 < 0 || s1 < 0 {
                let w = s0 / (s0 - s1)
                let cut = p0 + (p1 - p0) * w, at = t0 + (t1 - t0) * w
                if s0 < 0 { (p0, t0) = (cut, at) } else { (p1, t1) = (cut, at) }
            }
            let chord = p1 - p0, length = chord.length
            let h = frame.altitude(of: p0 + chord * 0.5)
            // Nor above the ceiling.
            guard length > 0, t1 > t0, h < Self.ceiling else {
                ahead = 0
                continue
            }
            let tm = t0 + 0.5 * (t1 - t0), flow = min(1, owner.flow(c, tm))
            guard flow > 0.005 else {
                ahead = 0
                continue
            }
            let sample = air.map { $0.sample(altitude: h) }
            let wind = sample.map { frame.east * $0.windEast + frame.north * $0.windNorth } ?? .zero
            let along = chord * (1 / (t1 - t0))
            let column: PlumeAirflow.Column?
            if let l = live, abs(h - l.altitude) < Self.liveReach {
                column = l.column
            } else {
                let bin = Int((h / Self.modelBin).rounded(.down))
                if let m = models[bin] {
                    column = m
                } else {
                    column = sample.flatMap {
                        // Each F-1 at full flow until its cutoff (the journal's,
                        // or before the release for one the count lost),
                        // tailing off over `LaunchEffects.tailOff`.
                        Self.modelColumn(c.vehicle.vessel, flow: { [cutoffs = owner.engineCutoffs(c), full = fullFlow] name in
                            full * Self.engineFlow(name, at: tm, cutoffs: cutoffs)
                        }, density: $0.density, temperature: $0.temperature,
                                         pressure: $0.pressure, airspeed: (wind - along).length, settings: c.frame.plumes)
                    }
                    models[bin] = column
                }
            }
            guard let col = column, let puffs = Self.puffs(col) else {
                ahead = 0
                continue
            }
            // One lattice along the path, its strata `spacing` long, from
            // where the last piece's left off (`ahead`, at or before this
            // piece's start): each stratum wholly within the piece gets a
            // puff (the emit sampler's stratified ages), so the puffs are
            // as even across pieces as within one. The strata are dealt to
            // the two albedos in turn, the first's then the second's.
            let total = Int(((length - ahead) / puffs.spacing).rounded(.down))
            let from = ahead
            ahead = ahead + Double(total) * puffs.spacing - length
            guard total > 0 else { continue }
            let w = puffs.albedo[0].weight * Double(total) + carry
            let first = min(max(Int(w.rounded()), 0), total)
            carry = w - Double(first)
            // The age where the piece is d metres from its older end.
            func age(_ d: Double) -> Double { c.now - t0 - d / length * (t1 - t0) }
            // The strata whose newer end is still within the fade (the
            // newest, the piece's far end): each its own request, its puff at
            // that end, so that it spawns faded out, not jittered up to a
            // stratum into the fade. The older ones in two stratified
            // requests, one an albedo.
            let fading = fadeSeconds
            var fresh = total
            while fresh > 0 && age(from + Double(fresh) * puffs.spacing) < fading { fresh -= 1 }
            func emit(_ k: Int, strata lo: Int, count: Int, single: Bool) {
                guard count > 0 else { return }
                let m = puffs.depthLevel * Self.albedoLevels.count + k
                var r = EmitRequest(anchor: a, material: materials[m], count: count)
                // A puff of age a began at p1 − along (a − (now − t1)).
                r.origin = p1 + along * (c.now - t1)
                r.sourceVelocity = along
                // At rest in the air: a puff's slip of a few dm/s would
                // take minutes to die (quadratic drag), so none is given.
                r.velocity = wind - along
                r.radius = ((1 - Self.radiusSpread) * puffs.radius)...((1 + Self.radiusSpread) * puffs.radius)
                r.lifetime = Self.lifetime
                let near = from + Double(lo) * puffs.spacing, far = near + Double(count) * puffs.spacing
                r.ages = single ? max(0, age(far))...max(0, age(far)) : max(0, age(far))...max(0, age(near))
                r.seed = owner.nextSeed("trail \(m)")
                c.frame.emit(r)
                laid += count
            }
            let (k0, k1) = (puffs.albedo[0].level, puffs.albedo[1].level)
            emit(k0, strata: 0, count: min(first, fresh), single: false)
            emit(k1, strata: min(first, fresh), count: fresh - min(first, fresh), single: false)
            for j in fresh..<total { emit(j < first ? k0 : k1, strata: j, count: 1, single: true) }
        }
    }
}
