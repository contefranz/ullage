import Foundation
import Combine
import OrbitCore
import OrbitInstruments

struct TankInfo: Identifiable, Equatable {
    var id: String
    var name: String
    var fraction: Double
    var mass: Double
    /// The tank belongs to the stage the main throttle drives.
    var inActiveStage = false
}

/// Values shown by the SwiftUI overlay, refreshed ~10 times per second.
struct HUDState: Equatable {
    var vesselName = ""
    var status = ""
    var utc = ""
    var met = ""
    var warp = "1×"
    var paused = false
    /// The warp achieved since the last refresh when a frame fell short of
    /// the set one; nil otherwise.
    var effectiveWarp: String? = nil
    var reference = ""
    var cameraInfo = ""

    /// Geodetic altitude and its rate (the orbit and surface numbers are
    /// the instrument cluster's and the MFDs').
    var altitude = 0.0
    var verticalSpeed = 0.0

    var thrustAcceleration = 0.0
    /// Thrust over the weight at the vessel (the reference body's gravity).
    var thrustToWeight = 0.0
    /// What Space separates next (`nextStage(of:)`).
    var nextStage = "–"
    var deltaV = 0.0
    var mass = 0.0
    var tanks: [TankInfo] = []
    var autopilot: String? = nil
    /// The flight program's HUD line and its label (`programLabel`): the
    /// Saturn's IU, the CSM's SCS, the CM's entry program; nil when the
    /// vessel carries no program.
    var program: String? = nil
    var programLabel = "IU"
    /// Largest deflection of a firing gimballed engine and its range; nil when none fires.
    var gimbal: String? = nil
    /// After F: the stage whose engine the next digit fails ("S-IC engine
    /// 1-5?  (Esc cancels)").
    var failurePrompt: String? = nil
    /// The failed engines still aboard, with the time they failed, then the
    /// failures scheduled on the IU and not yet due.
    var failures: [String] = []
    var events: [String] = []
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var hud = HUDState()
    @Published var showHelp = true
    @Published var showOrbit = true
    @Published private(set) var scenario: Scenario?
    @Published private(set) var loadError: String?

    let input = InputState()
    /// The navball and the flight instruments, updated every frame.
    let instruments = InstrumentModel()
    private(set) var system: SolarSystem?
    private(set) var stars: [Star] = []
    private(set) var sim: Simulation?
    var camera = OrbitCamera()

    /// Zero of the mission clock: the scenario's, else liftoff.
    private var missionStart = Epoch(tdbSecondsPastJ2000: 0)
    /// After F, until the next key: the vessel and stage whose engine a
    /// digit fails, and that stage's main engines in order.
    private var failureCapture: (vessel: Vessel, part: String, engines: [String])?
    private var hudClock = 0.0
    private var rateWindow = RateWindow()
    private static let warpSteps: [Double] = [0.1, 1, 10, 100, 1_000, 10_000, 100_000]
    /// Wall-clock time a frame may spend stepping. A powered step (0.02 s)
    /// costs about 0.5 ms in Debug and 0.05 ms in Release, so without it a
    /// frame at high warp would take seconds.
    private static let stepBudget = 0.04
    /// Longest real interval one frame makes up for.
    private static let maxFrameInterval = 0.1

    /// Real and simulated seconds since the last HUD refresh at one warp,
    /// and whether any frame fell short of it.
    private struct RateWindow {
        var warp = 1.0
        var real = 0.0
        var simulated = 0.0
        var limited = false
    }

    init() {
        do {
            system = try SolarSystem.bundled()
            stars = try StarCatalog.bundled()
            load(Scenario.all[0])
        } catch {
            loadError = "Could not load data files: \(error)"
        }
    }

    func reportError(_ message: String) {
        DispatchQueue.main.async { self.loadError = message }
    }

