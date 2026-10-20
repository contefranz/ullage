import Foundation

/// An impulsive retrograde deorbit burn: when to light it, how much Δv brings
/// the perigee down to a target or the entry interface (EI) to a target
/// flight-path angle, how long the engine runs for it, and the orbit after.
///
/// The burn is along the anti-velocity, so it keeps the flight-path angle
/// and the orbit plane. The coast to the ignition time (TIG) and on to EI
/// is in vacuum with J2 (`VacuumCoast`); apsides are the osculating
/// conic's, at the start.
public enum DeorbitPlanner {
    /// The time of ignition.
    public enum Ignition: Equatable {
        case now
        /// The osculating conic's next apoapsis, or periapsis.
        case apoapsis, periapsis
        case at(Epoch)
    }

    public enum Target: Equatable {
        /// The post-burn conic's periapsis radius (m).
        case perigeeRadius(Double)
        /// The inertial flight-path angle at EI (rad, negative).
        case entryFlightPathAngle(Double)
    }

    /// The engine that flies the burn.
    public struct Engine: Equatable {
        /// N.
        public var thrust: Double
        /// s.
        public var specificImpulse: Double

        public init(thrust: Double, specificImpulse: Double) {
            self.thrust = thrust
            self.specificImpulse = specificImpulse
        }

        /// The thruster's vacuum rating.
        public init(_ t: Thruster) { self.init(thrust: t.maxThrustVacuum, specificImpulse: t.ispVacuum) }

        public var exhaustVelocity: Double { specificImpulse * standardGravity }
    }

    public struct Plan {
        /// The impulsive TIG.
        public let ignition: Epoch
        /// The state at TIG before and after the burn (ICRF, relative to the body).
        public let preBurn: Kepler.State
        public let postBurn: Kepler.State
        /// The burn (ICRF, m/s).
        public let deltaV: Vec3
        /// The burn in Apollo's P30 local vertical axes at TIG (m/s): X along
        /// the horizontal velocity, Y opposite the orbit normal, Z down.
        public let deltaVLocal: Vec3
        /// The osculating orbit after the burn, about the body's pole.
        public let postBurnElements: OrbitalElements
        /// The EI the burn leads to, if any.
        public let entry: EntryInterface?
        /// The engine's burn time and propellant (s, kg), when the engine and
        /// the mass are given.
        public let burnTime: Double?
        public let propellantMass: Double?

        public var deltaVMagnitude: Double { deltaV.length }
        /// The ICRF thrust direction, for an attitude marker.
        public var burnDirection: Vec3 { deltaV.normalized }
        /// Ignition for a burn of `burnTime` centred on the impulsive TIG, the
        /// first-order correction for a finite burn.
        public var centredIgnition: Epoch? { burnTime.map { ignition + -$0 / 2 } }
    }

    /// The plan from `state` (ICRF, relative to `body`, oriented as
    /// `orientation` at `epoch`), or nil if the ignition time is not on the
    /// orbit (an apsis of an escape orbit that has passed) or the target cannot
    /// be reached by a retrograde burn. `mass` (kg) and `engine` give the burn
    /// time.
    public static func plan(from state: Kepler.State, around body: CelestialBody, orientation: BodyOrientation,
                            at epoch: Epoch, ignition: Ignition = .now, target: Target, mass: Double? = nil,
                            engine: Engine? = nil, entryHeight: Double = EntryInterface.standardHeight,
                            j2: Bool = true) -> Plan? {
        let mu = body.gm, pole = orientation.pole
        let el = OrbitalElements(position: state.position, velocity: state.velocity, mu: mu, pole: pole)
        let wait: Double
        switch ignition {
        case .now: wait = 0
        case .apoapsis:
            guard el.isBound, el.eccentricity > 1e-10 else { return nil }
            wait = el.timeToApoapsis
        case .periapsis:
            guard el.eccentricity > 1e-10, el.isBound || el.timeToPeriapsis >= 0 else { return nil }
            wait = el.timeToPeriapsis
        case .at(let t):
            guard t >= epoch else { return nil }
            wait = t - epoch
        }
        let coast = VacuumCoast(body: body, pole: pole, j2: j2)
        let pre = coast.propagate(state, by: wait)
        let tig = epoch + wait
        // The body has turned rigidly about its pole by TIG.
        let turned = BodyOrientation(icrfToBody: Mat3.frameZ(orientation.angularVelocity.dot(pole) * wait)
                                         * orientation.icrfToBody,
                                     angularVelocity: orientation.angularVelocity)
        func entry(_ dv: Double) -> EntryInterface? {
            EntryInterface.predict(from: burned(pre, dv), around: body, orientation: turned, at: tig,
                                   height: entryHeight, j2: j2)
        }

        let dv: Double
        switch target {
        case .perigeeRadius(let rp):
            guard let d = retrogradeDeltaV(toPerigeeRadius: rp, state: pre, mu: mu) else { return nil }
            dv = d
        case .entryFlightPathAngle(let gamma):
            guard gamma < 0 else { return nil }
            // γ at EI steepens as the burn grows; no EI counts as grazing (γ = 0).
            func miss(_ d: Double) -> Double { (entry(d)?.inertialFlightPathAngle ?? 0) - gamma }
            let speed = pre.velocity.length
            var a = 0.0, fa = miss(0)
            guard fa > 0 else { return nil }
            var b = 0.25 * speed, fb = miss(b)
            while fb > 0 {
                guard b < 0.99 * speed else { return nil }
                a = b; fa = fb
                b = min(2 * b, 0.99 * speed)
                fb = miss(b)
            }
            var side = 0
            for _ in 0..<100 {
                let c = (a * fb - b * fa) / (fb - fa)
                let fc = miss(c)
                if abs(fc) < 1e-10 || b - a < 1e-7 { a = c; b = c; break }
                if fc > 0 {
                    a = c; fa = fc
                    if side == 1 { fb /= 2 }
                    side = 1
                } else {
                    b = c; fb = fc
                    if side == -1 { fa /= 2 }
                    side = -1
                }
            }
            dv = (a + b) / 2
        }

        let post = burned(pre, dv)
        var time: Double?, propellant: Double?
        if let mass, let engine {
            time = burnTime(deltaV: abs(dv), mass: mass, thrust: engine.thrust,
                            specificImpulse: engine.specificImpulse)
            propellant = propellantMass(deltaV: abs(dv), mass: mass, specificImpulse: engine.specificImpulse)
        }
        let deltaV = post.velocity - pre.velocity
        return Plan(ignition: tig, preBurn: pre, postBurn: post, deltaV: deltaV,
                    deltaVLocal: localVerticalFrame(pre) * deltaV,
                    postBurnElements: OrbitalElements(position: post.position, velocity: post.velocity, mu: mu,
                                                      pole: pole),
                    entry: entry(dv), burnTime: time, propellantMass: propellant)
    }

