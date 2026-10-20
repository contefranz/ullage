import Foundation

/// The LVDC's pre-IGM pitch program for the S-IC (Boeing D5-15706-4, Table
/// 4-II): the commanded pitch attitude chi_Y (rad; negative tilts the nose
/// downrange) as a quartic in t, the time from liftoff (T1), with a separate
/// coefficient set on each segment, frozen at the tilt arrest. The IU starts
/// it, with the roll program, once tower clearance is assured.
public struct TiltProgram {
    /// Segment boundaries t_S1, t_S2, ... (s from T1): segment k applies from
    /// boundary k-1 (inclusive) to boundary k (exclusive).
    public var boundaries: [Double]
    /// Coefficients F_k0 ... F_k4 of each segment (deg, deg/s, deg/s^2 ...).
    public var coefficients: [[Double]]
    /// Tilt arrest, s from T1: the command holds its value from here.
    public var arrest: Double

    public init(boundaries: [Double], coefficients: [[Double]], arrest: Double) {
        precondition(coefficients.count == boundaries.count + 1, "one coefficient set per segment")
        self.boundaries = boundaries
        self.coefficients = coefficients
        self.arrest = arrest
    }

    /// The pitch command at `t` s from T1, held after the arrest (rad).
    public func pitch(at t: Double) -> Double { pitch(at: t, bias: 0, arrest: arrest) }

    /// The pitch command at `t` s from T1 with the polynomial run `bias` s
    /// behind (GE504's t_c - Δt_f after an S-IC engine-out freeze), held
    /// from `arrest` on: its value at `arrest` - `bias` (rad).
    public func pitch(at t: Double, bias: Double, arrest: Double) -> Double {
        let tc = min(t, arrest) - bias
        let k = boundaries.firstIndex { tc < $0 } ?? boundaries.count
        let degrees = coefficients[k].reversed().reduce(0.0) { $0 * tc + $1 }
        return degrees * .pi / 180
    }
}

/// The Saturn V Instrument Unit's flight program (LVDC and flight control
/// computer) for Apollo 11: the S-IC's open-loop attitude programs, then
/// iterative guidance (IGM) through the S-II and S-IVB. It runs the flight
/// sequence on the IU's time bases:
///
/// - T1 starts at liftoff. The tower-clearance yaw, then, once the vehicle
///   has risen clear of the tower, the roll program from the pad azimuth to
///   the flight azimuth and the pitch program until the tilt arrest, all
///   relative to the space-fixed frame fixed at guidance reference release,
///   with each commanded angle rate-limited. The outboard F-1 cant and the
///   S-IC flight-control gain switches.
/// - T2 when the LVDC senses the centre engine's cutoff, which T1 commands:
///   its own cutoff, not a failure of that engine.
/// - T3 when it senses the S-IC outboard cutoff (LOX depletion): separation,
///   S-II ignition, S-II gains, aft interstage and LET jettison, iterative
///   guidance, S-II centre cutoff.
/// - T4 when it senses the S-II cutoff (LOX depletion): separation and S-IVB
///   ignition, whose J-2 flies the vehicle's own `tvcGains` law.
/// - T5 when it senses the S-IVB cutoff: APS ullage burn, then the local
///   horizontal in orbit, the command moving there within the orbital rate
///   limits.
///
/// Engine failures come from a schedule (`scheduleFailure`), each applied at
/// the start of the step at its time. The IU senses an engine out, one it
/// did not cut off itself, when the engine's thrust falls below its stage's
/// thrust OK level: on the S-IC from `EngineOut.sensingStart` until T3,
/// with GE504's chi freeze of the pitch program and a later tilt arrest for
/// the first; on the S-II from mainstage until T4, where iterative guidance
/// stretches its stage 2 burn by the engines its presettings assume over
/// those left. Losing every engine of a stage starts the next time base.
/// Aborts are logged, not flown.
///
/// From its start event to the S-IVB cutoff the attitude comes from the
/// iterative guidance mode (`IterativeGuidance`), run on its own cycle with
/// the vehicle's state in the space-fixed frame. It commands the S-II
/// mixture-ratio shift, which sets off the plan's shift event, and cuts the
/// S-IVB off on velocity: the step ends on the predicted cutoff.
///
/// Each time base runs its own switch-selector events; when the next one
/// starts, the earlier ones' pending events are dropped, as the LVDC moved to
/// the new base's table. The IU stages by part and skips a part already
/// gone, so a pilot's Space press from T3 on does the sequence no harm; the
/// S-II dropped by hand starts T4 early, which leaves the S-II's remaining
/// events behind. Before T3 it refuses manual staging. It sets
/// `.attitudeHold` at T1 and writes `attitudeCommand` every step. A pilot who
/// gives manual input, or selects another mode, flies the attitude while the
/// IU keeps the sequence. When the hold flies again (input released, or key
/// 8), the IU restarts its command from the attitude then and returns to its
/// program within its command rate limits.
public final class SaturnIU: FlightProgram {
    public enum TimeBase: Int, CaseIterable, Comparable, CustomStringConvertible {
        case t1 = 1, t2, t3, t4, t5
        public var description: String { "T\(rawValue)" }
        public static func < (a: TimeBase, b: TimeBase) -> Bool { a.rawValue < b.rawValue }
    }

    /// What a timed event does.
    public enum Action: Equatable {
        /// Shut down the named engine.
        case engineCutoff(String)
        case mainThrottle(Double)
        /// Separate the staging event of the named part, if still attached.
        case separate(String)
        /// New operating setting for the main engines of the named part,
        /// reached over `ramp` s (0: at once; `Thruster.setRating`), and,
        /// if given, the change of its performance over the rest of the
        /// burn, its times from this event (in place of the engines'
        /// schedule; nil keeps theirs).
        case rating(part: String, EngineRating, ramp: Double = 0, schedule: PerformanceSchedule? = nil)
        /// Start ramping the outboard cant of the named part's engines.
        case startCant(String)
        case gains(FCCGains?)
        case ullage(Bool)
        /// Light the solid motors whose names start with the given prefix.
        case ignite(String)
        /// Start iterative guidance (IGM phase 1).
        case iterativeGuidance
        case localHorizontal
        /// Nothing but the log entry.
        case note
    }