    func load(_ s: Scenario) {
        guard let system else { return }
        // Fresh body objects each time would be cleaner; the system is
        // stateless apart from its cache, so it is reused.
        let sim = s.build(system)
        sim.stepBudget = Self.stepBudget
        sim.maxRealInterval = Self.maxFrameInterval
        self.sim = sim
        rateWindow = RateWindow(warp: sim.warp)
        scenario = s
        missionStart = s.missionClockZero ?? sim.time
        failureCapture = nil
        instruments.reset()
        if let focus = sim.focus {
            camera.target = .vessel(focus.id)
            camera.distance = max(focus.boundingRadius * 3, 30)
        }
        camera.update(sim: sim)
        instruments.update(sim: sim)
        refreshHUD()
    }

    // MARK: Frame update

    func tick(dt: Double) {
        guard let sim else { return }
        handleKeys(sim: sim, dt: dt)
        // Measure the achieved warp afresh after a pause or a change of warp.
        if sim.paused || sim.warp != rateWindow.warp { rateWindow = RateWindow(warp: sim.warp) }

        let wasLanded = sim.focus?.landed != nil
        let frameStart = sim.time
        sim.advance(by: dt)
        rateWindow.real += dt
        rateWindow.simulated += sim.time - frameStart
        rateWindow.limited = rateWindow.limited || sim.warpLimited
        // Without a scenario's zero the mission clock starts at liftoff, logged
        // at the start of the step that left the ground: at time warp a frame
        // holds many steps, and the vehicle may even be down again by its end.
        if scenario?.missionClockZero == nil, wasLanded, let f = sim.focus,
           let liftoff = sim.events.last(where: { $0.message == "\(f.name): liftoff" && $0.time >= frameStart }) {
            missionStart = liftoff.time
        }

        let mouse = input.takeMouse()
        if mouse.dx != 0 || mouse.dy != 0 { camera.orbit(dx: mouse.dx, dy: mouse.dy) }
        if mouse.scroll != 0 {
            camera.zoom(mouse.scroll, minimum: OrbitCamera.minimumDistance(for: camera.target, sim: sim))
        }
        camera.update(sim: sim)
        instruments.update(sim: sim)

        hudClock += dt
        if hudClock > 0.1 {
            hudClock = 0
            refreshHUD()
            rateWindow = RateWindow(warp: sim.warp)
        }
    }

    private func handleKeys(sim: Simulation, dt: Double) {
        for key in input.takePressed() {
            // F, then a digit: the key after F is the capture's. A digit fails
            // that engine of the stage (none if out of range), so 1-8 and 0
            // never reach the autopilot here; Escape or F cancels; any other
            // key cancels and then acts as usual.
            if let capture = failureCapture {
                failureCapture = nil
                if let n = key.digit {
                    if (1...capture.engines.count).contains(n) {
                        failEngine(capture.engines[n - 1], of: capture.vessel, sim: sim)
                    }
                    continue
                }
                if key == .escape || key == .f { continue }
            }
            if instruments.handle(key, sim: sim) { continue }
            switch key {
            case .h: showHelp.toggle()
            case .m: showOrbit.toggle()
            case .p: sim.paused.toggle()
            case .period: setWarp(step: +1, sim: sim)
            case .comma: setWarp(step: -1, sim: sim)
            case .slash: sim.warp = 1
            case .c: cycleCameraTarget(sim: sim)
            case .v: cycleCameraFrame()
            case .leftBracket: cycleFocus(sim: sim, by: -1)
            case .rightBracket: cycleFocus(sim: sim, by: +1)
            default: break
            }
            guard let v = sim.focus, v.status != .crashed else { continue }
            switch key {
            case .space: stageOrBackUpELS(v, sim: sim)
            case .digit9: cycleEntryMode(of: v, sim: sim)
            case .z: v.mainThrottle = 1
            case .x: v.mainThrottle = 0
            case .t: v.autopilot = v.autopilot == .killRotation ? nil : .killRotation
            case .f:
                if let stage = Self.failableStage(of: v) { failureCapture = (v, stage.part, stage.engines) }
            case .digit1: v.autopilot = .prograde
            case .digit2: v.autopilot = .retrograde
            case .digit3: v.autopilot = .normal
            case .digit4: v.autopilot = .antinormal
            case .digit5: v.autopilot = .radialOut
            case .digit6: v.autopilot = .radialIn
            case .digit7: v.autopilot = .horizonLevel
            case .digit8: v.autopilot = .attitudeHold
            case .digit0: v.autopilot = nil
            default: break
            }
        }

        guard let v = sim.focus else { return }
        if input.isHeld(.equal) { v.mainThrottle = min(1, v.mainThrottle + 0.5 * dt) }
        if input.isHeld(.minus) { v.mainThrottle = max(0, v.mainThrottle - 0.5 * dt) }

        func axis(_ plus: PhysicalKey, _ minus: PhysicalKey) -> Double {
            (input.isHeld(plus) ? 1 : 0) - (input.isHeld(minus) ? 1 : 0)
        }
        var rotation = RotationCommand(roll: axis(.e, .q), pitch: axis(.s, .w), yaw: axis(.d, .a))
        // In the entry program's manual mode, from 0.05 g, Q and E roll the
        // lift about the air velocity (the entry autopilot's coordinated
        // roll) instead of about the CM's axis. The CM flies heat shield
        // first, so a roll to the right about +X turns the lift to the left:
        // E lowers the bank, as it would on the RCS alone.
        if let entry = ApolloMission.entryProgram(of: v), entry.mode == .manual, entry.phase == .entry {
            entry.pilotRoll = -rotation.roll
            rotation.roll = 0
        }
        v.setPilotInput(rotation: rotation, translation: Vec3(axis(.u, .o), axis(.l, .j), axis(.k, .i)))
    }

