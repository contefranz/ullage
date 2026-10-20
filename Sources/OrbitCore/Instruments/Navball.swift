import Foundation

/// The velocity the navball's speed and prograde markers refer to (KSP's
/// speed modes).
public enum VelocityFrame: String, CaseIterable, Sendable {
    /// Inertial, relative to the reference body's centre.
    case orbit
    /// Relative to the reference body's rotating surface.
    case surface
    /// Relative to the target vessel.
    case target

    /// Short label for the speed readout.
    public var label: String {
        switch self {
        case .orbit: "ORB"
        case .surface: "SRF"
        case .target: "TGT"
        }
    }
}

/// A vessel's state relative to a target vessel, from their barycentric
/// states, so the two may have different reference bodies. The bodies'
/// offset is taken first, so the relative state keeps the precision of the
/// vessels' own states (barycentric positions are ~1e11 m, whose last bit
/// is ~3e-5 m).
public struct TargetRelative: Equatable {
    /// The vessel's position and velocity relative to the target (ICRF, m
    /// and m/s): the velocity is target mode's.
    public let position: Vec3
    public let velocity: Vec3

    public init(position: Vec3, velocity: Vec3) {
        self.position = position
        self.velocity = velocity
    }

    /// `vessel` relative to `target` at `snap`.
    public init(of v: Vessel, to target: Vessel, snapshot snap: SystemSnapshot) {
        let a = v.reference, b = target.reference
        let r = a.id == b.id ? Vec3.zero : snap.position(a) - snap.position(b)
        let w = a.id == b.id ? Vec3.zero : snap.velocity(a) - snap.velocity(b)
        position = r + (v.position - target.position)
        velocity = w + (v.velocity - target.velocity)
    }

    /// Distance between the two, m.
    public var range: Double { position.length }
    /// Rate of `range`, m/s: positive opening, negative closing.
    public var rangeRate: Double { range > 0 ? position.dot(velocity) / range : velocity.length }
    /// The direction from the vessel to the target (ICRF).
    public var towardTarget: Vec3 { -position }
}

/// A direction marked on the navball.
public struct NavballMarker: Equatable {
    public enum Kind: String, CaseIterable, Sendable {
        case prograde, retrograde, normal, antinormal, radialOut, radialIn
        /// Where the autopilot steers the nose (flight director).
        case command
        /// The main engines' thrust.
        case thrust
        case target, antitarget, maneuver
    }

    public let kind: Kind
    /// Unit direction in pilot axes (`Vessel.controlFrame`).
    public let body: Vec3

    public init(kind: Kind, body: Vec3) {
        self.kind = kind
        self.body = body
    }
}

/// Angle of attack and sideslip, rad: the velocity relative to the air in
/// pilot axes (u, v, w), α = atan2(w, u), β = asin(v / |V|).
public struct AeroAngles: Equatable {
    public let alpha: Double
    public let beta: Double
}

/// What the navball and its readouts show for a vessel at one instant: the
/// pilot's attitude in the geodetic horizon, the speed in the chosen frame,
/// and the markers. Everything is in pilot axes, `attitude * controlFrame`
/// (+x nose, +y right, +z down for the crew), so the ball's top is the
/// crew's head.
public struct Navball {
    public private(set) var frame: VelocityFrame
    public private(set) var horizon: LocalHorizon
    /// Pilot axes -> north-east-down: the ball's orientation.
    public private(set) var bodyToNED: Mat3
    public private(set) var angles: HorizonAttitude
    /// Speed in `frame`, m/s.
    public private(set) var speed: Double
    /// Inertial velocity along the horizon's up, m/s (the HUD's).
    public private(set) var verticalSpeed: Double
    /// Geodetic altitude, m.
    public private(set) var altitude = 0.0
    /// Body rates in pilot axes (roll, pitch, yaw), rad/s.
    public private(set) var rates = Vec3.zero
    public private(set) var markers: [NavballMarker]
    /// The rotation (pilot axes, rad) from the attitude to the command: the
    /// hold's full error, the nose's in the pointing modes; nil without one.
    public private(set) var attitudeError: Vec3?
    /// Nil out of the air.
    public private(set) var aero: AeroAngles?
    /// The target vessel relative to this one; nil without a target.
    public private(set) var target: TargetRelative?

