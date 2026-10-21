import CoreGraphics
import CoreText
import Foundation
import Metal
import simd
import OrbitCore
import OrbitScene

/// Screen-aligned sprites drawn once, at startup, with CoreGraphics and
/// CoreText into one texture: the orbit-line markers (Ap, Pe, AN, DN, EI)
/// with their labels, the characters of their readouts, and the navball's
/// marker symbols (track A's `MarkerGlyph`, so the 3-D view can show the same
/// art). Symbols have the navball's look: a coloured stroke over a dark
/// outline, readable on sky, ground and space.
@MainActor
final class SpriteAtlas {
    /// The markers on the focus vessel's orbit line.
    typealias OrbitMarker = OrbitMarkerKind

    enum Key: Hashable {
        case orbit(OrbitMarker)
        case glyph(MarkerGlyph)
        case character(Character)
    }

    struct Cell {
        /// Texture coordinates: left, top, right, bottom.
        let uv: SIMD4<Float>
        /// Size in points.
        let size: SIMD2<Float>
        /// The anchor, in points from the cell's bottom-left corner (y up).
        let anchor: SIMD2<Float>
        /// Characters: points to the next one's anchor.
        let advance: Float
    }

    /// Texture pixels per point.
    static let scale: CGFloat = 2
    /// The characters readouts are written in.
    static let characters = Array("0123456789.,-+ kmsh:")

    let texture: MTLTexture
    private var cells: [Key: Cell] = [:]

