import Foundation
import OrbitCore

/// Which tiles of a body's cube sphere to draw this frame, and at what level
/// (M1.6 Earth and Moon design §3): continuous distance-dependent LOD
/// (Strugar 2009, "CDLOD", JGT 14:4) on the six-face quadtree of
/// `CubeSphere`, in double precision. E1's tile cache streams the selection
/// for the Earth's imagery; M2's Moon terrain draws it as geomorphed grids.
///
/// Level ℓ is fine enough at a distance when its samples (texels, or mesh
/// quads for a terrain grid: `Parameters.samplesPerTile` across a tile)
/// subtend at most `pixelError` pixels there: from `detailDistance(ℓ)` out.
/// A tile is split while the nearest point of its bounding volume is closer
/// than that, down to the level limit, and the selection is the leaves: each
/// visible point of the surface lies in exactly one selected tile.
///
/// Culling is conservative: a tile is dropped only when none of its points
/// can be seen.
/// - The horizon: the body's lowest surface (its figure lowered by the
///   layer's least height) occludes. An ellipsoid is a sphere in figure
///   coordinates (z stretched by a/b), where straight lines stay straight,
///   so the test is exact there: a point at angle θ from the camera's
///   direction and radius r is hidden when θ > acos(ρ/r_camera) + acos(ρ/r),
///   ρ the occluder's radius (`horizonAngle`).
/// - The view frustum's four side planes, against a cap around the tile.
///
/// Selected tiles that touch, across an edge or only at a corner, differ by
/// at most one level: a pass splits any tile that touches one two or more
/// levels finer. A tile at level ℓ geomorphs to its parent's grid between
/// `morphStart` and `morphEnd` (where its parent becomes fine enough). Where
/// two levels meet, the finer tile's vertices take its parent's grid (morph
/// 1) and the coarser tile's keep their own (morph 0), so the two meshes
/// share their edge: no cracks (`Tile.seams` says where, `Tile.morph(column:
/// row:gridSize:distance:)` and `morphTargets` give the vertex rule).
///
/// The distances alone do not ensure that. Selection bounds only the
/// nearest point of a tile's volume, so a coarse tile's vertices on an
/// edge it shares with a finer tile can lie a tile diagonal plus its height
/// range beyond its detail distance: past its morph start once that margin
/// passes `morphStartRatio` of the detail distance. The budget bias shrinks
/// detail distances but not tiles, so it gets there (2.5 to 3.5 octaves in
/// the tests' views), as does a grid too coarse for its tiles; and a
/// balancing split's children are fully morphed by distance. The seams pin
/// those vertices. Where the distance bands do hold, the pins agree with
/// them and change nothing.
///
/// Two biases coarsen the selection, both uniformly so that the ranges stay
/// consistent:
/// - the tile budget: when the selection would exceed it, the detail
///   distances shrink by half an octave at a time (`Selection.lodBias`), and
///   past 8 octaves the level limit drops;
/// - motion under time warp: no tile is finer than the ground covers in
///   `minimumFramesPerTile` frames, so a tile stays on screen long enough to
///   stream. Its image then moves less than 1/F of its own size a frame,
///   which is the same rule in pixels as in metres (`Selection.levelLimit`).
public struct PlanetQuadtree {
    public struct Parameters {
        /// The body's figure: tiles are taken in its figure coordinates.
        public var figure: Ellipsoid
        /// The deepest level to select: the data's, or the terrain grid's.
        public var maxLevel: Int
        /// Samples across a tile that the pixel error is measured in: the
        /// layer's texels (256 or 512), or a terrain grid's quads (32).
        public var samplesPerTile: Int
        /// The largest a sample may appear, px.
        public var pixelError: Double
        /// The most tiles to select (at least the six faces').
        public var tileBudget: Int
        /// Where in its distance band [d, 2d] a tile starts morphing to its
        /// parent's grid, as a fraction of the band (Strugar's 2/3).
        public var morphStartRatio: Double
        /// The fewest frames the ground may take to cross a selected tile.
        public var minimumFramesPerTile: Double
        /// The layer's heights over the whole body, m: they bound every tile
        /// and lower the occluding horizon (`moonRelief`; 0...0 for imagery
        /// on the figure).
        public var heightRange: ClosedRange<Double>
        /// Tighter height bounds per tile, inside `heightRange`, e.g. a tile
        /// file's index (`PlanetTileFile.valueRange`); nil falls back to it.
        public var tileHeights: ((TileKey) -> ClosedRange<Double>?)?

