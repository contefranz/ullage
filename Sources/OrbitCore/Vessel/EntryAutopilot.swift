import Foundation

/// What the entry autopilot holds about the velocity relative to the air
/// (`Vessel.entryCommand`).
public enum EntryCommand: Equatable {
    /// Hold the lift vector `bank` rad from the local up, positive to the
    /// right looking along the velocity: 0 is lift up, π lift down.
    case bank(Double)
    /// Roll steadily at `rate` rad/s, for zero mean lift.
    case rolling(rate: Double)
}
