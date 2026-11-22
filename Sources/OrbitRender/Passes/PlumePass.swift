import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

/// P0: the frame's plumes (`PlumeSystem.prepare`): their members, clusters
/// and level of detail, the nozzle glow's heat, and the plume lights,
/// written into the frame's lighting uniforms for R2's vessel pass. Track
/// P2 owns this file, Plumes.swift and the plume module.
@MainActor
public final class PlumePreparePass: RenderPass {
    public let name = "Plume lights"
    public let stage = PassStage.prepare
    /// After the atmosphere's and the clouds' (their sky and layer).
    public let order = 900

    let system: PlumeSystem

    public init(system: PlumeSystem) {
        self.system = system
    }

    public func setUp(_ s: PassSetup) throws {
        try system.setUp(device: s.device, shaders: s.shaders)
    }

    public func startOver() { system.startOver() }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        system.prepare(f)
        guard case .commandBuffer = e, let noise = system.noise, !noise.isReady,
              system.marches(f), let enc = f.makeComputeEncoder() else { return }
        system.encodeNoise(enc)
        enc.endEncoding()
    }
}

/// The ray-marched plumes, R6's volumes layer at half resolution (P3): one
/// instanced draw of every marched cluster's proxy, back faces only, each
/// fragment intersecting its ray with the proxy and marching it.
@MainActor
public final class PlumeMarchEffect: HalfResEffect {
    public let name = "Plume march"

    let system: PlumeSystem
    private var pipeline: MTLRenderPipelineState?
    private var fallback: MTLTexture?

    public init(system: PlumeSystem) {
        self.system = system
    }

    public func setUpHalfRes(_ s: HalfResSetup) throws {
        try system.setUp(device: s.device, shaders: s.shaders)
        pipeline = try s.pipeline(try s.shaders.library(.plume), vertex: "plume_proxy_vertex",
                                  fragment: "plume_march_fragment", layer: .volumes)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        fallback = s.device.makeTexture(descriptor: d)
    }

    public func halfResLayers(in f: FrameContext) -> HalfResLayers {
        pipeline != nil && system.noise != nil && system.marches(f) ? .volumes : []
    }

    public func encodeHalfRes(_ f: FrameContext, _ slots: HalfResSlots, _ enc: MTLRenderCommandEncoder) {
        system.prepare(f)
        let data = system.frame
        guard let pipeline, let noise = system.noise, let fallback, !data.marched.isEmpty,
              let clusters = f.arena.push(data.marched), let members = f.arena.push(data.members) else { return }
        var u = data.uniforms
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(slots.noDepth)
        // Back faces only: each texel once, the camera inside too.
        enc.setFrontFacing(.counterClockwise)
        enc.setCullMode(.front)
        enc.setVertexBuffer(clusters.buffer, offset: clusters.offset, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<PlumeFrameGPU>.stride, index: 0)
        enc.setFragmentBuffer(clusters.buffer, offset: clusters.offset, index: 1)
        enc.setFragmentBuffer(members.buffer, offset: members.offset, index: 2)
        enc.setFragmentTexture(noise.texture, index: 0)
        enc.setFragmentSamplerState(noise.sampler, index: 0)
        enc.setFragmentTexture(f.textures[.cloudLayer] ?? fallback, index: 1)
        enc.setFragmentTexture(f.textures[.cloudDepth] ?? fallback, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: Plumes.proxyVertices,
                           instanceCount: data.marched.count)
        enc.setCullMode(.none)
    }
}

/// The plumes at full resolution in the scene (P3, before R6's composite):
/// the impostors of small plumes, premultiplied, the SPS extension's glow
/// added on its drawn bell, and the J-2s' chambers glowing through their
/// throats.
@MainActor
public final class PlumePass: RenderPass {
    public let name = "Plumes"
    public let stage = PassStage.transparent
    public let order = 10

    let system: PlumeSystem
    private var impostor: MTLRenderPipelineState?
    private var glow: MTLRenderPipelineState?

    public init(system: PlumeSystem) {
        self.system = system
    }

    public func isActive(in f: FrameContext) -> Bool { system.drawsFullResolution(f) }

