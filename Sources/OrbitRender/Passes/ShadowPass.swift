import Foundation
import Metal
import OrbitScene

/// Sun shadow maps (P0): one per vessel cluster and a detail map about the
/// camera target.
/// Track R4 owns this pass. It is off, and the frame graph skips it,
/// until R4 fills it.
@MainActor
public final class ShadowPass: RenderPass {
    public let name = "Shadows"
    public let stage = PassStage.prepare
    public let order = 20
    public var writes: Set<ResourceID> { [.shadowAtlas] }
    public var isEnabled: Bool { false }

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        _ = try s.shaders.library(.shadow)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {}
}
