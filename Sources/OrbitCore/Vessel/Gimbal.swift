import Foundation

/// One servo actuator of a gimballed engine. It tilts the thrust in the plane
/// of the engine's null `direction` and `tilt`: at angle θ the force leans
/// towards `tilt` by θ in that plane. An engine has one or two, at right
/// angles, each with its own range (a square deflection pattern).
public struct GimbalActuator: Equatable {
    /// Unit vector, part frame, perpendicular to the thruster's null direction.
    public var tilt: Vec3
    /// Deflection limit about null, rad: no command or angle leaves it. For
    /// the Saturn engines, the published control limit (the F-1 actuator
    /// stop, 5.25°, lies just outside it: datasheet §7.1).
    public var range: ClosedRange<Double>
    /// Slew-rate limit, rad/s.
    public var rateLimit: Double
    /// First-order servo lag, s (0: pure rate-limited tracking).
    public var timeConstant: Double
    /// Null offset of the control commands, rad (the S-IC outboard cant, which
    /// the flight program sets). Control deflections are added to it.
    public var bias = 0.0
    /// Angle now, rad.
    public internal(set) var angle = 0.0
    /// Angle commanded this step (inside `range`), rad.
    public internal(set) var command = 0.0

    public init(tilt: Vec3, range: ClosedRange<Double>, rateLimit: Double, timeConstant: Double = 0) {
        precondition(tilt.length > 0, "gimbal tilt must not be zero")
        precondition(range.contains(0), "gimbal range must contain null")
        precondition(rateLimit > 0 && timeConstant >= 0, "gimbal rate limit must be positive, lag not negative")
        self.tilt = tilt.normalized
        self.range = range
        self.rateLimit = rateLimit
        self.timeConstant = timeConstant
    }

    /// Symmetric travel ±`limit`.
    public init(tilt: Vec3, limit: Double, rateLimit: Double, timeConstant: Double = 0) {
        self.init(tilt: tilt, range: -limit...limit, rateLimit: rateLimit, timeConstant: timeConstant)
    }

    /// Travel left on the tighter side of the bias, rad.
    public var travel: Double { max(0, min(range.upperBound - bias, bias - range.lowerBound)) }

    mutating func setCommand(_ c: Double) { command = min(range.upperBound, max(range.lowerBound, c)) }

    /// Move `angle` towards `command` for `dt` s with the command held.
    mutating func advance(dt: Double) {
        guard dt > 0, angle != command else { return }
        angle = Self.response(from: angle, to: command, dt: dt, rate: rateLimit, lag: timeConstant)
    }

    /// Exact solution of x' = clamp((c - x) / tau, -rate, rate) after `dt`
    /// from x0, for any `dt`: a ramp at the rate limit while the error
    /// exceeds rate * tau, then an exponential approach.
    static func response(from x0: Double, to c: Double, dt: Double, rate: Double, lag tau: Double) -> Double {
        let e = c - x0, sign = e > 0 ? 1.0 : -1.0
        guard tau > 0 else { return abs(e) <= rate * dt ? c : x0 + sign * rate * dt }
        var x = x0, t = dt
        let band = rate * tau           // below this error the lag is linear
        if abs(e) > band {
            let ramp = (abs(e) - band) / rate
            if ramp >= t { return x + sign * rate * t }
            x += sign * rate * ramp
            t -= ramp
        }
        return c - (c - x) * exp(-t / tau)
    }
}

/// How this step's rotation commands reach the vessel: the minimum-norm
/// allocation of a torque request to the actuators of every firing gimballed
/// engine (linearised at null, in units of each actuator's travel), and the
/// authority of the rotation groups. Computed once per control step, so the
/// remaining engines re-mix after an engine out (the Saturn's flight control
/// computer had fixed mixing).
struct ControlAllocation {
    struct Channel {
        let thruster: Thruster
        let index: Int
        /// Deflection (rad) per unit command on each axis (roll, pitch, yaw).
        let perCommand: Vec3
        /// Torque per radian of deflection from the bias, N m (linearised at null).
        let torque: Vec3
    }
    var channels: [Channel] = []
    /// Torque about each body axis at a full single-axis gimbal command, N m;
    /// 0 where the gimbals cannot act alone.
    var gimbalAuthority = Vec3.zero
    /// Torque authority of the rotation groups (M0's sum), N m.
    var groupAuthority = Vec3.zero
    /// Longest null-to-stop time of a firing actuator, lag included, s.
    var slewTime = 0.0

    /// Axes the gimbals fly: those where they beat the rotation groups.
    var gimbalAxes: (roll: Bool, pitch: Bool, yaw: Bool) {
        (gimbalAuthority.x > groupAuthority.x, gimbalAuthority.y > groupAuthority.y,
         gimbalAuthority.z > groupAuthority.z)
    }
    /// Authority of whichever effector flies each axis, N m.
    var authority: Vec3 {
        Vec3(max(gimbalAuthority.x, groupAuthority.x), max(gimbalAuthority.y, groupAuthority.y),
             max(gimbalAuthority.z, groupAuthority.z))
    }

