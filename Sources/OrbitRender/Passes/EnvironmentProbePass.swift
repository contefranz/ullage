import Foundation
import Metal
import OrbitScene

/// The environment probe (P0): a radiance cube at the camera target, its
/// GGX-prefiltered mips, the irradiance cube and SH9.
/// Track R3 owns this pass. It is off, and the frame graph skips it,
/// until R3 fills it.
@MainActor
public final class EnvironmentProbePass: RenderPass {
    public let name = "Environment probe"
    public let stage = PassStage.prepare
    public let order = 30
    public var writes: Set<ResourceID> { [.environment] }
    public var isEnabled: Bool { false }

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        _ = try s.shaders.library(.probe)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {}
}