    public struct Event: Equatable {
        public var base: TimeBase
        /// Seconds after the time base starts.
        public var offset: Double
        public var name: String
        public var action: Action
        public init(_ base: TimeBase, _ offset: Double, _ name: String, _ action: Action) {
            self.base = base
            self.offset = offset
            self.name = name
            self.action = action
        }
    }

    /// The flight program's data.
    public struct Plan {
        /// Seconds from first motion (hold-down release) to T1.
        public var liftoffDelay: Double
        /// Seconds from guidance reference release to T1: the space-fixed
        /// frame is the launch vertical and flight azimuth at that instant.
        public var referenceToLiftoff: Double
        /// Flight azimuth, rad from north.
        public var flightAzimuth: Double
        /// Tower-clearance yaw: angle (rad, nose towards +Y of the space-fixed
        /// frame), and when the command steps to it and back to 0 (s from T1).
        public var towerYaw: (angle: Double, start: Double, end: Double)
        /// The roll program (to zero roll in the space-fixed frame) and the
        /// pitch program start once the vehicle has risen `rise` metres, or
        /// at `backup` s from T1.
        public var programStart: (rise: Double, backup: Double)
        public var tilt: TiltProgram
        /// Limit on the rate of each commanded angle until the S-IVB cutoff
        /// (T5), rad/s.
        public var commandRateLimit: Double
        /// The limits from T5 on (roll, pitch, yaw), rad/s: on the commanded
        /// angles until the turn to the local horizontal, then on the
        /// command's rate about each of its axes.
        public var coastRateLimit: Vec3
        /// Outboard cant: radial angle (rad, thrust lines inwards) and ramp rate (rad/s).
        public var cant: (angle: Double, rate: Double)
        public var sequence: [Event]
        /// The parts whose cutoffs the LVDC senses to start T3, T4 and T5,
        /// and the centre engine whose cutoff starts T2.
        public var stages: (first: String, second: String, third: String)
        public var centreEngine: String
        /// Iterative guidance, from the `.iterativeGuidance` event to the S-IVB cutoff.
        public var guidance: Guidance?
        /// Engine-out sensing and reactions.
        public var engineOut = EngineOut.as506
    }

    /// The IU's engine-out logic (datasheet §16): when it senses an engine
    /// out, and the S-IC chi freeze's presettings (GE504 Table 4-II and
    /// Figure 3-4).
    public struct EngineOut {
        /// Fractions of rated thrust below which the IU senses an engine of
        /// the first and of the second stage out (thrust OK switches).
        public var thrustOK: (first: Double, second: Double)
        /// The first stage's engines are sensed from this time (s from T1)
        /// until T3; the second stage's from mainstage (one of its engines
        /// at its thrust OK level) until T4.
        public var sensingStart: Double
        /// The freeze schedule's times t_2 ... t_5 (s from T1) and lines
        /// B11 t + B12, B21 t + B22 (s).
        public var freezeTimes: (t2: Double, t3: Double, t4: Double, t5: Double)
        public var freezeLines: (b11: Double, b12: Double, b21: Double, b22: Double)
        /// Until this time (s from T1) a second first-stage engine out sets
        /// off the EDS automatic abort (logged only).
        public var autoAbortEnd: Double
        /// Range time of T1, for failures scheduled in range time.
        public var liftoffRangeTime: Double

        public init(thrustOK: (first: Double, second: Double), sensingStart: Double,
                    freezeTimes: (t2: Double, t3: Double, t4: Double, t5: Double),
                    freezeLines: (b11: Double, b12: Double, b21: Double, b22: Double),
                    autoAbortEnd: Double, liftoffRangeTime: Double) {
            self.thrustOK = thrustOK
            self.sensingStart = sensingStart
            self.freezeTimes = freezeTimes
            self.freezeLines = freezeLines
            self.autoAbortEnd = autoAbortEnd
            self.liftoffRangeTime = liftoffRangeTime
        }

        /// AS-506's: GE504's SA-504 presettings for the freeze, MAN506's
        /// thrust OK levels and EDS limit (`AS506`, datasheet §16).
        public static var as506: EngineOut {
            EngineOut(thrustOK: (AS506.sICThrustOK, AS506.sIIThrustOK), sensingStart: AS506.sICEngineOutSensingStart,
                      freezeTimes: AS506.engineOutFreezeTimes, freezeLines: AS506.engineOutFreezeLines,
                      autoAbortEnd: AS506.edsAutoAbortEnd, liftoffRangeTime: AS506.liftoff)
        }

        /// The chi freeze for a first-stage engine out sensed at `t` s from
        /// T1 (GE504 Table 4-II): it starts at t, or at t_2 for t up to t_2,
        /// and lasts `duration` s (0: none).
        public func freeze(failure t: Double) -> (start: Double, duration: Double) {
            let f = freezeTimes, b = freezeLines
            if t <= f.t2 { return (f.t2, f.t3) }
            if t <= f.t4 { return (t, b.b11 * t + b.b12) }
            if t <= f.t5 { return (t, b.b21 * t + b.b22) }
            return (t, 0)
        }

        /// The tilt arrest after a first-stage engine out at `t` s from T1:
        /// t_AR + (t_AR - t)/4 (GE504 Table 4-II). One after the arrest
        /// leaves it, as the LVDC already holds the command.
        public func arrest(_ tAR: Double, failure t: Double) -> Double { t < tAR ? tAR + (tAR - t) / 4 : tAR }
    }

    /// An engine failure to inject: the named engine fails at `time`
    /// (`scheduleFailure`). It stops as on a cutoff, and nothing restarts it.
    public struct EngineFailure: Equatable {
        public enum Time: Equatable {
            /// Range time, s (T1 at the plan's `engineOut.liftoffRangeTime`).
            case range(Double)
            /// Seconds after a time base starts.
            case timeBase(TimeBase, Double)
            /// An epoch: `sim.time` fails the engine at the start of the next step.
            case epoch(Epoch)
        }
        public var engine: String
        public var time: Time
        public init(engine: String, time: Time) {
            self.engine = engine
            self.time = time
        }
    }

    /// The IGM's presettings (μ is set from the vehicle's reference body),
    /// its cycle (s), and the event its mixture-ratio-shift command sets off,
    /// `shift.delay` s later.
    public struct Guidance {
        public var presettings: IGMPresettings
        public var cycle: Double
        public var shift: (delay: Double, name: String, action: Action)
        public init(presettings: IGMPresettings, cycle: Double, shift: (delay: Double, name: String, action: Action)) {
            self.presettings = presettings
            self.cycle = cycle
            self.shift = shift
        }
    }

