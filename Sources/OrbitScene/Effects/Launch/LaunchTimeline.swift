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
    /// buildup, 1 once all are at full flow (by T−0.28 s).
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