        public init(figure: Ellipsoid, maxLevel: Int, samplesPerTile: Int = 256, pixelError: Double = 1,
                    tileBudget: Int = 384, morphStartRatio: Double = 2.0 / 3, minimumFramesPerTile: Double = 4,
                    heightRange: ClosedRange<Double> = 0 ... 0,
                    tileHeights: ((TileKey) -> ClosedRange<Double>?)? = nil) {
            self.figure = figure; self.maxLevel = min(max(maxLevel, 0), TileKey.maxLevel)
            self.samplesPerTile = samplesPerTile; self.pixelError = pixelError; self.tileBudget = tileBudget
            self.morphStartRatio = morphStartRatio; self.minimumFramesPerTile = minimumFramesPerTile
            self.heightRange = heightRange; self.tileHeights = tileHeights
        }
    }

    /// The Moon's relief about its 1737.4 km sphere in LOLA, m (design §3:
    /// +10.8 km and -9.1 km).
    public static let moonRelief = -9_100.0 ... 10_800.0

    /// The four side planes of a perspective camera, body-fixed.
    public struct Frustum: Equatable {
        public let apex: Vec3
        /// Inward unit normals, of the left, right, bottom and top planes.
        public let normals: [Vec3]

        /// A camera at `apex` looking along `forward`, `up` its vertical,
        /// `fovY` its vertical field of view (rad), `aspect` width/height.
        public init(apex: Vec3, forward: Vec3, up: Vec3, fovY: Double, aspect: Double) {
            let f = forward.normalized
            let r = f.cross(up).normalized
            let u = r.cross(f)
            let hy = fovY / 2, hx = atan(aspect * tan(fovY / 2))
            let sx = f * sin(hx), sy = f * sin(hy)
            self.apex = apex
            normals = [r * cos(hx) + sx, sx - r * cos(hx), u * cos(hy) + sy, sy - u * cos(hy)]
        }

        public func contains(_ p: Vec3) -> Bool {
            normals.allSatisfy { $0.dot(p - apex) >= 0 }
        }
    }

    /// The camera, body-fixed.
    public struct View {
        /// Position, m.
        public var position: Vec3
        /// The view's frustum; nil culls by the horizon only (a probe, prefetch).
        public var frustum: Frustum?
        /// The angle a pixel subtends at the image centre, rad: fovY / height.
        public var pixelAngle: Double
        /// The speed over the ground of the point below the camera, m/s
        /// (`PlanetQuadtree.groundSpeed`).
        public var groundSpeed: Double
        /// Simulated seconds per real second.
        public var warp: Double
        /// Real seconds per frame.
        public var frameInterval: Double

        public init(position: Vec3, frustum: Frustum? = nil, pixelAngle: Double, groundSpeed: Double = 0,
                    warp: Double = 1, frameInterval: Double = 1.0 / 60) {
            self.position = position; self.frustum = frustum; self.pixelAngle = pixelAngle
            self.groundSpeed = groundSpeed; self.warp = warp; self.frameInterval = frameInterval
        }
    }

    /// What a tile's edge or corner meets, which pins the morph of its
    /// vertices there (`Tile.morph(column:row:gridSize:distance:)`).
    public enum Seam: UInt16 {
        /// Tiles of its own level, or none (culled): the vertices morph by
        /// their distance, as the neighbours' do.
        case level = 0
        /// A finer tile: the vertices keep the tile's own grid (morph 0),
        /// which the finer tile's edge morphs to.
        case finer = 1
        /// A coarser tile: the vertices take the parent's grid (morph 1),
        /// which is the coarser tile's own.
        case coarser = 2
    }

    /// A selected tile.
    public struct Tile: Equatable {
        public let key: TileKey
        /// The distance from the camera to the nearest point of the tile's
        /// bounding volume, m: a lower bound of the distance to its surface.
        public let distance: Double
        /// The vertex distances (m) over which the tile's grid morphs to its
        /// parent's: none nearer than `morphStart`, all of it from
        /// `morphEnd`. Both infinite at level 0, which has no parent.
        public let morphStart: Double
        public let morphEnd: Double
        /// The seams, two bits each (`Seam.rawValue`): the four edges in
        /// bits 0-7, by `TileKey.Edge.rawValue`, then the four corners in
        /// bits 8-15, in the order of `TileKey.corners`. A corner is
        /// `.coarser` if any tile touching it is, else `.finer` if any is.
        /// MR2 uploads it per instance as it is.
        public let seams: UInt16

        init(key: TileKey, distance: Double, morphStart: Double, morphEnd: Double, seams: UInt16 = 0) {
            self.key = key; self.distance = distance; self.morphStart = morphStart; self.morphEnd = morphEnd
            self.seams = seams
        }

