import Foundation
import OrbitCore

// When the launch effects happen (P4): the S-IC's ignition before first
// motion, which the simulation does not fly (it starts at first motion with
// the F-1s at full thrust), and the countdown each effect is timed on.

/// The S-IC's ignition on LC-39A before first motion, as the pad's exhaust
/// sees it. Range times, s from range zero (T−0).
/// - The ignition command, the start of the engine start sequence, at
///   T−8.9 s (SP-4206 Appendix B, the Saturn V launch sequence; the Apollo 11
///   commentary's "ignition sequence start", H).
/// - The thrust starts to build at T−5.3 s, where the sequence monitors the
///   S-IC engines' thrust buildup (SP-4206 Appendix B, AS-502's sequence;
///   M for AS-506). Before it the turbopumps spin up: no exhaust to speak of.
/// - The engines start 1-2-2, the centre engine first, then the opposing
///   outboard pairs 0.3 s apart (M).
/// - Each rises linearly to full flow over `rampTime` (shape L), fitted so
///   that the five engines' flow from the buildup to first motion, AS-506's
///   at first motion, is FER Table 20-9's 39,307 kg of thrust buildup (H;
///   `LaunchEffectsTests.testIgnitionBurnsTheFERsBuildup`).
/// So at first motion (T+0.30 s) the pad's exhaust is up to 5.6 s old, the
/// last of 9.2 s since the ignition command.
public enum PadIgnition {
    /// The ignition command (start sequence), range time, s.
    public static let ignitionCommand = -8.9
    /// The thrust buildup's start, range time, s.
    public static let thrustBuildup = -5.3
    /// Each engine's start: the centre, then two opposing pairs (1-2-2).
    public static let engineStarts: [Double] = [0, 0.3, 0.3, 0.6, 0.6].map { thrustBuildup + $0 }
    /// The rise from start to full flow, s (fitted to Table 20-9: L shape).
    public static let rampTime = 4.50

    /// Engine `i`'s flow over its full flow at range time `t`.
    public static func engineFraction(_ i: Int, rangeTime t: Double) -> Double {
        min(1, max(0, (t - engineStarts[i]) / rampTime))
    }

    /// The five engines' mean flow fraction at range time `t`: 0 before the
    /// buildup, 1 once all are at full flow (by T−0.20 s).
    public static func thrustFraction(rangeTime t: Double) -> Double {
        engineStarts.indices.reduce(0) { $0 + engineFraction($1, rangeTime: t) } / Double(engineStarts.count)
    }

    /// ∫ `thrustFraction` dt from range time `t0` to `t1`, s (exact).
    public static func integral(from t0: Double, to t1: Double) -> Double {
        guard t1 > t0 else { return 0 }
        func g(_ start: Double, _ t: Double) -> Double {
            let u = t - start
            if u <= 0 { return 0 }
            return u <= rampTime ? u * u / (2 * rampTime) : u - rampTime / 2
        }
        return engineStarts.reduce(0) { $0 + g($1, t1) - g($1, t0) } / Double(engineStarts.count)
    }
}

/// The vehicle's rise off the pad, which a rebuilt history assumes (the
/// frames before a reset are not kept), as the simulation flies it: straight
/// up, the tower-clearance yaw's metres aside, under the S-IC's thrust at
/// first motion as the propellant burns, a = F / (m0 − ṁ t) − g, with
///
/// - F, 34.34 MN: the stage's thrust at 0.5 s (FER Figure 5-3, H), the
///   model's since §17 (AS506-datasheet §8.5);
/// - m0, 2,899,008 kg: the vehicle at first motion (FER Table 20-1, H);
/// - ṁ, 13,157 kg/s: the five F-1s' flow at first motion (AS506's rating,
///   FER §5: `LaunchEffectsTests.testLiftoffRiseIsTheModels` checks it
///   against the vehicle).
///
/// Drag is negligible this low. It reproduces the model's climb in the
/// datasheet (§8.5): 105 m at range 10 s and 473 m at 20 s, within 3 m, and
/// GE504's 137 m rise, at which the IU starts the roll and pitch programs
/// (SaturnIU), 11.0 s after first motion (T1 + 10.7 s). AS-506 itself,
/// slower off the pad with its controlled release, started them at
/// T1 + 12.6 s (FER Table 2-2).
public enum LiftoffRise {
    public static let thrust = 34.34e6
    public static let mass = 2_899_008.0
    public static let flow = 13_157.0
    public static let gravity = 9.79
    /// The rise at which the pitch program starts, m, and when, s after first motion.
    public static let programStartRise = 137.0
    public static let programStart: Double = {
        var lo = 0.0, hi = 30.0
        for _ in 0..<60 {
            let mid = 0.5 * (lo + hi)
            if rise(after: mid) < programStartRise { lo = mid } else { hi = mid }
        }
        return 0.5 * (lo + hi)
    }()

    /// The speed `t` s after first motion, m/s: (F / ṁ) ln(m0 / m) − g t.
    public static func speed(after t: Double) -> Double {
        let s = max(0, t), k = flow / mass
        return -(thrust / flow) * log(1 - k * s) - gravity * s
    }

    /// The rise `t` s after first motion, m: the speed's integral,
    /// (F / ṁ) ((1 − k t) ln(1 − k t) / k + t) − g t² / 2 with k = ṁ / m0.
    public static func rise(after t: Double) -> Double {
        let s = max(0, t), k = flow / mass
        return (thrust / flow) * ((1 - k * s) * log(1 - k * s) / k + s) - 0.5 * gravity * s * s
    }
}

/// The launch an epoch belongs to: Apollo 8's or Apollo 11's countdown,
/// whichever range zero is nearer (as LC-39A's swing arms are driven).
public enum LaunchCountdown {
    public static let known: [LC39A.Countdown] = [.apollo8, .apollo11]

    public static func nearest(_ epoch: Epoch) -> LC39A.Countdown {
        known.min { abs($0.rangeTime(at: epoch)) < abs($1.rangeTime(at: epoch)) }!
    }

    /// The epoch of range time `t` in `c`.
    public static func epoch(_ t: Double, in c: LC39A.Countdown) -> Epoch { c.rangeZero + t }
}
