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
/// computer) for Apollo 11, open loop. It runs the flight sequence on the
/// IU's time bases and flies the S-IC's attitude programs:
///
/// - T1 starts at liftoff. The tower-clearance yaw, then, once the vehicle
///   has risen clear of the tower, the roll program from the pad azimuth to
///   the flight azimuth and the pitch program, all relative to the
///   space-fixed frame fixed at guidance reference release, with each
///   commanded angle rate-limited. The outboard F-1 cant, the S-IC
///   flight-control gain switches and the tilt arrest.
/// - T2 (time-based): S-IC centre engine cutoff.
/// - T3 at S-IC outboard cutoff (LOX depletion): separation, S-II ignition,
///   S-II gains, aft interstage and LET jettison, S-II centre cutoff and the
///   mixture-ratio shift.
/// - T4 at S-II cutoff (LOX depletion): separation and S-IVB ignition, whose
///   J-2 flies the vehicle's own `tvcGains` law.
/// - T5 at S-IVB cutoff: APS ullage burn, then local horizontal in orbit.
///
/// Iterative guidance (IGM) is not modelled yet: the attitude stays where the
/// tilt was arrested through the S-II and S-IVB burns, and the S-IVB cuts off
/// at the flight's time rather than on reaching orbit.
///
/// It sets `.attitudeHold` at T1 and writes `attitudeCommand` every step; a
/// pilot who selects another mode flies the attitude while the IU keeps the
/// sequence. It stages by part, so an early Space press does no harm.
public final class SaturnIU: FlightProgram {
    public enum TimeBase: Int, CaseIterable, Comparable, CustomStringConvertible {
        case t1 = 1, t2, t3, t4, t5
        public var description: String { "T\(rawValue)" }
        public static func < (a: TimeBase, b: TimeBase) -> Bool { a.rawValue < b.rawValue }
    }

    /// What a timed event does.
    public enum Action: Equatable {
        case startTimeBase(TimeBase)
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
        case arrestTilt
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
        /// Limit on the rate of each commanded angle, rad/s.
        public var commandRateLimit: Double
        /// Outboard cant: radial angle (rad, thrust lines inwards) and ramp rate (rad/s).
        public var cant: (angle: Double, rate: Double)
        public var sequence: [Event]
        /// The parts whose cutoffs the LVDC senses to start T3, T4 and T5,
        /// and the centre engine whose cutoff starts T2.
        public var stages: (first: String, second: String, third: String)
        public var centreEngine: String
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
    public private(set) var status = "IU: on the pad"
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
    private var thirdStageLit = false
    private var localHorizontal = false
    private var lastCommand: Quat?

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
        if firstMotion == nil { firstMotion = lastLanded ?? now }
        if timeBases[.t1] == nil {
            let t1 = firstMotion! + plan.liftoffDelay
            guard now - t1 >= -1e-9 else {
                status = "IU: first motion"
                return
            }
            startT1(at: t1, v, sim)
        }
        detectTimeBases(v, now: now)
        runDueEvents(v, sim, now: now)
        if let cant = cantStart { applyCant(v, part: cant.part, since: now - cant.at) }
        if ullageOn { v.translationInput.x = 1 }
        commandAttitude(v, sim, now: now)
        status = statusLine(v, now: now)
    }

