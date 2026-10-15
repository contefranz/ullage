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
    public private(set) var parts: [VesselPart]

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

    // MARK: Controls
    /// Main engine throttle 0...1.
    public var mainThrottle = 0.0
    /// Hover/retro levels 0...1.
    public var retroThrottle = 0.0
    /// Manual rotation input (RCS).
    public var rotationInput = RotationCommand()
    /// Manual translation input, body axes, -1...1.
    public var translationInput = Vec3.zero
    public var autopilot: AttitudeAutopilot?

    // MARK: Telemetry (updated every step)
    public internal(set) var altitude = 0.0
    public internal(set) var atmosphere = AtmosphereState.vacuum
    public internal(set) var airspeed = 0.0
    public internal(set) var dynamicPressure = 0.0
    public internal(set) var mach = 0.0
    public internal(set) var thrustAcceleration = 0.0

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

    public var centerOfMass: Vec3 {
        let m = mass
        guard m > 0 else { return .zero }
        return parts.reduce(Vec3.zero) { $0 + $1.offset * $1.mass } / m
    }

    /// Inertia tensor about the centre of mass, vessel frame, kg m^2.
    public var inertia: Mat3 {
        let com = centerOfMass
        var total = Mat3.zero
        for p in parts {
            let d = p.offset - com
            let m = p.mass
            let parallel = Mat3.identity * (m * d.lengthSquared) + Mat3(columns: d * (-m * d.x), d * (-m * d.y), d * (-m * d.z))
            total = total + p.localInertia + parallel
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

    /// Maximum cross-section times drag coefficient (m^2).
    public var dragArea: Double {
        parts.map { Double.pi * $0.radius * $0.radius * $0.dragCoefficient }.max() ?? 0
    }

    /// Shift the vessel frame so its origin is at the centre of mass, keeping
    /// the vessel physically where it is.
    func recenter() {
        let com = centerOfMass
        guard com.lengthSquared > 1e-12 else { return }
        for p in parts { p.offset -= com }
        let shift = attitude.rotate(com)
        position += shift
        velocity += attitude.rotate(angularVelocity.cross(com))
        if var l = landed {
            l.bodyFixedPosition += l.bodyFixedAttitude.rotate(com)
            landed = l
        }
    }

    // MARK: Staging

    /// Detach `detached` parts as a new vessel. Both vessels are re-centred on
    /// their own centre of mass. Returns the new vessel, or nil if nothing matched.
    @discardableResult
    public func separate(parts detached: [VesselPart], name: String, separationSpeed: Double = 0) -> Vessel? {
        let ids = Set(detached.map { ObjectIdentifier($0) })
        let leaving = parts.filter { ids.contains(ObjectIdentifier($0)) }
        guard !leaving.isEmpty, leaving.count < parts.count else { return nil }
        let leavingMass = leaving.reduce(0) { $0 + $1.mass }
        let leavingCom = leaving.reduce(Vec3.zero) { $0 + $1.offset * $1.mass } / max(leavingMass, 1e-9)
        let oldLanded = landed

        parts.removeAll { ids.contains(ObjectIdentifier($0)) }
        for t in leaving.flatMap(\.thrusters) { t.level = 0 }

        // The initialiser re-centres the new vessel on its own centre of mass.
        let other = Vessel(name: name, parts: leaving, reference: reference, position: position,
                           velocity: velocity, attitude: attitude, angularVelocity: angularVelocity)
        other.status = status
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

    /// Separate the part with the lowest x (the bottom stage of a stack).
    @discardableResult
    public func jettisonBottomPart() -> Vessel? {
        guard parts.count > 1, let bottom = parts.min(by: { $0.offset.x < $1.offset.x }) else { return nil }
        return separate(parts: [bottom], name: "\(name) – \(bottom.name)", separationSpeed: 1.0)
    }

    // MARK: Control allocation

    /// Torque authority about each body axis (N m) for the rotation groups.
    public func rotationAuthority() -> Vec3 {
        let com = centerOfMass
        var authority = Vec3.zero
        for t in thrusters where t.hasPropellant {
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

    /// Set thruster levels from throttles, rotation and translation commands.
    func applyControls(rotation: RotationCommand) {
        for t in thrusters { t.level = 0 }
        func set(_ g: ThrusterGroup, _ level: Double) {
            guard level > 0 else { return }
            for t in thrusters where t.groups.contains(g) { t.level = min(1, max(t.level, level)) }
        }
        // Main engines: only the lowest part that has main engines (the active
        // stage of a stack) responds to the main throttle.
        if mainThrottle > 0,
           let active = parts.filter({ $0.thrusters.contains { $0.groups.contains(.main) } })
                .min(by: { $0.offset.x < $1.offset.x }) {
            for t in active.thrusters where t.groups.contains(.main) { t.level = min(1, mainThrottle) }
        }
        set(.retro, retroThrottle)
        set(rotation.pitch > 0 ? .pitchUp : .pitchDown, abs(rotation.pitch))
        set(rotation.yaw > 0 ? .yawRight : .yawLeft, abs(rotation.yaw))
        set(rotation.roll > 0 ? .rollRight : .rollLeft, abs(rotation.roll))
        set(translationInput.x > 0 ? .translateForward : .translateBack, abs(translationInput.x))
        set(translationInput.y > 0 ? .translateRight : .translateLeft, abs(translationInput.y))
        set(translationInput.z > 0 ? .translateDown : .translateUp, abs(translationInput.z))
    }

    /// Total thrust force and torque about the CoM, vessel frame.
    func thrustForceAndTorque(ambientPressure p: Double, seaLevelPressure p0: Double) -> (force: Vec3, torque: Vec3) {
        let com = centerOfMass
        var f = Vec3.zero, tq = Vec3.zero
        for part in parts {
            for t in part.thrusters {
                let mag = t.thrust(ambientPressure: p, seaLevelPressure: p0)
                guard mag > 0 else { continue }
                let force = t.direction * mag
                f += force
                tq += (t.position + part.offset - com).cross(force)
            }
        }
        return (f, tq)
    }

    func consumePropellant(dt: Double) {
        for t in thrusters {
            guard let tank = t.tank else { continue }
            let flow = t.massFlow
            if flow > 0 { tank.mass = max(0, tank.mass - flow * dt) }
        }
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

    /// Geodetic-free (spherical) latitude/longitude in radians.
    public func latitudeLongitude(snapshot: SystemSnapshot) -> (lat: Double, lon: Double) {
        let bf = snapshot.orientation(reference).toBody(position)
        return (asin(bf.z / bf.length), atan2(bf.y, bf.x))
    }

    /// Δv available from the active stage's main engines (rocket equation, vacuum Isp).
    public var mainDeltaV: Double {
        guard let active = parts.filter({ $0.thrusters.contains { $0.groups.contains(.main) } })
            .min(by: { $0.offset.x < $1.offset.x }) else { return 0 }
        let mains = active.thrusters.filter { $0.groups.contains(.main) && $0.hasPropellant }
        guard let first = mains.first else { return 0 }
        var seen = Set<ObjectIdentifier>()
        var prop = 0.0
        for t in mains { if let tk = t.tank, seen.insert(ObjectIdentifier(tk)).inserted { prop += tk.mass } }
        let m0 = mass
        return first.ispVacuum * standardGravity * log(m0 / (m0 - prop))
    }
}
