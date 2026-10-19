import Foundation
import Combine
import OrbitCore
import OrbitInstruments

/// The two multi-function displays of an `AppModel`: an `MFDController` fed
/// with the keys pressed with Shift (`InputState.takeMFDKeys`) and the
/// buttons clicked, sampling the simulation four times a second for the
/// pages it publishes (the MAP's predicted track no more than once a second,
/// `MFDController.predictionInterval`).
///
/// It lives as long as its app model, not as long as the panels' view, so
/// the displays keep their modes and tracks while F2 hides the HUD, and
/// keys pressed meanwhile still act. It runs on its own timer between the
/// frames (both on the main thread), so it needs nothing from `AppModel`
/// beyond what it already exposes.
@MainActor
final class MFDModel: ObservableObject {
    @Published private(set) var pages: [MFDSide: MFDPage] = [.left: .off, .right: .off]

    /// The sides with a slot on screen; keys for a hidden display go to the
    /// left one.
    var visibleSides: Set<MFDSide> = [.left, .right]

    private weak var app: AppModel?
    private(set) var controller: MFDController
    private var timer: Timer?
    /// The simulation sampled last, and its time when first seen (the
    /// mission clock's zero until liftoff, as the HUD's MET).
    private weak var sim: Simulation?
    private var simStart: Epoch?
    private var lastRefresh = -Double.infinity

    /// Seconds between page refreshes, and between key polls.
    static let refreshInterval = 0.25
    static let pollInterval = 1.0 / 30

    private static var models: [ObjectIdentifier: MFDModel] = [:]

    /// The displays of `app`, made on first use.
    static func shared(for app: AppModel) -> MFDModel {
        if let m = models[ObjectIdentifier(app)] { return m }
        let m = MFDModel(app: app)
        models[ObjectIdentifier(app)] = m
        return m
    }

    static func environment() -> MFDEnvironment {
        let deg = Double.pi / 180
        let pad = VesselLibrary.lc39A
        return MFDEnvironment(coastlines: Coastlines.earth,
                              sites: [MFDSite("LC-39A", latitude: pad.latitude * deg, longitude: pad.longitude * deg)])
    }

    private init(app: AppModel) {
        self.app = app
        controller = MFDController(left: .surface, right: .orbit, environment: Self.environment())
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    /// A click on a display's control.
    func press(_ control: MFDControl, side: MFDSide) {
        controller.press(control, side: route(side), sim: currentSim())
        refresh()
    }

    private func route(_ side: MFDSide) -> MFDSide { visibleSides.contains(side) ? side : .left }

    /// The app's simulation; a new one (a scenario loaded) starts the
    /// displays afresh on the modes they showed.
    private func currentSim() -> Simulation? {
        guard let s = app?.sim else { return nil }
        if s !== sim {
            if sim != nil {
                let old = controller
                controller = MFDController(left: old.panel(.left).mode, right: old.panel(.right).mode,
                                           environment: old.environment)
            }
            sim = s
            simStart = s.time
        }
        return s
    }

    private func poll() {
        guard let app else {
            timer?.invalidate()
            return
        }
        let sim = currentSim()
        var acted = false
        for (side, key) in app.input.takeMFDKeys() {
            acted = controller.handle(key, side: route(side), sim: sim) || acted
        }
        let now = ProcessInfo.processInfo.systemUptime
        if acted || now - lastRefresh >= Self.refreshInterval { refresh() }
    }

    private func refresh() {
        lastRefresh = ProcessInfo.processInfo.systemUptime
        let sim = currentSim()
        if let sim {
            controller.missionClockZero = missionClockZero(sim)
            controller.update(sim: sim, realTime: lastRefresh)
        }
        let new: [MFDSide: MFDPage] = [.left: controller.page(.left, sim: sim), .right: controller.page(.right, sim: sim)]
        if new != pages { pages = new }
    }

    /// The HUD's MET zero: the scenario's, else liftoff, else the time the
    /// scenario was loaded.
    private func missionClockZero(_ sim: Simulation) -> Epoch? {
        if let zero = app?.scenario?.missionClockZero { return zero }
        if let f = sim.focus, let liftoff = sim.events.last(where: { $0.message == "\(f.name): liftoff" }) {
            return liftoff.time
        }
        return simStart
    }
}
