import Foundation

/// M2's onboard computer: the CMC as docs/m2/design-flight-controls.md §1,
/// §3 and §7 reduce it ("CMC-lite"), hosted by the CSM's SCS (`ApolloSCS`),
/// with the programs a burn needs:
/// - P00, idling: the uplink lands here (UP TLM ACCEPT, ground contact);
///   V82 shows the apsides; NXT picks P40 or P41 for the load.
/// - P30, External ΔV, in two steps: the load (N81, and N33 for TIG when
///   keyed by hand), which the crew may re-key, then the computer's own
///   prediction (N42: HAPO, HPER, ΔVT). Return accepts each.
/// - P40, the SPS burn: V50N18 asks to slew (Return, or G, gives the
///   computer the attitude: G&N AUTO), V06N18 while it slews at 0.5°/s,
///   roll included, the gimbal test (logged), V06N40 counting down, blank
///   from TIG−35 s to TIG−30 s, Average-G from TIG−30 s (the ullage counts),
///   V99 at TIG−5 s: "enable ignition?". Without Return there is no
///   ignition; with it the computer lights the SPS at TIG (a late Return
///   lights it late), steers on VG and cuts off when VG along the thrust is
///   down to the tail-off, predicted to the step. Then V16N85, the
///   residuals in body axes with the RCS key that nulls each, V16N44, and
///   P00. Z before TIG makes it an SCS burn: the EMS counter cuts off, the
///   computer monitors. X cuts the SPS; the computer goes on to N85.
/// - P41, the RCS burn: P40's slew and count, and at TIG N85, the crew
///   thrusting on the translation keys until VG is nulled.
/// - P47, thrust monitor: N83, the body Δv sensed since it started.
///
/// Keys (`DSKYKey`): Return is ENTR when digits are keyed and PRO
/// otherwise; ENTR with nothing keyed is OPR ERR, as is PRO with digits not
/// entered, so a keyed value is never dropped silently. PROG lights when a
/// program cannot do what it is asked, with the reason. Apollo units on the
/// display (ft/s, n mi, GET), SI everywhere else.
public final class CMCLite: GuidanceComputer {
    /// The program's step: what the display shows and the computer waits
    /// for.
    public enum Step: Equatable, Sendable {
        /// P00.
        case idle
        /// V82 (V16N44) over P00.
        case orbitParameters
        /// P30's load: N33 (TIG) when keyed by hand, then N81 (Δv, LVLH).
        case loadTIG, loadDeltaV
        /// P30's check, N42.
        case check
        /// V50N18: please perform auto maneuver.
        case maneuver
        /// V06N18: the computer slews.
        case maneuvering
        /// V06N40: counting down to TIG.
        case countdown
        /// V99N40: enable engine ignition?
        case ignition
        /// V06N40: the SPS burns.
        case burn
        /// V16N85: the residuals to null.
        case residuals
        /// V16N44: the orbit after the burn.
        case postBurn
        /// P47's V16N83.
        case thrustMonitor
    }

    // MARK: Switches

    /// UP TLM: ACCEPT (true) or BLOCK.
    public var uplinkAccept = true
    /// The ground has contact (no uplink behind the Moon).
    public var groundContact = true
    /// Zero of the mission clock (GET 0), for TIG on the display and keyed
    /// by hand; nil shows it from the J2000 epoch.
    public var clockZero: Epoch?

    // MARK: State

    public private(set) var program = 0
    public private(set) var step = Step.idle
    public private(set) var load: ManeuverPlan?
    /// The load's burn while P40 or P41 runs.
    public private(set) var burn: ExternalDeltaVSteering?
    /// The computer's attitude, approached at `slewRate`: what G&N AUTO flies
    /// (the host writes it to the vessel's `attitudeCommand`); nil when no
    /// program wants an attitude.
    public private(set) var attitudeCommand: AttitudeCommand?
    /// The computer lit the engine and owns its cutoff (the EMS then only
    /// counts).
    public private(set) var ownsThrust = false
    /// When the burn lit (by the computer or Z) and when it was cut off.
    public private(set) var ignition: Epoch?
    public private(set) var cutoff: Epoch?
    /// The crew's Return at V99.
    public private(set) var ignitionEnabled = false
    /// Z lit the SPS before TIG: an SCS burn, the computer monitoring.
    public private(set) var scsBurn = false
    private var pendingCutoff: Epoch?
    private var autoManeuverRequested = false
    private var lamps: DSKYDisplay.Lamps = []
    private var reason: String?
    /// The digits keyed and their sign.
    private var sign: Character?
    private var digits = ""
    /// PRG was pressed: the digits name a program.
    private var programKeying = false
    /// The register the next ENTR loads in P30 (0-2).
    private var register = 0
    /// P30's values as keyed: TIG (GET h, min, s) and the Δv (LVLH, m/s).
    private var keyedTIG: [Double]?
    private var keyedDeltaV: Vec3?
    /// P47's Average-G.
    private var monitor: AverageG?
    private var situation: Situation?
    private var lastUpdate: Epoch?
    private weak var sim: Simulation?
    private var pendingLog: [String] = []

