import Foundation

/// A vessel resting on a body's surface, fixed in that body's rotating frame.
public struct LandedState {
    public var body: CelestialBody
    /// Position of the vessel origin in the body-fixed frame, m.
    public var bodyFixedPosition: Vec3
    /// Vessel attitude relative to the body-fixed frame (vessel -> body-fixed).
    public var bodyFixedAttitude: Quat
}

public enum VesselStatus: Equatable {
    case flying, landed, crashed
}

/// Largest speed over the surface (m/s) at which a vessel comes to rest on
/// contact; faster, it crashes.
public struct ImpactLimits: Equatable {
    public var water: Double
    public var land: Double
    public init(water: Double, land: Double) {
        self.water = water; self.land = land
    }
    /// 5 m/s on any surface.
    public static let standard = ImpactLimits(water: 5, land: 5)
}

/// Rotational command per axis, -1...1. x = roll (right +), y = pitch (up +), z = yaw (right +).
public struct RotationCommand: Equatable {
    public var roll = 0.0, pitch = 0.0, yaw = 0.0
    public init(roll: Double = 0, pitch: Double = 0, yaw: Double = 0) {
        self.roll = roll; self.pitch = pitch; self.yaw = yaw
    }
    public var isZero: Bool { roll == 0 && pitch == 0 && yaw == 0 }
}

public final class Vessel: Identifiable {
    public let id = UUID()
    public var name: String
    public internal(set) var parts: [VesselPart]

    // MARK: State (inertial, relative to the reference body's centre, ICRF axes)
    public internal(set) var reference: CelestialBody
    public var position: Vec3
    public var velocity: Vec3
    /// Body -> ICRF.
    public var attitude: Quat
    /// Body-frame angular velocity, rad/s.
    public var angularVelocity: Vec3
    public internal(set) var landed: LandedState?
    public internal(set) var status: VesselStatus = .flying
    /// Where the origin of the frame the vessel was built in (its construction
    /// frame, e.g. Saturn V stations) now sits in the vessel frame. The vessel
    /// frame is re-centred on the CoM as propellant is used; construction
    /// coordinates of a part are `part.offset - structureOrigin`.
    public internal(set) var structureOrigin = Vec3.zero

    // MARK: Controls
    /// Main engine throttle 0...1.
    public var mainThrottle = 0.0
    /// Hover/retro levels 0...1.
    public var retroThrottle = 0.0
    /// Manual rotation input (RCS and gimbals).
    public var rotationInput = RotationCommand()
    /// Manual translation input, body axes, -1...1.
    public var translationInput = Vec3.zero
    /// Pilot axes -> body axes: the frame of the pilot's commands
    /// (`setPilotInput`). The identity flies in body axes.
    public var controlFrame = Quat.identity
    public var autopilot: AttitudeAutopilot? {
        didSet { if autopilot != oldValue { resetAttitudeReference() } }
    }
    /// What `.attitudeHold` steers to; nil holds the attitude captured when
    /// the mode was selected or manual input last moved the vessel (see
    /// `AttitudeAutopilot.attitudeHold`).
    public var attitudeCommand: AttitudeCommand?
    /// Gains of the attitude law on axes the gimbals fly.
    public var tvcGains = TVCGains()
    /// The Saturn flight control computer's law (see `FCCGains`): when set,
    /// it flies the gimbal axes in `.attitudeHold` with an `attitudeCommand`,
    /// in place of the `tvcGains` law. The IU sets it per flight phase.
    public var fccGains: FCCGains?
    /// On/off law of the rotation groups (the Saturn's APS): every axis in
    /// the hold, pitch and yaw in the pointing modes (roll keeps M0's rate
    /// damping there); nil uses M0's law. Kill rotation always uses M0's.
    public var phasePlane: PhasePlaneLaw?
    /// Program aboard (the Saturn's IU), which sequences the flight and
    /// writes `attitudeCommand`; nil when the vessel carries none.
    public var flightProgram: FlightProgram?
    /// What the entry autopilot holds about the air-relative velocity; nil
    /// when nothing is commanded. Nothing flies it yet.
    public var entryCommand: EntryCommand?
    /// Contact speeds the vessel survives.
    public var impactLimits = ImpactLimits.standard
    /// Attitude `.attitudeHold` captured (body -> ICRF).
    var heldAttitude: Quat?
    /// Rate-limited reference the gimbal law tracks (body -> ICRF), and its
    /// rate (ICRF, rad/s). Nil while no axis is flown by the gimbals, or
    /// while the FCC law flies them.
    var referenceAttitude: Quat?
    var referenceRate = Vec3.zero
    /// The FCC law's attitude filters (`FCCGains`) while it flies with them.
    var fccFilter: FCCFilterState?
    /// Phase-plane pulses in progress on the group axes: direction (-1, 0,
    /// +1 per axis) and the minimum on-time still to run, s.
    var groupPulse = (direction: Vec3.zero, remaining: Vec3.zero)
    /// Predicted time until a coasting group axis reaches the phase plane's
    /// switching line, s (infinity when none is heading there).
    var groupSwitch = Double.infinity

