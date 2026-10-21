import Foundation
import Metal
import MetalKit
import QuartzCore
import OrbitScene

/// What a window's renderer draws: something that advances the world by the
/// real time between frames and then describes it.
@MainActor
public protocol SceneSource: AnyObject {
    /// Advances by `dt` real seconds (the app: its keys, the simulation and
    /// the camera).
    func tick(dt: Double)
    /// This frame's scene for a drawable of `viewport`, nil when there is
    /// nothing to draw.
    func scene(viewport: RenderScene.Viewport, realTime: Double) -> RenderScene?
    /// The settings to render with (the debug view of F9, the timings of F10).
    var renderSettings: RenderSettings { get }
    /// Whether a snapshot was asked for (F12) since the last frame; asking clears it.
    func takeSnapshotRequest() -> Bool
    /// The latest finished frame's GPU times, after each frame.
    func didRender(_ report: FrameReport)
    /// Where a snapshot was written, or why it was not.
    func didSnapshot(_ result: Result<URL, Error>)
}

extension SceneSource {
    public var renderSettings: RenderSettings { RenderSettings() }
    public func takeSnapshotRequest() -> Bool { false }
    public func didRender(_ report: FrameReport) {}
    public func didSnapshot(_ result: Result<URL, Error>) {}
}

/// The MTKView's delegate: each frame it ticks the source, takes its scene
/// and has the `SceneRenderer` draw it into the view's drawable. The view
/// keeps one sample and no depth; the renderer owns its targets.
@MainActor
public final class ViewRenderer: NSObject, MTKViewDelegate {
    public let renderer: SceneRenderer
    public weak var source: SceneSource?
    private var lastTime = CACurrentMediaTime()

    public init(view: MTKView, renderer: SceneRenderer) {
        self.renderer = renderer
        super.init()
        view.device = renderer.device
        view.colorPixelFormat = renderer.outputFormat
        view.depthStencilPixelFormat = .invalid
        view.sampleCount = 1
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
    }

    public nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MTKView calls its delegate on the main thread.
    public nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(in: view) }
    }

    private func render(in view: MTKView) {
        let now = CACurrentMediaTime()
        // The real interval, uncapped: the simulation caps what it makes up
        // for and reports the shortfall as limited warp.
        let dt = now - lastTime
        lastTime = now
        guard let source else { return }
        source.tick(dt: dt)
        let size = view.drawableSize
        let viewport = RenderScene.Viewport(width: Double(size.width), height: Double(size.height),
                                            pointScale: Double(view.window?.backingScaleFactor ?? 2))
        guard let scene = source.scene(viewport: viewport, realTime: now),
              let drawable = view.currentDrawable else { return }
        renderer.settings = source.renderSettings
        renderer.profiling = renderer.settings.debug.showPassTimings
        renderer.render(scene, to: drawable.texture, present: drawable)
        if let report = renderer.lastReport { source.didRender(report) }
        if source.takeSnapshotRequest() {
            source.didSnapshot(Result { try AppSnapshot.write(scene, renderer: renderer) })
        }
    }
}
