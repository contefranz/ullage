import Foundation
import OrbitCore

/// A plume's far field bent into the relative wind (track P2): the jet's
/// path in the stream (`JetPath`, OrbitCore) as lateral offsets of its
/// centreline from the nozzle's axis, which the field is sheared onto (x
/// along the axis, r from the bent centreline: `PlumeMember.sample(at:)`, the
/// shader's `plume_member`). The near field stays on the nozzle, gimbal and
/// all; far out the jet turns into the stream and slows to it.
public struct PlumeBend: Equatable {
    /// The stream's direction across the nozzle's axis (unit, world): the
    /// bend lies in the plane of the axis and the stream.
    public var direction: Vec3
    /// The centreline's offset towards `direction` at the `stations`
    /// stations x = length (k/(n-1))², m.
    public var offsets: [Double]
    /// The x the stations span, m.
    public var length: Double

    public static let stations = 8
    public static let none = PlumeBend(direction: .zero, offsets: [], length: 0)

    public init(direction: Vec3, offsets: [Double], length: Double) {
        self.direction = direction
        self.offsets = offsets
        self.length = length
    }

    /// The offset at x along the axis (m): between the stations linearly in
    /// √(x/length); 0 before the exit.
    public func offset(atX x: Double) -> Double {
        guard offsets.count == Self.stations, length > 0, x > 0 else { return 0 }
        let t = min((x / length).squareRoot(), 1) * Double(Self.stations - 1)
        let i = min(Int(t), Self.stations - 2), f = t - Double(i)
        return offsets[i] + (offsets[i + 1] - offsets[i]) * f
    }

    /// The largest offset, m.
    public var largest: Double { offsets.map(abs).max() ?? 0 }
}

/// The plumes in the airflow: their bend, and where the exhaust, slowed to
/// the air, is handed over to P4's trail.
public enum PlumeAirflow {
    /// Where the exhaust counts as at rest in the air, for the trail: its
    /// speed relative to the air down to 2 % of what it left the nozzle with
    /// (L; some 160 momentum diameters out in still air, past the plume
    /// drawn at the pad and at max-Q, so the built length rules there).
    public static let restFraction = 0.02
    /// The steepest the path may turn from the nozzle's axis and still be
    /// drawn as a bend of it (the shear's limit), rad: beyond, the jet has
    /// turned back into the stream (a retro's into the oncoming air) and the
    /// plume ends.
    public static let steepest = 70 * Double.pi / 180

    /// The member a cluster's jet takes its speed, stream and kind from: the
    /// one of the most flow (the first of those), so that an engine shutting
    /// down does not lead it.
    public static func lead(_ members: [PlumeMember]) -> PlumeMember? {
        members.max { $0.flowFraction < $1.flowFraction }
    }

    /// The path of a cluster's jets: one jet of their summed momentum
    /// (momentum diameters in quadrature) at the lead's speed, along
    /// `axis`, into the lead's relative wind; nil without one.
    public static func path(_ members: [PlumeMember], axis: Vec3, length: Double) -> [JetPath.Station]? {
        guard let lead = lead(members), lead.jetVelocity > 0, lead.relativeWind.length > 1e-3 else { return nil }
        let d = members.reduce(0) { $0 + $1.momentumDiameter * $1.momentumDiameter }.squareRoot()
        guard d > 0 else { return nil }
        return JetPath.path(diameter: d, speed: lead.jetVelocity, direction: axis, stream: lead.relativeWind,
                            length: length)
    }

    /// A cluster's jets in the stream: their centrelines' bend, where they
    /// stop being drawable (along the axis), and for a kerosene cluster the
    /// hand-over to P4's trail.
    public struct Airflow: Equatable {
        public var bend: PlumeBend
        public var end: Double?
        public var handover: Handover?
    }

