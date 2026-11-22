import Foundation

/// The CSM's stabilization and control system, as the crew flew it after
/// orbit insertion: the program aboard the CM (`hostPart` "CM"). The CM part
/// carries it on standby on the launch stack; it takes over once the IU has
/// left with the S-IVB (`VesselPart.standbyProgram`).
///
/// - It sets the CSM's laws when it takes over: the phase-plane law on the
///   SM RCS with the narrow (0.5°) or wide (5°) dead band
///   (`ApolloCSM.phasePlaneLaw`), and the SPS's thrust-vector control.
/// - It trims the SPS gimbal through the centre of mass, as the CMC's trim
///   did before a burn and its trim tracker during one: the attitude law then
///   only steers.
/// - Its EMS ΔV counter (`DeltaVCounting`): loaded with a burn's Δv, it
///   counts down the Δv sensed along X_A while anything thrusts, and cuts
///   the SPS off (the main throttle) as it reaches zero; it counts on
///   through the tail-off, below zero.
/// - An SCS built for a launch stack (`separationUllage`) fires the SM RCS's
///   +X jets for that long once it takes over at the CSM/LV separation,
///   standing in for the crew's +X translation through the CSM/LV SEP push.
/// - Space for CM/SM separation (event 7) needs a second press within 2 s of
///   wall-clock time (`Simulation.clock`), so that time warp does not
///   stretch it.
/// - Once the SM has left, `successor` (the CM's entry program) flies the
///   vessel: every call is forwarded to it.
/// - It hosts the onboard computer, `computer` (M2's CMC-lite), run first
///   in each of its steps while the SM is aboard. Under G&N AUTO (`gnAuto`:
///   G, or Return at P40's V50N18) the computer's attitude is the hold's
///   command; 8, a pointing mode or the RCS rotation keys hand the attitude
///   back to the SCS. The computer lights the SPS at TIG in P40 and cuts
///   it off on VG: the EMS counter then counts but does not cut off, so a
///   burn has one cutoff authority (docs/m2/design-flight-controls.md §10,
///   decisions 1 and 9). Z remains the SCS way: the pilot lights the SPS
///   and the counter cuts it off. The computer's warp events are the SCS's.
public final class ApolloSCS: FlightProgram, DeltaVCounting, GuidanceComputerHost {
    /// The onboard computer (CMC-lite).
    public let computer = CMCLite()
    public var guidanceComputer: GuidanceComputer { computer }
    /// G&N AUTO: the computer flies the attitude, through the hold's
    /// command (`Vessel.attitudeCommand` under `.attitudeHold`).
    public private(set) var gnAuto = false
    /// What flies the CM once the SM has gone (track E1's entry program).
    public var successor: FlightProgram?
    /// Seconds of +X ullage at the CSM/LV separation; 0 for none (a CSM that
    /// starts alone).
    public let separationUllage: Double
    /// The wide dead band (5°) instead of the narrow one (0.5°).
    public var wideDeadband = false {
        didSet { lawChanged = true }
    }

    public private(set) var deltaVRemaining: Double?
    public private(set) var status = "SCS"

    private var configured = false
    private var lawChanged = false
    private var lastUpdate: Epoch?
    private var ullageUntil: Epoch?
    private var cutoffDone = false
    private var pendingCutoff: Epoch?
    /// The first Space press for CM/SM separation (wall clock, s), and the clock.
    private var armedAt: Double?
    private var clock: (() -> Double)?
    private var smGone = false

    public init(separationUllage: Double = 0) {
        self.separationUllage = separationUllage
    }

    // MARK: DeltaVCounting

    public func loadDeltaV(_ deltaV: Double?) {
        deltaVRemaining = deltaV
        cutoffDone = false
        pendingCutoff = nil
    }

    // MARK: FlightProgram

    public var hostPart: String? { "CM" }

