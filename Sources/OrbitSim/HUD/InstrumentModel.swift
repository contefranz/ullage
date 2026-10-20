import Foundation
import Combine
import OrbitCore
import OrbitInstruments

/// What the flight instruments show, refreshed every frame (`update`, from
/// `AppModel.tick`) and pulled by the navball's Metal view and the cluster's
/// timeline, so the ball and the tapes move in step with the scene. Only the
/// HUD's visibility is published.
@MainActor
final class InstrumentModel: ObservableObject {
    /// F2 (or the key left of 1) cycles them: everything, the instrument
    /// cluster alone, nothing (clean screenshots).
    enum Visibility: CaseIterable {
        case full, instruments, off
    }

    @Published private(set) var visibility = Visibility.full

    /// The speed mode the automatic rule gives (40/50 km); nil before the
    /// first update.
    private(set) var automaticFrame: VelocityFrame?
    /// The pilot's choice (N), kept until the automatic mode next changes.
    private(set) var override: VelocityFrame?
    /// The speed mode shown.
    var frame: VelocityFrame { override ?? automaticFrame ?? .orbit }

    /// The vessel target mode and the target markers refer to (Y); nil for
    /// none.
    private(set) var targetID: UUID?
    /// Where the burn loaded for a vessel comes from (DEORBIT's SET, through
    /// `MFDModel`); nil shows no manoeuvre marker.
    var maneuverSource: (@MainActor (Vessel) -> ActiveManeuver?)?

    private(set) var navball: Navball?
    private(set) var readouts = Readouts()

    /// The cluster's numbers besides the ball's.
    struct Readouts {
        var frame = VelocityFrame.orbit
        var automatic = true
        var speed = 0.0
        var altitude = 0.0
        var verticalSpeed = 0.0
        var apoapsisAltitude: Double?
        var periapsisAltitude: Double?
        var mach = 0.0
        var dynamicPressure = 0.0
        /// Commanded main throttle, 0...1.
        var throttle = 0.0
        var autopilot: AttitudeAutopilot?
        /// The program whose command the hold flies, for the HOLD row ("IU",
        /// "SCS", "CM"); nil when the hold flies none.
        var holdProgram: String?
        var landed = true
        /// The g meter, bank, heating, ELS and 0.05 g light, while they matter.
        var entry: EntryReadouts?
        /// The target's name, and this vessel relative to it.
        var target: (name: String, relative: TargetRelative)?
        /// The flight program's next event, or the loaded burn's ignition,
        /// and the seconds to it.
        var nextEvent: (name: String, timeToGo: Double)?
        /// The burn loaded (DEORBIT's SET) while it is still to fly.
        var maneuver: ActiveManeuver?
    }

    /// Forget the speed mode and the target for a new scenario.
    func reset() {
        automaticFrame = nil
        override = nil
        targetID = nil
        navball = nil
    }

    /// Recompute the ball and the readouts for the focus vessel.
    func update(sim: Simulation) {
        guard let v = sim.focus else {
            navball = nil
            return
        }
        let snap = sim.snapshot
        let auto = Navball.autoFrame(previous: automaticFrame, vessel: v, snapshot: snap)
        if let previous = automaticFrame, previous != auto { override = nil }
        automaticFrame = auto
        let target = self.target(in: sim)
        if target == nil {
            targetID = nil
            if override == .target { override = nil }
        }
        let maneuver = maneuverSource?(v)
        let ball = Navball(vessel: v, in: sim, snapshot: snap, frame: frame, target: target,
                           maneuver: maneuver?.direction)
        navball = ball

        var r = Readouts()
        r.frame = frame
        r.automatic = override == nil
        r.speed = ball.speed
        r.altitude = v.altitude
        r.verticalSpeed = ball.verticalSpeed
        if v.landed == nil {
            let el = v.elements(snapshot: snap)
            r.apoapsisAltitude = el.isBound ? el.apoapsisRadius - v.reference.radius : nil
            r.periapsisAltitude = el.periapsisRadius - v.reference.radius
        }
        r.mach = v.mach
        r.dynamicPressure = v.dynamicPressure
        r.throttle = v.mainThrottle
        r.autopilot = v.autopilot
        r.holdProgram = v.autopilot == .attitudeHold && v.attitudeCommand != nil ? Self.programName(v) : nil
        r.landed = v.landed != nil
        r.entry = EntryReadouts(vessel: v)
        if let t = target, let rel = ball.target { r.target = (t.name, rel) }
        r.maneuver = maneuver
        var next = v.flightProgram?.nextEvent(at: sim.time)
        if let m = maneuver, m.ignition > sim.time, next.map({ m.ignition < $0.at }) ?? true {
            next = (m.name + " TIG", m.ignition)
        }
        r.nextEvent = next.map { ($0.name, $0.at - sim.time) }
        readouts = r
    }

    /// A short name for the vessel's flight program: the Saturn's IU, the
    /// CSM's SCS, the CM's entry program (also when the SCS hosts it, the
    /// SM gone); nil without one.
    static func programName(_ v: Vessel) -> String? {
        switch v.flightProgram {
        case nil: return nil
        case is SaturnIU: return "IU"
        case is CMEntryProgram, is EarthLandingSystem: return "CM"
        case is ApolloSCS: return v.parts.contains { $0.name == "SM" } ? "SCS" : "CM"
        default: return "PGM"
        }
    }

    // MARK: Target

    /// The target, if it is still in the simulation and not the focus.
    private func target(in sim: Simulation) -> Vessel? {
        guard let id = targetID, let t = sim.vessels.first(where: { $0.id == id }), t !== sim.focus,
              t.status != .crashed else { return nil }
        return t
    }

    /// The vessels the target can be, nearest the focus first: every other
    /// vessel still flying or landed.
    func targetCandidates(in sim: Simulation) -> [Vessel] {
        guard let v = sim.focus else { return [] }
        let snap = sim.snapshot
        return sim.vessels.filter { $0 !== v && $0.status != .crashed }
            .map { ($0, TargetRelative(of: v, to: $0, snapshot: snap).range) }
            .sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Select the next target (Y): the nearest vessel, then each farther
    /// one, then none. Target mode ends with the target.
    func cycleTarget(sim: Simulation) {
        let candidates = targetCandidates(in: sim)
        if let i = candidates.firstIndex(where: { $0.id == targetID }) {
            targetID = i + 1 < candidates.count ? candidates[i + 1].id : nil
        } else {
            targetID = candidates.first?.id
        }
        if targetID == nil, override == .target { override = nil }
        update(sim: sim)
    }

    /// Take `key` if it is the instruments' (N: speed mode; Y: target; F2
    /// or the key left of 1: HUD visibility). Returns true when taken.
    func handle(_ key: PhysicalKey, sim: Simulation) -> Bool {
        switch key {
        case .n:
            // The next mode (target mode only with a target); back on the
            // automatic one, the override ends.
            let modes: [VelocityFrame] = target(in: sim) == nil ? [.orbit, .surface] : [.orbit, .surface, .target]
            let next = modes[((modes.firstIndex(of: frame) ?? 0) + 1) % modes.count]
            override = next == automaticFrame ? nil : next
            update(sim: sim)
            return true
        case .y:
            cycleTarget(sim: sim)
            return true
        case .f2, .grave, .isoSection:
            let all = Visibility.allCases
            visibility = all[((all.firstIndex(of: visibility) ?? 0) + 1) % all.count]
            return true
        default:
            return false
        }
    }
}