    public let plan: Plan

    // MARK: State

    /// When each time base started.
    public private(set) var timeBases: [TimeBase: Epoch] = [:]
    /// Commanded attitude angles relative to the space-fixed frame, rad:
    /// roll, pitch, yaw (x, y, z), applied pitch, then yaw, then roll. The
    /// tilt downrange is a negative pitch.
    public private(set) var chi = Vec3.zero
    /// Attitude (body -> ICRF) of a body aligned with the space-fixed frame:
    /// +x the launch vertical, +z the flight azimuth, +y to its right.
    public private(set) var spaceFixed: Quat?
    public private(set) var status = "on the pad"
    /// What the IU did and when (the scheduled time of a timed event; a
    /// detected one at the step that saw it), in order.
    public private(set) var log: [(time: Epoch, event: String)] = []

    private var done = Set<Int>()
    private var lastLanded: Epoch?
    private var firstMotion: Epoch?
    private var lastUpdate: Epoch?
    private var initialRoll = 0.0
    private var startRadius = 0.0
    /// When the roll and pitch programs started, s from T1.
    public private(set) var programStarted: Double?
    private var tiltArrested = false
    private var cantStart: (part: String, at: Epoch)?
    private var ullageOn = false
    private var secondStageLit = false
    private var thirdStageLit = false
    private var pilotHasAttitude = false
    /// After a hand-back under the FCC law, until the vehicle's turn is damped.
    private var settlingAfterHandBack = false
    private var localHorizontal = false
    private var lastCommand: Quat?

    /// The IGM while it guides, and its last command (pitch, yaw; rad).
    public private(set) var guidance: IterativeGuidance?
    public private(set) var guidanceCommand: (pitch: Double, yaw: Double)?
    private var guidanceDone = false
    /// The IGM cut the S-IVB off on velocity (not the pilot or depletion).
    private var guidanceCutoff = false
    private var lastCycle: Epoch?
    /// ∫F/m dt since the last guidance cycle, and the S-II's characteristic
    /// velocity (∫F/m dt from its ignition to its cutoff), m/s.
    private var sensedSinceCycle = 0.0
    public private(set) var characteristicVelocity = 0.0
    private var cutoffAt: Epoch?
    /// Events the IGM set off: (when, name, action).
    private var pending: [(at: Epoch, name: String, action: Action)] = []
    /// The rating ramps started (when, and how long): their cells' ends end steps.
    private var ratingRamps: [(start: Epoch, duration: Double)] = []

    /// The failures scheduled, and those that have happened (by index).
    public private(set) var failureSchedule: [EngineFailure] = []
    private var failuresDone = Set<Int>()
    /// The engines the IU cut off itself (its `.engineCutoff` events).
    private var ownCutoffs = Set<String>()
    /// The engines it sensed out, and when, in order.
    public private(set) var enginesOut: [(engine: String, time: Epoch)] = []
    /// The S-II has reached mainstage: its engines are sensed from here.
    private var secondStageMainstage = false
    /// The S-IC engine-out chi freeze (s from T1), from the first S-IC engine
    /// out (GE504's T_EO1), and the tilt arrest (s from T1), moved out by it.
    public private(set) var chiFreeze: (start: Double, duration: Double)?
    public private(set) var tiltArrest: Double
    /// The engines the IGM's stage 2 presettings assume over those of them
    /// not sensed out (1 with none out).
    public private(set) var stage2EngineFactor = 1.0

    public init(plan: Plan) {
        self.plan = plan
        tiltArrest = plan.tilt.arrest
    }

    /// Fail the named engine at `time`: at the start of the step there, the
    /// simulation ending a step on it at any time warp. An engine already
    /// gone or failed then is logged as such.
    public func scheduleFailure(of engine: String, at time: EngineFailure.Time) {
        failureSchedule.append(EngineFailure(engine: engine, time: time))
    }

    /// Euler angles of `attitude` (body -> ICRF) in the space-fixed frame, in
    /// the IU's convention: (roll, pitch, yaw) = (x, y, z), rad, for the
    /// rotations pitch, then yaw, then roll. Nil before T1.
    public func eulerAngles(of attitude: Quat) -> Vec3? {
        guard let frame = spaceFixed else { return nil }
        let q = frame.conjugate * attitude
        let x = q.rotate(.unitX), y = q.rotate(.unitY), z = q.rotate(.unitZ)
        return Vec3(atan2(-z.y, y.y), atan2(-x.z, x.x), asin(max(-1, min(1, x.y))))
    }

    // MARK: FlightProgram

    public func update(_ v: Vessel, in sim: Simulation) {
        let now = sim.time
        defer { lastUpdate = now }
        applyDueFailures(v, sim, now: now)
        if v.landed != nil {
            lastLanded = now
            startRadius = v.position.length
            return
        }
        if firstMotion == nil {
            firstMotion = lastLanded ?? now
            // Never seen on the ground: rise from here.
            if lastLanded == nil { startRadius = v.position.length }
        }
        if timeBases[.t1] == nil {
            let t1 = firstMotion! + plan.liftoffDelay
            guard now - t1 >= -1e-9 else {
                status = "first motion"
                return
            }
            startT1(at: t1, v, sim)
        }
        detectTimeBases(v, now: now)
        // A failure on a time base that started just now.
        applyDueFailures(v, sim, now: now)
        senseEngineOut(v, sim, now: now)
        runDueEvents(v, sim, now: now)
        runGuidance(v, sim, now: now)
        if let cant = cantStart { applyCant(v, part: cant.part, since: now - cant.at) }
        if ullageOn { v.translationInput.x = 1 }
        // Back from the pilot: restart the command from the attitude now.
        // Under the FCC law it keeps restarting it while the vehicle still
        // turns faster than twice the command rate limit, so the law first
        // only damps what the pilot left: a command restarted from a fast
        // spin falls behind the attitude, and its error wraps past half a
        // turn into pitch and yaw (a 1 s roll tap in the S-IC burn leaves
        // about 120°/s with FER Table 20-10's roll inertia).
        let pilot = v.autopilot != .attitudeHold || !v.rotationInput.isZero
        if pilotHasAttitude && !pilot {
            settlingAfterHandBack = true
            log.append((now, "attitude back to the IU"))
        }
        if pilot { settlingAfterHandBack = false }
        if settlingAfterHandBack, let angles = eulerAngles(of: v.attitude) {
            chi = angles
            lastCommand = v.attitude
            settlingAfterHandBack = v.fccGains != nil && v.angularVelocity.length > 2 * plan.commandRateLimit
        }
        pilotHasAttitude = pilot
        commandAttitude(v, sim, now: now)
        status = statusLine(v, now: now)
    }

