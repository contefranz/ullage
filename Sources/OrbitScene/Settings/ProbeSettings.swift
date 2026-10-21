import Foundation

/// Track R3's render settings: the environment probe and image-based lighting, the night floor. R3 owns this file and fills
/// it; `RenderSettings` holds one.
public struct ProbeSettings: Codable, Equatable {
    public init() {}
}
