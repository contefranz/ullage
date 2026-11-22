import Foundation

/// The burn of an External ΔV load as P40 (the SPS) and P41 (the RCS) fly
/// it (docs/m2/design-flight-controls.md §1, §3 and §7):
/// - Average-G from TIG−30 s: the Δv the accelerometers sense (thrust over
///   mass, along the engines' thrust), so the ullage counts;
/// - the velocity to be gained, VG ← VG − sensed Δv, from the load's Δv
///   (inertial): with nothing off it stays along the load, an inertial hold;
/// - the attitude that puts the thrust along VG (the SPS's through the
///   centre of mass, the RCS's +X along it), rolled heads up or down as at
///   TIG, which the computer's command approaches at 0.5°/s and stops
///   following in the last `freezeTime` of the burn;
/// - the SPS cutoff when VG along the thrust is down to what the engine's
///   tail-off will still give, predicted to the step.
public final class ExternalDeltaVSteering {
    public let plan: ManeuverPlan
    /// Velocity to be gained, ICRF, m/s.
    public private(set) var velocityToBeGained: Vec3
    /// The accelerometers' count, from TIG−30 s.
    public private(set) var averageG = AverageG()
    /// The attitude the burn flies, as last steered (body -> ICRF).
    public private(set) var burnAttitude: Quat?
    /// The steering stopped following VG (the last seconds of the burn).
    public private(set) var frozen = false
    /// Down at TIG (ICRF): the roll reference of the burn attitude.
    let downAtIgnition: Vec3

    /// Average-G starts this long before TIG, s.
    public static let averageGLead = 30.0
    /// The steering is frozen when the burn has less than this to go, s
    /// (Colossus's threshold [verify] in D8).
    public static let freezeTime = 4.0

    /// The load's burn from `state` (ICRF, about a body of `mu`) at `now`:
    /// VG is the load's Δv, and down at TIG comes from a conic coast there.
    public init(plan: ManeuverPlan, state: Kepler.State, mu: Double, at now: Epoch) {
        self.plan = plan
        velocityToBeGained = plan.deltaV
        downAtIgnition = -Kepler.propagate(state, mu: mu, by: plan.ignition - now).position.normalized
    }

    // MARK: Average-G

    func startAverageG(at now: Epoch) { averageG.begin(at: now) }

    /// VG less the Δv sensed over the step that has just ended at `now`.
    func sense(_ v: Vessel, in sim: Simulation, now: Epoch) {
        velocityToBeGained -= averageG.sense(v, in: sim, now: now)
    }

    // MARK: Attitude

    /// The attitude (body -> ICRF) that points the burn's engine along `d`:
    /// the SPS's thrust through `v`'s centre of mass, or the vessel's +X for
    /// the RCS; rolled so that the crew's heads (body +z, −Z_A) are towards
    /// the Earth at TIG (heads down) or away from it (heads up).
    func attitude(_ v: Vessel, along d: Vec3) -> Quat {
        let down = plan.headsUp ? -downAtIgnition : downAtIgnition
        switch plan.engine {
        case .sps: return ApolloCSM.burnAttitude(v, along: d, down: down)
        case .rcs: return ApolloCSM.alignedAttitude(along: d, down: down)
        }
    }

    /// The burn attitude now: along VG, unless frozen.
    func steer(_ v: Vessel) -> Quat {
        if frozen, let q = burnAttitude { return q }
        let d = velocityToBeGained.length > 1e-6 ? velocityToBeGained : plan.deltaV
        let q = attitude(v, along: d)
        burnAttitude = q
        return q
    }

    /// Stop following VG.
    func freeze() { frozen = true }

    // MARK: Cutoff

    /// What the engine's tail-off still gives after a cutoff signal now, m/s:
    /// its thrust falling linearly to nothing over its shutdown time.
    static func tailOff(_ v: Vessel, thrust: Double) -> Double {
        let sps = v.thrusters.first { $0.name == "SPS" }
        return thrust / max(v.mass, 1e-9) * (sps?.transients?.shutdown ?? 0) / 2
    }

    /// Seconds from now to the cutoff signal: when VG along the thrust has
    /// come down to the tail-off, at the thrust now; nil without thrust.
    func timeToCutoff(_ v: Vessel, in sim: Simulation) -> Double? {
        let p0 = sim.atmosphere(of: v.reference)?.seaLevelPressure ?? 0
        let f = v.thrustForceAndTorque(ambientPressure: v.atmosphere.pressure, seaLevelPressure: p0).force
        let thrust = f.length
        guard thrust > 0 else { return nil }
        let u = v.attitude.rotate(f / thrust), a = thrust / max(v.mass, 1e-9)
        return (velocityToBeGained.dot(u) - Self.tailOff(v, thrust: thrust)) / a
    }
}

extension ApolloCSM {
    /// The attitude (body -> ICRF) whose +x is along `direction` and whose
    /// +z (the crew's heads in Apollo axes, −Z_A) is towards `down` as far as
    /// it can be.
    static func alignedAttitude(along direction: Vec3, down: Vec3) -> Quat {
        let d = direction.normalized
        var z = down - d * down.dot(d)
        if z.length < 1e-9 { z = d.cross(abs(d.x) < 0.9 ? Vec3.unitX : Vec3.unitY) }
        z = z.normalized
        return Quat(matrix: Mat3(columns: d, z.cross(d), z))
    }
}
