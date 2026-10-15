import Foundation

/// Standard gravity used to convert specific impulse to exhaust velocity.
public let standardGravity = 9.80665

/// One standard atmosphere, Pa: the pressure engine sea-level ratings refer to.
public let standardAtmosphere = 101_325.0

/// Where a tank's propellant sits inside its part (part frame).
public enum TankGeometry: Equatable {
    /// M0 behaviour: the propellant sits at the part's dry centre of mass and
    /// is included in the part's body inertia.
    case lumped
    /// A point mass at the given position.
    case point(Vec3)
    /// Liquid settled aft (towards -x) in a constant-section column whose aft
    /// end is `aftEnd`; `length` is the column height when the tank holds
    /// `capacity`. The fill height is `length * mass / capacity`.
    case settledColumn(aftEnd: Vec3, length: Double, radius: Double)

    /// Column whose full-load centroid is `fullLoadCentroid`, sized from the
    /// load volume (`capacity / density`) and the tank radius. Pass the
    /// tank's own capacity.
    public static func column(fullLoadCentroid c: Vec3, radius: Double, capacity: Double,
                              density: Double) -> TankGeometry {
        let length = capacity / (density * Double.pi * radius * radius)
        return .settledColumn(aftEnd: c - Vec3.unitX * (length / 2), length: length, radius: radius)
    }
}

public final class PropellantTank {
    public let name: String
    public let capacity: Double   // kg
    public var mass: Double       // kg, including `unusableMass`
    /// Propellant the engines cannot draw (below the depletion sensors, in
    /// lines and sumps). It stays in the tank and counts in mass and CoM.
    public var unusableMass: Double
    public var geometry: TankGeometry

    public init(name: String, capacity: Double, mass: Double? = nil, unusableMass: Double = 0,
                geometry: TankGeometry = .lumped) {
        self.name = name
        self.capacity = capacity
        self.mass = mass ?? capacity
        self.unusableMass = unusableMass
        self.geometry = geometry
    }

    public var fraction: Double { capacity > 0 ? mass / capacity : 0 }
    public var usableMass: Double { max(0, mass - unusableMass) }

    /// Centre of the propellant in the part frame, or nil for a lumped tank.
    public var centroid: Vec3? {
        switch geometry {
        case .lumped: return nil
        case .point(let p): return p
        case let .settledColumn(aftEnd, length, _): return aftEnd + Vec3.unitX * (length * fraction / 2)
        }
    }

    /// Inertia of the propellant about its own centroid (a solid cylinder for
    /// a column; zero for point and lumped tanks).
    var ownInertia: Mat3 {
        guard case let .settledColumn(_, length, r) = geometry else { return .zero }
        let h = length * fraction, m = mass
        let iyy = m * (3 * r * r + h * h) / 12
        return .diagonal(Vec3(0.5 * m * r * r, iyy, iyy))
    }
}

/// Logical groups used by the flight controls and autopilots (Orbiter-style).
public enum ThrusterGroup: String, CaseIterable, Codable {
    case main, retro, hover
    case pitchUp, pitchDown, yawLeft, yawRight, rollLeft, rollRight
    case translateForward, translateBack, translateLeft, translateRight, translateUp, translateDown
}

/// What an engine delivers at one operating setting (for example one J-2
/// mixture-ratio setting). Mass flow does not depend on ambient pressure.
public struct EngineRating: Equatable {
    public var name: String
    public var thrustVacuum: Double     // N
    public var ispVacuum: Double        // s
    public var ispSeaLevel: Double      // s, at `standardAtmosphere`
    /// Oxidizer/fuel mass ratio drawn from the tanks (engine overall, gas
    /// generator included). Required for bipropellant feeds.
    public var mixtureRatio: Double?

    public init(name: String = "", thrustVacuum: Double, ispVacuum: Double, ispSeaLevel: Double? = nil,
                mixtureRatio: Double? = nil) {
        self.name = name
        self.thrustVacuum = thrustVacuum
        self.ispVacuum = ispVacuum
        self.ispSeaLevel = ispSeaLevel ?? ispVacuum
        self.mixtureRatio = mixtureRatio
    }

    /// Rating of a fixed nozzle: F(p) = F_vac - p A_e at constant flow, so
    /// Isp_sl = Isp_vac (1 - p0 A_e / F_vac). Use it for every setting of one
    /// engine so the pressure loss stays tied to the nozzle geometry.
    public static func fixedNozzle(name: String, thrustVacuum: Double, ispVacuum: Double, exitArea: Double,
                                   mixtureRatio: Double?) -> EngineRating {
        EngineRating(name: name, thrustVacuum: thrustVacuum, ispVacuum: ispVacuum,
                     ispSeaLevel: ispVacuum * (1 - standardAtmosphere * exitArea / thrustVacuum),
                     mixtureRatio: mixtureRatio)
    }