    /// The airflow of `members` along `axis`, whose plumes reach `reach` m
    /// where nothing hands them over: P2's cluster draws it and P4's trail
    /// joins it (`trailHandover`), one reckoning. The path runs to twice
    /// the members' reach or built length, the bend over what is drawn: to
    /// the hand-over's window's end, or `reach`. Nil without a stream.
    public static func airflow(_ members: [PlumeMember], axis: Vec3, reach: Double) -> Airflow? {
        let built = members.map(\.builtLength).max() ?? 0
        guard max(reach, built) > 0,
              let path = path(members, axis: axis, length: 2 * max(reach, built)) else { return nil }
        let handover = handover(members, path: path, axis: axis)
        let (bend, end) = bend(path, axis: axis, length: handover.map { $0.x + $0.window } ?? reach)
        return Airflow(bend: bend, end: end, handover: handover)
    }

    /// The bend of a path along `axis` over `length` of it, and where along
    /// the axis it stops being drawable (the turn past `steepest`; nil if
    /// never).
    public static func bend(_ path: [JetPath.Station], axis: Vec3, length: Double) -> (bend: PlumeBend, end: Double?) {
        guard !path.isEmpty, length > 0 else { return (.none, nil) }
        // The stream across the axis, from the far end's heading (none for
        // a stream along the axis, either way).
        var across = Vec3.zero
        for s in path.reversed() {
            let lateral = s.position - axis * s.position.dot(axis)
            if lateral.length > 1e-9 { across = lateral.normalized; break }
        }
        // Where it turns past the steepest (a jet straight into the stream
        // too, where it stops and is swept back), and the offsets along x.
        // The end between the stations either side of the turn, on its
        // cosine, so that it moves continuously with the path.
        var points: [(x: Double, y: Double)] = []
        var end: Double?
        var previous: (x: Double, c: Double)?
        for s in path {
            let v = s.velocity.length > 1e-9 ? s.velocity.normalized : axis
            let c = v.dot(axis), x = s.position.dot(axis)
            if c < cos(steepest) {
                if let p = previous {
                    let f = (p.c - cos(steepest)) / max(p.c - c, 1e-12)
                    end = max(p.x + (x - p.x) * min(max(f, 0), 1), 0)
                } else {
                    end = 0
                }
                break
            }
            previous = (x, c)
            if let last = points.last, x <= last.x { continue }
            points.append((x, s.position.dot(across)))
        }
        guard across.length > 0.5 else { return (.none, end) }
        let span = min(length, end ?? length)
        func y(at x: Double) -> Double {
            guard let k = points.firstIndex(where: { $0.x >= x }) else { return points.last?.y ?? 0 }
            guard k > 0 else { return points[0].y }
            let a = points[k - 1], b = points[k]
            return a.y + (b.y - a.y) * (x - a.x) / max(b.x - a.x, 1e-12)
        }
        let n = PlumeBend.stations
        let offsets = (0..<n).map { k -> Double in
            let t = Double(k) / Double(n - 1)
            return y(at: span * t * t)
        }
        return (PlumeBend(direction: across, offsets: offsets, length: span), end)
    }

    /// How far along the path the exhaust has slowed to the air
    /// (`restFraction`), m; nil if not within the path.
    public static func restDistance(_ path: [JetPath.Station], stream: Vec3) -> Double? {
        guard let first = path.first else { return nil }
        let start = (first.velocity - stream).length
        guard start > 0 else { return nil }
        guard let k = path.firstIndex(where: { ($0.velocity - stream).length <= restFraction * start }) else {
            return nil
        }
        guard k > 0 else { return 0 }
        let a = path[k - 1], b = path[k]
        let ra = (a.velocity - stream).length, rb = (b.velocity - stream).length
        let f = (ra - restFraction * start) / max(ra - rb, 1e-12)
        return a.distance + (b.distance - a.distance) * f
    }

