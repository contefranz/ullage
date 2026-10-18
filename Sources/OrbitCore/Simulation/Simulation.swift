import Foundation

public struct SimEvent: Identifiable {
    public let id = UUID()
    public let time: Epoch
    public let message: String
}

/// Rigid-body state integrated by RK4.
struct RigidState {
    var r: Vec3, v: Vec3, q: Quat, w: Vec3

    static func + (a: RigidState, b: RigidState) -> RigidState {
        RigidState(r: a.r + b.r, v: a.v + b.v, q: a.q + b.q, w: a.w + b.w)
    }
    static func * (a: RigidState, s: Double) -> RigidState {
        RigidState(r: a.r * s, v: a.v * s, q: a.q * s, w: a.w * s)
    }
}

public final class Simulation {
    public let system: SolarSystem
    public private(set) var time: Epoch
    public var warp: Double = 1
    public var paused = false
    public private(set) var vessels: [Vessel] = []
    public var focus: Vessel?
    public private(set) var events: [SimEvent] = []

    /// Upper bound on integration steps per `advance` call; time warp is
    /// effectively reduced when the bound is hit.
    public var maxSubsteps = 20_000
    /// Wall-clock seconds one `advance` may spend stepping, timed on `clock`;
    /// nil for no bound. Powered flight takes 0.02 s steps, so at high warp
    /// a frame would otherwise run for seconds.
    public var stepBudget: Double?
    /// Monotonic wall clock in seconds, for `stepBudget`.
    public var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// Longest real interval one `advance` makes up for; the rest of a
    /// longer one (a hitch) is dropped.
    public var maxRealInterval = Double.infinity
    /// Set when the last `advance` covered less than `warp` times its real
    /// interval: `maxRealInterval`, `maxSubsteps` or `stepBudget` cut it
    /// short, and the rest is dropped, not carried over.
    public private(set) var warpLimited = false

    /// The day's atmosphere of a body, by NAIF id, in place of its standard
    /// model in this simulation (a launch day's measured air and winds). The
    /// solar system is shared between simulations, so the weather lives here.
    public var atmospheres: [Int: Atmosphere] = [:]

    public init(system: SolarSystem, time: Epoch) {
        self.system = system
        self.time = time
    }

    public func atmosphere(of body: CelestialBody) -> Atmosphere? { atmospheres[body.id] ?? body.atmosphere }

    /// Velocity of a point at `r` moving at `v` relative to the air of `body`
    /// (its rotating atmosphere and the wind), ICRF axes.
    func airVelocity(r: Vec3, v: Vec3, body: CelestialBody, atmosphere: Atmosphere, altitude: Double,
                     snapshot s: SystemSnapshot) -> Vec3 {
        let o = s.orientation(body)
        var air = v - o.angularVelocity.cross(r)
        let w = atmosphere.wind(altitude: altitude)
        if w.east != 0 || w.north != 0 {
            let up = r.normalized, east = o.pole.cross(up).normalized, north = up.cross(east)
            air -= east * w.east + north * w.north
        }
        return air
    }

    public var snapshot: SystemSnapshot { system.snapshot(at: time) }

    public func add(_ v: Vessel) {
        vessels.append(v)
        if focus == nil { focus = v }
    }

    public func remove(_ v: Vessel) {
        vessels.removeAll { $0 === v }
        if focus === v { focus = vessels.first }
    }

    public func log(_ message: String) {
        events.append(SimEvent(time: time, message: message))
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }

    /// Jump to a new epoch without integrating (vessels keep their relative state).
    public func setTime(_ t: Epoch) { time = t }

    // MARK: Time stepping

    /// Advance by `realSeconds` of wall-clock time multiplied by `warp`, or
    /// less when a bound stops it (`warpLimited`). The step that crosses the
    /// budget finishes, so a frame always makes progress.
    public func advance(by realSeconds: Double) {
        warpLimited = false
        guard !paused else { return }
        let real = min(realSeconds, maxRealInterval)
        var remaining = real * warp
        let deadline = stepBudget.map { clock() + $0 }
        var count = 0
        while remaining > 1e-9 {
            for v in vessels { prepareControls(v) }
            let h = min(remaining, maxStep())
            step(h)
            remaining -= h
            count += 1
            if count >= maxSubsteps { break }
            if let deadline, clock() >= deadline { break }
        }
        warpLimited = real < realSeconds || remaining > 1e-9
    }

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