    // MARK: Telemetry (updated every step)
    public internal(set) var altitude = 0.0
    public internal(set) var atmosphere = AtmosphereState.vacuum
    public internal(set) var airspeed = 0.0
    public internal(set) var dynamicPressure = 0.0
    public internal(set) var mach = 0.0
    /// Total angle of attack: between +x and the velocity relative to the
    /// air, winds included (rad).
    public internal(set) var angleOfAttack = 0.0
    public internal(set) var thrustAcceleration = 0.0
    // Entry telemetry, set by `Simulation.updateEntryTelemetry`, which does
    // not compute it yet: zero, and the bank nil, until it does.
    /// What an accelerometer at the centre of mass senses (aerodynamic,
    /// parachute and thrust forces over mass), body axes, m/s^2.
    public internal(set) var sensedAcceleration = Vec3.zero
    /// `sensedAcceleration` in standard g.
    public internal(set) var loadFactor = 0.0
    /// Angle of the lift vector about the air-relative velocity from the
    /// local up, positive to the right (rad); nil without a lifting model.
    public internal(set) var bankAngle: Double?
    /// Stagnation-point convective heat flux, W/m^2.
    public internal(set) var heatFlux = 0.0
    /// `heatFlux` integrated over time, J/m^2.
    public internal(set) var heatLoad = 0.0
    /// Epoch of the last entry-telemetry update, for integrating `heatLoad`.
    var entryTelemetryEpoch: Epoch?

    public init(name: String, parts: [VesselPart], reference: CelestialBody,
                position: Vec3 = .zero, velocity: Vec3 = .zero,
                attitude: Quat = .identity, angularVelocity: Vec3 = .zero) {
        self.name = name
        self.parts = parts
        self.reference = reference
        self.position = position
        self.velocity = velocity
        self.attitude = attitude
        self.angularVelocity = angularVelocity
        recenter()
    }

    // MARK: Mass properties

    public var mass: Double { parts.reduce(0) { $0 + $1.mass } }
    public var thrusters: [Thruster] { parts.flatMap(\.thrusters) }
    public var tanks: [PropellantTank] { parts.flatMap(\.tanks) }
    public var parachutes: [Parachute] { parts.flatMap(\.parachutes) }

    /// Centre of mass in the vessel frame. The simulation keeps it at the
    /// origin: it re-centres after every step that uses propellant.
    public var centerOfMass: Vec3 {
        let m = mass
        guard m > 0 else { return .zero }
        return parts.reduce(Vec3.zero) { $0 + ($1.offset + $1.centerOfMass) * $1.mass } / m
    }

    /// Centre of mass in construction coordinates (e.g. Saturn V stations, m).
    public var structuralCenterOfMass: Vec3 { centerOfMass - structureOrigin }

    /// Inertial position (relative to the reference body) of a point given in
    /// construction coordinates.
    public func inertialPosition(ofStructuralPoint p: Vec3) -> Vec3 {
        position + attitude.rotate(p + structureOrigin)
    }

    /// Inertia tensor about the centre of mass, vessel frame, kg m^2.
    public var inertia: Mat3 {
        let com = centerOfMass
        var total = Mat3.zero
        for p in parts {
            total = total + p.localInertia + .parallelAxis(mass: p.mass, offset: p.offset + p.centerOfMass - com)
        }
        return total
    }

