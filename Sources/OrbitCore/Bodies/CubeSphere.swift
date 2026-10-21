import Foundation

/// The cube sphere that addresses a body's surface tiles (M1.6 Earth and Moon
/// design §3): the six faces of a cube centred on the body, each projected
/// from the centre onto the unit sphere and cut into a quadtree of tiles.
///
/// A face is a gnomonic projection (straight lines on the face are great
/// circles) whose two coordinates are each warped by a tangent, a = tan(πs/4)
/// for s in [-1, 1] (Google's S2 "tangent" projection). The warp makes the
/// arc along the face's centre lines uniform in s; the area a step in s and t
/// covers is largest at the face centre and smallest at the edge midpoints, in
/// the ratio √2 (`areaRatio`), against 5.2 for the unwarped cube. Lines of
/// constant s are lines of constant a, so tile edges are great-circle arcs.
///
/// Face coordinates (u, v) = ((s + 1)/2, (t + 1)/2) run from 0 to 1 across a
/// face: they are what tiles and textures address. Directions are unit
/// vectors in the body-fixed frame; on an ellipsoid they are directions in
/// figure coordinates (z stretched by a/b, where the figure is a sphere of
/// radius a: `Ellipsoid.surfacePoint(figureDirection:)`), the coordinates the
/// planet shader ray-traces in.
public enum CubeSphere {
    /// A cube face, by its outward normal. Seen from outside with +v up, u
    /// runs to the right: the equatorial faces have u east and v north, the
    /// polar faces u along +y, and the frame (u, v, normal) is right-handed.
    public enum Face: Int, CaseIterable, Codable, Comparable {
        /// Normal +x (longitude 0°), u +y, v +z.
        case posX
        /// Normal +y (90° E), u -x, v +z.
        case posY
        /// Normal -x (180°), u -y, v +z.
        case negX
        /// Normal -y (90° W), u +x, v +z.
        case negY
        /// Normal +z (the north pole), u +y, v -x.
        case posZ
        /// Normal -z (the south pole), u +y, v +x.
        case negZ

        public static func < (a: Face, b: Face) -> Bool { a.rawValue < b.rawValue }

        public var normal: Vec3 { axes.normal.vector }
        /// The direction u increases along, at the face centre.
        public var uAxis: Vec3 { axes.u.vector }
        /// The direction v increases along, at the face centre.
        public var vAxis: Vec3 { axes.v.vector }

        var axes: (normal: Axis, u: Axis, v: Axis) {
            switch self {
            case .posX: return (Axis(1, 0, 0), Axis(0, 1, 0), Axis(0, 0, 1))
            case .posY: return (Axis(0, 1, 0), Axis(-1, 0, 0), Axis(0, 0, 1))
            case .negX: return (Axis(-1, 0, 0), Axis(0, -1, 0), Axis(0, 0, 1))
            case .negY: return (Axis(0, -1, 0), Axis(1, 0, 0), Axis(0, 0, 1))
            case .posZ: return (Axis(0, 0, 1), Axis(0, 1, 0), Axis(-1, 0, 0))
            case .negZ: return (Axis(0, 0, -1), Axis(0, 1, 0), Axis(1, 0, 0))
            }
        }

        /// The face whose outward normal is `axis`.
        init(normal axis: Axis) {
            self = Face.allCases.first { $0.axes.normal == axis }!
        }
    }

    /// An integer unit vector: the cube's axes, for exact edge arithmetic.
    struct Axis: Equatable {
        let x: Int, y: Int, z: Int
        init(_ x: Int, _ y: Int, _ z: Int) { self.x = x; self.y = y; self.z = z }
        var vector: Vec3 { Vec3(Double(x), Double(y), Double(z)) }
        static prefix func - (a: Axis) -> Axis { Axis(-a.x, -a.y, -a.z) }
    }

    /// Max/min of the area a step in u and v covers, over a face: √2, between
    /// the face centre (largest) and the edge midpoints (smallest).
    public static let areaRatio = 2.0.squareRoot()
    /// The largest arc a step in u or v covers, against the face's centre
    /// lines (`tileAngle`): 2/√3, along a corner's anti-diagonal.
    public static let maxLinearScale = 2 / 3.0.squareRoot()
    /// The smallest: 2/3, along a corner's diagonal.
    public static let minLinearScale = 2.0 / 3

    /// The angle a tile at `level` spans along a face's centre lines, rad:
    /// (π/2) / 2^level, its nominal size. Elsewhere on the face a tile edge
    /// spans `minLinearScale` to `maxLinearScale` times this.
    public static func tileAngle(level: Int) -> Double {
        Double.pi / 2 / Double(1 << level)
    }

    /// The number of tiles at `level`: 6 · 4^level.
    public static func tileCount(level: Int) -> Int { 6 << (2 * level) }