    /// The slew rate of an auto maneuver, rad/s (0.5°/s).
    public static let slewRate = 0.5 * Double.pi / 180
    /// The attitude error under which the maneuver is done, rad.
    public static let attitudeReached = 1.0 * Double.pi / 180
    /// V99 comes this long before TIG, s; the display is blank from
    /// `blankLead` to Average-G's start.
    public static let ignitionPromptLead = 5.0
    public static let blankLead = 35.0
    /// Burns of this Δv or less go on the RCS when keyed by hand, m/s (5 ft/s).
    public static let rcsBelow = 5 * foot

    static let foot = 0.3048, nauticalMile = 1852.0

    /// The vessel's state as the computer last saw it, for its displays.
    struct Situation {
        var time: Epoch
        var state: Kepler.State
        var mu: Double
        var radius: Double
        var attitude: Quat
        var controlFrame: Quat
        var mass: Double
        /// The SPS's vacuum thrust and Isp, if it is aboard.
        var sps: (thrust: Double, isp: Double)?
    }

    public init() {}

    // MARK: Host interface

    /// Return at V50N18 asked for G&N AUTO since the last call.
    public func takeAutoManeuverRequest() -> Bool {
        defer { autoManeuverRequested = false }
        return autoManeuverRequested
    }

    /// Start the computer's attitude from `q` (G&N AUTO selected now): the
    /// slew starts where the vessel is.
    public func restartSlew(from q: Quat) {
        guard attitudeCommand != nil else { return }
        attitudeCommand = AttitudeCommand(attitude: q)
    }

    /// The next event the computer will act on: the cutoff, else the load's
    /// TIG.
    public func nextEvent(at now: Epoch) -> (name: String, at: Epoch)? {
        if let c = pendingCutoff { return ("SPS cutoff (CMC)", c) }
        if let l = load, ignition == nil, l.ignition > now { return ("TIG \(l.name)", l.ignition) }
        return nil
    }

    // MARK: GuidanceComputer

    public var display: DSKYDisplay { makeDisplay() }

    public func uplink(_ plan: ManeuverPlan, at now: Epoch) -> UplinkResult {
        guard uplinkAccept else { return .refused("UP TLM BLOCK") }
        guard groundContact else { return .refused("NO CONTACT") }
        guard program == 0 else { return .refused("CMC NOT IN P00") }
        load = plan
        keyedTIG = nil
        keyedDeltaV = nil
        clearKeys()
        program = 30
        step = .loadDeltaV
        register = 0
        lamps.insert(.uplinkActivity)
        note("CMC: \(plan.name) uplink accepted, P30")
        return .accepted
    }

    /// In P00, or P30 checking it, the load goes and the program is P00.
    @discardableResult
    public func clearLoad(at now: Epoch) -> Bool {
        guard load != nil, program == 0 || program == 30 else { return false }
        load = nil
        keyedTIG = nil
        keyedDeltaV = nil
        clearKeys()
        finish(keepLoad: true)
        note("CMC: load cleared by the ground")
        return true
    }

