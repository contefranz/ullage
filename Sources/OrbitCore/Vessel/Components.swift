import Foundation

/// Standard gravity used to convert specific impulse to exhaust velocity.
public let standardGravity = 9.80665

public final class PropellantTank {
    public let name: String
    public let capacity: Double   // kg
    public var mass: Double       // kg

    public init(name: String, capacity: Double, mass: Double? = nil) {
        self.name = name
        self.capacity = capacity
        self.mass = mass ?? capacity
    }

    public var fraction: Double { capacity > 0 ? mass / capacity : 0 }
}

/// Logical groups used by the flight controls and autopilots (Orbiter-style).
public enum ThrusterGroup: String, CaseIterable, Codable {
    case main, retro, hover
    case pitchUp, pitchDown, yawLeft, yawRight, rollLeft, rollRight
    case translateForward, translateBack, translateLeft, translateRight, translateUp, translateDown
}

public final class Thruster {
    public let name: String
    /// Position relative to the owning part's origin (part frame == vessel frame axes), m.
    public var position: Vec3
    /// Unit direction of the force applied to the vessel (opposite to the exhaust).
    public var direction: Vec3
    public let maxThrustVacuum: Double   // N
    public let ispVacuum: Double         // s
    public let ispSeaLevel: Double       // s
    public weak var tank: PropellantTank?
    public var groups: Set<ThrusterGroup>
    /// Commanded level 0...1 (set by controls each step).
    public var level: Double = 0

    public init(name: String, position: Vec3, direction: Vec3, maxThrustVacuum: Double,
                ispVacuum: Double, ispSeaLevel: Double? = nil, tank: PropellantTank?, groups: Set<ThrusterGroup>) {
        self.name = name
        self.position = position
        self.direction = direction.normalized
        self.maxThrustVacuum = maxThrustVacuum
        self.ispVacuum = ispVacuum
        self.ispSeaLevel = ispSeaLevel ?? ispVacuum
        self.tank = tank
        self.groups = groups
    }

    public var hasPropellant: Bool { (tank?.mass ?? 0) > 0 }

    /// Delivered thrust (N) at ambient pressure `p` given sea-level pressure `p0`.
    public func thrust(ambientPressure p: Double, seaLevelPressure p0: Double) -> Double {
        guard level > 0, hasPropellant else { return 0 }
        let loss = p0 > 0 ? (1 - ispSeaLevel / ispVacuum) * p / p0 : 0
        return level * maxThrustVacuum * max(0, 1 - loss)
    }

    /// Propellant mass flow (kg/s) at the current level.
    public var massFlow: Double {
        guard level > 0, hasPropellant else { return 0 }
        return level * maxThrustVacuum / (ispVacuum * standardGravity)
    }
}

/// Simple primitives used to draw a part until real meshes exist.
public struct VisualShape {
    public enum Kind { case frustum(baseRadius: Double, topRadius: Double), sphere(radius: Double) }
    public var kind: Kind
    /// Centre of the shape's base (frustum) or centre (sphere), part frame, m.
    public var origin: Vec3
    /// Frustum axis and length (base -> top).
    public var axis: Vec3
    public var length: Double
    /// Linear RGB.
    public var color: (Double, Double, Double)

    public static func frustum(from origin: Vec3, length: Double, baseRadius: Double, topRadius: Double,
                               axis: Vec3 = .unitX, color: (Double, Double, Double)) -> VisualShape {
        VisualShape(kind: .frustum(baseRadius: baseRadius, topRadius: topRadius), origin: origin,
                    axis: axis.normalized, length: length, color: color)
    }
}

/// A rigid module of a vessel (a rocket stage, a spacecraft module...). Parts
/// are what staging separates.
public final class VesselPart {
    public let name: String
    public var dryMass: Double
    /// Position of the part's own centre of mass in the vessel frame, m.
    public var offset: Vec3
    /// Bounding cylinder along the vessel x axis (for inertia, drag and contact).
    public var length: Double
    public var radius: Double
    public var dragCoefficient: Double
    public var tanks: [PropellantTank]
    public var thrusters: [Thruster]
    public var shapes: [VisualShape]

