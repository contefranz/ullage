import Foundation

/// The Apollo Block II earth landing system (ELS), flown from Apollo 7 on:
/// baroswitches and timers that bring the command module down on its
/// parachutes (TN D-7437 Fig. 2 and pp. 4-8, H):
/// 1. armed, the 24,000 ft baroswitch (39.3 kPa static pressure, US 1976)
///    closes; 0.4 s later the apex cover is jettisoned (staging event 30);
/// 2. 1.6 s after that the drogue mortars fire: two drogues, reefed for 10 s
///    (their reefing cutters run in `Parachute`);
/// 3. the 10,000 ft baroswitch (69.7 kPa) releases the drogues (event 31)
///    and fires the pilot mortars: three mains, disreefed at 6 and 10 s.
///    The CM RCS is switched off;
/// 4. once the CM is down, the mains are released (event 32).
///
/// It works on any vessel carrying the CM's parts by name ("Apex cover",
/// "Drogue parachutes", "Main parachutes"). A program hosting it (the CM's
/// entry program) calls `arm()` when the crew would arm the ELS, and its own
/// `update`, `timeToNextEvent`, `nextEvent` and `status` call these; the ELS
/// is also a `FlightProgram` on its own. Pressures are read from the
/// vessel's telemetry (`Vessel.atmosphere`), so a baroswitch acts at the
/// start of the step after it closes.
public final class EarthLandingSystem: FlightProgram {
    /// Static pressure at which the upper baroswitch closes, Pa: 24,000 ft in
    /// the US Standard Atmosphere 1976 (TN D-7437 Fig. 2, H).
    public var upperBaroswitch = 39_300.0
    /// Static pressure at which the lower baroswitch closes, Pa: 10,000 ft
    /// (M: TN D-7437 gives "approximately 11,000 feet", 67.0 kPa; Apollo
    /// 15's mains deployed at about 10,000 ft).
    public var lowerBaroswitch = 69_700.0
    /// From the upper baroswitch to the apex cover's jettison, and to the
    /// drogue mortars, s (TN D-7437 Fig. 2: 24,000 ft + 0.4 s and + 2 s, H).
    public static let apexCoverDelay = 0.4
    public static let drogueMortarDelay = 2.0
    /// Timers count as reached this close to their time, s: an `Epoch` near
    /// 1969 resolves about 1e-7 s, and a step ending a hair short of a timer
    /// must not leave a sliver for the next.
    static let timeResolution = 1e-5

    public private(set) var isArmed: Bool
    /// When each step happened; nil until it has.
    public private(set) var upperBaroswitchClosed: Epoch?
    public private(set) var apexCoverJettisoned: Epoch?
    public private(set) var droguesDeployed: Epoch?
    public private(set) var mainsDeployed: Epoch?
    public private(set) var mainsReleased: Epoch?
    /// The canopies the ELS has deployed and not released, whose reefing
    /// schedules end steps (`timeToNextEvent`).
    private var canopies: [Parachute] = []

    public init(armed: Bool = false) {
        isArmed = armed
    }

    /// Arm the sequence (the crew's ELS logic and auto switches).
    public func arm() { isArmed = true }

    /// One step of the sequence on `v` at `sim.time`.
    public func update(_ v: Vessel, in sim: Simulation) {
        guard isArmed, v.status != .crashed else { return }
        let now = sim.time, p = v.atmosphere.pressure
        let epsilon = Self.timeResolution
        if upperBaroswitchClosed == nil {
            guard v.landed == nil, p >= upperBaroswitch else { return }
            upperBaroswitchClosed = now
            sim.log("\(v.name): ELS sequence started")
        }
        guard let start = upperBaroswitchClosed else { return }
        if apexCoverJettisoned == nil, now - start >= Self.apexCoverDelay - epsilon {
            jettisonApexCover(v, in: sim)
        }
        if droguesDeployed == nil, now - start >= Self.drogueMortarDelay - epsilon {
            deployDrogues(v, in: sim)
        }
        if mainsDeployed == nil, droguesDeployed != nil, v.landed == nil, p >= lowerBaroswitch {
            deployMains(v, in: sim)
        }
        if mainsReleased == nil, mainsDeployed != nil, v.landed != nil {
            releaseMains(v, in: sim)
        }
    }

