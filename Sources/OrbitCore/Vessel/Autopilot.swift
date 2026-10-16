import Foundation

/// Orbiter-style attitude modes. Axes flown by the rotation groups (RCS, APS)
/// use the M0 law; axes flown by gimballed engines use the attitude law of
/// `TVCGains`.
public enum AttitudeAutopilot: String, CaseIterable, Codable {
    /// Rate damping only, on every axis (Orbiter-like): it does not hold the
    /// attitude against a steady torque such as an engine out.
    case killRotation = "KillRot"
    case prograde = "Prograde"
    case retrograde = "Retrograde"
    case normal = "Normal"
    case antinormal = "Antinormal"
    case radialOut = "Radial+"
    case radialIn = "Radial-"
    case horizonLevel = "Hold Level"
    /// Hold `Vessel.attitudeCommand`, or the attitude captured when selected
    /// or when manual input ends. With gimbals flying, the hold first damps
    /// the turn and captures once their law can take over without saturating
    /// (`Vessel.holdCanCapture`); it steers to either attitude only from
    /// then. The captured attitude lies short of where the turn stops by up
    /// to the law's swing, about 0.4 alpha rad with the default gains (alpha
    /// the gimbal angular acceleration: 1.8° in pitch and 12° in roll at
    /// liftoff).
    case attitudeHold = "Hold Att"

    /// Desired direction of the vessel +x axis (ICRF), or nil for rate damping
    /// (and for `.attitudeHold`, which targets a full attitude).
    func target(for v: Vessel) -> Vec3? {
        let r = v.position, vel = v.velocity
        switch self {
        case .killRotation, .attitudeHold: return nil
        case .prograde: return vel.normalized
        case .retrograde: return -vel.normalized
        case .normal: return r.cross(vel).normalized
        case .antinormal: return -r.cross(vel).normalized
        case .radialOut: return r.normalized
        case .radialIn: return -r.normalized
        case .horizonLevel:
            let up = r.normalized
            let horiz = vel - up * vel.dot(up)
            return horiz.normalized
        }
    }
}

/// An attitude to hold (body -> ICRF) and its rate (ICRF, rad/s), which the
/// gimbal law feeds forward. The seam for the IU flight program, which sets
/// `.attitudeHold` and writes this every step.
public struct AttitudeCommand: Equatable {
    public var attitude: Quat
    public var rate: Vec3
    public init(attitude: Quat, rate: Vec3 = .zero) {
        self.attitude = attitude
        self.rate = rate
    }
}

/// Attitude law on gimbal-flown axes: c = (Kp e + Kd (w_ref - w)) / alpha per
/// axis, with Kp = wn^2 and Kd = 2 zeta wn, tracking a reference that moves
/// towards the target at no more than `maxSlewRate` (and half the weakest
/// gimbal axis's acceleration / Kd). Normalising by alpha = authority /
/// inertia keeps the loop the same at every flight condition.
public struct TVCGains: Equatable {
    public var naturalFrequency: Double   // rad/s
    public var dampingRatio: Double
    public var maxSlewRate: Double        // rad/s
    public init(naturalFrequency: Double = 0.8, dampingRatio: Double = 0.8, maxSlewRate: Double = 0.1) {
        self.naturalFrequency = naturalFrequency
        self.dampingRatio = dampingRatio
        self.maxSlewRate = maxSlewRate
    }
}

/// Rotation vector of `q` (axis times angle, |angle| <= pi).
func rotationVector(_ q: Quat) -> Vec3 {
    let s = q.w < 0 ? -1.0 : 1.0
    let v = Vec3(q.x * s, q.y * s, q.z * s), n = v.length
    return n < 1e-15 ? .zero : v * (2 * atan2(n, q.w * s) / n)
}

/// Shortest rotation taking unit vector `a` to `b`; a half turn about
/// `fallbackAxis` when they are opposite.
func shortestTurn(from a: Vec3, to b: Vec3, fallbackAxis: Vec3) -> Quat {
    let c = a.cross(b), angle = atan2(c.length, a.dot(b))
    if c.length > 1e-12 { return Quat(axis: c, angle: angle) }
    return angle > 1 ? Quat(axis: fallbackAxis, angle: .pi) : .identity
}

extension Vessel {
    /// Rotation command that steers towards the autopilot target (or nulls rates).
    func autopilotCommand(_ mode: AttitudeAutopilot) -> RotationCommand {
        autopilotCommand(mode, control: controlAllocation())
    }

