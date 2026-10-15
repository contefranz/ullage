import SwiftUI
import MetalKit
import OrbitCore

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
                HUDView(hud: model.hud)
                    .allowsHitTesting(false)
                if model.showHelp {
                    HelpView()
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color.black)
    }
}

// MARK: - HUD

struct HUDView: View {
    let hud: HUDState

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                panel {
                    row(hud.vesselName, hud.status, bold: true)
                    row("UTC", hud.utc)
                    row("MET", hud.met)
                    row("Warp", hud.warp + (hud.paused ? "  PAUSED" : "") + (hud.warpLimited ? "  (limited)" : ""))
                    row("Ref", hud.reference)
                    row("Cam", hud.cameraInfo)
                }
                Spacer()
                panel {
                    row("Throttle", String(format: "%3.0f %%", hud.throttle * 100))
                    row("Thrust acc", String(format: "%.2f g", hud.thrustAcceleration / 9.80665))
                    row("Stage Δv", String(format: "%.0f m/s", hud.deltaV))
                    row("Mass", String(format: "%.1f t", hud.mass / 1000))
                    row("Autopilot", hud.autopilot ?? "off")
                    ForEach(hud.tanks) { tank in
                        HStack(spacing: 6) {
                            Text(tank.name).frame(width: 110, alignment: .leading)
                            ProgressView(value: max(0, min(1, tank.fraction)))
                                .frame(width: 70)
                            Text(String(format: "%.0f kg", tank.mass)).frame(width: 70, alignment: .trailing)
                        }
                    }
                }
            }
            Spacer()
            HStack(alignment: .bottom) {
                panel {
                    row("Altitude", Self.distance(hud.altitude))
                    row("Orbital v", String(format: "%.1f m/s", hud.orbitalSpeed))
                    row("Surface v", String(format: "%.1f m/s", hud.surfaceSpeed))
                    row("Vertical v", String(format: "%+.1f m/s", hud.verticalSpeed))
                    row("Mach / q", String(format: "%.2f / %.1f kPa", hud.mach, hud.dynamicPressure / 1000))
                    row("Lat / Lon", String(format: "%.3f° / %.3f°", hud.latitude, hud.longitude))
                }
                panel {
                    row("ApA", hud.apoapsisAltitude.map(Self.distance) ?? "escape")
                    row("PeA", Self.distance(hud.periapsisAltitude))
                    row("Inc", String(format: "%.2f°", hud.inclination))
                    row("Ecc", String(format: "%.4f", hud.eccentricity))
                    row("Period", hud.period.map { AppModel.formatDuration($0) } ?? "–")
                    row("T→Ap / Pe", "\(hud.timeToApoapsis.map { AppModel.formatDuration($0) } ?? "–") / \(hud.timeToPeriapsis.map { AppModel.formatDuration($0) } ?? "–")")
                }
                Spacer()
                panel {
                    ForEach(Array(hud.events.enumerated()), id: \.offset) { _, e in
                        Text(e).frame(maxWidth: 380, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Color(red: 0.6, green: 1.0, blue: 0.7))
    }

    @ViewBuilder
    func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) { content() }
            .padding(8)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    func row(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 90, alignment: .leading).opacity(bold ? 1 : 0.75)
            Text(value).fontWeight(bold ? .bold : .regular)
        }
    }

    static func distance(_ m: Double) -> String {
        abs(m) >= 1_000_000 ? String(format: "%.1f km", m / 1000)
            : abs(m) >= 10_000 ? String(format: "%.2f km", m / 1000)
            : String(format: "%.1f m", m)
    }
}

struct HelpView: View {
    let lines: [(String, String)] = [
        ("Z / X", "full throttle / cut"),
        ("= / -", "throttle up / down (hold)"),
        ("W S A D Q E", "pitch down/up, yaw left/right, roll left/right"),
        ("I K J L U O", "translate up/down/left/right/fwd/back"),
        ("Space", "jettison bottom stage"),
        ("T", "kill rotation   1-7 prograde, retro, normal, anti-normal, radial±, level   0 off"),
        (". , /", "time warp up / down / reset     P pause"),
        ("Mouse drag / scroll", "orbit / zoom camera"),
        ("C / V", "camera target / camera frame"),
        ("[ ]", "switch vessel     M orbit line     H this help"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Controls").font(.system(size: 13, weight: .bold, design: .monospaced))
            ForEach(lines.indices, id: \.self) { i in
                HStack(spacing: 10) {
                    Text(lines[i].0).frame(width: 150, alignment: .leading).fontWeight(.semibold)
                    Text(lines[i].1)
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.white)
        .padding(14)
        .background(Color.black.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
