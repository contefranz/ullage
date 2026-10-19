import SwiftUI
import OrbitInstruments

/// The multi-function displays in their slots beside the instrument cluster
/// (`slots`, frames in this view's coordinates, by side; the layout gives one
/// or two). A stub until the MFDs (track B2) take this file over: the left
/// slot shows the surface panel and the right one the orbit panel, both in
/// the left one when it is alone.
struct MFDPanelsView: View {
    @ObservedObject var model: AppModel
    let slots: [MFDSide: CGRect]

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let left = slots[.left] {
                VStack(alignment: .leading, spacing: 8) {
                    if slots[.right] == nil { OrbitPanel(hud: model.hud) }
                    SurfacePanel(hud: model.hud)
                }
                .frame(width: left.width, height: left.height, alignment: .bottomLeading)
                .offset(x: left.minX, y: left.minY)
            }
            if let right = slots[.right] {
                OrbitPanel(hud: model.hud)
                    .frame(width: right.width, height: right.height, alignment: .bottomTrailing)
                    .offset(x: right.minX, y: right.minY)
            }
        }
    }
}

/// Altitude, speeds, Mach and dynamic pressure, latitude and longitude.
struct SurfacePanel: View {
    let hud: HUDState

    var body: some View {
        HUDPanel {
            HUDRow("Altitude", HUDRow.distance(hud.altitude))
            HUDRow("Orbital v", String(format: "%.1f m/s", hud.orbitalSpeed))
            HUDRow("Surface v", String(format: "%.1f m/s", hud.surfaceSpeed))
            HUDRow("Vertical v", String(format: "%+.1f m/s", hud.verticalSpeed))
            HUDRow("Mach / q", String(format: "%.2f / %.1f kPa", hud.mach, hud.dynamicPressure / 1000))
            HUDRow("Lat / Lon", String(format: "%.3f° / %.3f°", hud.latitude, hud.longitude))
        }
    }
}

/// The osculating orbit: apsides, inclination, eccentricity, period and the
/// times to the apsides.
struct OrbitPanel: View {
    let hud: HUDState

    var body: some View {
        HUDPanel {
            HUDRow("ApA", hud.apoapsisAltitude.map(HUDRow.distance) ?? "escape")
            HUDRow("PeA", HUDRow.distance(hud.periapsisAltitude))
            HUDRow("Inc", String(format: "%.2f°", hud.inclination))
            HUDRow("Ecc", String(format: "%.4f", hud.eccentricity))
            HUDRow("Period", hud.period.map { AppModel.formatDuration($0) } ?? "–")
            HUDRow("T→Ap / Pe", "\(hud.timeToApoapsis.map { AppModel.formatDuration($0) } ?? "–") / \(hud.timeToPeriapsis.map { AppModel.formatDuration($0) } ?? "–")")
        }
    }
}
