import Foundation
import OrbitCore

/// The controls under a display and its side buttons.
public enum MFDControl: Hashable, Sendable {
    /// Side button 0-5 down the left, 6-11 down the right.
    case button(Int)
    case power, select, menu
}

/// The two multi-function displays, Orbiter's way: each shows a mode, picked
/// on its select page (SEL), with its buttons' help on its menu page (MNU),
/// and can be switched off (PWR). Keys come with the side of the Shift key
/// that was held: left Shift drives the left display and right Shift the
/// right one.
///
/// - SEL: Shift+F1, or Shift+Tab for keyboards whose F-keys need fn.
/// - MNU: Shift and the key left of 1 (` on ANSI, § on ISO).
/// - PWR: Shift+Esc.
/// - Any other Shift+key: on the select page, the mode whose key it is; on
///   the mode's page or its menu page, the mode's button with that key.
///
/// The controller also keeps, per vessel, what the pages draw over time:
/// the ground track flown, the predicted one (refreshed at most once a
/// second of real time), and the entry trace.
public final class MFDController {
    public enum Screen: Hashable, Sendable {
        case mode, select, menu
    }

    /// One display's state.
    public struct Panel {
        public var power = true
        public var mode: MFDModeID
        public var screen = Screen.mode
        /// The modes shown so far, each with its settings.
        var modes: [MFDModeID: MFDMode] = [:]

        init(mode: MFDModeID) { self.mode = mode }

        mutating func instance(_ id: MFDModeID) -> MFDMode {
            if let m = modes[id] { return m }
            let m = id.make()
            modes[id] = m
            return m
        }
    }

    public static let selectKeys: Set<PhysicalKey> = [.f1, .tab]
    public static let menuKeys: Set<PhysicalKey> = [.grave, .isoSection]
    public static let powerKeys: Set<PhysicalKey> = [.escape]
    /// The modes on the select page, in button order.
    public static let modeOrder = MFDModeID.allCases

    private var panels: [MFDSide: Panel]
    public var environment: MFDEnvironment
    /// Zero of the mission clock, for the times the pages give.
    public var missionClockZero: Epoch?
    /// Shortest real time between two predictions of a vessel's ground track.
    public var predictionInterval = 1.0
    private var vesselData: [UUID: MFDVesselData] = [:]

    public init(left: MFDModeID = .surface, right: MFDModeID = .orbit, environment: MFDEnvironment = MFDEnvironment()) {
        panels = [.left: Panel(mode: left), .right: Panel(mode: right)]
        self.environment = environment
    }

    public func panel(_ side: MFDSide) -> Panel { panels[side]! }

    /// The instance of mode `id` on `side` (made if it has not been shown).
    public func mode(_ id: MFDModeID, on side: MFDSide) -> MFDMode { panels[side]!.instance(id) }

    // MARK: Keys and buttons

    /// Route a key pressed with Shift on `side`. Returns true when the key
    /// did something.
    @discardableResult
    public func handle(_ key: PhysicalKey, side: MFDSide, sim: Simulation?) -> Bool {
        if Self.powerKeys.contains(key) { return press(.power, side: side, sim: sim) }
        if Self.selectKeys.contains(key) { return press(.select, side: side, sim: sim) }
        if Self.menuKeys.contains(key) { return press(.menu, side: side, sim: sim) }
        var p = panels[side]!
        guard p.power else { return false }
        defer { panels[side] = p }
        switch p.screen {
        case .select:
            guard let id = MFDModeID.allCases.first(where: { $0.selectKey == key }) else { return false }
            p.mode = id
            p.screen = .mode
            return true
        case .mode, .menu:
            let taken = p.instance(p.mode).handle(key, context(sim))
            if taken { p.screen = .mode }
            return taken
        }
    }

    /// A click on a control of the display on `side`.
    @discardableResult
    public func press(_ control: MFDControl, side: MFDSide, sim: Simulation?) -> Bool {
        var p = panels[side]!
        defer { panels[side] = p }
        switch control {
        case .power:
            p.power.toggle()
            p.screen = .mode
            return true
        case .select:
            guard p.power else { return false }
            p.screen = p.screen == .select ? .mode : .select
            return true
        case .menu:
            guard p.power else { return false }
            p.screen = p.screen == .menu ? .mode : .menu
            return true
        case .button(let i):
            guard p.power else { return false }
            switch p.screen {
            case .select:
                guard Self.modeOrder.indices.contains(i) else { return false }
                p.mode = Self.modeOrder[i]
                p.screen = .mode
                return true
            case .mode, .menu:
                let mode = p.instance(p.mode)
                let c = context(sim)
                let buttons = mode.buttons(c)
                guard buttons.indices.contains(i), let b = buttons[i], b.active else { return false }
                let taken = mode.handle(b.key, c)
                if taken { p.screen = .mode }
                return taken
            }
        }
    }

