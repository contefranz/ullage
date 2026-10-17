import Foundation
import Combine
import OrbitCore

struct TankInfo: Identifiable, Equatable {
    var id: String
    var name: String
    var fraction: Double
    var mass: Double
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

    var altitude = 0.0
    var orbitalSpeed = 0.0
    var surfaceSpeed = 0.0
    var verticalSpeed = 0.0
    var mach = 0.0
    var dynamicPressure = 0.0
    var latitude = 0.0
    var longitude = 0.0

    var apoapsisAltitude: Double? = nil
    var periapsisAltitude = 0.0
    var inclination = 0.0
    var eccentricity = 0.0
    var period: Double? = nil
    var timeToApoapsis: Double? = nil
    var timeToPeriapsis: Double? = nil

    var throttle = 0.0
    var thrustAcceleration = 0.0
    var deltaV = 0.0
    var mass = 0.0
    var tanks: [TankInfo] = []
    var autopilot: String? = nil
    /// The flight program's HUD line (the Saturn's IU); nil when the vessel
    /// carries no program.
    var program: String? = nil
    /// Largest deflection of a firing gimballed engine and its range; nil when none fires.
    var gimbal: String? = nil
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
    private(set) var system: SolarSystem?
    private(set) var stars: [Star] = []
    private(set) var sim: Simulation?
    var camera = OrbitCamera()

    private var missionStart = Epoch(tdbSecondsPastJ2000: 0)
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
        missionStart = sim.time
        if let focus = sim.focus {
            camera.target = .vessel(focus.id)
            camera.distance = max(focus.boundingRadius * 3, 30)
        }
        camera.update(sim: sim)
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
        // The mission clock starts at liftoff, logged at the start of the step
        // that left the ground: at time warp a frame holds many steps, and the
        // vehicle may even be down again by its end.
        if wasLanded, let f = sim.focus,
           let liftoff = sim.events.last(where: { $0.message == "\(f.name): liftoff" && $0.time >= frameStart }) {
            missionStart = liftoff.time
        }

        let mouse = input.takeMouse()
        if mouse.dx != 0 || mouse.dy != 0 { camera.orbit(dx: mouse.dx, dy: mouse.dy) }
        if mouse.scroll != 0 {
            camera.zoom(mouse.scroll, minimum: OrbitCamera.minimumDistance(for: camera.target, sim: sim))
        }
        camera.update(sim: sim)

        hudClock += dt
        if hudClock > 0.1 {
            hudClock = 0
            refreshHUD()
            rateWindow = RateWindow(warp: sim.warp)
        }
    }

    private func handleKeys(sim: Simulation, dt: Double) {
        for key in input.takePressed() {
            switch key {
            case "h": showHelp.toggle()
            case "m": showOrbit.toggle()
            case "p": sim.paused.toggle()
            case ".": setWarp(step: +1, sim: sim)
            case ",": setWarp(step: -1, sim: sim)
            case "/": sim.warp = 1
            case "c": cycleCameraTarget(sim: sim)
            case "v": cycleCameraFrame()
            case "[": cycleFocus(sim: sim, by: -1)
            case "]": cycleFocus(sim: sim, by: +1)
            default: break
            }
            guard let v = sim.focus, v.status != .crashed else { continue }
            switch key {
            case "space": sim.stage(v)
            case "z": v.mainThrottle = 1
            case "x": v.mainThrottle = 0
            case "t": v.autopilot = v.autopilot == .killRotation ? nil : .killRotation
            case "1": v.autopilot = .prograde
            case "2": v.autopilot = .retrograde
            case "3": v.autopilot = .normal
            case "4": v.autopilot = .antinormal
            case "5": v.autopilot = .radialOut
            case "6": v.autopilot = .radialIn
            case "7": v.autopilot = .horizonLevel
            case "8": v.autopilot = .attitudeHold
            case "0": v.autopilot = nil
            default: break
            }
        }

        guard let v = sim.focus else { return }
        if input.isHeld("=") { v.mainThrottle = min(1, v.mainThrottle + 0.5 * dt) }
        if input.isHeld("-") { v.mainThrottle = max(0, v.mainThrottle - 0.5 * dt) }

        func axis(_ plus: String, _ minus: String) -> Double {
            (input.isHeld(plus) ? 1 : 0) - (input.isHeld(minus) ? 1 : 0)
        }
        v.rotationInput = RotationCommand(roll: axis("e", "q"), pitch: axis("s", "w"), yaw: axis("d", "a"))
        v.translationInput = Vec3(axis("u", "o"), axis("l", "j"), axis("k", "i"))
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

        h.altitude = v.altitude
        h.orbitalSpeed = v.velocity.length
        h.surfaceSpeed = v.surfaceVelocity(snapshot: snap).length   // over the ground; airspeed has the wind
        h.verticalSpeed = v.velocity.dot(v.position.normalized)
        h.mach = v.mach
        h.dynamicPressure = v.dynamicPressure
        let ll = v.latitudeLongitude(snapshot: snap)
        h.latitude = ll.lat * 180 / .pi
        h.longitude = ll.lon * 180 / .pi

        if v.landed == nil {
            let el = v.elements(snapshot: snap)
            let radius = v.reference.radius
            h.apoapsisAltitude = el.isBound ? el.apoapsisRadius - radius : nil
            h.periapsisAltitude = el.periapsisRadius - radius
            h.inclination = el.inclination * 180 / .pi
            h.eccentricity = el.eccentricity
            h.period = el.isBound ? el.period : nil
            h.timeToApoapsis = el.isBound ? el.timeToApoapsis : nil
            h.timeToPeriapsis = el.timeToPeriapsis
        }

        h.throttle = v.mainThrottle
        h.thrustAcceleration = v.thrustAcceleration
        h.deltaV = v.mainDeltaV
        h.mass = v.mass
        h.tanks = v.tanks.enumerated().map {
            TankInfo(id: "\($0.offset)", name: $0.element.name, fraction: $0.element.fraction, mass: $0.element.mass)
        }
        h.autopilot = v.autopilot?.rawValue
        h.program = v.flightProgram?.status
        h.gimbal = Self.gimbalSummary(v)
        h.events = sim.events.suffix(6).map { "\(Self.formatDuration($0.time - missionStart))  \($0.message)" }
        if h != hud { hud = h }
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

    static func formatDuration(_ seconds: Double) -> String {
        let sign = seconds < 0 ? "-" : "+"
        var s = abs(seconds)
        let d = Int(s / 86400); s -= Double(d) * 86400
        let hh = Int(s / 3600); s -= Double(hh) * 3600
        let mm = Int(s / 60); s -= Double(mm) * 60
        if d > 0 { return String(format: "%@%dd %02d:%02d:%02d", sign, d, hh, mm, Int(s)) }
        return String(format: "%@%02d:%02d:%02d", sign, hh, mm, Int(s))
    }
}
