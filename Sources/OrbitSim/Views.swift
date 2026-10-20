import SwiftUI
import MetalKit
import OrbitCore
import OrbitInstruments

/// Hosts the Metal view.
struct MetalView: NSViewRepresentable {
    let model: AppModel

    final class Coordinator {
        var renderer: Renderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> GameView {
        let view = GameView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.input = model.input
        if let renderer = Renderer(view: view) {
            renderer.model = model
            renderer.setStars(model.stars)
            view.delegate = renderer
            context.coordinator.renderer = renderer
        } else {
            model.reportError("Metal renderer could not be created (see the Xcode console for the shader error).")
        }
        return view
    }

    func updateNSView(_ nsView: GameView, context: Context) {}
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            MetalView(model: model)
            if let error = model.loadError {
                Text(error).foregroundStyle(.red).padding().background(.black.opacity(0.7))
            } else {
                // Only the MFDs take clicks (their buttons); elsewhere the
                // mouse reaches the Metal view (camera).
                FlightHUD(model: model, instruments: model.instruments)
                if model.showHelp {
                    HelpView(scenario: model.scenario)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color.black)
    }
}

// MARK: - HUD layout

/// Where the HUD's parts sit in a window of `size`, so that none overlaps
/// another down to the minimum 900 × 600:
/// - the top bar across the top;
/// - the event log at the top left, the vehicle panel at the top right;
/// - the instrument cluster at the bottom, centred between two MFD slots
///   when both fit beside it (with room left for the vehicle panel above
///   the right one), otherwise at the right with one slot at its left.
struct HUDLayout {
    static let pad: CGFloat = 12
    static let topBarHeight: CGFloat = 40
    static let logHeight: CGFloat = 112
    static let vehicleWidth: CGFloat = 340
    static let slotSize: ClosedRange<CGFloat> = 200...300
    /// Below this the vehicle panel drops its tank bars (`VehiclePanel`).
    static let vehicleMinimum: CGFloat = 240

    let topBar: CGRect
    let ballSize: CGFloat
    let cluster: CGRect
    let log: CGRect
    let vehicle: CGRect
    let mfds: [MFDSide: CGRect]

    init(size: CGSize) {
        let w = size.width, h = size.height, pad = Self.pad
        topBar = CGRect(x: 0, y: 0, width: w, height: Self.topBarHeight)
        let top = topBar.maxY + pad
        ballSize = h >= 800 ? 220 : 180
        let cs = InstrumentCluster.Layout(ball: ballSize).size
        let clusterTop = h - pad - cs.height
        let vehicleWidth = min(Self.vehicleWidth, w / 2 - 2 * pad)
        let vehicleX = w - pad - vehicleWidth
        let slotRoom = h - top - Self.logHeight - 2 * pad

        // Two slots, the cluster centred.
        let side = (w - cs.width) / 2 - 2 * pad
        let two = min(Self.slotSize.upperBound, side, slotRoom)
        let centred = CGRect(x: (w - cs.width) / 2, y: clusterTop, width: cs.width, height: cs.height)
        var vehicleBottom = h - 2 * pad - two
        if vehicleX < centred.maxX { vehicleBottom = min(vehicleBottom, clusterTop - pad) }
        if two >= Self.slotSize.lowerBound, vehicleBottom - top >= Self.vehicleMinimum {
            cluster = centred
            mfds = [.left: CGRect(x: pad, y: h - pad - two, width: two, height: two),
                    .right: CGRect(x: w - pad - two, y: h - pad - two, width: two, height: two)]
            vehicle = CGRect(x: vehicleX, y: top, width: vehicleWidth, height: vehicleBottom - top)
            log = CGRect(x: pad, y: top, width: min(400, side), height: Self.logHeight)
            return
        }
        // One slot, the cluster at the right.
        cluster = CGRect(x: w - pad - cs.width, y: clusterTop, width: cs.width, height: cs.height)
        let left = w - cs.width - 3 * pad
        let one = min(Self.slotSize.upperBound, left, slotRoom)
        mfds = one >= Self.slotSize.lowerBound ? [.left: CGRect(x: pad, y: h - pad - one, width: one, height: one)] : [:]
        vehicle = CGRect(x: vehicleX, y: top, width: vehicleWidth, height: max(0, clusterTop - pad - top))
        log = CGRect(x: pad, y: top, width: min(400, left, vehicleX - 2 * pad), height: Self.logHeight)
    }
}

/// The HUD for flying: top bar, event log, vehicle panel, MFDs and the
/// instrument cluster, as F2 shows them.
struct FlightHUD: View {
    @ObservedObject var model: AppModel
    @ObservedObject var instruments: InstrumentModel