    public func timeToNextEvent(at now: Epoch) -> Double? {
        var next: Double?
        if timeBases[.t1] == nil, let m = firstMotion { next = m + plan.liftoffDelay - now }
        for (i, e) in plan.sequence.enumerated() where !done.contains(i) {
            guard let base = timeBases[e.base] else { continue }
            let dt = base + e.offset - now
            if dt > 0 { next = min(next ?? dt, dt) }
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
        let up = v.position.normalized
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
        func start(_ b: TimeBase, _ what: String) {
            timeBases[b] = now
            log.append((now, "\(b): \(what) sensed"))
        }
        if timeBases[.t2] == nil
            && v.thrusters.first(where: { $0.name == plan.centreEngine }).map({ !$0.isEnabled }) ?? true {
            start(.t2, "centre engine cutoff")
        }
        if timeBases[.t3] == nil && burnedOut(plan.stages.first) {
            if timeBases[.t2] == nil { start(.t2, "centre engine cutoff") }
            start(.t3, "S-IC outboard engine cutoff")
        }
        if timeBases[.t3] != nil && timeBases[.t4] == nil && burnedOut(plan.stages.second) {
            start(.t4, "S-II outboard engine cutoff")
        }
        if timeBases[.t4] != nil && timeBases[.t5] == nil, let third = part(plan.stages.third) {
            let firing = third.thrusters.contains { $0.groups.contains(.main) && $0.level > 0 && $0.isEnabled
                                                    && $0.hasPropellant }
            if firing { thirdStageLit = true } else if thirdStageLit { start(.t5, "S-IVB cutoff") }
        }
    }

    private func runDueEvents(_ v: Vessel, _ sim: Simulation, now: Epoch) {
        while true {
            let due = plan.sequence.enumerated().compactMap { (i, e) -> (Int, Epoch)? in
                guard !done.contains(i), let base = timeBases[e.base], base + e.offset <= now + 1e-9 else { return nil }
                return (i, base + e.offset)
            }
            guard let (i, at) = due.min(by: { $0.1 < $1.1 }) else { return }
            done.insert(i)
            let e = plan.sequence[i]
            log.append((at, e.name))
            sim.log("\(v.name): \(e.name)")
            perform(e.action, at: at, v, sim)
        }
    }

    private func perform(_ action: Action, at: Epoch, _ v: Vessel, _ sim: Simulation) {
        switch action {
        case .startTimeBase(let b):
            if timeBases[b] == nil { timeBases[b] = at }
        case .engineCutoff(let name):
            v.thrusters.first { $0.name == name }?.isEnabled = false
        case .mainThrottle(let level):
            v.mainThrottle = level
        case .separate(let name):
            if let part = v.parts.first(where: { $0.name == name }), case .event(let n) = part.staging {
                sim.stage(v, event: n)
            }
        case let .rating(name, rating):
            for t in v.parts.first(where: { $0.name == name })?.thrusters ?? [] where t.groups.contains(.main) {
                t.rating = rating
            }
        case .startCant(let name):
            cantStart = (name, at)
        case .gains(let g):
            v.fccGains = g
        case .ullage(let on):
            ullageOn = on
            if !on { v.translationInput.x = 0 }
        case .arrestTilt:
            tiltArrested = true
        case .localHorizontal:
            localHorizontal = true
        case .note:
            break
        }
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

    // MARK: Attitude

    private func commandAttitude(_ v: Vessel, _ sim: Simulation, now: Epoch) {
        guard let frame = spaceFixed, let t1 = timeBases[.t1] else { return }
        let dt = lastUpdate.map { max(0, now - $0) } ?? 0
        let command: Quat
        if localHorizontal {
            // Orbital attitude: +x along the horizontal velocity, +z (Position
            // I) towards the Earth, turning at the orbital rate.
            let r = v.position, vel = v.velocity
            let down = -r.normalized, x = (vel - r.normalized * vel.dot(r.normalized)).normalized
            command = Quat(matrix: Mat3(columns: x, down.cross(x), down))
            v.attitudeCommand = AttitudeCommand(attitude: command, rate: r.cross(vel) / r.lengthSquared)
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
        let yaw = t >= plan.towerYaw.start && t < plan.towerYaw.end ? plan.towerYaw.angle : 0
        let roll = programStarted != nil ? 0 : initialRoll
        let pitch = tiltArrested ? chi.y : programStarted != nil ? plan.tilt.pitch(at: t) : 0
        let step = plan.commandRateLimit * dt
        func toward(_ a: Double, _ b: Double) -> Double { a + max(-step, min(step, b - a)) }
        chi = Vec3(toward(chi.x, roll), toward(chi.y, pitch), toward(chi.z, yaw))
        command = frame * Quat(axis: .unitY, angle: chi.y) * Quat(axis: .unitZ, angle: chi.z)
            * Quat(axis: .unitX, angle: chi.x)
        var rate = Vec3.zero
        if let last = lastCommand, dt > 0 { rate = rotationVector(command * last.conjugate) / dt }
        v.attitudeCommand = AttitudeCommand(attitude: command, rate: rate)
        lastCommand = command
    }

    // MARK: HUD

    private func statusLine(_ v: Vessel, now: Epoch) -> String {
        guard let (base, start) = timeBases.max(by: { $0.key < $1.key }) else { return "IU: on the pad" }
        let t1 = timeBases[.t1].map { now - $0 } ?? 0
        let phase: String
        switch base {
        case .t1, .t2:
            if t1 < plan.towerYaw.end && t1 >= plan.towerYaw.start { phase = "tower-clearance yaw" }
            else if tiltArrested { phase = "tilt arrested" }
            else if programStarted != nil && abs(chi.x) > 1e-6 { phase = "roll and pitch program" }
            else if programStarted != nil { phase = "pitch program" }
            else { phase = "vertical rise" }
        case .t3: phase = v.mainThrottle > 0 ? "S-II burn, attitude held (no IGM)" : "S-IC/S-II staging"
        case .t4: phase = v.mainThrottle > 0 ? "S-IVB burn, attitude held (no IGM)" : "S-II/S-IVB staging"
        case .t5: phase = localHorizontal ? "orbit, local horizontal" : ullageOn ? "APS ullage" : "S-IVB cutoff"
        }
        let manual = v.autopilot == .attitudeHold ? "" : "  (attitude: pilot)"
        return String(format: "%@+%.0f %@%@", base.description, now - start, phase, manual)
    }
}
