import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

/// The vessels' meshes, their gimballed nozzles and their parachute
/// canopies (P1). Track R2 owns this pass and its shader module.
@MainActor
public final class VesselPass: RenderPass {
    public let name = "Vessels"
    public let stage = PassStage.opaque
    public let order = 20

    private var pipeline: MTLRenderPipelineState?
    private var mainCanopy: CanopyMesh?
    private var drogueCanopy: CanopyMesh?

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        pipeline = try PipelineBuilder.scene(try s.shaders.library(.vessel), vertex: "mesh_vertex",
                                             fragment: "mesh_fragment", blend: .opaque, setup: s)
        let orange = (0.89, 0.17, 0.012), white = (0.9, 0.9, 0.88)
        mainCanopy = CanopyMesh.build(device: s.device, gores: 12, colours: [orange, white])
        drogueCanopy = CanopyMesh.build(device: s.device, gores: 8, colours: [white, orange])
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pipeline else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(f.states.depthWrite)
        enc.setFrontFacing(.counterClockwise)
        let viewProj = f.viewProjection
        for v in f.scene.vessels {
            guard let mesh = f.mesh(of: v) else { continue }
            let light = v.light
            // Mesh vertices are in the construction frame; v.position is the CoM.
            let attitude = v.attitude.matrix
            let translation = v.position + v.attitude.rotate(v.structureOrigin)
            var u = MeshUniforms(modelViewProjection: viewProj, model: matrix_identity_float4x4,
                                 normalMatrix: matrix_identity_float4x4, sunDir: SIMD4(light.toSun, 0),
                                 light: SIMD4(Float(light.sunlit), LegacyLighting.ambientFloor + Float(light.sky),
                                              Float(light.earthStrength), 0),
                                 earthDir: SIMD4(light.earthDirection, Float(light.earthLit)),
                                 earthColor: SIMD4(SIMD3(light.earthColor), 0),
                                 glow: SIMD4(SIMD3(v.glow), 0), flowDir: SIMD4(v.flowDirection, 0))
            enc.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
            for g in mesh.groups {
                var rotation = attitude, shift = translation
                if let key = g.thruster, let t = v.thrusters[key] {
                    // The nozzle turns about its gimbal point with the thrust.
                    let r = Mat3.rotation(from: t.direction, to: t.thrustDirection)
                    rotation = attitude * r
                    shift = translation + attitude * (g.pivot - r * g.pivot)
                }
                let m = simd_float4x4(rotation: rotation, translation: shift)
                u.model = m
                u.normalMatrix = simd_float4x4(rotation: rotation)
                u.modelViewProjection = viewProj * m
                enc.setCullMode(g.culled ? .back : .none)
                enc.setVertexBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: g.range.lowerBound, vertexCount: g.range.count)
            }
            enc.setCullMode(.none)
            drawCanopies(of: v, frame: f, uniforms: u, encoder: enc)
        }
    }

    /// The vessel's deployed canopies (`RenderScene.canopies`), lit as it is.
    private func drawCanopies(of v: RenderScene.Vessel, frame f: FrameContext, uniforms: MeshUniforms,
                              encoder enc: MTLRenderCommandEncoder) {
        var u = uniforms
        u.glow = .zero
        u.flowDir = .zero
        for c in f.scene.canopies where c.vesselID == v.id {
            guard let mesh = c.isMain ? mainCanopy : drogueCanopy else { continue }
            let m = simd_float4x4(columns: (SIMD4(c.axis * c.sx, 0), SIMD4(c.side * c.sr, 0), SIMD4(c.other * c.sr, 0),
                                            SIMD4(c.skirt, 1)))
            u.model = m
            u.normalMatrix = simd_float4x4(columns: (SIMD4(c.axis / c.sx, 0), SIMD4(c.side / c.sr, 0),
                                                     SIMD4(c.other / c.sr, 0), SIMD4(0, 0, 0, 1)))
            u.modelViewProjection = f.viewProjection * m
            enc.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertexCount)
        }
    }
}

// Swift mirrors of VesselShaders' structs.

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
