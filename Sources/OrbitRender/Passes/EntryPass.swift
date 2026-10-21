import Foundation
import Metal
import OrbitScene

/// The plasma sheath's shock-layer shell and wake (P3).
/// Track P6 owns this pass. It is off, and the frame graph skips it,
/// until P6 fills it.
@MainActor
public final class EntryPass: RenderPass {
    public let name = "Entry plasma"
    public let stage = PassStage.transparent
    public let order = 50
    public var isEnabled: Bool { false }

    public init() {}

    public func setUp(_ s: PassSetup) throws {
        _ = try s.shaders.library(.entry)
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {}
}
