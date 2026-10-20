import Foundation

/// The command module's entry program: it flies the CM from CM/SM
/// separation to splashdown.
///
/// 1. Dormant while an "SM" part is aboard (a CSM's program hosts it until
///    the SM leaves).
/// 2. Pre-entry, from the first step without the SM: it arms the CM RCS (on
///    its own dead-banded law, `holdLaw`) and
///    the earth landing system, drops the launch day's sounding of the
///    reference body (`Simulation.atmospheres`; the standard air applies
///    over the recovery area), and holds the trim attitude about the air
///    velocity at the mode's bank (`.attitudeHold`), lift up for manual and
///    rolling.
/// 3. Entry, from 0.05 g sensed (the EMS light): the entry autopilot
///    (`.entry`) flies the mode.
/// 4. Under the drogues it damps rates (`.killRotation`); from the mains the
///    ELS has switched the CM RCS off and the program lets go.
///
/// The ELS (`EarthLandingSystem`, on baroswitch pressure) runs inside it
/// from pre-entry on; `advanceELS` is the crew's backup. A display-only
/// landing-point predictor (`prediction`) runs every `predictionInterval`
/// seconds before the drogues. Constant-g guidance is M2's, the CMC's
/// predictor-corrector M3's.
public final class CMEntryProgram: FlightProgram {
    /// What the program flies about the air velocity.
    public enum Mode: Equatable {
        /// The pilot's roll (`pilotRoll`) commands the roll rate about the
        /// stability axis; with it released the bank is held where it is.
        case manual
        /// Hold `bank` rad (0 lift up, π lift down, positive right).
        case bankHold(Double)
        /// Roll at `rate` rad/s: zero mean lift.
        case rolling(Double)
    }

    public enum Phase: Equatable {
        case dormant, preEntry, entry, drogues, mains, landed
    }

    public var mode: Mode {
        didSet { if mode != oldValue { heldBank = nil } }
    }
    /// In manual mode, the pilot's roll command, -1...1 of the entry
    /// autopilot's top roll rate, positive raising the bank (the app sets
    /// it from the roll keys).
    public var pilotRoll = 0.0
    public let els: EarthLandingSystem
    public private(set) var phase = Phase.dormant
    /// When the program woke (the SM gone) and when it sensed 0.05 g.
    public private(set) var activated: Epoch?
    public private(set) var pointZeroFiveG: Epoch?
    /// Highest load factor sensed since it woke, g.
    public private(set) var peakLoadFactor = 0.0
    /// The last landing-point prediction, and how often it is made, s.
    public private(set) var prediction: LandingPointPredictor.Prediction?
    public var predictionInterval = 2.0
    public var predictor = LandingPointPredictor()
    /// Sensed load factor that starts the entry phase, g.
    public static let entryLoadFactor = 0.05
    /// The bank manual mode holds once the pilot lets go (`targetBank`).
    var heldBank: Double?
    var lastPrediction: Epoch?

    public init(mode: Mode = .bankHold(0), els: EarthLandingSystem = EarthLandingSystem()) {
        self.mode = mode
        self.els = els
    }

    public var hostPart: String? { "CM" }

    // MARK: Flight

    public func update(_ v: Vessel, in sim: Simulation) {
        if v.parts.contains(where: { $0.name == "SM" }) {
            phase = .dormant
            return
        }
        if phase == .dormant { activate(v, in: sim) }
        els.update(v, in: sim)
        peakLoadFactor = max(peakLoadFactor, v.loadFactor)

        if v.landed != nil {
            if phase != .landed {
                phase = .landed
                v.autopilot = nil
                v.entryCommand = nil
            }
            return
        }
        if els.mainsDeployed != nil {
            if phase != .mains {
                phase = .mains
                v.autopilot = nil
                v.entryCommand = nil
            }
            return
        }
        if els.droguesDeployed != nil {
            if phase != .drogues {
                phase = .drogues
                v.autopilot = .killRotation
                v.entryCommand = nil
            }
            return
        }
        if phase == .preEntry, v.loadFactor >= Self.entryLoadFactor {
            phase = .entry
            pointZeroFiveG = sim.time
            v.autopilot = .entry
            sim.log("\(v.name): 0.05 g")
        }
        if lastPrediction.map({ sim.time - $0 >= predictionInterval }) ?? true { predict(v, in: sim) }
        switch phase {
        case .preEntry: holdTrim(v, in: sim)
        case .entry: v.entryCommand = command(v)
        default: break
        }
    }

    /// The pre-entry hold's law on the CM RCS: a phase plane with a 2° dead
    /// band (half the entry autopilot's bank dead band), turning at 2°/s at
    /// most on a 2.5 s switching line, with 14 ms pulses (L: the CMC's
    /// pre-entry dead band is not in the sources read; the turn and pulse
    /// are the CSM's, `ApolloCSM.phasePlaneLaw`). Its pitch and yaw jets
    /// fire alone, so a proportional law's steady trickle of thrust would
    /// also push the CM off its trajectory before entry interface.
    public static let holdLaw: PhasePlaneLaw = {
        let deg = Double.pi / 180, deadband = 2 * deg, limit = deadband + 2 * deg * 2.5
        return PhasePlaneLaw(deadband: deadband, errorLimit: Vec3(limit, limit, limit), rateGain: 2.5,
                             minimumOnTime: 0.014)
    }()

    /// Wake: arm the CM RCS, on `holdLaw` in place of a CSM's law, and the
    /// ELS; drop the day's sounding.
    func activate(_ v: Vessel, in sim: Simulation) {
        phase = .preEntry
        activated = sim.time
        for t in v.thrusters where t.name.hasPrefix("CM RCS") { t.isEnabled = true }
        v.phasePlane = Self.holdLaw
        els.arm()
        if sim.atmospheres.removeValue(forKey: v.reference.id) != nil {
            sim.log("\(v.name): entry program, standard atmosphere over \(v.reference.name)")
        }
        sim.log("\(v.name): entry program active")
    }

