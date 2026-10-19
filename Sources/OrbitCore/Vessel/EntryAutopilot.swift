import Foundation

/// What the entry autopilot holds about the velocity relative to the air
/// (`Vessel.entryCommand`).
public enum EntryCommand: Equatable {
    /// Hold the lift vector `bank` rad from the local up, positive to the
    /// right looking along the velocity: 0 is lift up, π lift down.
    case bank(Double)
    /// Roll steadily at `rate` rad/s, for zero mean lift.
    case rolling(rate: Double)
}

/// The entry digital autopilot (`AttitudeAutopilot.entry`): Apollo's entry
/// attitude control, rolling the command module about its stability axis
/// to fly `Vessel.entryCommand` and leaving pitch and yaw to the trim.
///
/// - The stability axis is the air velocity at trim, in body axes: -x
///   turned towards the centre of mass's side by the capsule's trim α' at
///   the current Mach and centre of mass. Rolling about it is Apollo's
///   coordinated roll about the velocity, the roll rate coupled into yaw
///   (TN D-5399), so the lift turns without disturbing the trim.
/// - Bank hold: outside a `bankDeadband` of the command it rolls the short
///   way at up to `maxRollRate`, no faster than it can stop in, at half
///   its roll acceleration; inside it, roll rates under `rateDeadband` are
///   left alone. Rolling holds the commanded rate.
/// - Across the stability axis, rates under `rateDeadband` are left to the
///   aerodynamics (Apollo 4's ±2°/s rate dead bands), larger ones damped.
///
/// Each body axis then runs M0's 0.5 s rate loop on the rotation groups.
/// The bank comes from the telemetry (`Vessel.bankAngle`, about the true
/// air velocity); without it (no capsule model) the autopilot damps rates.
public enum EntryAutopilot {
    /// Bank error left alone, rad (L: the CMC's entry dead band is not in
    /// the sources read).
    public static let bankDeadband = 4 * Double.pi / 180
    /// Fastest commanded roll about the stability axis, rad/s (L: the CMC's
    /// 20°/s).
    public static let maxRollRate = 20 * Double.pi / 180
    /// Rate dead band, rad/s: TN D-5399's ±2°/s on Apollo 4's three axes (H).
    public static let rateDeadband = 2 * Double.pi / 180

    /// `angle` wrapped into -π...π.
    static func wrap(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * Double.pi)
        if a > Double.pi { a -= 2 * Double.pi }
        if a < -Double.pi { a += 2 * Double.pi }
        return a
    }
}

extension Vessel {
    /// The entry autopilot's stability axis, body axes (unit): the air
    /// velocity's direction at the trim of the capsule model flying now, at
    /// the current Mach (Mach 10 out of the air) and centre of mass; -x
    /// without a capsule.
    public var stabilityAxis: Vec3 {
        guard let capsule = activeAerodynamics?.capsule else { return -Vec3.unitX }
        let trim = capsule.trimAngle(mach: mach > 0 ? mach : 10, centerOfMass: structuralCenterOfMass)
        return Vec3.unitX * -cos(trim) + liftSide(capsule) * sin(trim)
    }

    /// The entry autopilot's rotation command, with `alpha` the angular
    /// acceleration authority about each body axis (rad/s^2).
    func entryAutopilotCommand(alpha: Vec3) -> RotationCommand {
        let w = stabilityAxis, rate = angularVelocity
        let about = rate.dot(w), across = rate - w * about
        typealias D = EntryAutopilot
        // The rate about the stability axis to fly, and whether a small
        // error from it may be left (holding inside the dead band).
        var desired = 0.0, coast = true
        switch entryCommand {
        case .bank(let target)?:
            if let bank = bankAngle {
                let e = D.wrap(target - bank)
                if abs(e) > D.bankDeadband {
                    // Acceleration about w: each body axis supplies its share.
                    var a = Double.infinity
                    for (wk, ak) in [(w.x, alpha.x), (w.y, alpha.y), (w.z, alpha.z)] where abs(wk) > 1e-6 {
                        a = min(a, ak / abs(wk))
                    }
                    desired = (e > 0 ? 1 : -1) * min(D.maxRollRate, (max(a, 0) * abs(e)).squareRoot())
                    coast = false
                }
            }
        case .rolling(let r)?:
            desired = max(-D.maxRollRate, min(D.maxRollRate, r))
            coast = false
        case nil:
            break
        }
        var error = Vec3.zero
        let rollError = desired - about
        if !coast || abs(rollError) > D.rateDeadband { error += w * rollError }
        let spin = across.length
        if spin > D.rateDeadband { error -= across * ((spin - D.rateDeadband) / spin) }
        func axis(_ e: Double, _ a: Double) -> Double {
            guard a > 0 else { return 0 }
            let c = e / (a * 0.5)
            if abs(c) < 0.02 && abs(e) < 2e-4 { return 0 }
            return max(-1, min(1, c))
        }
        return RotationCommand(roll: axis(error.x, alpha.x), pitch: axis(error.y, alpha.y), yaw: axis(error.z, alpha.z))
    }
}

extension CapsuleAerodynamics {
    /// The trim α' (rad) of the sphere-centre model at `mach` (from
    /// `sphereCentreMach` up; held below it) for a centre of mass at
    /// `center` (construction coordinates), in closed form: tan(k α') =
    /// z / (x_cp - x).
    public func trimAngle(mach: Double, centerOfMass center: Vec3) -> Double {
        let kn = knot(at: max(mach, sphereCentreMach), sphereCentre: true)
        guard let xcp = kn.centre, kn.k > 0 else { return kn.trim }
        let offset = (center.y * center.y + center.z * center.z).squareRoot()
        return atan2(offset, xcp - center.x) / kn.k
    }
}