    /// Below this speed (m/s) in the frame there are no prograde markers;
    /// in target mode below `minimumTargetSpeed`, as docking speeds are a
    /// few cm/s.
    public static let minimumSpeed = 0.1
    public static let minimumTargetSpeed = 0.001

    /// The ball for an attitude (pilot axes -> the frame of the vectors) in
    /// `horizon`: the trajectory markers from `position` and the inertial
    /// `velocity` (normal and radial), and prograde from `frameVelocity`,
    /// the velocity in `frame`. Radial is ±r̂, as the autopilot flies it.
    /// With a `target`, the target and anti-target markers.
    public init(attitude: Quat, horizon: LocalHorizon, position: Vec3, velocity: Vec3,
                frame: VelocityFrame, frameVelocity: Vec3, target: TargetRelative? = nil) {
        self.frame = frame
        self.horizon = horizon
        self.target = target
        bodyToNED = horizon.nedToInertial.transposed * attitude.matrix
        angles = HorizonAttitude(bodyToNED: bodyToNED)
        speed = frameVelocity.length
        verticalSpeed = velocity.dot(horizon.up)
        var m: [NavballMarker] = []
        func add(_ kind: NavballMarker.Kind, _ d: Vec3) {
            m.append(NavballMarker(kind: kind, body: attitude.inverseRotate(d.normalized)))
        }
        if speed >= (frame == .target ? Self.minimumTargetSpeed : Self.minimumSpeed) {
            add(.prograde, frameVelocity)
            add(.retrograde, -frameVelocity)
        }
        let n = position.cross(velocity)
        if n.length > 0 {
            add(.normal, n)
            add(.antinormal, -n)
        }
        if position.length > 0 {
            add(.radialOut, position)
            add(.radialIn, -position)
        }
        if let t = target, t.range > 0 {
            add(.target, t.towardTarget)
            add(.antitarget, -t.towardTarget)
        }
        markers = m
    }

    /// The ball for `vessel`, with its command and thrust markers, rates,
    /// attitude error and aerodynamic angles; `target` is the vessel target
    /// mode refers to, and `maneuver` a burn's Δv direction (ICRF). The
    /// target frame without a target is the orbit's.
    public init(vessel v: Vessel, in sim: Simulation, snapshot snap: SystemSnapshot, frame: VelocityFrame,
                target: Vessel? = nil, maneuver: Vec3? = nil) {
        let body = v.reference, o = snap.orientation(body)
        let pilot = (v.attitude * v.controlFrame).normalized
        let relative = target.flatMap { $0 === v ? nil : TargetRelative(of: v, to: $0, snapshot: snap) }
        let frame = frame == .target && relative == nil ? .orbit : frame
        let frameVelocity: Vec3
        switch frame {
        case .orbit: frameVelocity = v.velocity
        case .surface: frameVelocity = v.surfaceVelocity(snapshot: snap)
        case .target: frameVelocity = relative!.velocity
        }
        self.init(attitude: pilot, horizon: .geodetic(at: v.position, body: body, orientation: o),
                  position: v.position, velocity: v.velocity, frame: frame, frameVelocity: frameVelocity,
                  target: relative)
        altitude = v.altitude
        rates = v.controlFrame.inverseRotate(v.angularVelocity)

        // The command: under the hold, the attitude it steers to (the IU's,
        // or the one it captured); under a pointing mode, its target.
        switch v.autopilot {
        case nil, .killRotation?:
            break
        case .attitudeHold?:
            if let goal = v.attitudeCommand?.attitude ?? v.heldAttitude {
                markers.append(NavballMarker(kind: .command,
                                             body: pilot.inverseRotate((goal * v.controlFrame).rotate(.unitX))))
                attitudeError = v.controlFrame.inverseRotate(rotationVector(v.attitude.conjugate * goal))
            }
        case let mode?:
            if let target = mode.target(for: v), target.lengthSquared > 0.5 {
                let b = pilot.inverseRotate(target.normalized)
                markers.append(NavballMarker(kind: .command, body: b))
                let axis = Vec3.unitX.cross(b), angle = atan2(axis.length, b.x)
                attitudeError = axis.length > 1e-12 ? axis.normalized * angle : .zero
            }
        }

        // The main engines' thrust, gimbal deflections and engines out included.
        let p0 = sim.atmosphere(of: body)?.seaLevelPressure ?? 0
        var force = Vec3.zero
        for t in v.thrusters where t.groups.contains(.main) && t.isDelivering {
            force += t.thrustDirection * t.thrust(ambientPressure: v.atmosphere.pressure, seaLevelPressure: p0)
        }
        if force.length > 0 {
            markers.append(NavballMarker(kind: .thrust, body: v.controlFrame.inverseRotate(force.normalized)))
        }
        if let m = maneuver, m.length > 0 {
            markers.append(NavballMarker(kind: .maneuver, body: pilot.inverseRotate(m.normalized)))
        }

        if let atm = sim.atmosphere(of: body), v.atmosphere.density > 0 {
            let air = pilot.inverseRotate(sim.airVelocity(r: v.position, v: v.velocity, body: body, atmosphere: atm,
                                                          altitude: v.altitude, snapshot: snap))
            let speed = air.length
            if speed > Self.minimumSpeed {
                aero = AeroAngles(alpha: atan2(air.z, air.x), beta: asin(max(-1, min(1, air.y / speed))))
            }
        }
    }