    /// Actuator commands (rad, one per channel) for the normalised command
    /// `c` (roll, pitch, yaw): pitch and yaw are scaled together to fit the
    /// travel, keeping their direction, and roll gets what is left. `scale`
    /// is the smaller of the two factors: 1 when `c` fits as it is.
    func deflections(_ c: Vec3) -> (angles: [Double], scale: Double) {
        var base = channels.map { $0.thruster.gimbal[$0.index].bias }
        /// Largest s <= 1 keeping base + s d inside every range.
        func fit(_ d: [Double]) -> Double {
            var s = 1.0
            for (k, ch) in channels.enumerated() {
                let r = ch.thruster.gimbal[ch.index].range
                if d[k] > 0 { s = min(s, max(0, (r.upperBound - base[k]) / d[k])) }
                if d[k] < 0 { s = min(s, max(0, (r.lowerBound - base[k]) / d[k])) }
            }
            return s
        }
        let pitchYaw = channels.map { $0.perCommand.y * c.y + $0.perCommand.z * c.z }
        let s1 = fit(pitchYaw)
        for k in base.indices { base[k] += s1 * pitchYaw[k] }
        let roll = channels.map { $0.perCommand.x * c.x }
        let s2 = fit(roll)
        return (zip(base, roll).map { $0 + s2 * $1 }, min(s1, s2))
    }
}

extension Vessel {
    /// This step's allocation: call after the throttles have set the levels.
    /// Gimbals count when their engine delivers thrust now (enabled, lit,
    /// fed; ambient pressure from telemetry).
    func controlAllocation() -> ControlAllocation {
        var out = ControlAllocation()
        out.groupAuthority = rcsAuthority()
        guard thrusters.contains(where: { !$0.gimbal.isEmpty && $0.level > 0 }) else { return out }
        let com = centerOfMass
        let p = atmosphere.pressure, p0 = reference.atmosphere?.seaLevelPressure ?? 0
        // Torque per unit of travel of each actuator, and their Gram matrix.
        var columns: [(thruster: Thruster, index: Int, torque: Vec3, travel: Double)] = []
        var m = Mat3.zero
        for part in parts {
            for t in part.thrusters where !t.gimbal.isEmpty {
                let f = t.thrust(ambientPressure: p, seaLevelPressure: p0)
                guard f > 0 else { continue }
                let r = t.position + part.offset - com
                for (i, a) in t.gimbal.enumerated() where a.travel > 0 {
                    let b = r.cross(a.tilt * (f * a.travel))
                    columns.append((t, i, b, a.travel))
                    m = m + Mat3(columns: b * b.x, b * b.y, b * b.z)
                }
            }
        }
        let diagonal = [m[0, 0], m[1, 1], m[2, 2]]
        guard let top = diagonal.max(), top > 0 else { return out }
        // Axes the actuators cannot move independently (one engine on the
        // axis: roll) are dropped, weakest first, until the determinant is
        // sound relative to the diagonal (Hadamard's bound).
        var live = diagonal.map { $0 > 1e-12 * top }
        func reduced() -> Mat3 {
            func row(_ k: Int, _ r: Vec3) -> Vec3 {
                guard live[k] else { return [Vec3.unitX, .unitY, .unitZ][k] }
                return Vec3(live[0] ? r.x : 0, live[1] ? r.y : 0, live[2] ? r.z : 0)
            }
            return Mat3(rows: row(0, m.r0), row(1, m.r1), row(2, m.r2))
        }
        var mr = reduced()
        while mr.determinant <= 1e-6 * mr[0, 0] * mr[1, 1] * mr[2, 2] {
            guard let weakest = (0..<3).filter({ live[$0] }).min(by: { diagonal[$0] < diagonal[$1] }) else {
                return out
            }
            live[weakest] = false
            mr = reduced()
        }
        let inverse = mr.inverse
        func mask(_ v: Vec3) -> Vec3 { Vec3(live[0] ? v.x : 0, live[1] ? v.y : 0, live[2] ? v.z : 0) }
        // Fraction of travel per N m on each axis; an axis is at full scale
        // when its most loaded actuator reaches its travel.
        let patterns = columns.map { mask(inverse * $0.torque) }
        func full(_ k: KeyPath<Vec3, Double>) -> Double {
            let peak = patterns.map { abs($0[keyPath: k]) }.max() ?? 0
            return peak > 0 ? 1 / peak : 0
        }
        out.gimbalAuthority = Vec3(full(\.x), full(\.y), full(\.z))
        for (column, pattern) in zip(columns, patterns) {
            out.channels.append(.init(thruster: column.thruster, index: column.index,
                                      perCommand: pattern.scaled(by: out.gimbalAuthority) * column.travel,
                                      torque: column.torque / column.travel))
            let a = column.thruster.gimbal[column.index]
            out.slewTime = max(out.slewTime, column.travel / a.rateLimit + a.timeConstant)
        }
        return out
    }

    /// Gimbal commands for the normalised command `c` (roll, pitch, yaw; 0 on
    /// axes the gimbals do not fly). Pitch and yaw are scaled together to fit
    /// the travel, keeping their direction; roll gets what is left. Engines
    /// not firing return to their bias.
    func commandGimbals(_ c: Vec3, control: ControlAllocation) {
        for t in thrusters where !t.gimbal.isEmpty {
            for i in t.gimbal.indices { t.gimbal[i].setCommand(t.gimbal[i].bias) }
        }
        guard !control.channels.isEmpty else { return }
        for (ch, angle) in zip(control.channels, control.deflections(c).angles) {
            ch.thruster.gimbal[ch.index].setCommand(angle)
        }
    }

    /// Move every gimbal actuator towards its command for `dt` seconds.
    func advanceActuators(dt: Double) {
        for t in thrusters where !t.gimbal.isEmpty {
            for i in t.gimbal.indices { t.gimbal[i].advance(dt: dt) }
        }
    }
}
