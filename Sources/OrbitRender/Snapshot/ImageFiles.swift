import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import OrbitScene

/// Image files the snapshots write and the golden tests read: 8-bit sRGB
/// PNGs (no alpha), linear PFMs and JPEG contact sheets.
public enum ImageFiles {
    public enum Failure: Error, CustomStringConvertible {
        case cannotWrite(URL)
        case cannotRead(URL)

        public var description: String {
            switch self {
            case .cannotWrite(let url): "cannot write \(url.path)"
            case .cannotRead(let url): "cannot read \(url.path)"
            }
        }
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// An opaque sRGB image of 4-byte pixels (rows top first), alpha ignored.
    public static func cgImage(_ pixels: [UInt8], width: Int, height: Int, order: ImageMetrics.Order) -> CGImage? {
        let info: UInt32 = order == .bgra
            ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4 * width,
                       space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    public static func writePNG(_ pixels: [UInt8], width: Int, height: Int, order: ImageMetrics.Order,
                                to url: URL) throws {
        guard let image = cgImage(pixels, width: width, height: height, order: order) else {
            throw Failure.cannotWrite(url)
        }
        try write(image, type: .png, to: url)
    }

    public static func write(_ image: CGImage, type: UTType, quality: Double? = nil, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure.cannotWrite(url)
        }
        let options = NSMutableDictionary()
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.cannotWrite(url) }
    }

    /// A PNG's pixels as RGBA in sRGB, rows top first.
    public static func readPNG(_ url: URL) throws -> (pixels: [UInt8], width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.cannotRead(url) }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: 4 * w * h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 4 * w,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw Failure.cannotRead(url) }
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        return (pixels, w, h)
    }

    /// A Portable Float Map of the linear light the 8-bit sRGB pixels encode
    /// (RGB, little-endian, rows bottom first, scale -1).
    public static func writePFM(_ pixels: [UInt8], width: Int, height: Int, order: ImageMetrics.Order,
                                to url: URL) throws {
        let (ri, gi, bi) = order == .bgra ? (2, 1, 0) : (0, 1, 2)
        var data = Data("PF\n\(width) \(height)\n-1.0\n".utf8)
        var floats = [Float](repeating: 0, count: 3 * width * height)
        for y in 0..<height {
            let row = height - 1 - y
            for x in 0..<width {
                let i = 4 * (row * width + x), o = 3 * (y * width + x)
                floats[o] = Float(ImageMetrics.linear[Int(pixels[i + ri])])
                floats[o + 1] = Float(ImageMetrics.linear[Int(pixels[i + gi])])
                floats[o + 2] = Float(ImageMetrics.linear[Int(pixels[i + bi])])
            }
        }
        floats.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }

    /// BGRA pixels as RGBA.
    public static func rgba(fromBGRA p: [UInt8]) -> [UInt8] {
        var out = p
        for i in stride(from: 0, to: p.count, by: 4) {
            out[i] = p[i + 2]
            out[i + 2] = p[i]
        }
        return out
    }
}
