import Foundation
import Metal
import OrbitScene

/// Volumetric clouds (P0): coverage, the cloud shadow map, and the march
/// into the cloud layer and its depth, which the P2 composite applies.
/// Track C2 owns this pass. It is off, and the frame graph skips it,
/// until C2 fills it.
@MainActor
public final class CloudPass: RenderPass {
    public let name = "Clouds"
    public let stage = PassStage.prepare
    public let order = 10
    public var writes: Set<ResourceID> { [.cloudLayer, .cloudDepth, .cloudShadow] }
    public var isEnabled: Bool { false }

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        _ = try s.shaders.library(.cloud)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {}
}