        public func seam(_ edge: TileKey.Edge) -> Seam { Seam(rawValue: seams >> (2 * edge.rawValue) & 3)! }

        public func seam(corner: Int) -> Seam { Seam(rawValue: seams >> (8 + 2 * corner) & 3)! }

        /// The morph factor of a vertex `distance` (m) from the camera: 0
        /// keeps the tile's own grid, 1 is its parent's.
        public func morph(atDistance distance: Double) -> Double {
            guard morphEnd.isFinite else { return 0 }
            return min(1, max(0, (distance - morphStart) / (morphEnd - morphStart)))
        }

        /// The morph factor of vertex (column `i` along u, row `j` along v)
        /// of the tile's `n`-quad grid, `distance` (m) from the camera
        /// (placed with the tile's own heights): pinned by the seam its
        /// corner or edge lies on, else `morph(atDistance:)`.
        public func morph(column i: Int, row j: Int, gridSize n: Int, distance: Double) -> Double {
            let onU = i == 0 || i == n, onV = j == 0 || j == n
            let seam: Seam
            if onU && onV {
                // Corners 0 to 3: (0, 0), (n, 0), (n, n), (0, n).
                let corner: Int = j == 0 ? (i == 0 ? 0 : 1) : (i == 0 ? 3 : 2)
                seam = self.seam(corner: corner)
            } else if onU {
                seam = self.seam(i == 0 ? .minU : .maxU)
            } else if onV {
                seam = self.seam(j == 0 ? .minV : .maxV)
            } else {
                seam = .level
            }
            switch seam {
            case .level: return morph(atDistance: distance)
            case .finer: return 0
            case .coarser: return 1
            }
        }
    }

    public struct Selection: Equatable {
        /// The selected tiles, by ascending key id.
        public let tiles: [Tile]
        /// Octaves by which the tile budget shrank the detail distances (0: none).
        public let lodBias: Double
        /// The deepest level allowed: `maxLevel`, or less under warp or a
        /// tight budget.
        public let levelLimit: Int
        /// Nodes tested, the selection's cost.
        public let nodesVisited: Int
        /// Tiles split to keep tiles that touch within a level of each other.
        let balanceSplits: Int
    }

    public var parameters: Parameters

    public init(_ parameters: Parameters) { self.parameters = parameters }

    /// The distance (m) from which level `level` is fine enough for a view
    /// whose pixels subtend `pixelAngle`: a sample of the tile's nominal size
    /// a · (π/2)/2^level / samplesPerTile then spans `pixelError` pixels. It
    /// halves with each level.
    public func detailDistance(level: Int, pixelAngle: Double) -> Double {
        let p = parameters
        let sample = p.figure.equatorialRadius * CubeSphere.tileAngle(level: level) / Double(p.samplesPerTile)
        return sample / (p.pixelError * pixelAngle)
    }

    /// The deepest level whose tiles take at least `minimumFramesPerTile`
    /// frames for the ground to cross: a tile spans a · (π/2)/2^level. No
    /// limit when the ground stands still or `minimumFramesPerTile` is 0 or
    /// less (the bias off).
    public func motionLevelLimit(_ view: View) -> Int {
        let p = parameters
        let perFrame = view.groundSpeed * view.warp * view.frameInterval
        guard perFrame > 0, p.minimumFramesPerTile > 0 else { return p.maxLevel }
        let face = p.figure.equatorialRadius * Double.pi / 2
        let ratio = face / (p.minimumFramesPerTile * perFrame)
        // A product that underflows to a subnormal leaves the ratio infinite.
        guard ratio.isFinite else { return p.maxLevel }
        guard ratio >= 1 else { return 0 }
        return min(p.maxLevel, Int(log2(ratio).rounded(.down)))
    }

    /// The speed over the ground (m/s) of the point below a camera at
    /// body-fixed `position` moving at body-fixed `velocity`: its horizontal
    /// velocity scaled down to the surface, `radius` (m) from the centre.
    public static func groundSpeed(position: Vec3, velocity: Vec3, radius: Double) -> Double {
        let r = position.length
        guard r > 0 else { return 0 }
        let up = position / r
        let horizontal = velocity - up * velocity.dot(up)
        return horizontal.length * min(1, radius / r)
    }

