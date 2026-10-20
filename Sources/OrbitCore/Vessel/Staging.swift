import Foundation

extension Vessel {
    /// Detach `detached` parts as a new vessel. Both vessels are re-centred on
    /// their own centre of mass. Springs push them apart: `separationVelocity`
    /// (the new vessel's velocity relative to this one, vessel axes) if
    /// given, otherwise `separationSpeed` along the line between the two
    /// centres of mass, shared by momentum; `separationRate` adds to the new
    /// vessel's body rate (its reaction on this one is not modelled). The
    /// flight program goes with its host part, and each vessel flies in its
    /// crew's frame (`handOver`). Returns the new vessel, or nil if nothing
    /// matched.
    @discardableResult
    public func separate(parts detached: [VesselPart], name: String, separationSpeed: Double = 0,
                         separationVelocity: Vec3? = nil, separationRate: Vec3? = nil) -> Vessel? {
        let ids = Set(detached.map { ObjectIdentifier($0) })
        let leaving = parts.filter { ids.contains(ObjectIdentifier($0)) }
        guard !leaving.isEmpty, leaving.count < parts.count else { return nil }
        let leavingMass = leaving.reduce(0) { $0 + $1.mass }
        let leavingCom = leaving.reduce(Vec3.zero) { $0 + ($1.offset + $1.centerOfMass) * $1.mass }
            / max(leavingMass, 1e-9)
        let oldLanded = landed

        parts.removeAll { ids.contains(ObjectIdentifier($0)) }
        for t in leaving.flatMap(\.thrusters) { t.level = 0 }

        // The initialiser re-centres the new vessel on its own centre of mass.
        let other = Vessel(name: name, parts: leaving, reference: reference, position: position,
                           velocity: velocity, attitude: attitude, angularVelocity: angularVelocity)
        other.status = status
        // Its offsets were in this vessel's frame, so it shares this construction origin.
        other.structureOrigin += structureOrigin
        other.aerodynamics = aerodynamics
        if let l = oldLanded {
            other.landed = LandedState(body: l.body,
                                       bodyFixedPosition: l.bodyFixedPosition + l.bodyFixedAttitude.rotate(leavingCom),
                                       bodyFixedAttitude: l.bodyFixedAttitude, surface: l.surface)
        }
        recenter()

        if oldLanded == nil {
            let mTotal = mass + other.mass
            if let dv = separationVelocity {
                let relative = attitude.rotate(dv)
                velocity -= relative * (other.mass / mTotal)
                other.velocity += relative * (mass / mTotal)
            } else if separationSpeed > 0 {
                let dir = (other.position - position).normalized
                velocity -= dir * (separationSpeed * other.mass / mTotal)
                other.velocity += dir * (separationSpeed * mass / mTotal)
            }
            if let w = separationRate { other.angularVelocity += w }
        }
        handOver(to: other, leaving: leaving)
        return other
    }

    /// After `other` has left with `leaving`: the flight program and the
    /// control state it flies with go with the program's host part (the
    /// IU's leave with the S-IVB), and this vessel starts afresh: no
    /// autopilot, the throttles at zero, M0's laws, and the first standby
    /// program of its parts (the CM's SCS). The new vessel, if it has no
    /// program, takes its parts' standby one too. Each flies in the frame
    /// of the crewed part it carries.
    func handOver(to other: Vessel, leaving: [VesselPart]) {
        func standby(_ w: Vessel) -> FlightProgram? { w.parts.lazy.compactMap(\.standbyProgram).first }
        if let host = flightProgram?.hostPart, leaving.contains(where: { $0.name == host }) {
            other.takeControls(from: self)
            resetControls()
            flightProgram = standby(self)
        }
        if other.flightProgram == nil { other.flightProgram = standby(other) }
        if let crew = parts.first(where: \.isCrewed) {
            controlFrame = crew.crewFrame
        } else if leaving.contains(where: \.isCrewed) {
            controlFrame = .identity
        }
        if let crew = other.parts.first(where: \.isCrewed) { other.controlFrame = crew.crewFrame }
    }

    /// Take `source`'s program and every control it flies with: throttles,
    /// inputs, autopilot mode, attitude command, laws, and the hold's and the
    /// laws' state. The two share their attitude at a separation, so the
    /// held and reference attitudes carry over as they are.
    func takeControls(from source: Vessel) {
        flightProgram = source.flightProgram
        mainThrottle = source.mainThrottle
        retroThrottle = source.retroThrottle
        rotationInput = source.rotationInput
        translationInput = source.translationInput
        autopilot = source.autopilot
        attitudeCommand = source.attitudeCommand
        tvcGains = source.tvcGains
        fccGains = source.fccGains
        phasePlane = source.phasePlane
        heldAttitude = source.heldAttitude
        referenceAttitude = source.referenceAttitude
        referenceRate = source.referenceRate
        fccFilter = source.fccFilter
        groupPulse = source.groupPulse
        groupSwitch = source.groupSwitch
    }

    /// No program, no autopilot, nothing commanded, M0's laws.
    func resetControls() {
        flightProgram = nil
        mainThrottle = 0
        retroThrottle = 0
        rotationInput = RotationCommand()
        translationInput = .zero
        autopilot = nil
        attitudeCommand = nil
        tvcGains = TVCGains()
        fccGains = nil
        phasePlane = nil
        resetAttitudeReference()
        groupPulse = (.zero, .zero)
        groupSwitch = .infinity
    }