    /// The burn a powered display shows on its DEORBIT page (the left one's
    /// first), for the navball's manoeuvre marker: its thrust direction (ICRF).
    public var deorbitBurnDirection: Vec3? {
        for side in [MFDSide.left, .right] {
            let p = panels[side]!
            if p.power, p.mode == .deorbit, let m = p.modes[.deorbit] as? DeorbitMFD, let plan = m.plan {
                return plan.burnDirection
            }
        }
        return nil
    }

    // MARK: Sampling

    /// The data kept for vessel `v`.
    public func data(for v: Vessel) -> MFDVesselData {
        if let d = vesselData[v.id] { return d }
        let d = MFDVesselData()
        vesselData[v.id] = d
        return d
    }

    /// Sample the focus vessel: record its ground track and entry trace, and
    /// predict its ground track again if `predictionInterval` of real time
    /// (`realTime`, s, any origin) has passed since the last prediction.
    /// Vessels that have left the simulation are forgotten.
    public func update(sim: Simulation, realTime: Double) {
        let ids = Set(sim.vessels.map(\.id))
        vesselData = vesselData.filter { ids.contains($0.key) }
        guard let v = sim.focus else { return }
        let snap = sim.snapshot
        let d = data(for: v)
        d.sample(v, snapshot: snap)
        if realTime - d.predictedAtRealTime >= predictionInterval || realTime < d.predictedAtRealTime {
            d.predict(v, snapshot: snap, warp: sim.paused ? 0 : sim.warp)
            d.predictedAtRealTime = realTime
        }
    }

    /// The context for the focus vessel; nil without one.
    public func context(_ sim: Simulation?) -> MFDContext? {
        guard let sim, let v = sim.focus else { return nil }
        return MFDContext(sim: sim, vessel: v, snapshot: sim.snapshot, missionClockZero: missionClockZero,
                          data: data(for: v), environment: environment)
    }

    // MARK: Pages

    /// What the display on `side` shows now.
    public func page(_ side: MFDSide, sim: Simulation?) -> MFDPage {
        var p = panels[side]!
        defer { panels[side] = p }
        guard p.power else { return .off }
        switch p.screen {
        case .select:
            return selectPage(current: p.mode)
        case .menu:
            let mode = p.instance(p.mode)
            return menuPage(mode, buttons: mode.buttons(context(sim)))
        case .mode:
            let mode = p.instance(p.mode)
            guard let c = context(sim) else {
                return MFDPage(title: p.mode.name.uppercased(), text: [MFDText(4, 11, "NO VESSEL", .warn)],
                               buttons: labels(mode.buttons(nil)))
            }
            var page = mode.page(c)
            page.buttons = labels(mode.buttons(c))
            return page
        }
    }

    func labels(_ buttons: [MFDButton?]) -> [MFDButtonLabel?] {
        buttons.prefix(12).map { $0.map { MFDButtonLabel($0.label, inactive: !$0.active) } }
    }

    /// The modes beside the left buttons, with their keys.
    func selectPage(current: MFDModeID) -> MFDPage {
        var page = MFDPage(title: "MODE SELECT")
        for (i, id) in Self.modeOrder.enumerated() {
            let row = MFDPage.buttonRow(i)
            page.add(4, row, id.name, id == current ? .own : .ownDim)
            page.add(35, row, "Shift-" + id.selectKey.rawValue.uppercased(), .referenceDim, alignment: .trailing)
        }
        page.add(4, 22, "SEL: back   PWR: off", .referenceDim)
        page.buttons = Self.modeOrder.map { MFDButtonLabel($0.label) }
        return page
    }

    /// The mode's buttons with their help and keys.
    func menuPage(_ mode: MFDMode, buttons: [MFDButton?]) -> MFDPage {
        var page = MFDPage(title: mode.id.name.uppercased() + " MENU")
        var row = 2
        for b in buttons.compactMap({ $0 }) {
            page.add(4, row, b.label, b.active ? .own : .ownDim)
            page.add(8, row, b.key.rawValue.uppercased(), .target)
            page.add(10, row, b.help, b.active ? .reference : .referenceDim)
            row += 1
        }
        if buttons.compactMap({ $0 }).isEmpty { page.add(4, row, "No buttons", .referenceDim) }
        page.add(4, 21, "Keys: Shift and the key", .referenceDim)
        page.add(4, 22, "MNU: back", .referenceDim)
        page.buttons = labels(buttons)
        return page
    }
}

// MARK: - Per-vessel data

