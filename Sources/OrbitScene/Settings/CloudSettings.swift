import Foundation

/// Track C2's render settings: volumetric clouds: regimes, steps, reprojection. C2 owns this file and fills
/// it; `RenderSettings` holds one.
public struct CloudSettings: Codable, Equatable {
    public init() {}
}
