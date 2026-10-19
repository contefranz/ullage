import Foundation

/// Simple primitives used to draw a part until real meshes exist, in the part
/// frame (m). Each shape knows how to turn itself into triangles
/// (`triangles(offset:)`), so the renderer and the tests share one
/// tessellation.
public struct VisualShape {
    public enum Kind {
        case frustum(baseRadius: Double, topRadius: Double)
        case sphere(radius: Double)
        /// A surface of revolution about `axis` through `origin`: each profile
        /// point is a distance along the axis from `origin` and a radius,
        /// turned through `sweep` (rad, from `reference`, right-handed about
        /// the axis) in `segments` facets per full turn. The outside is to
        /// the left of the profile's direction of travel, with x to the right
        /// and r up: a profile running towards +x has its outside away from
        /// the axis. A sweep short of a full turn leaves the sides open.
        case revolution(profile: [ProfilePoint], segments: Int, sweep: ClosedRange<Double>)
    }

    /// A point of a `.revolution` profile: `x` along the axis, `r` from it (m).
    public struct ProfilePoint: Equatable {
        public var x: Double
        public var r: Double
        /// A sharp edge: the surface's normal is not smoothed across it.
        public var crease: Bool

        public init(_ x: Double, _ r: Double, crease: Bool = false) {
            self.x = x
            self.r = r
            self.crease = crease
        }
    }

    /// What the renderer does with a surface beyond lighting it.
    public enum EmissiveRole: Int {
        case none = 0
        /// The CM's ablator: glows with the entry heating.
        case heatShield = 1
    }

    /// A tessellated vertex, part frame plus the offset given (m).
    public struct Vertex: Equatable {
        public var position: Vec3
        public var normal: Vec3
    }

    public var kind: Kind
    /// Centre of the shape's base (frustum), centre (sphere) or profile
    /// origin (revolution), part frame, m.
    public var origin: Vec3
    /// Frustum axis and length (base -> top); for a revolution, the axis and
    /// the profile's extent along it.
    public var axis: Vec3
    public var length: Double
    /// Azimuth 0 of sweeps and facets, perpendicular to `axis`.
    public var reference: Vec3
    /// Linear RGB.
    public var color: (Double, Double, Double)
    /// Close the base (a frustum's base, a profile's first point) and the top
    /// with a disc. An open end shows the inside: set `twoSided` with it.
    public var capBase = true
    public var capTop = true
    /// Both faces are drawn, the back face lit with the normal reversed:
    /// nozzle bells, interstages, panels and shells, whose inside can be seen.
    public var twoSided = false
    /// Flat facets (face normals) instead of a smooth surface.
    public var faceted = false
    /// The thruster, by name in the same part, whose nozzle this is: the
    /// renderer turns the shape with the thruster's gimbal, about the
    /// thruster's position.
    public var thruster: String?
    public var emissive = EmissiveRole.none

    public init(kind: Kind, origin: Vec3, axis: Vec3, length: Double, reference: Vec3? = nil,
                color: (Double, Double, Double)) {
        let axis = axis.normalized
        self.kind = kind
        self.origin = origin
        self.axis = axis
        self.length = length
        self.reference = reference.map { ($0 - axis * $0.dot(axis)).normalized }
            ?? VisualShape.defaultReference(for: axis)
        self.color = color
    }

    public static func frustum(from origin: Vec3, length: Double, baseRadius: Double, topRadius: Double,
                               axis: Vec3 = .unitX, color: (Double, Double, Double)) -> VisualShape {
        VisualShape(kind: .frustum(baseRadius: baseRadius, topRadius: topRadius), origin: origin,
                    axis: axis, length: length, color: color)
    }

    /// A surface of revolution through `origin` along `axis`; see `Kind`.
    /// Its `length` is the profile's extent along the axis.
    public static func revolution(_ profile: [ProfilePoint], from origin: Vec3, axis: Vec3 = .unitX,
                                  reference: Vec3? = nil, segments: Int = 48,
                                  sweep: ClosedRange<Double> = 0...(2 * Double.pi),
                                  color: (Double, Double, Double)) -> VisualShape {
        let xs = profile.map(\.x)
        return VisualShape(kind: .revolution(profile: profile, segments: segments, sweep: sweep), origin: origin,
                           axis: axis, length: (xs.max() ?? 0) - (xs.min() ?? 0), reference: reference,
                           color: color)
    }

    /// Azimuth 0 when none is given: the axis crossed with x, or with y for an
    /// axis near x (+z for an axis along +x).
    public static func defaultReference(for axis: Vec3) -> Vec3 {
        let helper = abs(axis.x) < 0.9 ? Vec3.unitX : Vec3.unitY
        return axis.cross(helper).normalized
    }

    /// Part-frame point at `x` along the axis, `r` from it, at `azimuth` (rad).
    public func point(x: Double, r: Double, azimuth: Double) -> Vec3 {
        origin + axis * x + radial(azimuth) * r
    }

