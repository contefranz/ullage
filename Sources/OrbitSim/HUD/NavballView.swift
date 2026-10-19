import SwiftUI
import MetalKit
import OrbitCore

/// The navball in its own small, transparent Metal view over the scene. It
/// takes no mouse or keyboard input: those stay with the scene's view.
struct NavballView: NSViewRepresentable {
    let instruments: InstrumentModel

    final class Coordinator {
        var renderer: NavballRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NavballMTKView {
        let view = NavballMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        guard let device = view.device else { return view }
        let fresh = !NavballRenderer.hasShared
        guard let renderer = NavballRenderer.shared(device: device) else { return view }
        renderer.configure(view)
        let instruments = instruments
        renderer.source = { instruments.navball }
        context.coordinator.renderer = renderer
        // ORBITSIM_NAVBALL_GALLERY=<directory>: write the canned attitudes as
        // PNGs there, for reviewing the art without flying.
        if fresh, let dir = ProcessInfo.processInfo.environment["ORBITSIM_NAVBALL_GALLERY"], !dir.isEmpty {
            NavballArtwork.writeGallery(to: URL(fileURLWithPath: dir), renderer: renderer)
        }
        return view
    }

    func updateNSView(_ nsView: NavballMTKView, context: Context) {}
}

/// An MTKView that lets every event through to the views below it.
final class NavballMTKView: MTKView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.isOpaque = false
        layer?.backgroundColor = .clear
    }
}
