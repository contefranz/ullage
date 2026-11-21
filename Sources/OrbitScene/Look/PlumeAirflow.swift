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
        var points: [(x: Double, y: Double)] = []
        var end: Double?
        for s in path {
            let v = s.velocity.length > 1e-9 ? s.velocity.normalized : axis
            if v.dot(axis) < cos(steepest) {
                end = points.last?.x ?? 0
                break
            }
            let x = s.position.dot(axis)
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
        // The path's point at x along the axis.
        guard let k = path.firstIndex(where: { $0.position.dot(axis) >= x }) else { return nil }
        let p: Vec3
        if k == 0 {
            p = path[0].position
        } else {
            let a = path[k - 1], b = path[k]
            let xa = a.position.dot(axis), xb = b.position.dot(axis)
            p = a.position + (b.position - a.position) * ((x - xa) / max(xb - xa, 1e-12))
        }
        return Handover(x: x, point: p, window: max(0.15 * x, 2 * lead.exitDiameter))
    }

    /// The trail's hand-over for a vessel's S-IC: its firing F-1s' members
    /// (not jets), on their cluster's axis, through `airflow` exactly as
    /// P2's cluster reckons it (the built lengths, the same at any
    /// exposure); the point is from the cluster's origin, world axes. For
    /// P4's `ExhaustTrail`.
    public static func trailHandover(_ emitters: [RenderScene.Emitter],
                                     settings: PlumeSettings = PlumeSettings()) -> Handover? {
        let members = emitters.filter { $0.name.hasPrefix("S-IC engine") && !$0.isJet }
            .compactMap { PlumeLook.member($0, settings: settings) }
        guard !members.isEmpty else { return nil }
        let axis = PlumeClusters.frame(members).axis
        return airflow(members, axis: axis, reach: members.map(\.builtLength).max() ?? 0)?.handover
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