    /// Propellant mass flow at full level, kg/s.
    public var massFlow: Double { thrustVacuum / (ispVacuum * standardGravity) }
    /// Exit area implied by the two Isp values, m^2.
    public var impliedExitArea: Double { thrustVacuum * (1 - ispSeaLevel / ispVacuum) / standardAtmosphere }
}

/// Tanks an engine draws from.
public enum PropellantFeed {
    case single(PropellantTank)
    /// Split by the rating's mixture ratio; the engine stops when either tank
    /// is down to its unusable mass.
    case bipropellant(oxidizer: PropellantTank, fuel: PropellantTank)

    public var tanks: [PropellantTank] {
        switch self {
        case .single(let t): return [t]
        case let .bipropellant(o, f): return [o, f]
        }
    }
}

public final class Thruster {
    public let name: String
    /// A point on the thrust line (the gimbal point for engines), part frame, m.
    public var position: Vec3
    /// Unit direction of the force applied to the vessel (opposite to the exhaust).
    public var direction: Vec3
    /// Current operating setting; assigning it changes thrust, flow and the
    /// propellant split from the next step.
    public var rating: EngineRating { didSet { checkMixtureRatio() } }
    public var feed: PropellantFeed? { didSet { checkMixtureRatio() } }
    public var groups: Set<ThrusterGroup>
    /// Levels the engine can run at; any positive command is clamped into it.
    /// `1...1` is an on/off engine (F-1, J-2).
    public var throttleRange: ClosedRange<Double>
    /// False keeps the engine shut down whatever the controls command.
    public var isEnabled = true
    /// Commanded level 0...1 (set by controls each step).
    public var level: Double = 0

    public init(name: String, position: Vec3, direction: Vec3, rating: EngineRating, feed: PropellantFeed?,
                groups: Set<ThrusterGroup>, throttleRange: ClosedRange<Double> = 0...1) {
        self.name = name
        self.position = position
        self.direction = direction.normalized
        self.rating = rating
        self.feed = feed
        self.groups = groups
        self.throttleRange = throttleRange
        checkMixtureRatio()
    }

    /// Single-tank thruster with an M0-style rating.
    public convenience init(name: String, position: Vec3, direction: Vec3, maxThrustVacuum: Double,
                            ispVacuum: Double, ispSeaLevel: Double? = nil, tank: PropellantTank?,
                            groups: Set<ThrusterGroup>) {
        self.init(name: name, position: position, direction: direction,
                  rating: EngineRating(thrustVacuum: maxThrustVacuum, ispVacuum: ispVacuum, ispSeaLevel: ispSeaLevel),
                  feed: tank.map { .single($0) }, groups: groups)
    }

    private func checkMixtureRatio() {
        if case .bipropellant = feed {
            precondition((rating.mixtureRatio ?? 0) > 0, "\(name): a bipropellant feed needs a mixture ratio")
        }
    }

    public var maxThrustVacuum: Double { rating.thrustVacuum }
    public var ispVacuum: Double { rating.ispVacuum }
    public var ispSeaLevel: Double { rating.ispSeaLevel }
    /// The tank of a single-tank feed (nil for bipropellant engines).
    public var tank: PropellantTank? { if case .single(let t) = feed { return t } else { return nil } }

    /// True while every tank of the feed holds usable propellant.
    public var hasPropellant: Bool { feed.map { $0.tanks.allSatisfy { $0.usableMass > 0 } } ?? false }

    /// Level for a positive command, clamped into `throttleRange`.
    func clampedLevel(_ c: Double) -> Double {
        min(throttleRange.upperBound, max(throttleRange.lowerBound, c))
    }

    /// Delivered thrust (N) at ambient pressure `p` given sea-level pressure `p0`.
    public func thrust(ambientPressure p: Double, seaLevelPressure p0: Double) -> Double {
        guard isEnabled, level > 0, hasPropellant else { return 0 }
        let loss = p0 > 0 ? (1 - ispSeaLevel / ispVacuum) * p / p0 : 0
        return level * maxThrustVacuum * max(0, 1 - loss)
    }

    /// Propellant mass flow (kg/s) at the current level.
    public var massFlow: Double {
        guard isEnabled, level > 0, hasPropellant else { return 0 }
        return level * rating.massFlow
    }

