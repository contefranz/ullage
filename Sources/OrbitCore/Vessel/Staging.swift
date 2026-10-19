import Foundation

extension Vessel {
    /// Detach `detached` parts as a new vessel. Both vessels are re-centred on
    /// their own centre of mass. Returns the new vessel, or nil if nothing matched.
    @discardableResult
    public func separate(parts detached: [VesselPart], name: String, separationSpeed: Double = 0) -> Vessel? {
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
                                       bodyFixedAttitude: l.bodyFixedAttitude)
        }
        recenter()

        if separationSpeed > 0, oldLanded == nil {
            let dir = (other.position - position).normalized
            let mTotal = mass + other.mass
            velocity -= dir * (separationSpeed * other.mass / mTotal)
            other.velocity += dir * (separationSpeed * mass / mTotal)
        }
        return other
    }

    /// Separate the lowest `.bottomOfStack` part (the bottom stage of an M0 stack).
    @discardableResult
    public func jettisonBottomPart() -> Vessel? {
        guard parts.count > 1,
              let bottom = parts.filter({ $0.staging == .bottomOfStack }).min(by: { $0.offset.x < $1.offset.x })
        else { return nil }
        return separate(parts: [bottom], name: "\(name) – \(bottom.name)", separationSpeed: 1.0)
    }

    /// The Space key: separate every part of the lowest pending `.event(n)` as
    /// one new vessel; with no events left, fall back to `jettisonBottomPart`.
    /// `.fixed` parts never separate, and a vessel made only of one event's
    /// parts (spent debris) does not split again.
    @discardableResult
    public func jettisonNextStage() -> Vessel? {
        let pending = parts.compactMap { p -> Int? in if case .event(let n) = p.staging { return n } else { return nil } }
        guard let next = pending.min() else { return jettisonBottomPart() }
        return jettison(event: next)
    }

    /// Separate every part of staging event `n` as one new vessel, whatever
    /// events are still pending below it (a flight program staging by
    /// identity); nil if no part carries it or nothing would remain. The
    /// separation lights the solids it triggers (`Thruster.trigger`) first:
    /// the leaving parts' retros burn on with them, and the ullage motors of
    /// the stack that stays burn on with it. Springs add the parts'
    /// `separationSpeed`.
    @discardableResult
    public func jettison(event n: Int) -> Vessel? {
        let group = parts.filter { $0.staging == .event(n) }
        guard let lowest = group.min(by: { $0.offset.x < $1.offset.x }), group.count < parts.count else { return nil }
        for p in parts {
            let leaving = p.staging == .event(n)
            for t in p.thrusters {
                switch t.trigger {
                case .ownSeparation?: if leaving { t.ignite() }
                case .event(let e)?: if e == n && !leaving { t.ignite() }
                case nil: break
                }
            }
        }
        return separate(parts: group, name: "\(name) – \(lowest.name)",
                        separationSpeed: group.map(\.separationSpeed).max() ?? 0)
    }

    /// Lowest part with main engines, enabled or not: the stage the main
    /// throttle drives.
    public var activeStage: VesselPart? {
        parts.filter { $0.thrusters.contains { $0.groups.contains(.main) } }.min { $0.offset.x < $1.offset.x }
    }
}