    /// The view of a camera given as the renderer has it: `cameraPosition`
    /// and `velocity` relative to the body's centre in ICRF, `worldToView`
    /// rows right, up and back (`OrbitCamera`), the body oriented as
    /// `orientation`.
    public func view(cameraPosition: Vec3, worldToView: Mat3, fovY: Double, viewportWidth: Double,
                     viewportHeight: Double, orientation: BodyOrientation, velocity: Vec3 = .zero,
                     warp: Double = 1, frameInterval: Double = 1.0 / 60) -> View {
        let position = orientation.toBody(cameraPosition)
        let forward = orientation.toBody(-worldToView.r2), up = orientation.toBody(worldToView.r1)
        let frustum = Frustum(apex: position, forward: forward, up: up, fovY: fovY,
                              aspect: viewportWidth / viewportHeight)
        let relative = velocity - orientation.angularVelocity.cross(cameraPosition)
        let speed = PlanetQuadtree.groundSpeed(position: position, velocity: orientation.toBody(relative),
                                               radius: parameters.figure.equatorialRadius)
        return View(position: position, frustum: frustum, pixelAngle: fovY / viewportHeight, groundSpeed: speed,
                    warp: warp, frameInterval: frameInterval)
    }

    // MARK: Selection

    /// The tiles to draw for `view`. The same view and parameters (and
    /// `previous`) give the same selection.
    ///
    /// Under budget pressure the bias is searched upwards in half octaves
    /// from 0, or, given the last frame's selection, from half an octave
    /// below its bias: a frame then usually costs one pass that stops early
    /// and one that fits, and detail comes back by half an octave a frame as
    /// the pressure eases.
    public func select(_ view: View, previous: Selection? = nil) -> Selection {
        let context = Context(view, parameters)
        let budget = max(parameters.tileBudget, 6)
        let detail = detailDistance(level: 0, pixelAngle: view.pixelAngle)
        let motion = motionLevelLimit(view)
        var bias = 0.0, limit = motion, visited = 0
        if let p = previous {
            if p.lodBias >= 8 && p.levelLimit < motion {
                bias = 8; limit = p.levelLimit + 1
            } else {
                bias = max(0, min(8, p.lodBias) - 0.5)
            }
        }
        while true {
            // A pass stops as soon as it passes the budget; at level 0 it cannot.
            var pass = Pass(context: context, levelLimit: limit, detail: detail * pow(2, -bias))
            let complete = pass.run(budget: budget)
            visited += pass.visited
            if complete {
                return Selection(tiles: pass.tiles(morphStartRatio: parameters.morphStartRatio), lodBias: bias,
                                 levelLimit: limit, nodesVisited: visited, balanceSplits: pass.balanceSplits)
            }
            if bias < 8 { bias += 0.5 } else { limit -= 1 }
        }
    }

    /// The two vertices whose midpoint vertex (column `i`, row `j`) of a
    /// tile's grid morphs to, nil if it is also a vertex of the parent's
    /// grid (both even). The grid's cells, at every level, are split along
    /// their (0, 0)-(1, 1) diagonal. A morphed vertex is lerp(own position,
    /// target, morph), where the target is the midpoint of these two (or the
    /// vertex itself) placed with the parent level's heights, and the
    /// vertex's own height blends to its parent's with the same factor: at
    /// morph 1 the tile is its parent's mesh exactly. The rule is symmetric,
    /// so it holds across face edges, where neighbouring grids run in
    /// opposite directions.
    public static func morphTargets(column i: Int, row j: Int) -> (Int, Int, Int, Int)? {
        switch (i % 2 != 0, j % 2 != 0) {
        case (false, false): return nil
        case (true, false): return (i - 1, j, i + 1, j)
        case (false, true): return (i, j - 1, i, j + 1)
        case (true, true): return (i - 1, j - 1, i + 1, j + 1)
        }
    }

    /// The angle from the camera's direction (in figure coordinates) beyond
    /// which no point at `height` (m) can be seen over the occluding horizon,
    /// for a camera at body-fixed `position`; nil if the camera is not above
    /// the occluder. Exact on a sphere, and on an ellipsoid in figure
    /// coordinates.
    public func horizonAngle(position: Vec3, height: Double) -> Double? {
        let c = Context(View(position: position, pixelAngle: 1), parameters)
        guard c.cameraRadius > c.occluder else { return nil }
        let shell = c.radial(height ... height)
        return acos(c.occluder / c.cameraRadius) + acos(min(1, c.occluder / shell.upperBound))
    }
}

// MARK: - Geometry

extension PlanetQuadtree {
    /// What a selection pass needs of the view, in figure coordinates scaled
    /// to the unit sphere: x' = (x/a, y/a, z/b). There the figure is the
    /// unit sphere and real distances are between b and a times scaled ones.
    struct Context {
        let parameters: Parameters
        let a: Double, b: Double
        /// The camera: its distance from the centre and its direction.
        let cameraRadius: Double, cameraDirection: Vec3
        /// The occluding sphere's radius; the cosine and sine of the camera's
        /// horizon angle over it (nil when the camera is not above it).
        let occluder: Double
        let horizon: (cos: Double, sin: Double)?
        /// The frustum's planes: |m| (m̂·x') + d ≥ 0 inside.
        let planes: [(unit: Vec3, length: Double, d: Double)]