    /// Space: the next staging event (`Simulation.stage`, which the flight
    /// program may refuse: the IU until T3, the SCS's first press for CM/SM
    /// separation); once the CM's entry program is awake (the SM gone), the
    /// crew's backup of the earth landing system instead, the next step of
    /// its sequence (apex cover, drogues, mains, mains release) that the
    /// baroswitches would otherwise fire. Above `elsBackupCeiling` it does
    /// nothing but log, so a stray press in orbit or high in the entry cannot
    /// fire the parachutes.
    private func stageOrBackUpELS(_ v: Vessel, sim: Simulation) {
        guard let entry = ApolloMission.entryProgram(of: v), entry.phase != .dormant else {
            sim.stage(v)
            return
        }
        guard v.altitude <= Self.elsBackupCeiling else {
            sim.log("\(v.name): ELS backup inhibited above 40,000 ft")
            return
        }
        if !entry.advanceELS(v, in: sim) { sim.log("\(v.name): ELS sequence complete") }
    }

    /// Highest altitude Space backs up the ELS at, m: 40,000 ft, well above
    /// the upper baroswitch's 24,000 ft (an app guard).
    static let elsBackupCeiling = 40_000 * 0.3048
    /// The rolling entry's roll rate, rad/s (L: zero mean lift needs only a
    /// steady roll; 15°/s, under the entry autopilot's 20°/s).
    static let entryRollRate = 15 * Double.pi / 180

    /// 9: the entry program's next mode, manual → bank hold → rolling →
    /// manual. Bank hold holds the bank flown now (lift up while the SM is
    /// aboard, where there is none), so manual sets a bank and bank hold
    /// keeps it. Before CM/SM separation it presets the mode the program
    /// wakes in.
    private func cycleEntryMode(of v: Vessel, sim: Simulation) {
        guard let entry = ApolloMission.entryProgram(of: v) else { return }
        switch entry.mode {
        case .manual: entry.mode = .bankHold(v.bankAngle ?? 0)
        case .bankHold: entry.mode = .rolling(Self.entryRollRate)
        case .rolling: entry.mode = .manual
        }
        entry.pilotRoll = 0
        sim.log("\(v.name): entry mode \(Self.describe(entry.mode))")
    }

