import Foundation

/// The terminal count of a launch vehicle standing on its pad, and the
/// launch it ends in, as the launch complex's terminal countdown sequencer
/// ran it: the count holds where the scenario stops it, and once resumed
/// (the pilot's Space, `resume`) runs on its own to first motion.
///
/// - Range time: while the count holds it stands still; from `resume` it
///   runs, and range zero (T−0) falls `-hold` s after the resume. The
///   mission clock counts from it (`rangeZero(at:)`).
/// - The pad's events are logged and shown on the next-event line
///   (`nextEvent`): for AS-506 the S-IC intertank and forward arms' retract
///   commands and the ignition command.
/// - Each engine starts at its time and its thrust rises linearly to full
///   over `Plan.rise` (`fraction`), delivered through
///   `Thruster.groundStart` at the engine's first-motion rating: the 1-2-2
///   start shows in the core's thrust.
/// - The hold-down arms hold the vehicle on the pad whatever its thrust
///   (`holdsDown`). At launch commit (T−0) every engine must run at its
///   thrust OK level; then the arms release at `Plan.release` and the
///   engines run on in flight, their burn clocks starting there. An engine
///   that failed or is short of thrust at commit scrubs the launch: the
///   engines stop and the vehicle stays held. One lost after commit does
///   not stop the release; first motion then waits for the others to lift
///   the vehicle.
/// - Controlled release: for the first `ControlledRelease.stroke` of rise
///   the tapered pins drawn through their dies hold the vehicle back
///   (`restraint`).
/// - The propellant the engines burn before first motion comes out of the
///   stage's tanks, which start that much fuller: each tank holds its
///   first-motion load plus its share of what the engines still have to
///   burn until the release, a function of range time, so it is the load
///   exactly at the release whatever the steps. For AS-506 the vehicle is
///   FER Table 20-1's ground ignition mass on the pad and its first-motion
///   mass at the release, Table 20-9's thrust buildup apart.
///
/// The simulation runs it for `vehicle` (`Simulation.terminalCount`): at the
/// start of each of its steps, before the flight program (`update`), and at
/// the end of each (`stepped`), and it ends a step on each of the count's
/// events.
public final class TerminalCount {
    /// The restraint of the controlled release mechanisms: a force against
    /// the rise falling linearly from `force` at release to zero at
    /// `stroke` m of rise, as the tapered pins draw through their dies.
    public struct ControlledRelease: Equatable {
        public var force: Double
        public var stroke: Double
        public init(force: Double, stroke: Double) {
            self.force = force
            self.stroke = stroke
        }

        /// The force at `rise` m, N.
        public func force(atRise rise: Double) -> Double {
            guard rise < stroke else { return 0 }
            return force * (1 - max(0, rise) / stroke)
        }
    }

    /// A pad event: its name and range time.
    public struct Event: Equatable {
        public var name: String
        public var time: Double
        public init(_ name: String, _ time: Double) {
            self.name = name
            self.time = time
        }
    }

    /// One engine's start: its name, its start command, and its main
    /// chamber's ignition, where its thrust starts to rise.
    public struct Start: Equatable {
        public var engine: String
        public var command: Double
        public var ignition: Double
        public init(engine: String, command: Double, ignition: Double) {
            self.engine = engine
            self.command = command
            self.ignition = ignition
        }
    }

    /// What the count does, range time (s from T−0).
    public struct Plan: Equatable {
        /// Logged and shown, in order. An event named
        /// `guidanceReferenceRelease` also targets the IU for the time of
        /// launch (`SaturnIU.target(launchDelay:)`).
        public var events: [Event]
        /// Each engine's start.
        public var starts: [Start]
        /// The rise from ignition to full thrust, s (linear).
        public var rise: Double
        /// The flow from a start command to the ignition, over full flow:
        /// propellant through the engine before it gives thrust.
        public var startFlow: Double
        /// The part whose tanks feed the engines.
        public var stage: String
        /// Launch commit, and the fraction of full thrust each engine must
        /// reach by then.
        public var commit: Double
        public var thrustOK: Double
        /// The hold-down release.
        public var release: Double
        public var controlledRelease: ControlledRelease?
        /// The rise of the vehicle at which its liftoff switches close, m.
        public var liftoffSwitchRise: Double