    /// Cube-face coordinate a (the gnomonic tan of the angle from the face
    /// centre) of warped coordinate s: tan(πs/4).
    @inlinable public static func unwarp(_ s: Double) -> Double { tan(Double.pi / 4 * s) }
    /// Warped coordinate s of cube-face coordinate a: (4/π) atan(a).
    @inlinable public static func warp(_ a: Double) -> Double { atan(a) * (4 / Double.pi) }

    /// The unit direction at face coordinates (u, v). u and v may run past
    /// [0, 1] into the neighbouring faces, by less than half a face, along
    /// this face's projection: tile borders are sampled so.
    public static func direction(face: Face, u: Double, v: Double) -> Vec3 {
        cubePoint(face: face, a: unwarp(2 * u - 1), b: unwarp(2 * v - 1)).normalized
    }

    /// The point (normal + a·uAxis + b·vAxis) on the cube of half-side 1.
    static func cubePoint(face: Face, a: Double, b: Double) -> Vec3 {
        switch face {
        case .posX: return Vec3(1, a, b)
        case .posY: return Vec3(-a, 1, b)
        case .negX: return Vec3(-1, -a, b)
        case .negY: return Vec3(a, -1, b)
        case .posZ: return Vec3(-b, a, 1)
        case .negZ: return Vec3(b, a, -1)
        }
    }

    /// The face whose cone holds `direction` (any non-zero vector, not
    /// necessarily unit) and its face coordinates there, each in [0, 1]. A
    /// direction on an edge between faces goes to the first of them in the
    /// order x, y, z.
    public static func faceCoordinates(_ direction: Vec3) -> (face: Face, u: Double, v: Double) {
        let x = direction.x, y = direction.y, z = direction.z
        let ax = abs(x), ay = abs(y), az = abs(z)
        let face: Face, a: Double, b: Double
        if ax >= ay && ax >= az {
            face = x >= 0 ? .posX : .negX
            a = x >= 0 ? y / ax : -y / ax
            b = z / ax
        } else if ay >= az {
            face = y >= 0 ? .posY : .negY
            a = y >= 0 ? -x / ay : x / ay
            b = z / ay
        } else {
            face = z >= 0 ? .posZ : .negZ
            a = y / az
            b = z >= 0 ? -x / az : x / az
        }
        let u = (warp(a) + 1) / 2, v = (warp(b) + 1) / 2
        return (face, min(1, max(0, u)), min(1, max(0, v)))
    }
}

/// A tile of the cube sphere: the square of face coordinates [x, x+1)/2^level
/// by [y, y+1)/2^level on `face`. Level 0 is the whole face; each level
/// splits a tile into four.
public struct TileKey: Hashable, Comparable, Codable, CustomStringConvertible {
    public let face: CubeSphere.Face
    public let level: Int
    /// Column, along u: 0 ..< 2^level.
    public let x: Int
    /// Row, along v: 0 ..< 2^level.
    public let y: Int

    /// The deepest level a key can address: at 27 an Earth tile is about 7 cm.
    public static let maxLevel = 27

    public init(face: CubeSphere.Face, level: Int, x: Int, y: Int) {
        precondition(level >= 0 && level <= TileKey.maxLevel, "tile level \(level)")
        precondition(x >= 0 && y >= 0 && x < 1 << level && y < 1 << level, "tile \(x), \(y) at level \(level)")
        self.face = face; self.level = level; self.x = x; self.y = y
    }

    /// The level-0 tile: the whole face.
    public static func root(_ face: CubeSphere.Face) -> TileKey { TileKey(face: face, level: 0, x: 0, y: 0) }
    /// The six faces' tiles.
    public static let roots = CubeSphere.Face.allCases.map(root)

    public var description: String { "\(face)/\(level)/\(x)/\(y)" }

    /// Tiles across a face at this level, 2^level.
    public var tilesAcross: Int { 1 << level }

    // MARK: Identifier

    /// A 64-bit identifier, unique per tile: face in bits 60-62, level in
    /// 55-59, y in 27-53 and x in 0-26. Ordering by it groups a face's
    /// tiles by level, then by row; the tile file's index is sorted by it.
    public var id: UInt64 {
        UInt64(face.rawValue) << 60 | UInt64(level) << 55 | UInt64(y) << 27 | UInt64(x)
    }

    /// The tile of identifier `id`, nil if it addresses none.
    public init?(id: UInt64) {
        let mask: UInt64 = (1 << 27) - 1
        guard id >> 63 == 0, id & (1 << 54) == 0, let face = CubeSphere.Face(rawValue: Int(id >> 60)) else {
            return nil
        }
        let level = Int(id >> 55 & 31), y = Int(id >> 27 & mask), x = Int(id & mask)
        guard level <= TileKey.maxLevel, x < 1 << level, y < 1 << level else { return nil }
        self.init(face: face, level: level, x: x, y: y)
    }