    /// "manual", "bank hold 55° L", "lift up", "rolling 15°/s".
    static func describe(_ mode: CMEntryProgram.Mode) -> String {
        let deg = 180 / Double.pi
        switch mode {
        case .manual: return "manual"
        case .bankHold(let b):
            if abs(b) < 0.5 / deg { return "bank hold, lift up" }
            if abs(abs(b) - .pi) < 0.5 / deg { return "bank hold, lift down" }
            return String(format: "bank hold %.0f° %@", abs(b) * deg, b > 0 ? "R" : "L")
        case .rolling(let r): return String(format: "rolling %.0f°/s", r * deg)
        }
    }

    /// The stage F fails an engine of: the lowest part with a main liquid
    /// engine still able to run and fed, and its main liquid engines in the
    /// part's order (the Saturn's "S-IC engine 1" ... "5", 5 the centre).
    static func failableStage(of v: Vessel) -> (part: String, engines: [String])? {
        for p in v.parts {
            let mains = p.thrusters.filter { $0.groups.contains(.main) && !$0.isSolid }
            if mains.contains(where: { $0.isAvailable && $0.hasPropellant }) { return (p.name, mains.map(\.name)) }
        }
        return nil
    }

    /// Fail the named engine now. The Saturn's IU fails it at the start of
    /// the next step (logging it, and sensing it as AS-506's LVDC would);
    /// elsewhere it fails at once.
    private func failEngine(_ name: String, of v: Vessel, sim: Simulation) {
        if let iu = v.flightProgram as? SaturnIU {
            iu.scheduleFailure(of: name, at: .epoch(sim.time))
        } else if let e = v.thrusters.first(where: { $0.name == name }), !e.isFailed {
            e.fail()
            sim.log("\(v.name): \(name) failed")
        }
    }

    private func setWarp(step: Int, sim: Simulation) {
        let steps = Self.warpSteps
        let current = steps.enumerated().min { abs(log($0.element / sim.warp)) < abs(log($1.element / sim.warp)) }?.offset ?? 1
        let next = min(max(current + step, 0), steps.count - 1)
        sim.warp = steps[next]
    }

    private func cycleCameraTarget(sim: Simulation) {
        var targets: [CameraTarget] = sim.vessels.map { .vessel($0.id) }
        targets += [.body(399), .body(301), .body(10)]
        let i = targets.firstIndex(of: camera.target) ?? -1
        camera.target = targets[(i + 1) % targets.count]
        switch camera.target {
        case .vessel(let id):
            let r = sim.vessels.first { $0.id == id }?.boundingRadius ?? 10
            camera.distance = max(r * 3, 30)
        case .body(let id):
            camera.distance = (sim.system.body(id: id)?.radius ?? 1e6) * 3
        }
    }

    private func cycleCameraFrame() {
        switch camera.frame {
        case .horizon: camera.frame = .vessel
        case .vessel: camera.frame = .inertial
        case .inertial: camera.frame = .horizon
        }
    }

    private func cycleFocus(sim: Simulation, by step: Int) {
        let vs = sim.vessels.filter { $0.status != .crashed }
        guard !vs.isEmpty else { return }
        let i = vs.firstIndex { $0 === sim.focus } ?? 0
        let next = vs[(i + step + vs.count) % vs.count]
        sim.focus = next
        camera.target = .vessel(next.id)
        camera.distance = max(next.boundingRadius * 3, 30)
    }

    // MARK: HUD