    /// The hand-over to P4's trail of a kerosene cluster's exhaust: where it
    /// has slowed to the air (`restDistance`), at most 85 % of its built
    /// length, as x along `axis` and the point on the path there (from the
    /// cluster's exits), with the half-width of the window the plume fades
    /// out over about it (15 % of x, at least two exit diameters); nil
    /// without a stream.
    public struct Handover: Equatable {
        public var x: Double
        public var point: Vec3
        public var window: Double
        /// The path's point at the window's start, x − window along the
        /// axis (from the cluster's exits, world axes): where the trail
        /// begins to take the exhaust over.
        public var start: Vec3
        /// P2's far field there, projected (`trailHandover` gives it; nil
        /// from `handover`).
        public var column: Column?
        /// The jet there as `JetPath` has it: its top-hat half-width (m), its
        /// speed relative to the air (m/s) and the air's past the vehicle
        /// (m/s), for the trail's coflow growth (`TrailColumn.Coflow`).
        public var jet: (halfWidth: Double, excess: Double, airspeed: Double)?
        /// The cluster's origin (camera-relative) and axis x is reckoned
        /// along, as P2's fade reckons it (`trailHandover` gives them; nil
        /// from `handover`): where the trail's young nodes take their fade
        /// (`TrailChain.media`).
        public var origin: Vec3?
        public var axis: Vec3?

        public init(x: Double, point: Vec3, window: Double, start: Vec3? = nil, column: Column? = nil,
                    jet: (halfWidth: Double, excess: Double, airspeed: Double)? = nil, origin: Vec3? = nil,
                    axis: Vec3? = nil) {
            self.x = x
            self.point = point
            self.window = window
            self.start = start ?? point
            self.column = column
            self.jet = jet
            self.origin = origin
            self.axis = axis
        }

        /// The window along the axis the trail's nodes fade in over and P2
        /// fades out about (`PlumeAirflow.trailFade`), m from the origin.
        public var fadeWindow: ClosedRange<Double> { max(x - window, 0)...(x + window) }

        public static func == (a: Handover, b: Handover) -> Bool {
            a.x == b.x && a.point == b.point && a.window == b.window && a.start == b.start && a.column == b.column
                && a.jet?.halfWidth == b.jet?.halfWidth && a.jet?.excess == b.jet?.excess
                && a.jet?.airspeed == b.jet?.airspeed && a.origin == b.origin && a.axis == b.axis
        }
    }

    /// The far field at the hand-over seen side-on, unfaded, its turbulence
    /// left out (the noise's mean): what P4's trail must carry on (LR5).
    /// Projected across the column: τ(y) = ∫ σ dz through the cluster's
    /// merged far field, radially symmetric about its axis.
    public struct Column: Equatable {
        /// τ through the axis, side-on.
        public var depth: Double
        /// ∫ τ dy across, m: the extinction per metre of column (κ λ for a
        /// smoke of mass extinction κ).
        public var crossSection: Double
        /// The soot's and the scattering's shares of it, m.
        public var sootCrossSection: Double
        public var scatteringCrossSection: Double
        /// The smoke's Henyey-Greenstein g.
        public var asymmetry: Double
        /// λ = ṁ / V_air, kg/m: the exhaust left in each metre of air the
        /// vehicle passes through (the airspeed at least 1 m/s).
        public var lineDensity: Double

        public init(depth: Double, crossSection: Double, sootCrossSection: Double, scatteringCrossSection: Double,
                    asymmetry: Double, lineDensity: Double) {
            self.depth = depth
            self.crossSection = crossSection
            self.sootCrossSection = sootCrossSection
            self.scatteringCrossSection = scatteringCrossSection
            self.asymmetry = asymmetry
            self.lineDensity = lineDensity
        }

        /// The column's single-scattering albedo.
        public var albedo: Double { crossSection > 0 ? scatteringCrossSection / crossSection : 0 }
        /// The full width at half maximum of the Gaussian of the same depth
        /// and cross-section, m: 2√(2 ln 2) C / (τ √(2π)).
        public var width: Double { depth > 0 ? 2.354_820_045 * crossSection / (depth * (2 * Double.pi).squareRoot()) : 0 }
        /// The soot's mass fraction of the exhaust it implies, for soot of
        /// mass extinction `massExtinction` (m²/kg): C_soot = κ Y λ.
        public func sootYield(massExtinction: Double) -> Double {
            lineDensity > 0 ? sootCrossSection / (lineDensity * massExtinction) : 0
        }
    }