    public func press(_ key: DSKYKey, at now: Epoch) {
        switch key {
        case .digit(let d):
            guard (0...9).contains(d) else { return }
            if digits.count < 5 { digits.append(Character(String(d))) } else { error("FIVE DIGITS AT MOST") }
        case .plus, .minus:
            guard !programKeying else { return error("NO SIGN FOR A PROGRAM") }
            sign = key == .plus ? "+" : "-"
        case .program:
            clearKeys()
            programKeying = true
        case .clear:
            clearKeys()
        case .reset:
            lamps.subtract([.programAlarm, .operatorError, .uplinkActivity])
            reason = nil
        case .keyRelease:
            lamps.remove(.keyRelease)
        case .enter:
            if hasKeys { enter(at: now) } else { error("NOTHING KEYED") }
        case .returnKey:
            if hasKeys { enter(at: now) } else if flashing { proceed(at: now) }
        case .proceed:
            if !digits.isEmpty { error("KEYED, NOT ENTERED: RETURN OR CLR") } else { proceed(at: now) }
        case .next:
            guard let l = load else { return alarm("NO LOAD") }
            guard program == 0 || program == 30 && step == .check else { return error("NXT FROM P00") }
            select(l.engine == .sps ? 40 : 41, at: now)
        case .orbitParameters:
            guard program == 0 else { return error("V82 FROM P00") }
            step = step == .orbitParameters ? .idle : .orbitParameters
        case .display:
            switch step {
            case .loadTIG: step = .loadDeltaV
            case .loadDeltaV: step = .loadTIG
            default: error("NO OTHER DISPLAY")
            }
            register = 0
        }
    }

    public func update(_ v: Vessel, in sim: Simulation) {
        let now = sim.time
        self.sim = sim
        flushLog()
        defer {
            lastUpdate = now
            flushLog()
        }
        situation = Situation(v, at: now)
        switch program {
        case 40, 41: updateBurn(v, in: sim, now: now)
        case 47: monitor?.sense(v, in: sim, now: now)
        default: break
        }
        if let b = burn { advanceCommand(toward: b.steer(v), now: now) }
    }

    public func timeToNextEvent(at now: Epoch) -> Double? {
        var times: [Epoch] = []
        if let c = pendingCutoff { times.append(c) }
        if let l = load, burn != nil, ignition == nil {
            let tig = l.ignition
            times += [tig + -Self.blankLead, tig + -ExternalDeltaVSteering.averageGLead,
                      tig + -Self.ignitionPromptLead]
            if ignitionEnabled || program == 41 { times.append(tig) }
        }
        return times.map { $0 - now }.filter { $0 > 1e-9 }.min()
    }

    /// While a load waits to be flown: caps of 100x from TIG−60 min and 10x
    /// from TIG−10 min, a stop at TIG−2 min, and 1x from TIG−30 s to TIG+5 s;
    /// the caps last until 30 s after the planned burn.
    public func warpEvents(after now: Epoch) -> [WarpEvent] {
        guard let l = load, cutoff == nil else { return [] }
        let tig = l.ignition, end = tig + ((l.burnTime ?? 0) + 30)
        let events: [WarpEvent] = [
            .cap(from: tig + -3_600, until: end, maxWarp: 100, reason: "TIG-60 min"),
            .cap(from: tig + -600, until: end, maxWarp: 10, reason: "TIG-10 min"),
            .stop(at: tig + -120, reason: "TIG-2 min"),
            .cap(from: tig + -30, until: tig + 5, maxWarp: 1, reason: "TIG-30 s"),
        ]
        return events.filter { $0.matters(at: now) }
    }

    // MARK: Keys

    private var hasKeys: Bool { !digits.isEmpty }

    private func clearKeys() {
        sign = nil
        digits = ""
        programKeying = false
    }

    /// The computer waits for the crew: the verb and noun flash.
    var flashing: Bool {
        switch step {
        case .orbitParameters, .loadTIG, .loadDeltaV, .check, .maneuver, .residuals, .postBurn, .thrustMonitor: true
        case .ignition: !ignitionEnabled
        default: false
        }
    }

    private func error(_ why: String) {
        lamps.insert(.operatorError)
        reason = why
    }

    private func alarm(_ why: String) {
        lamps.insert(.programAlarm)
        reason = why
        note("CMC: PROG, \(why.lowercased())")
    }

    /// ENTR: the keyed digits into the program number or the register.
    private func enter(at now: Epoch) {
        defer { clearKeys() }
        let magnitude = Double(digits) ?? 0, value = sign == "-" ? -magnitude : magnitude
        if programKeying {
            guard let n = Int(digits) else { return error("NO PROGRAM") }
            select(n, at: now)
            return
        }
        switch step {
        case .loadTIG:
            var t = keyedTIG ?? tigFields(load?.ignition)
            t[register] = register == 2 ? value / 100 : value
            keyedTIG = t
            register = (register + 1) % 3
        case .loadDeltaV:
            var dv = keyedDeltaV ?? load?.deltaVLocal ?? .zero
            let ms = value / 10 * Self.foot   // ft/s to a tenth, as the DSKY keys it
            switch register {
            case 0: dv.x = ms
            case 1: dv.y = ms
            default: dv.z = ms
            }
            keyedDeltaV = dv
            register = (register + 1) % 3
        default:
            error("NO REGISTER TO LOAD")
        }
    }