    /// The pilot may stage from T3 on: before it, Space would drop the S-IC
    /// on the pad, or full and burning in flight. While the S-IVB burns only
    /// its ullage motors' cases may go (event 5): Space would otherwise
    /// separate the spacecraft from a burning S-IVB.
    public func allowsManualStaging(of vessel: Vessel) -> Bool {
        guard timeBases[.t3] != nil else { return false }
        return !stageFiring(vessel, plan.stages.third) || vessel.nextStagingEvent == 5
    }

    /// The IU rides in its own part, and leaves with it: with the S-IVB at
    /// the CSM's separation.
    public var hostPart: String? { "IU" }

    public func timeToNextEvent(at now: Epoch) -> Double? {
        var next: Double?
        if timeBases[.t1] == nil, let m = firstMotion { next = m + plan.liftoffDelay - now }
        for (i, e) in plan.sequence.enumerated() where !done.contains(i) {
            guard let base = timeBases[e.base] else { continue }
            let dt = base + e.offset - now
            if dt > 0 { next = min(next ?? dt, dt) }
        }
        for e in pending where e.at > now { next = min(next ?? (e.at - now), e.at - now) }
        for (i, f) in failureSchedule.enumerated() where !failuresDone.contains(i) {
            guard let at = epoch(of: f), at > now else { continue }
            next = min(next ?? (at - now), at - now)
        }
        if let c = cutoffAt, c > now { next = min(next ?? (c - now), c - now) }
        // The ends of a rating ramp's cells (`Thruster.setRating`): each step
        // then lies in one cell, and the ramp's impulse does not depend on
        // the steps, at any warp.
        for r in ratingRamps {
            let n = Thruster.rampCells(r.duration), cell = r.duration / Double(n), elapsed = now - r.start
            guard elapsed < r.duration - 1e-6 else { continue }
            let k = min(Double(n), ((elapsed + 1e-6) / cell).rounded(.down) + 1)
            let dt = r.start + k * cell - now
            if dt > 0 { next = min(next ?? dt, dt) }
        }
        // The next IGM cycle ends a step, so the cycles stay `cycle` s apart
        // at any time warp (within the gate's slack, no step is needed).
        if let last = lastCycle, let g = plan.guidance, let igm = guidance, !igm.highSpeedLoop {
            let c = last + g.cycle - now
            if c > 1e-4 { next = min(next ?? c, c) }
        }
        return next
    }

    // MARK: Sequencing

    private func startT1(at t1: Epoch, _ v: Vessel, _ sim: Simulation) {
        timeBases[.t1] = t1
        log.append((t1, "T1: liftoff"))
        sim.log("\(v.name): IU T1, liftoff")
        let frame = spaceFixedFrame(at: v.position, of: v.reference, orientation: sim.snapshot.orientation(v.reference))
        spaceFixed = frame
        // The vehicle's roll in that frame (Position I's azimuth against the
        // flight azimuth); it starts the roll program from there.
        let zS = (frame.conjugate * v.attitude).rotate(.unitZ)
        initialRoll = atan2(-zS.y, zS.z)
        chi = Vec3(initialRoll, 0, 0)
        v.autopilot = .attitudeHold
    }

    /// The space-fixed frame (PACSS 13) the IU fixes for a vehicle at
    /// `position` (relative to `body`) at liftoff, when `body` turns as
    /// `o`: launch vertical and flight azimuth at guidance reference
    /// release, before the Earth turned the pad on.
    public func spaceFixedFrame(at position: Vec3, of body: CelestialBody, orientation o: BodyOrientation) -> Quat {
        let back = Quat(axis: o.angularVelocity, angle: -o.angularVelocity.length * plan.referenceToLiftoff)
        // X_S is the plumb line, opposite local gravity (GE504 Fig 1-1): the
        // reference body's gravity and its rotation's centrifugal term, which
        // on the Earth tilt it from the radial as the geodetic vertical is.
        let plumb = body.gravity(at: position, pole: o.pole)
            - o.angularVelocity.cross(o.angularVelocity.cross(position))
        let up = -plumb.normalized
        let east = o.pole.cross(up).normalized, north = up.cross(east)
        let downrange = north * cos(plan.flightAzimuth) + east * sin(plan.flightAzimuth)
        let x = back.rotate(up), z = back.rotate(downrange)
        return Quat(matrix: Mat3(columns: x, z.cross(x), z))
    }

    /// Pick the program up after the S-IVB's cutoff, at `now`, on `v`: its
    /// time bases at `bases` (T1 to T5), its space-fixed frame `frame`, the
    /// IGM done on its velocity cutoff, every event due by `now` done (the
    /// APS ullage running if it is on by then) and the later ones to come.
    /// The attitude command starts from `v`'s attitude, which the IU holds
    /// until its turn to the local horizontal. A parking-orbit scenario
    /// starts here (`as506InParkingOrbit`).
    public func resume(after bases: [TimeBase: Epoch], spaceFixed frame: Quat, on v: Vessel, at now: Epoch) {
        precondition(bases[.t1] != nil && bases[.t5] != nil, "resuming needs T1 and T5")
        timeBases = bases
        spaceFixed = frame
        firstMotion = bases[.t1].map { $0 + (-plan.liftoffDelay) }
        programStarted = plan.programStart.backup
        tiltArrested = true
        secondStageLit = true
        secondStageMainstage = true
        thirdStageLit = true
        guidance = nil
        guidanceDone = true
        guidanceCutoff = true
        for (i, e) in plan.sequence.enumerated() {
            guard let base = bases[e.base], base + e.offset <= now + 1e-9 else { continue }
            done.insert(i)
            switch e.action {
            case .ullage(let on): ullageOn = on
            case .localHorizontal: localHorizontal = true
            case .gains(let g): v.fccGains = g
            default: break
            }
        }
        for (b, t) in bases.sorted(by: { $0.key < $1.key }) { log.append((t, "\(b): resumed")) }
        chi = eulerAngles(of: v.attitude) ?? .zero
        lastCommand = v.attitude
        lastUpdate = now
        v.autopilot = .attitudeHold
        v.attitudeCommand = AttitudeCommand(attitude: v.attitude)
        status = statusLine(v, now: now)
    }

