import Foundation
import OrbitCore

/// The trail's column of Gaussian nodes (look round 2, LR5 PR2), laid in
/// the pad's body-fixed anchor where P2's plume hands its exhaust over,
/// each closed form in its age (`TrailColumn.Node`): one every `spacing`
/// metres of the jet at the joint, which runs on from the vehicle at the
/// airspeed V and its excess u there, so every spacing V / (V + u) of the
/// S-IC's path through the air. Each carries P2's column over `spacing`,
/// and is along the path σ `jointAlong` (0.6 of its spacing there): as the
/// jet slows to the air they close up to spacing V / (V + u) apart, as the
/// exhaust does. `ExhaustTrail` feeds it the same pieces of path it
/// lays its puffs along: between frames the Hermite cubic, after a reset the
/// rebuilt climb. So a frame, a rebuild and any warp lay the same nodes at
/// the same epochs, and every node's state comes from its age alone.
///
/// Each node takes P2's hand-over as it was where the node was laid: the
/// frame's own near the vehicle, else the model's at the node's height,
/// airspeed and engines' flows (`ExhaustTrail.modelHead`, in
/// `ExhaustTrail.modelBin` bins). The exhaust laid below `groundCloudTop`
/// belongs to LR4's ground cloud (the stabilised cloud of TM X-2935's
/// accounting), so no node is laid there.
public final class TrailChain {
    /// The nodes' spacing along the jet at the joint, m.
    public static let spacing = 25.0
    /// A young node's σ along the path (0.6 of the spacing, so that a line
    /// of them is smooth to 0.2 %), m: the width of the kernel P2's
    /// hand-over fade is the complement of (`PlumeAirflow.trailFade`).
    public static let jointAlong = 0.6 * spacing
    /// How long a node is kept, s (L: Apollo's trails hung for minutes; by
    /// then a node has spread over hundreds of metres).
    public static let lifetime = 600.0
    /// The most nodes kept (40 km of path and more).
    public static let maximumNodes = 4_096
    /// The launch morning's convective mixed layer at the Cape: its top z_i
    /// (m) and velocity scale w* (m/s) (L, plan §6: a July morning at 09:32
    /// local, on the coast).
    public static let mixedLayerTop = 1_000.0
    public static let convective = 1.5
    /// The height above the deck below which LR4's ground cloud holds the
    /// exhaust (none laid here): LR4 proposes it (TM X-2935's stabilisation
    /// height, about 2.2 km for Apollo 16); 0 until it does.
    public static let groundCloudTop = 0.0
    /// The height span the air's gradients (N, the shear) are taken over, m.
    public static let gradientSpan = 200.0

    public private(set) var nodes: [TrailColumn.Node] = []
    /// The serial of `nodes[0]`: node i's is `first + i`, the count laid
    /// before it since the reset (what the drawn nodes merge on, `lod`).
    public private(set) var first = 0
    /// Where the next node lies, m from the next piece's start (at or
    /// before it).
    private var ahead = 0.0
    private var heads: [Int: PlumeAirflow.Handover] = [:]

    public init() {}

    func reset() {
        nodes = []
        first = 0
        ahead = 0
        heads = [:]
    }

    /// Drops the first `count` nodes.
    private func dropFirst(_ count: Int) {
        guard count > 0 else { return }
        nodes.removeFirst(count)
        first += count
    }

    /// The air at height `h` (m) in `profile` for a node whose path runs
    /// along `tangent` (the anchor's axes, `frame`'s up and east): its
    /// density and temperature, the buoyancy frequency from the
    /// temperature's lapse, N² = (g/T)(dT/dz + g/c_p), and the wind's shear
    /// across the path and in all, over `gradientSpan`.
    static func air(_ profile: AirProfile, height h: Double, tangent: Vec3, frame: AnchorFrame)
        -> (air: TrailColumn.Air, wind: Vec3) {
        let s = profile.sample(altitude: h)
        let lo = profile.sample(altitude: max(h - 0.5 * gradientSpan, 0)), hi = profile.sample(altitude: h + 0.5 * gradientSpan)
        let dz = h + 0.5 * gradientSpan - max(h - 0.5 * gradientSpan, 0)
        let g = 9.806_65
        let n2 = g / max(s.temperature, 100) * ((hi.temperature - lo.temperature) / dz + g / 1_004.7)
        func wind(_ x: (density: Double, temperature: Double, pressure: Double, windEast: Double, windNorth: Double))
            -> Vec3 { frame.east * x.windEast + frame.north * x.windNorth }
        let shear = (wind(hi) - wind(lo)) * (1 / dz)
        let across = tangent.cross(frame.up)
        let normal = across.length > 1e-6 ? shear.dot(across.normalized) : 0
        return (TrailColumn.Air(height: h, mixedLayerTop: mixedLayerTop, convective: convective,
                                frequency: max(n2, 0).squareRoot(), normalShear: normal, totalShear: shear.length,
                                density: s.density, temperature: s.temperature), wind(s))
    }