    public static func < (a: TileKey, b: TileKey) -> Bool { a.id < b.id }

    /// Coded as its identifier, checked on decoding.
    public init(from decoder: Decoder) throws {
        let id = try decoder.singleValueContainer().decode(UInt64.self)
        guard let key = TileKey(id: id) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "tile id \(id)"))
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(id)
    }

    // MARK: Hierarchy

    /// The tile one level up, nil at level 0.
    public var parent: TileKey? {
        level == 0 ? nil : TileKey(face: face, level: level - 1, x: x >> 1, y: y >> 1)
    }

    /// The four tiles one level down, in the order (x, y), (x+1, y), (x, y+1),
    /// (x+1, y+1) of their columns and rows.
    public var children: [TileKey] {
        let l = level + 1, cx = 2 * x, cy = 2 * y
        return [TileKey(face: face, level: l, x: cx, y: cy), TileKey(face: face, level: l, x: cx + 1, y: cy),
                TileKey(face: face, level: l, x: cx, y: cy + 1), TileKey(face: face, level: l, x: cx + 1, y: cy + 1)]
    }

    /// The tile at `level` (at most this one's) that contains this one.
    public func ancestor(atLevel level: Int) -> TileKey {
        precondition(level >= 0 && level <= self.level, "ancestor level \(level) of \(self)")
        let shift = self.level - level
        return TileKey(face: face, level: level, x: x >> shift, y: y >> shift)
    }

    /// Whether `other` is this tile or lies inside it.
    public func contains(_ other: TileKey) -> Bool {
        other.face == face && other.level >= level && other.ancestor(atLevel: level) == self
    }

    // MARK: Face coordinates

    /// The tile's square of face coordinates: u from u0 to u1, v from v0 to v1.
    public var bounds: (u0: Double, v0: Double, u1: Double, v1: Double) {
        let n = Double(tilesAcross)
        return (Double(x) / n, Double(y) / n, Double(x + 1) / n, Double(y + 1) / n)
    }

    /// The tile at `level` holding face coordinates (u, v) on `face`; u or v
    /// of 1 (the face's far edge) goes to the last column or row.
    public static func containing(face: CubeSphere.Face, u: Double, v: Double, level: Int) -> TileKey {
        let n = 1 << level, s = Double(n)
        let x = min(n - 1, max(0, Int((u * s).rounded(.down))))
        let y = min(n - 1, max(0, Int((v * s).rounded(.down))))
        return TileKey(face: face, level: level, x: x, y: y)
    }

    /// The tile at `level` holding `direction` (any non-zero vector).
    public static func containing(_ direction: Vec3, level: Int) -> TileKey {
        let p = CubeSphere.faceCoordinates(direction)
        return containing(face: p.face, u: p.u, v: p.v, level: level)
    }

    /// Tile-local coordinates (0 to 1 across the tile) of face coordinates (u, v).
    public func localCoordinates(u: Double, v: Double) -> (u: Double, v: Double) {
        let n = Double(tilesAcross)
        return (u * n - Double(x), v * n - Double(y))
    }

    /// Face coordinates of tile-local coordinates (lu, lv).
    public func faceCoordinates(localU lu: Double, localV lv: Double) -> (u: Double, v: Double) {
        let n = Double(tilesAcross)
        return ((Double(x) + lu) / n, (Double(y) + lv) / n)
    }

    /// The unit direction at tile-local coordinates (lu, lv), which may run
    /// past [0, 1] (a border) along this face's projection.
    public func direction(localU lu: Double, localV lv: Double) -> Vec3 {
        let p = faceCoordinates(localU: lu, localV: lv)
        return CubeSphere.direction(face: face, u: p.u, v: p.v)
    }

    /// The tile's centre direction, at local (½, ½).
    public var centre: Vec3 { direction(localU: 0.5, localV: 0.5) }

    /// The four corner directions, counter-clockwise seen from outside: (u0,
    /// v0), (u1, v0), (u1, v1), (u0, v1). The edges between them are
    /// great-circle arcs.
    public var corners: [Vec3] {
        [direction(localU: 0, localV: 0), direction(localU: 1, localV: 0),
         direction(localU: 1, localV: 1), direction(localU: 0, localV: 1)]
    }

    /// The solid angle the tile covers, sr: its spherical quadrilateral's
    /// excess, from two triangles (Van Oosterom & Strackee 1983).
    public var solidAngle: Double {
        let c = corners
        return TileKey.triangleSolidAngle(c[0], c[1], c[2]) + TileKey.triangleSolidAngle(c[0], c[2], c[3])
    }

    static func triangleSolidAngle(_ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double {
        let triple = a.dot(b.cross(c))
        let denominator = 1 + a.dot(b) + b.dot(c) + c.dot(a)
        return 2 * atan2(abs(triple), denominator)
    }

    // MARK: Neighbours

    /// A tile edge, by the face coordinate that is extreme along it.
    public enum Edge: Int, CaseIterable, Codable {
        /// u = u0.
        case minU
        /// u = u1.
        case maxU
        /// v = v0.
        case minV
        /// v = v1.
        case maxV

        var acrossU: Bool { self == .minU || self == .maxU }
    }

    /// The tile at the same level across `edge`, on this face or, at a face
    /// edge, on the neighbouring face. Every tile has four, also at the
    /// cube's corners, where three tiles meet.
    public func neighbor(_ edge: Edge) -> TileKey { neighborAndEdge(edge).key }

    /// The neighbour across `edge` and its edge that touches this tile.
    public func neighborAndEdge(_ edge: Edge) -> (key: TileKey, edge: Edge) {
        let n = tilesAcross
        switch edge {
        case .minU where x > 0: return (TileKey(face: face, level: level, x: x - 1, y: y), .maxU)
        case .maxU where x < n - 1: return (TileKey(face: face, level: level, x: x + 1, y: y), .minU)
        case .minV where y > 0: return (TileKey(face: face, level: level, x: x, y: y - 1), .maxV)
        case .maxV where y < n - 1: return (TileKey(face: face, level: level, x: x, y: y + 1), .minV)
        default: break
        }
        // Across a face edge: fold the neighbour's centre, half a tile past
        // the edge, over onto the next face. In units of half a tile from
        // the face centre (the cube's half-side is n), the fold point is
        // (n - 1)·normal + n·outward + c·along, an integer vector whose
        // coordinates on the next face are its centre's.
        let axes = face.axes
        let outward = TileKey.outward(edge, axes)
        let along = edge.acrossU ? axes.v : axes.u
        let c = edge.acrossU ? 2 * y + 1 - n : 2 * x + 1 - n
        let px = (n - 1) * axes.normal.x + n * outward.x + c * along.x
        let py = (n - 1) * axes.normal.y + n * outward.y + c * along.y
        let pz = (n - 1) * axes.normal.z + n * outward.z + c * along.z
        let next = CubeSphere.Face(normal: outward), nextAxes = next.axes
        let a = px * nextAxes.u.x + py * nextAxes.u.y + pz * nextAxes.u.z
        let b = px * nextAxes.v.x + py * nextAxes.v.y + pz * nextAxes.v.z
        let key = TileKey(face: next, level: level, x: (a + n - 1) / 2, y: (b + n - 1) / 2)
        // The next face's edge toward this face points along this face's normal.
        let back = Edge.allCases.first { TileKey.outward($0, nextAxes) == axes.normal }!
        return (key, back)
    }

    static func outward(_ edge: Edge, _ axes: (normal: CubeSphere.Axis, u: CubeSphere.Axis, v: CubeSphere.Axis))
        -> CubeSphere.Axis {
        switch edge {
        case .minU: return -axes.u
        case .maxU: return axes.u
        case .minV: return -axes.v
        case .maxV: return axes.v
        }
    }
}