    /// PRO: go on from the step that waits for the crew.
    private func proceed(at now: Epoch) {
        switch step {
        case .orbitParameters: step = .idle
        case .loadTIG:
            step = .loadDeltaV
            register = 0
        case .loadDeltaV:
            guard applyKeyed(at: now) else { return }
            step = .check
        case .check:
            lamps.remove(.uplinkActivity)
            program = 0
            step = .idle
            note("CMC: P30 \(load?.name ?? "") accepted, P00")
        case .maneuver:
            autoManeuverRequested = true
            step = .maneuvering
        case .ignition:
            guard !ignitionEnabled else { return }
            ignitionEnabled = true
            note(now < (load?.ignition ?? now) ? "CMC: ignition enabled (V99)"
                 : String(format: "CMC: ignition enabled (V99), %.1f s after TIG", now - (load?.ignition ?? now)))
        case .residuals:
            step = .postBurn
        case .postBurn, .thrustMonitor:
            finish()
        default: break
        }
    }

    /// V37: change to program `n`.
    private func select(_ n: Int, at now: Epoch) {
        if burning { return error("NOT DURING THE BURN") }
        switch n {
        case 0:
            // From P30 it abandons the load; from P40 or P41 before the burn
            // it keeps it, for NXT.
            if program == 30, load != nil {
                load = nil
                note("CMC: load abandoned")
            }
            keyedTIG = nil
            keyedDeltaV = nil
            finish(keepLoad: true)
        case 30:
            clearBurn()
            program = 30
            register = 0
            keyedDeltaV = nil
            keyedTIG = load == nil ? tigFields(nil) : nil
            step = load == nil ? .loadTIG : .loadDeltaV
        case 40, 41:
            guard let l = load else { return alarm("NO LOAD FOR P\(n)") }
            if n == 40, l.engine != .sps { return alarm("THE LOAD IS FOR THE RCS: P41") }
            guard let s = situation else { return alarm("NO STATE") }
            clearBurn()
            program = n
            step = .maneuver
            burn = ExternalDeltaVSteering(plan: l, state: s.state, mu: s.mu, at: s.time)
            attitudeCommand = AttitudeCommand(attitude: s.attitude)
            if s.time >= l.ignition + -ExternalDeltaVSteering.averageGLead { burn?.startAverageG(at: s.time) }
            note("CMC: P\(n) \(l.name)")
        case 47:
            clearBurn()
            program = 47
            step = .thrustMonitor
            var g = AverageG()
            g.begin(at: situation?.time ?? now)
            monitor = g
            note("CMC: P47")
        default:
            error(String(format: "NO PROGRAM %02d", n))
        }
    }

    /// The program ends: P00, the load flown (or kept, `keepLoad`).
    private func finish(keepLoad: Bool = false) {
        if !keepLoad, program == 40 || program == 41 { load = nil }
        clearBurn()
        program = 0
        step = .idle
        lamps.remove(.uplinkActivity)
    }

    private func clearBurn() {
        burn = nil
        attitudeCommand = nil
        ownsThrust = false
        ignition = nil
        cutoff = nil
        ignitionEnabled = false
        scsBurn = false
        pendingCutoff = nil
        monitor = nil
    }

    private var burning: Bool { (program == 40 || program == 41) && ignition != nil && step == .burn }

    /// P30's keyed values made into the load: TIG and the Δv in LVLH at
    /// TIG, turned to ICRF on the conic there. False (OPR ERR) when there is
    /// nothing to load.
    private func applyKeyed(at now: Epoch) -> Bool {
        guard keyedTIG != nil || keyedDeltaV != nil else {
            if load == nil { error("NO LOAD: KEY TIG AND DV") }
            return load != nil
        }
        guard let s = situation else {
            error("NO STATE")
            return false
        }
        let tig = keyedTIG.map { epoch(fromGET: $0) } ?? load?.ignition ?? s.time
        let local = keyedDeltaV ?? load?.deltaVLocal ?? .zero
        guard tig > s.time, local.length > 0 else {
            error(tig > s.time ? "NO DV" : "TIG PASSED")
            return false
        }
        let atTIG = Kepler.propagate(s.state, mu: s.mu, by: tig - s.time)
        let dv = DeorbitPlanner.localVerticalFrame(atTIG).transposed * local
        let engine: ManeuverPlan.Engine = local.length <= Self.rcsBelow ? .rcs : .sps
        var bt: Double?
        if engine == .sps, let sps = s.sps {
            bt = DeorbitPlanner.burnTime(deltaV: dv.length, mass: s.mass, thrust: sps.thrust,
                                         specificImpulse: sps.isp)
        }
        var plan = load ?? ManeuverPlan(name: "PAD", engine: engine, ignition: tig, deltaV: dv, deltaVLocal: local,
                                        stateEpoch: s.time, source: .keyed)
        plan.ignition = tig
        plan.deltaV = dv
        plan.deltaVLocal = local
        plan.engine = engine
        plan.burnTime = bt ?? plan.burnTime
        if keyedDeltaV != nil || keyedTIG != nil {
            plan.source = .keyed
            plan.stateEpoch = s.time
            plan.attitude = nil
        }
        load = plan
        keyedTIG = nil
        keyedDeltaV = nil
        return true
    }