    /// The column of the field `member` at x along its axis (m from its
    /// exit), unfaded and to any length: τ = 2 ∫ σ dr, C = 2π ∫ σ r dr by
    /// the midpoint rule over its field's extent; the soot is the field
    /// without its condensate (the kerosene gas phase).
    /// P2's hand-over fade at `x` along its axis (m): the complement of the
    /// trail's line seen side-on, whose nodes fade in linearly over
    /// `window` (a...b, `TrailColumn.Node.fade`), each a Gaussian of σ
    /// `along` along the path. That line is the ramp convolved with the
    /// Gaussian, R = (g(x − a) − g(x − b)) / (b − a), g(z) = z Φ(z/σ) +
    /// σ φ(z/σ), so P2's 1 − R and the trail's R sum to one at every x.
    /// 2.5σ before a and past b it is within 2e-3 σ/(b − a) of 1 and 0
    /// (φ(2.5) − 2.5 (1 − Φ(2.5))); with σ 0 it is the ramp's complement.
    public static func trailFade(_ x: Double, window w: ClosedRange<Double>, along sigma: Double) -> Double {
        let a = w.lowerBound, b = max(w.upperBound, a + 1e-6)
        guard sigma > 1e-9 else { return 1 - min(max((x - a) / (b - a), 0), 1) }
        func g(_ z: Double) -> Double {
            let u = z / sigma
            return z * 0.5 * (1 + GaussianMedium.erf(u / 2.0.squareRoot())) + sigma * exp(-0.5 * u * u) / (2 * Double.pi).squareRoot()
        }
        return min(max(1 - (g(x - a) - g(x - b)) / (b - a), 0), 1)
    }

    /// How far past the window's end P2's fade reaches, in σ along the
    /// path: there it is 2e-3 σ/(b − a) (under 1e-3 for any window over
    /// 2σ).
    public static let trailFadeReach = 2.5

    public static func column(_ member: PlumeMember, atX x: Double, lineDensity: Double) -> Column {
        var m = member
        m.length = 1e9
        m.fadeStart = nil
        m.handoverFade = nil
        m.visibleExtents = []
        var soot = m
        soot.particleExtinction = 0
        let n = 96, e = m.fieldExtent(atX: x), dr = e / Double(n)
        var depth = 0.0, c = 0.0, cs = 0.0, cscat = 0.0
        for i in 0..<n {
            let r = (Double(i) + 0.5) * dr
            let s = m.sample(x: x, r: r)
            depth += 2 * s.extinction * dr
            c += 2 * Double.pi * s.extinction * r * dr
            cscat += 2 * Double.pi * s.scattering * r * dr
            cs += 2 * Double.pi * soot.sample(x: x, r: r).extinction * r * dr
        }
        return Column(depth: depth, crossSection: c, sootCrossSection: cs, scatteringCrossSection: cscat,
                      asymmetry: m.phaseG, lineDensity: lineDensity)
    }

