import Foundation

/// A program that flies a vessel, such as the Saturn V Instrument Unit: it
/// runs at the start of every control step, before the throttles are applied,
/// and may set any of the vessel's controls (throttle, engines, gimbal biases,
/// autopilot and attitude command) or stage it through the simulation.
public protocol FlightProgram: AnyObject {
    /// One control step of `vessel` at `sim.time`.
    func update(_ vessel: Vessel, in sim: Simulation)
    /// Seconds from `now` to the program's next timed action, so that the
    /// simulation can end a step there; nil when none is scheduled.
    func timeToNextEvent(at now: Epoch) -> Double?
    /// One line for the HUD.
    var status: String { get }
    /// Whether the pilot may stage `vessel` now (the Space key).
    func allowsManualStaging(of vessel: Vessel) -> Bool
    /// Name of the part that carries the program (the Saturn's "IU"); nil
    /// when it is not tied to one.
    var hostPart: String? { get }
    /// The next event the program will act on, for the pilot: its name and
    /// when it is due; nil when none is known.
    func nextEvent(at now: Epoch) -> (name: String, at: Epoch)?
}

extension FlightProgram {
    public func allowsManualStaging(of vessel: Vessel) -> Bool { true }
    public var hostPart: String? { nil }
    public func nextEvent(at now: Epoch) -> (name: String, at: Epoch)? { nil }
}
