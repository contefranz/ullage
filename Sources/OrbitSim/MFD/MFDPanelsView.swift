import SwiftUI
import OrbitInstruments

/// The multi-function displays in their slots beside the instrument cluster
/// (`slots`, frames in this view's coordinates, by side; the layout gives one
/// or two). With one slot only the left display shows, and keys pressed with
/// either Shift drive it.
///
/// Keys: left Shift drives the left display and right Shift the right one
/// (Orbiter's scheme): Shift+F1 or Shift+Tab is SEL, Shift with the key left
/// of 1 is MNU, Shift+Esc is PWR, and Shift+letter presses a mode's button
/// or, on the select page, picks a mode.
struct MFDPanelsView: View {
    let model: AppModel
    let slots: [MFDSide: CGRect]

    var body: some View {
        MFDPanels(mfd: MFDModel.shared(for: model), slots: slots)
    }
}

private struct MFDPanels: View {
    @ObservedObject var mfd: MFDModel
    let slots: [MFDSide: CGRect]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach([MFDSide.left, .right], id: \.self) { side in
                if let r = slots[side] {
                    MFDPanelView(page: mfd.pages[side] ?? .off, side: side, size: r.size) { mfd.press($0, side: side) }
                        .equatable()
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
            }
        }
        .onAppear { mfd.visibleSides = Set(slots.keys) }
        .onChange(of: slots[.right] != nil) { mfd.visibleSides = Set(slots.keys) }
    }
}
