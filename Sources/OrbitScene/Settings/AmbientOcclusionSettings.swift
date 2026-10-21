import Foundation

/// Track R5's render settings: the baked per-vertex ambient occlusion. R5 owns this file and fills
/// it; `RenderSettings` holds one.
public struct AmbientOcclusionSettings: Codable, Equatable {
    public init() {}
}
