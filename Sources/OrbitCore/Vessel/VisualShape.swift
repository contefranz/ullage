import Foundation

/// Simple primitives used to draw a part until real meshes exist, in the part
/// frame (m). Each shape knows how to turn itself into an indexed mesh
/// (`mesh(offset:)`) or a triangle list (`triangles(offset:)`), so the
/// renderer and the tests share one tessellation.
///
/// Every vertex carries surface coordinates (`SurfaceCoordinates`: u, v, r,
/// s) and a tangent, which paint, markings and procedural relief are built
/// on, in the shape's `surfaceFrame`.
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
        /// A section extruded along `axis` from `origin` through `stations`:
        /// tunnels, umbilical plates, radiator bands, fairings. The section's
        /// points are (a, b), a along `reference` and b along
        /// `axis × reference`, in either winding; each station scales them
        /// about the section's origin, so a station of zero width or height
        /// ends the prism in a point or an edge (a taper or a ramp). Every
        /// station is a sharp edge. The first and last stations are capped
        /// as `capBase` and `capTop` say, unless they have no area.
        case prism(section: [SectionPoint], stations: [PrismStation])
        /// A flat outline made `thickness` thick and centred on its plane:
        /// fins, canards, struts. The outline's points are (a, b), a along
        /// `axis` and b along `reference`, in either winding; the thickness
        /// is along `axis × reference`. A positive `bevel` chamfers the edges
        /// of both faces by that much (m), less than half the thickness.
        case plate(outline: [SectionPoint], thickness: Double, bevel: Double)
        /// A ring about `axis` through `origin`: the circle of `minorRadius`
        /// whose centre is `majorRadius` from the axis, turned about it in
        /// `segments` facets, the circle in `minorSegments`.
        case torus(majorRadius: Double, minorRadius: Double, segments: Int, minorSegments: Int)
        /// A box from `origin` along `axis` for `length`, `width` along
        /// `reference` and `height` along `axis × reference`, centred on the
        /// axis: RCS quad housings, APS module bodies, ballast blocks.
        case box(width: Double, height: Double)
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

    /// A point of a `.prism` section or a `.plate` outline, in that kind's
    /// (a, b) plane (m).
    public struct SectionPoint: Equatable {
        public var a: Double
        public var b: Double
        /// A sharp edge: the surface's normal is not smoothed across it.
        public var crease: Bool

        public init(_ a: Double, _ b: Double, crease: Bool = false) {
            self.a = a
            self.b = b
            self.crease = crease
        }
    }

    /// Where a `.prism`'s section sits along its axis (`x`, m from the
    /// origin) and how it is scaled there: `width` along `reference`,
    /// `height` along `axis × reference`, neither negative.
    public struct PrismStation: Equatable {
        public var x: Double
        public var width: Double
        public var height: Double

        public init(_ x: Double, width: Double = 1, height: Double = 1) {
            precondition(width >= 0 && height >= 0, "a prism station's scales cannot be negative")
            self.x = x
            self.width = width
            self.height = height
        }
    }

    /// What the renderer does with a surface beyond lighting it.
    public enum EmissiveRole: Int {
        case none = 0
        /// The CM's ablator: glows with the entry heating.
        case heatShield = 1
    }

    /// The frame a shape's surface coordinates are measured in.
    public enum SurfaceFrame: Equatable {
        /// The shape's own: u along its axis from its origin, v its azimuth
        /// from `reference` (right-handed about the axis), r the distance
        /// from the axis.
        case local
        /// The vehicle's construction frame (the Saturn V station frame in
        /// metres), whose origin is at `partOrigin` from the part frame's: u
        /// is construction x, so STA = u / 0.0254 plus the frame's offset; v
        /// the azimuth about the construction x axis from Position I (+z)
        /// towards Position II (-y); r the distance from that axis. For the
        /// shapes of revolution about the vehicle's axis, and for shapes off
        /// it that do not straddle it (fins, fairings, boxes): a shape that
        /// wraps round the axis without being a surface of revolution has no
        /// continuous v.
        case vehicle(partOrigin: Vec3)
    }

    /// Where a vertex lies on its shape, in its `surfaceFrame`.
    ///
    /// - u: along the axis (m);
    /// - v: azimuth (rad), continuous over the shape but for its seam (the
    ///   start of a full turn, a section's first point), so v·r is an arc
    ///   length in metres;
    /// - r: distance from the axis (m);
    /// - s: arc length (m) along the curve the shape is made from: a
    ///   revolution's profile from its first point (the frustum's base, the
    ///   sphere's -axis pole), carried on over the caps, negative over the
    ///   base cap and growing to the centre over the top cap; a torus's
    ///   minor circle from its outer equator, towards +axis; a prism's,
    ///   box's or plate's section or outline from its first point (in its
    ///   counter-clockwise order, see `Vertex.tangent`), its end faces
    ///   taking their edge's.
    public struct SurfaceCoordinates: Equatable {
        public var u: Double
        public var v: Double
        public var r: Double
        public var s: Double

        public init(u: Double, v: Double, r: Double, s: Double) {
            self.u = u
            self.v = v
            self.r = r
            self.s = s
        }
    }

    /// A tessellated vertex, part frame plus the offset given (m).
    public struct Vertex: Equatable {
        public var position: Vec3
        public var normal: Vec3
        /// Unit, perpendicular to `normal`: on a surface of revolution
        /// (frustum, sphere, revolution, torus) and its caps, along
        /// increasing azimuth about the shape's own axis, and so along
        /// increasing v in either frame for one about the vehicle's axis; on
        /// a prism, box or plate, along its section or outline in the
        /// counter-clockwise order (seen from +axis for a prism or box, from
        /// +(`axis` × `reference`) for a plate), on the end faces too.
        public var tangent: Vec3
        /// +1 or -1: `normal × tangent × tangentSign` is the bitangent, along
        /// increasing s on a surface of revolution's sides and caps, along
        /// +axis on a prism's or box's sides, along +(axis × reference)
        /// on a plate's; +1 on the end faces of prisms, boxes and plates.
        public var tangentSign: Double
        public var surface: SurfaceCoordinates
    }

    /// An indexed triangle mesh: three indices into `vertices` per triangle,
    /// counter-clockwise seen from the side the normals point to.
    public struct Mesh: Equatable {
        public var vertices: [Vertex] = []
        public var indices: [UInt32] = []

        public init() {}

        public var triangleCount: Int { indices.count / 3 }

        /// The triangles, three vertices each.
        public var triangles: [Vertex] { indices.map { vertices[Int($0)] } }
    }

    public var kind: Kind
    /// Centre of the shape's base (frustum, prism, box), centre (sphere,
    /// torus), profile origin (revolution) or outline origin, on the plate's
    /// mid-plane (plate), part frame, m.
    public var origin: Vec3
    /// Frustum axis and length (base -> top); for a revolution, the axis and
    /// the profile's extent along it; for a prism, its stations' extent; for
    /// a plate, its outline's extent along the axis; for a torus, twice its
    /// minor radius.
    public var axis: Vec3
    public var length: Double
    /// Azimuth 0 of sweeps and facets, perpendicular to `axis`.
    public var reference: Vec3
    /// Linear RGB: the material's base colour where the renderer has no
    /// entry for `material`.
    public var color: (Double, Double, Double)
    /// The surface's material, by name in the renderer's table.
    public var material = MaterialKey.unspecified
    /// The frame of the vertices' surface coordinates.
    public var surfaceFrame = SurfaceFrame.local
    /// Close the base (a frustum's base, a profile's first point, a prism's
    /// first station) and the top with a disc or face. An open end shows the
    /// inside: set `twoSided` with it.
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

    /// A prism of `section` from `origin` along `axis` through `stations`;
    /// see `Kind`.
    public static func prism(_ section: [SectionPoint], from origin: Vec3, axis: Vec3 = .unitX,
                             reference: Vec3? = nil, stations: [PrismStation],
                             color: (Double, Double, Double)) -> VisualShape {
        let xs = stations.map(\.x)
        return VisualShape(kind: .prism(section: section, stations: stations), origin: origin, axis: axis,
                           length: (xs.max() ?? 0) - (xs.min() ?? 0), reference: reference, color: color)
    }

    /// A straight prism of `section`, `length` long from `origin` along `axis`.
    public static func prism(_ section: [SectionPoint], from origin: Vec3, length: Double, axis: Vec3 = .unitX,
                             reference: Vec3? = nil, color: (Double, Double, Double)) -> VisualShape {
        prism(section, from: origin, axis: axis, reference: reference,
              stations: [PrismStation(0), PrismStation(length)], color: color)
    }

    /// A plate of `outline`, `thickness` thick, its outline's origin at
    /// `origin`; see `Kind`.
    public static func plate(_ outline: [SectionPoint], at origin: Vec3, axis: Vec3 = .unitX,
                             reference: Vec3? = nil, thickness: Double, bevel: Double = 0,
                             color: (Double, Double, Double)) -> VisualShape {
        precondition(thickness > 0 && bevel >= 0 && 2 * bevel < thickness, "a plate's bevel is under half its thickness")
        let xs = outline.map(\.a)
        return VisualShape(kind: .plate(outline: outline, thickness: thickness, bevel: bevel), origin: origin,
                           axis: axis, length: (xs.max() ?? 0) - (xs.min() ?? 0), reference: reference, color: color)
    }

    /// A torus about `axis` centred on `centre`; see `Kind`.
    public static func torus(centre: Vec3, axis: Vec3 = .unitX, reference: Vec3? = nil, majorRadius: Double,
                             minorRadius: Double, segments: Int = 48, minorSegments: Int = 16,
                             color: (Double, Double, Double)) -> VisualShape {
        VisualShape(kind: .torus(majorRadius: majorRadius, minorRadius: minorRadius, segments: segments,
                                 minorSegments: minorSegments),
                    origin: centre, axis: axis, length: 2 * minorRadius, reference: reference, color: color)
    }

    /// A box from `origin` along `axis`; see `Kind`.
    public static func box(from origin: Vec3, length: Double, width: Double, height: Double, axis: Vec3 = .unitX,
                           reference: Vec3? = nil, color: (Double, Double, Double)) -> VisualShape {
        VisualShape(kind: .box(width: width, height: height), origin: origin, axis: axis, length: length,
                    reference: reference, color: color)
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

    /// Azimuth (rad) of the construction-frame direction (`y`, `z`) about
    /// the vehicle's x axis, from Position I (+z) towards Position II (-y):
    /// Position III at π, Position IV at 3π/2 (or -π/2).
    public static func vehicleAzimuth(y: Double, z: Double) -> Double { atan2(-y, z) }

    /// Triangles, three vertices each, counter-clockwise seen from the side
    /// their normals point to (the outside), shifted by `offset`.
    public func triangles(offset: Vec3 = .zero) -> [Vertex] { mesh(offset: offset).triangles }

    /// The indexed mesh, shifted by `offset` (surface coordinates are not:
    /// they belong to the shape). Vertices are shared where a surface is
    /// smooth; creases, seams, caps and facets have their own.
    public func mesh(offset: Vec3 = .zero) -> Mesh {
        var m: Mesh
        switch kind {
        case let .frustum(r0, r1):
            m = lathe([ProfilePoint(0, r0, crease: true), ProfilePoint(length, r1, crease: true)],
                      segments: 32, sweep: 0...(2 * Double.pi))
        case let .sphere(radius):
            let rings = 12
            let profile = (0...rings).map { i -> ProfilePoint in
                let t = Double.pi * Double(i) / Double(rings)
                return ProfilePoint(-radius * cos(t), radius * sin(t))
            }
            m = lathe(profile, segments: 24, sweep: 0...(2 * Double.pi))
        case let .revolution(profile, segments, sweep):
            m = lathe(profile, segments: segments, sweep: sweep)
        case let .torus(major, minor, segments, minorSegments):
            m = torus(major: major, minor: minor, segments: segments, minorSegments: minorSegments)
        case let .prism(section, stations):
            m = prism(section, stations: stations)
        case let .box(width, height):
            let w = width / 2, h = height / 2
            m = prism([SectionPoint(-w, -h, crease: true), SectionPoint(w, -h, crease: true),
                       SectionPoint(w, h, crease: true), SectionPoint(-w, h, crease: true)],
                      stations: [PrismStation(0), PrismStation(length)])
        case let .plate(outline, thickness, bevel):
            m = plate(outline, thickness: thickness, bevel: bevel)
        }
        if faceted { m = Self.facet(m) }
        for i in m.vertices.indices {
            var v = m.vertices[i]
            // The tangent exactly perpendicular to the normal (facets tilt
            // the normal away from it).
            let t = v.tangent - v.normal * v.normal.dot(v.tangent)
            v.tangent = t.length > 1e-12 ? t.normalized : Self.anyPerpendicular(to: v.normal)
            if offset != .zero { v.position += offset }
            m.vertices[i] = v
        }
        return m
    }

    /// Each triangle on vertices of its own, with the face's normal.
    static func facet(_ m: Mesh) -> Mesh {
        var out = Mesh()
        out.vertices.reserveCapacity(m.indices.count)
        for i in stride(from: 0, to: m.indices.count, by: 3) {
            var v = (0..<3).map { m.vertices[Int(m.indices[i + $0])] }
            let n = (v[1].position - v[0].position).cross(v[2].position - v[0].position).normalized
            for k in 0..<3 {
                v[k].normal = n
                out.indices.append(UInt32(out.vertices.count))
                out.vertices.append(v[k])
            }
        }
        return out
    }

    static func anyPerpendicular(to n: Vec3) -> Vec3 {
        let helper = abs(n.x) < 0.9 ? Vec3.unitX : Vec3.unitY
        return n.cross(helper).normalized
    }

    /// `a` moved by whole turns to within half a turn of `near`.
    static func unwrap(_ a: Double, near: Double) -> Double {
        let turn = 2 * Double.pi
        return a - turn * ((a - near) / turn).rounded()
    }

    // MARK: Surface frames

    /// The construction-frame origin of the part frame when the shape's
    /// surface is measured in the vehicle's frame.
    var partOrigin: Vec3? {
        if case let .vehicle(o) = surfaceFrame { return o }
        return nil
    }

    /// For a surface of revolution about the vehicle's axis in the vehicle
    /// frame: the vehicle azimuth of `reference` and +1 or -1 as the shape's
    /// azimuth turns with the vehicle's or against it.
    var aboutVehicleAxis: (reference: Double, sense: Double)? {
        guard let o = partOrigin, abs(axis.x) > 1 - 1e-12 else { return nil }
        let c = origin + o
        guard (c.y * c.y + c.z * c.z).squareRoot() < 1e-9 else { return nil }
        return (Self.vehicleAzimuth(y: reference.y, z: reference.z), axis.x > 0 ? 1 : -1)
    }

    /// Surface coordinates of the part-frame point `p` in the vehicle frame
    /// (`partOrigin` `o`), its azimuth taken within half a turn of `near`.
    static func vehicleCoordinates(_ p: Vec3, partOrigin o: Vec3, near: Double, s: Double) -> SurfaceCoordinates {
        let c = p + o, r = (c.y * c.y + c.z * c.z).squareRoot()
        let v = r > 1e-12 ? unwrap(vehicleAzimuth(y: c.y, z: c.z), near: near) : near
        return SurfaceCoordinates(u: c.x, v: v, r: r, s: s)
    }

    /// Surface coordinates of the part-frame point `p` about the shape's own
    /// axis, its azimuth taken within half a turn of `near`.
    func localCoordinates(_ p: Vec3, near: Double, s: Double) -> SurfaceCoordinates {
        let d = p - origin, a = d.dot(reference), b = d.dot(axis.cross(reference))
        let r = (a * a + b * b).squareRoot()
        return SurfaceCoordinates(u: d.dot(axis), v: r > 1e-12 ? Self.unwrap(atan2(b, a), near: near) : near, r: r, s: s)
    }

    // MARK: Surfaces of revolution

    /// The profile turned about the axis, with the caps the flags ask for.
    private func lathe(_ profile: [ProfilePoint], segments: Int, sweep: ClosedRange<Double>) -> Mesh {
        guard profile.count >= 2 else { return Mesh() }
        let width = sweep.upperBound - sweep.lowerBound
        let n = max(1, Int((Double(segments) * width / (2 * Double.pi) - 1e-9).rounded(.up)))
        let azimuths = (0...n).map { sweep.lowerBound + width * Double($0) / Double(n) }
        let directions = azimuths.map(radial)
        let around = Around(shape: self, azimuths: azimuths, directions: directions)

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
        // Arc length along the profile at each point.
        var arc = [0.0]
        for (a, b) in zip(profile, profile.dropFirst()) {
            let dx = b.x - a.x, dr = b.r - a.r
            arc.append(arc[arc.count - 1] + (dx * dx + dr * dr).squareRoot())
        }

        var m = Mesh()
        /// The vertices of profile point `i` with normal `nrm` round the
        /// sweep; `travel` is the profile's direction there (along, radial).
        func row(_ i: Int, _ nrm: (Double, Double), travel: (Double, Double)) -> [UInt32] {
            let p = profile[i]
            return (0...n).map { j -> UInt32 in
                let position = origin + axis * p.x + directions[j] * p.r
                let normal = (axis * nrm.0 + directions[j] * nrm.1).normalized
                let along = axis * travel.0 + directions[j] * travel.1
                return m.add(Vertex(position: position, normal: normal, tangent: around.tangents[j],
                                    tangentSign: normal.cross(around.tangents[j]).dot(along) < 0 ? -1 : 1,
                                    surface: around.coordinates(position, x: p.x, r: p.r, j, s: arc[i])))
            }
        }

        // The row a segment ends on serves the next when the normal there is
        // smooth: the vertices are shared.
        var last: (point: Int, normal: (Double, Double), row: [UInt32])?
        for s in 0..<(profile.count - 1) {
            let a = profile[s], b = profile[s + 1]
            guard segmentNormals[s] != (0, 0) else { continue }
            let na = normal(s, on: s), nb = normal(s + 1, on: s)
            let travel = (b.x - a.x, b.r - a.r)
            let rowA: [UInt32]
            if let l = last, l.point == s, l.normal == na { rowA = l.row } else { rowA = row(s, na, travel: travel) }
            let rowB = row(s + 1, nb, travel: travel)
            last = (s + 1, nb, rowB)
            for j in 0..<n {
                if a.r > 0 { m.triangle(rowA[j], rowA[j + 1], rowB[j + 1]) }
                if b.r > 0 { m.triangle(rowA[j], rowB[j + 1], rowB[j]) }
            }
        }

        // Caps face away from the profile's run along the axis; s runs on
        // from the profile's ends, towards the centre over the top cap.
        let run: Double = profile[profile.count - 1].x >= profile[0].x ? 1 : -1
        func cap(_ i: Int, facing sign: Double) {
            let p = profile[i]
            guard p.r > 0 else { return }
            let nrm = axis * sign, centrePosition = origin + axis * p.x
            let centreS = arc[i] + (i == 0 ? -p.r : p.r)
            let rim = (0...n).map { j -> UInt32 in
                let position = origin + axis * p.x + directions[j] * p.r
                let outward = directions[j] * (i == 0 ? 1 : -1)
                return m.add(Vertex(position: position, normal: nrm, tangent: around.tangents[j],
                                    tangentSign: nrm.cross(around.tangents[j]).dot(outward) < 0 ? -1 : 1,
                                    surface: around.coordinates(position, x: p.x, r: p.r, j, s: arc[i])))
            }
            for j in 0..<n {
                let outward = directions[j] * (i == 0 ? 1 : -1)
                let centre = m.add(Vertex(position: centrePosition, normal: nrm, tangent: around.tangents[j],
                                          tangentSign: nrm.cross(around.tangents[j]).dot(outward) < 0 ? -1 : 1,
                                          surface: around.coordinates(centrePosition, x: p.x, r: 0, j, s: centreS)))
                if sign > 0 { m.triangle(centre, rim[j], rim[j + 1]) } else { m.triangle(centre, rim[j + 1], rim[j]) }
            }
        }
        if capBase { cap(0, facing: -run) }
        if capTop { cap(profile.count - 1, facing: run) }
        return m
    }

    /// The azimuth columns of a surface of revolution: each column's tangent
    /// and the surface coordinates of points on it.
    private struct Around {
        let shape: VisualShape
        let azimuths: [Double]
        /// Along increasing azimuth, about the vehicle's axis for a shape
        /// about it in the vehicle frame, else about the shape's own.
        let tangents: [Vec3]
        let vehicle: (reference: Double, sense: Double)?
        let partOrigin: Vec3?
        let centreAzimuth: Double

        init(shape: VisualShape, azimuths: [Double], directions: [Vec3]) {
            self.shape = shape
            self.azimuths = azimuths
            vehicle = shape.aboutVehicleAxis
            partOrigin = shape.partOrigin
            let sense = vehicle?.sense ?? 1
            tangents = directions.map { shape.axis.cross($0) * sense }
            let c = shape.origin + (partOrigin ?? .zero)
            centreAzimuth = VisualShape.vehicleAzimuth(y: c.y, z: c.z)
        }

        /// Coordinates of `position` (part frame), `x` along the axis and `r`
        /// from it on column `j`, at arc length `s`.
        func coordinates(_ position: Vec3, x: Double, r: Double, _ j: Int, s: Double) -> SurfaceCoordinates {
            if let o = partOrigin {
                if let vehicle {
                    return SurfaceCoordinates(u: position.x + o.x, v: vehicle.reference + vehicle.sense * azimuths[j],
                                              r: r, s: s)
                }
                return VisualShape.vehicleCoordinates(position, partOrigin: o, near: centreAzimuth, s: s)
            }
            return SurfaceCoordinates(u: x, v: azimuths[j], r: r, s: s)
        }
    }

    /// The minor circle turned about the axis: a grid shared all round, with
    /// seams at azimuth 0 and the outer equator.
    private func torus(major: Double, minor: Double, segments: Int, minorSegments: Int) -> Mesh {
        let n = max(3, segments), k = max(3, minorSegments)
        let azimuths = (0...n).map { 2 * Double.pi * Double($0) / Double(n) }
        let directions = azimuths.map(radial)
        let around = Around(shape: self, azimuths: azimuths, directions: directions)
        var m = Mesh()
        var rows: [[UInt32]] = []
        for i in 0...k {
            // From the outer equator towards +axis: the outside on the left.
            let beta = 2 * Double.pi * Double(i) / Double(k)
            let x = minor * sin(beta), r = major + minor * cos(beta)
            rows.append((0...n).map { j -> UInt32 in
                let position = origin + axis * x + directions[j] * r
                let normal = (axis * sin(beta) + directions[j] * cos(beta)).normalized
                let along = axis * cos(beta) - directions[j] * sin(beta)
                return m.add(Vertex(position: position, normal: normal, tangent: around.tangents[j],
                                    tangentSign: normal.cross(around.tangents[j]).dot(along) < 0 ? -1 : 1,
                                    surface: around.coordinates(position, x: x, r: r, j, s: minor * beta)))
            })
        }
        for i in 0..<k {
            for j in 0..<n {
                m.triangle(rows[i][j], rows[i][j + 1], rows[i + 1][j + 1])
                m.triangle(rows[i][j], rows[i + 1][j + 1], rows[i + 1][j])
            }
        }
        return m
    }

    // MARK: Prisms, boxes and plates

    /// The section through the stations, the section counter-clockwise
    /// about the axis.
    private func prism(_ section: [SectionPoint], stations: [PrismStation]) -> Mesh {
        guard section.count >= 3, stations.count >= 2 else { return Mesh() }
        let ring = Self.counterClockwise(section)
        let ordered = stations[0].x <= stations[stations.count - 1].x ? stations : Array(stations.reversed())
        let side = axis.cross(reference)
        let rings = ordered.map { st -> [Vec3] in
            let base: Vec3 = origin + axis * st.x
            return ring.map { p -> Vec3 in
                let across: Vec3 = reference * (p.a * st.width) + side * (p.b * st.height)
                return base + across
            }
        }
        let planes = ordered.map { st in ring.map { (a: $0.a * st.width, b: $0.b * st.height) } }
        return loft(rings: rings, planes: planes, creases: ring.map(\.crease), sweep: axis)
    }

    /// The outline thickened along `axis × reference`, its faces inset by
    /// the bevel.
    private func plate(_ outline: [SectionPoint], thickness: Double, bevel: Double) -> Mesh {
        guard outline.count >= 3 else { return Mesh() }
        let ring = Self.counterClockwise(outline)
        let normal = axis.cross(reference), half = thickness / 2
        let inset = bevel > 0 ? Self.inset(ring.map { (a: $0.a, b: $0.b) }, by: bevel) : ring.map { (a: $0.a, b: $0.b) }
        let full = ring.map { (a: $0.a, b: $0.b) }
        let layers: [(z: Double, plane: [(a: Double, b: Double)])] = bevel > 0
            ? [(-half, inset), (-half + bevel, full), (half - bevel, full), (half, inset)]
            : [(-half, full), (half, full)]
        let rings = layers.map { layer -> [Vec3] in
            let base: Vec3 = origin + normal * layer.z
            return layer.plane.map { p -> Vec3 in
                let inPlane: Vec3 = axis * p.a + reference * p.b
                return base + inPlane
            }
        }
        return loft(rings: rings, planes: layers.map { $0.plane }, creases: ring.map(\.crease), sweep: normal)
    }

    /// `points` in counter-clockwise order (positive area in (a, b)).
    static func counterClockwise(_ points: [SectionPoint]) -> [SectionPoint] {
        signedArea(points.map { (a: $0.a, b: $0.b) }) < 0 ? points.reversed() : points
    }

    static func signedArea(_ p: [(a: Double, b: Double)]) -> Double {
        var area = 0.0
        for i in p.indices {
            let q = p[(i + 1) % p.count]
            area += p[i].a * q.b - q.a * p[i].b
        }
        return area / 2
    }

    /// A counter-clockwise polygon moved inwards by `d`, each corner mitred.
    static func inset(_ p: [(a: Double, b: Double)], by d: Double) -> [(a: Double, b: Double)] {
        p.indices.map { i -> (a: Double, b: Double) in
            let prev = p[(i + p.count - 1) % p.count], next = p[(i + 1) % p.count], c = p[i]
            func inward(_ from: (a: Double, b: Double), _ to: (a: Double, b: Double)) -> (a: Double, b: Double) {
                let ea = to.a - from.a, eb = to.b - from.b, l = (ea * ea + eb * eb).squareRoot()
                return l > 0 ? (-eb / l, ea / l) : (0, 0)
            }
            let n1 = inward(prev, c), n2 = inward(c, next)
            let k = 1 + n1.a * n2.a + n1.b * n2.b
            guard k > 1e-9 else { return (c.a + d * n1.a, c.b + d * n1.b) }
            return (c.a + d * (n1.a + n2.a) / k, c.b + d * (n1.b + n2.b) / k)
        }
    }

    /// Rings of the same number of points, each counter-clockwise about
    /// `sweep` (unit), joined band by band, every ring a sharp edge; the
    /// first and last capped as the flags say (`planes` are their points in
    /// a counter-clockwise 2D frame, for the caps). A point that is not a
    /// crease is smooth round its ring; the first point is the seam of s and v.
    private func loft(rings: [[Vec3]], planes: [[(a: Double, b: Double)]], creases: [Bool], sweep: Vec3) -> Mesh {
        let count = rings[0].count
        let partOrigin = partOrigin
        // Azimuth reference: the shape's centre about the vehicle's axis, or
        // the first point's about the shape's own.
        let centroid = rings.joined().reduce(Vec3.zero, +) / Double(rings.count * count)
        let centreAzimuth: Double = {
            guard let o = partOrigin else { return 0 }
            let c = centroid + o
            return Self.vehicleAzimuth(y: c.y, z: c.z)
        }()

        func coordinates(_ p: Vec3, near: Double, s: Double) -> SurfaceCoordinates {
            if let o = partOrigin { return Self.vehicleCoordinates(p, partOrigin: o, near: near, s: s) }
            return localCoordinates(p, near: near, s: s)
        }

        // Each ring's points: the surface coordinates going round (s and v
        // unwrapped from the first point, which closes the ring as a seam),
        // v kept within half a turn of the previous ring's.
        var arcs: [[Double]] = [], azimuths: [[Double]] = [], seams: [(s: Double, v: Double)] = []
        for (k, ring) in rings.enumerated() {
            var s = [0.0], v: [Double] = []
            for i in 0..<count {
                let near = k > 0 ? azimuths[k - 1][i] : (i > 0 ? v[i - 1] : centreAzimuth)
                v.append(coordinates(ring[i], near: near, s: 0).v)
                if i > 0 { s.append(s[i - 1] + (ring[i] - ring[i - 1]).length) }
            }
            let perimeter = s[count - 1] + (ring[0] - ring[count - 1]).length
            seams.append((s: perimeter, v: coordinates(ring[0], near: v[count - 1], s: 0).v))
            arcs.append(s)
            azimuths.append(v)
        }
        /// Surface coordinates of point `i` of ring `k`, at the seam's end
        /// of the ring if `closing`.
        func surface(_ k: Int, _ i: Int, closing: Bool = false) -> SurfaceCoordinates {
            var c = coordinates(rings[k][i], near: azimuths[k][i], s: arcs[k][i])
            if closing { c.v = seams[k].v; c.s = seams[k].s }
            return c
        }
        /// Unit direction of edge `i` (point `i` to `i + 1`), from whichever
        /// of the band's rings has it.
        func edge(_ ring: [Vec3], _ other: [Vec3], _ i: Int) -> Vec3 {
            let e = ring[(i + 1) % count] - ring[i]
            return e.length > 1e-12 ? e.normalized : (other[(i + 1) % count] - other[i]).normalized
        }

        var m = Mesh()
        for k in 0..<(rings.count - 1) {
            let a = rings[k], b = rings[k + 1]
            // Each quad's outward normal, nil where it has no area.
            let faces = (0..<count).map { i -> Vec3? in
                let p0 = a[i], p1 = a[(i + 1) % count], q0 = b[i], q1 = b[(i + 1) % count]
                var n = (p1 - p0).cross(q1 - p0)
                if n.length < 1e-12 { n = (q1 - p0).cross(q0 - p0) }
                return n.length < 1e-12 ? nil : n.normalized
            }
            let edges = (0..<count).map { edge(a, b, $0) }
            // The vertices at point i, where edge i starts (right) and where
            // edge i - 1 ends (left); one pair if the point is smooth.
            var right: [(UInt32, UInt32)] = [], left: [(UInt32, UInt32)] = []
            for i in 0..<count {
                let before = (i + count - 1) % count
                let fl = faces[before] ?? faces[i], fr = faces[i] ?? faces[before]
                func pair(_ normal: Vec3?, _ tangent: Vec3, closing: Bool) -> (UInt32, UInt32) {
                    let n = normal ?? sweep
                    let sign: Double = n.cross(tangent).dot(sweep) < 0 ? -1 : 1
                    return (m.add(Vertex(position: a[i], normal: n, tangent: tangent, tangentSign: sign,
                                         surface: surface(k, i, closing: closing))),
                            m.add(Vertex(position: b[i], normal: n, tangent: tangent, tangentSign: sign,
                                         surface: surface(k + 1, i, closing: closing))))
                }
                if creases[i] || fl == nil || fr == nil {
                    right.append(pair(fr, edges[i], closing: false))
                    left.append(pair(fl, edges[before], closing: i == 0))
                } else {
                    let n = (fl! + fr!).normalized, t = (edges[before] + edges[i]).normalized
                    let p = pair(n, t, closing: false)
                    right.append(p)
                    left.append(i == 0 ? pair(n, t, closing: true) : p)
                }
            }
            for i in 0..<count where faces[i] != nil {
                let j = (i + 1) % count
                let (a0, b0) = right[i], (a1, b1) = left[j]
                m.triangle(ifArea: a0, a1, b1)
                m.triangle(ifArea: a0, b1, b0)
            }
        }

        // The end faces: a fan from the centroid of a convex face, else
        // ear-clipped; the base faces -sweep, the top +sweep.
        func cap(_ k: Int, facing sign: Double) {
            let plane = planes[k]
            guard abs(Self.signedArea(plane)) > 1e-12 else { return }
            let ring = rings[k], other = rings[k == 0 ? 1 : k - 1], nrm = sweep * sign
            let tangents = (0..<count).map { i -> Vec3 in
                (edge(ring, other, (i + count - 1) % count) + edge(ring, other, i)).normalized
            }
            func add(_ i: Int, closing: Bool = false) -> UInt32 {
                m.add(Vertex(position: ring[i], normal: nrm, tangent: tangents[i], tangentSign: 1,
                             surface: surface(k, i, closing: closing)))
            }
            func triangle(_ x: UInt32, _ y: UInt32, _ z: UInt32) {
                if sign > 0 { m.triangle(ifArea: x, y, z) } else { m.triangle(ifArea: x, z, y) }
            }
            if Self.isConvex(plane) {
                let centre = ring.reduce(Vec3.zero, +) / Double(count)
                let rim = (0..<count).map { add($0) } + [add(0, closing: true)]
                for i in 0..<count {
                    let at = surface(k, i)
                    var c = coordinates(centre, near: at.v, s: at.s)
                    if c.r < 1e-12 { c.v = at.v }
                    let centreIndex = m.add(Vertex(position: centre, normal: nrm, tangent: edge(ring, other, i),
                                                   tangentSign: 1, surface: c))
                    triangle(centreIndex, rim[i], rim[i + 1])
                }
            } else {
                let rim = (0..<count).map { add($0) }
                for t in Self.earClip(plane) { triangle(rim[t.0], rim[t.1], rim[t.2]) }
            }
        }
        if capBase { cap(0, facing: -1) }
        if capTop { cap(rings.count - 1, facing: 1) }
        return m
    }

    static func isConvex(_ p: [(a: Double, b: Double)]) -> Bool {
        let scale = p.reduce(0) { max($0, abs($1.a), abs($1.b)) }
        for i in p.indices {
            let o = p[(i + p.count - 1) % p.count], a = p[i], b = p[(i + 1) % p.count]
            let cross = (a.a - o.a) * (b.b - a.b) - (a.b - o.b) * (b.a - a.a)
            if cross < -1e-12 * scale * scale { return false }
        }
        return true
    }

    /// Triangles of a simple counter-clockwise polygon, counter-clockwise,
    /// by ear clipping.
    static func earClip(_ p: [(a: Double, b: Double)]) -> [(Int, Int, Int)] {
        var left = Array(p.indices), out: [(Int, Int, Int)] = []
        func cross(_ o: Int, _ a: Int, _ b: Int) -> Double {
            (p[a].a - p[o].a) * (p[b].b - p[o].b) - (p[a].b - p[o].b) * (p[b].a - p[o].a)
        }
        func inside(_ x: Int, _ a: Int, _ b: Int, _ c: Int) -> Bool {
            cross(a, b, x) >= 0 && cross(b, c, x) >= 0 && cross(c, a, x) >= 0
        }
        while left.count > 3 {
            var clipped = false
            for k in left.indices {
                let a = left[(k + left.count - 1) % left.count], b = left[k], c = left[(k + 1) % left.count]
                guard cross(a, b, c) > 0 else { continue }
                let blocked = left.contains { x in x != a && x != b && x != c && inside(x, a, b, c) }
                guard !blocked else { continue }
                out.append((a, b, c))
                left.remove(at: k)
                clipped = true
                break
            }
            // Degenerate rest: fan it.
            if !clipped {
                for k in 1..<(left.count - 1) { out.append((left[0], left[k], left[k + 1])) }
                return out
            }
        }
        out.append((left[0], left[1], left[2]))
        return out
    }
}

