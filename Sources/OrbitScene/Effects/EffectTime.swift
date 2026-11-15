import Foundation
import OrbitCore

// The plan's time rules for effects (docs/m16/plan.md, "Time warp"; the
// design's section E):
// - particle physics runs on simulation time, so 10× is consistently 10×
//   faster, and pause freezes it;
// - journal bursts spawn at their true age, frame epoch − event epoch;
// - continuous emitters emit only over the last lifetime of each frame
//   interval, with stratified spawn ages, and stop at 1,000× and above
//   (except the trail);
// - the turbulence clock, which drives the noise, is real dt × min(warp, 4),
//   so flames do not strobe at 1,000×;
// - above 10× flashes are held on screen for at least 3 frames;
// - everything resets on a scenario change or a time jump (dt < 0 or > 600 s).
// The GPU's kill and look rules mirror `FlashHold`.

/// One frame's clocks, as the effects see them.
public struct EffectClock: Equatable {
    /// The frame's epoch.
    public var epoch: Epoch
    /// Simulation seconds the particles advance this frame: 0 when paused,
    /// on the first frame and on a frame drawn again (an AOV of a snapshot).
    public var dt: Double
    public var realDt: Double
    public var warp: Double
    public var paused: Bool
    /// The turbulence clock's step and its time (wrapped at an hour), s.
    public var turbulenceDt: Double
    public var turbulenceTime: Double
    /// Frames advanced since the last reset (a frame drawn again is not counted).
    public var frame: Int

    public init(epoch: Epoch, dt: Double = 0, realDt: Double = 0, warp: Double = 1, paused: Bool = false,
                turbulenceDt: Double = 0, turbulenceTime: Double = 0, frame: Int = 0) {
        self.epoch = epoch
        self.dt = dt
        self.realDt = realDt
        self.warp = warp
        self.paused = paused
        self.turbulenceDt = turbulenceDt
        self.turbulenceTime = turbulenceTime
        self.frame = frame
    }

    /// Continuous emitters are suspended (all but the trail).
    public var suspendsContinuous: Bool { warp >= EffectTimeRules.suspendWarp }
    /// Flashes are held for `EffectTimeRules.flashHoldFrames`.
    public var holdsFlashes: Bool { warp > EffectTimeRules.flashHoldWarp }
    /// The frame moves time on.
    public var advances: Bool { dt > 0 }
}

public enum EffectTimeRules {
    /// The turbulence clock runs at most this many times real time.
    public static let turbulenceWarp = 4.0
    /// A step longer than this (s), or backwards, is a jump: everything resets.
    public static let timeJump = 600.0
    /// At this warp and above continuous emitters stop, except the trail.
    public static let suspendWarp = 1_000.0
    /// Above this warp flashes are held...
    public static let flashHoldWarp = 10.0
    /// ...for at least this many frames.
    public static let flashHoldFrames = 3
    /// The turbulence clock wraps here, s (Float keeps 0.25 ms at an hour).
    public static let turbulencePeriod = 3_600.0

    /// The turbulence clock's step: real dt × min(warp, 4); 0 when paused.
    public static func turbulenceDt(realDt: Double, warp: Double, paused: Bool) -> Double {
        paused ? 0 : max(realDt, 0) * min(max(warp, 0), turbulenceWarp)
    }

    /// Whether a frame's simulation step is a jump.
    public static func isTimeJump(_ dt: Double) -> Bool { dt < 0 || dt > timeJump }

    /// A burst's age at the frame: the frame's epoch less the event's (0 for
    /// an event that is somehow ahead of the frame).
    public static func burstAge(event: Epoch, frame: Epoch) -> Double { max(0, frame - event) }

    /// Whether a particle of `lifetime` spawned at `age` is drawn at all:
    /// while it lives, or, for a flash above 10×, if it ended within this
    /// frame's interval `dt`, which it would otherwise never be seen in.
    public static func spawns(age: Double, lifetime: Double, isFlash: Bool, clock: EffectClock) -> Bool {
        age < lifetime || isFlash && clock.holdsFlashes && age < lifetime + max(clock.dt, 0)
    }
}

/// A flash's hold (above 10×), as the GPU applies it to each particle: one
/// past its lifetime lives on until it has been drawn on
/// `flashHoldFrames` frames, looking as it did halfway through its life.
public enum FlashHold {
    /// Whether the particle lives this frame.
    public static func isAlive(age: Double, lifetime: Double, framesShown: Int, isFlash: Bool, holds: Bool) -> Bool {
        age < lifetime || isFlash && holds && framesShown < EffectTimeRules.flashHoldFrames
    }

    /// The age its look is drawn at: its own, or half its lifetime while held.
    public static func displayAge(age: Double, lifetime: Double) -> Double {
        age < lifetime ? age : 0.5 * lifetime
    }
}

/// A continuous emitter's bookkeeping across frames: the fraction of a
/// particle it owes (so 1.7 particles a frame are 1.7, not 1 or 2), and the
/// rule that only the last lifetime of the frame's interval is covered.
public struct ContinuousEmission: Equatable {
    public var carry = 0.0

    public init() {}

    /// This frame's count and the range of their ages, for `rate` particles
    /// a second living at most `lifetime` s, over a frame of `dt` s.
    /// Particles that would have been born before the last lifetime of the
    /// interval are dead by now: they are not counted, nor carried.
    public mutating func schedule(rate: Double, dt: Double, lifetime: Double) -> (count: Int, ages: ClosedRange<Double>) {
        guard rate > 0, dt > 0, lifetime > 0 else { return (0, 0...0) }
        let covered = min(dt, lifetime)
        let expected = rate * covered + (covered == dt ? carry : 0)
        let count = Int(expected.rounded(.down))
        carry = expected - Double(count)
        return (count, 0...covered)
    }
}