    /// Unit vector perpendicular to the axis at `azimuth`.
    public func radial(_ azimuth: Double) -> Vec3 {
        reference * cos(azimuth) + axis.cross(reference) * sin(azimuth)
    }

    /// Triangles, three vertices each, counter-clockwise seen from the side
    /// their normals point to (the outside), shifted by `offset`.
    public func triangles(offset: Vec3 = .zero) -> [Vertex] {
        var out: [Vertex]
        switch kind {
        case let .frustum(r0, r1):
            out = lathe([ProfilePoint(0, r0, crease: true), ProfilePoint(length, r1, crease: true)],
                        segments: 32, sweep: 0...(2 * Double.pi))
        case let .sphere(radius):
            let rings = 12
            let profile = (0...rings).map { i -> ProfilePoint in
                let t = Double.pi * Double(i) / Double(rings)
                return ProfilePoint(-radius * cos(t), radius * sin(t))
            }
            out = lathe(profile, segments: 24, sweep: 0...(2 * Double.pi))
        case let .revolution(profile, segments, sweep):
            out = lathe(profile, segments: segments, sweep: sweep)
        }
        if faceted {
            for i in stride(from: 0, to: out.count, by: 3) {
                let n = (out[i + 1].position - out[i].position).cross(out[i + 2].position - out[i].position).normalized
                for k in i..<i + 3 { out[k].normal = n }
            }
        }
        if offset != .zero {
            for i in out.indices { out[i].position += offset }
        }
        return out
    }

    /// The profile turned about the axis, with the caps the flags ask for.
    private func lathe(_ profile: [ProfilePoint], segments: Int, sweep: ClosedRange<Double>) -> [Vertex] {
        guard profile.count >= 2 else { return [] }
        let width = sweep.upperBound - sweep.lowerBound
        let n = max(1, Int((Double(segments) * width / (2 * Double.pi) - 1e-9).rounded(.up)))
        let azimuths = (0...n).map { sweep.lowerBound + width * Double($0) / Double(n) }
        let directions = azimuths.map(radial)

        // Outward normal of each profile segment in (along the axis, radial).
        let segmentNormals = zip(profile, profile.dropFirst()).map { a, b -> (Double, Double) in
            let dx = b.x - a.x, dr = b.r - a.r, l = (dx * dx + dr * dr).squareRoot()
            return l > 0 ? (-dr / l, dx / l) : (0, 0)
        }
        /// Normal at profile point `i` on segment `s` (`i` is `s` or `s + 1`),
        /// smoothed with the neighbouring segment unless `i` is a crease or an
        /// end; along the axis at a pole.
        func normal(_ i: Int, on s: Int) -> (Double, Double) {
            if profile[i].r == 0 { return (segmentNormals[s].0 < 0 ? -1 : 1, 0) }
            let other = i == s ? s - 1 : s + 1
            guard !profile[i].crease, other >= 0, other < segmentNormals.count else { return segmentNormals[s] }
            let a = segmentNormals[s], b = segmentNormals[other]
            let l = ((a.0 + b.0) * (a.0 + b.0) + (a.1 + b.1) * (a.1 + b.1)).squareRoot()
            return l > 0 ? ((a.0 + b.0) / l, (a.1 + b.1) / l) : a
        }
        func vertex(_ p: ProfilePoint, _ j: Int, _ nrm: (Double, Double)) -> Vertex {
            Vertex(position: origin + axis * p.x + directions[j] * p.r,
                   normal: (axis * nrm.0 + directions[j] * nrm.1).normalized)
        }

        var out: [Vertex] = []
        for s in 0..<(profile.count - 1) {
            let a = profile[s], b = profile[s + 1]
            guard segmentNormals[s] != (0, 0) else { continue }
            let na = normal(s, on: s), nb = normal(s + 1, on: s)
            for j in 0..<n {
                let a0 = vertex(a, j, na), a1 = vertex(a, j + 1, na)
                let b0 = vertex(b, j, nb), b1 = vertex(b, j + 1, nb)
                if a.r > 0 { out += [a0, a1, b1] }
                if b.r > 0 { out += [a0, b1, b0] }
            }
        }

        // Caps face away from the profile's run along the axis.
        let run: Double = profile[profile.count - 1].x >= profile[0].x ? 1 : -1
        func cap(_ p: ProfilePoint, facing sign: Double) {
            guard p.r > 0 else { return }
            let nrm = axis * sign, centre = Vertex(position: origin + axis * p.x, normal: nrm)
            for j in 0..<n {
                let r0 = Vertex(position: origin + axis * p.x + directions[j] * p.r, normal: nrm)
                let r1 = Vertex(position: origin + axis * p.x + directions[j + 1] * p.r, normal: nrm)
                out += sign > 0 ? [centre, r0, r1] : [centre, r1, r0]
            }
        }
        if capBase { cap(profile[0], facing: -run) }
        if capTop { cap(profile[profile.count - 1], facing: run) }
        return out
    }
}
