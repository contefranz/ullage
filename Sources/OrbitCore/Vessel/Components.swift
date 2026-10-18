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

    /// This rating with its vacuum thrust and mass flow scaled, and its
    /// mixture ratio replaced if given, on the same nozzle: the exit area,
    /// and so the pressure loss p A_e, stay the same.
    public func scaled(thrust kF: Double, flow kM: Double, mixtureRatio r: Double? = nil) -> EngineRating {
        if kF == 1 && kM == 1 && r == nil { return self }
        let area = impliedExitArea, f = thrustVacuum * kF, mdot = massFlow * kM
        let isp = f / (mdot * standardGravity)
        return EngineRating(name: name, thrustVacuum: f, ispVacuum: isp,
                            ispSeaLevel: isp * (1 - standardAtmosphere * area / f), mixtureRatio: r ?? mixtureRatio)
    }
}

/// How an engine's performance changes over its burn, against its burn
/// clock (`Thruster.burnTime`, seconds since it was last commanded on):
/// factors on the rating's vacuum thrust and mass flow, and optionally its
/// mixture ratio, linear between knots and constant beyond the ends. The
/// nozzle, and so the pressure loss, stays the rating's.
public struct PerformanceSchedule: Equatable {
    public struct Knot: Equatable {
        public var time: Double
        public var thrustFactor: Double
        public var flowFactor: Double
        public var mixtureRatio: Double?
        public init(time: Double, thrustFactor: Double, flowFactor: Double, mixtureRatio: Double? = nil) {
            self.time = time
            self.thrustFactor = thrustFactor
            self.flowFactor = flowFactor
            self.mixtureRatio = mixtureRatio
        }
    }

    public let knots: [Knot]

    /// Knots in increasing time; a mixture ratio on one knot needs one on every knot.
    public init(_ knots: [Knot]) {
        precondition(!knots.isEmpty, "a schedule needs knots")
        precondition(zip(knots, knots.dropFirst()).allSatisfy { $0.time < $1.time }, "knot times must increase")
        precondition(knots.allSatisfy { $0.mixtureRatio == nil } || knots.allSatisfy { $0.mixtureRatio != nil },
                     "mixture ratio on every knot or none")
        self.knots = knots
    }

    /// Factors and mixture ratio at burn time `t`.
    public func values(at t: Double) -> (thrust: Double, flow: Double, mixtureRatio: Double?) {
        guard let i = knots.firstIndex(where: { $0.time > t }) else {
            let k = knots[knots.count - 1]
            return (k.thrustFactor, k.flowFactor, k.mixtureRatio)
        }
        guard i > 0 else { return (knots[0].thrustFactor, knots[0].flowFactor, knots[0].mixtureRatio) }
        let a = knots[i - 1], b = knots[i], u = (t - a.time) / (b.time - a.time)
        func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * u }
        return (lerp(a.thrustFactor, b.thrustFactor), lerp(a.flowFactor, b.flowFactor),
                a.mixtureRatio.flatMap { ma in b.mixtureRatio.map { lerp(ma, $0) } })
    }
}

/// Start and shutdown transients, as linear ramps of thrust and flow. Once
/// commanded on, the engine gives nothing for `startDelay` s, then rises to
/// full over `startRise` s: the start impulse is (startRise / 2) s of full
/// thrust. Once it stops (cut off, throttled to zero, or out of propellant)
/// it falls from where it was to zero over `shutdown` s, half that time of
/// full thrust, drawing the tail-off propellant from below its tanks'
/// unusable mass. A cut engine runs that decay to its end before it can
/// start again.
public struct EngineTransients: Equatable {
    public var startDelay: Double
    public var startRise: Double
    public var shutdown: Double
    public init(startDelay: Double = 0, startRise: Double = 0, shutdown: Double = 0) {
        precondition(startDelay >= 0 && startRise >= 0 && shutdown >= 0, "transient times must not be negative")
        self.startDelay = startDelay
        self.startRise = startRise
        self.shutdown = shutdown
    }
}