    /// Radius of a sphere centred on the vessel origin enclosing all parts.
    public var boundingRadius: Double {
        parts.map { $0.offset.length + max($0.length / 2, $0.radius) }.max() ?? 1
    }

    /// Distance from the origin to the bottom (-x end) of the stack. Used to
    /// place rockets standing on a pad.
    public var baseHeight: Double {
        -(parts.map { $0.offset.x - $0.length / 2 }.min() ?? 0)
    }

    /// Aerodynamic models by configuration, in order of preference: the first
    /// whose parts are all aboard flies (`activeAerodynamics`). Without one
    /// the vessel has only the drag of `dragArea` along the airflow.
    public var aerodynamics: [AerodynamicModel] = []

    /// Maximum cross-section times drag coefficient (m^2).
    public var dragArea: Double {
        parts.map { Double.pi * $0.radius * $0.radius * $0.dragCoefficient }.max() ?? 0
    }

    /// Shift the vessel frame so its origin is at the centre of mass, keeping
    /// the vessel physically where it is: `position` and `velocity` become
    /// those of the structural point at the new centre of mass.
    func recenter() {
        let com = centerOfMass
        guard com.lengthSquared > 0 else { return }
        for p in parts { p.offset -= com }
        structureOrigin -= com
        let shift = attitude.rotate(com)
        position += shift
        velocity += attitude.rotate(angularVelocity.cross(com))
        if var l = landed {
            l.bodyFixedPosition += l.bodyFixedAttitude.rotate(com)
            landed = l
        }
    }

    // MARK: Control allocation

    /// Set the manual rotation and translation inputs from commands in pilot
    /// axes (`controlFrame`), -1...1 per axis, as the keys give them.
    public func setPilotInput(rotation: RotationCommand, translation: Vec3) {
        func clamped(_ v: Vec3) -> Vec3 {
            Vec3(min(max(v.x, -1), 1), min(max(v.y, -1), 1), min(max(v.z, -1), 1))
        }
        let r = clamped(controlFrame.rotate(Vec3(rotation.roll, rotation.pitch, rotation.yaw)))
        rotationInput = RotationCommand(roll: r.x, pitch: r.y, yaw: r.z)
        translationInput = clamped(controlFrame.rotate(translation))
    }

    /// Torque authority about each body axis (N m): per axis, the larger of
    /// the gimballed engines' at their current thrust and the rotation
    /// groups'. Gimbal authority follows the engine levels, so it is only
    /// meaningful once the throttles have been applied for the step.
    public func rotationAuthority() -> Vec3 { controlAllocation().authority }

    /// Whether a thruster takes rotation and translation commands now
    /// (`active` is the vessel's `activeStage`).
    func responds(_ t: Thruster, activeStage active: VesselPart?) -> Bool {
        !t.activeStageOnly || active?.thrusters.contains(where: { $0 === t }) == true
    }

    /// Torque authority of the rotation groups (M0's sum at full vacuum
    /// thrust, over the thrusters that respond now), N m.
    func rcsAuthority() -> Vec3 {
        let com = centerOfMass, active = activeStage
        var authority = Vec3.zero
        for t in thrusters where t.isEnabled && t.hasPropellant && responds(t, activeStage: active) {
            let torque = (t.position + offsetOfPart(owning: t) - com).cross(t.direction) * t.maxThrustVacuum
            if t.groups.contains(.rollRight) { authority.x += abs(torque.x) }
            if t.groups.contains(.pitchUp) { authority.y += abs(torque.y) }
            if t.groups.contains(.yawRight) { authority.z += abs(torque.z) }
        }
        return authority
    }

    func offsetOfPart(owning thruster: Thruster) -> Vec3 {
        for p in parts where p.thrusters.contains(where: { $0 === thruster }) { return p.offset }
        return .zero
    }

    /// Set thruster levels and gimbal commands from the throttles, rotation
    /// and translation commands.
    func applyControls(rotation: RotationCommand) {
        applyThrottles()
        applyRotation(rotation, control: controlAllocation())
    }

