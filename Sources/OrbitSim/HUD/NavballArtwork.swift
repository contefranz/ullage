import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Metal
import OrbitCore

/// The navball's art, drawn with CoreGraphics at start-up: no image assets,
/// and nothing from KSP (its art is proprietary).
enum NavballArtwork {
    // MARK: Ball texture

    /// Size of the ball's equirectangular map: azimuth across from north
    /// (u = 0) through east, elevation down from the zenith (v = 0).
    static let width = 2048, height = 1024

    /// Draw the ball's map: blue sky over brown ground, a white horizon,
    /// heading meridians every 10° (heavier every 30°), pitch parallels every
    /// 10° labelled on eight meridians, 5° ticks within ±20°, the compass card
    /// above and below the horizon, a zenith circle and a nadir cross. Lines
    /// and labels are widened by 1/cos(elevation), so they keep their width
    /// on the sphere.
    static func drawBall(in ctx: CGContext) {
        let w = CGFloat(width), h = CGFloat(height)
        let pxPerDeg = w / 360
        func y(_ el: CGFloat) -> CGFloat { (el + 90) * pxPerDeg }   // CG's y is up: the zenith at the top
        func x(_ az: CGFloat) -> CGFloat { az * pxPerDeg }
        func stretch(_ el: CGFloat) -> CGFloat { 1 / max(cos(el * .pi / 180), 0.08) }
        func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!

        // Sky and ground.
        let sky = CGGradient(colorsSpace: space, colors: [srgb(0.40, 0.64, 0.90), srgb(0.10, 0.28, 0.60)] as CFArray,
                             locations: [0, 1])!
        let ground = CGGradient(colorsSpace: space, colors: [srgb(0.60, 0.40, 0.20), srgb(0.24, 0.15, 0.07)] as CFArray,
                                locations: [0, 1])!
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: h / 2, width: w, height: h / 2))
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h / 2), end: CGPoint(x: 0, y: h), options: [])
        ctx.restoreGState()
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h / 2))
        ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: h / 2), end: CGPoint(x: 0, y: 0), options: [])
        ctx.restoreGState()

        let skyLine = srgb(1, 1, 1, 0.55), groundLine = srgb(1, 0.93, 0.85, 0.45)
        func lineColor(_ el: CGFloat) -> CGColor { el >= 0 ? skyLine : groundLine }

        /// A meridian at azimuth `az` from `el0` to `el1`, `px` wide on the sphere.
        func meridian(_ az: CGFloat, from el0: CGFloat, to el1: CGFloat, px: CGFloat, color: CGColor) {
            let path = CGMutablePath()
            let steps = Int(abs(el1 - el0) / 1) + 1
            var left: [CGPoint] = [], right: [CGPoint] = []
            for i in 0...steps {
                let el = el0 + (el1 - el0) * CGFloat(i) / CGFloat(steps)
                let half = px / 2 * stretch(el)
                left.append(CGPoint(x: x(az) - half, y: y(el)))
                right.append(CGPoint(x: x(az) + half, y: y(el)))
            }
            path.addLines(between: left + right.reversed())
            path.closeSubpath()
            for dx in [-w, 0, w] {   // wrap across the seam
                ctx.saveGState()
                ctx.translateBy(x: dx, y: 0)
                ctx.addPath(path)
                ctx.setFillColor(color)
                ctx.fillPath()
                ctx.restoreGState()
            }
        }
        /// A parallel at elevation `el`, `px` tall, from azimuth `az0` to `az1`.
        func parallel(_ el: CGFloat, px: CGFloat, color: CGColor, from az0: CGFloat = 0, to az1: CGFloat = 360) {
            ctx.setFillColor(color)
            for dx in [-w, 0, w] {
                ctx.fill(CGRect(x: x(az0) + dx, y: y(el) - px / 2, width: x(az1) - x(az0), height: px))
            }
        }
        /// Text centred at (`az`, `el`), `size` px tall on the sphere.
        func label(_ s: String, az: CGFloat, el: CGFloat, size: CGFloat, color: CGColor, bold: Bool = true) {
            let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            for dx in [-w, 0, w] {
                ctx.saveGState()
                ctx.translateBy(x: x(az) + dx, y: y(el))
                ctx.scaleBy(x: stretch(el), y: 1)
                ctx.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        }

        // Heading meridians.
        for az in stride(from: CGFloat(0), to: 360, by: 10) {
            let heavy = az.truncatingRemainder(dividingBy: 30) == 0
            meridian(az, from: -80, to: 0, px: heavy ? 3 : 1.6, color: srgb(1, 0.93, 0.85, heavy ? 0.5 : 0.3))
            meridian(az, from: 0, to: 80, px: heavy ? 3 : 1.6, color: srgb(1, 1, 1, heavy ? 0.55 : 0.32))
        }
        // Pitch parallels, ticks and labels.
        for el in stride(from: CGFloat(-80), through: 80, by: 10) where el != 0 {
            parallel(el, px: 2, color: lineColor(el))
        }
        for el: CGFloat in [-15, -5, 5, 15] {
            for az in stride(from: CGFloat(0), to: 360, by: 30) {
                parallel(el, px: 2, color: lineColor(el), from: az - 2.5, to: az + 2.5)
            }
        }
        for az in stride(from: CGFloat(0), to: 360, by: 45) {
            for el in stride(from: CGFloat(-80), through: 80, by: 10) where el != 0 {
                let text = "\(Int(abs(el)))"
                label(text, az: az + 4.2 * stretch(el), el: el + 2.2, size: 15,
                      color: el > 0 ? srgb(1, 1, 1, 0.9) : srgb(1, 0.95, 0.88, 0.85))
            }
        }
        // The horizon and the compass card.
        parallel(0, px: 5, color: srgb(1, 1, 1, 0.95))
        let card = ["N", "3", "6", "E", "12", "15", "S", "21", "24", "W", "30", "33"]
        for (i, s) in card.enumerated() {
            let az = CGFloat(i * 30)
            let cardinal = i % 3 == 0
            label(s, az: az, el: 3.6, size: cardinal ? 22 : 17, color: srgb(1, 1, 1, 0.95))
            label(s, az: az, el: -3.6, size: cardinal ? 22 : 17, color: srgb(1, 0.95, 0.88, 0.95))
        }
        // Zenith circle, nadir cross.
        parallel(85, px: 4, color: srgb(1, 1, 1, 0.8))
        for az: CGFloat in [0, 90, 180, 270] {
            meridian(az, from: -90, to: -84, px: 4, color: srgb(1, 0.95, 0.88, 0.8))
        }
    }

    // MARK: Marker atlas

    /// The marker atlas: `atlasColumns` × `atlasColumns` cells of `cellSize`
    /// px, glyph `n` in column n % columns and row n / columns from the top.
    static let atlasColumns = 4, cellSize = 128

    static func drawAtlas(in ctx: CGContext) {
        let n = atlasColumns, s = CGFloat(cellSize), top = CGFloat(n * cellSize)
        for g in MarkerGlyph.allCases {
            let col = g.rawValue % n, row = g.rawValue / n
            g.draw(in: ctx, rect: CGRect(x: CGFloat(col) * s, y: top - CGFloat(row + 1) * s, width: s, height: s))
        }
    }

    /// The atlas cell of `glyph`: origin and size in texture coordinates.
    static func cell(_ glyph: MarkerGlyph) -> SIMD4<Float> {
        let n = atlasColumns, size = 1 / Float(n)
        return SIMD4(Float(glyph.rawValue % n) * size, Float(glyph.rawValue / n) * size, size, size)
    }

    // MARK: Textures

    /// An sRGB, premultiplied RGBA texture of `width` × `height` drawn by
    /// `draw` (CoreGraphics, y up), with its mipmaps.
    static func texture(device: MTLDevice, queue: MTLCommandQueue, width: Int, height: Int,
                        draw: (CGContext) -> Void) -> MTLTexture? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        draw(ctx)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: width, height: height,
                                                         mipmapped: true)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data,
                    bytesPerRow: width * 4)
        if let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        return tex
    }

    // MARK: Gallery

    /// Canned attitudes for reviewing the art without flying: the Saturn on
    /// the pad (crew axes, heads east), climbing at 45° on 072, level with a
    /// 30° bank, inverted, and heads down in orbit; each with a velocity
    /// that puts the trajectory markers on the face.
    static let gallery: [(name: String, attitude: HorizonAttitude, velocity: (el: Double, az: Double))] = [
        ("pad-090-90-0", HorizonAttitude(heading: 90 * deg, pitch: 90 * deg, roll: 0), (0, 90)),
        ("climb-072-45-180", HorizonAttitude(heading: 72 * deg, pitch: 45 * deg, roll: .pi), (40, 74)),
        ("level-030-0-30", HorizonAttitude(heading: 30 * deg, pitch: 0, roll: 30 * deg), (2, 35)),
        ("inverted-200-10-180", HorizonAttitude(heading: 200 * deg, pitch: 10 * deg, roll: .pi), (-5, 190)),
        ("orbit-heads-down-088-0-180", HorizonAttitude(heading: 88 * deg, pitch: 0, roll: .pi), (0.05, 88)),
    ]
    static let deg = Double.pi / 180

    /// Render the gallery into `directory` as PNGs of `size` px.
    @MainActor
    static func writeGallery(to directory: URL, renderer: NavballRenderer, size: Int = 512) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let r = Vec3(6_571_000, 0, 0)
        let horizon = LocalHorizon.geocentric(at: r, pole: .unitZ)
        for g in gallery {
            let velocity = horizon.direction(elevation: g.velocity.el * deg, azimuth: g.velocity.az * deg) * 7_800
            let ball = Navball(attitude: g.attitude.attitude(in: horizon), horizon: horizon, position: r,
                               velocity: velocity, frame: .orbit, frameVelocity: velocity)
            guard let image = renderer.renderToImage(ball, size: size) else { continue }
            let url = directory.appendingPathComponent("navball-\(g.name).png")
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
        }
    }
}