        public static let guidanceReferenceRelease = "guidance reference release"

        public init(events: [Event], starts: [Start], rise: Double, startFlow: Double, stage: String,
                    commit: Double, thrustOK: Double, release: Double, controlledRelease: ControlledRelease?,
                    liftoffSwitchRise: Double) {
            self.events = events
            self.starts = starts
            self.rise = rise
            self.startFlow = startFlow
            self.stage = stage
            self.commit = commit
            self.thrustOK = thrustOK
            self.release = release
            self.controlledRelease = controlledRelease
            self.liftoffSwitchRise = liftoffSwitchRise
        }

        /// Engine `i`'s thrust over its full thrust at range time `t`, as
        /// planned: 0 before its ignition, linear to 1 over `rise`.
        public func fraction(_ i: Int, rangeTime t: Double) -> Double {
            min(1, max(0, (t - starts[i].ignition) / rise))
        }

        /// Engine `i`'s flow over its full flow at range time `t`: the start
        /// flow from its command to its ignition, then its thrust's fraction.
        public func flowFraction(_ i: Int, rangeTime t: Double) -> Double {
            t >= starts[i].command && t < starts[i].ignition ? startFlow : fraction(i, rangeTime: t)
        }

        /// The engines' mean thrust fraction at range time `t`.
        public func meanFraction(rangeTime t: Double) -> Double {
            starts.indices.reduce(0) { $0 + fraction($1, rangeTime: t) } / Double(starts.count)
        }

        /// ∫ `fraction(i, ·)` dt from range time `t0` to `t1`, s, exactly;
        /// 0 unless t1 > t0.
        public func integral(_ i: Int, from t0: Double, to t1: Double) -> Double {
            guard t1 > t0 else { return 0 }
            let start = starts[i].ignition, rise = rise
            func g(_ t: Double) -> Double {
                let u = t - start
                if u <= 0 { return 0 }
                return u <= rise ? u * u / (2 * rise) : u - rise / 2
            }
            return g(t1) - g(t0)
        }

        /// ∫ `flowFraction(i, ·)` dt from `t0` to `t1`, s, exactly.
        public func flowIntegral(_ i: Int, from t0: Double, to t1: Double) -> Double {
            guard t1 > t0 else { return 0 }
            let s = starts[i]
            let lead = max(0, min(t1, s.ignition) - max(t0, s.command))
            return startFlow * lead + integral(i, from: t0, to: t1)
        }

        /// ∫ `meanFraction` dt from `t0` to `t1`, s.
        public func meanIntegral(from t0: Double, to t1: Double) -> Double {
            starts.indices.reduce(0) { $0 + integral($1, from: t0, to: t1) } / Double(starts.count)
        }

        /// The plan's own times: the events, the commands, ignitions and
        /// ends of the rises, commit and release.
        var times: [Double] {
            var times = events.map(\.time) + [commit, release]
            for s in starts { times += [s.command, s.ignition, s.ignition + rise] }
            return times
        }
    }

    public let plan: Plan
    /// The vehicle on the pad: the count drives its engines until the release.
    public private(set) weak var vehicle: Vessel?
    /// The range time the count holds at, until resumed.
    public let hold: Double
    /// Range zero as planned: where it falls if the count is resumed as
    /// soon as it holds (the launch window's opening). A later range zero is
    /// a late launch (`SaturnIU.target(launchDelay:)`).
    public let plannedRangeZero: Epoch
    /// Range zero, once the count runs; nil while it holds.
    public private(set) var rangeZero: Epoch?
    /// Launch commit and the release, when they happened.
    public private(set) var committed: Epoch?
    public private(set) var released: Epoch?
    /// The vehicle's first motion, and when its liftoff switches closed
    /// (`Plan.liftoffSwitchRise`, interpolated within the step).
    public private(set) var firstMotion: Epoch?
    public private(set) var liftoffSwitch: Epoch?
    /// Why the launch was scrubbed, and when; nil while it goes ahead.
    public private(set) var scrub: (time: Epoch, reason: String)?
    /// What the count did and when, in order.
    public private(set) var log: [(time: Epoch, event: String)] = []

