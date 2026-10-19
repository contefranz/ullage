import Foundation

/// A ΔV counter, as on the Apollo Entry Monitor System: loaded with a burn's
/// Δv, it counts down the Δv sensed along the thrust axis while the engine
/// burns, and cuts the engine off at zero. A flight program that has one
/// adopts it, so that displays can load and read it.
public protocol DeltaVCounting: AnyObject {
    /// Δv still to go, m/s; nil while the counter is not loaded.
    var deltaVRemaining: Double? { get }
    /// Load the counter with `deltaV` m/s for the next burn, or clear it
    /// with nil.
    func loadDeltaV(_ deltaV: Double?)
}
