import Foundation
import simd
import OrbitCore

// Swift mirrors of the structs in Shaders.swift. Only float4 / float4x4
// members, so the memory layout is identical on both sides.

struct PlanetUniforms {
    var viewToWorld: simd_float4x4
    var worldToBody: simd_float4x4
    var centerRadius: SIMD4<Float>
    var params: SIMD4<Float>
    var sunDir: SIMD4<Float>
    var baseColor: SIMD4<Float>
    var atmosphere: SIMD4<Float>
    var options: SIMD4<Float>
    var origin: SIMD4<Float>
    var figure: SIMD4<Float>
}

struct MeshVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
    /// rgb linear; w: the shape's `VisualShape.EmissiveRole` raw value.
    var color: SIMD4<Float>
}

struct MeshUniforms {
    var modelViewProjection: simd_float4x4
    var model: simd_float4x4
    /// Takes normals to the world: the model's rotation, with the inverse of
    /// any scale (canopies are scaled unevenly).
    var normalMatrix: simd_float4x4
    /// xyz: unit vector to the Sun (world).
    var sunDir: SIMD4<Float>
    /// x: sunlit fraction (`Eclipse`), y: ambient floor, z: earthshine
    /// irradiance from the whole disc lit (Sun = 1), w: unused.
    var light: SIMD4<Float>
    /// xyz: unit vector to the reference body's centre (world), w: the lit
    /// share of the disc the vessel sees.
    var earthDir: SIMD4<Float>
    /// rgb: the earthshine's colour.
    var earthColor: SIMD4<Float>
    /// rgb: heat-shield glow (linear, added on emissive vertices), w: unused.
    var glow: SIMD4<Float>
    /// xyz: unit vector along the vessel's velocity through the air (world),
    /// the side the heating is on; zero without air.
    var flowDir: SIMD4<Float>
}

struct PointVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
    var size: SIMD4<Float>
}

struct PointUniforms {
    var viewProjection: simd_float4x4
    var params: SIMD4<Float>      // x: point-size scale (backing scale factor)
}

struct LineVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
}

/// A plume impostor's vertex (Plumes.swift).
struct PlumeVertex {
    /// Camera-relative world position, w = 1.
    var position: SIMD4<Float>
    /// rgb: colour times intensity (added), w: unused.
    var color: SIMD4<Float>
    /// x: across the cone (-1...1), y: along it (0 at the exit, 1 at the
    /// tail), z: the dark fuel-rich core's strength, w: 0 for the cone, 1
    /// for the glow disc (x, y then the disc's coordinates).
    var shape: SIMD4<Float>
}

/// A screen-aligned sprite's vertex (SpriteAtlas.swift).
struct SpriteVertex {
    /// Camera-relative world position of the anchor, w = 1.
    var position: SIMD4<Float>
    /// xy: offset from the anchor in pixels (y up), zw: atlas texture coordinates.
    var offset: SIMD4<Float>
    /// Tint (premultiplied by alpha).
    var color: SIMD4<Float>
}

struct SpriteUniforms {
    var viewProjection: simd_float4x4
    /// xy: 2 / drawable size in pixels (pixels to NDC).
    var params: SIMD4<Float>
}

// MARK: - Conversions from the double-precision core types

extension SIMD4 where Scalar == Float {
    init(_ v: Vec3, _ w: Float) {
        self.init(Float(v.x), Float(v.y), Float(v.z), w)
    }
}

extension simd_float4x4 {
    /// Rotation-only 4x4 from a row-major double 3x3.
    init(rotation m: Mat3) {
        self.init(columns: (
            SIMD4<Float>(Float(m[0, 0]), Float(m[1, 0]), Float(m[2, 0]), 0),
            SIMD4<Float>(Float(m[0, 1]), Float(m[1, 1]), Float(m[2, 1]), 0),
            SIMD4<Float>(Float(m[0, 2]), Float(m[1, 2]), Float(m[2, 2]), 0),
            SIMD4<Float>(0, 0, 0, 1)))
    }

    /// Rotation plus translation (translation given in camera-relative metres).
    init(rotation m: Mat3, translation t: Vec3) {
        self.init(rotation: m)
        columns.3 = SIMD4<Float>(Float(t.x), Float(t.y), Float(t.z), 1)
    }

    /// Reversed-Z perspective with an infinite far plane: depth = near / -z.
    static func reversedInfinitePerspective(fovY: Float, aspect: Float, near: Float) -> simd_float4x4 {
        let f = 1 / tan(fovY / 2)
        return simd_float4x4(columns: (
            SIMD4<Float>(f / aspect, 0, 0, 0),
            SIMD4<Float>(0, f, 0, 0),
            SIMD4<Float>(0, 0, 0, -1),
            SIMD4<Float>(0, 0, near, 0)))
    }
}

extension Mat3 {
    /// The shortest rotation taking unit vector `a` to unit vector `b`
    /// (identity when they agree; a half turn about any normal when opposite).
    static func rotation(from a: Vec3, to b: Vec3) -> Mat3 {
        let c = max(-1, min(1, a.dot(b))), axis = a.cross(b), s = axis.length
        if s < 1e-12 {
            if c > 0 { return .identity }
            let n = VisualShape.defaultReference(for: a)
            return Quat(axis: n, angle: Double.pi).matrix
        }
        return Quat(axis: axis / s, angle: atan2(s, c)).matrix
    }
}