    /// GET hours, minutes and seconds of `t` (zeros when nil).
    private func tigFields(_ t: Epoch?) -> [Double] {
        guard let t else { return [0, 0, 0] }
        let get = t - (clockZero ?? Epoch(tdbSecondsPastJ2000: 0))
        let h = (get / 3_600).rounded(.down), m = ((get - h * 3_600) / 60).rounded(.down)
        return [h, m, get - h * 3_600 - m * 60]
    }

    private func epoch(fromGET f: [Double]) -> Epoch {
        (clockZero ?? Epoch(tdbSecondsPastJ2000: 0)) + (f[0] * 3_600 + f[1] * 60 + f[2])
    }

    // MARK: The burn

    private func updateBurn(_ v: Vessel, in sim: Simulation, now: Epoch) {
        guard let b = burn, let l = load else { return }
        let tig = l.ignition, eps = 1e-6
        if b.averageG.start == nil, now >= tig + (-ExternalDeltaVSteering.averageGLead - eps) {
            b.startAverageG(at: now)
            note("CMC: Average-G on")
        }
        b.sense(v, in: sim, now: now)
        // Z before the computer lit it: an SCS burn, which it monitors.
        if program == 40, ignition == nil, spsCommanded(v) {
            scsBurn = true
            ignition = now
            step = .burn
            note("CMC: SPS on by the SCS (Z): monitoring, the EMS cuts off")
        }
        switch step {
        case .maneuvering:
            if attitudeError(v) < Self.attitudeReached {
                if program == 40 { note("CMC: SPS gimbal test") }
                step = .countdown
            }
        case .countdown:
            if program == 40, now >= tig + (-Self.ignitionPromptLead - eps) { step = .ignition }
            if program == 41, now >= tig + -eps {
                ignition = now
                step = .residuals
            }
        case .ignition:
            if ignitionEnabled, now >= tig + -eps { ignite(v, now: now, tig: tig) }
        case .burn:
            if ownsThrust {
                if cutoff == nil {
                    if v.mainThrottle == 0 {
                        cutoff = now
                        pendingCutoff = nil
                        note(String(format: "CMC: SPS off by the crew (X), VG %.1f ft/s",
                                    b.velocityToBeGained.length / Self.foot))
                    } else {
                        cutOffIfDue(v, b, in: sim, now: now)
                    }
                } else if !spsDelivering(v) {
                    ownsThrust = false
                    step = .residuals
                }
            } else if scsBurn, v.mainThrottle == 0 || !spsCommanded(v), !spsDelivering(v) {
                cutoff = cutoff ?? now
                step = .residuals
            }
        default: break
        }
    }

    private func ignite(_ v: Vessel, now: Epoch, tig: Epoch) {
        v.mainThrottle = 1
        ownsThrust = true
        ignition = now
        step = .burn
        note(now - tig < 1e-3 ? "CMC: SPS ignition at TIG" : String(format: "CMC: SPS ignition, %.1f s late", now - tig))
    }

    /// The cutoff signal when VG along the thrust is down to the tail-off;
    /// else when it will be, so the step ends there.
    private func cutOffIfDue(_ v: Vessel, _ b: ExternalDeltaVSteering, in sim: Simulation, now: Epoch) {
        guard let toGo = b.timeToCutoff(v, in: sim) else { return }
        if toGo < ExternalDeltaVSteering.freezeTime { b.freeze() }
        if toGo < 1e-3 {
            v.mainThrottle = 0
            cutoff = now
            pendingCutoff = nil
            let burned = ignition.map { now - $0 } ?? 0
            note(String(format: "CMC: SPS cutoff (VG), %.2f s burn", burned))
        } else {
            pendingCutoff = now + toGo
        }
    }

