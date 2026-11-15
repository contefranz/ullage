import Foundation
import OrbitCore

/// The S-IC's exhaust trail below 40 km (P4): a ribbon of smoke puffs laid
/// along the vehicle's path in LC-39A's body-fixed anchor, each spaced about
/// its own radius from the next, at rest in the air it was left in. P3's
/// particles then carry every puff on the wind at its own height in the
/// launch day's sounding (`AirProfile`, from `sim.atmosphere(of:)`), so
/// AS-506's measured shear bends and twists the ribbon over the minutes it
/// lives, while each puff spreads (the material's `spreadRate`).
///
/// The path between two frames is the cubic through both frames' positions
/// and velocities (Hermite), laid in pieces of at most a second, each one
/// request with the pieces' true ages: at 1,000× a frame's 16.7 s of path
/// is still a curve, and its puffs have drifted as long as they have lived.
/// The first frame after a reset, in flight with the S-IC firing, rebuilds
/// the path from the pad at first motion to the vehicle now, the same
/// cubic over the whole climb (its shape L). Puffs are laid while the S-IC
/// fires below `ceiling` and the point they leave is above the ML deck.
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
    /// has one velocity: the wind at the piece's middle), and the most
    /// pieces a frame lays.
    public static let pieceTime = 1.0
    public static let pieceLength = 100.0
    public static let maxPieces = 32
    /// A rebuilt path's pieces at most: a line's puffs fall at random along
    /// it, so short pieces keep the ribbon even.
    public static let maxRebuiltPieces = 192

    /// The share of the puffs in each material band (`LaunchMaterials.trail`):
    /// low to 6 km, mid to 18 km, high above, each crossfading over 4 km.
    public static func bandWeights(altitude h: Double) -> [Double] {
        func ramp(_ x: Double, _ at: Double) -> Double { min(1, max(0, (x - at + 2_000) / 4_000)) }
        let toMid = ramp(h, 6_000), toHigh = ramp(h, 18_000)
        return [1 - toMid, toMid - toHigh, toHigh]
    }

    /// Where the trail was last laid: the point the puffs leave, in the
    /// pad's anchor, its velocity there and the epoch.
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

    /// The cubic through (p0, v0) at time 0 and (p1, v1) at `d`, at `u` in 0...1.
    static func hermite(_ p0: Vec3, _ v0: Vec3, _ p1: Vec3, _ v1: Vec3, duration d: Double, _ u: Double) -> Vec3 {
        let u2 = u * u, u3 = u2 * u
        return p0 * (2 * u3 - 3 * u2 + 1) + v0 * (d * (u3 - 2 * u2 + u)) + p1 * (-2 * u3 + 3 * u2) + v1 * (d * (u3 - u2))
    }

    func update(_ c: inout LaunchEffects.Context, materials: [ParticleMaterialID], owner: LaunchEffects) {
        let v = c.vehicle.vessel
        guard c.now > c.firstMotion || c.rebuilt, c.vehicle.flow > 0.05 || c.now <= c.firstMotion,
              let exits = Self.exitCentroid(v), let a = owner.anchor(&c), let frame = c.frame.anchorFrame(a),
              let centre = c.frame.place(exits, of: v, in: a)
        else {
            last = nil
            return
        }
        let altitude = frame.altitude(of: centre.position)
        let behind = Self.offset(altitude: altitude)
        guard let here = c.frame.place(exits - Vec3.unitX * behind, of: v, in: a) else { return }
        let now = Point(epoch: c.now, position: here.position, velocity: here.velocity)
        defer { last = now }
        let start: Point
        if let l = last, l.epoch < c.now {
            start = l
        } else if c.rebuilt, c.now > c.firstMotion {
            // From the pad at first motion: the exits on the deck's axis.
            let pad = c.toAnchor * Vec3(0, 0, PadExhaust.exitHeightOnPad - Self.offset(altitude: c.site.placement.height))
            start = Point(epoch: c.firstMotion, position: pad, velocity: .zero)
        } else {
            return
        }
        lay(from: start, to: now, &c, anchor: a, frame: frame, materials: materials, owner: owner,
            maxPieces: c.rebuilt ? Self.maxRebuiltPieces : Self.maxPieces)
    }

    /// Lays the path from `p` to `q` in pieces.
    func lay(from p: Point, to q: Point, _ c: inout LaunchEffects.Context, anchor a: EffectAnchorID, frame: AnchorFrame,
             materials: [ParticleMaterialID], owner: LaunchEffects, maxPieces: Int) {
        let d = q.epoch - p.epoch
        guard d > 0 else { return }
        let chord = (q.position - p.position).length
        let n = min(maxPieces, max(1, Int((d / Self.pieceTime).rounded(.up)), Int((chord / Self.pieceLength).rounded(.up))))
        let up = c.toAnchor * .unitZ
        let air = c.body.air
        var previous = p.position
        for i in 0..<n {
            let u1 = Double(i + 1) / Double(n)
            let next = i == n - 1 ? q.position : Self.hermite(p.position, p.velocity, q.position, q.velocity, duration: d, u1)
            defer { previous = next }
            let chord = next - previous, length = chord.length
            let mid = previous + chord * 0.5
            let h = frame.altitude(of: mid)
            // Not below the deck (the pad's exhaust is there) nor above the ceiling.
            guard length > 0, h < Self.ceiling, mid.dot(up) > 0 else { continue }
            let t0 = p.epoch + d * Double(i) / Double(n), t1 = p.epoch + d * u1
            let wind = air.map { $0.sample(altitude: h) }.map { frame.east * $0.windEast + frame.north * $0.windNorth } ?? .zero
            let puffs = length / Self.spacing(altitude: h) * min(1, c.vehicle.flow)
            for (band, w) in Self.bandWeights(altitude: h).enumerated() where w > 0 {
                let x = puffs * w + carry[band]
                let count = Int(x.rounded(.down))
                carry[band] = x - Double(count)
                guard count > 0 else { continue }
                var r = EmitRequest(anchor: a, material: materials[band], count: count)
                r.origin = previous
                r.axis = chord * (1 / length)
                r.shape = .line(length: length)
                // At rest in the air: a puff's slip of a few dm/s would
                // take minutes to die (quadratic drag), so none is given.
                r.velocity = wind
                let radius = Self.puffRadius(altitude: h)
                r.radius = (0.8 * radius)...(1.2 * radius)
                r.lifetime = Self.lifetime
                r.ages = (c.now - t1)...(c.now - t0)
                r.seed = owner.nextSeed("trail \(band)")
                c.frame.emit(r)
                laid += count
            }
        }
    }
}
