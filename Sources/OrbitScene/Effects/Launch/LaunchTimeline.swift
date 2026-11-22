import Foundation
import OrbitCore

// When the launch effects happen (P4): the S-IC's ignition before first
// motion, as the terminal count runs it in the core (`TerminalCount`), and
// the countdown each effect is timed on.

/// The S-IC's ignition on LC-39A before first motion as AS-506's count
/// plans it (`TerminalCount.Plan.as506`), for a scene without a count (a
/// look-development scene placed at a historic epoch). Range times, s from
/// range zero (T−0). A scene with a count reads its record instead
/// (`LaunchEffects.Ignition`).
/// - The ignition command at T−8.9 s.
/// - FER-506's 1-2-2 start: engine 5's start command at T−6.4 s, 1 and 3 at
///   −6.1 s, 4 at −6.0 s, 2 at −5.9 s (Table 2-2, H); each engine's main
///   chamber ignites 3.35 s after its command and its thrust rises
///   linearly to full over 1.15 s (Figure 5-2, M), all at full by T−1.4 s.
/// - Before ignition each engine's turbopumps spin up on its gas generator
///   and LOX leads into the chamber: flow, no thrust (`startFlow`). The
///   whole makes FER Table 20-9's 39,307 kg by first motion.
public enum PadIgnition {
    public static let plan = TerminalCount.Plan.as506
    /// The ignition command (start sequence), range time, s.
    public static let ignitionCommand = plan.events.first { $0.name == "ignition sequence start" }!.time
    /// The first start command and the first ignition, range time, s.
    public static let firstCommand = plan.starts.map(\.command).min()!
    public static let thrustBuildup = plan.starts.map(\.ignition).min()!
    /// Each engine's ignition, range time, s.
    public static var engineStarts: [Double] { plan.starts.map(\.ignition) }
    /// The rise from ignition to full thrust, s.
    public static let rampTime = plan.rise

    /// Engine `i`'s thrust over its full thrust at range time `t`.
    public static func engineFraction(_ i: Int, rangeTime t: Double) -> Double { plan.fraction(i, rangeTime: t) }

    /// The five engines' mean thrust fraction at range time `t`: 0 before
    /// the first ignition, 1 once all are at full thrust (by T−1.4 s).
    public static func thrustFraction(rangeTime t: Double) -> Double { plan.meanFraction(rangeTime: t) }

    /// ∫ `thrustFraction` dt from range time `t0` to `t1`, s (exact).
    public static func integral(from t0: Double, to t1: Double) -> Double { plan.meanIntegral(from: t0, to: t1) }
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