    /// Range time at which each engine stopped building thrust before the
    /// release (it failed, or the launch was scrubbed), by its index in
    /// `plan.starts`: its propellant stops there.
    private var stops: [Int: Double] = [:]
    /// The events logged, by index in `plan.events`.
    private var done = Set<Int>()
    /// Each tank of the stage, its load at first motion, and its share of
    /// each engine's flow (the flow at the engine's first-motion rating,
    /// split by its mixture ratio).
    private var tanks: [(tank: PropellantTank, load: Double, flows: [Double])] = []
    /// Where the structure's origin stood on the pad, body-fixed, the
    /// body's up there, and the body.
    private var pad: (body: CelestialBody, point: Vec3, up: Vec3)?
    /// The rise at the last step after the release, for the liftoff switch.
    private var lastRise: (time: Epoch, rise: Double)?
    /// The last epoch the vehicle was seen standing after the release: the
    /// start of the step it lifted off in, once it has.
    private var lastStanding: Epoch?

    /// The count of `vehicle`, standing landed on its pad at `now`, held at
    /// range time `hold` (negative: before T−0) with its engines off. Its
    /// tanks take on what the engines will burn before the release. Not yet
    /// run by any simulation: `Simulation.terminalCount` takes it.
    public init(vehicle: Vessel, plan: Plan, hold: Double, at now: Epoch) {
        precondition(vehicle.landed != nil, "the count's vehicle stands on its pad")
        precondition(hold < plan.starts.map(\.command).min() ?? plan.commit, "the count holds before the engines start")
        self.plan = plan
        self.vehicle = vehicle
        self.hold = hold
        plannedRangeZero = now + (-hold)
        let engines = plan.starts.map { s in vehicle.thrusters.first { $0.name == s.engine } }
        precondition(!engines.contains { $0 == nil }, "every engine of the plan is aboard")
        guard let part = vehicle.parts.first(where: { $0.name == plan.stage }) else {
            preconditionFailure("the stage \(plan.stage) is aboard")
        }
        tanks = part.tanks.map { tank in
            let flows = engines.map { e -> Double in
                guard let e, let feed = e.feed else { return 0 }
                let r = e.rating(atBurnTime: 0), ratio = r.mixtureRatio ?? 0
                switch feed {
                case .single(let t): return t === tank ? r.massFlow : 0
                case let .bipropellant(o, f):
                    if o === tank { return r.massFlow * ratio / (1 + ratio) }
                    if f === tank { return r.massFlow / (1 + ratio) }
                    return 0
                }
            }
            return (tank, tank.mass, flows)
        }
        if let l = vehicle.landed {
            let structure = l.bodyFixedPosition + l.bodyFixedAttitude.rotate(vehicle.structureOrigin)
            pad = (l.body, structure, l.body.figure.normal(at: structure))
        }
        bookTanks(rangeTime: hold)
    }