    /// The first marker of `kind`, if shown.
    public func marker(_ kind: NavballMarker.Kind) -> NavballMarker? { markers.first { $0.kind == kind } }

    /// Elevation and azimuth on the ball (in `horizon`) of a pilot-axis
    /// direction, rad.
    public func elevationAzimuth(of body: Vec3) -> (elevation: Double, azimuth: Double) {
        let d = (bodyToNED * body).normalized
        let az = atan2(d.y, d.x)
        return (asin(max(-1, min(1, -d.z))), az < 0 ? az + 2 * .pi : az)
    }

    /// Where a pilot-axis unit direction lies on the ball's face, seen along
    /// the nose: orthographic, x = b.y to the right, y = -b.z up (the
    /// head), both within the unit circle; `front` when it is on the near
    /// hemisphere.
    public static func project(_ b: Vec3) -> (x: Double, y: Double, front: Bool) {
        (b.y, -b.z, b.x > 0)
    }

    /// Angle on the ball's rim (rad, from the right towards the top) of the
    /// pointer for a direction behind the ball.
    public static func edgeAngle(_ b: Vec3) -> Double { atan2(-b.z, b.y) }

    // MARK: Speed mode

    /// Altitudes of the automatic speed mode (m): the surface below
    /// `surfaceBelow` descending, the orbit above `orbitAbove` climbing.
    public static let surfaceBelow = 40_000.0
    public static let orbitAbove = 50_000.0

    /// The automatic speed mode: the surface when landed or descending below
    /// 40 km, the orbit when climbing above 50 km, otherwise `previous`
    /// (with none, the nearer threshold's side of 45 km).
    public static func autoFrame(previous: VelocityFrame?, altitude: Double, verticalSpeed: Double,
                                 landed: Bool) -> VelocityFrame {
        if landed || altitude < surfaceBelow && verticalSpeed < 0 { return .surface }
        if altitude > orbitAbove && verticalSpeed > 0 { return .orbit }
        return previous ?? (altitude >= (surfaceBelow + orbitAbove) / 2 ? .orbit : .surface)
    }

    /// The automatic speed mode for `vessel` (its inertial vertical speed
    /// along the geodetic normal).
    public static func autoFrame(previous: VelocityFrame?, vessel v: Vessel, snapshot snap: SystemSnapshot)
        -> VelocityFrame {
        let up = v.reference.vertical(at: v.position, orientation: snap.orientation(v.reference))
        return autoFrame(previous: previous, altitude: v.altitude, verticalSpeed: v.velocity.dot(up),
                         landed: v.landed != nil)
    }
}