        init(_ view: View, _ parameters: Parameters) {
            self.parameters = parameters
            let a = parameters.figure.equatorialRadius, b = parameters.figure.polarRadius
            self.a = a; self.b = b
            let p = view.position
            let camera = Vec3(p.x / a, p.y / a, p.z / b)
            cameraRadius = camera.length
            cameraDirection = camera.normalized
            let occluder = 1 + min(parameters.heightRange.lowerBound, 0) / b
            self.occluder = occluder
            if cameraRadius > occluder {
                let c = occluder / cameraRadius
                horizon = (c, (1 - c * c).squareRoot())
            } else {
                horizon = nil
            }
            planes = view.frustum.map { f in
                f.normals.map { n -> (unit: Vec3, length: Double, d: Double) in
                    let m = Vec3(n.x * a, n.y * a, n.z * b)
                    return (m.normalized, m.length, -n.dot(f.apex))
                }
            } ?? []
        }

        /// The radii (scaled) between which a surface at heights `h` lies:
        /// a point at height h along the normal has |x'| between 1 + h/a and
        /// 1 + h/b for h ≥ 0, and above 1 + h/b for h < 0.
        func radial(_ h: ClosedRange<Double>) -> ClosedRange<Double> {
            let lo = h.lowerBound >= 0 ? 1 + h.lowerBound / a : 1 + h.lowerBound / b
            let hi = h.upperBound >= 0 ? 1 + h.upperBound / b : 1
            return lo ... max(lo, hi)
        }

        /// nil if `key` (its quadrilateral `q`) is certainly invisible, else
        /// the lower bound of its distance from the camera, m.
        func test(_ key: TileKey, _ q: Quad) -> Double? {
            let shell = radial(parameters.tileHeights?(key) ?? parameters.heightRange)
            let chord2 = q.chordSquared(from: cameraDirection)
            let cosTheta = 1 - chord2 / 2
            if let h = horizon {
                // Hidden past the sum of the camera's and the tile's horizon angles.
                let c = occluder / shell.upperBound, s = (1 - c * c).squareRoot()
                let cosLimit = h.cos * c - h.sin * s
                if cosTheta < cosLimit { return nil }
            }
            for plane in planes {
                // The most of m̂·x' over the cap: at its point nearest m̂.
                let cm = plane.unit.dot(q.centre)
                var reach = 1.0
                if cm < q.cosCap {
                    let sm = max(0, 1 - cm * cm).squareRoot()
                    reach = cm * q.cosCap + sm * q.sinCap
                }
                reach *= plane.length
                let r = reach >= 0 ? shell.upperBound : shell.lowerBound
                if r * reach + plane.d < 0 { return nil }
            }
            // The nearest point of the shell over the tile is at its nearest
            // direction; |c - r u|² = (|c| - r)² + |c| r chord².
            let r = min(max(cameraRadius * cosTheta, shell.lowerBound), shell.upperBound)
            let dr = cameraRadius - r
            let d2 = dr * dr + cameraRadius * r * chord2
            // Real distances are at least b times scaled ones.
            return b * d2.squareRoot()
        }
    }

    /// A tile's spherical quadrilateral: its corners counter-clockwise from
    /// (u0, v0), the great circles through its edges, and a cap around it.
    struct Quad {
        let c0: Vec3, c1: Vec3, c2: Vec3, c3: Vec3
        let n0: Vec3, n1: Vec3, n2: Vec3, n3: Vec3
        /// The cap: the corners' mean direction, and the cosine and sine of
        /// its radius, a hair wider than the corners against rounding.
        let centre: Vec3
        let cosCap: Double, sinCap: Double

        init(_ c0: Vec3, _ c1: Vec3, _ c2: Vec3, _ c3: Vec3) {
            self.c0 = c0; self.c1 = c1; self.c2 = c2; self.c3 = c3
            n0 = c0.cross(c1); n1 = c1.cross(c2); n2 = c2.cross(c3); n3 = c3.cross(c0)
            let sum: Vec3 = (c0 + c1) + (c2 + c3)
            centre = sum.normalized
            let nearest = min(min(centre.dot(c0), centre.dot(c1)), min(centre.dot(c2), centre.dot(c3)))
            let c = max(-1, min(1, nearest)) - 1e-12
            cosCap = c
            sinCap = max(0, 1 - c * c).squareRoot()
        }