// MARK: - Figure directions

extension Ellipsoid {
    /// The surface point (body-fixed, m) whose figure direction is `d`: the
    /// figure coordinates a·d, z shrunk back by b/a, i.e. (a dx, a dy, b dz)
    /// for a unit d. `d` need not be unit.
    public func surfacePoint(figureDirection d: Vec3) -> Vec3 {
        let u = d.normalized
        return Vec3(equatorialRadius * u.x, equatorialRadius * u.y, polarRadius * u.z)
    }

    /// The direction of a body-fixed point in figure coordinates (z
    /// stretched by a/b): for a point on the surface, the direction that
    /// `surfacePoint(figureDirection:)` maps back to it.
    public func figureDirection(of position: Vec3) -> Vec3 {
        Vec3(position.x, position.y, position.z * equatorialRadius / polarRadius).normalized
    }

    /// The figure direction of the surface point at geodetic `latitude` and
    /// `longitude` (rad): its parametric latitude β, tan β = (1 - f) tan φ.
    public func figureDirection(latitude: Double, longitude: Double) -> Vec3 {
        let beta = atan2((1 - flattening) * sin(latitude), cos(latitude))
        return Vec3(cos(beta) * cos(longitude), cos(beta) * sin(longitude), sin(beta))
    }

    /// Geodetic latitude and longitude (rad) of the surface point whose
    /// figure direction is `d`.
    public func geodeticCoordinates(figureDirection d: Vec3) -> (latitude: Double, longitude: Double) {
        let rho = (d.x * d.x + d.y * d.y).squareRoot()
        let longitude = rho > 0 ? atan2(d.y, d.x) : 0
        return (atan2(d.z, (1 - flattening) * rho), longitude)
    }
}
