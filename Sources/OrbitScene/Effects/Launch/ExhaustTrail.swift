import Foundation
import OrbitCore

/// The S-IC's exhaust trail below 40 km (P4): a ribbon of smoke puffs laid
/// along the vehicle's path in LC-39A's body-fixed anchor, about half their
/// radius apart, at rest in the air they were left in. P3's particles then
/// carry every puff on the wind at its own height in the launch day's
/// sounding (`AirProfile`, from `sim.atmosphere(of:)`), so AS-506's
/// measured shear bends and twists the ribbon over the minutes it lives,
/// while each puff spreads (the material's `spreadRate`).
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
/// through the two ends' velocities would swing the ribbon uprange.
/// Along it puffs are laid at the S-IC's flow then, from the journal's
/// cutoffs, so a rebuild after CECO or OECO has the trail the frames laid.
/// Puffs are laid only below `ceiling` and above the ML deck.
public final class ExhaustTrail {
    /// The design's 40 km.
    public static let ceiling = 40_000.0
    /// How long a puff lives, s (L: Apollo's trails hung for minutes).
    public static let lifetime = 300.0...480.0
    /// A puff's radius where it is laid at altitude `h` (m), m: some 18 m
    /// near the ground, where the five plumes have mixed out to about three
    /// times the cluster's width, growing as the plume balloons in thinner
    /// air (L).
    public static func puffRadius(altitude h: Double) -> Double { 18 * pow(1 + max(h, 0) / 10_000, 0.8) }
    /// The spacing of the puffs along the path, m: half their radius, so
    /// the ribbon reads as one.
    public static func spacing(altitude h: Double) -> Double { 0.5 * puffRadius(altitude: h) }
    /// How far behind the nozzle exits the puffs are laid, m: past the
    /// visible flame, where the exhaust has slowed to the air's speed (L).
    public static func offset(altitude h: Double) -> Double { 30 + puffRadius(altitude: h) }
    /// The longest piece of path one request lays, s and m (one request
    /// has one velocity: the wind at the piece's middle), while the pieces
    /// a frame may lay suffice: `maxPieces`, or `maxRebuiltPieces` on a
    /// rebuilt path (about 38 km of it). A line's puffs fall at random along
    /// it, so short pieces also keep the ribbon even.
    public static let pieceTime = 1.0
    public static let pieceLength = 100.0
    public static let maxPieces = 128
    public static let maxRebuiltPieces = 384

    /// The share of the puffs in each material band (`LaunchMaterials.trail`):
    /// low to 6 km, mid to 18 km, high above, each crossfading over 4 km.
    public static func bandWeights(altitude h: Double) -> [Double] {
        func ramp(_ x: Double, _ at: Double) -> Double { min(1, max(0, (x - at + 2_000) / 4_000)) }
        let toMid = ramp(h, 6_000), toHigh = ramp(h, 18_000)
        return [1 - toMid, toMid - toHigh, toHigh]
    }

    /// A point of the path: where the puffs leave, in the pad's anchor, its
    /// velocity there and the epoch.
    struct Point {
        var epoch: Epoch
        var position: Vec3
        var velocity: Vec3
    }

    private var last: Point?
    private var carry = [0.0, 0.0, 0.0]
    /// Puffs laid since the reset (for the tests and the log).
    public private(set) var laid = 0

    public init() {}

    func reset() {
        last = nil
        carry = [0, 0, 0]
        laid = 0
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
        let behind = Self.offset(altitude: frame.altitude(of: centre.position))
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
            let back = Self.offset(altitude: frame.altitude(of: at.position))
            here = Point(epoch: at.epoch, position: at.position - along * back, velocity: at.velocity)
        } else {
            guard let p = c.frame.place(exits - Vec3.unitX * behind, of: v, in: a) else { return }
            here = Point(epoch: c.now, position: p.position, velocity: p.velocity)
        }
        defer { last = firing ? here : nil }
        if let l = last, l.epoch < c.now, !c.rebuilt {
            let curve = Curve.hermite(start: l.epoch, duration: c.now - l.epoch, p0: l.position, v0: l.velocity,
                                      p1: here.position, v1: here.velocity)
            lay(curve, &c, anchor: a, frame: frame, materials: materials, owner: owner, maxPieces: Self.maxPieces)
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
        let base = PadExhaust.exitHeightOnPad - Self.offset(altitude: c.site.placement.height)
        let pad = Point(epoch: c.firstMotion, position: c.toAnchor * Vec3(0, 0, base), velocity: .zero)
        let d = here.epoch - c.firstMotion, tp = LiftoffRise.programStart
        var curves: [Curve] = []
        if d <= tp {
            curves.append(Self.climb(from: pad, to: here, axes: c.toAnchor))
        } else {
            let pitch = Point(epoch: c.firstMotion + tp, position: pad.position + up * LiftoffRise.rise(after: tp),
                              velocity: up * LiftoffRise.speed(after: tp))
            curves.append(.hermite(start: pad.epoch, duration: tp, p0: pad.position, v0: .zero, p1: pitch.position,
                                   v1: pitch.velocity))
            curves.append(Self.climb(from: pitch, to: here, axes: c.toAnchor))
        }
        var left = Self.maxRebuiltPieces
        for (i, curve) in curves.enumerated() {
            let pieces = i == curves.count - 1 ? left : Int((curve.duration / Self.pieceTime).rounded(.up))
            lay(curve, &c, anchor: a, frame: frame, materials: materials, owner: owner, maxPieces: max(1, pieces))
            left = max(1, left - pieces)
        }
    }

    /// Lays `curve` in pieces of equal length.
    func lay(_ curve: Curve, _ c: inout LaunchEffects.Context, anchor a: EffectAnchorID, frame: AnchorFrame,
             materials: [ParticleMaterialID], owner: LaunchEffects, maxPieces: Int) {
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
            guard s0 > 0 || s1 > 0 else { continue }
            if s0 < 0 || s1 < 0 {
                let w = s0 / (s0 - s1)
                let cut = p0 + (p1 - p0) * w, at = t0 + (t1 - t0) * w
                if s0 < 0 { (p0, t0) = (cut, at) } else { (p1, t1) = (cut, at) }
            }
            let chord = p1 - p0, length = chord.length
            let mid = p0 + chord * 0.5
            let h = frame.altitude(of: mid)
            // Nor above the ceiling.
            guard length > 0, h < Self.ceiling else { continue }
            let flow = min(1, owner.flow(c, t0 + 0.5 * (t1 - t0)))
            let wind = air.map { $0.sample(altitude: h) }.map { frame.east * $0.windEast + frame.north * $0.windNorth } ?? .zero
            let puffs = length / Self.spacing(altitude: h) * flow
            for (band, w) in Self.bandWeights(altitude: h).enumerated() where w > 0 {
                let x = puffs * w + carry[band]
                let count = Int(x.rounded(.down))
                carry[band] = x - Double(count)
                guard count > 0 else { continue }
                var r = EmitRequest(anchor: a, material: materials[band], count: count)
                r.origin = p0
                r.axis = chord * (1 / length)
                r.shape = .line(length: length)
                // At rest in the air: a puff's slip of a few dm/s would
                // take minutes to die (quadratic drag), so none is given.
                r.velocity = wind
                let radius = Self.puffRadius(altitude: h)
                r.radius = (0.8 * radius)...(1.2 * radius)
                r.lifetime = Self.lifetime
                r.ages = max(0, c.now - t1)...max(0, c.now - t0)
                r.seed = owner.nextSeed("trail \(band)")
                c.frame.emit(r)
                laid += count
            }
        }
    }
}