    /// The time bases the LVDC starts on sensing a cutoff, at the first step
    /// that sees it: T2 the centre engine's, T3 and T4 the S-IC's and S-II's
    /// burnout (or the stage gone), T5 the S-IVB's cutoff once it has fired.
    private func detectTimeBases(_ v: Vessel, now: Epoch) {
        func part(_ name: String) -> VesselPart? { v.parts.first { $0.name == name } }
        func burnedOut(_ name: String) -> Bool {
            guard let p = part(name) else { return true }
            return !p.thrusters.contains { $0.groups.contains(.main) && $0.isAvailable && $0.hasPropellant }
        }
        func firing(_ name: String) -> Bool { stageFiring(v, name) }
        func start(_ b: TimeBase, _ what: String) {
            timeBases[b] = now
            log.append((now, "\(b): \(what) sensed"))
            // The LVDC leaves the earlier time bases' tables. The IGM start is
            // the guidance equations' own timer (GE504 Fig 4-1), not a table
            // entry: it stands until the S-IVB cutoff.
            for (i, e) in plan.sequence.enumerated()
            where e.base < b && (e.action != .iterativeGuidance || b == .t5) {
                done.insert(i)
            }
            // The S-IVB cut off (by the IGM, the pilot, or out of propellant):
            // no more IGM, whether or not it had started.
            if b == .t5 {
                guidance = nil
                guidanceDone = true
                cutoffAt = nil
            }
        }
        // T2 on the IU's own centre engine cutoff, not on a failure of that
        // engine: T1's later events (gain switches, cant, the cutoff) stand.
        if timeBases[.t2] == nil
            && (ownCutoffs.contains(plan.centreEngine) || !v.thrusters.contains { $0.name == plan.centreEngine }) {
            start(.t2, "centre engine cutoff")
        }
        if timeBases[.t3] == nil && burnedOut(plan.stages.first) {
            if timeBases[.t2] == nil { start(.t2, "centre engine cutoff") }
            start(.t3, "S-IC outboard engine cutoff")
        }
        if timeBases[.t3] != nil && timeBases[.t4] == nil {
            if burnedOut(plan.stages.second) {
                start(.t4, "S-II outboard engine cutoff")
            } else if firing(plan.stages.second) {
                secondStageLit = true
            }
        }
        if timeBases[.t4] != nil && timeBases[.t5] == nil && part(plan.stages.third) != nil {
            if firing(plan.stages.third) { thirdStageLit = true } else if thirdStageLit { start(.t5, "S-IVB cutoff") }
        }
    }

    private func runDueEvents(_ v: Vessel, _ sim: Simulation, now: Epoch) {
        while true {
            let due = plan.sequence.enumerated().compactMap { (i, e) -> (Int, Epoch)? in
                guard !done.contains(i), let base = timeBases[e.base], base + e.offset <= now + 1e-9 else { return nil }
                return (i, base + e.offset)
            }
            let next = due.min { $0.1 < $1.1 }
            if let k = pending.indices.min(by: { pending[$0].at < pending[$1].at }), pending[k].at <= now + 1e-9,
               next.map({ pending[k].at < $0.1 }) ?? true {
                let e = pending.remove(at: k)
                let note = cutoffNote(e.action, v)
                record(perform(e.action, at: e.at, v, sim) ? e.name + note : "\(e.name) (nothing to do: gone)", at: e.at, v, sim)
                continue
            }
            guard let (i, at) = next else { return }
            done.insert(i)
            let e = plan.sequence[i]
            let note = cutoffNote(e.action, v)
            record(perform(e.action, at: at, v, sim) ? e.name + note : "\(e.name) (nothing to do: gone)", at: at, v, sim)
        }
    }

    /// For the log, an engine cutoff of an engine already out (failed or
    /// sensed out), or with other engines of its stage sensed out.
    private func cutoffNote(_ action: Action, _ v: Vessel) -> String {
        guard case .engineCutoff(let name) = action,
              let part = v.parts.first(where: { $0.thrusters.contains { $0.name == name } }) else { return "" }
        let out = enginesOut.map(\.engine).filter { n in part.thrusters.contains { $0.name == n } }
        if out.contains(name) || part.thrusters.first(where: { $0.name == name })?.isFailed == true {
            return " (engine already out)"
        }
        return out.isEmpty ? "" : " (with \(out.joined(separator: ", ")) out)"
    }

    private func record(_ name: String, at: Epoch, _ v: Vessel, _ sim: Simulation) {
        log.append((at, name))
        sim.log("\(v.name): \(name)")
    }

    /// Carry out `action`; false when its part or engine is gone.
    private func perform(_ action: Action, at: Epoch, _ v: Vessel, _ sim: Simulation) -> Bool {
        switch action {
        case .engineCutoff(let name):
            guard let engine = v.thrusters.first(where: { $0.name == name }) else { return false }
            engine.isEnabled = false
            ownCutoffs.insert(name)
        case .mainThrottle(let level):
            v.mainThrottle = level
        case .separate(let name):
            guard let part = v.parts.first(where: { $0.name == name }), case .event(let n) = part.staging else {
                return false
            }
            sim.stage(v, event: n)
        case let .rating(name, rating, ramp, schedule):
            guard let part = v.parts.first(where: { $0.name == name }) else { return false }
            for t in part.thrusters where t.groups.contains(.main) {
                t.setRating(rating, ramp: ramp)
                if let s = schedule { t.schedule = s.delayed(by: t.burnTime) }
            }
            if ramp > 0 { ratingRamps.append((sim.time, ramp)) }
        case .startCant(let name):
            guard v.parts.contains(where: { $0.name == name }) else { return false }
            cantStart = (name, at)
        case .gains(let g):
            v.fccGains = g
        case .ullage(let on):
            ullageOn = on
            if !on { v.translationInput.x = 0 }
        case .ignite(let prefix):
            let motors = v.thrusters.filter { $0.isSolid && $0.name.hasPrefix(prefix) }
            guard !motors.isEmpty else { return false }
            for m in motors { m.ignite() }
        case .iterativeGuidance:
            guard let g = plan.guidance, let frame = spaceFixed, guidance == nil, !guidanceDone else { return false }
            var p = g.presettings
            p.mu = v.reference.gm
            // The latitude of the space-fixed X_S: it places the Earth's axis.
            let pole = sim.snapshot.orientation(v.reference).pole
            let latitude = asin(max(-1, min(1, frame.rotate(.unitX).dot(pole))))
            guidance = IterativeGuidance(presettings: p, launchLatitude: latitude, azimuth: plan.flightAzimuth)
            lastCycle = nil
        case .localHorizontal:
            localHorizontal = true
        case .note:
            break
        }
        return true
    }