        init(_ key: TileKey) {
            self.init(key.direction(localU: 0, localV: 0), key.direction(localU: 1, localV: 0),
                      key.direction(localU: 1, localV: 1), key.direction(localU: 0, localV: 1))
        }

        /// Pushes the four quarters of `key` (this quadrilateral), sharing
        /// the corners they have in common, so that they pop in the order of
        /// `TileKey.children`.
        func pushQuarters(of key: TileKey, onto stack: inout [(key: TileKey, quad: Quad)]) {
            let m01 = key.direction(localU: 0.5, localV: 0), m12 = key.direction(localU: 1, localV: 0.5)
            let m23 = key.direction(localU: 0.5, localV: 1), m30 = key.direction(localU: 0, localV: 0.5)
            let cc = key.direction(localU: 0.5, localV: 0.5)
            let l = key.level + 1, x = 2 * key.x, y = 2 * key.y
            stack.append((TileKey(face: key.face, level: l, x: x + 1, y: y + 1), Quad(cc, m12, c2, m23)))
            stack.append((TileKey(face: key.face, level: l, x: x, y: y + 1), Quad(m30, cc, m23, c3)))
            stack.append((TileKey(face: key.face, level: l, x: x + 1, y: y), Quad(m01, c1, m12, cc)))
            stack.append((TileKey(face: key.face, level: l, x: x, y: y), Quad(c0, m01, cc, m30)))
        }

        /// The squared chord from unit `d` to the quadrilateral's nearest
        /// point: 0 inside it, (2 sin(θ/2))² at angle θ. Chords keep their
        /// precision for small angles, as cosines would not.
        func chordSquared(from d: Vec3) -> Double {
            if d.dot(n0) >= 0 && d.dot(n1) >= 0 && d.dot(n2) >= 0 && d.dot(n3) >= 0 { return 0 }
            let e0 = Quad.arcChordSquared(d, c0, c1, n0), e1 = Quad.arcChordSquared(d, c1, c2, n1)
            let e2 = Quad.arcChordSquared(d, c2, c3, n2), e3 = Quad.arcChordSquared(d, c3, c0, n3)
            return min(min(e0, e1), min(e2, e3))
        }

        /// The squared chord from `d` to the great-circle arc from `p` to
        /// `q`, `n` = p × q.
        static func arcChordSquared(_ d: Vec3, _ p: Vec3, _ q: Vec3, _ n: Vec3) -> Double {
            let nn = n.length
            if nn > 0 {
                let unit = n / nn
                let off = d.dot(unit)
                let t = d - unit * off
                if p.cross(t).dot(n) >= 0 && t.cross(q).dot(n) >= 0 {
                    // The foot on the circle, at |t| = cos of the angle off it.
                    let o2 = off * off
                    let gap = o2 / (1 + max(0, 1 - o2).squareRoot())
                    return o2 + gap * gap
                }
            }
            return min((d - p).lengthSquared, (d - q).lengthSquared)
        }
    }

    /// One selection at a given detail distance and level limit.
    struct Pass {
        let context: Context
        let levelLimit: Int
        /// Level 0's detail distance, biased; level ℓ's is this / 2^ℓ.
        let detail0: Double
        /// The tree as selected, by key id: a leaf's distance (m), or
        /// `Pass.split`. Culled tiles are absent.
        var nodes = NodeTable()
        static let split = -1.0
        var visited = 0
        var leafCount = 0
        var balanceSplits = 0

        init(context: Context, levelLimit: Int, detail: Double) {
            self.context = context; self.levelLimit = levelLimit; detail0 = detail
        }

        func detail(_ level: Int) -> Double { detail0 / Double(1 << level) }

        /// Selects and balances; false if it stopped on passing `budget` leaves.
        mutating func run(budget: Int) -> Bool {
            // Splits and leaves come to about 4/3 of the leaves; the table
            // grows past that if it must.
            nodes = NodeTable(capacity: 2 * min(budget, 1_024))
            var stack: [(key: TileKey, quad: Quad)] = TileKey.roots.reversed().map { ($0, Quad($0)) }
            while let (key, quad) = stack.popLast() {
                visited += 1
                guard let distance = context.test(key, quad) else { continue }
                if key.level < levelLimit && distance < detail(key.level) {
                    nodes[key.id] = Pass.split
                    quad.pushQuarters(of: key, onto: &stack)
                } else {
                    nodes[key.id] = distance
                    leafCount += 1
                    if leafCount > budget { return false }
                }
            }
            return balance(budget: budget)
        }