    /// Lays the nodes along `curve` from the lattice's place: each at its
    /// point and epoch, with the hand-over `live` gives within
    /// `ExhaustTrail.liveReach` of its height, else the model's.
    func lay(_ curve: ExhaustTrail.Curve, _ c: LaunchEffects.Context, frame: AnchorFrame, owner: LaunchEffects,
             live: (head: PlumeAirflow.Handover, altitude: Double)?, fullFlow: Double) {
        let d = curve.duration, length = curve.length
        guard d > 0, length > 0, let profile = c.body.air else { return }
        let up = c.toAnchor * .unitZ
        func windAt(_ p: Vec3) -> Vec3 {
            let x = profile.sample(altitude: frame.altitude(of: p))
            return frame.east * x.windEast + frame.north * x.windNorth
        }
        // The cumulative length of path through the air along the curve,
        // for the lattice's points: each step's ground chord less the
        // wind's drift over it (the wind at its middle).
        let m = max(32, Int(length / 5)), dt = d / Double(m)
        var lengths = [0.0], previous = curve.position(0)
        for k in 1...m {
            let p = curve.position(Double(k) / Double(m))
            lengths.append(lengths[k - 1] + ((p - previous) - windAt((p + previous) * 0.5) * dt).length)
            previous = p
        }
        func parameter(at s: Double) -> Double {
            guard let k = lengths.firstIndex(where: { $0 >= s }), k > 0 else { return 0 }
            let w = (s - lengths[k - 1]) / max(lengths[k] - lengths[k - 1], 1e-12)
            return (Double(k - 1) + w) / Double(m)
        }
        var s = ahead
        while s < lengths[m] {
            // The next node is `spacing` on along the jet at the joint:
            // as the vehicle flies V Δt through the air the joint's exhaust
            // runs (V + u) Δt from it, u the jet's excess there, so
            // spacing V / (V + u) on along the path through the air.
            var step = Self.spacing
            defer { s += step }
            guard s >= 0 else { continue }
            let u = parameter(at: s), p = curve.position(u), t = curve.start + d * u
            // Above the deck and the ground cloud's top, below the ceiling.
            let h = frame.altitude(of: p)
            guard p.dot(up) > Self.groundCloudTop, h < ExhaustTrail.ceiling else { continue }
            guard owner.flow(c, t) > 0.005 else { continue }
            // The path's velocity through the air, from the curve either
            // side: the node's line lies along it, as the wind carries the
            // nodes laid before.
            let du = 0.5 / Double(m), wind = windAt(p)
            func through(_ u: Double) -> Vec3 {
                let a = max(u - du, 0), b = min(u + du, 1)
                return (curve.position(b) - curve.position(a)) * (1 / ((b - a) * d)) - wind
            }
            let velocity = through(u), airspeed = velocity.length
            guard airspeed > 1e-3 else { continue }
            let tangent = velocity * (1 / airspeed)
            // The airspeed's rate over the piece, from its ends (the cubic's
            // speed wanders within it).
            let rate = (through(1).length - through(0).length) / d
            let (air, _) = Self.air(profile, height: h, tangent: tangent, frame: frame)
            let head: PlumeAirflow.Handover?
            if let l = live, abs(h - l.altitude) < ExhaustTrail.liveReach {
                head = l.head
            } else {
                let bin = Int((h / ExhaustTrail.modelBin).rounded(.down))
                if let cached = heads[bin] {
                    head = cached
                } else {
                    let sample = profile.sample(altitude: h)
                    head = ExhaustTrail.modelHead(c.vehicle.vessel, flow: { [cutoffs = owner.engineCutoffs(c)] name in
                        fullFlow * ExhaustTrail.engineFlow(name, at: t, cutoffs: cutoffs)
                    }, density: sample.density, temperature: sample.temperature, pressure: sample.pressure,
                                                  airspeed: airspeed, settings: c.frame.plumes)
                    heads[bin] = head
                }
            }
            guard let hd = head, let column = hd.column, let jet = hd.jet else { continue }
            step = Self.spacing * airspeed / (airspeed + max(jet.excess, 0))
            let heat = column.lineDensity * GroundCloud.exhaustHeat(ambient: air.temperature)
                * (1 - GroundCloud.radiantFraction)
            nodes.append(TrailColumn.Node(
                laid: t, position: p, tangent: tangent, up: frame.up, wind: wind, spacing: Self.spacing, column: column,
                coflow: TrailColumn.Coflow(halfWidth: jet.halfWidth, excess: jet.excess, stream: jet.airspeed),
                heat: heat, air: air, window: 2 * hd.window, acceleration: max(rate, 0)))
        }
        ahead = s - lengths[m]
        dropFirst(nodes.count - Self.maximumNodes)
    }