    /// Draw `massFlow * dt` from the feed, never below a tank's unusable mass;
    /// a bipropellant draw is scaled so the mixture ratio stays exact. A tank
    /// that limits the draw ends exactly at its unusable mass.
    func draw(dt: Double) {
        let m = massFlow * dt
        guard m > 0, let feed else { return }
        switch feed {
        case .single(let t):
            t.mass = max(t.unusableMass, t.mass - m)
        case let .bipropellant(o, f):
            let r = rating.mixtureRatio ?? 0
            let ox = m * r / (1 + r), fu = m / (1 + r)
            let sOx = o.usableMass / ox, sFu = f.usableMass / fu
            let s = min(1, sOx, sFu)
            o.mass = s == sOx ? o.unusableMass : o.mass - ox * s
            f.mass = s == sFu ? f.unusableMass : f.mass - fu * s
        }
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

/// How the Space key (`Vessel.jettisonNextStage`) treats a part.
public enum StagingRule: Equatable {
    /// M0: the lowest such part is jettisoned when no event is pending.
    case bottomOfStack
    /// Separated, together with every part carrying the same number, by the
    /// press after all lower-numbered events. The number orders the events.
    case event(Int)
    /// Never separated by the Space key.
    case fixed
}

/// A rigid module of a vessel (a rocket stage, a spacecraft module...). Parts
/// are what staging separates.
public final class VesselPart {
    public let name: String
    public var dryMass: Double
    /// Position of the part's reference point (the centre of its bounding
    /// cylinder) in the vessel frame, m. The simulation keeps the vessel
    /// origin at the centre of mass, so offsets change as propellant is used.
    public var offset: Vec3
    /// Bounding cylinder along the vessel x axis (for inertia, drag and contact).
    public var length: Double
    public var radius: Double
    public var dragCoefficient: Double
    public var tanks: [PropellantTank]
    public var thrusters: [Thruster]
    public var shapes: [VisualShape]
    /// Centre of mass of the dry part (and of its lumped tanks), part frame.
    public var dryCenterOfMass: Vec3
    /// Dry inertia about `dryCenterOfMass`; nil uses a solid bounding cylinder.
    public var dryInertia: Mat3?
    public var staging: StagingRule

    public init(name: String, dryMass: Double, offset: Vec3 = .zero, length: Double, radius: Double,
                dragCoefficient: Double = 0.5, tanks: [PropellantTank] = [], thrusters: [Thruster] = [],
                shapes: [VisualShape] = [], dryCenterOfMass: Vec3 = .zero, dryInertia: Mat3? = nil,
                staging: StagingRule = .bottomOfStack) {
        self.name = name
        self.dryMass = dryMass
        self.offset = offset
        self.length = length
        self.radius = radius
        self.dragCoefficient = dragCoefficient
        self.tanks = tanks
        self.thrusters = thrusters
        self.shapes = shapes
        self.dryCenterOfMass = dryCenterOfMass
        self.dryInertia = dryInertia
        self.staging = staging
    }

    public var mass: Double { dryMass + tanks.reduce(0) { $0 + $1.mass } }

    struct MassElement { var mass: Double; var position: Vec3; var inertia: Mat3 }

    /// The dry body (with any lumped tanks) and one element per placed tank,
    /// part frame. Each inertia is about the element's own position.
    var massElements: [MassElement] {
        var lumped = 0.0
        var elements: [MassElement] = []
        for t in tanks {
            if let c = t.centroid {
                elements.append(MassElement(mass: t.mass, position: c, inertia: t.ownInertia))
            } else {
                lumped += t.mass
            }
        }
        // Solid bounding cylinder along x.
        func cylinder(_ m: Double) -> Mat3 {
            let r = radius, l = length
            let ixx = 0.5 * m * r * r
            let iyy = m * (3 * r * r + l * l) / 12
            return .diagonal(Vec3(ixx, iyy, iyy))
        }
        let bodyInertia = dryInertia.map { $0 + cylinder(lumped) } ?? cylinder(dryMass + lumped)
        elements.insert(MassElement(mass: dryMass + lumped, position: dryCenterOfMass, inertia: bodyInertia), at: 0)
        return elements
    }

    /// Centre of mass of the part, part frame.
    public var centerOfMass: Vec3 {
        let m = mass
        guard m > 0 else { return dryCenterOfMass }
        return massElements.reduce(Vec3.zero) { $0 + $1.position * $1.mass } / m
    }

    /// Inertia tensor about the part's own centre of mass (for an M0 part,
    /// a solid cylinder along x).
    public var localInertia: Mat3 {
        let c = centerOfMass
        return massElements.reduce(Mat3.zero) { $0 + $1.inertia + .parallelAxis(mass: $1.mass, offset: $1.position - c) }
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

extension Mat3 {
    /// Parallel-axis term m (|d|^2 I - d d^T) for a mass `m` displaced by `d`.
    static func parallelAxis(mass m: Double, offset d: Vec3) -> Mat3 {
        Mat3.identity * (m * d.lengthSquared) + Mat3(columns: d * (-m * d.x), d * (-m * d.y), d * (-m * d.z))
    }
}