    /// This step's levels and gimbal commands. A flight program sets the
    /// controls first; the allocation needs the engine levels, so the
    /// throttles go next; it is skipped when nothing commands a rotation.
    func prepareControls(_ v: Vessel) {
        guard v.status != .crashed else {
            for t in v.thrusters { t.level = 0 }
            return
        }
        v.flightProgram?.update(v, in: self)
        v.applyThrottles()
        v.groupSwitch = .infinity   // the phase-plane law sets it again if it runs
        var cmd = v.rotationInput
        let control = cmd.isZero && v.autopilot == nil ? ControlAllocation() : v.controlAllocation()
        if cmd.isZero, let ap = v.autopilot {
            cmd = v.autopilotCommand(ap, control: control)
        } else {
            v.resetAttitudeReference()   // manual input: the hold recaptures once released
        }
        v.applyRotation(cmd, control: control)
    }

    /// Advance every vessel by `h` seconds of simulation time.
    public func step(_ h: Double) {
        let t0 = time
        let t1 = time + h
        for v in vessels {
            if v.status == .crashed {
                if let l = v.landed { setLandedKinematics(v, l, snapshot: system.snapshot(at: t1)) }
            } else if v.landed != nil {
                stepLanded(v, from: t0, to: t1)
            } else {
                stepFlying(v, from: t0, h: h)
            }
            // The step used the actuator angles at t0 (held, like the levels);
            // now move them, with this step's commands, to t1.
            if v.status != .crashed { v.advanceControlState(dt: h) }
        }
        time = t1
        let snap = system.snapshot(at: time)
        for v in vessels where v.status != .crashed {
            updateTelemetry(v, snapshot: snap)
            if v.landed == nil {
                checkSurfaceContact(v, snapshot: snap)
                checkReferenceBody(v, snapshot: snap)
            }
        }
    }

    func environment(_ v: Vessel, r: Vec3, snapshot s: SystemSnapshot) -> (alt: Double, atm: AtmosphereState) {
        let alt = r.length - v.reference.radius
        guard let atm = atmosphere(of: v.reference), alt < atm.ceiling else { return (alt, .vacuum) }
        return (alt, atm.state(altitude: alt))
    }

    func stepFlying(_ v: Vessel, from t0: Epoch, h: Double) {
        let mass = v.mass
        let inertia = v.inertia
        let invInertia = inertia.inverse
        let s0 = system.snapshot(at: t0)
        let env0 = environment(v, r: v.position, snapshot: s0)
        let atmosphere = atmosphere(of: v.reference)
        let p0 = atmosphere?.seaLevelPressure ?? 0
        let (thrustBody, torqueBody) = v.thrustForceAndTorque(ambientPressure: env0.atm.pressure, seaLevelPressure: p0)
        let dragArea = v.dragArea
        let ref = v.reference
        // The configuration's aerodynamics, fixed over the step like the thrust.
        let aero = v.activeAerodynamics
        let powered = aero.map(v.basePowered) ?? false
        let cpX = aero.map(v.centerOfPressureX) ?? { _ in 0 }
        let planform = v.planform

        func deriv(_ t: Epoch, _ s: RigidState) -> RigidState {
            let snap = system.snapshot(at: t)
            var a = system.acceleration(relativeTo: ref, at: s.r, snapshot: snap)
            a += s.q.rotate(thrustBody) / mass
            var torque = torqueBody
            if let atm = atmosphere {
                let alt = s.r.length - ref.radius
                if alt < atm.ceiling {
                    let state = atm.state(altitude: alt)
                    let air = airVelocity(r: s.r, v: s.v, body: ref, atmosphere: atm, altitude: alt, snapshot: snap)
                    if let model = aero {
                        let l = model.loads(air: s.q.inverseRotate(air), atmosphere: state, altitude: alt,
                                            powered: powered, centerOfPressureX: cpX, planform: planform)
                        a += s.q.rotate(l.force) / mass
                        torque += l.torque
                    } else {
                        a += air * (-0.5 * state.density * air.length * dragArea / mass)
                    }
                }
            }
            let iw = inertia * s.w
            let dw = invInertia * (torque - s.w.cross(iw))
            return RigidState(r: s.v, v: a, q: s.q.derivative(bodyRate: s.w), w: dw)
        }

        let y = RigidState(r: v.position, v: v.velocity, q: v.attitude, w: v.angularVelocity)
        let k1 = deriv(t0, y)
        let k2 = deriv(t0 + h / 2, y + k1 * (h / 2))
        let k3 = deriv(t0 + h / 2, y + k2 * (h / 2))
        let k4 = deriv(t0 + h, y + k3 * h)
        let y1 = y + (k1 + k2 * 2 + k3 * 2 + k4) * (h / 6)

        v.position = y1.r
        v.velocity = y1.v
        v.attitude = y1.q.normalized
        v.angularVelocity = y1.w
        v.thrustAcceleration = thrustBody.length / mass
        // The step moved the structural point at the old CoM; keep the origin
        // at the CoM, which propellant use has moved within the structure.
        if v.consumePropellant(dt: h) { v.recenter() }
    }