    public func setUp(_ s: PassSetup) throws {
        let library = try s.shaders.library(.plume)
        impostor = try PipelineBuilder.scene(library, vertex: "plume_impostor_vertex",
                                             fragment: "plume_impostor_fragment", blend: .premultiplied, setup: s)
        glow = try PipelineBuilder.scene(library, vertex: "plume_glow_vertex", fragment: "plume_glow_fragment",
                                         blend: .additive, setup: s)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e else { return }
        system.prepare(f)
        let data = system.frame
        var u = data.uniforms
        if let impostor, let b = f.arena.push(data.impostors) {
            enc.setRenderPipelineState(impostor)
            enc.setDepthStencilState(f.states.depthReadOnly)
            enc.setCullMode(.none)
            enc.setVertexBuffer(b.buffer, offset: b.offset, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<PlumeFrameGPU>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: data.impostors.count)
        }
        if let glow, !data.glows.isEmpty || !data.chambers.isEmpty { drawGlows(f, enc, glow, data, &u) }
    }

    /// Each glowing nozzle's draws again, emissive and added: the same
    /// vertices through the same transform as the vessel pass, nudged
    /// towards the camera so they pass its depth.
    private func drawGlows(_ f: FrameContext, _ enc: MTLRenderCommandEncoder, _ pipeline: MTLRenderPipelineState,
                           _ data: PlumeFrameData, _ u: inout PlumeFrameGPU) {
        let spec = ApolloExhaust.sps.spec
        let top = spec.exitRadius * (6 / spec.areaRatio).squareRoot()
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(f.states.depthReadOnly)
        enc.setDepthBias(2, slopeScale: 2, clamp: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<PlumeFrameGPU>.stride, index: 0)
        // The SPS extension's heat, and the chambers seen through their
        // throats (the J-2s'): each the thruster's own draws again.
        var items: [(vessel: UUID, thruster: RenderScene.ThrusterKey, heat: Double,
                     chamber: (exit: SIMD4<Float>, axis: SIMD4<Float>, light: SIMD4<Float>, throat: SIMD4<Float>)?)] =
            data.glows.map { ($0.vessel, $0.thruster, $0.heat, nil) }
        items += data.chambers.map { c in
            (c.vessel, c.thruster, 1, (Plumes.f4(c.exit, c.chamber.throatDepth), Plumes.f4(c.axis, c.chamber.injectorDepth),
                                     Plumes.f4(c.light, c.chamber.radius),
                                     Plumes.f4(c.chamber.throatRadius, c.chamber.convergentDepth, 0, 0)))
        }
        for g in items {
            guard let v = f.scene.vessels.first(where: { $0.id == g.vessel }), let mesh = f.mesh(of: v) else { continue }
            let pose = v.thrusters[g.thruster]
            guard pose != nil || g.chamber != nil else { continue }
            let attitude = v.attitude.matrix
            let translation = v.position + v.attitude.rotate(v.structureOrigin)
            for (entry, offset) in zip(mesh.parts, mesh.offsets) {
                // A fixed engine (the S-II's centre J-2) is in its part's
                // static draws: those again, its chamber picked out by the
                // fragment's test in the world.
                let fixed = g.chamber != nil && entry.part.thrusters.contains { $0.key == g.thruster && !$0.isGimballed }
                enc.setVertexBuffer(entry.mesh.vertices, offset: 0, index: 0)
                for d in entry.mesh.draws where d.thruster == g.thruster || (fixed && d.thruster == nil) {
                    let r = d.thruster == nil ? Mat3.identity
                        : pose.map { Mat3.rotation(from: $0.direction, to: $0.thrustDirection) } ?? Mat3.identity
                    var draw = PlumeGlowGPU(
                        model: simd_float4x4(rotation: attitude * r,
                                             translation: translation + attitude * (offset + d.pivot - r * d.pivot)),
                        pivot: Plumes.f4(d.pivot, top), direction: Plumes.f4(pose?.direction ?? .unitX, g.heat))
                    if let c = g.chamber {
                        draw.chamberExit = c.exit
                        draw.chamberAxis = c.axis
                        draw.chamberLight = c.light
                        draw.chamberThroat = c.throat
                    }
                    enc.setCullMode(.none)
                    enc.setVertexBytes(&draw, length: MemoryLayout<PlumeGlowGPU>.stride, index: 1)
                    enc.setFragmentBytes(&draw, length: MemoryLayout<PlumeGlowGPU>.stride, index: 1)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: d.indices.count, indexType: .uint32,
                                              indexBuffer: entry.mesh.indices,
                                              indexBufferOffset: d.indices.lowerBound * 4)
                }
            }
        }
        enc.setDepthBias(0, slopeScale: 0, clamp: 0)
    }
}