    public func update(_ v: Vessel, in sim: Simulation) {
        let now = sim.time
        clock = sim.clock
        defer { lastUpdate = now }
        if !smGone, v.parts.contains(where: { $0.name == "SM" }) {
            computer.update(v, in: sim)
            flyComputer(v, in: sim)
        }
        if !smGone && !v.parts.contains(where: { $0.name == "SM" }) {
            smGone = true
            sim.log("\(v.name): SM gone, \(successor == nil ? "SCS holds the CM" : "entry program")")
        }
        if smGone, let next = successor {
            next.update(v, in: sim)
            status = next.status
            return
        }
        if !configured {
            configured = true
            lawChanged = true
            if separationUllage > 0 {
                ullageUntil = now + separationUllage
                sim.log("\(v.name): CSM/LV separation, +X ullage")
            }
        }
        if lawChanged {
            lawChanged = false
            v.phasePlane = ApolloCSM.phasePlaneLaw(deadband: wideDeadband ? ApolloCSM.wideDeadband
                                                                         : ApolloCSM.narrowDeadband)
            v.tvcGains = ApolloCSM.spsTVCGains
        }
        trimGimbal(v)
        countDeltaV(v, in: sim, now: now)
        if let end = ullageUntil {
            if end - now > 1e-9 { v.translationInput.x = 1 } else {
                ullageUntil = nil
                v.translationInput.x = 0
            }
        }
        if let a = armedAt, let c = clock, c() - a > ApolloCSM.separationGuard { armedAt = nil }
        status = statusLine(v)
    }

    public func timeToNextEvent(at now: Epoch) -> Double? {
        if smGone, let next = successor { return next.timeToNextEvent(at: now) }
        var next: Double?
        if let end = ullageUntil, end > now { next = end - now }
        if let c = pendingCutoff, c > now { next = min(next ?? (c - now), c - now) }
        if let c = computer.timeToNextEvent(at: now) { next = min(next ?? c, c) }
        return next
    }

    public func warpEvents(after now: Epoch) -> [WarpEvent] {
        if smGone { return successor?.warpEvents(after: now) ?? [] }
        return computer.warpEvents(after: now)
    }

    // MARK: G&N AUTO

    /// G: give the attitude to the computer, if it has one to fly; false
    /// (logged) when it has none.
    @discardableResult
    public func selectGNAuto(_ v: Vessel, in sim: Simulation) -> Bool {
        guard !smGone, computer.attitudeCommand != nil else {
            sim.log("\(v.name): G&N AUTO refused, no computer attitude")
            return false
        }
        startGNAuto(v, in: sim)
        return true
    }

    /// Hand the attitude back to the SCS (8): the hold captures the
    /// attitude now.
    public func clearGNAuto(_ v: Vessel, in sim: Simulation, reason: String = "SCS hold") {
        guard gnAuto else { return }
        gnAuto = false
        v.attitudeCommand = nil
        sim.log("\(v.name): G&N AUTO off, \(reason)")
    }

    private func startGNAuto(_ v: Vessel, in sim: Simulation) {
        computer.restartSlew(from: v.attitude)
        if !gnAuto { sim.log("\(v.name): G&N AUTO") }
        gnAuto = true
        v.autopilot = .attitudeHold
        if let c = computer.attitudeCommand { v.attitudeCommand = c }
    }

    /// After the computer's step: G&N AUTO asked for at V50N18, the pilot
    /// taking the attitude back (rotation keys, a pointing mode), and the
    /// computer's attitude written to the hold.
    private func flyComputer(_ v: Vessel, in sim: Simulation) {
        if computer.takeAutoManeuverRequest() { startGNAuto(v, in: sim) }
        guard gnAuto else { return }
        if !v.rotationInput.isZero {
            clearGNAuto(v, in: sim, reason: "SCS takeover (RCS)")
            return
        }
        if v.autopilot != .attitudeHold {
            gnAuto = false
            sim.log("\(v.name): G&N AUTO off, \(v.autopilot?.rawValue ?? "free")")
            return
        }
        if let c = computer.attitudeCommand { v.attitudeCommand = c }
    }

    /// The Space key's check: for CM/SM separation (event 7) the first press
    /// arms the guard and is refused, a second within
    /// `ApolloCSM.separationGuard` of the simulation's clock is allowed.
    public func allowsManualStaging(of vessel: Vessel) -> Bool {
        if smGone, let next = successor { return next.allowsManualStaging(of: vessel) }
        guard vessel.nextStagingEvent == 7 else { return true }
        let t = clock?() ?? 0
        if let a = armedAt, t - a <= ApolloCSM.separationGuard {
            armedAt = nil
            return true
        }
        armedAt = t
        status = "CM/SM SEP armed: Space again within 2 s"
        return false
    }

