import Foundation
import Metal
import OrbitScene

/// The atmosphere's LUTs and aerial-perspective froxels (P0).
/// Track A2 owns this pass. It is off, and the frame graph skips it,
/// until A2 fills it.
@MainActor
public final class AtmosphereLUTPass: RenderPass {
    public let name = "Atmosphere LUTs"
    public let stage = PassStage.prepare
    public let order = 0
    public var writes: Set<ResourceID> { [.atmosphereLUTs, .aerialPerspective] }
    public var isEnabled: Bool { false }

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        _ = try s.shaders.library(.atmosphere)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {}
}

/// The sky, aerial perspective over everything opaque, and the cloud layer,
/// composited full-screen (P2). Today's sky and haze stay in the planet
/// shader until it lands.
/// Track A2 owns this pass. It is off, and the frame graph skips it,
/// until A2 fills it.
@MainActor
public final class AtmosphereCompositePass: RenderPass {
    public let name = "Atmosphere composite"
    public let stage = PassStage.composite
    public let order = 0
    public var reads: Set<ResourceID> { [.atmosphereLUTs, .aerialPerspective] }
    public var isEnabled: Bool { false }

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        _ = try s.shaders.library(.atmosphere)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {}
}