    /// The plan for vessel `v` from `snapshot`'s time, with its mass.
    public static func plan(_ v: Vessel, snapshot: SystemSnapshot, ignition: Ignition = .now, target: Target,
                            engine: Engine? = nil) -> Plan? {
        plan(from: Kepler.State(position: v.position, velocity: v.velocity), around: v.reference,
             orientation: snapshot.orientation(v.reference), at: snapshot.time, ignition: ignition, target: target,
             mass: v.mass, engine: engine)
    }

    /// `s` after a burn of `dv` along the anti-velocity (m/s; negative along
    /// the velocity).
    static func burned(_ s: Kepler.State, _ dv: Double) -> Kepler.State {
        Kepler.State(position: s.position, velocity: s.velocity - s.velocity.normalized * dv)
    }

    /// The Δv along the anti-velocity that puts the periapsis at `rp` (m/s;
    /// negative means a burn along the velocity). Keeping the radius r and
    /// flight-path angle γ, the conic with an apsis at rp has speed v' with
    /// v'² = 2μ (1/r - 1/rp) / (1 - (r cos γ / rp)²), from its energy and
    /// angular momentum; rp is its periapsis when rp < r. Nil if rp is not
    /// below r cos γ, which no conic through this point and direction can
    /// have as its periapsis.
    public static func retrogradeDeltaV(toPerigeeRadius rp: Double, state s: Kepler.State, mu: Double) -> Double? {
        let r = s.position.length, v = s.velocity.length
        let rCosGamma = s.position.cross(s.velocity).length / v
        guard rp > 0, rp < rCosGamma * (1 - 1e-12) else { return nil }
        let k = rCosGamma / rp
        let v2 = 2 * mu * (1 / r - 1 / rp) / (1 - k * k)
        return v - v2.squareRoot()
    }

    /// The Hohmann transfer between circular orbits of radii `r1` and `r2`
    /// (m): the two burns' magnitudes (m/s) and the half-ellipse's flight
    /// time (s).
    public static func hohmann(from r1: Double, to r2: Double, mu: Double) -> (first: Double, second: Double,
                                                                              transferTime: Double) {
        let a = (r1 + r2) / 2
        let first = abs((mu * (2 / r1 - 1 / a)).squareRoot() - (mu / r1).squareRoot())
        let second = abs((mu / r2).squareRoot() - (mu * (2 / r2 - 1 / a)).squareRoot())
        return (first, second, Double.pi * (a * a * a / mu).squareRoot())
    }

    /// The propellant a burn of `deltaV` (m/s) uses from `mass` (kg), by the
    /// rocket equation: m0 (1 - exp(-Δv / ve)).
    public static func propellantMass(deltaV: Double, mass: Double, specificImpulse: Double) -> Double {
        mass * -expm1(-deltaV / (specificImpulse * standardGravity))
    }

    /// The time an engine of `thrust` (N) and `specificImpulse` (s) burns to
    /// give `deltaV` (m/s) from `mass` (kg) at a constant flow:
    /// m0 ve / F (1 - exp(-Δv / ve)).
    public static func burnTime(deltaV: Double, mass: Double, thrust: Double, specificImpulse: Double) -> Double {
        let ve = specificImpulse * standardGravity
        return propellantMass(deltaV: deltaV, mass: mass, specificImpulse: specificImpulse) * ve / thrust
    }

    /// Apollo's P30 local vertical frame at `s`, as rows in ICRF: X along
    /// the horizontal velocity, Y opposite the orbit normal, Z down. The
    /// matrix takes ICRF vectors to it.
    public static func localVerticalFrame(_ s: Kepler.State) -> Mat3 {
        let z = -s.position.normalized
        let x = (s.velocity + z * -s.velocity.dot(z)).normalized
        return Mat3(rows: x, z.cross(x), z)
    }
}
