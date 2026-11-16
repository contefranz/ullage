import Foundation
import OrbitCore

/// Plumes side by side drawn as one: the members of one engine family on
/// one vessel whose exits are close and whose axes agree (the S-IC's five
/// F-1s, the S-II's five J-2s), in one convex proxy the ray march runs in.
public struct PlumeCluster {
    /// A ring of the proxy's profile: x along the axis from `origin` and the
    /// radius there, m.
    public struct Ring: Equatable {
        public var x: Double
        public var r: Double
        public init(x: Double, r: Double) {
            self.x = x
            self.r = r
        }
    }

    /// How a cluster is drawn this frame.
    public enum Detail: Equatable {
        /// Too small to see: the vessel's far point carries it.
        case none
        /// Strips facing the camera, shaded from the look (`PlumeImpostor`).
        case impostor
        /// Ray-marched in its proxy.
        case march
    }

    public var members: [PlumeMember]
    /// Camera-relative point on the axis in the exits' plane, m, the unit
    /// axis, and two unit vectors across it (u, v, axis right-handed).
    public var origin: Vec3
    public var axis: Vec3
    public var u: Vec3, v: Vec3
    /// The proxy: a solid of revolution about the axis whose profile, the
    /// rings from first to last, is concave (its slopes never rise), so it
    /// is the intersection of one cone per edge and the slab between the
    /// end rings, and convex.
    public var rings: [Ring]
    /// Beyond `mergeX` along the axis (m from `origin`; 0 for none) the
    /// members' plumes have run together and `merged` stands for them all:
    /// one member on the axis, wider by their offsets (RMS) and as dense as
    /// all of them, the march's far field at the cost of one.
    public var merged: PlumeMember?
    public var mergeX = 0.0
    public var family: PlumeFamily
    public var isJet: Bool
    public var vesselID: UUID?

    public var start: Double { rings.first?.x ?? 0 }
    public var end: Double { rings.last?.x ?? 0 }

    /// The profile's radius at x (m), 0 outside it.
    public func radius(atX x: Double) -> Double {
        guard let first = rings.first, let last = rings.last, x >= first.x - 1e-9, x <= last.x + 1e-9 else { return 0 }
        let x = min(max(x, first.x), last.x)
        for k in 1..<rings.count where x <= rings[k].x {
            let a = rings[k - 1], b = rings[k]
            let t = b.x > a.x ? (x - a.x) / (b.x - a.x) : 1
            return a.r + (b.r - a.r) * t
        }
        return last.r
    }

    /// Whether the camera-relative point `p` is inside the proxy.
    public func contains(_ p: Vec3) -> Bool {
        let d = p - origin, x = d.dot(axis)
        return (d - axis * x).length <= radius(atX: x) + 1e-9 && x >= start - 1e-9 && x <= end + 1e-9
    }
}

/// Clustering, proxies and level of detail (P2), in double precision; the
/// renderer only packs what this gives.
public enum PlumeClusters {
    /// Members of one cluster at most (the march's loop).
    public static let maximumMembers = 8
    /// Rings of a proxy at most.
    public static let maximumRings = 8
    /// Axes within this of each other cluster (rad).
    public static let alignment = 12 * Double.pi / 180
    /// Exits closer than this many of their two radii summed cluster.
    public static let spacing = 3.0
    /// The proxy's margin over the members' extents.
    public static let margin = 1.04

    /// The clusters of `members`: by vessel and family, joined while their
    /// axes agree and their exits are close, at most `maximumMembers` each.
    public static func clusters(_ members: [PlumeMember]) -> [PlumeCluster] {
        var groups: [[PlumeMember]] = []
        for m in members {
            if let k = groups.firstIndex(where: { g in
                g.count < maximumMembers && g[0].vesselID == m.vesselID && g[0].family == m.family
                    && g[0].isJet == m.isJet && g.contains { joins($0, m) }
            }) {
                groups[k].append(m)
            } else {
                groups.append([m])
            }
        }
        return groups.map(cluster)
    }