    /// The crew's backup: do the next step of the sequence now (and arm it).
    /// Returns false when nothing is left.
    @discardableResult
    public func advance(_ v: Vessel, in sim: Simulation) -> Bool {
        isArmed = true
        if upperBaroswitchClosed == nil { upperBaroswitchClosed = sim.time }
        if apexCoverJettisoned == nil {
            jettisonApexCover(v, in: sim)
            // The drogue mortars follow on their own timer.
            upperBaroswitchClosed = sim.time + (-Self.apexCoverDelay)
        } else if droguesDeployed == nil {
            deployDrogues(v, in: sim)
        } else if mainsDeployed == nil {
            deployMains(v, in: sim)
        } else if mainsReleased == nil {
            releaseMains(v, in: sim)
        } else {
            return false
        }
        return true
    }

    // MARK: Steps

    func jettisonApexCover(_ v: Vessel, in sim: Simulation) {
        apexCoverJettisoned = sim.time
        if v.parts.contains(where: { $0.name == "Apex cover" }) {
            sim.stage(v, event: ApolloCM.apexCoverEvent)
        }
    }

    func deployDrogues(_ v: Vessel, in sim: Simulation) {
        droguesDeployed = sim.time
        deploy(chutesOf: "Drogue parachutes", on: v, at: sim.time)
        sim.log("\(v.name): drogues deployed")
    }

    func deployMains(_ v: Vessel, in sim: Simulation) {
        mainsDeployed = sim.time
        if let drogues = v.parts.first(where: { $0.name == "Drogue parachutes" }) {
            for c in drogues.parachutes { c.release() }
            canopies.removeAll { c in drogues.parachutes.contains { $0 === c } }
            sim.stage(v, event: ApolloCM.droguesEvent)
        }
        deploy(chutesOf: "Main parachutes", on: v, at: sim.time)
        for t in v.thrusters where t.name.hasPrefix("CM RCS") { t.isEnabled = false }
        sim.log("\(v.name): mains deployed, CM RCS off")
    }

    func releaseMains(_ v: Vessel, in sim: Simulation) {
        mainsReleased = sim.time
        if let mains = v.parts.first(where: { $0.name == "Main parachutes" }) {
            for c in mains.parachutes { c.release() }
            sim.stage(v, event: ApolloCM.mainsEvent)
        }
        canopies.removeAll()
    }

    private func deploy(chutesOf partName: String, on v: Vessel, at t: Epoch) {
        guard let part = v.parts.first(where: { $0.name == partName }) else { return }
        for c in part.parachutes {
            c.deploy(at: t)
            canopies.append(c)
        }
    }

    // MARK: Program

    /// The next timed step or reefing change.
    public func nextEvent(at now: Epoch) -> (name: String, at: Epoch)? {
        var events: [(name: String, at: Epoch)] = []
        if isArmed, let start = upperBaroswitchClosed {
            if apexCoverJettisoned == nil { events.append(("Apex cover", start + Self.apexCoverDelay)) }
            if droguesDeployed == nil { events.append(("Drogues", start + Self.drogueMortarDelay)) }
        }
        for c in canopies {
            guard let t0 = c.deployedAt else { continue }
            var at = t0
            for stage in c.reefing {
                at = at + stage.duration
                events.append(("\(c.name) disreef", at))
            }
        }
        return events.filter { $0.at > now }.min { $0.at < $1.at }
    }

    public func timeToNextEvent(at now: Epoch) -> Double? {
        var times = [nextEvent(at: now)?.at].compactMap { $0 }
        for c in canopies { times += c.scheduleCorners(after: now) }
        return times.map { $0 - now }.filter { $0 > Self.timeResolution }.min()
    }

    public var status: String {
        guard isArmed else { return "ELS safe" }
        if mainsReleased != nil { return "ELS mains released" }
        if mainsDeployed != nil { return "ELS mains " + describe(canopies.last) }
        if droguesDeployed != nil { return "ELS drogues " + describe(canopies.last) }
        if apexCoverJettisoned != nil { return "ELS apex cover off" }
        if upperBaroswitchClosed != nil { return "ELS sequence started" }
        return "ELS armed"
    }

    private func describe(_ c: Parachute?) -> String {
        switch c?.state {
        case .deploying?: return "deploying"
        case .reefed(let n)?: return "reefed \(n)"
        case .open?: return "open"
        default: return ""
        }
    }

    /// The sequence stages the CM itself: the pilot's Space key does not,
    /// while it is armed and not done.
    public func allowsManualStaging(of vessel: Vessel) -> Bool { !isArmed || mainsReleased != nil }

    public var hostPart: String? { "CM" }
}
