import Foundation
import Metal
import OrbitScene

/// The half-resolution volume target and weighted-blended OIT pair, and
/// their depth-aware upsample (P3).
/// Track R6 owns this pass. It is off, and the frame graph skips it,
/// until R6 fills it.
@MainActor
public final class HalfResTransparentPass: RenderPass {
    public let name = "Half-resolution transparents"
    public let stage = PassStage.transparent
    public let order = 30
    public var writes: Set<ResourceID> { [.halfResDepth, .halfResTransparent] }
    public var isEnabled: Bool { false }

    public init() {}

    public func encode(_ f: FrameContext, _ e: PassEncoding) {}
}