    static func joins(_ a: PlumeMember, _ b: PlumeMember) -> Bool {
        a.axis.dot(b.axis) > cos(alignment)
            && (a.exit - b.exit).length < spacing * (a.exitRadius + b.exitRadius)
    }

    /// One cluster of `members`: its frame (the exits' mean, weighted by
    /// their areas, and the mean axis) and its proxy.
    public static func cluster(_ members: [PlumeMember]) -> PlumeCluster {
        var origin = Vec3.zero, axis = Vec3.zero, weight = 0.0
        for m in members {
            let w = m.exitRadius * m.exitRadius
            origin = origin + m.exit * w
            axis = axis + m.axis * w
            weight += w
        }
        origin = origin / max(weight, 1e-12)
        axis = axis.length > 0 ? axis.normalized : (members.first?.axis ?? .unitX)
        // The origin onto the most upstream exit's plane.
        let lowest = members.map { ($0.exit - origin).dot(axis) }.min() ?? 0
        origin = origin + axis * lowest
        let u = PlumeLook.perpendicular(axis), v = axis.cross(u).normalized
        let merge = merged(members, origin: origin, axis: axis)
        var c = PlumeCluster(members: members, origin: origin, axis: axis, u: u, v: v,
                             rings: proxy(members + (merge.map { [$0.member] } ?? []), origin: origin, axis: axis),
                             family: members.first?.family ?? .kerosene, isJet: members.first?.isJet ?? false,
                             vesselID: members.first?.vesselID)
        c.merged = merge?.member
        c.mergeX = merge?.x ?? 0
        return c
    }

    /// The merged far field of three or more members: from where a
    /// member's jet has grown to 0.9 of the furthest member's offset from
    /// the axis (they overlap there), if that is within 0.8 of their
    /// length. The member nearest the axis, moved onto it, its radius
    /// widened by the RMS offset, its density times N; no Mach disk or base
    /// of its own (the members keep theirs upstream).
    static func merged(_ members: [PlumeMember], origin: Vec3,
                       axis: Vec3) -> (member: PlumeMember, x: Double)? {
        guard members.count >= 3 else { return nil }
        let offsets = members.map { m -> Double in
            let d = m.exit - origin
            return (d - axis * d.dot(axis)).length
        }
        guard let far = offsets.max(), far > 0 else { return nil }
        let rms = (offsets.reduce(0) { $0 + $1 * $1 } / Double(offsets.count)).squareRoot()
        let base = members[offsets.firstIndex(of: offsets.min()!)!]
        let start = (base.exit - origin).dot(axis)
        var x = 0.0
        while x < 0.8 * base.length && base.radius(atX: x) < 0.9 * far { x += 0.25 * base.exitDiameter }
        guard x < 0.8 * base.length else { return nil }
        var m = base
        m.exit = origin + axis * start
        m.axis = axis
        m.radiusOffset = rms
        m.densityScale = Double(members.count)
        m.machDiskExtinction = 0
        m.baseExtinction = 0
        m.upstream = 0
        return (m, start + x)
    }

    /// The proxy's rings: the upper concave hull of every member's extent
    /// (each cross-section's circle at sampled x, at its offset and tilt
    /// from the cluster's axis), with a small margin, reduced to at most
    /// `maximumRings` by dropping the edges whose removal adds least.
    public static func proxy(_ members: [PlumeMember], origin: Vec3, axis: Vec3) -> [PlumeCluster.Ring] {
        var points: [PlumeCluster.Ring] = []
        for m in members {
            let sinTilt = (1 - min(1, m.axis.dot(axis) * m.axis.dot(axis))).squareRoot()
            let n = 40
            var xs: [Double] = []
            if m.upstream > 0 { xs += [-m.upstream, -0.5 * m.upstream] }
            for i in 0...n {
                // Denser near the exit, where the profile turns.
                let t = Double(i) / Double(n)
                xs.append(m.length * t * t)
            }
            for xm in xs {
                let c = m.exit + m.axis * xm - origin
                let xc = c.dot(axis)
                let rho = (c - axis * xc).length
                let e = m.extent(atX: xm)
                let r = (rho + e) * margin
                points.append(.init(x: xc - e * sinTilt, r: r))
                points.append(.init(x: xc + e * sinTilt, r: r))
            }
        }
        let hull = upperConcaveHull(points)
        return reduce(hull, to: maximumRings)
    }