    private func spsCommanded(_ v: Vessel) -> Bool {
        v.mainThrottle > 0 && v.thrusters.contains { $0.name == "SPS" && $0.isCommanded }
    }

    private func spsDelivering(_ v: Vessel) -> Bool { v.thrusters.contains { $0.name == "SPS" && $0.isDelivering } }

    /// The angle between the vessel's attitude and the burn's, rad.
    private func attitudeError(_ v: Vessel) -> Double {
        guard let goal = burn?.burnAttitude else { return .infinity }
        return rotationVector(v.attitude.conjugate * goal).length
    }

    /// Move the computer's attitude towards `goal` at `slewRate` at most.
    private func advanceCommand(toward goal: Quat, now: Epoch) {
        guard let current = attitudeCommand?.attitude else { return }
        let dt = max(0, lastUpdate.map { now - $0 } ?? 0)
        let turn = rotationVector(goal * current.conjugate), angle = turn.length
        if angle <= Self.slewRate * dt || angle < 1e-12 {
            attitudeCommand = AttitudeCommand(attitude: goal)
        } else {
            let axis = turn / angle
            attitudeCommand = AttitudeCommand(attitude: (Quat(axis: axis, angle: Self.slewRate * dt) * current).normalized,
                                              rate: axis * Self.slewRate)
        }
    }

    // MARK: Log

    private func note(_ message: String) {
        pendingLog.append(message)
        flushLog()
    }

    private func flushLog() {
        guard let sim, !pendingLog.isEmpty else { return }
        for m in pendingLog { sim.log(m) }
        pendingLog.removeAll()
    }

    // MARK: Display