    /// The guard as it stands, without arming or clearing it.
    public func manualStaging(of vessel: Vessel) -> ManualStaging {
        if smGone, let next = successor { return next.manualStaging(of: vessel) }
        guard vessel.nextStagingEvent == 7 else { return .allowed }
        let t = clock?() ?? 0
        return .guarded(armed: armedAt.map { t - $0 <= ApolloCSM.separationGuard } ?? false)
    }

    public func nextEvent(at now: Epoch) -> (name: String, at: Epoch)? {
        if smGone, let next = successor { return next.nextEvent(at: now) }
        if let e = computer.nextEvent(at: now) { return e }
        if let c = pendingCutoff { return ("SPS cutoff (ΔV counter)", c) }
        if let end = ullageUntil { return ("CSM/LV separation ullage off", end) }
        return nil
    }

    // MARK: SPS

    /// Set the SPS gimbal's bias to the angles that put its thrust through
    /// the centre of mass, inside its travel; the attitude law deflects
    /// about them.
    func trimGimbal(_ v: Vessel) {
        let com = v.centerOfMass
        for p in v.parts {
            for t in p.thrusters where t.name == "SPS" && t.gimbal.count == 2 {
                let r = com - (t.position + p.offset)   // gimbal to centre of mass
                let along = r.dot(t.direction)
                guard along > 1e-6 else { continue }
                for i in t.gimbal.indices {
                    let a = t.gimbal[i]
                    t.gimbal[i].bias = min(a.range.upperBound, max(a.range.lowerBound, atan(r.dot(a.tilt) / along)))
                }
            }
        }
    }

    /// The EMS counter: the last step's sensed Δv along X_A (thrust over
    /// mass, the step's thrust direction from the engines' now), and the SPS
    /// cutoff as the counter reaches zero. While the SPS burns it predicts
    /// when, so the simulation ends a step there. In a burn the computer lit
    /// it only counts (decision 9).
    func countDeltaV(_ v: Vessel, in sim: Simulation, now: Epoch) {
        guard var remaining = deltaVRemaining else { return }
        let p0 = sim.atmosphere(of: v.reference)?.seaLevelPressure ?? 0
        let force = v.thrustForceAndTorque(ambientPressure: v.atmosphere.pressure, seaLevelPressure: p0).force
        let alongX = force.length > 0 ? force.x / force.length : 1
        if let last = lastUpdate { remaining -= v.thrustAcceleration * alongX * max(0, now - last) }
        deltaVRemaining = remaining
        pendingCutoff = nil
        guard !cutoffDone, spsBurning(v), !computer.ownsThrust else { return }
        let rate = force.x / max(v.mass, 1e-9)
        let toGo = rate > 0 ? remaining / rate : .infinity
        if toGo < 1e-3 {
            v.mainThrottle = 0
            cutoffDone = true
            sim.log(String(format: "%@: SPS cutoff (ΔV counter), %.1f m/s to go", v.name, remaining))
        } else {
            pendingCutoff = now + toGo
        }
    }

    func spsBurning(_ v: Vessel) -> Bool {
        v.mainThrottle > 0 && v.thrusters.contains { $0.name == "SPS" && $0.isAvailable && $0.hasPropellant }
    }

    private func statusLine(_ v: Vessel) -> String {
        var line = "SCS " + (wideDeadband ? "wide" : "narrow") + " dead band"
        if ullageUntil != nil { line += ", CSM/LV SEP +X ullage" }
        if let dv = deltaVRemaining { line += String(format: ", ΔV %.1f m/s", dv) }
        if spsBurning(v) { line += computer.ownsThrust ? ", SPS on (CMC)" : ", SPS on" }
        if gnAuto { line += ", G&N AUTO" }
        if armedAt != nil { line += ", CM/SM SEP armed" }
        return line
    }
}