        /// Splits every leaf that touches one two or more levels finer,
        /// across an edge or only at a corner, until none does (a restricted
        /// quadtree, also diagonally: where tiles of three levels met at a
        /// corner, no heights could agree there). A leaf split here is
        /// beyond its own detail distance, so its children are fully morphed
        /// by distance; the seams pin their edges toward the finer tile to
        /// their own grid (`tiles`).
        mutating func balance(budget: Int) -> Bool {
            var queue = nodes.sorted().compactMap { $0.value >= 0 ? TileKey(id: $0.id) : nil }
            var head = 0
            while head < queue.count {
                let key = queue[head]
                head += 1
                guard key.level >= 2, let state = nodes[key.id], state >= 0 else { continue }
                // The same-level tiles that touch it: across its edges, and
                // diagonally at its corners.
                var split = false
                for k in 0 ..< 8 {
                    let neighbour: TileKey
                    if k < 4 {
                        neighbour = key.neighbor(TileKey.Edge(rawValue: k)!)
                    } else if let d = key.diagonalNeighbor(corner: k - 4) {
                        neighbour = d.key
                    } else {
                        continue
                    }
                    guard let coarse = coarseLeaf(covering: neighbour), coarse.level <= key.level - 2 else { continue }
                    splitForBalance(coarse, queue: &queue)
                    split = true
                    if leafCount > budget { return false }
                }
                // A split three or more levels up leaves its children still
                // too coarse: look again.
                if split { queue.append(key) }
            }
            return true
        }

        /// Splits leaf `coarse` for `balance`, queueing its children.
        mutating func splitForBalance(_ coarse: TileKey, queue: inout [TileKey]) {
            nodes[coarse.id] = Pass.split
            leafCount -= 1
            balanceSplits += 1
            var children: [(key: TileKey, quad: Quad)] = []
            Quad(coarse).pushQuarters(of: coarse, onto: &children)
            for (child, quad) in children {
                visited += 1
                guard let distance = context.test(child, quad) else { continue }
                nodes[child.id] = distance
                leafCount += 1
                queue.append(child)
            }
        }

        /// The leaf two or more levels coarser than `key` whose area holds
        /// it, nil if `key`'s area is selected at its level or finer, or culled.
        func coarseLeaf(covering key: TileKey) -> TileKey? {
            if nodes[key.id] != nil { return nil }
            var level = key.level - 1
            while level >= 0 {
                let a = key.ancestor(atLevel: level)
                guard let state = nodes[a.id] else { level -= 1; continue }
                return state >= 0 && level <= key.level - 2 ? a : nil
            }
            return nil
        }

        func tiles(morphStartRatio: Double) -> [Tile] {
            var out: [Tile] = []
            out.reserveCapacity(leafCount)
            for (id, distance) in nodes.sorted() where distance >= 0 {
                let key = TileKey(id: id)!, level = key.level
                // A tile's band runs from its own detail distance to its parent's.
                let end = level == 0 ? Double.infinity : detail(level - 1)
                let start = level == 0 ? Double.infinity : detail(level) * (1 + morphStartRatio)
                out.append(Tile(key: key, distance: distance, morphStart: start, morphEnd: end, seams: seams(of: key)))
            }
            return out
        }

        /// A selected tile's seams (`Tile.seams`): what it meets across each
        /// edge and round each corner.
        func seams(of key: TileKey) -> UInt16 {
            var bits: UInt16 = 0, splitEdges = 0
            for e in 0 ..< 4 {
                let (neighbour, back) = key.neighborAndEdge(TileKey.Edge(rawValue: e)!)
                // The neighbour's two quarters along its edge toward this tile.
                let x = 2 * neighbour.x, y = 2 * neighbour.y
                let (a, b): ((Int, Int), (Int, Int))
                switch back {
                case .minU: (a, b) = ((x, y), (x, y + 1))
                case .maxU: (a, b) = ((x + 1, y), (x + 1, y + 1))
                case .minV: (a, b) = ((x, y), (x + 1, y))
                case .maxV: (a, b) = ((x, y + 1), (x + 1, y + 1))
                }
                let state = nodes[neighbour.id]
                if state == Pass.split { splitEdges |= 1 << e }
                bits |= seam(neighbour, state, quarters: a, b).rawValue << (2 * e)
            }
            // A corner's seam is the greatest (coarser over finer over level)
            // of the tiles round it.
            for corner in 0 ..< 4 {
                // The corner's edges: minU or maxU, then minV or maxV.
                let e1 = corner == 1 || corner == 2 ? 1 : 0, e2 = corner >= 2 ? 3 : 2
                var s = Seam.level.rawValue
                if splitEdges & (1 << e1 | 1 << e2) == 0 {
                    // Unsplit, the edge neighbours hold there what they hold
                    // along the edges; then only the diagonal one is left.
                    let s1: UInt16 = bits >> (2 * e1) & 3, s2: UInt16 = bits >> (2 * e2) & 3
                    s = max(s1, s2)
                    if s != Seam.coarser.rawValue, let (d, c) = key.diagonalNeighbor(corner: corner) {
                        let q = Pass.quarter(of: d, atCorner: c)
                        s = max(s, seam(d, nodes[d.id], quarters: q, q).rawValue)
                    }
                } else {
                    key.forEachTile(aroundCorner: corner) { t, c in
                        guard t != key else { return }
                        let q = Pass.quarter(of: t, atCorner: c)
                        s = max(s, seam(t, nodes[t.id], quarters: q, q).rawValue)
                    }
                }
                bits |= s << (8 + 2 * corner)
            }
            return bits
        }