    public init(name: String, dryMass: Double, offset: Vec3 = .zero, length: Double, radius: Double,
                dragCoefficient: Double = 0.5, tanks: [PropellantTank] = [], thrusters: [Thruster] = [],
                shapes: [VisualShape] = []) {
        self.name = name
        self.dryMass = dryMass
        self.offset = offset
        self.length = length
        self.radius = radius
        self.dragCoefficient = dragCoefficient
        self.tanks = tanks
        self.thrusters = thrusters
        self.shapes = shapes
    }

    public var mass: Double { dryMass + tanks.reduce(0) { $0 + $1.mass } }

    /// Inertia tensor about the part's own centre of mass (solid cylinder along x).
    public var localInertia: Mat3 {
        let m = mass, r = radius, l = length
        let ixx = 0.5 * m * r * r
        let iyy = m * (3 * r * r + l * l) / 12
        return .diagonal(Vec3(ixx, iyy, iyy))
    }

    /// Adds a symmetric set of attitude-control thrusters at station `x` (part
    /// frame): two quads fore/aft give pitch, yaw and roll authority.
    public func addRCS(foreX: Double, aftX: Double, radius r: Double, thrust: Double, isp: Double,
                       tank: PropellantTank) {
        func add(_ name: String, _ pos: Vec3, _ dir: Vec3, _ groups: Set<ThrusterGroup>) {
            thrusters.append(Thruster(name: name, position: pos, direction: dir, maxThrustVacuum: thrust,
                                      ispVacuum: isp, tank: tank, groups: groups))
        }
        // Body axes: +x forward (nose), +y right, +z down.
        // Pitch up = positive rotation about +y: push the nose towards -z.
        add("RCS fwd -z", Vec3(foreX, 0, r), Vec3(0, 0, -1), [.pitchUp, .translateUp])
        add("RCS fwd +z", Vec3(foreX, 0, -r), Vec3(0, 0, 1), [.pitchDown, .translateDown])
        add("RCS aft -z", Vec3(aftX, 0, r), Vec3(0, 0, -1), [.pitchDown, .translateUp])
        add("RCS aft +z", Vec3(aftX, 0, -r), Vec3(0, 0, 1), [.pitchUp, .translateDown])
        // Yaw right = positive rotation about +z: push the nose towards +y.
        add("RCS fwd +y", Vec3(foreX, -r, 0), Vec3(0, 1, 0), [.yawRight, .translateRight])
        add("RCS fwd -y", Vec3(foreX, r, 0), Vec3(0, -1, 0), [.yawLeft, .translateLeft])
        add("RCS aft +y", Vec3(aftX, -r, 0), Vec3(0, 1, 0), [.yawLeft, .translateRight])
        add("RCS aft -y", Vec3(aftX, r, 0), Vec3(0, -1, 0), [.yawRight, .translateLeft])
        // Roll right = positive rotation about +x (tangential thrusters at the fore ring).
        add("RCS roll R1", Vec3(foreX, 0, -r), Vec3(0, 1, 0), [.rollRight])
        add("RCS roll R2", Vec3(foreX, 0, r), Vec3(0, -1, 0), [.rollRight])
        add("RCS roll L1", Vec3(foreX, 0, -r), Vec3(0, -1, 0), [.rollLeft])
        add("RCS roll L2", Vec3(foreX, 0, r), Vec3(0, 1, 0), [.rollLeft])
        // Fore/aft translation.
        add("RCS fwd", Vec3(aftX, 0, 0), Vec3(1, 0, 0), [.translateForward])
        add("RCS back", Vec3(foreX, 0, 0), Vec3(-1, 0, 0), [.translateBack])
    }
}