/// When staging lights a solid motor (`Thruster.trigger`).
public enum SolidTrigger: Equatable {
    /// When its own part separates: a retro motor on the stage that leaves.
    case ownSeparation
    /// When staging event `n` separates, on the vessel that stays: an ullage
    /// motor on the stage that starts next.
    case event(Int)
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
    /// Unit direction of the force applied to the vessel (opposite to the
    /// exhaust), with the gimbal at null.
    public var direction: Vec3
    /// Gimbal actuators (none: a fixed nozzle). Each tilts the thrust in its
    /// own plane through `position`; see `GimbalActuator`.
    public var gimbal: [GimbalActuator]
    /// True for thrusters that take rotation and translation commands only
    /// while their part is the vessel's `activeStage` (the S-IVB APS, which
    /// was inactive during S-IC and S-II flight).
    public var activeStageOnly = false
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
    /// A solid motor: once lit (`ignite()`, or staging through `trigger`) it
    /// burns its grain to the end at full output and nothing stops or relights
    /// it; levels, groups and `isEnabled` do nothing after ignition, and a
    /// motor not enabled when lit is a dud. It needs a single feed, and no
    /// shutdown transient (its tank has nothing below empty to tail off on).
    public var isSolid = false
    /// When staging lights this solid; nil: only `ignite()` does.
    public var trigger: SolidTrigger?
    /// True once a solid has been lit, burnt out or not.
    public private(set) var isIgnited = false
    /// Change of performance over the burn; nil keeps `rating` throughout.
    public var schedule: PerformanceSchedule?
    /// Start and shutdown ramps; nil switches thrust on and off within a step.
    public var transients: EngineTransients?
    /// Seconds the engine has been commanded on since it last started (0
    /// while it is off). The schedule and the start ramp run on it.
    public private(set) var burnTime = 0.0
    /// What the engine delivered on the last step it was commanded on: the
    /// fraction of full output and the rating then. A shutdown ramp falls from it.
    private var lastOutput: (fraction: Double, rating: EngineRating)?
    /// Seconds since the engine stopped, while its shutdown ramp runs.
    private var shutdownElapsed: Double?
    /// Length of the last step the engine was commanded or ramping in: the
    /// ramps are sampled at the middle of the coming step, assuming it is as
    /// long. Zero after a coast, so a long coast step does not move the
    /// first sample of a start into its ramp.
    private var lastStep = 0.0

    /// `gimbal` holds at most two actuators, their tilts perpendicular to
    /// `direction` and to each other.
    public init(name: String, position: Vec3, direction: Vec3, rating: EngineRating, feed: PropellantFeed?,
                groups: Set<ThrusterGroup>, throttleRange: ClosedRange<Double> = 0...1,
                gimbal: [GimbalActuator] = []) {
        self.name = name
        self.position = position
        self.direction = direction.normalized
        self.rating = rating
        self.feed = feed
        self.groups = groups
        self.throttleRange = throttleRange
        self.gimbal = gimbal
        checkMixtureRatio()
        precondition(gimbal.count <= 2, "\(name): at most two gimbal actuators")
        for (i, a) in gimbal.enumerated() {
            precondition(abs(a.tilt.dot(self.direction)) < 1e-9, "\(name): gimbal tilt not perpendicular to the thrust")
            for b in gimbal[..<i] {
                precondition(abs(a.tilt.dot(b.tilt)) < 1e-9, "\(name): gimbal tilts not perpendicular")
            }
        }
    }

