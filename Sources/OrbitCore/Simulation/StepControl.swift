import Foundation

extension Simulation {
    /// Largest stable step for the current situation.
    func maxStep() -> Double {
        var h = 60.0
        for v in vessels where v.status != .crashed {
            h = min(h, maxStep(for: v))
        }
        return h
    }

    func maxStep(for v: Vessel) -> Double {
        var h = 60.0
        if v.landed != nil {
            h = v.thrusters.contains(where: { $0.isCommanded || ($0.isEnabled && $0.level > 0) }) ? 0.02 : 10
        } else {
            // Commanded engines too: a start delay delivers nothing yet.
            let thrusting = v.thrusters.contains { $0.isCommanded || $0.isDelivering }
            if thrusting || v.dynamicPressure > 1 { h = min(h, 0.02) }
            let w = v.angularVelocity.length
            if w > 1e-6 { h = min(h, 0.05 / w) }
            let r = v.position.length
            let orbital = (r * r * r / v.reference.gm).squareRoot()   // = period / 2π for a circle
            h = min(h, 2 * Double.pi / 1000 * orbital)
            // The phase-plane law decides once a step: end the step where a
            // coasting axis reaches its switching line, and turn no more than
            // its dead band in any step, so it never sees the line late (a
            // limit cycle at warp otherwise).
            if let law = v.phasePlane, let mode = v.autopilot, mode != .killRotation {
                h = min(h, v.groupSwitch)
                if w > 1e-12 { h = min(h, law.deadband / w) }
            }
        }
        // End steps where a phase-plane pulse ends and on the program's next event.
        let pulse = v.groupPulse.remaining
        for r in [pulse.x, pulse.y, pulse.z] where r > 1e-9 { h = min(h, r) }
        if let next = v.flightProgram?.timeToNextEvent(at: time), next > 0 { h = min(h, next) }
        h = max(h, 1e-3)
        // And where a lit solid's grain runs out, at the flow of every lit
        // solid it feeds, even within the 1 ms floor: its impulse then does
        // not depend on the step.
        var grains: [ObjectIdentifier: (tank: PropellantTank, flow: Double)] = [:]
        for t in v.thrusters where t.isSolid && t.isCommanded {
            guard let tank = t.tank else { continue }
            grains[ObjectIdentifier(tank), default: (tank, 0)].flow += t.currentRating.massFlow
        }
        for g in grains.values where g.flow > 0 {
            let r = g.tank.usableMass / g.flow
            if r > 0 { h = min(h, max(r, 1e-9)) }
        }
        return h
    }
}
