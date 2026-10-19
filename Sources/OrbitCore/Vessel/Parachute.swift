import Foundation

/// A cluster of identical parachutes packed in a part (`VesselPart.parachutes`).
///
/// Once deployed (`deploy(at:)`) the cluster pulls on the vessel at its
/// `attachPoint`, the riser confluence, with the drag of the air velocity
/// there, the vessel's rotation (ω × r) included:
///
///     F = -½ ρ (C_D S) |u| u,   u = v_air + ω × r,
///
/// so a canopy above the centre of mass damps the swing with no extra
/// coefficient, and its torque is r × F. The canopy's mass stays with its
/// part, at the stowed station: the canopies are force (and visuals) only.
///
/// The drag area follows the reefing schedule from deployment: each stage's
/// area for its duration, then full open, every change of area ramped over
/// `inflationTime` (a canopy inflates over a second or two; the ramp also
/// keeps the opening shock smooth enough for the 0.02 s steps).
public final class Parachute {
    public enum State: Equatable {
        case stowed
        /// Inflating, before the first reefing stage.
        case deploying
        /// In reefing stage `n` (1 is the first).
        case reefed(Int)
        case open
        /// Cut away from the vessel.
        case released
    }

    /// One reefing stage: the drag area of one canopy while reefed (m^2) and
    /// how long the stage lasts (s).
    public struct Reefing: Equatable {
        public var dragArea: Double
        public var duration: Double
        public init(dragArea: Double, duration: Double) {
            self.dragArea = dragArea; self.duration = duration
        }
    }

    public let name: String
    /// Canopies in the cluster.
    public var count: Int
    /// Nominal diameter of one canopy, m.
    public var diameter: Double
    /// Drag area C_D S of one fully open canopy, m^2.
    public var dragArea: Double
    /// Where the risers meet (the confluence), part frame, m.
    public var attachPoint: Vec3
    public internal(set) var state = State.stowed
    /// The reefing stages from deployment, in order; empty for a canopy that
    /// opens in one go.
    public var reefing: [Reefing] = []
    /// Seconds each change of drag area takes, from deployment and at each
    /// disreef.
    public var inflationTime = 1.0
    /// Fraction of the canopies' summed drag area a cluster of `n` open
    /// canopies delivers (their interference), by `n`; 1 when not given.
    public var clusterEfficiency: [Int: Double] = [:]
    /// When the cluster was deployed (line stretch, which starts the reefing
    /// cutters' timers); nil while stowed.
    public private(set) var deployedAt: Epoch?
    /// The cluster's effective drag area at the end of the last step, m^2.
    public internal(set) var currentDragArea = 0.0

    public init(name: String, count: Int, diameter: Double, dragArea: Double, attachPoint: Vec3) {
        self.name = name
        self.count = count
        self.diameter = diameter
        self.dragArea = dragArea
        self.attachPoint = attachPoint
    }

    /// Deploy the cluster at `t`; nothing happens unless it is stowed.
    public func deploy(at t: Epoch) {
        guard state == .stowed else { return }
        deployedAt = t
        update(at: t)
    }

    /// Cut the cluster away: it pulls no more.
    public func release() {
        state = .released
        currentDragArea = 0
    }

    public var isDeployed: Bool { deployedAt != nil && state != .released }

    /// The cluster's effective drag area C_D S at `t`, m^2: zero stowed,
    /// released or before deployment.
    public func effectiveDragArea(at t: Epoch) -> Double {
        guard let t0 = deployedAt, state != .released else { return 0 }
        let s = t - t0
        guard s > 0 else { return 0 }
        // Areas per canopy along the schedule: from 0 to each stage's, then
        // to full open, each change starting at its stage's start.
        var from = 0.0, start = 0.0
        var area = dragArea
        for stage in reefing {
            if s < start + stage.duration {
                area = stage.dragArea
                break
            }
            from = stage.dragArea
            start += stage.duration
        }
        // `start` is where the change to `area` began; before that the
        // previous stage ramps towards its own area, which a stage at least
        // `inflationTime` long has reached.
        let ramp = inflationTime > 0 ? min(1, (s - start) / inflationTime) : 1
        let perCanopy = from + (area - from) * ramp
        return Double(count) * perCanopy * (clusterEfficiency[count] ?? 1)
    }

    /// Times after `t` where the drag area's schedule has a corner (a stage
    /// starts, or a ramp ends), so that steps can end on them.
    public func scheduleCorners(after t: Epoch) -> [Epoch] {
        guard let t0 = deployedAt, state != .released else { return [] }
        var corners: [Double] = []
        var start = 0.0
        for stage in reefing {
            corners += [start, start + inflationTime]
            start += stage.duration
        }
        corners += [start, start + inflationTime]
        return corners.map { t0 + $0 }.filter { $0 > t }
    }

    /// Bring `state` and `currentDragArea` to time `t`.
    func update(at t: Epoch) {
        guard let t0 = deployedAt, state != .released else { return }
        currentDragArea = effectiveDragArea(at: t)
        let s = t - t0
        var start = 0.0
        for (i, stage) in reefing.enumerated() {
            if s < start + stage.duration {
                state = i == 0 && s < inflationTime ? .deploying : .reefed(i + 1)
                return
            }
            start += stage.duration
        }
        state = reefing.isEmpty && s < inflationTime ? .deploying : .open
    }

    /// Force and torque on the vessel (body axes, about the centre of mass),
    /// at the effective drag area `area`, for an attach point at `r` from the
    /// centre of mass (body axes): the air velocity of the centre of mass is
    /// `air` (body axes), the body rate `omega`, the air density `density`.
    static func loads(area: Double, at r: Vec3, air: Vec3, omega: Vec3,
                      density: Double) -> (force: Vec3, torque: Vec3) {
        let u = air + omega.cross(r)
        let force = u * (-0.5 * density * area * u.length)
        return (force, r.cross(force))
    }
}

extension Vessel {
    /// The deployed parachutes' force and torque (body axes, about the centre
    /// of mass) at `t`, for the air velocity `air` of the centre of mass and
    /// the body rate `omega` (body axes), in air of `density`.
    func parachuteLoads(at t: Epoch, air: Vec3, omega: Vec3, density: Double) -> (force: Vec3, torque: Vec3) {
        var force = Vec3.zero, torque = Vec3.zero
        let com = centerOfMass
        for part in parts {
            for chute in part.parachutes where chute.isDeployed {
                let area = chute.effectiveDragArea(at: t)
                guard area > 0 else { continue }
                let l = Parachute.loads(area: area, at: part.offset + chute.attachPoint - com, air: air,
                                        omega: omega, density: density)
                force += l.force
                torque += l.torque
            }
        }
        return (force, torque)
    }
}
