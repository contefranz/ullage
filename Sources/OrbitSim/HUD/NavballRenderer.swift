import Foundation
import Metal
import MetalKit
import simd
import OrbitCore

/// Draws the navball: the textured ball and its bezel, then the markers,
/// the fixed waterline and pointers on the bezel for prograde, the
/// command, the target and the manoeuvre when they are behind the ball.
/// `encode(into:viewport:navball:)` draws into any render pass, so the scene
/// renderer can later take the ball into an overlay pass unchanged.
@MainActor
final class NavballRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    /// What to draw, read every frame.
    var source: (() -> Navball?)?

    private let pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb
    private let sampleCount: Int
    private var ballPipeline: MTLRenderPipelineState!
    private var markerPipeline: MTLRenderPipelineState!
    private var sampler: MTLSamplerState!
    private var art: MTLTexture!
    private var atlas: MTLTexture!

    /// Ball and bezel radii in the viewport's NDC: the markers' half-size
    /// fits between the bezel and the viewport's edge.
    nonisolated static let ballRadius: Float = 0.80
    nonisolated static let bezelRadius: Float = 0.92
    nonisolated static let markerSize: Float = 0.17
    nonisolated static let waterlineSize: Float = 0.30
    nonisolated static let pointerSize: Float = 0.085
    /// Markers fade out over the last 5° before the limb.
    nonisolated static let fadeWidth = sin(5 * Double.pi / 180)

    /// One renderer for the app's navball views: the art is drawn once, not
    /// each time the cluster is rebuilt (F2, a resize).
    private static var shared: NavballRenderer?

    static var hasShared: Bool { shared != nil }

    static func shared(device: MTLDevice) -> NavballRenderer? {
        if let r = shared, r.device === device { return r }
        shared = NavballRenderer(device: device)
        return shared
    }

    init?(device: MTLDevice, sampleCount: Int = 4) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.sampleCount = sampleCount
        super.init()
        do {
            try build()
        } catch {
            NSLog("OrbitSim: navball pipeline creation failed: \(error)")
            return nil
        }
    }

    /// Set `view` up for the navball: transparent, multisampled, drawing at
    /// 60 fps with this renderer as its delegate.
    func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = pixelFormat
        view.sampleCount = sampleCount
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.preferredFramesPerSecond = 60
        view.layer?.isOpaque = false
        view.delegate = self
    }

    private func build() throws {
        let library = try device.makeLibrary(source: navballShaderSource, options: nil)
        func pipeline(_ vfn: String, _ ffn: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vfn)
            d.fragmentFunction = library.makeFunction(name: ffn)
            d.rasterSampleCount = sampleCount
            let c = d.colorAttachments[0]!
            c.pixelFormat = pixelFormat
            // Premultiplied alpha over a transparent target.
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.sourceAlphaBlendFactor = .one
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: d)
        }
        ballPipeline = try pipeline("navball_vertex", "navball_fragment")
        markerPipeline = try pipeline("marker_vertex", "marker_fragment")

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .repeat
        sd.tAddressMode = .clampToEdge
        sd.maxAnisotropy = 8
        sampler = device.makeSamplerState(descriptor: sd)

        let cells = NavballArtwork.atlasColumns * NavballArtwork.cellSize
        guard let art = NavballArtwork.texture(device: device, queue: queue, width: NavballArtwork.width,
                                               height: NavballArtwork.height, draw: NavballArtwork.drawBall),
              let atlas = NavballArtwork.texture(device: device, queue: queue, width: cells, height: cells,
                                                 draw: NavballArtwork.drawAtlas)
        else { throw NSError(domain: "OrbitSim", code: 1, userInfo: [NSLocalizedDescriptionKey: "navball art"]) }
        self.art = art
        self.atlas = atlas
    }

    // MARK: Drawing

    private struct BallUniforms {
        var bodyToNED: simd_float4x4
        var geometry: SIMD4<Float>
    }

    private struct MarkerInstance {
        var place: SIMD4<Float>
        var cell: SIMD4<Float>
        var tint: SIMD4<Float>
    }

    /// Markers drawn later are on top: the trajectory pairs and the target's,
    /// then thrust, the command, prograde/retrograde, and last the
    /// manoeuvre, which a retrograde burn puts on the retrograde marker and
    /// the pilot flies to.
    private static let order: [NavballMarker.Kind] = [.radialIn, .radialOut, .antinormal, .normal, .antitarget,
                                                      .target, .thrust, .command, .retrograde, .prograde, .maneuver]
    /// Markers that get a pointer on the bezel when behind the ball.
    private static let pointed: [NavballMarker.Kind] = [.prograde, .command, .target, .maneuver]

    /// Encode the ball for `navball` into `encoder`, whose target is the
    /// square `viewport` (pixels).
    func encode(into encoder: MTLRenderCommandEncoder, viewport: MTLViewport, navball: Navball) {
        encoder.setViewport(viewport)
        let c = navball.bodyToNED
        func column(_ v: Vec3) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), 0) }
        var u = BallUniforms(bodyToNED: simd_float4x4(columns: (column(c.c0), column(c.c1), column(c.c2),
                                                                SIMD4(0, 0, 0, 1))),
                             geometry: SIMD4(Self.ballRadius, Self.bezelRadius, 0, 0))
        encoder.setRenderPipelineState(ballPipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<BallUniforms>.stride, index: 0)
        encoder.setFragmentTexture(art, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        var instances: [MarkerInstance] = []
        let white = SIMD4<Float>(1, 1, 1, 1)
        for kind in Self.order {
            for m in navball.markers where m.kind == kind {
                let p = Navball.project(m.body)
                let glyph = MarkerGlyph(kind)
                if p.front {
                    let alpha = Float(min(1, m.body.x / Self.fadeWidth))
                    let at = SIMD2(Float(p.x), Float(p.y)) * Self.ballRadius
                    instances.append(MarkerInstance(place: SIMD4(at.x, at.y, Self.markerSize, 0),
                                                    cell: NavballArtwork.cell(glyph), tint: SIMD4(1, 1, 1, alpha)))
                } else if Self.pointed.contains(kind) {
                    let a = Float(Navball.edgeAngle(m.body)), r = (Self.ballRadius + Self.bezelRadius) / 2
                    let color = glyph.color
                    instances.append(MarkerInstance(place: SIMD4(r * cos(a), r * sin(a), Self.pointerSize, a),
                                                    cell: NavballArtwork.cell(.pointer),
                                                    tint: SIMD4(Float(color.r), Float(color.g), Float(color.b), 1)))
                }
            }
        }
        instances.append(MarkerInstance(place: SIMD4(0, 0, Self.waterlineSize, 0),
                                        cell: NavballArtwork.cell(.waterline), tint: white))
        encoder.setRenderPipelineState(markerPipeline)
        encoder.setVertexBytes(&instances, length: MemoryLayout<MarkerInstance>.stride * instances.count, index: 0)
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
    }

    /// The largest centred square of a drawable.
    static func squareViewport(_ size: CGSize) -> MTLViewport {
        let side = Double(min(size.width, size.height))
        return MTLViewport(originX: (Double(size.width) - side) / 2, originY: (Double(size.height) - side) / 2,
                           width: side, height: side, znear: 0, zfar: 1)
    }

    // MARK: MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MTKView calls its delegate on the main thread.
    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(in: view) }
    }

    private func render(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let ball = source?() {
            encode(into: enc, viewport: Self.squareViewport(view.drawableSize), navball: ball)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: Offscreen

    /// The ball for `navball` as a `size` × `size` image, for reviewing the
    /// art without flying (`NavballArtwork.writeGallery`).
    func renderToImage(_ navball: Navball, size: Int) -> CGImage? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: size, height: size,
                                                         mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let resolved = device.makeTexture(descriptor: d) else { return nil }
        let pass = MTLRenderPassDescriptor()
        let a = pass.colorAttachments[0]!
        a.loadAction = .clear
        a.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        if sampleCount > 1 {
            let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: size, height: size,
                                                              mipmapped: false)
            md.textureType = .type2DMultisample
            md.sampleCount = sampleCount
            md.usage = .renderTarget
            md.storageMode = .private
            a.texture = device.makeTexture(descriptor: md)
            a.resolveTexture = resolved
            a.storeAction = .multisampleResolve
        } else {
            a.texture = resolved
            a.storeAction = .store
        }
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
        else { return nil }
        encode(into: enc, viewport: MTLViewport(originX: 0, originY: 0, width: Double(size), height: Double(size),
                                               znear: 0, zfar: 1), navball: navball)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        resolved.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
