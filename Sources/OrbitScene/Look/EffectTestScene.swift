import Foundation
import OrbitCore

/// The camera target's local frame, where R6's test emitters are placed:
/// the target at the origin (camera-relative), up away from the nearest
/// body's centre, east and north across it.
public struct EffectTargetFrame: Equatable {
    /// The target, camera-relative, m.
    public var origin: Vec3
    /// Unit vectors (world).
    public var east: Vec3, north: Vec3, up: Vec3

    public init(origin: Vec3, east: Vec3, north: Vec3, up: Vec3) {
        self.origin = origin
        self.east = east
        self.north = north
        self.up = up
    }

    /// The frame at `scene`'s camera target: a vessel's centre of mass or a
    /// body's centre.
    public init(scene: RenderScene) {
        var origin = Vec3.zero
        switch scene.camera.target {
        case .vessel(let id): origin = scene.vessel(id)?.position ?? .zero
        case .body(let id): origin = scene.bodies.first { $0.id == id }?.position ?? .zero
        }
        // Up from the nearest other body (or from the target body to the camera).
        let others = scene.bodies.filter { !$0.isSun && ($0.position - origin).length > 1 }
        var up = Vec3.unitZ
        if case .body(let id) = scene.camera.target, scene.bodies.contains(where: { $0.id == id }) {
            up = (-origin).length > 0 ? (-origin).normalized : .unitZ
        } else if let body = others.min(by: { ($0.position - origin).length < ($1.position - origin).length }) {
            up = (origin - body.position).normalized
        }
        // East: the ICRF pole across up (x when up is along the pole).
        var east = Vec3.unitZ.cross(up)
        if east.length < 1e-6 { east = Vec3.unitX.cross(up) }
        east = east.normalized
        self.init(origin: origin, east: east, north: up.cross(east), up: up)
    }

    /// The camera-relative point `enu` metres east, north and up of the target.
    public func point(_ enu: [Double]) -> Vec3 {
        origin + east * component(enu, 0) + north * component(enu, 1) + up * component(enu, 2)
    }

    /// The unit direction `enu` (east, north, up); down if it is zero.
    public func direction(_ enu: [Double]) -> Vec3 {
        let d = east * component(enu, 0) + north * component(enu, 1) + up * component(enu, 2)
        return d.length > 0 ? d.normalized : -up
    }

    /// From the camera to the target, m: the OIT weight's reference.
    public var distance: Double { origin.length }

    private func component(_ v: [Double], _ i: Int) -> Double { i < v.count ? v[i] : 0 }
}

/// The test emitters' shapes for one frame, camera-relative and in double
/// precision; the renderer turns them into float uniforms and instances.
public enum EffectTestScene {
    /// A lit box of homogeneous medium: the slab.
    public struct Slab: Equatable {
        public var center: Vec3
        /// Unit axes and half-extents, m (`up` is the thin one).
        public var axes: (east: Vec3, north: Vec3, up: Vec3)
        public var halfExtents: Vec3
        /// Per metre.
        public var extinction: Double
        public var albedo: Double

        public static func == (a: Slab, b: Slab) -> Bool {
            a.center == b.center && a.axes.east == b.axes.east && a.axes.north == b.axes.north
                && a.axes.up == b.axes.up && a.halfExtents == b.halfExtents && a.extinction == b.extinction
                && a.albedo == b.albedo
        }
    }

    /// An emissive cone: apex, unit axis, length and base radius, m.
    public struct Cone: Equatable {
        public var apex: Vec3
        public var axis: Vec3
        public var length: Double
        public var radius: Double
    }

    /// A vertical column, opaque: base centre, unit axis (up), height and radius, m.
    public struct Column: Equatable {
        public var base: Vec3
        public var axis: Vec3
        public var height: Double
        public var radius: Double
    }

    /// A soft billboard: centre, radius (m), linear colour and peak opacity.
    public struct Sprite: Equatable {
        public var center: Vec3
        public var radius: Double
        public var color: Vec3
        public var alpha: Double
    }