extension VisualShape.Mesh {
    mutating func add(_ v: VisualShape.Vertex) -> UInt32 {
        vertices.append(v)
        return UInt32(vertices.count - 1)
    }

    mutating func triangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) { indices += [a, b, c] }

    /// A triangle, unless it has no area.
    mutating func triangle(ifArea a: UInt32, _ b: UInt32, _ c: UInt32) {
        let p = vertices[Int(a)].position, q = vertices[Int(b)].position, r = vertices[Int(c)].position
        guard (q - p).cross(r - p).length > 1e-14 else { return }
        triangle(a, b, c)
    }
}

/// Names a surface's material in the renderer's material table; a shape's
/// `color` stands in where the table has no entry.
public struct MaterialKey: Hashable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public var description: String { rawValue }

    /// No material given: the renderer's default, in the shape's colour.
    public static let unspecified: MaterialKey = "unspecified"
}

/// A point or region of a part that effects attach to: where plumes and
/// particles leave the vehicle's geometry. Part frame, m, like the part's
/// shapes; the dresser (`VesselLibrary.dressApollo`) sets them.
public struct VisualAttachment: Equatable {
    public enum Kind: Equatable {
        /// A solid retro motor's nozzle exit.
        case retroPort
        /// A solid ullage motor's nozzle exit.
        case ullageExit
        /// A propellant or gas vent's outlet.
        case vent
        /// A plane the part separates on: its pyrotechnic ring or joint.
        case separationPlane
        /// A band of skin over a cryogenic tank that sheds frost and ice.
        case frostZone
    }

    public var name: String
    public var kind: Kind
    /// The outlet's centre (port, vent), the plane's centre, or the centre
    /// of the zone's start on the axis it runs along.
    public var position: Vec3
    /// Unit: the flow out of a port or vent; the plane's normal, away from
    /// the part; the way the zone runs.
    public var direction: Vec3
    /// The outlet's, the plane's or the zone's radius (m); 0 when not known.
    public var radius: Double
    /// The zone's extent along `direction` (m); 0 for the other kinds.
    public var length: Double
    /// The thruster, by name in the same part, that fires through a port.
    public var thruster: String?

    public init(name: String, kind: Kind, position: Vec3, direction: Vec3, radius: Double = 0, length: Double = 0,
                thruster: String? = nil) {
        self.name = name
        self.kind = kind
        self.position = position
        self.direction = direction.normalized
        self.radius = radius
        self.length = length
        self.thruster = thruster
    }
}