    /// Drops the nodes older than `lifetime` at `now` (the first ones: they
    /// are laid in order).
    func retire(at now: Epoch) {
        dropFirst(nodes.prefix { now - $0.laid > Self.lifetime }.count)
    }

    /// Where the frame's hand-over fades the young nodes in: P2's cluster
    /// origin and axis, and the window along it (m from the origin), in the
    /// pad anchor's axes.
    public struct Window: Equatable {
        public var origin: Vec3
        public var axis: Vec3
        public var range: ClosedRange<Double>

        public init(origin: Vec3, axis: Vec3, range: ClosedRange<Double>) {
            self.origin = origin
            self.axis = axis
            self.range = range
        }
    }

    /// A medium as the trail draws it: and the peak extinction of its line
    /// through it, C / (2π σv σw), C its extinction per metre along the
    /// path, for the shadows through the column (a node's own Gaussian holds
    /// only its share of what lies between the point and the Sun).
    public struct Drawn: Equatable {
        public var medium: GaussianMedium
        public var linePeak: Double

        public init(medium: GaussianMedium, linePeak: Double) {
            self.medium = medium
            self.linePeak = linePeak
        }
    }

    /// The nodes at `now` as Gaussian media in the anchor's axes, those
    /// laid by then, faded in (`fade`), merged far from `camera` (the
    /// anchor's axes; `lod`).
    public func anchorMedia(at now: Epoch, window: Window?, camera: Vec3? = nil) -> [Drawn] {
        let items = Self.drawn(nodes, first: first, at: now, window: window)
        return camera.map { Self.lod(items, camera: $0) } ?? items.map(\.drawn)
    }

    /// `nodes` (the first's serial `first`) at `now` as drawn in the
    /// anchor's axes, faded in (`fade`), each with its line's peak; those
    /// laid later or not yet in, none.
    public static func drawn(_ nodes: [TrailColumn.Node], first: Int, at now: Epoch, window: Window?)
        -> [(serial: Int, drawn: Drawn)] {
        var items: [(serial: Int, drawn: Drawn)] = []
        for (i, n) in nodes.enumerated() {
            let age = now - n.laid
            guard age >= 0 else { continue }
            var g = n.medium(age: age, faded: false)
            let fade = Self.fade(n, age: age, centre: g.centre, window: window)
            guard fade > 0 else { continue }
            g.peakExtinction *= fade
            let line = n.column.crossSection * fade / (2 * Double.pi * g.sigma.y * g.sigma.z)
            items.append((first + i, Drawn(medium: g, linePeak: line)))
        }
        return items
    }

    // MARK: Level of detail

    /// Where a ray runs down the trail it would cross a box a node, so
    /// runs of nodes are drawn as one, a power of two of them aligned on
    /// their serials (`lod`): no longer than `strideShare` of their
    /// distance (look round 2: about 25 boxes on a ray down the trail), and
    /// seen across the view no longer than `acrossWidths` of the trail's
    /// width (so that side-on, where nothing is gained, the line's ends and
    /// bends stay as sharp as its width), at most `largestStride`.
    public static let strideShare = 0.25
    public static let acrossWidths = 2.0
    public static let largestStride = 256

    /// How long a run may be at `g`, seen from `camera`, m.
    public static func allowedSpan(_ g: GaussianMedium, camera: Vec3) -> Double {
        let r = g.centre - camera, d = r.length
        guard d > 1e-6 else { return spacing }
        let across = g.axisU.cross(r * (1 / d)).length
        return min(strideShare * d, acrossWidths * max(g.sigma.y, g.sigma.z) / max(across, 1e-3))
    }

