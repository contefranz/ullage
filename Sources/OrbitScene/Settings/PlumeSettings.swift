import Foundation

/// Track P2's render settings: ray-marched plumes: steps, LOD, the "readable plumes" toggle. P2 owns this file and fills
/// it; `RenderSettings` holds one.
public struct PlumeSettings: Codable, Equatable {
    public init() {}
}
