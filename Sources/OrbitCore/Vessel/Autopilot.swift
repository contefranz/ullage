import Foundation

/// Orbiter-style attitude modes. Axes flown by the rotation groups (RCS, APS)
/// use the vessel's `phasePlane` law if it has one (kill rotation excepted,
/// and roll in the pointing modes, which set no roll attitude and keep M0's
/// rate damping), otherwise the M0 law. Axes flown by gimballed engines use the attitude law
/// of `TVCGains`, or in the hold the flight control computer's law when the
/// vessel has `fccGains` and an `attitudeCommand` (the Saturn's IU).
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
    /// or when manual input ends. With gimbals flying the `TVCGains` law, the
    /// hold first damps the turn and captures once that law can take over
    /// without saturating (`Vessel.holdCanCapture`); it steers to either
    /// attitude only from then. The captured attitude lies short of where the
    /// turn stops by up to the law's swing, about 0.4 alpha rad with the
    /// default gains (alpha the gimbal angular acceleration: 1.8° in pitch
    /// and 12° in roll at liftoff). Under the FCC law it captures at once.
    /// With a flight program writing `attitudeCommand` (the Saturn's IU),
    /// selecting it hands the attitude back to the program.
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

/// The Saturn flight control computer's attitude law (TVC datasheet §7.2):
/// on each gimbal-flown axis a thrust-vector deflection beta = a0 e - a1 w
/// (rad), with e the attitude error to the command (body axes) and w the
/// body rate from the rate gyros. Proportional-derivative with no integral
/// term and no feed-forward of the command's rate, so a ramp is tracked a1/a0
/// times its rate behind. Beta is each engine's deflection: per actuator in
/// pitch and yaw, tangential in roll. The IU switches the gains by flight
/// phase; roll has its own pair, the pitch and yaw one unless given.
public struct FCCGains: Equatable {
    /// Attitude gain in pitch and yaw, deg of deflection per deg of error.
    public var a0: Double
    /// Rate gain in pitch and yaw, deg of deflection per deg/s of body rate (s).
    public var a1: Double
    /// The same two gains in roll.
    public var rollA0: Double
    public var rollA1: Double
    public init(a0: Double, a1: Double, rollA0: Double? = nil, rollA1: Double? = nil) {
        self.a0 = a0
        self.a1 = a1
        self.rollA0 = rollA0 ?? a0
        self.rollA1 = rollA1 ?? a1
    }
}