    /// The power of two of nodes `spacing` apart a run of `span` m holds.
    public static func stride(span: Double) -> Int {
        let want = span / spacing
        guard want >= 2 else { return 1 }
        return min(1 << Int(log2(want).rounded(.down)), largestStride)
    }

    /// `items` (laid in order, each with its serial) merged in aligned
    /// blocks of serials: a block of `largestStride` is drawn as one where
    /// even its most demanding member's `stride` (its `allowedSpan`)
    /// reaches the block's, else as its two halves, and so on down to the
    /// nodes. A block's own nodes alone merge (a gap in the serials, the
    /// head's nodes not yet faded in, cuts it). A run's σ along is 0.6 of
    /// the span allowed at its centre, which changes smoothly where the
    /// runs double in length (a σ that doubled from one run to the next
    /// would bump the line ±16 %), and is never less than 0.6 of its own
    /// span (no beads).
    public static func lod(_ items: [(serial: Int, drawn: Drawn)], camera: Vec3) -> [Drawn] {
        let need = items.map { stride(span: allowedSpan($0.drawn.medium, camera: camera)) }
        var out: [Drawn] = []
        func emit(_ lo: Int, _ hi: Int, size: Int) {
            guard lo < hi else { return }
            if size == 1 || need[lo..<hi].min()! >= size {
                if hi - lo == 1 {
                    out.append(items[lo].drawn)
                } else {
                    let run = merge(items[lo..<hi].map(\.drawn.medium))
                    out.append(Drawn(medium: widened(run.medium, along: 0.6 * allowedSpan(run.medium, camera: camera)),
                                     linePeak: run.linePeak))
                }
                return
            }
            let half = size / 2, middle = (items[lo].serial / size) * size + half
            var m = lo
            while m < hi && items[m].serial < middle { m += 1 }
            emit(lo, m, size: half)
            emit(m, hi, size: half)
        }
        var i = 0
        while i < items.count {
            let block = items[i].serial / largestStride
            var j = i + 1
            while j < items.count && items[j].serial / largestStride == block { j += 1 }
            emit(i, j, size: largestStride)
            i = j
        }
        return out
    }

    /// `g` at least `along` long (σ along its first axis), its extinction
    /// kept.
    static func widened(_ g: GaussianMedium, along: Double) -> GaussianMedium {
        guard along > g.sigma.x else { return g }
        var w = g
        w.peakExtinction *= g.sigma.x / along
        w.sigma.x = along
        return w
    }