    /// Rotation command for this step's allocation `control`.
    func autopilotCommand(_ mode: AttitudeAutopilot, control: ControlAllocation) -> RotationCommand {
        let inertia = self.inertia
        let authority = control.authority
        let byGimbal = control.gimbalAxes
        let anyGimbal = byGimbal.roll || byGimbal.pitch || byGimbal.yaw
        let alpha = Vec3(authority.x / max(inertia[0, 0], 1e-6),
                         authority.y / max(inertia[1, 1], 1e-6),
                         authority.z / max(inertia[2, 2], 1e-6))
        guard alpha.x > 0 || alpha.y > 0 || alpha.z > 0 else {
            referenceAttitude = nil
            referenceRate = .zero
            return RotationCommand()
        }

        // Gains of the gimbal law (below).
        let g = tvcGains
        let wn = min(g.naturalFrequency, 3 / max(control.slewTime, 1e-9))   // within the actuators' reach
        let kp = wn * wn, kd = 2 * g.dampingRatio * wn, kr = wn / (2 * g.dampingRatio)

        // Pointing error: the M0 target direction (body axis and angle), or
        // the full attitude error of the hold. With gimbals flying, the hold
        // only damps rates until `holdCanCapture`: captured while the
        // actuators still push the turn on, or with more damping to do than
        // they have travel, it would swing back past the capture with the
        // actuators on their stops.
        var pointing: (axis: Vec3, angle: Double)?
        if mode == .attitudeHold {
            if landed != nil || heldAttitude == nil && holdCanCapture(control, alpha: alpha, kd: kd) {
                heldAttitude = attitude
            }
            if let held = heldAttitude {
                let e = rotationVector(attitude.conjugate * (attitudeCommand?.attitude ?? held))
                let angle = e.length
                pointing = (angle > 0 ? e / angle : .zero, angle)
            }
        } else if let target = mode.target(for: self), target.lengthSquared > 0.5 {
            let tb = attitude.inverseRotate(target)
            var axis = Vec3.unitX.cross(tb)
            let angle = atan2(axis.length, tb.x)
            if axis.length < 1e-9 { axis = angle > 1 ? .unitY : .zero } else { axis = axis.normalized }
            pointing = (axis, angle)
        }

        // Axes flown by the rotation groups: the M0 law, a bang-bang-like
        // approach rate that can still be stopped in time, and a 0.5 s rate
        // loop. The approach uses the weakest group axis the turn involves:
        // pitch and yaw (M0's pointing modes turn the nose), and roll too in
        // the hold. With no group axis left it is M0's pitch/yaw value.
        var desired = Vec3.zero
        if let (axis, angle) = pointing {
            let involved = [(!byGimbal.roll && mode == .attitudeHold, alpha.x), (!byGimbal.pitch, alpha.y),
                            (!byGimbal.yaw, alpha.z)]
            let a = max(involved.filter(\.0).map(\.1).min() ?? min(alpha.y, alpha.z), 1e-6)
            let rate = min(0.1, (2 * a * angle * 0.5).squareRoot())
            desired = axis * rate
            if angle < 0.002 { desired = .zero }
        }
        let err = desired - angularVelocity
        let response = 0.5  // s
        func axisCommand(_ e: Double, _ a: Double) -> Double {
            guard a > 0 else { return 0 }
            let c = e / (a * response)
            if abs(c) < 0.02 && abs(e) < 2e-4 { return 0 }
            return max(-1, min(1, c))
        }
        var command = RotationCommand(roll: axisCommand(err.x, alpha.x),
                                      pitch: axisCommand(err.y, alpha.y),
                                      yaw: axisCommand(err.z, alpha.z))
        guard anyGimbal else {
            referenceAttitude = nil
            referenceRate = .zero
            return command
        }

        // Axes flown by the gimbals: PD on the error to a rate-limited
        // reference, with the reference rate fed forward, normalised by alpha.
        // The M0 law does not suit them: it assumes braking is available at
        // once, while the actuators take about a second to reverse.
        if referenceAttitude == nil || landed != nil { referenceAttitude = attitude }
        var reference = referenceAttitude!
        var goal: Quat?
        var goalRate = Vec3.zero
        if mode == .attitudeHold, let held = heldAttitude {
            goal = attitudeCommand?.attitude ?? held
            goalRate = attitudeCommand?.rate ?? .zero
            if !byGimbal.roll {
                // The groups fly roll straight to the goal (the S-IVB APS
                // during a burn), so the gimbals track the nose only: the
                // reference takes the vehicle's roll and turns its nose the
                // shortest way to the goal's. A roll change then neither
                // slows the nose's slew nor mixes into its error. A nose
                // exactly reversed turns about the goal's own half-turn axis
                // (perpendicular to the nose), so it arrives with the goal's
                // roll, as it does for a goal a hair short of reversed.
                let nose = reference.rotate(.unitX)
                reference = shortestTurn(from: attitude.rotate(.unitX), to: nose,
                                         fallbackAxis: attitude.rotate(.unitY)) * attitude
                referenceAttitude = reference
                let turn = rotationVector(goal! * reference.conjugate), across = turn - nose * turn.dot(nose)
                goal = shortestTurn(from: nose, to: goal!.rotate(.unitX),
                                    fallbackAxis: across.length > 1e-9 ? across : reference.rotate(.unitY)) * reference
            }
        } else if let (axis, angle) = pointing, angle > 0 {
            goal = Quat(axis: attitude.rotate(axis), angle: angle) * attitude   // the nose's shortest turn
        }
        var e = Vec3.zero, wReference = Vec3.zero
        if let goal {
            // Slews start with at most half the weakest gimbal axis's authority.
            let gimbalAlpha = [(byGimbal.roll, alpha.x), (byGimbal.pitch, alpha.y), (byGimbal.yaw, alpha.z)]
                .filter(\.0).map(\.1)
            let slew = min(g.maxSlewRate, 0.5 * (gimbalAlpha.min() ?? 0) / kd)
            let r = rotationVector(goal * reference.conjugate)
            let n = r.length
            referenceRate = goalRate + (n > 0 ? r * (min(slew, kr * n) / n) : .zero)
            e = rotationVector(attitude.conjugate * reference)
            wReference = attitude.inverseRotate(referenceRate)
            if mode != .attitudeHold || !byGimbal.roll { e.x = 0; wReference.x = 0 }   // roll free, as M0
        } else {
            // Kill rotation, or a hold not yet captured: rate damping only.
            referenceAttitude = attitude
            referenceRate = .zero
        }
        let w = angularVelocity
        func law(_ ek: Double, _ wr: Double, _ wk: Double, _ ak: Double) -> Double {
            ak > 0 ? max(-1, min(1, (kp * ek + kd * (wr - wk)) / ak)) : 0
        }
        if byGimbal.roll { command.roll = law(e.x, wReference.x, w.x, alpha.x) }
        if byGimbal.pitch { command.pitch = law(e.y, wReference.y, w.y, alpha.y) }
        if byGimbal.yaw { command.yaw = law(e.z, wReference.z, w.z, alpha.z) }
        return command
    }

