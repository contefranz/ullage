import Foundation

extension Simulation {
    /// The entry telemetry of `v` at the end of a step: its sensed
    /// acceleration and load factor, bank angle and heating
    /// (`Vessel.sensedAcceleration` ... `heatLoad`). Not computed yet.
    func updateEntryTelemetry(_ v: Vessel, snapshot s: SystemSnapshot) {}
}