    /// A spark's streak, start to end (m), its width (m) and colour.
    public struct Spark: Equatable {
        public var start: Vec3
        public var end: Vec3
        public var width: Double
        public var color: Vec3
    }

    /// The slab's optical depth straight through its thickness, whatever
    /// its size, and its single-scattering albedo (a cloud's).
    public static let slabOpticalDepth = 1.0
    public static let slabAlbedo = 0.9

    public static func slab(_ e: EffectTestEmitter, in frame: EffectTargetFrame) -> Slab {
        let thickness = 0.2 * max(e.size, 1e-3)
        return Slab(center: frame.point(e.position), axes: (frame.east, frame.north, frame.up),
                    halfExtents: Vec3(e.size, e.size, thickness / 2), extinction: slabOpticalDepth / thickness,
                    albedo: slabAlbedo)
    }

    public static func cone(_ e: EffectTestEmitter, in frame: EffectTargetFrame) -> Cone {
        Cone(apex: frame.point(e.position), axis: frame.direction(e.axis), length: e.size, radius: 0.25 * e.size)
    }

    public static func column(_ e: EffectTestEmitter, in frame: EffectTargetFrame) -> Column {
        Column(base: frame.point(e.position), axis: frame.up, height: e.size, radius: 0.04 * e.size)
    }

    /// Two smoke tints, warm and cool, alternating, so that the order OIT
    /// gives them shows.
    static let spriteTints = [Vec3(0.95, 0.62, 0.42), Vec3(0.45, 0.62, 0.95)]

    /// `count` sprites in a ball of radius `size` about the position, at
    /// fixed pseudo-random places (the same on every platform).
    public static func sprites(_ e: EffectTestEmitter, in frame: EffectTargetFrame) -> [Sprite] {
        let center = frame.point(e.position)
        return (0..<max(e.count, 0)).map { i in
            let p = ballPoint(i, seed: 1)
            let offset = frame.east * p.x + frame.north * p.y + frame.up * p.z
            return Sprite(center: center + offset * e.size, radius: (0.3 + 0.15 * unit(i, 2, seed: 1)) * e.size,
                          color: spriteTints[i % spriteTints.count], alpha: 0.55)
        }
    }

    /// `count` sparks from the position, flying along the axis within 25°,
    /// each 0.2 × size long at most.
    public static func sparks(_ e: EffectTestEmitter, in frame: EffectTargetFrame) -> [Spark] {
        let start = frame.point(e.position), axis = frame.direction(e.axis)
        var side = axis.cross(frame.up)
        if side.length < 1e-6 { side = axis.cross(frame.east) }
        side = side.normalized
        let other = axis.cross(side)
        let spread = tan(25 * Double.pi / 180)
        return (0..<max(e.count, 0)).map { i in
            let a = 2 * Double.pi * unit(i, 0, seed: 2), r = spread * sqrt(unit(i, 1, seed: 2))
            let dir = (axis + side * (r * cos(a)) + other * (r * sin(a))).normalized
            let from = start + dir * (e.size * unit(i, 2, seed: 2))
            let to = from + dir * (0.2 * e.size * (0.5 + 0.5 * unit(i, 3, seed: 2)))
            return Spark(start: from, end: to, width: 0.01 * e.size, color: Vec3(1.0, 0.62, 0.25))
        }
    }

    // MARK: Fixed pseudo-random numbers

    /// A number in [0, 1) for (index, component), from splitmix64: the
    /// same on every platform.
    static func unit(_ i: Int, _ k: Int, seed: UInt64) -> Double {
        var z = seed &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(truncatingIfNeeded: i) &* 0xBF58_476D_1CE4_E5B9
            &+ UInt64(truncatingIfNeeded: k) &* 0x94D0_49BB_1331_11EB
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// A point in the unit ball (uniform by volume).
    static func ballPoint(_ i: Int, seed: UInt64) -> Vec3 {
        let z = 2 * unit(i, 10, seed: seed) - 1, a = 2 * Double.pi * unit(i, 11, seed: seed)
        let r = cbrt(unit(i, 12, seed: seed)), s = sqrt(max(0, 1 - z * z))
        return Vec3(s * cos(a), s * sin(a), z) * r
    }
}