    init?(device: MTLDevice) {
        typealias Item = (key: Key, size: CGSize, anchor: CGPoint, advance: CGFloat, draw: (CGContext, CGRect) -> Void)
        let labelFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, 11, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, 11, nil)
        let digitFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, 10, nil) ?? labelFont

        var items: [Item] = []
        for m in OrbitMarker.allCases {
            let label = Self.line(m.label, font: labelFont, color: m.color)
            let width = 20 + CTLineGetTypographicBounds(label.fill, nil, nil, nil) + 3
            items.append((.orbit(m), CGSize(width: width, height: 22), CGPoint(x: 10, y: 11), 0, { ctx, r in
                Self.drawSymbol(m, in: ctx, centre: CGPoint(x: r.minX + 10, y: r.minY + 11))
                Self.draw(label, in: ctx, at: CGPoint(x: r.minX + 20, y: r.minY + 11.5))
            }))
        }
        for g in MarkerGlyph.allCases {
            items.append((.glyph(g), CGSize(width: 26, height: 26), CGPoint(x: 13, y: 13), 0, { ctx, r in
                g.draw(in: ctx, rect: r.insetBy(dx: 1, dy: 1))
            }))
        }
        for c in Self.characters {
            let line = Self.line(String(c), font: digitFont, color: (1, 1, 1))
            let advance = CTLineGetTypographicBounds(line.fill, nil, nil, nil)
            items.append((.character(c), CGSize(width: advance + 4, height: 16), CGPoint(x: 2, y: 4), advance, { ctx, r in
                Self.draw(line, in: ctx, at: CGPoint(x: r.minX + 2, y: r.minY + 4))
            }))
        }

        // Shelf packing in points, 2 pt apart.
        let widthPoints: CGFloat = 256
        var x: CGFloat = 1, y: CGFloat = 1, shelf: CGFloat = 0
        var placed: [(Item, CGRect)] = []
        for item in items {
            if x + item.size.width + 1 > widthPoints { x = 1; y += shelf + 2; shelf = 0 }
            placed.append((item, CGRect(origin: CGPoint(x: x, y: y), size: item.size)))
            x += item.size.width + 2
            shelf = max(shelf, item.size.height)
        }
        let heightPoints = y + shelf + 1
        let w = Int(widthPoints * Self.scale), h = Int((heightPoints * Self.scale).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 4 * w, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: Self.scale, y: Self.scale)
        ctx.setShouldAntialias(true)
        for (item, rect) in placed {
            ctx.saveGState()
            ctx.clip(to: rect)
            item.draw(ctx, rect)
            ctx.restoreGState()
            // The bitmap's first row is the top: v runs down from it.
            let fw = Float(widthPoints), fh = Float(heightPoints)
            cells[item.key] = Cell(uv: SIMD4(Float(rect.minX) / fw, 1 - Float(rect.maxY) / fh,
                                             Float(rect.maxX) / fw, 1 - Float(rect.minY) / fh),
                                   size: SIMD2(Float(rect.width), Float(rect.height)),
                                   anchor: SIMD2(Float(item.anchor.x), Float(item.anchor.y)),
                                   advance: Float(item.advance))
        }

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: w, height: h,
                                                          mipmapped: false)
        td.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: td) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: 4 * w)
        self.texture = texture
    }

    func cell(_ key: Key) -> Cell? { cells[key] }

    /// A sprite's two triangles: `key`'s cell with its anchor `offset`
    /// points (y up) from the screen position of `position` (camera-relative
    /// world), at `pointScale` pixels per point, tinted by `tint`
    /// (premultiplied). Returns the cell's width in points (0 if none).
    @discardableResult
    func append(_ key: Key, at position: Vec3, offset: SIMD2<Float> = .zero, pointScale: Float,
                tint: SIMD4<Float> = SIMD4(1, 1, 1, 1), to out: inout [SpriteVertex]) -> Float {
        guard let c = cells[key] else { return 0 }
        let p = SIMD4<Float>(position, 1)
        let x0 = (offset.x - c.anchor.x) * pointScale, x1 = (offset.x - c.anchor.x + c.size.x) * pointScale
        let y0 = (offset.y - c.anchor.y) * pointScale, y1 = (offset.y - c.anchor.y + c.size.y) * pointScale
        let bl = SpriteVertex(position: p, offset: SIMD4(x0, y0, c.uv.x, c.uv.w), color: tint)
        let br = SpriteVertex(position: p, offset: SIMD4(x1, y0, c.uv.z, c.uv.w), color: tint)
        let tr = SpriteVertex(position: p, offset: SIMD4(x1, y1, c.uv.z, c.uv.y), color: tint)
        let tl = SpriteVertex(position: p, offset: SIMD4(x0, y1, c.uv.x, c.uv.y), color: tint)
        out += [bl, br, tr, bl, tr, tl]
        return c.size.x
    }

    /// `text` in readout characters, its baseline starting `offset` points
    /// from the screen position of `position`. Characters the atlas lacks
    /// are skipped.
    func appendText(_ text: String, at position: Vec3, offset: SIMD2<Float>, pointScale: Float,
                    tint: SIMD4<Float> = SIMD4(1, 1, 1, 1), to out: inout [SpriteVertex]) {
        var x = offset.x
        for ch in text {
            guard let c = cells[.character(ch)] else { continue }
            if ch != " " { append(.character(ch), at: position, offset: SIMD2(x, offset.y), pointScale: pointScale, tint: tint, to: &out) }
            x += c.advance
        }
    }

    // MARK: Drawing

    private struct Line {
        let fill: CTLine
        let outline: CTLine
    }

    private static func line(_ s: String, font: CTFont, color: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Line {
        func make(_ extra: [NSAttributedString.Key: Any]) -> CTLine {
            var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            attributes.merge(extra) { $1 }
            return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attributes))
        }
        let fill = make([NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                            CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1)])
        // A positive stroke width (percent of the size) strokes without filling.
        let outline = make([NSAttributedString.Key(kCTStrokeWidthAttributeName as String): 28,
                            NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(gray: 0, alpha: 0.8)])
        return Line(fill: fill, outline: outline)
    }

    /// Draws `line` with its baseline at `origin`, over its dark outline.
    private static func draw(_ line: Line, in ctx: CGContext, at origin: CGPoint) {
        ctx.saveGState()
        ctx.setLineJoin(.round)
        ctx.textPosition = origin
        CTLineDraw(line.outline, ctx)
        ctx.textPosition = origin
        CTLineDraw(line.fill, ctx)
        ctx.restoreGState()
    }

    /// The orbit markers' symbols, 12 pt across: Ap and Pe a ring round a
    /// dot, AN and DN triangles up and down, EI a ring crossed.
    private static func drawSymbol(_ m: OrbitMarker, in ctx: CGContext, centre c: CGPoint) {
        let path = CGMutablePath()
        var dot = false
        let r: CGFloat = 5
        switch m {
        case .periapsis, .apoapsis:
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            dot = true
        case .ascendingNode:
            path.addLines(between: [CGPoint(x: c.x, y: c.y + r + 1), CGPoint(x: c.x - r, y: c.y - r + 1),
                                    CGPoint(x: c.x + r, y: c.y - r + 1)])
            path.closeSubpath()
        case .descendingNode:
            path.addLines(between: [CGPoint(x: c.x, y: c.y - r - 1), CGPoint(x: c.x - r, y: c.y + r - 1),
                                    CGPoint(x: c.x + r, y: c.y + r - 1)])
            path.closeSubpath()
        case .entryInterface:
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            let d = r * 0.6
            path.move(to: CGPoint(x: c.x - d, y: c.y - d)); path.addLine(to: CGPoint(x: c.x + d, y: c.y + d))
            path.move(to: CGPoint(x: c.x - d, y: c.y + d)); path.addLine(to: CGPoint(x: c.x + d, y: c.y - d))
        }
        let color = CGColor(srgbRed: m.color.r, green: m.color.g, blue: m.color.b, alpha: 1)
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.8))
        ctx.setLineWidth(3.6)
        ctx.strokePath()
        if dot {
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.8))
            ctx.fillEllipse(in: CGRect(x: c.x - 2.2, y: c.y - 2.2, width: 4.4, height: 4.4))
        }
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1.6)
        ctx.strokePath()
        if dot {
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: c.x - 1.3, y: c.y - 1.3, width: 2.6, height: 2.6))
        }
        ctx.restoreGState()
    }
}

extension OrbitMarkerKind {
    /// sRGB.
    var color: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch self {
        case .periapsis, .apoapsis: (0.35, 0.75, 1.0)
        case .ascendingNode, .descendingNode: MarkerGlyph.normal.color
        case .entryInterface: (1.0, 0.48, 0.15)
        }
    }
}

/// A screen-aligned sprite's vertex (OverlayShaders).
struct SpriteVertex {
    /// Camera-relative world position of the anchor, w = 1.
    var position: SIMD4<Float>
    /// xy: offset from the anchor in pixels (y up), zw: atlas texture coordinates.
    var offset: SIMD4<Float>
    /// Tint (premultiplied by alpha).
    var color: SIMD4<Float>
}
