import Foundation

/// Track R2's render settings: physically based shading of vessels and sites, specular anti-aliasing, plume lights. R2 owns this file and fills
/// it; `RenderSettings` holds one.
public struct ShadingSettings: Codable, Equatable {
    public init() {}
}
