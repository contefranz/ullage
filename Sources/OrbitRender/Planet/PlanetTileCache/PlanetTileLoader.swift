import Foundation
import ImageIO
import Metal
import QuartzCore
import OrbitCore
import OrbitScene

/// Decodes tile payloads off the main thread (track E1): images (JPEG,
/// PNG, HEIC) through ImageIO into 8-bit texels with their mips, raw tiles
/// copied as they are or loaded by Metal's IO queue straight into the
/// staging buffer. Results wait in a locked list for the main thread.
final class PlanetTileLoader: @unchecked Sendable {
    struct Job {
        let key: TileKey
        let staging: MTLBuffer
        /// The payload, a slice of the mapped file (images, and raw tiles
        /// without an IO queue).
        let payload: Data?
    }

    struct Result {
        let key: TileKey
        let staging: MTLBuffer
        let ok: Bool
        /// Seconds spent decoding (or copying), and payload bytes read.
        let seconds: Double
        let bytes: Int
    }

    let format: PlanetTileSampleFormat
    let across: Int
    let channels: Int
    let mipLevels: Int
    let srgb: Bool
    private let queue = DispatchQueue(label: "OrbitSim.PlanetTiles.decode", qos: .utility, attributes: .concurrent)
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var done: [Result] = []

    init(format: PlanetTileSampleFormat, across: Int, channels: Int, mipLevels: Int, srgb: Bool) {
        self.format = format
        self.across = across
        self.channels = channels
        self.mipLevels = mipLevels
        self.srgb = srgb
    }

    /// Decodes `job` on the background queue.
    func submit(_ job: Job) {
        group.enter()
        queue.async { [self] in
            let start = CACurrentMediaTime()
            var ok = false
            if let payload = job.payload {
                ok = (try? Self.decode(payload, format: format, into: job.staging.contents(), across: across,
                                       channels: channels, mipLevels: mipLevels, srgb: srgb)) != nil
            }
            finish(Result(key: job.key, staging: job.staging, ok: ok, seconds: CACurrentMediaTime() - start,
                          bytes: job.payload?.count ?? 0))
        }
    }

    /// Records a finished load (the IO queue's completions land here too).
    func finish(_ r: Result) {
        lock.lock()
        done.append(r)
        lock.unlock()
        group.leave()
    }

    /// Counts a load the IO queue will finish.
    func enterIO() { group.enter() }

    /// The finished loads, oldest first.
    func drain() -> [Result] {
        lock.lock()
        defer { lock.unlock() }
        let out = done
        done = []
        return out
    }

    /// Waits for every submitted load (synchronous mode, tests).
    func waitForAll() { group.wait() }

    /// Decodes a payload into the atlas's texel layout at `p`: mip 0 of
    /// across² texels of `channels` samples, then its mips.
    static func decode(_ payload: Data, format: PlanetTileSampleFormat, into p: UnsafeMutableRawPointer, across m: Int,
                       channels: Int, mipLevels: Int, srgb: Bool) throws {
        switch format {
        case .int16, .uint8:
            // Raw: the texels as stored (channels as the file's; no mips).
            payload.withUnsafeBytes { src in p.copyMemory(from: src.baseAddress!, byteCount: payload.count) }
            return
        case .jpeg, .png, .heic:
            break
        }
        guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == m, image.height == m else { throw PlanetTileError.badFormat("tile image") }
        let dst = p.assumingMemoryBound(to: UInt8.self)
        if !copyDecoded(image, into: dst, across: m, channels: channels) {
            try draw(image, into: dst, across: m, channels: channels, srgb: srgb)
        }
        TileTexelMips.generate(p, across: m, channels: channels, levels: mipLevels, srgb: srgb)
    }

    /// Copies an 8-bit image's decoded pixels as they are, with no colour
    /// management (data layers must not be converted); false for a pixel
    /// layout it does not know.
    static func copyDecoded(_ image: CGImage, into dst: UnsafeMutablePointer<UInt8>, across m: Int, channels: Int) -> Bool {
        guard image.bitsPerComponent == 8, let data = image.dataProvider?.data, let src = CFDataGetBytePtr(data) else {
            return false
        }
        let bpp = image.bitsPerPixel / 8, row = image.bytesPerRow
        let alpha = image.alphaInfo
        let little = image.bitmapInfo.contains(.byteOrder32Little)
        // Where red, green and blue are in a pixel.
        let rgb: (Int, Int, Int)
        switch bpp {
        case 1, 2: rgb = (0, 0, 0)
        case 3: rgb = (0, 1, 2)
        case 4:
            let first = alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst
            if little { rgb = first ? (2, 1, 0) : (3, 2, 1) } else { rgb = first ? (1, 2, 3) : (0, 1, 2) }
        default: return false
        }
        guard CFDataGetLength(data) >= row * m else { return false }
        for y in 0 ..< m {
            let s = src + y * row, d = dst + y * m * channels
            for x in 0 ..< m {
                let px = s + x * bpp
                switch channels {
                case 1: d[x] = px[rgb.0]
                case 2: d[2 * x] = px[rgb.0]; d[2 * x + 1] = px[rgb.1]
                default:
                    d[4 * x] = px[rgb.0]; d[4 * x + 1] = px[rgb.1]; d[4 * x + 2] = px[rgb.2]; d[4 * x + 3] = 255
                }
            }
        }
        return true
    }

    /// Draws the image into an 8-bit context (other pixel layouts).
    static func draw(_ image: CGImage, into dst: UnsafeMutablePointer<UInt8>, across m: Int, channels: Int, srgb: Bool) throws {
        let grey = channels == 1
        let space = grey ? CGColorSpaceCreateDeviceGray()
            : (srgb ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceRGB())
        let info = grey ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        let bpr = m * (grey ? 1 : 4)
        var buffer = [UInt8](repeating: 0, count: bpr * m)
        try buffer.withUnsafeMutableBytes { b in
            guard let ctx = CGContext(data: b.baseAddress, width: m, height: m, bitsPerComponent: 8, bytesPerRow: bpr,
                                      space: space, bitmapInfo: info) else { throw PlanetTileError.badFormat("context") }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: m, height: m))
        }
        for y in 0 ..< m {
            for x in 0 ..< m {
                for c in 0 ..< channels { dst[(y * m + x) * channels + c] = grey ? buffer[y * bpr + x] : buffer[y * bpr + 4 * x + c] }
            }
        }
    }
}

/// Which of the renderer's frames the GPU has finished, from command
/// buffers' completion handlers (any thread).
final class FrameCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var through: UInt64 = 0
    private var finished = Set<UInt64>()

    /// Every frame up to this one has finished; nil before the first.
    var completedThrough: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return through == 0 ? nil : through
    }

    func complete(_ frame: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        finished.insert(frame)
        while finished.remove(through + 1) != nil { through += 1 }
    }
}