    var body: some View {
        GeometryReader { geo in
            let l = HUDLayout(size: geo.size)
            ZStack(alignment: .topLeading) {
                if instruments.visibility == .full {
                    Group {
                        TopBar(hud: model.hud)
                            .frame(width: l.topBar.width, height: l.topBar.height)
                        EventLog(events: model.hud.events)
                            .frame(width: l.log.width, height: l.log.height, alignment: .topLeading)
                            .offset(x: l.log.minX, y: l.log.minY)
                        VehiclePanel(hud: model.hud)
                            .frame(width: l.vehicle.width, height: l.vehicle.height, alignment: .topTrailing)
                            .offset(x: l.vehicle.minX, y: l.vehicle.minY)
                    }
                    .allowsHitTesting(false)
                    MFDPanelsView(model: model, slots: l.mfds)
                }
                if instruments.visibility != .off {
                    InstrumentCluster(instruments: instruments, ball: l.ballSize)
                        .offset(x: l.cluster.minX, y: l.cluster.minY)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(HUDRow.color)
    }
}

// MARK: - Panels

/// A translucent HUD panel.
struct HUDPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) { content() }
            .padding(8)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// A label and its value.
struct HUDRow: View {
    static let color = Color(red: 0.6, green: 1.0, blue: 0.7)
    let label: String
    let value: String
    var bold = false

    init(_ label: String, _ value: String, bold: Bool = false) {
        self.label = label
        self.value = value
        self.bold = bold
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).frame(width: 90, alignment: .leading).opacity(bold ? 1 : 0.75)
            Text(value).fontWeight(bold ? .bold : .regular).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func distance(_ m: Double) -> String {
        abs(m) >= 1_000_000 ? String(format: "%.1f km", m / 1000)
            : abs(m) >= 10_000 ? String(format: "%.2f km", m / 1000)
            : String(format: "%.1f m", m)
    }
}

/// Vessel and clocks at the left, the altitude in the middle, warp,
/// reference body and camera at the right.
struct TopBar: View {
    let hud: HUDState

    var body: some View {
        ZStack {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(hud.vesselName)  \(hud.status)").fontWeight(.bold)
                    Text("MET \(hud.met)   \(hud.utc)").font(.system(size: 10, design: .monospaced)).opacity(0.8)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Warp \(hud.warp)" + (hud.effectiveWarp.map { " (limited: \($0))" } ?? "")
                         + (hud.paused ? "  PAUSED" : ""))
                        .fontWeight(hud.paused ? .bold : .regular)
                    Text("\(hud.reference) · \(hud.cameraInfo)").font(.system(size: 10, design: .monospaced))
                        .opacity(0.8)
                }
            }
            HStack(spacing: 6) {
                Text("ALT " + HUDRow.distance(hud.altitude)).font(.system(size: 16, weight: .bold, design: .monospaced))
                Text((hud.verticalSpeed >= 0 ? "▲" : "▼") + String(format: "%.0f m/s", abs(hud.verticalSpeed)))
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.45))
        .lineLimit(1)
    }
}

/// The last events, oldest first.
struct EventLog: View {
    let events: [String]

    var body: some View {
        if !events.isEmpty {
            HUDPanel {
                ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                    Text(e).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                }
            }
        }
    }
}

