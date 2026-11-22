import Foundation

/// A point in the flight where time warp must come down, which a flight
/// program asks for (`FlightProgram.warpEvents(after:)`): a stop (TIG−2 min,
/// TB6−60 s), or a cap over a window (1x from TIG−30 s to TIG+5 s). The
/// simulation's governor (`Simulation.advance`) honours the focus vessel's
/// hard events: no step crosses one that would lower the warp, and the warp
/// is only ever lowered, never raised. Soft events (LOS, AOS, the SOI) are
/// for a warp-to key and are not honoured on their own.
public struct WarpEvent: Equatable {
    public enum Kind: Equatable {
        /// From `at` on, at most `maxWarp`, until the pilot raises it again.
        case stop(maxWarp: Double)
        /// From `at` until `until`, at most `maxWarp`.
        case cap(maxWarp: Double, until: Epoch)
    }

    public var at: Epoch
    public var kind: Kind
    /// Always honoured (a hard stop); false for a soft one.
    public var hard: Bool
    /// What it is, for the log ("TIG-2 min").
    public var reason: String

    public init(at: Epoch, _ kind: Kind, hard: Bool = true, reason: String) {
        self.at = at
        self.kind = kind
        self.hard = hard
        self.reason = reason
    }

    public static func stop(at: Epoch, maxWarp: Double = 1, hard: Bool = true, reason: String) -> WarpEvent {
        WarpEvent(at: at, .stop(maxWarp: maxWarp), hard: hard, reason: reason)
    }

    public static func cap(from at: Epoch, until: Epoch, maxWarp: Double, hard: Bool = true,
                           reason: String) -> WarpEvent {
        WarpEvent(at: at, .cap(maxWarp: maxWarp, until: until), hard: hard, reason: reason)
    }

    /// The warp the event allows once it is reached.
    public var maxWarp: Double {
        switch kind {
        case .stop(let w), .cap(let w, _): w
        }
    }

    /// Whether the event still matters at `now`: a stop not yet passed, a
    /// cap whose window has not ended.
    public func matters(at now: Epoch) -> Bool {
        switch kind {
        case .stop: at - now > -WarpEvent.reachedWithin
        case .cap(_, let until): until > now
        }
    }

    /// Whether `now` is inside a cap's window, or at a stop (within
    /// `reachedWithin`).
    public func holds(at now: Epoch) -> Bool {
        switch kind {
        case .stop: abs(at - now) <= WarpEvent.reachedWithin
        case .cap(_, let until): at - now <= WarpEvent.reachedWithin && now < until
        }
    }

    /// How near (s) a step's end counts as reaching an event: the steps that
    /// end on one land on it to within rounding.
    public static let reachedWithin = 1e-6
}

extension Simulation {
    /// The share of the time left to the next warp event a frame of `real`
    /// seconds covers at most is 1 − exp(−real / `warpApproachTime`): the
    /// warp seems to fall smoothly as the event nears, so a stop met at
    /// 100,000x is reached about `warpApproachTime` × ln(time left) seconds
    /// of real time later (about 5 s from two hours away), not in one frame,
    /// and never overrun. (docs/m2/design-flight-controls.md §4 asks for the
    /// stop to stay 4 s of real time ahead as the warp steps down by
    /// decades; with steps of ten that takes 36 s of real time per decade,
    /// so this approach keeps its intent and not its letter.)
    public static let warpApproachTime = 0.5

    /// The focus vessel's hard warp events that still matter now.
    func governingWarpEvents() -> [WarpEvent] {
        guard let p = focus?.flightProgram else { return [] }
        return p.warpEvents(after: time).filter { $0.hard && $0.matters(at: time) }
    }

    /// The governor at the start of a frame of `real` seconds: lower the warp
    /// for the events in force now, and return the simulated time the frame
    /// may cover, which ends at the first event ahead that would lower the
    /// warp further and approaches it (`warpApproachTime`), with the event
    /// it ends on, if it does.
    func governedSpan(_ events: [WarpEvent], real: Double) -> (span: Double, endsOn: WarpEvent?) {
        for e in events where e.holds(at: time) { lowerWarp(for: e) }
        var span = real * warp, endsOn: WarpEvent?
        let share = -expm1(-real / Self.warpApproachTime)
        for e in events where e.at - time > WarpEvent.reachedWithin && warp > e.maxWarp {
            let ahead = e.at - time
            let allowed = max(real * e.maxWarp, ahead * share)
            if ahead <= min(span, allowed) {
                span = ahead
                endsOn = e
            } else if allowed < span {
                span = allowed
                endsOn = nil
            }
        }
        return (span, endsOn)
    }

    /// After a frame: lower the warp for the events it reached, `endsOn`
    /// included (the frame's steps land on it to within their rounding).
    func governorReached(_ events: [WarpEvent], endsOn: WarpEvent?) {
        if let e = endsOn { lowerWarp(for: e) }
        for e in events where e.holds(at: time) { lowerWarp(for: e) }
    }

    /// Lower the warp to what `e` allows, logging it once per event.
    func lowerWarp(for e: WarpEvent) {
        guard warp > e.maxWarp else { return }
        warp = e.maxWarp
        let key = WarpLogKey(at: e.at, reason: e.reason)
        guard !loggedWarpEvents.contains(key) else { return }
        loggedWarpEvents.insert(key)
        let w = e.maxWarp < 1 ? String(format: "%.1f", e.maxWarp) : String(format: "%.0f", e.maxWarp)
        switch e.kind {
        case .stop: log("Warp \(w)×: \(e.reason)")
        case .cap: log("Warp at most \(w)×: \(e.reason)")
        }
    }
}

/// An event the governor has logged.
struct WarpLogKey: Hashable {
    var at: Epoch
    var reason: String
}