    /// Main and retro levels from the throttles; every other level 0.
    func applyThrottles() {
        for t in thrusters { t.level = 0 }
        // Main engines: only the lowest part that has main engines (the active
        // stage of a stack) responds to the main throttle.
        if mainThrottle > 0, let active = activeStage {
            for t in active.thrusters where t.groups.contains(.main) { t.level = t.clampedLevel(mainThrottle) }
        }
        if retroThrottle > 0 {
            for t in thrusters where t.groups.contains(.retro) { t.level = t.clampedLevel(max(t.level, retroThrottle)) }
        }
    }

    /// Rotation and translation, after `applyThrottles`. Each rotation axis
    /// goes to the gimbals when they beat the rotation groups on it (see
    /// `ControlAllocation`), otherwise to the groups. A group thruster's
    /// level is the signed sum of the commands of the axes it serves, so a
    /// thruster in one rotation group gets M0's level.
    func applyRotation(_ rotation: RotationCommand, control: ControlAllocation) {
        let byGimbal = control.gimbalAxes, active = activeStage
        let c = Vec3(byGimbal.roll ? 0 : rotation.roll, byGimbal.pitch ? 0 : rotation.pitch,
                     byGimbal.yaw ? 0 : rotation.yaw)   // what the groups fly
        if c != .zero {
            for t in thrusters where responds(t, activeStage: active) {
                var s = 0.0
                if t.groups.contains(.pitchUp) { s += c.y }
                if t.groups.contains(.pitchDown) { s -= c.y }
                if t.groups.contains(.yawRight) { s += c.z }
                if t.groups.contains(.yawLeft) { s -= c.z }
                if t.groups.contains(.rollRight) { s += c.x }
                if t.groups.contains(.rollLeft) { s -= c.x }
                if s > 0 { t.level = t.clampedLevel(max(t.level, s)) }
            }
        }
        func set(_ g: ThrusterGroup, _ level: Double) {
            guard level > 0 else { return }
            for t in thrusters where t.groups.contains(g) && responds(t, activeStage: active) {
                t.level = t.clampedLevel(max(t.level, level))
            }
        }
        set(translationInput.x > 0 ? .translateForward : .translateBack, abs(translationInput.x))
        set(translationInput.y > 0 ? .translateRight : .translateLeft, abs(translationInput.y))
        set(translationInput.z > 0 ? .translateDown : .translateUp, abs(translationInput.z))
        commandGimbals(Vec3(byGimbal.roll ? rotation.roll : 0, byGimbal.pitch ? rotation.pitch : 0,
                            byGimbal.yaw ? rotation.yaw : 0), control: control)
    }

    /// Total thrust force and torque about the CoM, vessel frame.
    func thrustForceAndTorque(ambientPressure p: Double, seaLevelPressure p0: Double) -> (force: Vec3, torque: Vec3) {
        let com = centerOfMass
        var f = Vec3.zero, tq = Vec3.zero
        for part in parts {
            for t in part.thrusters {
                let mag = t.thrust(ambientPressure: p, seaLevelPressure: p0)
                guard mag > 0 else { continue }
                let force = t.thrustDirection * mag
                f += force
                tq += (t.position + part.offset - com).cross(force)
            }
        }
        return (f, tq)
    }

    /// Draw each firing thruster's propellant for `dt`, then move the
    /// engines' burn clocks and ramps on (once per step). Every engine's
    /// step is fixed before any draws, so engines sharing a tank that runs
    /// dry within it are treated alike. Returns true if any propellant was
    /// drawn (the centre of mass may have moved).
    @discardableResult
    func consumePropellant(dt: Double) -> Bool {
        let steps = thrusters.map { ($0, $0.output, $0.isCommanded) }
        var drew = false
        for (t, output, commanded) in steps {
            if let o = output, o.fraction * o.rating.massFlow > 0 {
                t.draw(dt: dt, output: o, commanded: commanded)
                drew = true
            }
        }
        for t in thrusters { t.advanceTransients(dt: dt) }
        return drew
    }

    // MARK: Derived quantities

