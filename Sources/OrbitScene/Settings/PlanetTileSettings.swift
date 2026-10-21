import Foundation

/// Track E1's render settings: the planet tile cache: atlas size, prefetch. E1 owns this file and fills
/// it; `RenderSettings` holds one.
public struct PlanetTileSettings: Codable, Equatable {
    public init() {}
}