    /// The count of a vehicle that the scenario places at its first motion
    /// (`VesselLibrary.apollo11OnPad`, its engines at full): released at
    /// `plan.release` with range zero `rangeZero`, its history as planned.
    /// It drives nothing, not even the controlled release (the vehicle flies
    /// as it was placed); it tells the scene when the count ran, first motion
    /// at the release, and finds the liftoff switches.
    public init(releasedVehicle vehicle: Vessel, plan: Plan, rangeZero: Epoch) {
        var plan = plan
        plan.controlledRelease = nil
        self.plan = plan
        self.vehicle = vehicle
        hold = plan.events.map(\.time).min() ?? plan.commit
        self.rangeZero = rangeZero
        plannedRangeZero = rangeZero
        committed = rangeZero + plan.commit
        released = rangeZero + plan.release
        firstMotion = released
        for (i, e) in plan.events.enumerated() {
            done.insert(i)
            log.append((rangeZero + e.time, e.name))
        }
        log.append((rangeZero + plan.commit, "launch commit"))
        log.append((rangeZero + plan.release, "hold-down release"))
        if let l = vehicle.landed {
            let structure = l.bodyFixedPosition + l.bodyFixedAttitude.rotate(vehicle.structureOrigin)
            pad = (l.body, structure, l.body.figure.normal(at: structure))
        }
    }

    // MARK: The record

    /// What the count did, as a value: for the scene, which draws the pad
    /// and its effects from it.
    public struct Record: Equatable {
        public var plan: Plan
        public var hold: Double
        public var plannedRangeZero: Epoch
        public var rangeZero: Epoch?
        public var committed: Epoch?
        public var released: Epoch?
        public var firstMotion: Epoch?
        public var liftoffSwitch: Epoch?
        public var scrubbed: Epoch?
        /// Range time each engine stopped at before the release, by index.
        public var stops: [Int: Double]

        /// Range time at `now` (the hold's while it holds).
        public func rangeTime(at now: Epoch) -> Double { rangeZero.map { now - $0 } ?? hold }
        /// Where range time counts from at `now`.
        public func rangeZero(at now: Epoch) -> Epoch { rangeZero ?? now + (-hold) }

        /// Engine `i`'s thrust over full at `epoch`, as the count ran it: 0
        /// once it stopped before the release, then and after.
        public func fraction(_ i: Int, at epoch: Epoch) -> Double {
            guard let zero = rangeZero else { return 0 }
            let t = epoch - zero
            if let s = stops[i], t >= s { return 0 }
            if let r = released, epoch >= r { return 1 }
            return plan.fraction(i, rangeTime: t)
        }

        /// Engine `i`'s flow over full at `epoch`: its start flow from its
        /// command to its ignition, then its thrust's fraction.
        public func flowFraction(_ i: Int, at epoch: Epoch) -> Double {
            guard let zero = rangeZero else { return 0 }
            let t = epoch - zero
            if let s = stops[i], t >= s { return 0 }
            if let r = released, epoch >= r { return 1 }
            return plan.flowFraction(i, rangeTime: t)
        }

        /// The epochs engine `i` was commanded to start and ignited at; nil
        /// while the count holds, or for one it never reached (it failed
        /// before its command).
        public func start(_ i: Int) -> (command: Epoch, ignition: Epoch)? {
            guard let zero = rangeZero else { return nil }
            let s = plan.starts[i]
            if let stop = stops[i], stop < s.command { return nil }
            return (zero + s.command, zero + s.ignition)
        }

        /// The epoch engine `i` stopped at before the release, if it did.
        public func stop(_ i: Int) -> Epoch? {
            guard let zero = rangeZero, let s = stops[i] else { return nil }
            return zero + s
        }
    }

    /// The count so far, as a value.
    public var record: Record {
        Record(plan: plan, hold: hold, plannedRangeZero: plannedRangeZero, rangeZero: rangeZero, committed: committed,
               released: released, firstMotion: firstMotion, liftoffSwitch: liftoffSwitch, scrubbed: scrub?.time,
               stops: stops)
    }

    // MARK: Time

    /// True while the count holds.
    public var isHolding: Bool { rangeZero == nil }

    /// Range time at `now`: the hold's while the count holds.
    public func rangeTime(at now: Epoch) -> Double { rangeZero.map { now - $0 } ?? hold }

    /// The epoch the range time at `now` counts from: range zero once the
    /// count runs; while it holds, where it would fall if it ran on now.
    public func rangeZero(at now: Epoch) -> Epoch { rangeZero ?? now + (-hold) }