/// What the displays keep for one vessel between refreshes.
public final class MFDVesselData {
    /// The ground track flown.
    public private(set) var track = GroundTrackRecorder()
    /// The ground track predicted from the last prediction's time on.
    public private(set) var predicted: [GroundTrack.Point] = []
    /// Orbits predicted beyond the time the prediction may go stale.
    public static let predictedOrbits = 3.0
    var predictedAtRealTime = -Double.infinity
    /// The vacuum entry interface (400,000 ft) ahead, from the same
    /// prediction; nil when the orbit does not come down through it.
    public private(set) var entryInterface: EntryInterface?

    /// The entry trace for the ENTRY page: inertial speed (m/s) and load
    /// factor (g), oldest first, from below 130 km while coasting down.
    public private(set) var entryTrace: [(speed: Double, g: Double)] = []
    /// When the load factor first reached 0.05 g on the way down (the EMS's
    /// 0.05 G light), and the highest since.
    public private(set) var pointZeroFiveG: Epoch?
    public private(set) var peakLoadFactor = 0.0

    /// The last sample: the state to fill a gap in the track from.
    private var last: Sample?

    private struct Sample {
        var state: Kepler.State
        var time: Epoch
        var orientation: BodyOrientation
        var body: ObjectIdentifier
        var mass: Double
        var coasting: Bool
    }

    public init() {}

    /// Longest time between track points: a longer gap (time warp) is
    /// filled from the last state when the vessel coasted through it.
    public static let trackGap = 45.0
    /// Height below which the entry trace is kept, m.
    public static let entryCeiling = 130_000.0

    func sample(_ v: Vessel, snapshot s: SystemSnapshot) {
        let o = s.orientation(v.reference)
        let coasting = v.landed == nil && v.thrustAcceleration < 1e-3 && v.dynamicPressure < 1
        let now = Sample(state: Kepler.State(position: v.position, velocity: v.velocity), time: s.time,
                         orientation: o, body: ObjectIdentifier(v.reference), mass: v.mass, coasting: coasting)
        if let l = last, l.coasting, now.coasting, l.body == now.body, abs(l.mass - now.mass) <= 1e-9 * now.mass,
           s.time - l.time > Self.trackGap, s.time - l.time < 3 * 86400 {
            // Coasted through a gap (time warp): fill it from the last state.
            let fill = GroundTrack.predict(from: l.state, around: v.reference, orientation: l.orientation, at: l.time,
                                           duration: s.time - l.time, step: 30)
            for p in fill.dropFirst().dropLast() { track.record(p) }
        }
        track.record(v, snapshot: s)
        last = now

        // The entry trace: coasting down through the air.
        if v.landed == nil, v.altitude < Self.entryCeiling, v.thrustAcceleration < 0.01 * 9.80665 {
            let g = v.loadFactor
            let descending = v.position.dot(v.velocity) < 0
            if pointZeroFiveG == nil, descending, g >= 0.05 { pointZeroFiveG = s.time }
            if pointZeroFiveG != nil {
                peakLoadFactor = max(peakLoadFactor, g)
                let speed = v.velocity.length
                if let l = entryTrace.last, abs(l.speed - speed) < 10, abs(l.g - g) < 0.05 {
                } else {
                    entryTrace.append((speed, g))
                    if entryTrace.count > 2000 { entryTrace.removeFirst(entryTrace.count - 2000) }
                }
            }
        } else if v.landed == nil, v.altitude > Self.entryCeiling + 20_000 {
            // Back in orbit (or a new flight): the next entry starts afresh.
            pointZeroFiveG = nil
            peakLoadFactor = 0
            entryTrace = []
        }
    }

    func predict(_ v: Vessel, snapshot s: SystemSnapshot, warp: Double) {
        guard v.landed == nil else {
            predicted = []
            entryInterface = nil
            return
        }
        // Below the interface and coming down, the vessel is past it (the
        // predictor would wait for it to climb through it and come back).
        let past = v.altitude < EntryInterface.standardHeight && v.position.dot(v.velocity) < 0
        entryInterface = v.dynamicPressure < 1 && !past ? EntryInterface.predict(v, snapshot: s) : nil
        let el = v.elements(snapshot: s)
        let period = el.specificEnergy < 0 ? 2 * Double.pi * (pow(el.semiMajorAxis, 3) / v.reference.gm).squareRoot()
            : 7200
        // Enough to stay ahead of the vessel until the next prediction at this warp.
        let stale = min(warp * 1.5, 20 * period)
        predicted = GroundTrack.predict(v, snapshot: s, duration: Self.predictedOrbits * period + stale,
                                        step: min(30, period / 120))
    }
}