    /// The upper hull of `points` by x (Andrew's monotone chain): the least
    /// concave polyline above them all, from the leftmost to the rightmost.
    public static func upperConcaveHull(_ points: [PlumeCluster.Ring]) -> [PlumeCluster.Ring] {
        let sorted = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.r > $1.r) }
        var hull: [PlumeCluster.Ring] = []
        for p in sorted {
            if let last = hull.last, last.x == p.x { continue }
            while hull.count >= 2 {
                let a = hull[hull.count - 2], b = hull[hull.count - 1]
                // Drop b while it lies on or below the chord from a to p.
                let cross = (b.x - a.x) * (p.r - a.r) - (b.r - a.r) * (p.x - a.x)
                if cross >= 0 { hull.removeLast() } else { break }
            }
            hull.append(p)
        }
        return hull
    }

    /// A concave profile with at most `limit` rings, containing `rings`: an
    /// edge at a time is dropped, its neighbours' lines extended to meet
    /// (or the end edge's neighbour to the end), choosing the drop that adds
    /// the least area.
    public static func reduce(_ rings: [PlumeCluster.Ring], to limit: Int) -> [PlumeCluster.Ring] {
        var p = rings
        func line(_ a: PlumeCluster.Ring, _ b: PlumeCluster.Ring) -> (Double, Double) {
            let slope = (b.r - a.r) / max(b.x - a.x, 1e-12)
            return (a.r - slope * a.x, slope)
        }
        func area(_ a: PlumeCluster.Ring, _ b: PlumeCluster.Ring, _ c: PlumeCluster.Ring) -> Double {
            abs((b.x - a.x) * (c.r - a.r) - (c.x - a.x) * (b.r - a.r)) / 2
        }
        while p.count > max(limit, 2) {
            var best: (cost: Double, edge: Int, ring: PlumeCluster.Ring)?
            let edges = p.count - 1
            for k in 0..<edges {
                // Dropping edge k (p[k] to p[k+1]).
                var replacement: PlumeCluster.Ring
                var cost: Double
                if k == 0 {
                    let (a, b) = line(p[1], p[2])
                    replacement = .init(x: p[0].x, r: a + b * p[0].x)
                    cost = area(p[0], replacement, p[1])
                } else if k == edges - 1 {
                    let (a, b) = line(p[k - 1], p[k])
                    replacement = .init(x: p[k + 1].x, r: a + b * p[k + 1].x)
                    cost = area(p[k], replacement, p[k + 1])
                } else {
                    let (a1, b1) = line(p[k - 1], p[k]), (a2, b2) = line(p[k + 1], p[k + 2])
                    guard b1 - b2 > 1e-12 else { continue }
                    let x = (a2 - a1) / (b1 - b2)
                    guard x >= p[k].x - 1e-9, x <= p[k + 1].x + 1e-9 else { continue }
                    replacement = .init(x: x, r: a1 + b1 * x)
                    cost = area(p[k], replacement, p[k + 1])
                }
                if best == nil || cost < best!.cost { best = (cost, k, replacement) }
            }
            guard let b = best else { break }
            if b.edge == 0 {
                p[0] = b.ring
                p.remove(at: 1)
            } else if b.edge == p.count - 2 {
                p[p.count - 1] = b.ring
                p.remove(at: p.count - 2)
            } else {
                p.replaceSubrange(b.edge...(b.edge + 1), with: [b.ring])
            }
        }
        return p.map { .init(x: $0.x, r: max($0.r, 1e-3)) }
    }

    /// How `c` is drawn: marched from `settings.marchPixels` across on
    /// screen (its length and width, at its nearest point), an impostor
    /// from `impostorPixels`, nothing below; attitude jets are impostors
    /// beyond `jetMarchDistance`, and so is a cluster only a readable glow
    /// shows. The camera inside a proxy marches it.
    public static func detail(_ c: PlumeCluster, camera: RenderScene.Camera,
                              settings: PlumeSettings) -> PlumeCluster.Detail {
        guard settings.enabled, settings.quality != .off else { return .none }
        let t = min(max((-c.origin).dot(c.axis), c.start), c.end)
        let nearest = c.origin + c.axis * t
        let distance = max(nearest.length - c.radius(atX: t), 0)
        let maxRadius = c.rings.map(\.r).max() ?? 0
        let size = max(c.end - c.start, 2 * maxRadius)
        let pixels = distance > 0 ? size / distance * camera.pixelsPerRadian : .infinity
        let marches = settings.quality.steps > 0 && pixels >= settings.marchPixels
            && (!c.isJet || distance <= settings.jetMarchDistance) && !c.members.allSatisfy(\.glowOnly)
        if marches { return .march }
        return pixels >= settings.impostorPixels ? .impostor : .none
    }
}