    /// Whether `.attitudeHold` can capture the attitude now: at once when no
    /// axis is gimbal-flown, otherwise once the gimbal law can take over
    /// without saturating. The actuators must no longer push the turn on
    /// (after manual input or another mode's slew they take up to a second
    /// to unwind, and the turn speeds up meanwhile), and the law's first
    /// command, rate damping relative to `attitudeCommand`'s rate, must fit
    /// their travel on every axis at once (roll shares the actuators of
    /// pitch and yaw). A steady drift that rate damping balances (an engine
    /// out under kill rotation) passes, so it captures at once. A slew to a
    /// distant `attitudeCommand` can still start on the stops: leaving room
    /// here for its feed-forward would never capture such a drift.
    func holdCanCapture(_ control: ControlAllocation, alpha: Vec3, kd: Double) -> Bool {
        let flown = control.gimbalAxes
        guard flown.roll || flown.pitch || flown.yaw else { return true }
        var push = Vec3.zero   // torque of the actuators' deflection from their bias, N m
        for ch in control.channels {
            let a = ch.thruster.gimbal[ch.index]
            push += ch.torque * (a.angle - a.bias)
        }
        let w = angularVelocity - attitude.inverseRotate(attitudeCommand?.rate ?? .zero)
        let authority = control.authority
        /// The damping command on one axis, or nil while the actuators push its turn on.
        func damping(_ on: Bool, _ wk: Double, _ pk: Double, _ ak: Double, _ alphak: Double) -> Double? {
            guard on else { return 0 }
            return pk * wk > 0 && abs(pk) > 1e-3 * ak ? nil : -kd * wk / alphak
        }
        guard let roll = damping(flown.roll, w.x, push.x, authority.x, alpha.x),
              let pitch = damping(flown.pitch, w.y, push.y, authority.y, alpha.y),
              let yaw = damping(flown.yaw, w.z, push.z, authority.z, alpha.z),
              max(abs(roll), abs(pitch), abs(yaw)) <= 1 else { return false }
        return control.deflections(Vec3(roll, pitch, yaw)).scale >= 1 - 1e-9
    }

    /// Gimbal actuators and the attitude reference over a step of `dt`, with
    /// this step's commands held.
    func advanceControlState(dt: Double) {
        advanceActuators(dt: dt)
        if let r = referenceAttitude, referenceRate != .zero {
            referenceAttitude = (Quat(axis: referenceRate, angle: referenceRate.length * dt) * r).normalized
        }
    }

    /// Forget the hold and the reference (a mode change, or manual input
    /// moving the vessel): the hold captures afresh.
    func resetAttitudeReference() {
        heldAttitude = nil
        referenceAttitude = nil
        referenceRate = .zero
    }
}
