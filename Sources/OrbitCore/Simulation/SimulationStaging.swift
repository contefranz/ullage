import Foundation

extension Simulation {
    /// Separate the next staging event of `v` (`Vessel.jettisonNextStage`),
    /// or staging event `event` if given (`Vessel.jettison(event:)`); the
    /// spent parts become their own vessels (`stageAll`). Returns the main
    /// one (the S-IVB stack at CSM separation, not its SLA panels).
    @discardableResult
    public func stage(_ v: Vessel, event: Int? = nil) -> Vessel? { stageAll(v, event: event).first }

    /// `stage`, returning every vessel the separation makes, the main one
    /// first: each is added to the simulation. Without an event (the
    /// pilot's Space key) a flight program aboard may refuse it.
    @discardableResult
    public func stageAll(_ v: Vessel, event: Int? = nil) -> [Vessel] {
        if event == nil, let program = v.flightProgram, !program.allowsManualStaging(of: v) {
            log("\(v.name): staging inhibited by the flight program")
            return []
        }
        let separated = event ?? v.nextStagingEvent
        let spent = event.map { v.jettisonAll(event: $0) } ?? v.jettisonNextStageAll()
        guard !spent.isEmpty else { return [] }
        let snap = snapshot
        for s in spent {
            add(s)
            updateTelemetry(s, snapshot: snap)
        }
        updateTelemetry(v, snapshot: snap)
        for s in spent { recordEffect(.separation(event: separated, parts: s.parts.map(\.name), parent: v.id), s) }
        log("\(v.name): staged \(spent.map { $0.parts.first?.name ?? "part" }.joined(separator: ", "))")
        return spent
    }
}