    private func makeDisplay() -> DSKYDisplay {
        var d = DSKYDisplay(program: program, title: Self.title(program), lamps: lamps, reason: reason,
                            keyBuffer: (sign.map(String.init) ?? "") + digits)
        d.flashing = flashing
        if programKeying {
            d.verb = 37
            d.flashing = true
            d.prompt = "KEY THE PROGRAM, THEN RETURN"
            return d
        }
        let s = situation
        func ft(_ ms: Double) -> String { String(format: "%+.1f", ms / Self.foot) }
        func nm(_ m: Double?) -> String {
            guard let m else { return "OVFL" }
            return abs(m / Self.nauticalMile) >= 9_999.95 ? "OVFL" : String(format: "%+.1f", m / Self.nauticalMile)
        }
        func mmss(_ t: Double) -> String {
            let a = abs(t)
            guard a < 3_600 else { return t < 0 ? "-59:59" : "+59:59" }
            return String(format: "%@%02d:%02d", t < 0 ? "-" : "+", Int(a) / 60, Int(a) % 60)
        }
        switch step {
        case .idle:
            if let l = load {
                d.prompt = "LOAD \(l.name) \(l.engine.rawValue): NXT FOR P\(l.engine == .sps ? 40 : 41)"
            } else {
                d.prompt = "CMC IDLING"
            }
        case .orbitParameters, .postBurn:
            d.verb = 16
            d.noun = 44
            let a = s.map { apsides($0.state, mu: $0.mu, radius: $0.radius) }
            d.registers = [.init("HAPO", nm(a?.apo ?? nil), "NM"), .init("HPER", nm(a?.peri), "NM"),
                           .init("TFF", a?.tff.map(mmss) ?? "-59:59", "MIN:S")]
            d.prompt = step == .postBurn ? "ORBIT AFTER THE BURN: RETURN FOR P00" : "APSIDES: RETURN TO GO ON"
        case .loadTIG:
            d.verb = 6
            d.noun = 33
            let t = keyedTIG ?? tigFields(load?.ignition)
            d.registers = [.init("TIG H", String(format: "%+.0f", t[0]), "H"),
                           .init("TIG M", String(format: "%+.0f", t[1]), "MIN"),
                           .init("TIG S", String(format: "%+.2f", t[2]), "S")]
            d.prompt = "KEY TIG (R\(register + 1) NEXT), THEN RETURN"
        case .loadDeltaV:
            d.verb = 6
            d.noun = 81
            let dv = keyedDeltaV ?? load?.deltaVLocal ?? .zero
            d.registers = [.init("DVX", ft(dv.x), "FT/S"), .init("DVY", ft(dv.y), "FT/S"),
                           .init("DVZ", ft(dv.z), "FT/S")]
            d.prompt = keyedDeltaV == nil && load != nil ? "CHECK THE LOAD: RETURN TO ACCEPT"
                : "KEY DV (R\(register + 1) NEXT, FT/S X10), THEN RETURN"
        case .check:
            d.verb = 6
            d.noun = 42
            let p = load.flatMap { l in s.map { predicted(l, from: $0) } }
            d.registers = [.init("HAPO", nm(p?.apo ?? nil), "NM"), .init("HPER", nm(p?.peri), "NM"),
                           .init("DVT", ft(load?.deltaVMagnitude ?? 0), "FT/S")]
            d.prompt = "CHECK THE CMC'S PREDICTION: RETURN TO ACCEPT"
        case .maneuver, .maneuvering:
            d.verb = step == .maneuver ? 50 : 6
            d.noun = 18
            let e = s.flatMap { s in burn?.burnAttitude.map { goal in
                s.controlFrame.inverseRotate(rotationVector(s.attitude.conjugate * goal)) * (180 / Double.pi) } }
            d.registers = [.init("R ERR", e.map { String(format: "%+.1f", $0.x) } ?? "", "DEG"),
                           .init("P ERR", e.map { String(format: "%+.1f", $0.y) } ?? "", "DEG"),
                           .init("Y ERR", e.map { String(format: "%+.1f", $0.z) } ?? "", "DEG")]
            d.prompt = step == .maneuver ? "PLEASE PERFORM AUTO MANEUVER: RETURN OR G" : "AUTO MANEUVER TO THE BURN ATTITUDE"
        case .countdown, .ignition, .burn:
            if step == .countdown, let l = load, let t = s?.time, t >= l.ignition + -Self.blankLead,
               t < l.ignition + -ExternalDeltaVSteering.averageGLead {
                d.program = nil
                d.prompt = "AVERAGE-G STARTS AT TIG-30 S"
                return d
            }
            d.verb = step == .ignition && !ignitionEnabled ? 99 : 6
            d.noun = 40
            let vg = burn?.velocityToBeGained.length ?? 0
            let time: DSKYDisplay.Register
            if step == .burn, let c = pendingCutoff, let t = s?.time {
                time = .init("TFC", mmss(t - c), "MIN:S")
            } else {
                let tfi = s.flatMap { s in load.map { s.time - $0.ignition } } ?? 0
                time = .init("TFI", mmss(tfi), "MIN:S")
            }
            d.registers = [time, .init("VG", ft(vg), "FT/S"), .init("DVM", ft(burn?.averageG.measured ?? 0), "FT/S")]
            switch step {
            case .ignition: d.prompt = ignitionEnabled ? "IGNITION AT TIG" : "ENABLE ENGINE IGNITION? RETURN"
            case .burn: d.prompt = scsBurn ? "SPS ON (SCS): MONITORING, THE EMS CUTS OFF"
                : cutoff == nil ? "SPS ON (CMC): STEERING ON VG" : "SPS CUTOFF"
            default: d.prompt = "COUNTING DOWN TO TIG"
            }
        case .residuals:
            d.verb = 16
            d.noun = 85
            let r = residuals ?? .zero
            func key(_ x: Double, _ plus: String, _ minus: String) -> String {
                abs(x) < 0.2 * Self.foot ? "FT/S" : "FT/S KEY " + (x > 0 ? plus : minus)
            }
            d.registers = [.init("VGX", ft(r.x), key(r.x, "U", "O")), .init("VGY", ft(r.y), key(r.y, "L", "J")),
                           .init("VGZ", ft(r.z), key(r.z, "K", "I"))]
            d.prompt = program == 41 ? "THRUST TO NULL VG, THEN RETURN" : "NULL THE RESIDUALS ON THE RCS, THEN RETURN"
        case .thrustMonitor:
            d.verb = 16
            d.noun = 83
            let dv = s.map { $0.controlFrame.inverseRotate($0.attitude.inverseRotate(monitor?.sensed ?? .zero)) } ?? .zero
            d.registers = [.init("DVX", ft(dv.x), "FT/S"), .init("DVY", ft(dv.y), "FT/S"),
                           .init("DVZ", ft(dv.z), "FT/S")]
            d.prompt = "BODY DV SINCE P47: RETURN FOR P00"
        }
        return d
    }