/// On/off phase-plane control of the rotation groups, the S-IVB APS logic
/// (TVC datasheet §7.2): on each group-flown axis the attitude error, clipped
/// to `errorLimit`, less `rateGain` times the body rate, fires the axis full
/// on in its direction when it leaves ±`deadband`, for at least
/// `minimumOnTime`. The clip bounds the manoeuvre rate at about
/// (limit - deadband) / rateGain. No hysteresis.
public struct PhasePlaneLaw: Equatable {
    public var deadband: Double         // rad
    public var errorLimit: Vec3         // rad: roll, pitch, yaw
    public var rateGain: Double         // s
    public var minimumOnTime: Double    // s
    public init(deadband: Double, errorLimit: Vec3, rateGain: Double, minimumOnTime: Double) {
        self.deadband = deadband
        self.errorLimit = errorLimit
        self.rateGain = rateGain
        self.minimumOnTime = minimumOnTime
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

        // The FCC law flies the gimbals when the IU commands the hold.
        let fcc = mode == .attitudeHold && attitudeCommand != nil && anyGimbal ? fccGains : nil

        // Gains of the gimbal law (below).
        let g = tvcGains
        let wn = min(g.naturalFrequency, 3 / max(control.slewTime, 1e-9))   // within the actuators' reach
        let kp = wn * wn, kd = 2 * g.dampingRatio * wn, kr = wn / (2 * g.dampingRatio)

        // Pointing error: the M0 target direction (body axis and angle), or
        // the full attitude error of the hold. With gimbals flying, the hold
        // only damps rates until `holdCanCapture`: captured while the
        // actuators still push the turn on, or with more damping to do than
        // they have travel, it would swing back past the capture with the
        // actuators on their stops. Under the FCC law it captures at once:
        // that law steers to the command whatever the vehicle is doing.
        var pointing: (axis: Vec3, angle: Double)?
        if mode == .attitudeHold {
            if landed != nil || heldAttitude == nil && (fcc != nil || holdCanCapture(control, alpha: alpha, kd: kd)) {
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

        // Axes flown by the rotation groups: the phase-plane law if the
        // vessel has one (kill rotation excepted), otherwise the M0 law, a
        // bang-bang-like approach rate that can still be stopped in time, and
        // a 0.5 s rate loop. The approach uses the weakest group axis the
        // turn involves: pitch and yaw (M0's pointing modes turn the nose),
        // and roll too in the hold. With no group axis left it is M0's
        // pitch/yaw value.
        let response = 0.5  // s
        /// M0's command on one axis for the rate error `e`: a 0.5 s rate loop.
        func axisCommand(_ e: Double, _ a: Double) -> Double {
            guard a > 0 else { return 0 }
            let c = e / (a * response)
            if abs(c) < 0.02 && abs(e) < 2e-4 { return 0 }
            return max(-1, min(1, c))
        }
        var command: RotationCommand
        if let law = phasePlane, mode != .killRotation {
            // The pointing modes set no roll attitude, so roll keeps M0's rate
            // damping: the phase plane alone would leave rates under its
            // dead band / rate gain (0.2°/s on the Saturn's APS) undamped.
            let holdsRoll = mode == .attitudeHold
            // The error's rate while coasting: the command's rate less the
            // body's (the pointing modes' targets taken as fixed).
            let commandRate = holdsRoll ? attitude.inverseRotate(attitudeCommand?.rate ?? .zero) : .zero
            command = phasePlaneCommand(law, error: pointing.map { $0.axis * $0.angle } ?? .zero,
                                        errorRate: commandRate - angularVelocity,
                                        flown: (!byGimbal.roll && holdsRoll, !byGimbal.pitch, !byGimbal.yaw),
                                        alpha: alpha)
            if !holdsRoll && !byGimbal.roll { command.roll = axisCommand(-angularVelocity.x, alpha.x) }
        } else {
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
            command = RotationCommand(roll: axisCommand(err.x, alpha.x), pitch: axisCommand(err.y, alpha.y),
                                      yaw: axisCommand(err.z, alpha.z))
        }
        guard anyGimbal else {
            referenceAttitude = nil
            referenceRate = .zero
            return command
        }

        // The FCC law: deflection straight from the error to the command and
        // the body rate, with no reference (a later switch to the gains law
        // starts from the attitude then).
        if let fcc, let goal = attitudeCommand?.attitude {
            referenceAttitude = nil
            referenceRate = .zero
            let e = rotationVector(attitude.conjugate * goal), w = angularVelocity
            let per = control.deflectionPerCommand
            func law(_ a0: Double, _ a1: Double, _ ek: Double, _ wk: Double, _ pk: Double) -> Double {
                pk > 0 ? max(-1, min(1, (a0 * ek - a1 * wk) / pk)) : 0
            }
            if byGimbal.roll { command.roll = law(fcc.rollA0, fcc.rollA1, e.x, w.x, per.x) }
            if byGimbal.pitch { command.pitch = law(fcc.a0, fcc.a1, e.y, w.y, per.y) }
            if byGimbal.yaw { command.yaw = law(fcc.a0, fcc.a1, e.z, w.z, per.z) }
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

    /// The phase-plane law on the `flown` axes with authority (`alpha` > 0),
    /// for the attitude error `error` (body axes, rad): -1, 0 or +1 per axis.
    /// A pulse runs for at least the law's minimum on-time. It also predicts,
    /// from the error's rate `errorRate` and a steady body rate, when a
    /// coasting axis will reach the switching line (`groupSwitch`), so the
    /// simulation can end a step there: the law decides once a step.
    func phasePlaneCommand(_ law: PhasePlaneLaw, error: Vec3, errorRate: Vec3, flown: (Bool, Bool, Bool),
                           alpha: Vec3) -> RotationCommand {
        let on = [flown.0 && alpha.x > 0, flown.1 && alpha.y > 0, flown.2 && alpha.z > 0]
        let e = [error.x, error.y, error.z], w = [angularVelocity.x, angularVelocity.y, angularVelocity.z]
        let de = [errorRate.x, errorRate.y, errorRate.z]
        let limit = [law.errorLimit.x, law.errorLimit.y, law.errorLimit.z]
        var direction = [groupPulse.direction.x, groupPulse.direction.y, groupPulse.direction.z]
        var remaining = [groupPulse.remaining.x, groupPulse.remaining.y, groupPulse.remaining.z]
        var c = [0.0, 0.0, 0.0]
        var next = Double.infinity
        for k in 0..<3 {
            guard on[k] else {
                remaining[k] = 0
                continue
            }
            if remaining[k] > 1e-9 {
                c[k] = direction[k]
                continue
            }
            let s = max(-limit[k], min(limit[k], e[k])) - law.rateGain * w[k]
            c[k] = s > law.deadband ? 1 : s < -law.deadband ? -1 : 0
            direction[k] = c[k]
            remaining[k] = c[k] != 0 ? law.minimumOnTime : 0
            guard c[k] == 0, abs(de[k]) > 1e-12 else { continue }
            if abs(e[k]) >= limit[k] {
                // The clip holds s until the error comes back inside the limit.
                if e[k] * de[k] < 0 { next = min(next, (abs(e[k]) - limit[k]) / abs(de[k])) }
            } else {
                next = min(next, max(0, ((de[k] > 0 ? law.deadband : -law.deadband) - s) / de[k]))
            }
        }
        groupPulse = (Vec3(direction[0], direction[1], direction[2]), Vec3(remaining[0], remaining[1], remaining[2]))
        groupSwitch = next
        return RotationCommand(roll: c[0], pitch: c[1], yaw: c[2])
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
        let r = groupPulse.remaining
        groupPulse.remaining = Vec3(max(0, r.x - dt), max(0, r.y - dt), max(0, r.z - dt))
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
