import Foundation

extension Simulation {
    /// Longest step a passive vessel takes while it thrusts or flies in the
    /// air (s): the SM's jettison jets, a spent stage's retros, debris
    /// coming down. Its thrust is constant over the step, and the step still
    /// ends where a sequence's window or a tank ends.
    static let passiveThrustStep = 1.0
    /// Largest turn (rad) a passive vessel makes in one step: well inside
    /// RK4's stable range for a spinning body, and loose enough that tumbling
    /// debris (the SLA panels' 33.5°/s) does not hold the global step down.
    static let passiveTurn = 1.0
    /// Share of |v_air| / |a_drag|, the time its drag would take to stop
    /// it, that a passive vessel in the air steps at most. The drag pulls
    /// the airspeed back to where it balances gravity at 2 |a_drag| / |v_air|,
    /// so RK4 takes that at h λ = 1, well inside its stable 2.79: a falling
    /// SLA panel steps 0.57 s or more down to the sea, at its 11 m/s, and
    /// lands within a metre of where 0.02 s steps land it.
    static let passiveDragShare = 0.5
    /// Share of H / |ḣ|, the time it takes to climb or fall through a scale
    /// height H of the air, that it steps at most.
    static let passiveClimbShare = 0.1

    /// Largest stable step for the current situation.
    func maxStep() -> Double {
        var h = 60.0
        for v in vessels where v.status != .crashed {
            h = min(h, maxStep(for: v))
        }
        return h
    }

    /// Whether `v` flies on its own: not the focus, flown by nothing (no
    /// program, autopilot, input or throttle) and off the ground. Debris:
    /// spent stages, the SLA panels, the SM. What happens to it does not
    /// need the 0.02 s steps of controlled flight, in the air or out of it
    /// (`passiveAirStep`), and its spin need not hold the steps of every
    /// vessel down.
    func isPassive(_ v: Vessel) -> Bool {
        v !== focus && v.landed == nil && v.flightProgram == nil && v.autopilot == nil && v.rotationInput.isZero
            && v.translationInput == .zero && v.mainThrottle == 0 && v.retroThrottle == 0
    }

    /// Longest step of a passive vessel in the air (dynamic pressure over
    /// 1 Pa). Debris has drag only, along the wind, with no lift and no
    /// moment: once separated, the spent S-IC and S-II, the SM and the SLA
    /// panels match no aerodynamic model, and the S-IVB's is drag along
    /// the wind. Its steps then need only resolve what the drag does to its
    /// speed and how fast the air thickens around it: a share of
    /// |v_air| / |a_drag| and of H / |ḣ|, H the local scale height. A
    /// vessel with lift, moments or a parachute out keeps the 0.02 s steps.
    func passiveAirStep(_ v: Vessel) -> Double {
        if v.parachutes.contains(where: \.isDeployed) { return 0.02 }
        var dragArea = v.dragArea
        if let model = v.activeAerodynamics {
            guard model.dragAlongWind, model.capsule == nil else { return 0.02 }
            dragArea = model.referenceArea * model.forebodyAxial(v.mach)
        }
        var h = Self.passiveThrustStep
        let drag = v.dynamicPressure * dragArea / v.mass
        if drag > 0 { h = min(h, Self.passiveDragShare * v.airspeed / drag) }
        let r = v.position.length, air = v.atmosphere
        let scaleHeight = air.pressure / air.density * r * r / v.reference.gm   // p / (ρ g)
        let climb = abs(v.position.dot(v.velocity)) / r
        if climb > 0 { h = min(h, Self.passiveClimbShare * scaleHeight / climb) }
        return h
    }

    func maxStep(for v: Vessel) -> Double {
        var h = 60.0
        let passive = isPassive(v)
        if v.landed != nil {
            h = v.thrusters.contains(where: { $0.isCommanded || ($0.isEnabled && $0.level > 0) }) ? 0.02 : 10
        } else {
            // Commanded engines too: a start delay delivers nothing yet.
            let thrusting = v.thrusters.contains { $0.isCommanded || $0.isDelivering }
            if thrusting || v.dynamicPressure > 1 { h = min(h, passive ? Self.passiveThrustStep : 0.02) }
            if passive && v.dynamicPressure > 1 { h = min(h, passiveAirStep(v)) }
            let w = v.angularVelocity.length
            if w > 1e-6 { h = min(h, (passive ? Self.passiveTurn : 0.05) / w) }
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
        // And where a firing sequence's window opens or closes.
        for t in v.thrusters { if let e = t.timeToSequenceEdge, e > 1e-9 { h = min(h, e) } }
        h = max(h, 1e-3)
        // And where a lit solid's grain runs out, at the flow of every lit
        // solid it feeds, even within the 1 ms floor: its impulse then does
        // not depend on the step. A passive vessel's liquid engines too, so
        // its long steps do not run on past an empty tank.
        var grains: [ObjectIdentifier: (tank: PropellantTank, flow: Double)] = [:]
        for t in v.thrusters where t.isSolid && t.isCommanded {
            guard let tank = t.tank else { continue }
            grains[ObjectIdentifier(tank), default: (tank, 0)].flow += t.currentRating.massFlow
        }
        for g in grains.values where g.flow > 0 {
            let r = g.tank.usableMass / g.flow
            if r > 0 { h = min(h, max(r, 1e-9)) }
        }
        if passive {
            var feeds: [ObjectIdentifier: (tank: PropellantTank, flow: Double)] = [:]
            for t in v.thrusters where !t.isSolid && t.isCommanded {
                let flow = t.massFlow, r = t.currentRating.mixtureRatio ?? 0
                switch t.feed {
                case .single(let tank)?: feeds[ObjectIdentifier(tank), default: (tank, 0)].flow += flow
                case let .bipropellant(o, f)?:
                    feeds[ObjectIdentifier(o), default: (o, 0)].flow += flow * r / (1 + r)
                    feeds[ObjectIdentifier(f), default: (f, 0)].flow += flow / (1 + r)
                case nil: break
                }
            }
            for f in feeds.values where f.flow > 0 {
                let r = f.tank.usableMass / f.flow
                if r > 1e-9 { h = min(h, r) }
            }
        }
        return h
    }
}