    private func refreshHUD() {
        guard let sim, let v = sim.focus else { return }
        let snap = sim.snapshot
        var h = HUDState()
        h.vesselName = v.name
        switch v.status {
        case .flying: h.status = "Flying"
        case .landed: h.status = "Landed"
        case .crashed: h.status = "Crashed"
        }
        h.utc = sim.time.description
        h.met = Self.formatDuration(sim.time - missionStart)
        h.warp = sim.warp < 1 ? String(format: "%.1f×", sim.warp) : "\(Int(sim.warp))×"
        h.paused = sim.paused
        if rateWindow.limited, rateWindow.real > 0 {
            h.effectiveWarp = Self.formatEffectiveWarp(rateWindow.simulated / rateWindow.real)
        }
        h.reference = v.reference.name
        h.cameraInfo = "\(camera.targetName) · \(camera.frame.rawValue)"

        // Geodetic altitude (the reference body's figure, WGS 84 on the
        // Earth), and its rate: the speed along the normal.
        h.altitude = v.altitude
        h.verticalSpeed = v.velocity.dot(v.reference.vertical(at: v.position,
                                                                orientation: snap.orientation(v.reference)))

        h.thrustAcceleration = v.thrustAcceleration
        let weight = v.reference.gravity(at: v.position, pole: snap.orientation(v.reference).pole).length
        h.thrustToWeight = weight > 0 ? v.thrustAcceleration / weight : 0
        h.nextStage = Self.nextStage(of: v)
        h.deltaV = v.mainDeltaV
        h.mass = v.mass
        // One row per tank name: a set of solid motors has a grain per motor
        // under the set's name.
        var rows: [(name: String, mass: Double, capacity: Double, active: Bool)] = []
        let active = v.activeStage
        for p in v.parts {
            for t in p.tanks {
                if let i = rows.firstIndex(where: { $0.name == t.name }) {
                    rows[i].mass += t.mass
                    rows[i].capacity += t.capacity
                } else {
                    rows.append((t.name, t.mass, t.capacity, p === active))
                }
            }
        }
        h.tanks = rows.enumerated().map {
            TankInfo(id: "\($0.offset)", name: $0.element.name,
                     fraction: $0.element.capacity > 0 ? $0.element.mass / $0.element.capacity : 0,
                     mass: $0.element.mass, inActiveStage: $0.element.active)
        }
        h.autopilot = v.autopilot?.rawValue
        h.program = v.flightProgram?.status
        h.programLabel = Self.programLabel(v)
        h.gimbal = Self.gimbalSummary(v)
        if let c = failureCapture, c.vessel === v {
            h.failurePrompt = "\(c.part) engine \(c.engines.count == 1 ? "1" : "1-\(c.engines.count)")?  (Esc cancels)"
        }
        h.failures = failureLines(v, sim: sim)
        h.events = sim.events.suffix(6).map {
            "\(Self.formatDuration($0.time - missionStart, tenths: true))  \($0.message)"
        }
        if h != hud { hud = h }
    }

    /// What Space does next: the parts of the lowest pending staging event,
    /// or the bottom part of an M0 stack ("–" when nothing would go), and
    /// whether the flight program refuses it now (the IU until T3); CM/SM
    /// separation takes two presses; once the CM's entry program is awake,
    /// the ELS step it backs up.
    static func nextStage(of v: Vessel) -> String {
        if let entry = ApolloMission.entryProgram(of: v), entry.phase != .dormant {
            let els = entry.els
            let step = els.apexCoverJettisoned == nil ? "apex cover + drogues"
                : els.droguesDeployed == nil ? "drogues"
                : els.mainsDeployed == nil ? "mains"
                : els.mainsReleased == nil ? "release mains" : nil
            guard let step else { return "–" }
            return "ELS backup: " + step + (v.altitude > elsBackupCeiling ? " (inhibited)" : "")
        }
        let events = v.parts.compactMap { p -> Int? in if case .event(let n) = p.staging { n } else { nil } }
        let group: [VesselPart]
        if let n = events.min() {
            group = v.parts.filter { $0.staging == .event(n) }
        } else if let bottom = v.parts.filter({ $0.staging == .bottomOfStack }).min(by: { $0.offset.x < $1.offset.x }) {
            group = [bottom]
        } else {
            return "–"
        }
        guard group.count < v.parts.count else { return "–" }
        let names = group.map(\.name).joined(separator: " + ")
        // The SCS's guard is not asked: asking arms it (its first press).
        if v.flightProgram is ApolloSCS, v.nextStagingEvent == 7 { return names + " (Space twice)" }
        guard let program = v.flightProgram, !program.allowsManualStaging(of: v) else { return names }
        return names + (program is SaturnIU ? " (inhibited until T3)" : " (inhibited)")
    }