    /// Whether a main engine of the named part delivers thrust.
    private func stageFiring(_ v: Vessel, _ name: String) -> Bool {
        v.parts.first { $0.name == name }?.thrusters.contains {
            $0.groups.contains(.main) && $0.level > 0 && $0.isAvailable && $0.hasPropellant
        } ?? false
    }

    /// Bias the gimballed engines of `part` so each thrust line leans inwards
    /// by the cant angle reached `elapsed` s into the ramp (radial on each
    /// engine: both actuators share it by the engine's position).
    private func applyCant(_ v: Vessel, part name: String, since elapsed: Double) {
        guard let part = v.parts.first(where: { $0.name == name }) else {
            cantStart = nil
            return
        }
        let cant = min(plan.cant.angle, max(0, elapsed) * plan.cant.rate)
        for e in part.thrusters where e.gimbal.count == 2 {
            let r = (e.position.y * e.position.y + e.position.z * e.position.z).squareRoot()
            guard r > 0 else { continue }
            for i in e.gimbal.indices {
                // Outwards component of each actuator's tilt: the bias leans the
                // thrust the other way.
                let out = e.gimbal[i].tilt.dot(Vec3(0, e.position.y, e.position.z)) / r
                e.gimbal[i].bias = atan(-out * tan(cant))
            }
        }
    }

    // MARK: Engine out

    /// When failure `f` is due, once the time base it counts from has started.
    private func epoch(of f: EngineFailure) -> Epoch? {
        switch f.time {
        case .range(let r): return timeBases[.t1].map { $0 + (r - plan.engineOut.liftoffRangeTime) }
        case let .timeBase(b, dt): return timeBases[b].map { $0 + dt }
        case .epoch(let e): return e
        }
    }

    /// Fail the engines whose time has come, logged at their scheduled time.
    private func applyDueFailures(_ v: Vessel, _ sim: Simulation, now: Epoch) {
        for (i, f) in failureSchedule.enumerated() where !failuresDone.contains(i) {
            guard let at = epoch(of: f), at - now <= 1e-9 else { continue }
            failuresDone.insert(i)
            guard let engine = v.thrusters.first(where: { $0.name == f.engine }) else {
                record("\(f.engine) failed (nothing to do: gone)", at: at, v, sim)
                continue
            }
            if engine.isFailed {
                record("\(f.engine) failed (nothing to do: already failed)", at: at, v, sim)
                continue
            }
            engine.fail()
            record("\(f.engine) failed", at: at, v, sim)
        }
    }

    /// The engine-out discrete: a main engine of the first stage (from
    /// `sensingStart` until T3) or of the second (from its mainstage until
    /// T4) that the IU did not cut off itself, delivering under its stage's
    /// thrust OK level with the main throttle open, is sensed out, once. A
    /// closed throttle is the IU's (or the pilot's) cutoff of every engine.
    private func senseEngineOut(_ v: Vessel, _ sim: Simulation, now: Epoch) {
        guard let t1 = timeBases[.t1], v.mainThrottle > 0, timeBases[.t4] == nil else { return }
        let eo = plan.engineOut, second = timeBases[.t3] != nil
        if !second && now - t1 < eo.sensingStart { return }
        let name = second ? plan.stages.second : plan.stages.first
        guard let part = v.parts.first(where: { $0.name == name }) else { return }
        let level = second ? eo.thrustOK.second : eo.thrustOK.first
        let mains = part.thrusters.filter { $0.groups.contains(.main) && !ownCutoffs.contains($0.name) }
        func fraction(_ e: Thruster) -> Double { e.output?.fraction ?? 0 }
        if second && !secondStageMainstage {
            guard mains.contains(where: { fraction($0) >= level }) else { return }
            secondStageMainstage = true
        }
        for e in mains where fraction(e) < level && !enginesOut.contains(where: { $0.engine == e.name }) {
            enginesOut.append((e.name, now))
            record("engine out sensed: \(e.name)", at: now, v, sim)
            let out = enginesOut.filter { o in part.thrusters.contains { $0.name == o.engine } }.count
            if second { secondStageEngineOut(part, count: out, v, sim, now: now) }
            else { firstStageEngineOut(at: now - t1, count: out, v, sim, now: now) }
        }
    }

    /// The first S-IC engine out (GE504's T_EO1 latch) sets the chi freeze
    /// and moves the tilt arrest out; a second is an abort, logged only.
    private func firstStageEngineOut(at t: Double, count: Int, _ v: Vessel, _ sim: Simulation, now: Epoch) {
        let eo = plan.engineOut
        if chiFreeze == nil {
            let f = eo.freeze(failure: t)
            chiFreeze = f
            tiltArrest = eo.arrest(tiltArrest, failure: t)
            record(f.duration > 0
                   ? String(format: "S-IC engine out: chi freeze %.2f s from T1 + %.2f s, tilt arrest T1 + %.2f s",
                            f.duration, f.start, tiltArrest)
                   : String(format: "S-IC engine out: no chi freeze, tilt arrest T1 + %.2f s", tiltArrest), at: now, v, sim)
        }
        if count == 2 {
            record(t < eo.autoAbortEnd ? "EDS automatic abort: two S-IC engines out (abort not flown)"
                   : "abort limit: two S-IC engines out (abort not flown)", at: now, v, sim)
        }
    }