    func stepLanded(_ v: Vessel, from t0: Epoch, to t1: Epoch) {
        guard let l = v.landed else { return }
        let s0 = system.snapshot(at: t0)
        // Lift-off when thrust exceeds weight along the local vertical.
        let env = environment(v, r: v.position, snapshot: s0)
        let p0 = atmosphere(of: v.reference)?.seaLevelPressure ?? 0
        let thrust = v.attitude.rotate(v.thrustForceAndTorque(ambientPressure: env.atm.pressure, seaLevelPressure: p0).force)
        let g = system.acceleration(relativeTo: v.reference, at: v.position, snapshot: s0)
        let up = v.position.normalized
        if (thrust + g * v.mass).dot(up) > 0 {
            v.landed = nil
            v.status = .flying
            log("\(v.name): liftoff")
            stepFlying(v, from: t0, h: t1 - t0)
            return
        }
        // Re-centring moves `landed.bodyFixedPosition` to the new CoM, so use
        // the updated landed state rather than `l`.
        if v.consumePropellant(dt: t1 - t0) { v.recenter() }
        setLandedKinematics(v, v.landed ?? l, snapshot: system.snapshot(at: t1))
    }

    func setLandedKinematics(_ v: Vessel, _ l: LandedState, snapshot s: SystemSnapshot) {
        let o = s.orientation(l.body)
        let bodyToICRF = Quat(matrix: o.icrfToBody.transposed)
        v.reference = l.body
        v.position = o.toInertial(l.bodyFixedPosition)
        v.velocity = o.angularVelocity.cross(v.position)
        v.attitude = (bodyToICRF * l.bodyFixedAttitude).normalized
        v.angularVelocity = v.attitude.inverseRotate(o.angularVelocity)
    }

    func updateTelemetry(_ v: Vessel, snapshot s: SystemSnapshot) {
        let env = environment(v, r: v.position, snapshot: s)
        v.altitude = env.alt
        v.atmosphere = env.atm
        var air = v.surfaceVelocity(snapshot: s)
        if let atm = atmosphere(of: v.reference), env.atm.density > 0 {
            air = airVelocity(r: v.position, v: v.velocity, body: v.reference, atmosphere: atm, altitude: env.alt,
                              snapshot: s)
        }
        v.airspeed = air.length
        v.dynamicPressure = 0.5 * env.atm.density * v.airspeed * v.airspeed
        v.mach = env.atm.speedOfSound > 0 && env.atm.density > 0 ? v.airspeed / env.atm.speedOfSound : 0
        v.angleOfAttack = v.airspeed > 1e-6 ? angleBetween(v.attitude.rotate(.unitX), air) : 0
    }

