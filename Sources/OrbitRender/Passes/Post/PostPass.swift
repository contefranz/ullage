import Foundation
import Metal
import OrbitScene

/// Post (P4): the NaN guard, histogram and exposure, bloom, tone mapping and
/// dither into the output.
/// Track R1 owns this pass. It is off, and the frame graph skips it,
/// until R1 fills it.
@MainActor
public final class PostPass: RenderPass {
    public let name = "Post"
    public let stage = PassStage.post
    public let order = 0
    public var reads: Set<ResourceID> { [.hdrColor] }
    public var isEnabled: Bool { false }

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        _ = try s.shaders.library(.post)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {}
}