/// The vehicle: flight program, the next Space group, Δv, mass, TWR, gimbal,
/// failures and tanks. When its slot is short it keeps the active stage's
/// tanks only, then none.
struct VehiclePanel: View {
    let hud: HUDState

    var body: some View {
        ViewThatFits(in: .vertical) {
            panel(tanks: hud.tanks)
            panel(tanks: hud.tanks.filter(\.inActiveStage))
            panel(tanks: [])
        }
    }

    func panel(tanks: [TankInfo]) -> some View {
        HUDPanel {
            if let p = hud.program { HUDRow(hud.programLabel, p) }
            HUDRow("Space", hud.nextStage)
            HUDRow("Stage Δv", String(format: "%.0f m/s", hud.deltaV))
            HUDRow("Mass", String(format: "%.1f t", hud.mass / 1000))
            HUDRow("TWR", String(format: "%.2f  (%.2f g)", hud.thrustToWeight, hud.thrustAcceleration / 9.80665))
            if let g = hud.gimbal { HUDRow("Gimbal", g) }
            if let f = hud.failurePrompt { HUDRow("Fail engine", f, bold: true) }
            ForEach(Array(hud.failures.enumerated()), id: \.offset) { i, f in
                HUDRow(i == 0 ? "Engine out" : "", f)
            }
            ForEach(tanks) { tank in
                HStack(spacing: 6) {
                    Text(tank.name).frame(width: 120, alignment: .leading).lineLimit(1)
                    ProgressView(value: max(0, min(1, tank.fraction)))
                        .frame(width: 70)
                    Text(String(format: "%.0f kg", tank.mass)).frame(width: 90, alignment: .trailing)
                }
                .font(.system(size: 11, design: .monospaced))
            }
        }
        .frame(width: HUDLayout.vehicleWidth, alignment: .leading)
    }
}

/// The keys, under the scenario's name and summary (what to do in it).
struct HelpView: View {
    var scenario: Scenario?

    static let lines: [(String, String)] = [
        ("Z / X", "full throttle / cut (CSM: Z lights the SPS, the ΔV counter cuts it off)"),
        ("= / -", "throttle up / down (hold)"),
        ("W S A D Q E", "pitch down/up, yaw left/right, roll left/right"),
        ("I K J L U O", "translate up/down/left/right/fwd/back"),
        ("Space", "next staging event (Saturn V: after the S-IC cutoff; CM/SM: press twice within 2 s)"),
        ("", "CM after the SM has gone: ELS backup (apex cover and drogues, mains), below 40,000 ft"),
        ("T", "kill rotation   1-7 prograde, retro, normal, anti-normal, radial±, level   0 off"),
        ("8", "hold attitude (Saturn V: hands the attitude back to the IU)"),
        ("9", "entry mode: manual (Q/E roll the lift) / bank hold / rolling"),
        ("F, then 1-5", "fail engine n of the stage now firing (S-IC, S-II: 5 is the centre)   Esc cancels"),
        (". , /", "time warp up / down / reset     P pause"),
        ("N", "navball speed: orbit / surface (automatic at 50 km up, 40 km down until then)"),
        ("F2 or `", "HUD: full / instruments only / off"),
        ("L/R Shift + F1, Tab", "left/right MFD: mode select   Shift + ` menu   Shift + Esc power"),
        ("L/R Shift + key", "MFD button (or click it)"),
        ("Mouse drag / scroll", "orbit / zoom camera"),
        ("C / V", "camera target / camera frame"),
        ("[ ]", "switch vessel     M orbit line     H this help"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let scenario {
                Text(scenario.name).font(.system(size: 13, weight: .bold, design: .monospaced))
                Text(scenario.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(0.85)
                    .padding(.bottom, 6)
            }
            Text("Controls").font(.system(size: 13, weight: .bold, design: .monospaced))
            ForEach(Self.lines.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Self.lines[i].0).frame(width: 160, alignment: .leading).fontWeight(.semibold)
                    Text(Self.lines[i].1)
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.white)
        .frame(maxWidth: 820, alignment: .leading)
        .padding(14)
        .background(Color.black.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
