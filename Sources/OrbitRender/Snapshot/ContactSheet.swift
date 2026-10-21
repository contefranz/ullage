import CoreGraphics
import CoreText
import Foundation
import UniformTypeIdentifiers

/// A JPEG contact sheet a session can Read: one row per shot, its images
/// side by side (the golden, the render and their difference, or the render
/// and its debug views), each under a caption.
public struct ContactSheet {
    public struct Cell {
        public let image: CGImage
        public let caption: String

        public init(image: CGImage, caption: String) {
            self.image = image
            self.caption = caption
        }
    }

    public var rows: [[Cell]] = []
    /// Each image's width on the sheet, pixels.
    public var cellWidth = 480

    public init() {}

    public func write(to url: URL, quality: Double = 0.85) throws {
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return }
        let caption = 22, gap = 6
        func height(_ c: Cell) -> Int { Int((Double(c.image.height) * Double(cellWidth) / Double(c.image.width)).rounded()) }
        let rowHeights = rows.map { ($0.map(height).max() ?? 0) + caption }
        let w = columns * (cellWidth + gap) + gap, h = rowHeights.reduce(0) { $0 + $1 + gap } + gap
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageFiles.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ImageFiles.Failure.cannotWrite(url)
        }
        ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        var top = h - gap      // CoreGraphics' y runs up
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.enumerated() {
                let x = gap + c * (cellWidth + gap), ih = height(cell)
                ctx.interpolationQuality = .high
                ctx.draw(cell.image, in: CGRect(x: x, y: top - caption - ih, width: cellWidth, height: ih))
                // Built key by key: dictionary literals trip Swift 6.4's
                // optimizer in this module (see FallbackTextures).
                var attributes = [NSAttributedString.Key: Any]()
                attributes[NSAttributedString.Key(kCTFontAttributeName as String)] = font
                attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = CGColor(gray: 0.95, alpha: 1)
                let text = NSAttributedString(string: cell.caption, attributes: attributes)
                ctx.textPosition = CGPoint(x: x + 2, y: top - caption + 6)
                CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
            }
            top -= rowHeights[r] + gap
        }
        guard let image = ctx.makeImage() else { throw ImageFiles.Failure.cannotWrite(url) }
        try ImageFiles.write(image, type: .jpeg, quality: quality, to: url)
    }
}