    /// The vehicle panel's label for the flight program aboard `v`: "IU" for
    /// the Saturn's, "SCS" for the CSM's, "CM" once the SCS has handed the
    /// command module to its entry program, "ELS" for the landing system
    /// alone.
    static func programLabel(_ v: Vessel) -> String {
        switch v.flightProgram {
        case is SaturnIU: return "IU"
        case is CMEntryProgram: return "CM"
        case is EarthLandingSystem: return "ELS"
        case is ApolloSCS: return v.parts.contains { $0.name == "SM" } ? "SCS" : "CM"
        default: return "Program"
        }
    }

    /// "S-II engine 5 failed +00:05:28.6" for each failed engine aboard (its
    /// time from the IU's log, or the simulation's), then "S-II engine 5 at
    /// T3+167.0 s" for each failure scheduled on the IU and not yet due.
    private func failureLines(_ v: Vessel, sim: Simulation) -> [String] {
        let iu = v.flightProgram as? SaturnIU
        var lines: [String] = v.thrusters.filter(\.isFailed).map { e in
            let at = iu?.log.first { $0.event == "\(e.name) failed" }?.time
                ?? sim.events.last { $0.message == "\(v.name): \(e.name) failed" }?.time
            return "\(e.name) failed" + (at.map { " " + Self.formatDuration($0 - missionStart, tenths: true) } ?? "")
        }
        for f in iu?.failureSchedule ?? [] {
            guard let e = v.thrusters.first(where: { $0.name == f.engine }), !e.isFailed else { continue }
            switch f.time {
            case .range(let r): lines.append(String(format: "%@ at range %.1f s", f.engine, r))
            case let .timeBase(b, dt): lines.append(String(format: "%@ at %@+%.1f s", f.engine, b.description, dt))
            case .epoch(let t): lines.append("\(f.engine) at \(Self.formatDuration(t - missionStart, tenths: true))")
            }
        }
        return lines
    }

    /// "1.2° / 5.0°": the largest deflection of a firing gimballed engine and
    /// its range; nil when no gimballed engine fires.
    static func gimbalSummary(_ v: Vessel) -> String? {
        let firing = v.thrusters.filter { $0.isDelivering && !$0.gimbal.isEmpty }
        guard let range = firing.flatMap({ $0.gimbal.map(\.range.upperBound) }).max() else { return nil }
        let worst = firing.flatMap { $0.gimbal.map { abs($0.angle) } }.max() ?? 0
        return String(format: "%.1f° / %.1f°", worst * 180 / .pi, range * 180 / .pi)
    }

    /// An achieved warp to two significant figures ("0.37×", "4.2×", "38×",
    /// "380×"), so the HUD does not flicker with the frame time.
    static func formatEffectiveWarp(_ w: Double) -> String {
        guard w > 0 else { return "0×" }
        let magnitude = floor(log10(w))
        if magnitude < 1 { return String(format: "%.\(Int(1 - magnitude))f×", w) }
        let unit = pow(10, magnitude - 1)
        return "\(Int((w / unit).rounded() * unit))×"
    }

    /// "+00:02:15", or "+00:02:15.2" with `tenths` (rounded; the whole
    /// seconds of a running clock are truncated).
    static func formatDuration(_ seconds: Double, tenths: Bool = false) -> String {
        let sign = seconds < 0 ? "-" : "+"
        var s = tenths ? (abs(seconds) * 10).rounded() / 10 : abs(seconds)
        let d = Int(s / 86400); s -= Double(d) * 86400
        let hh = Int(s / 3600); s -= Double(hh) * 3600
        let mm = Int(s / 60); s -= Double(mm) * 60
        let ss = tenths ? String(format: "%04.1f", s) : String(format: "%02d", Int(s))
        if d > 0 { return String(format: "%@%dd %02d:%02d:%@", sign, d, hh, mm, ss) }
        return String(format: "%@%02d:%02d:%@", sign, hh, mm, ss)
    }
}
