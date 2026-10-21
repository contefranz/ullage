import Foundation

/// Track A2's render settings: the atmosphere: LUTs, aerial perspective, the limb. A2 owns this file and fills
/// it; `RenderSettings` holds one.
public struct AtmosphereSettings: Codable, Equatable {
    public init() {}
}
