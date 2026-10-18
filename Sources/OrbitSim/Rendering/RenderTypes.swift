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
    var color: SIMD4<Float>
}

struct MeshUniforms {
    var modelViewProjection: simd_float4x4
    var model: simd_float4x4
    var sunDir: SIMD4<Float>
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
