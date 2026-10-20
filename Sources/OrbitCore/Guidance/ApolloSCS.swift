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
///
/// Automatic P40 (the CMC lighting the SPS at TIG) is M3's: the pilot
/// lights the SPS (the main throttle) and the counter cuts it off.
public final class ApolloSCS: FlightProgram, DeltaVCounting {
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
        if !smGone && !v.parts.contains(where: { $0.name == "SM" }) {
            smGone = true
            sim.log("\(v.name): SM gone, \(successor == nil ? "SCS holds the CM" : "entry program")")
        }
        if smGone, let next = successor {
            next.update(v, in: sim)
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
        return next
    }

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

    public func nextEvent(at now: Epoch) -> (name: String, at: Epoch)? {
        if smGone, let next = successor { return next.nextEvent(at: now) }
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
    /// when, so the simulation ends a step there.
    func countDeltaV(_ v: Vessel, in sim: Simulation, now: Epoch) {
        guard var remaining = deltaVRemaining else { return }
        let p0 = sim.atmosphere(of: v.reference)?.seaLevelPressure ?? 0
        let force = v.thrustForceAndTorque(ambientPressure: v.atmosphere.pressure, seaLevelPressure: p0).force
        let alongX = force.length > 0 ? force.x / force.length : 1
        if let last = lastUpdate { remaining -= v.thrustAcceleration * alongX * max(0, now - last) }
        deltaVRemaining = remaining
        pendingCutoff = nil
        guard !cutoffDone, spsBurning(v) else { return }
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
        if spsBurning(v) { line += ", SPS on" }
        if armedAt != nil { line += ", CM/SM SEP armed" }
        return line
    }
}
