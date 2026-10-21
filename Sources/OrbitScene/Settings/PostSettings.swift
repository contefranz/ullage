import Foundation

/// Track R1's render settings: HDR targets, exposure (auto and the photo mode), tone mapping, bloom, stars. R1 owns this file and fills
/// it; `RenderSettings` holds one.
public struct PostSettings: Codable, Equatable {
    public init() {}
}