    /// The bank the mode wants now. Manual: where the pilot left it, the
    /// bank of the moment when the mode is chosen and again whenever the
    /// pilot flies the CM by hand (`Vessel.rotationInput`, the RCS keys
    /// before 0.05 g), held from there: aiming at the bank of the moment
    /// would never stop a slow roll inside the hold's dead band.
    func targetBank(_ v: Vessel) -> Double {
        switch mode {
        case .bankHold(let b): return b
        case .rolling: return 0
        case .manual:
            if heldBank == nil || !v.rotationInput.isZero { heldBank = v.bankAngle ?? 0 }
            return heldBank!
        }
    }

    /// The entry autopilot's command for the mode.
    func command(_ v: Vessel) -> EntryCommand {
        switch mode {
        case .bankHold(let b):
            heldBank = nil
            return .bank(b)
        case .rolling(let r):
            heldBank = nil
            return .rolling(rate: r)
        case .manual:
            if pilotRoll != 0 {
                heldBank = nil
                return .rolling(rate: max(-1, min(1, pilotRoll)) * EntryAutopilot.maxRollRate)
            }
            return .bank(targetBank(v))
        }
    }

    /// Before 0.05 g: hold the trim attitude about the air velocity, its
    /// lift side at the mode's bank (`.attitudeHold`).
    func holdTrim(_ v: Vessel, in sim: Simulation) {
        guard let capsule = v.activeAerodynamics?.capsule,
              let q = Self.trimAttitude(of: v, capsule: capsule, bank: targetBank(v), in: sim) else { return }
        v.autopilot = .attitudeHold
        v.attitudeCommand = AttitudeCommand(attitude: q)
    }

    /// The attitude (body -> ICRF) at which `v` flies heat shield first at
    /// `capsule`'s trim, its lift side `bank` rad from the local up about
    /// its air velocity; nil without an air velocity across the vertical.
    public static func trimAttitude(of v: Vessel, capsule: CapsuleAerodynamics, bank: Double,
                                    in sim: Simulation) -> Quat? {
        let s = sim.snapshot, o = s.orientation(v.reference)
        let air = v.velocity - o.angularVelocity.cross(v.position)
        let up = v.reference.vertical(at: v.position, orientation: o)
        guard air.length > 1e-3 else { return nil }
        let f = air.normalized, across = up - f * up.dot(f)
        guard across.length > 1e-6 else { return nil }
        let u = across.normalized, right = f.cross(u)
        let lift = u * cos(bank) + right * sin(bank)
        let trim = capsule.trimAngle(mach: v.mach > 0 ? v.mach : 10, centerOfMass: v.structuralCenterOfMass)
        // Body x and the lift side, and where they go.
        let side = v.liftSide(capsule)
        let x = f * -cos(trim) + lift * sin(trim), g = f * sin(trim) + lift * cos(trim)
        let body = Mat3(columns: .unitX, side, Vec3.unitX.cross(side))
        let world = Mat3(columns: x, g, x.cross(g))
        return Quat(matrix: world * body.transposed).normalized
    }

    // MARK: Prediction

    func predict(_ v: Vessel, in sim: Simulation) {
        lastPrediction = sim.time
        guard phase == .preEntry || phase == .entry, let capsule = v.activeAerodynamics?.capsule else { return }
        var bank: Double? = targetBank(v)
        if case .rolling = mode { bank = nil }
        if case .manual = mode, pilotRoll != 0 { bank = v.bankAngle }
        prediction = predictor.predict(v, capsule: capsule, bank: bank, in: sim)
    }

    // MARK: Program

    /// The crew's ELS backup: fire the next step of the sequence now.
    @discardableResult
    public func advanceELS(_ v: Vessel, in sim: Simulation) -> Bool { els.advance(v, in: sim) }

    public func timeToNextEvent(at now: Epoch) -> Double? {
        phase == .dormant ? nil : els.timeToNextEvent(at: now)
    }

    public func nextEvent(at now: Epoch) -> (name: String, at: Epoch)? {
        phase == .dormant ? nil : els.nextEvent(at: now)
    }

    /// Dormant, the SM's separation is the pilot's (Space); awake, the
    /// sequence is the ELS's, and `advanceELS` its backup.
    public func allowsManualStaging(of vessel: Vessel) -> Bool { phase == .dormant }

    public var status: String {
        let deg = 180 / Double.pi
        var s: String
        switch phase {
        case .dormant: return "ENTRY standby"
        case .preEntry: s = "ENTRY hold"
        case .entry, .drogues, .mains: s = "ENTRY"
        case .landed: s = "ENTRY down"
        }
        switch mode {
        case .manual: s += " manual"
        case .bankHold(let b):
            s += abs(b) < 1e-9 ? " lift up" : abs(abs(b) - .pi) < 1e-9 ? " lift down"
                : String(format: " bank %.0f°%@", abs(b) * deg, b > 0 ? "R" : "L")
        case .rolling(let r): s += String(format: " rolling %.0f°/s", r * deg)
        }
        if pointZeroFiveG != nil { s += String(format: " %.1f g", peakLoadFactor) }
        s += " | " + els.status
        if let p = prediction {
            s += String(format: " | %.1f%@ %.1f%@", abs(p.latitude) * deg, p.latitude >= 0 ? "N" : "S",
                        abs(p.longitude) * deg, p.longitude >= 0 ? "E" : "W")
        }
        return s
    }
}