    /// An S-II engine out scales the IGM's stage 2 burn: by the engines its
    /// presettings assume (the stage's, less those the plan cuts itself:
    /// the centre engine) over those of them left. MAN506's flight rules on
    /// two and three engines out are logged only.
    private func secondStageEngineOut(_ part: VesselPart, count: Int, _ v: Vessel, _ sim: Simulation, now: Epoch) {
        let cut = Set(plan.sequence.compactMap { e -> String? in
            if case .engineCutoff(let n) = e.action { return n } else { return nil }
        })
        let assumed = part.thrusters.filter { $0.groups.contains(.main) && !cut.contains($0.name) }.map(\.name)
        let left = assumed.filter { n in !enginesOut.contains { $0.engine == n } }.count
        if left > 0 && Double(assumed.count) / Double(left) != stage2EngineFactor {
            stage2EngineFactor = Double(assumed.count) / Double(left)
            record(String(format: "IGM engine-out presettings: stage 2 time and tau x %.4f", stage2EngineFactor),
                   at: now, v, sim)
        }
        if count == 2 { record("S-II double engine failure: abort if control is lost (abort not flown)", at: now, v, sim) }
        if count == 3 { record("abort limit: three S-II engines out (abort not flown)", at: now, v, sim) }
    }

    // MARK: Iterative guidance

    /// The last step's thrust acceleration is what the accelerometers sensed:
    /// it goes into the cycle's mean F/m and the S-II's characteristic
    /// velocity. Every `cycle` s the IGM runs on the vehicle's state in the
    /// space-fixed frame (gravity from the reference body's model). In its
    /// high-speed loop the IU predicts the velocity cutoff from the speed's
    /// rate, the simulation ends a step there, and the IU cuts the S-IVB off.
    private func runGuidance(_ v: Vessel, _ sim: Simulation, now: Epoch) {
        let dt = lastUpdate.map { max(0, now - $0) } ?? 0
        let sensed = v.thrustAcceleration * dt
        sensedSinceCycle += sensed
        if secondStageLit && timeBases[.t4] == nil { characteristicVelocity += sensed }
        guard var igm = guidance, let frame = spaceFixed, let g = plan.guidance else { return }
        let pole = sim.snapshot.orientation(v.reference).pole
        if igm.highSpeedLoop {
            let u = v.velocity.normalized
            let rate = v.attitude.rotate(.unitX).dot(u) * v.thrustAcceleration
                + v.reference.gravity(at: v.position, pole: pole).dot(u)
            let tgo = igm.cutoffTimeToGo(speed: v.velocity.length, rate: rate)
            if tgo < 1e-3 {
                v.mainThrottle = 0
                record("S-IVB velocity cutoff (IGM)", at: now, v, sim)
                cutoffAt = nil
                guidance = nil
                guidanceDone = true
                guidanceCutoff = true
            } else {
                cutoffAt = now + tgo
            }
            return
        }
        // A cycle every `cycle` s: the slack covers the epoch's rounding (a
        // 0.02 s step adds 0.019999981 s in 1969), well inside a step.
        if let last = lastCycle, now - last < g.cycle - 1e-4 { return }
        let toS = frame.conjugate
        let interval = lastCycle.map { now - $0 }
        let fm = interval.map { $0 > 0 ? sensedSinceCycle / $0 : v.thrustAcceleration } ?? v.thrustAcceleration
        let nav = IGMNavigation(position: toS.rotate(v.position), velocity: toS.rotate(v.velocity),
                                gravity: toS.rotate(v.reference.gravity(at: v.position, pole: pole)),
                                sensedAcceleration: fm, characteristicVelocity: characteristicVelocity,
                                sIICutoff: timeBases[.t4] != nil, sIVBIgnition: thirdStageAtThrust(v),
                                stage2EngineFactor: stage2EngineFactor)
        let stage = igm.stage
        let out = igm.cycle(nav, interval: interval)
        guidance = igm
        lastCycle = now
        sensedSinceCycle = 0
        if let p = out.pitch, let y = out.yaw { guidanceCommand = (p, y) }
        if out.commandShift {
            record("EMR shift command (IGM phase 2)", at: now, v, sim)
            pending.append((now + g.shift.delay, g.shift.name, g.shift.action))
        }
        if igm.stage != stage && igm.stage == .coast { record("IGM phase 3: steering frozen", at: now, v, sim) }
        if igm.stage != stage && igm.stage == .third { record("IGM steering on the S-IVB", at: now, v, sim) }
        if out.beganTerminalGuidance { record("terminal guidance", at: now, v, sim) }
        if out.enteredHighSpeedLoop { record("chi freeze: high-speed cutoff loop", at: now, v, sim) }
    }

    /// The S-IVB's J-2 delivers 90 % of its thrust: GE504's "S-IVB ignition".
    private func thirdStageAtThrust(_ v: Vessel) -> Bool {
        v.parts.first { $0.name == plan.stages.third }?.thrusters.contains {
            $0.groups.contains(.main) && $0.thrust(ambientPressure: 0, seaLevelPressure: 0) >= 0.9 * $0.maxThrustVacuum
                && $0.maxThrustVacuum > 0
        } ?? false
    }

    // MARK: Attitude

