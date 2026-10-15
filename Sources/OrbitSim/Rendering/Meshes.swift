import Foundation
import Metal
import OrbitCore

/// Triangle list for a vessel built from its parts' primitive shapes, in the
/// vessel frame (metres). Rebuilt whenever the vessel's part list changes.
struct VesselMesh {
    let buffer: MTLBuffer
    let vertexCount: Int
    let signature: [ObjectIdentifier]

    static func signature(of vessel: Vessel) -> [ObjectIdentifier] {
        vessel.parts.map { ObjectIdentifier($0) }
    }

    static func build(for vessel: Vessel, device: MTLDevice) -> VesselMesh? {
        var verts: [MeshVertex] = []
        for part in vessel.parts {
            for shape in part.shapes {
                append(shape, offset: part.offset, to: &verts)
            }
        }
        guard !verts.isEmpty,
              let buffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<MeshVertex>.stride,
                                             options: .storageModeShared) else { return nil }
        return VesselMesh(buffer: buffer, vertexCount: verts.count, signature: signature(of: vessel))
    }

    private static func append(_ shape: VisualShape, offset: Vec3, to verts: inout [MeshVertex]) {
        let color = SIMD4<Float>(Float(shape.color.0), Float(shape.color.1), Float(shape.color.2), 1)
        switch shape.kind {
        case let .frustum(baseRadius, topRadius):
            let axis = shape.axis
            // Orthonormal basis around the axis.
            let helper = abs(axis.x) < 0.9 ? Vec3.unitX : Vec3.unitY
            let u = axis.cross(helper).normalized
            let w = axis.cross(u)
            let base = offset + shape.origin
            let top = base + axis * shape.length
            let segments = 32
            // Slope of the side for normals.
            let slope = (baseRadius - topRadius) / max(shape.length, 1e-6)
            func ring(_ i: Int) -> Vec3 {
                let a = Double(i) / Double(segments) * 2 * Double.pi
                return u * cos(a) + w * sin(a)
            }
            func vtx(_ p: Vec3, _ n: Vec3) -> MeshVertex {
                MeshVertex(position: SIMD4(p, 1), normal: SIMD4(n.normalized, 0), color: color)
            }
            for i in 0..<segments {
                let d0 = ring(i), d1 = ring(i + 1)
                let n0 = d0 + axis * slope, n1 = d1 + axis * slope
                let b0 = base + d0 * baseRadius, b1 = base + d1 * baseRadius
                let t0 = top + d0 * topRadius, t1 = top + d1 * topRadius
                verts += [vtx(b0, n0), vtx(b1, n1), vtx(t1, n1), vtx(b0, n0), vtx(t1, n1), vtx(t0, n0)]
                // Caps.
                if topRadius > 0 {
                    verts += [vtx(top, axis), vtx(t0, axis), vtx(t1, axis)]
                }
                if baseRadius > 0 {
                    verts += [vtx(base, -axis), vtx(b1, -axis), vtx(b0, -axis)]
                }
            }
        case let .sphere(radius):
            let c = offset + shape.origin
            let rings = 12, segments = 24
            func point(_ i: Int, _ j: Int) -> Vec3 {
                let lat = Double.pi * (Double(i) / Double(rings) - 0.5)
                let lon = 2 * Double.pi * Double(j) / Double(segments)
                return Vec3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
            }
            for i in 0..<rings {
                for j in 0..<segments {
                    let p00 = point(i, j), p01 = point(i, j + 1), p10 = point(i + 1, j), p11 = point(i + 1, j + 1)
                    for n in [p00, p01, p11, p00, p11, p10] {
                        verts.append(MeshVertex(position: SIMD4(c + n * radius, 1), normal: SIMD4(n, 0), color: color))
                    }
                }
            }
        }
    }
}