    /// Osculating orbit about the current reference body (equatorial reference
    /// plane taken from the body's pole at `snapshot`).
    public func elements(snapshot: SystemSnapshot) -> OrbitalElements {
        OrbitalElements(position: position, velocity: velocity, mu: reference.gm,
                        pole: snapshot.orientation(reference).pole)
    }

    /// Velocity relative to the body's rotating surface/atmosphere, ICRF axes.
    public func surfaceVelocity(snapshot: SystemSnapshot) -> Vec3 {
        velocity - snapshot.orientation(reference).angularVelocity.cross(position)
    }

    /// Geodetic latitude and longitude on the reference body's figure, radians.
    public func latitudeLongitude(snapshot: SystemSnapshot) -> (lat: Double, lon: Double) {
        let g = reference.geodetic(position, orientation: snapshot.orientation(reference))
        return (g.latitude, g.longitude)
    }

    /// Δv available from the active stage's main engines (rocket equation, vacuum
    /// Isp): the enabled mains burn together at full level until the first tank
    /// they draw from is down to its unusable mass. Effective Isp is ΣF / Σṁ.
    /// Engines with a performance schedule follow it (`scheduledDeltaV`);
    /// start and shutdown ramps are ignored.
    public var mainDeltaV: Double {
        guard let active = activeStage else { return 0 }
        let mains = active.thrusters.filter { $0.groups.contains(.main) && $0.isEnabled && $0.hasPropellant }
        if mains.contains(where: { $0.schedule != nil }) { return scheduledDeltaV(mains) }
        var demand: [ObjectIdentifier: (tank: PropellantTank, rate: Double)] = [:]
        var flow = 0.0, thrust = 0.0
        for t in mains {
            guard let feed = t.feed else { continue }
            let mdot = t.rating.massFlow
            flow += mdot
            thrust += t.rating.thrustVacuum
            let r = t.rating.mixtureRatio ?? 0
            let shares: [(PropellantTank, Double)]
            switch feed {
            case .single(let tk): shares = [(tk, mdot)]
            case let .bipropellant(o, f): shares = [(o, mdot * r / (1 + r)), (f, mdot / (1 + r))]
            }
            for (tk, rate) in shares { demand[ObjectIdentifier(tk), default: (tk, 0)].rate += rate }
        }
        guard flow > 0 else { return 0 }
        let burnTime = demand.values.map { $0.tank.usableMass / $0.rate }.min() ?? 0
        let m0 = mass
        return thrust / flow * log(m0 / (m0 - flow * burnTime))
    }

    /// `mainDeltaV` along the engines' schedules, from each one's burn clock:
    /// the rocket equation over 0.5 s steps at the step's mid-point rates,
    /// the last step cut where the first tank reaches its unusable mass.
    func scheduledDeltaV(_ mains: [Thruster]) -> Double {
        var left: [ObjectIdentifier: Double] = [:]
        for t in mains { for tk in t.feed?.tanks ?? [] { left[ObjectIdentifier(tk)] = tk.usableMass } }
        var m = mass, dv = 0.0, elapsed = 0.0
        let h = 0.5
        while m > 0 {
            var flow = 0.0, thrust = 0.0, demand: [ObjectIdentifier: Double] = [:]
            for t in mains {
                guard let feed = t.feed else { continue }
                let rating = t.rating(atBurnTime: t.burnTime + elapsed + h / 2), mdot = rating.massFlow
                flow += mdot
                thrust += rating.thrustVacuum
                let r = rating.mixtureRatio ?? 0
                switch feed {
                case .single(let tk): demand[ObjectIdentifier(tk), default: 0] += mdot
                case let .bipropellant(o, f):
                    demand[ObjectIdentifier(o), default: 0] += mdot * r / (1 + r)
                    demand[ObjectIdentifier(f), default: 0] += mdot / (1 + r)
                }
            }
            guard flow > 0 else { break }
            let s = demand.map { id, rate in rate > 0 ? (left[id] ?? 0) / (rate * h) : 1 }.min() ?? 0
            let dt = h * max(0, min(1, s))
            dv += thrust / flow * log(m / (m - flow * dt))
            m -= flow * dt
            for (id, rate) in demand { left[id, default: 0] -= rate * dt }
            elapsed += dt
            if s < 1 { break }
        }
        return dv
    }
}
