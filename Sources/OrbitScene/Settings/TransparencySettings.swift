import Foundation

/// Track R6's render settings: the half-resolution volume target, weighted-blended OIT and the composite order. R6 owns this file and fills
/// it; `RenderSettings` holds one.
public struct TransparencySettings: Codable, Equatable {
    public init() {}
}