    private func commandAttitude(_ v: Vessel, _ sim: Simulation, now: Epoch) {
        guard let frame = spaceFixed, let t1 = timeBases[.t1] else { return }
        let dt = lastUpdate.map { max(0, now - $0) } ?? 0
        let command: Quat
        if localHorizontal {
            // Orbital attitude: +x along the horizontal velocity, +z (Position
            // I) towards the Earth, turning at the orbital rate. The command
            // moves there within the orbital rate limits about each axis.
            let r = v.position, vel = v.velocity
            let down = -r.normalized, x = (vel - r.normalized * vel.dot(r.normalized)).normalized
            let target = Quat(matrix: Mat3(columns: x, down.cross(x), down))
            var rate = r.cross(vel) / r.lengthSquared
            if let last = lastCommand {
                let turn = rotationVector(last.conjugate * target)   // the command's body axes
                let limit = plan.coastRateLimit * dt
                let step = Vec3(max(-limit.x, min(limit.x, turn.x)), max(-limit.y, min(limit.y, turn.y)),
                                max(-limit.z, min(limit.z, turn.z)))
                if (step - turn).length > 1e-12 {
                    command = step.length > 0 ? last * Quat(axis: step, angle: step.length) : last
                    rate = dt > 0 ? last.rotate(step) / dt : .zero
                } else {
                    command = target
                }
            } else {
                command = target
            }
            v.attitudeCommand = AttitudeCommand(attitude: command, rate: rate)
            lastCommand = command
            return
        }
        let t = now - t1
        if programStarted == nil && (v.position.length - startRadius >= plan.programStart.rise
                                     || t >= plan.programStart.backup) {
            programStarted = t
            log.append((now, "roll and pitch program"))
            sim.log("\(v.name): roll and pitch program")
        }
        if !tiltArrested && t >= tiltArrest {
            tiltArrested = true
            log.append((t1 + tiltArrest, "tilt arrest"))
            sim.log("\(v.name): tilt arrest")
        }
        var yaw = t >= plan.towerYaw.start && t < plan.towerYaw.end ? plan.towerYaw.angle : 0
        var roll = programStarted != nil ? 0 : initialRoll
        // The program holds its value from the arrest on, until the IGM's.
        var pitch = programStarted != nil ? programPitch(at: t) : 0
        if let c = guidanceCommand { (roll, pitch, yaw) = (0, c.pitch, c.yaw) }
        // From the S-IVB cutoff the LVDC uses its coast rate limits.
        let l = plan.commandRateLimit
        let limit = timeBases[.t5] != nil ? plan.coastRateLimit : Vec3(l, l, l)
        func toward(_ a: Double, _ b: Double, _ rate: Double) -> Double {
            a + max(-rate * dt, min(rate * dt, b - a))
        }
        chi = Vec3(toward(chi.x, roll, limit.x), toward(chi.y, pitch, limit.y), toward(chi.z, yaw, limit.z))
        command = frame * Quat(axis: .unitY, angle: chi.y) * Quat(axis: .unitZ, angle: chi.z)
            * Quat(axis: .unitX, angle: chi.x)
        var rate = Vec3.zero
        if let last = lastCommand, dt > 0 { rate = rotationVector(command * last.conjugate) / dt }
        v.attitudeCommand = AttitudeCommand(attitude: command, rate: rate)
        lastCommand = command
    }

    /// The pitch program at `t` s from T1 (GE504 Table 4-II): after an S-IC
    /// engine out it holds through the chi freeze, then runs on as far
    /// behind as the freeze lasted, from the value it held; it holds from
    /// the (moved) tilt arrest, or from the freeze if that ends later.
    private func programPitch(at t: Double) -> Double {
        guard let f = chiFreeze else { return plan.tilt.pitch(at: t) }
        if t < f.start { return plan.tilt.pitch(at: t, bias: 0, arrest: tiltArrest) }
        if t < f.start + f.duration { return plan.tilt.pitch(at: f.start, bias: 0, arrest: tiltArrest) }
        return plan.tilt.pitch(at: t, bias: f.duration, arrest: max(tiltArrest, f.start + f.duration))
    }

    // MARK: HUD

    private func statusLine(_ v: Vessel, now: Epoch) -> String {
        guard let (base, start) = timeBases.max(by: { $0.key < $1.key }) else { return "on the pad" }
        let t1 = timeBases[.t1].map { now - $0 } ?? 0
        let pilot = v.autopilot != .attitudeHold || !v.rotationInput.isZero
        let held = pilot ? "" : ", " + guidancePhase
        let phase: String
        switch base {
        case .t1, .t2:
            if t1 < plan.towerYaw.end && t1 >= plan.towerYaw.start { phase = "tower-clearance yaw" }
            else if tiltArrested { phase = "tilt arrested" }
            else if let f = chiFreeze, programStarted != nil, t1 >= f.start && t1 < f.start + f.duration {
                phase = "chi freeze (engine out)"
            }
            else if programStarted != nil && abs(chi.x) > 1e-6 { phase = "roll and pitch program" }
            else if programStarted != nil { phase = "pitch program" }
            else { phase = "vertical rise" }
        case .t3:
            phase = stageFiring(v, plan.stages.second) ? "S-II burn" + held
                : secondStageLit ? "S-II engines off" : "S-IC/S-II staging"
        case .t4:
            phase = stageFiring(v, plan.stages.third) ? "S-IVB burn" + held
                : thirdStageLit ? "S-IVB engine off" : "S-II/S-IVB staging"
        case .t5:
            let coast = localHorizontal
                ? "local horizontal, " + (Self.periapsisRadius(v) > v.reference.radius + 100_000
                                          ? "parking orbit" : "suborbital")
                : ullageOn ? "APS ullage" : "S-IVB cutoff"
            phase = guidanceCutoff ? coast + ", IGM done" : coast
        }
        // The engines sensed out that are still aboard.
        let out = enginesOut.map(\.engine).filter { n in v.thrusters.contains { $0.name == n } }
        let note = out.isEmpty ? "" : (out.count == 1 ? ", engine out: " : ", engines out: ") + out.joined(separator: ", ")
        return String(format: "%@+%.0f %@%@%@", base.description, now - start, phase, note,
                      pilot ? "  (attitude: pilot)" : "")
    }

    /// What the attitude follows in the S-II and S-IVB burns.
    private var guidancePhase: String {
        guard let igm = guidance else { return guidanceDone ? "IGM done" : "attitude held (pre-IGM)" }
        if igm.highSpeedLoop { return "IGM chi freeze" }
        switch igm.stage {
        case .first: return "IGM phase 1"
        case .second: return igm.artificialTau ? "IGM phase 2, artificial tau" : "IGM phase 2"
        case .coast: return "IGM phase 3, steering frozen"
        case .third:
            return igm.terminalGuidance ? "IGM terminal guidance"
                : igm.artificialTau ? "IGM phase 3, artificial tau" : "IGM phase 3"
        }
    }

    /// Two-body periapsis radius about the vessel's reference body, m (0 for
    /// an orbit that does not close).
    static func periapsisRadius(_ v: Vessel) -> Double {
        let r = v.position, w = v.velocity, mu = v.reference.gm
        let energy = w.lengthSquared / 2 - mu / r.length
        guard energy < 0 else { return 0 }
        let a = -mu / (2 * energy)
        let e = (w.cross(r.cross(w)) / mu - r.normalized).length
        return a * (1 - e)
    }
}
