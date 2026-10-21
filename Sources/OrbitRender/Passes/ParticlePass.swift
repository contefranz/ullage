import Foundation
import Metal
import OrbitScene

/// GPU particles' emission and simulation (P0).
/// Track P3 owns this pass. It is off, and the frame graph skips it,
/// until P3 fills it.
@MainActor
public final class ParticleSimulationPass: RenderPass {
    public let name = "Particle simulation"
    public let stage = PassStage.prepare
    public let order = 40
    public var writes: Set<ResourceID> { [.particles] }
    public var isEnabled: Bool { false }

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        _ = try s.shaders.library(.particle)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {}
}

/// GPU particles drawn: additive streaks, smoke and chunks (P3).
/// Track P3 owns this pass. It is off, and the frame graph skips it,
/// until P3 fills it.
@MainActor
public final class ParticleDrawPass: RenderPass {
    public let name = "Particles"
    public let stage = PassStage.transparent
    public let order = 40
    public var reads: Set<ResourceID> { [.particles] }
    public var isEnabled: Bool { false }

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        _ = try s.shaders.library(.particle)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {}
}