extension PlumeCluster {
    /// The interval of t over which the camera-relative ray `o + t d` lies
    /// in the proxy (`d` need not be unit), nil when it misses: the slab
    /// between the end rings intersected with each edge's cone, as
    /// PlumeShaders' march does it (`plume_coneInterval`).
    public func interval(origin o: Vec3, direction d: Vec3) -> ClosedRange<Double>? {
        let big = 1e30
        let rel = o - origin
        let ox = rel.dot(axis), dx = d.dot(axis)
        let op = rel - axis * ox, dp = d - axis * dx
        var enter = -big, exit = big
        if abs(dx) > 1e-12 {
            let t0 = (start - ox) / dx, t1 = (end - ox) / dx
            enter = max(enter, min(t0, t1))
            exit = min(exit, max(t0, t1))
        } else if ox < start || ox > end {
            return nil
        }
        for k in 1..<rings.count {
            let p0 = rings[k - 1], p1 = rings[k]
            let b = (p1.r - p0.r) / max(p1.x - p0.x, 1e-6)
            guard let span = PlumeClusters.coneInterval(ox: ox, dx: dx, op: op, dp: dp, a: p0.r - b * p0.x, b: b)
            else { return nil }
            enter = max(enter, span.lowerBound)
            exit = min(exit, span.upperBound)
        }
        return exit > enter ? enter...exit : nil
    }
}

extension PlumeClusters {
    /// Where `x(t) = ox + t dx`, perpendicular part `op + t dp`, lies in
    /// the cone r ≤ a + b x on its nappe a + b x ≥ 0; nil when nowhere.
    public static func coneInterval(ox: Double, dx: Double, op: Vec3, dp: Vec3, a: Double,
                                    b: Double) -> ClosedRange<Double>? {
        let big = 1e30
        let k = a + b * ox, kd = b * dx
        let qa = kd * kd - dp.dot(dp), qb = 2 * (kd * k - op.dot(dp)), qc = k * k - op.dot(op)
        var nappe = (-big, big)
        if abs(kd) > 1e-12 {
            let th = -k / kd
            nappe = kd > 0 ? (th, big) : (-big, th)
        } else if k < 0 {
            return nil
        }
        var inside: (Double, Double)
        if abs(qa) < 1e-12 {
            if abs(qb) < 1e-12 {
                guard qc >= 0 else { return nil }
                inside = (-big, big)
            } else {
                let t = -qc / qb
                inside = qb > 0 ? (t, big) : (-big, t)
            }
        } else {
            let disc = qb * qb - 4 * qa * qc
            if qa < 0 {
                guard disc >= 0 else { return nil }
                let q = disc.squareRoot()
                let t0 = (-qb + q) / (2 * qa), t1 = (-qb - q) / (2 * qa)
                inside = (min(t0, t1), max(t0, t1))
            } else if disc <= 0 {
                inside = (-big, big)
            } else {
                let q = disc.squareRoot()
                let t0 = (-qb - q) / (2 * qa), t1 = (-qb + q) / (2 * qa)
                inside = nappe.0 > -big ? (t1, big) : (-big, t0)
            }
        }
        let lo = max(inside.0, nappe.0), hi = min(inside.1, nappe.1)
        return hi >= lo ? lo...hi : nil
    }
}