    /// The display in one line while it flashes ("P40 V99N40 ENABLE ENGINE
    /// IGNITION? RETURN"), for the HUD to repeat; nil otherwise.
    public var flashingPrompt: String? {
        let d = display
        guard d.flashing else { return nil }
        let vn = [d.verb.map { String(format: "V%02d", $0) }, d.noun.map { String(format: "N%02d", $0) }]
            .compactMap { $0 }.joined()
        return [d.program.map { String(format: "P%02d", $0) }, vn.isEmpty ? nil : vn, d.prompt]
            .compactMap { $0 }.joined(separator: " ")
    }

    /// VG in the crew's body axes (Apollo X, Y, Z), m/s.
    public var residuals: Vec3? {
        guard let b = burn, let s = situation else { return nil }
        return s.controlFrame.inverseRotate(s.attitude.inverseRotate(b.velocityToBeGained))
    }

    static func title(_ program: Int) -> String {
        switch program {
        case 0: "CMC IDLING"
        case 30: "EXTERNAL DV"
        case 40: "SPS"
        case 41: "RCS"
        case 47: "THRUST MONITOR"
        default: ""
        }
    }

    /// Apoapsis and periapsis altitudes (m, nil apoapsis when unbound) and
    /// the time of free fall to 300,000 ft (s; nil when the orbit does not
    /// come down through it).
    func apsides(_ s: Kepler.State, mu: Double, radius: Double) -> (apo: Double?, peri: Double, tff: Double?) {
        let el = OrbitalElements(position: s.position, velocity: s.velocity, mu: mu)
        let tff = el.periapsisRadius < radius + 300_000 * Self.foot
            ? el.timeTo(radius: radius + 300_000 * Self.foot, outbound: false) : nil
        return (el.isBound ? el.apoapsisRadius - radius : nil, el.periapsisRadius - radius, tff)
    }

    /// N42: the orbit after the load's burn, impulsive at the middle of the
    /// burn, on the conic.
    func predicted(_ l: ManeuverPlan, from s: Situation) -> (apo: Double?, peri: Double) {
        let middle = l.ignition + (l.burnTime ?? 0) / 2
        var at = Kepler.propagate(s.state, mu: s.mu, by: middle - s.time)
        at.velocity += l.deltaV
        let a = apsides(at, mu: s.mu, radius: s.radius)
        return (a.apo, a.peri)
    }
}

extension CMCLite.Situation {
    init(_ v: Vessel, at now: Epoch) {
        let sps = v.thrusters.first { $0.name == "SPS" && $0.isAvailable }
        self.init(time: now, state: Kepler.State(position: v.position, velocity: v.velocity), mu: v.reference.gm,
                  radius: v.reference.radius, attitude: v.attitude, controlFrame: v.controlFrame, mass: v.mass,
                  sps: sps.map { ($0.maxThrustVacuum, $0.ispVacuum) })
    }
}

/// The accelerometers' Δv as the computer counts it: thrust over mass,
/// along the engines' thrust (Average-G's sensed Δv; drag in orbit is left
/// out).
public struct AverageG {
    /// When it started; nil before.
    public private(set) var start: Epoch?
    /// The Δv sensed since it started, ICRF, m/s.
    public private(set) var sensed = Vec3.zero
    /// The sum of the increments' sizes, m/s (N40's ΔVM).
    public private(set) var measured = 0.0
    private var last: Epoch?
    private var lastDirection: Vec3?

    public init() {}

    mutating func begin(at now: Epoch) {
        guard start == nil else { return }
        start = now
        last = now
    }

    /// The Δv sensed over the step that has just ended at `now` (ICRF):
    /// the thrust acceleration it flew (`Vessel.thrustAcceleration`) along
    /// the thrust's direction now (the last one when the thrust is gone).
    @discardableResult
    mutating func sense(_ v: Vessel, in sim: Simulation, now: Epoch) -> Vec3 {
        guard start != nil else { return .zero }
        defer { last = now }
        let p0 = sim.atmosphere(of: v.reference)?.seaLevelPressure ?? 0
        let f = v.thrustForceAndTorque(ambientPressure: v.atmosphere.pressure, seaLevelPressure: p0).force
        if f.length > 0 { lastDirection = v.attitude.rotate(f / f.length) }
        guard let t0 = last, now > t0, let d = lastDirection, v.thrustAcceleration > 0 else { return .zero }
        let dv = d * (v.thrustAcceleration * (now - t0))
        sensed += dv
        measured += dv.length
        return dv
    }
}