        /// The (column, row) of `t`'s quarter at its corner `corner`.
        static func quarter(of t: TileKey, atCorner corner: Int) -> (Int, Int) {
            let i = corner == 1 || corner == 2 ? 1 : 0, j = corner >= 2 ? 1 : 0
            return (2 * t.x + i, 2 * t.y + j)
        }

        /// What the area of `t`, a tile at the level of the one asking,
        /// holds where it touches, `state` being its node: a leaf of that
        /// level (`.level`), part of a coarser leaf (`.coarser`), or, split,
        /// finer tiles in one of its quarters `a` and `b` (column, row) that
        /// touch (`.finer`). Nothing selected there (culled) is `.level`.
        func seam(_ t: TileKey, _ state: Double?, quarters a: (Int, Int), _ b: (Int, Int)) -> Seam {
            if let state {
                if state >= 0 { return .level }
                let l = t.level + 1
                let qa = TileKey(face: t.face, level: l, x: a.0, y: a.1)
                let qb = TileKey(face: t.face, level: l, x: b.0, y: b.1)
                return nodes[qa.id] != nil || nodes[qb.id] != nil ? .finer : .level
            }
            var level = t.level - 1
            while level >= 0 {
                if let state = nodes[t.ancestor(atLevel: level).id] { return state >= 0 ? .coarser : .level }
                level -= 1
            }
            return .level
        }
    }

    /// A pass's nodes by tile id: open addressing with linear probing on a
    /// multiplicative hash. Balancing and seams look up several neighbours
    /// per tile, and this is a few times faster at it than a Dictionary's
    /// seeded hashing. Nodes are only ever added or changed.
    struct NodeTable {
        /// No tile id has bit 63 set.
        static let empty = UInt64.max
        private var keys: [UInt64]
        private var values: [Double]
        private var shift: UInt64
        private(set) var count = 0

        /// Room for `capacity` nodes at most half full; it grows past that.
        init(capacity: Int = 0) {
            var size = 16, bits: UInt64 = 4
            while size < 2 * capacity { size *= 2; bits += 1 }
            keys = Array(repeating: NodeTable.empty, count: size)
            values = Array(repeating: 0, count: size)
            shift = 64 - bits
        }

        /// The slot that holds `id`, or the empty one where it would go.
        private func slot(_ id: UInt64) -> Int {
            let mask = keys.count - 1
            var i = Int(truncatingIfNeeded: (id &* 0x9E37_79B9_7F4A_7C15) >> shift)
            while keys[i] != id && keys[i] != NodeTable.empty { i = (i + 1) & mask }
            return i
        }

        subscript(id: UInt64) -> Double? {
            get {
                let i = slot(id)
                return keys[i] == id ? values[i] : nil
            }
            set {
                guard let value = newValue else { preconditionFailure("nodes are never removed") }
                var i = slot(id)
                if keys[i] != id {
                    if 2 * (count + 1) > keys.count {
                        var bigger = NodeTable(capacity: keys.count)
                        for (k, v) in zip(keys, values) where k != NodeTable.empty { bigger[k] = v }
                        self = bigger
                        i = slot(id)
                    }
                    keys[i] = id
                    count += 1
                }
                values[i] = value
            }
        }

        /// The nodes, by ascending id.
        func sorted() -> [(id: UInt64, value: Double)] {
            var out: [(id: UInt64, value: Double)] = []
            out.reserveCapacity(count)
            for (k, v) in zip(keys, values) where k != NodeTable.empty { out.append((k, v)) }
            out.sort { $0.id < $1.id }
            return out
        }
    }
}