    /// Separate the lowest `.bottomOfStack` part (the bottom stage of an M0 stack).
    @discardableResult
    public func jettisonBottomPart() -> Vessel? {
        guard parts.count > 1,
              let bottom = parts.filter({ $0.staging == .bottomOfStack }).min(by: { $0.offset.x < $1.offset.x })
        else { return nil }
        return separate(parts: [bottom], name: "\(name) – \(bottom.name)", separationSpeed: 1.0)
    }

    /// The lowest staging event still aboard (`StagingRule.event`), if any.
    public var nextStagingEvent: Int? {
        parts.compactMap { p -> Int? in if case .event(let n) = p.staging { return n } else { return nil } }.min()
    }

    /// The Space key: separate the lowest pending `.event(n)`
    /// (`jettison(event:)`); with no events left, fall back to
    /// `jettisonBottomPart`. `.fixed` parts never separate, and a vessel made
    /// only of one event's parts (spent debris) does not split again.
    /// Returns the main vessel made (`jettisonAll(event:)`).
    @discardableResult
    public func jettisonNextStage() -> Vessel? { jettisonNextStageAll().first }

    /// `jettisonNextStage`, returning every vessel it makes, the main one first.
    @discardableResult
    public func jettisonNextStageAll() -> [Vessel] {
        guard let next = nextStagingEvent else { return jettisonBottomPart().map { [$0] } ?? [] }
        return jettisonAll(event: next)
    }

    /// Separate staging event `n` (`jettisonAll(event:)`) and return the main
    /// vessel it makes; nil if no part carries it or nothing would remain.
    @discardableResult
    public func jettison(event n: Int) -> Vessel? { jettisonAll(event: n).first }

    /// Separate every part of staging event `n`, whatever events are still
    /// pending below it (a flight program staging by identity), and return
    /// the vessels made: the event's ungrouped parts as one, the main
    /// vessel, first, then one per `separationGroup` (the SLA panels), which
    /// leave before it on their own `separationVelocity` and
    /// `separationRate`; empty if no part carries the event or nothing
    /// would remain. The crew keeps the vessel: should the event carry the
    /// crewed part, the parts without the event leave instead. The
    /// separation first acts on the thrusters it triggers
    /// (`Thruster.trigger`): `.ownSeparation` on the event's parts,
    /// `.event(n)` on the others. Solids light (the leaving parts' retros
    /// burn on with them, the ullage motors of the stack that stays with
    /// it), and liquid engines start their sequence (the SM jettison
    /// controller) or, without one, are armed (the CM RCS). Springs add the
    /// parts' `separationSpeed`. Parts centred until this event
    /// (`VesselPart.centeredUntilEvent`) take their own mass distribution.
    @discardableResult
    public func jettisonAll(event n: Int) -> [Vessel] {
        let event = parts.filter { $0.staging == .event(n) }
        guard !event.isEmpty, event.count < parts.count else { return [] }
        // Parts centred until this event take their own mass distribution
        // now; each vessel re-centres as it separates.
        for p in parts where (p.centeredUntilEvent ?? .max) <= n { p.centeredUntilEvent = nil }
        for p in parts {
            let inEvent = p.staging == .event(n)
            for t in p.thrusters {
                let triggered: Bool
                switch t.trigger {
                case .ownSeparation?: triggered = inEvent
                case .event(let e)?: triggered = e == n && !inEvent
                case nil: triggered = false
                }
                guard triggered else { continue }
                if t.isSolid { t.ignite() } else if t.sequence != nil { t.startSequence() } else { t.isEnabled = true }
            }
        }
        let crewLeaves = event.contains(where: \.isCrewed) && !parts.contains { $0.isCrewed && $0.staging != .event(n) }
        let leaving = crewLeaves ? parts.filter { $0.staging != .event(n) } : event
        func lowest(_ ps: [VesselPart]) -> VesselPart? { ps.min { $0.offset.x < $1.offset.x } }

        var groups: [String] = []
        for p in leaving { if let g = p.separationGroup, !groups.contains(g) { groups.append(g) } }
        var made: [Vessel] = []
        for g in groups {
            let members = leaving.filter { $0.separationGroup == g }
            guard let first = lowest(members),
                  let w = separate(parts: members, name: "\(name) – \(first.name)",
                                   separationSpeed: members.map(\.separationSpeed).max() ?? 0,
                                   separationVelocity: members.lazy.compactMap(\.separationVelocity).first,
                                   separationRate: members.lazy.compactMap(\.separationRate).first)
            else { continue }
            made.append(w)
        }
        let rest = leaving.filter { $0.separationGroup == nil }
        if let first = lowest(rest),
           let w = separate(parts: rest, name: "\(name) – \(first.name)",
                            separationSpeed: rest.map(\.separationSpeed).max() ?? 0) {
            made.insert(w, at: 0)
        }
        return made
    }

    /// Lowest part with main engines, enabled or not: the stage the main
    /// throttle drives.
    public var activeStage: VesselPart? {
        parts.filter { $0.thrusters.contains { $0.groups.contains(.main) } }.min { $0.offset.x < $1.offset.x }
    }
}