    /// Direction of the force with the gimbal's current angles: `direction`
    /// tilted by tan(angle) towards each actuator's `tilt`, so each angle is
    /// the deflection projected on that actuator's plane. Exactly `direction`
    /// at null.
    public var thrustDirection: Vec3 {
        guard gimbal.contains(where: { $0.angle != 0 }) else { return direction }
        var v = direction
        for a in gimbal where a.angle != 0 { v += a.tilt * tan(a.angle) }
        return v.normalized
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

    /// The rating now: `rating` with the schedule applied at the burn clock.
    public var currentRating: EngineRating { rating(atBurnTime: burnTime) }

    /// `rating` with the schedule applied at burn time `t`.
    public func rating(atBurnTime t: Double) -> EngineRating {
        guard let s = schedule else { return rating }
        let v = s.values(at: t)
        return rating.scaled(thrust: v.thrust, flow: v.flow, mixtureRatio: v.mixtureRatio)
    }

    public var maxThrustVacuum: Double { currentRating.thrustVacuum }
    public var ispVacuum: Double { currentRating.ispVacuum }
    public var ispSeaLevel: Double { currentRating.ispSeaLevel }
    /// The tank of a single-tank feed (nil for bipropellant engines).
    public var tank: PropellantTank? { if case .single(let t) = feed { return t } else { return nil } }

    /// True while every tank of the feed holds usable propellant.
    public var hasPropellant: Bool { feed.map { $0.tanks.allSatisfy { $0.usableMass > 0 } } ?? false }

    /// True while the controls command thrust: enabled, lit and fed, and not
    /// still decaying from a cutoff (a new command waits for the decay to
    /// end). Start and shutdown ramps aside, this is when the engine
    /// delivers thrust. A solid is commanded from ignition to burnout.
    public var isCommanded: Bool {
        (isSolid ? isIgnited : isEnabled && level > 0) && hasPropellant && shutdownElapsed == nil
    }

    /// Light a solid motor; false (and nothing happens) for a liquid engine,
    /// a dud (`isEnabled` false), an empty grain or one already lit.
    @discardableResult
    public func ignite() -> Bool {
        guard isSolid, isEnabled, !isIgnited, hasPropellant else { return false }
        precondition(tank != nil && (transients?.shutdown ?? 0) == 0,
                     "\(name): a solid motor needs a single feed and no shutdown ramp")
        isIgnited = true
        return true
    }

    /// Fraction of full output (level and transients) and the rating it
    /// applies to, this step; nil when the engine delivers nothing.
    var output: (fraction: Double, rating: EngineRating)? {
        if isCommanded {
            var f = isSolid ? 1 : level
            if let tr = transients, tr.startDelay + tr.startRise > 0 {
                let t = burnTime + lastStep / 2 - tr.startDelay
                f *= t <= 0 ? 0 : tr.startRise > 0 ? min(1, t / tr.startRise) : 1
            }
            return f > 0 ? (f, currentRating) : nil
        }
        guard let tr = transients, tr.shutdown > 0, let last = lastOutput else { return nil }
        let f = last.fraction * (1 - ((shutdownElapsed ?? 0) + lastStep / 2) / tr.shutdown)
        return f > 0 ? (f, last.rating) : nil
    }

    /// True while the engine delivers thrust, ramps included.
    public var isDelivering: Bool { output != nil }

    /// Move the burn clock and the ramps on by `dt`, after the step has used
    /// this step's output. Call once per step.
    func advanceTransients(dt: Double) {
        if isCommanded {
            lastOutput = output
            shutdownElapsed = nil
            burnTime += dt
            lastStep = dt
            return
        }
        burnTime = 0
        guard let tr = transients, tr.shutdown > 0, let last = lastOutput, last.fraction > 0 else {
            lastOutput = nil
            shutdownElapsed = nil
            lastStep = 0
            return
        }
        // A cutoff commanded before this step started the ramp with it; an
        // engine that ran out of propellant during it ran to its end.
        let ranOut = shutdownElapsed == nil && (isSolid ? isIgnited : isEnabled && level > 0)
        let e = shutdownElapsed.map { $0 + dt } ?? (ranOut ? 0 : dt)
        if e >= tr.shutdown {
            lastOutput = nil
            shutdownElapsed = nil
            lastStep = 0
        } else {
            shutdownElapsed = e
            lastStep = dt
        }
    }

    /// Level for a positive command, clamped into `throttleRange`.
    func clampedLevel(_ c: Double) -> Double {
        min(throttleRange.upperBound, max(throttleRange.lowerBound, c))
    }

    /// Delivered thrust (N) at ambient pressure `p` given sea-level pressure `p0`.
    public func thrust(ambientPressure p: Double, seaLevelPressure p0: Double) -> Double {
        guard let (f, r) = output else { return 0 }
        let loss = p0 > 0 ? (1 - r.ispSeaLevel / r.ispVacuum) * p / p0 : 0
        return f * r.thrustVacuum * max(0, 1 - loss)
    }

    /// Propellant mass flow (kg/s) this step.
    public var massFlow: Double {
        guard let (f, r) = output else { return 0 }
        return f * r.massFlow
    }

    /// Draw `massFlow * dt` from the feed, never below a tank's unusable mass
    /// (to zero during a shutdown ramp, whose propellant is the tail-off
    /// residual); a bipropellant draw is scaled so the mixture ratio stays
    /// exact. A tank that limits the draw ends exactly at its floor.
    func draw(dt: Double) { draw(dt: dt, output: output, commanded: isCommanded) }

    /// `draw(dt:)` with this step's `output` and `isCommanded` taken before
    /// any engine drew: one engine emptying a shared tank then neither
    /// starts another's ramp within the step nor lets it draw below the
    /// unusable mass.
    func draw(dt: Double, output: (fraction: Double, rating: EngineRating)?, commanded: Bool) {
        guard let (frac, r) = output, let feed else { return }
        let m = frac * r.massFlow * dt
        guard m > 0 else { return }
        let tailOff = !commanded
        func floor(_ t: PropellantTank) -> Double { tailOff ? 0 : t.unusableMass }
        switch feed {
        case .single(let t):
            t.mass = max(floor(t), t.mass - m)
            // A solid's last step ends at burnout: rounding must not leave a
            // sliver of grain to burn on into the next step.
            if isSolid, t.mass - floor(t) < 1e-9 * m { t.mass = floor(t) }
        case let .bipropellant(o, f):
            let ratio = r.mixtureRatio ?? 0
            let ox = m * ratio / (1 + ratio), fu = m / (1 + ratio)
            let sOx = (o.mass - floor(o)) / ox, sFu = (f.mass - floor(f)) / fu
            let s = max(0, min(1, sOx, sFu))
            o.mass = s == sOx ? floor(o) : o.mass - ox * s
            f.mass = s == sFu ? floor(f) : f.mass - fu * s
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
    /// Relative speed (m/s) springs or ordnance give the parts of its staging
    /// event as they separate; 0 when solid motors do the work.
    public var separationSpeed = 1.0

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