    /// Resume the count at `now`: range zero falls `-hold` s later. False
    /// (and nothing happens) unless it holds.
    @discardableResult
    public func resume(at now: Epoch, in sim: Simulation? = nil) -> Bool {
        guard rangeZero == nil else { return false }
        rangeZero = now + (-hold)
        record(String(format: "count resumed at T%+.0f s", hold), at: now, sim)
        return true
    }

    /// Engine `i`'s thrust over its full thrust at `epoch` as the count ran
    /// it: as planned from range zero, 0 once it stopped before the release
    /// (`stops`), 1 after the release; 0 while the count holds.
    public func fraction(_ i: Int, at epoch: Epoch) -> Double { record.fraction(i, at: epoch) }

    // MARK: The simulation's hooks

    /// Whether the arms hold `v` down: its count's vehicle before the release.
    public func holdsDown(_ v: Vessel) -> Bool { v === vehicle && released == nil }

    /// One step of the count at `sim.time`, before the vehicle's flight
    /// program: the events due, the engines' thrust, the tanks, commit and
    /// the release. First motion and the liftoff switches are found at the
    /// end of each step (`stepped`).
    public func update(_ v: Vessel, in sim: Simulation) {
        guard v === vehicle, let zero = rangeZero else {
            // Holding: the engines stay off whatever the throttle says.
            if v === vehicle, released == nil { v.mainThrottle = 0 }
            return
        }
        let now = sim.time, t = now - zero
        for (i, e) in plan.events.enumerated() where !done.contains(i) && e.time <= t + 1e-6 {
            done.insert(i)
            record(e.name, at: zero + e.time, sim)
            if e.name == Plan.guidanceReferenceRelease, let iu = v.flightProgram as? SaturnIU {
                let target = iu.target(launchDelay: zero - plannedRangeZero)
                record(String(format: "IU flight azimuth %.3f°, target plane i %.3f°, descending node %.3f°",
                              target.azimuth * 180 / .pi, target.inclination * 180 / .pi,
                              target.descendingNode * 180 / .pi), at: zero + e.time, sim)
            }
        }
        guard released == nil else {
            if v.landed != nil { lastStanding = now }
            return
        }
        // Until the release the count, not the pilot, runs the engines.
        v.mainThrottle = 0
        if scrub != nil { return }
        let engines = plan.starts.map { s in v.thrusters.first { $0.name == s.engine } }
        for (i, e) in engines.enumerated() {
            guard let e else { continue }
            // An engine lost since the resume stops there: before its
            // command it never starts (`Record.start`), and what it was to
            // burn stays in the tanks.
            if stops[i] == nil, !e.isAvailable { stops[i] = t }
            guard stops[i] == nil, t >= plan.starts[i].ignition - 1e-6 else {
                e.groundStart = nil
                continue
            }
            // The fraction at the middle of the coming step: 0.02 s, as a
            // thrusting landed vessel steps, or to the count's next time.
            let next = timeToNextEvent(at: now) ?? .infinity
            e.groundStart = plan.fraction(i, rangeTime: t + 0.5 * min(0.02, next))
        }
        if committed == nil, t >= plan.commit - 1e-6 {
            let short = engines.enumerated().filter { i, e in
                guard let e, stops[i] == nil, e.isAvailable else { return true }
                return plan.fraction(i, rangeTime: t) < plan.thrustOK
            }.map { plan.starts[$0.offset].engine }
            if short.isEmpty {
                committed = now
                record("launch commit: thrust OK", at: now, sim)
            } else {
                for (i, e) in engines.enumerated() {
                    e?.groundStart = nil
                    if stops[i] == nil { stops[i] = t }
                }
                scrub = (now, "thrust not OK at T-0 (\(short.joined(separator: ", ")))")
                record("cutoff, launch scrubbed: " + scrub!.reason, at: now, sim)
                bookTanks(rangeTime: t)
                return
            }
        }
        if committed != nil, now >= zero + plan.release {
            // The release: every tank at its first-motion load (what the
            // engines still had to burn is nothing now; an engine lost since
            // commit leaves its unburned share aboard), the engines on to the
            // flight under the throttle, their clocks from here.
            for e in engines { e?.groundStart = nil }
            bookTanks(rangeTime: plan.release)
            v.mainThrottle = 1
            released = now
            lastStanding = now
            record("hold-down release", at: now, sim)
            return
        }
        bookTanks(rangeTime: t)
    }

