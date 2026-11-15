import Foundation
import Metal
import OrbitScene

// The GPU particles' passes (track P3), sharing one `ParticleSystem`:
// - the director and the kernels, P0;
// - chunks, opaque, P1;
// - smoke, through R6's OIT layer at half resolution (`ParticleSmokeEffect`,
//   listed in HalfResTransparentPass's effects after the plumes);
// - streaks, additive at full resolution after the composite, P3.
// Each runs only on frames its render class may have particles alive.

/// The effect director and the particles' kernels (P0).
@MainActor
public final class ParticleSimulationPass: RenderPass {
    public let name = "Particle simulation"
    public let stage = PassStage.prepare
    public let order = 40
    public var writes: Set<ResourceID> { [.particles] }

    public let system: ParticleSystem

    public init(system: ParticleSystem) {
        self.system = system
    }

    public func isActive(in f: FrameContext) -> Bool { system.plan(for: f)?.works ?? false }

    public func setUp(_ s: PassSetup) throws {
        try system.setUp(device: s.device, shaders: s.shaders)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .commandBuffer = e else { return }
        system.encodeSimulation(f)
    }
}

/// Additive streaks: sparks, glints, flashes (P3, after the composite).
@MainActor
public final class ParticleDrawPass: RenderPass {
    public let name = "Particles"
    public let stage = PassStage.transparent
    public let order = 40
    public var reads: Set<ResourceID> { [.particles] }

    let system: ParticleSystem
    private var pipeline: MTLRenderPipelineState?

    public init(system: ParticleSystem) {
        self.system = system
    }

    public func isActive(in f: FrameContext) -> Bool { system.draws(.streak, in: f) }

    public func setUp(_ s: PassSetup) throws {
        try system.setUp(device: s.device, shaders: s.shaders)
        pipeline = try PipelineBuilder.scene(try s.shaders.library(.particle), vertex: "particle_streak_vertex",
                                             fragment: "particle_streak_fragment", blend: .additive, setup: s)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pipeline, system.bindDraw(enc) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(f.states.depthReadOnly)
        enc.setCullMode(.none)
        system.draw(.streak, on: enc)
    }
}

/// Tumbling chunks: debris, ice slabs, cork (P1, opaque).
@MainActor
public final class ParticleChunkPass: RenderPass {
    public let name = "Particle chunks"
    public let stage = PassStage.opaque
    public let order = 50
    public var reads: Set<ResourceID> { [.particles] }

    let system: ParticleSystem
    private var pipeline: MTLRenderPipelineState?

    public init(system: ParticleSystem) {
        self.system = system
    }

    public func isActive(in f: FrameContext) -> Bool { system.draws(.chunk, in: f) }

    public func setUp(_ s: PassSetup) throws {
        try system.setUp(device: s.device, shaders: s.shaders)
        pipeline = try PipelineBuilder.scene(try s.shaders.library(.particle), vertex: "particle_chunk_vertex",
                                             fragment: "particle_chunk_fragment", blend: .opaque, setup: s)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .render(let enc) = e, let pipeline, system.bindDraw(enc) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(f.states.depthWrite)
        enc.setCullMode(.none)
        system.draw(.chunk, on: enc)
    }
}

/// Smoke, steam, spray: lit soft billboards through R6's weighted-blended
/// OIT layer at half resolution (none at the Low tier).
@MainActor
public final class ParticleSmokeEffect: HalfResEffect {
    public let name = "Particle smoke"

    let system: ParticleSystem
    private var pipeline: MTLRenderPipelineState?

    public init(system: ParticleSystem) {
        self.system = system
    }

    public func setUpHalfRes(_ s: HalfResSetup) throws {
        try system.setUp(device: s.device, shaders: s.shaders)
        pipeline = try s.pipeline(try s.shaders.library(.particle), vertex: "particle_smoke_vertex",
                                  fragment: "particle_smoke_fragment", layer: .oit)
    }

    public func halfResLayers(in f: FrameContext) -> HalfResLayers {
        pipeline != nil && system.draws(.smoke, in: f) ? .oit : []
    }

    public func encodeHalfRes(_ f: FrameContext, _ slots: HalfResSlots, _ enc: MTLRenderCommandEncoder) {
        guard let pipeline, let noise = system.noise, system.bindDraw(enc) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(slots.depthTest)
        enc.setCullMode(.none)
        enc.setFragmentTexture(noise.texture, index: 0)
        enc.setFragmentSamplerState(noise.sampler, index: 0)
        system.draw(.smoke, on: enc)
    }
}
