import Foundation

/// Track E2's render settings: the Earth's surface: imagery month, relief, ocean, night lights. E2 owns this file and fills
/// it; `RenderSettings` holds one.
public struct EarthSurfaceSettings: Codable, Equatable {
    public init() {}
}