    /// Seconds from `now` to the count's next event, to end a step there;
    /// nil while it holds or once it has released. Taken between epochs: a
    /// step that lands on an event's epoch reads a range time a few 1e-8 s
    /// off the event's (the epoch's grid is 2⁻²³ s in 1969), and the next
    /// event is the first epoch after `now`, the release's until `now` is
    /// at it exactly.
    public func timeToNextEvent(at now: Epoch) -> Double? {
        guard let zero = rangeZero, released == nil, scrub == nil else { return nil }
        return plan.times.map { zero + $0 - now }.filter { $0 > 0 }.min()
    }

    /// The next event for the pilot: while the count holds, T−0 as if it
    /// ran on now; then the pad's events, the start of the thrust buildup,
    /// launch commit and the release. Nil once released or scrubbed.
    public func nextEvent(at now: Epoch) -> (name: String, at: Epoch)? {
        guard released == nil, scrub == nil else { return nil }
        guard let zero = rangeZero else {
            return (String(format: "T-0, count holding at T%+.0f s (Space)", hold), now + (-hold))
        }
        var events = plan.events.map { ($0.name, zero + $0.time) }
        for s in plan.starts { events.append(("\(s.engine) start", zero + s.command)) }
        events.append(("launch commit (T-0)", zero + plan.commit))
        events.append(("hold-down release", zero + plan.release))
        return events.filter { $0.1 > now }.min { $0.1 < $1.1 }
    }

    /// The controlled release's pull on `v` (ICRF, N) with its structure's
    /// origin at `position` + `attitude`(`structureOrigin`) and the body
    /// turned as `o`: along the pad's down while it has risen less than the
    /// stroke, after the release. Nil when nothing holds it back.
    func restraint(_ v: Vessel) -> ((_ position: Vec3, _ attitude: Quat, _ o: BodyOrientation) -> Vec3)? {
        guard v === vehicle, released != nil, let crm = plan.controlledRelease, let pad,
              v.reference === pad.body, (lastRise?.rise ?? 0) < crm.stroke else { return nil }
        let origin = v.structureOrigin
        return { position, attitude, o in
            let point = o.icrfToBody * (position + attitude.rotate(origin))
            let rise = (point - pad.point).dot(pad.up)
            let f = crm.force(atRise: rise)
            return f > 0 ? o.toInertial(pad.up) * -f : .zero
        }
    }

    /// The controlled release's force on `v` standing on the pad, N: the
    /// rods' whole force once released, until the vehicle has risen through
    /// their stroke; 0 otherwise. To leave the pad its thrust must exceed
    /// its weight and this (`Simulation.stepLanded`).
    func restraintOnThePad(_ v: Vessel) -> Double {
        guard v === vehicle, released != nil, let crm = plan.controlledRelease,
              (lastRise?.rise ?? 0) < crm.stroke else { return 0 }
        return crm.force(atRise: 0)
    }

    /// The vehicle's rise off the pad now, m: its structure's origin along
    /// the pad's up from where it stood. Nil off its body.
    public func rise(of v: Vessel, snapshot s: SystemSnapshot) -> Double? {
        guard let pad, v.reference === pad.body else { return nil }
        let o = s.orientation(pad.body)
        let point = o.icrfToBody * v.inertialPosition(ofStructuralPoint: .zero)
        return (point - pad.point).dot(pad.up)
    }