    /// A run of nodes along the path as one Gaussian: their extinction, its
    /// centre and its covariance across the run's line (each one's and its
    /// centre's scatter), the albedo by extinction and the asymmetry by
    /// scattering; along the line σ 0.6 of the run's span (its ends' centres
    /// and one spacing), so that a line of runs is as smooth as one of
    /// nodes (moment matching alone, L/√12, would bead it).
    public static func merge(_ run: [GaussianMedium]) -> Drawn {
        guard let a = run.first, let b = run.last, run.count > 1 else {
            let g = run[0]
            return Drawn(medium: g, linePeak: g.peakExtinction * (2 * Double.pi).squareRoot() * g.sigma.x / spacing)
        }
        func mass(_ g: GaussianMedium) -> Double { g.peakExtinction * pow(2 * Double.pi, 1.5) * g.sigma.x * g.sigma.y * g.sigma.z }
        let masses = run.map(mass), total = masses.reduce(0, +)
        guard total > 0 else { return Drawn(medium: a, linePeak: 0) }
        let centre = zip(run, masses).reduce(Vec3.zero) { $0 + $1.0.centre * $1.1 } * (1 / total)
        let chord = b.centre - a.centre
        let t = chord.length > 1e-9 ? chord.normalized : a.axisU
        let span = chord.length * Double(run.count) / Double(run.count - 1)
        // The plane across t.
        let e1 = PlumeLook.perpendicular(t), e2 = t.cross(e1).normalized
        var c11 = 0.0, c12 = 0.0, c22 = 0.0
        for (g, m) in zip(run, masses) {
            let axes = [g.axisU, g.axisV, g.axisW], s = [g.sigma.x, g.sigma.y, g.sigma.z]
            for (k, axis) in axes.enumerated() {
                let p = axis.dot(e1), q = axis.dot(e2), v = s[k] * s[k]
                c11 += m * v * p * p
                c12 += m * v * p * q
                c22 += m * v * q * q
            }
            let r = g.centre - centre, p = r.dot(e1), q = r.dot(e2)
            c11 += m * p * p
            c12 += m * p * q
            c22 += m * q * q
        }
        c11 /= total
        c12 /= total
        c22 /= total
        let mean = 0.5 * (c11 + c22), diff = 0.5 * (c11 - c22), radius = (diff * diff + c12 * c12).squareRoot()
        let angle = 0.5 * atan2(2 * c12, c11 - c22)
        let major = (mean + radius).squareRoot(), minor = max(mean - radius, 1e-6).squareRoot()
        let along = max(0.6 * span, run.map(\.sigma.x).max() ?? 0)
        let u = e1 * cos(angle) + e2 * sin(angle)
        let sigma = Vec3(along, max(major, 1e-3), max(minor, 1e-3))
        var albedo = Spectrum3.zero, scattering = 0.0, g = 0.0
        for (x, m) in zip(run, masses) {
            albedo = albedo + x.albedo * m
            let w = m * x.albedo.g
            scattering += w
            g += w * x.asymmetry
        }
        let medium = GaussianMedium(centre: centre, axisU: t, axisV: u, sigma: sigma,
                                    peakExtinction: total / (pow(2 * Double.pi, 1.5) * sigma.x * sigma.y * sigma.z),
                                    albedo: albedo * (1 / total), asymmetry: scattering > 0 ? g / scattering : a.asymmetry)
        // Its line: its extinction over its span, per metre.
        return Drawn(medium: medium, linePeak: total / max(span, 1e-6) / (2 * Double.pi * sigma.y * sigma.z))
    }

    /// A node's fade in at age `age` whose centre is at `centre` (the
    /// anchor's axes): where the frame's hand-over is live (`window`), a
    /// young node as P2 fades out, linearly in how far its centre is into
    /// the window along P2's axis, so that P2's complement
    /// (`PlumeAirflow.trailFade`) and the trail sum to one whatever the
    /// vehicle's turning, climbing or speeding up does to the window; past
    /// twice the window's crossing at the airspeed, or with no hand-over,
    /// by its age (`Node.fade`).
    public static func fade(_ n: TrailColumn.Node, age: Double, centre: Vec3, window: Window?) -> Double {
        if let w = window, age < 2 * n.window / max(n.coflow.stream, 1) + 1 {
            let x = (centre - w.origin).dot(w.axis), r = w.range
            return min(max((x - r.lowerBound) / max(r.upperBound - r.lowerBound, 1e-6), 0), 1)
        }
        return n.fade(age: age)
    }

    /// `nodes` at `now` as Gaussian media in the anchor's axes, faded in
    /// (all fully in where not `faded`); those not yet in, none.
    public static func anchorMedia(_ nodes: [TrailColumn.Node], at now: Epoch, window: Window?,
                                   faded: Bool = true) -> [GaussianMedium] {
        nodes.compactMap { n in
            let age = now - n.laid
            guard age >= 0 else { return nil }
            var g = n.medium(age: age, faded: false)
            guard faded else { return g }
            let fade = Self.fade(n, age: age, centre: g.centre, window: window)
            guard fade > 0 else { return nil }
            g.peakExtinction *= fade
            return g
        }
    }

    /// `nodes` at `now` as Gaussian media in `frame`'s world (camera-
    /// relative), faded in about `head`'s window (its cluster's origin and
    /// axis, camera-relative), as `anchorMedia`.
    public static func media(_ nodes: [TrailColumn.Node], at now: Epoch, in frame: AnchorFrame,
                             head: PlumeAirflow.Handover? = nil, faded: Bool = true) -> [GaussianMedium] {
        let back = frame.toWorld.transposed
        let window = head.flatMap { h -> Window? in
            guard let o = h.origin, let a = h.axis, h.window > 0 else { return nil }
            return Window(origin: back * (o - frame.origin), axis: back * a, range: h.fadeWindow)
        }
        return anchorMedia(nodes, at: now, window: window, faded: faded).map { m in
            var g = m
            g.centre = frame.world(g.centre)
            g.axisU = frame.toWorld * g.axisU
            g.axisV = frame.toWorld * g.axisV
            return g
        }
    }
}
