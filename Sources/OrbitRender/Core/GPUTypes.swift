import Foundation
import simd
import OrbitCore
import OrbitScene

// Swift mirrors of the structs in the shader modules. Only float4 / float4x4
// members (and fixed arrays of them, as tuples), so the memory layout is
// identical on both sides; ShaderCompileTests checks the sizes against MSL.
// Each pass keeps its own mirrors in its own file; the shared ones are here.

/// The point, line and plume pipelines' uniforms (ShaderCommon).
public struct PointUniforms {
    public var viewProjection: simd_float4x4
    /// x: point-size scale (pixels per point).
    public var params: SIMD4<Float>

    public init(viewProjection: simd_float4x4, params: SIMD4<Float>) {
        self.viewProjection = viewProjection
        self.params = params
    }
}

// MARK: - Conversions from the double-precision core types

extension SIMD4 where Scalar == Float {
    public init(_ v: Vec3, _ w: Float) {
        self.init(Float(v.x), Float(v.y), Float(v.z), w)
    }
}

extension SIMD3 where Scalar == Float {
    public init(_ c: RenderScene.RGB) {
        self.init(c.r, c.g, c.b)
    }
}

extension simd_float4x4 {
    /// Rotation-only 4x4 from a row-major double 3x3.
    public init(rotation m: Mat3) {
        self.init(columns: (
            SIMD4<Float>(Float(m[0, 0]), Float(m[1, 0]), Float(m[2, 0]), 0),
            SIMD4<Float>(Float(m[0, 1]), Float(m[1, 1]), Float(m[2, 1]), 0),
            SIMD4<Float>(Float(m[0, 2]), Float(m[1, 2]), Float(m[2, 2]), 0),
            SIMD4<Float>(0, 0, 0, 1)))
    }

    /// Rotation plus translation (translation given in camera-relative metres).
    public init(rotation m: Mat3, translation t: Vec3) {
        self.init(rotation: m)
        columns.3 = SIMD4<Float>(Float(t.x), Float(t.y), Float(t.z), 1)
    }

    /// Reversed-Z perspective with an infinite far plane: depth = near / -z.
    public static func reversedInfinitePerspective(fovY: Float, aspect: Float, near: Float) -> simd_float4x4 {
        let f = 1 / tan(fovY / 2)
        return simd_float4x4(columns: (
            SIMD4<Float>(f / aspect, 0, 0, 0),
            SIMD4<Float>(0, f, 0, 0),
            SIMD4<Float>(0, 0, 0, -1),
            SIMD4<Float>(0, 0, near, 0)))
    }
}