    func checkSurfaceContact(_ v: Vessel, snapshot s: SystemSnapshot) {
        let clearance = min(v.baseHeight, v.boundingRadius)
        guard v.altitude < clearance * 0.9 else { return }
        let speed = v.surfaceVelocity(snapshot: s).length
        let o = s.orientation(v.reference)
        let up = v.position.normalized
        // Put the vessel back on the surface.
        let surfacePos = up * (v.reference.radius + clearance)
        let bf = o.toBody(surfacePos)
        let icrfToBodyQ = Quat(matrix: o.icrfToBody)
        let landed = LandedState(body: v.reference, bodyFixedPosition: bf,
                                 bodyFixedAttitude: (icrfToBodyQ * v.attitude).normalized)
        v.landed = landed
        if speed < 5 {
            v.status = .landed
            log(String(format: "%@: touchdown at %.1f m/s", v.name, speed))
        } else {
            v.status = .crashed
            for t in v.thrusters { t.level = 0 }
            log(String(format: "%@: impact at %.0f m/s", v.name, speed))
        }
        setLandedKinematics(v, landed, snapshot: s)
    }

    func checkReferenceBody(_ v: Vessel, snapshot s: SystemSnapshot) {
        let bary = s.position(v.reference) + v.position
        let best = system.dominantBody(forBarycentric: bary, snapshot: s)
        guard best !== v.reference else { return }
        let baryVel = s.velocity(v.reference) + v.velocity
        v.position = bary - s.position(best)
        v.velocity = baryVel - s.velocity(best)
        log("\(v.name): entered \(best.name) sphere of influence")
        v.reference = best
    }

    // MARK: Staging

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

    // MARK: Placement helpers

    /// Stand `v` upright on the surface at `lat`/`lon` (degrees). The vessel's
    /// -z axis (its "up" for the crew) faces `azimuth` degrees from north.
    public func placeLanded(_ v: Vessel, on body: CelestialBody, latitude: Double, longitude: Double,
                            azimuth: Double = 90, elevation: Double = 0) {
        let deg = Double.pi / 180
        let lat = latitude * deg, lon = longitude * deg, az = azimuth * deg
        let up = Vec3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
        let east = Vec3(-sin(lon), cos(lon), 0)
        let north = up.cross(east)
        let dir = north * cos(az) + east * sin(az)
        let x = up, z = -dir, y = z.cross(x)
        let att = Quat(matrix: Mat3(columns: x, y, z))
        let l = LandedState(body: body, bodyFixedPosition: up * (body.radius + elevation + v.baseHeight),
                            bodyFixedAttitude: att)
        v.landed = l
        v.status = .landed
        v.reference = body
        setLandedKinematics(v, l, snapshot: snapshot)
        updateTelemetry(v, snapshot: snapshot)
    }

    /// Put `v` on a circular orbit, facing prograde with its +z axis towards the body.
    public func placeInCircularOrbit(_ v: Vessel, around body: CelestialBody, altitude: Double,
                                     inclination: Double = 0, ascendingNode: Double = 0, argumentOfLatitude: Double = 0) {
        let deg = Double.pi / 180
        let snap = snapshot
        let pole = snap.orientation(body).pole
        var xRef = Vec3.unitZ.cross(pole)
        xRef = xRef.length < 1e-9 ? .unitX : xRef.normalized
        let yRef = pole.cross(xRef)
        let r = body.radius + altitude
        let speed = (body.gm / r).squareRoot()
        // Perifocal -> equatorial: Rz(Ω) Rx(i) Rz(u)
        let m = Mat3.rotZ(ascendingNode * deg) * Mat3.rotX(inclination * deg) * Mat3.rotZ(argumentOfLatitude * deg)
        let pLocal = m * Vec3(r, 0, 0)
        let vLocal = m * Vec3(0, speed, 0)
        let toICRF = Mat3(columns: xRef, yRef, pole)
        v.reference = body
        v.landed = nil
        v.status = .flying
        v.position = toICRF * pLocal
        v.velocity = toICRF * vLocal
        let x = v.velocity.normalized, z = -v.position.normalized, y = z.cross(x)
        v.attitude = Quat(matrix: Mat3(columns: x, y, z))
        v.angularVelocity = .zero
        updateTelemetry(v, snapshot: snap)
    }
}
