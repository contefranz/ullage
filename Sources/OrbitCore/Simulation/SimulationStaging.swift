import Foundation

extension Simulation {
    /// Separate the next staging event of `v` (`Vessel.jettisonNextStage`),
    /// or staging event `event` if given (`Vessel.jettison(event:)`); the
    /// spent parts become their own vessel. Without an event (the pilot's
    /// Space key) a flight program aboard may refuse it.
    @discardableResult
    public func stage(_ v: Vessel, event: Int? = nil) -> Vessel? {
        if event == nil, let program = v.flightProgram, !program.allowsManualStaging(of: v) {
            log("\(v.name): staging inhibited by the flight program")
            return nil
        }
        let separated: Vessel?
        if let event { separated = v.jettison(event: event) } else { separated = v.jettisonNextStage() }
        guard let spent = separated else { return nil }
        add(spent)
        updateTelemetry(spent, snapshot: snapshot)
        updateTelemetry(v, snapshot: snapshot)
        log("\(v.name): staged \(spent.parts.first?.name ?? "part")")
        return spent
    }
}