    public static func handover(_ members: [PlumeMember], path: [JetPath.Station], axis: Vec3) -> Handover? {
        guard let lead = lead(members), lead.family == .kerosene else { return nil }
        let built = members.map(\.builtLength).max() ?? 0
        guard built > 0 else { return nil }
        var x = 0.85 * built
        if let rest = restDistance(path, stream: lead.relativeWind) {
            x = min(x, point(path, at: rest).dot(axis))
        }
        guard x > 0 else { return nil }
        // The path's points at x along the axis and at the window's start.
        func at(_ x: Double) -> Vec3? {
            guard let k = path.firstIndex(where: { $0.position.dot(axis) >= x }) else { return nil }
            guard k > 0 else { return path[0].position }
            let a = path[k - 1], b = path[k]
            let xa = a.position.dot(axis), xb = b.position.dot(axis)
            return a.position + (b.position - a.position) * ((x - xa) / max(xb - xa, 1e-12))
        }
        // P2 fades out as the complement of the trail's nodes fading in
        // (`trailFade`), to `trailFadeReach` σ past the window's end, which
        // must lie within the plume as built: so the window ends that much
        // before the built length's end.
        let reach = trailFadeReach * TrailChain.jointAlong
        var window = max(0.15 * x, 2 * lead.exitDiameter)
        if x + window + reach > built {
            x = max((built - reach) / 1.15, 0)
            window = max(0.15 * x, 2 * lead.exitDiameter)
            x = min(x, built - reach - window)
        }
        guard x > 0, let p = at(x) else { return nil }
        // The jet's top-hat state there, between the stations either side.
        var jet: (halfWidth: Double, excess: Double, airspeed: Double)?
        if let k = path.firstIndex(where: { $0.position.dot(axis) >= x }) {
            let a = path[max(k - 1, 0)], b = path[k]
            let xa = a.position.dot(axis), xb = b.position.dot(axis)
            let f = k > 0 ? min(max((x - xa) / max(xb - xa, 1e-12), 0), 1) : 0
            let stream = lead.relativeWind
            let ea = (a.velocity - stream).length, eb = (b.velocity - stream).length
            jet = (a.halfWidth + (b.halfWidth - a.halfWidth) * f, ea + (eb - ea) * f, stream.length)
        }
        return Handover(x: x, point: p, window: window, start: at(max(x - window, 0)) ?? p, jet: jet)
    }

    /// The trail's hand-over for a vessel's S-IC: its firing F-1s' members
    /// (not jets), on their cluster's axis, through `airflow` exactly as
    /// P2's cluster reckons it (the built lengths, the same at any
    /// exposure); the point is from the cluster's origin, world axes. With
    /// its `column`: the cluster's merged far field there
    /// (`PlumeClusters.merged`, as P2's march has it beyond 1.15 of its
    /// merge), or with fewer than three engines the strongest's, as dense as
    /// all of them; and λ from the engines' flow (`ApolloExhaust`) at the
    /// lead's airspeed. For P4's `ExhaustTrail`.
    public static func trailHandover(_ emitters: [RenderScene.Emitter],
                                     settings: PlumeSettings = PlumeSettings()) -> Handover? {
        let firing = emitters.filter { $0.name.hasPrefix("S-IC engine") && !$0.isJet }
        let members = firing.compactMap { PlumeLook.member($0, settings: settings) }
        guard !members.isEmpty else { return nil }
        let (origin, axis) = PlumeClusters.frame(members)
        guard var h = airflow(members, axis: axis, reach: members.map(\.builtLength).max() ?? 0)?.handover,
              let lead = lead(members) else { return nil }
        let flow = firing.reduce(0.0) { s, e in
            s + e.flowFraction * (ApolloExhaust.engine(thruster: e.name, part: e.part)?.ratedFlow ?? 0)
        }
        let lambda = flow / max(lead.relativeWind.length, 1)
        h.origin = origin
        h.axis = axis
        if let merged = PlumeClusters.merged(members, origin: origin, axis: axis) {
            let x = h.x - (merged.member.exit - origin).dot(axis)
            h.column = column(merged.member, atX: x, lineDensity: lambda)
        } else {
            var m = lead
            m.densityScale *= members.reduce(0) { $0 + $1.flowFraction } / max(lead.flowFraction, 1e-6)
            h.column = column(m, atX: h.x - (m.exit - origin).dot(axis), lineDensity: lambda)
        }
        return h
    }

    /// The point on a path `distance` along it (from its source), m.
    public static func point(_ path: [JetPath.Station], at distance: Double) -> Vec3 {
        guard let k = path.firstIndex(where: { $0.distance >= distance }) else { return path.last?.position ?? .zero }
        guard k > 0 else { return path[0].position }
        let a = path[k - 1], b = path[k]
        let f = (distance - a.distance) / max(b.distance - a.distance, 1e-12)
        return a.position + (b.position - a.position) * f
    }
}
