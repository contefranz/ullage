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
    public func pitch(at t: Double) -> Double {
        let tc = min(t, arrest)
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
/// - T2 when the LVDC senses the centre engine's cutoff, which T1 commands.
/// - T3 when it senses the S-IC outboard cutoff (LOX depletion): separation,
///   S-II ignition, S-II gains, aft interstage and LET jettison, iterative
///   guidance, S-II centre cutoff.
/// - T4 when it senses the S-II cutoff (LOX depletion): separation and S-IVB
///   ignition, whose J-2 flies the vehicle's own `tvcGains` law.
/// - T5 when it senses the S-IVB cutoff: APS ullage burn, then the local
///   horizontal in orbit, the command moving there within the orbital rate
///   limits.
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
        /// New operating setting for the main engines of the named part.
        case rating(part: String, EngineRating)
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

    public init(plan: Plan) {
        self.plan = plan
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
    /// on the pad, or full and burning in flight.
    public func allowsManualStaging(of vessel: Vessel) -> Bool { timeBases[.t3] != nil }

    public func timeToNextEvent(at now: Epoch) -> Double? {
        var next: Double?
        if timeBases[.t1] == nil, let m = firstMotion { next = m + plan.liftoffDelay - now }
        for (i, e) in plan.sequence.enumerated() where !done.contains(i) {
            guard let base = timeBases[e.base] else { continue }
            let dt = base + e.offset - now
            if dt > 0 { next = min(next ?? dt, dt) }
        }
        for e in pending where e.at > now { next = min(next ?? (e.at - now), e.at - now) }
        if let c = cutoffAt, c > now { next = min(next ?? (c - now), c - now) }
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
        // The space-fixed frame: launch vertical and flight azimuth at
        // guidance reference release, before the Earth turned the pad on.
        let o = sim.snapshot.orientation(v.reference)
        let back = Quat(axis: o.angularVelocity, angle: -o.angularVelocity.length * plan.referenceToLiftoff)
        // X_S is the plumb line, opposite local gravity (GE504 Fig 1-1): the
        // reference body's gravity and its rotation's centrifugal term, which
        // on the Earth tilt it from the radial as the geodetic vertical is.
        let plumb = v.reference.gravity(at: v.position, pole: o.pole)
            - o.angularVelocity.cross(o.angularVelocity.cross(v.position))
        let up = -plumb.normalized
        let east = o.pole.cross(up).normalized, north = up.cross(east)
        let downrange = north * cos(plan.flightAzimuth) + east * sin(plan.flightAzimuth)
        let x = back.rotate(up), z = back.rotate(downrange)
        let frame = Quat(matrix: Mat3(columns: x, z.cross(x), z))
        spaceFixed = frame
        // The vehicle's roll in that frame (Position I's azimuth against the
        // flight azimuth); it starts the roll program from there.
        let zS = (frame.conjugate * v.attitude).rotate(.unitZ)
        initialRoll = atan2(-zS.y, zS.z)
        chi = Vec3(initialRoll, 0, 0)
        v.autopilot = .attitudeHold
    }

    /// The time bases the LVDC starts on sensing a cutoff, at the first step
    /// that sees it: T2 the centre engine's, T3 and T4 the S-IC's and S-II's
    /// burnout (or the stage gone), T5 the S-IVB's cutoff once it has fired.
    private func detectTimeBases(_ v: Vessel, now: Epoch) {
        func part(_ name: String) -> VesselPart? { v.parts.first { $0.name == name } }
        func burnedOut(_ name: String) -> Bool {
            guard let p = part(name) else { return true }
            return !p.thrusters.contains { $0.groups.contains(.main) && $0.isEnabled && $0.hasPropellant }
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
        if timeBases[.t2] == nil
            && v.thrusters.first(where: { $0.name == plan.centreEngine }).map({ !$0.isEnabled }) ?? true {
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
                record(perform(e.action, at: e.at, v, sim) ? e.name : "\(e.name) (nothing to do: gone)", at: e.at, v, sim)
                continue
            }
            guard let (i, at) = next else { return }
            done.insert(i)
            let e = plan.sequence[i]
            record(perform(e.action, at: at, v, sim) ? e.name : "\(e.name) (nothing to do: gone)", at: at, v, sim)
        }
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
        case .mainThrottle(let level):
            v.mainThrottle = level
        case .separate(let name):
            guard let part = v.parts.first(where: { $0.name == name }), case .event(let n) = part.staging else {
                return false
            }
            sim.stage(v, event: n)
        case let .rating(name, rating):
            guard let part = v.parts.first(where: { $0.name == name }) else { return false }
            for t in part.thrusters where t.groups.contains(.main) { t.rating = rating }
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
            $0.groups.contains(.main) && $0.level > 0 && $0.isEnabled && $0.hasPropellant
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
                                sIICutoff: timeBases[.t4] != nil, sIVBIgnition: thirdStageAtThrust(v))
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
        if !tiltArrested && t >= plan.tilt.arrest {
            tiltArrested = true
            log.append((t1 + plan.tilt.arrest, "tilt arrest"))
            sim.log("\(v.name): tilt arrest")
        }
        var yaw = t >= plan.towerYaw.start && t < plan.towerYaw.end ? plan.towerYaw.angle : 0
        var roll = programStarted != nil ? 0 : initialRoll
        // The program holds its value from the arrest on, until the IGM's.
        var pitch = programStarted != nil ? plan.tilt.pitch(at: t) : 0
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
        return String(format: "%@+%.0f %@%@", base.description, now - start, phase, pilot ? "  (attitude: pilot)" : "")
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