    /// At the end of each of the simulation's steps, after the release:
    /// first motion once the vehicle has left the pad (the start of the step
    /// it lifted off in), the liftoff switches at their rise, and the rise
    /// itself until it is past them and the controlled release's stroke. So
    /// a frame's record says what happened in its last step.
    public func stepped(_ v: Vessel, in sim: Simulation) {
        guard v === vehicle, released != nil else { return }
        let now = sim.time
        if firstMotion == nil, v.landed == nil { firstMotion = lastStanding ?? released }
        let watched = max(plan.liftoffSwitchRise, plan.controlledRelease?.stroke ?? 0)
        guard firstMotion != nil, (lastRise?.rise ?? 0) < watched, let rise = rise(of: v, snapshot: sim.snapshot)
        else { return }
        if liftoffSwitch == nil, rise >= plan.liftoffSwitchRise {
            var at = now
            if let last = lastRise, rise > last.rise {
                let u = (plan.liftoffSwitchRise - last.rise) / (rise - last.rise)
                at = last.time + u * (now - last.time)
            }
            liftoffSwitch = at
            record("liftoff switches", at: at, sim)
        }
        lastRise = (now, rise)
    }

    // MARK: Inside

    /// Every tank at its load plus what the engines have not burned by range
    /// time `t` of what they were to burn by the release: from `t`, or from
    /// where an engine stopped.
    private func bookTanks(rangeTime t: Double) {
        for (tank, load, flows) in tanks {
            var extra = 0.0
            for (i, flow) in flows.enumerated() where flow > 0 {
                extra += flow * plan.flowIntegral(i, from: min(t, stops[i] ?? t), to: plan.release)
            }
            tank.mass = load + extra
        }
    }

    private func record(_ event: String, at time: Epoch, _ sim: Simulation?) {
        log.append((time, event))
        if let sim, let v = vehicle { sim.log("\(v.name): \(event)") }
    }
}

extension TerminalCount.Plan {
    /// AS-506's count from the S-IC intertank arm's retract command to the
    /// release (`AS506`): guidance reference release at T−17 s, the
    /// ignition command at T−8.9 s, FER-506's 1-2-2 start (engine 5 at
    /// T−6.4 s, 1 and 3 at −6.1 s, 4 at −6.0 s, 2 at −5.9 s, each igniting
    /// 3.35 s later and rising to full thrust over 1.15 s), the flow before
    /// ignition that makes FER Table 20-9's 39,307 kg of thrust buildup by
    /// first motion at the model's flow, thrust OK at 90 % by T−0, and the
    /// release at 0.30 s with eight rods' controlled release over the first
    /// 6 in of rise.
    public static var as506: TerminalCount.Plan {
        typealias D = AS506
        let starts = D.engineStarts.map {
            TerminalCount.Start(engine: "S-IC engine \($0.engine)", command: $0.command,
                                ignition: $0.command + D.f1IgnitionDelay)
        }
        // Σ_i ṁ (startFlow (ignition_i − command_i) + (release − ignition_i)
        // − rise/2) = the buildup propellant.
        let flow = D.f1.massFlow, rise = D.f1ThrustRise
        let thrusting = starts.reduce(0) { $0 + (D.holdDownRelease - $1.ignition) - rise / 2 }
        let leads = starts.reduce(0) { $0 + ($1.ignition - $1.command) }
        let startFlow = (D.thrustBuildupPropellant / flow - thrusting) / leads
        return TerminalCount.Plan(
            events: [.init("S-IC intertank arm retract", D.sICIntertankArmCommand),
                     .init(guidanceReferenceRelease, D.guidanceReferenceRelease),
                     .init("S-IC forward arm retract", D.sICForwardArmCommand),
                     .init("ignition sequence start", D.ignitionCommand)],
            starts: starts, rise: rise, startFlow: startFlow, stage: "S-IC", commit: D.launchCommit,
            thrustOK: D.sICThrustOK, release: D.holdDownRelease, controlledRelease: D.controlledRelease,
            liftoffSwitchRise: D.liftoffSwitchRise)
    }
}
