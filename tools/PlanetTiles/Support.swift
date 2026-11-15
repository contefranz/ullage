import Compression
import Foundation
import ImageIO
import OrbitCore
import OrbitScene

// What the subcommands share: options, Deflate, image files, SOURCES.txt,
// the tool's work rasters.

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

func log(_ s: String) {
    FileHandle.standardError.write(Data("PlanetTiles: \(s)\n".utf8))
}

/// `--key value` and `--flag` options after a subcommand.
struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []

    init(_ args: [String], flags known: Set<String>) throws {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if known.contains(key) {
                    flags.insert(key)
                } else {
                    guard i + 1 < args.count else { throw ToolError("\(a) needs a value") }
                    values[key] = args[i + 1]
                    i += 1
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func path(_ key: String, default d: URL) -> URL {
        values[key].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? d
    }

    func int(_ key: String, default d: Int) throws -> Int {
        guard let v = values[key] else { return d }
        guard let i = Int(v) else { throw ToolError("--\(key) \(v): not a number") }
        return i
    }

    func double(_ key: String, default d: Double) throws -> Double {
        guard let v = values[key] else { return d }
        guard let x = Double(v) else { throw ToolError("--\(key) \(v): not a number") }
        return x
    }
}

/// ~/Library/Application Support/OrbitSim.
let supportDirectory: URL = {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OrbitSim", isDirectory: true)
}()

/// zlib (RFC 1950) to exactly `count` bytes, for TIFF's Deflate.
func inflate(_ zlib: Data, _ count: Int) throws -> Data {
    guard zlib.count > 2 else { throw ToolError("Deflate block too short") }
    var out = Data(count: count)
    let n = out.withUnsafeMutableBytes { dst in
        zlib.withUnsafeBytes { src in
            compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, count,
                                      src.bindMemory(to: UInt8.self).baseAddress! + 2, zlib.count - 2, nil, COMPRESSION_ZLIB)
        }
    }
    guard n == count else { throw ToolError("Deflate block: \(n) of \(count) bytes") }
    return out
}

/// A TIFF file, mapped.
func openTIFF(_ url: URL) throws -> TIFFImage {
    try TIFFImage(data: Data(contentsOf: url, options: .alwaysMapped), inflate: inflate)
}

// MARK: Images

enum ImageFiles {
    /// An 8-bit image's pixels as `channels` interleaved samples (1 grey, 3
    /// RGB), rows top first: ImageIO's decoded bytes as they are when it
    /// gives a layout this knows (no colour management), else drawn.
    static func decode(_ url: URL, channels: Int) throws -> (width: Int, height: Int, pixels: [UInt8]) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw ToolError("\(url.path): not an image")
        }
        let w = image.width, h = image.height
        if image.bitsPerComponent == 8, let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) {
            let bpp = image.bitsPerPixel / 8, row = image.bytesPerRow
            let first = [.premultipliedFirst, .first, .noneSkipFirst].contains(image.alphaInfo)
            let little = image.bitmapInfo.contains(.byteOrder32Little)
            var map: [Int]?
            switch (bpp, channels) {
            case (1, 1): map = [0]
            case (3, 3): map = [0, 1, 2]
            case (3, 1): map = [0]
            case (4, _):
                let rgb = little ? (first ? [2, 1, 0] : [3, 2, 1]) : (first ? [1, 2, 3] : [0, 1, 2])
                map = Array(rgb.prefix(channels))
            default: map = nil
            }
            if let map, CFDataGetLength(data) >= row * h {
                var out = [UInt8](repeating: 0, count: w * h * channels)
                out.withUnsafeMutableBufferPointer { o in
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        let s = p + y * row
                        for x in 0 ..< w { for c in 0 ..< channels { o[(y * w + x) * channels + c] = s[x * bpp + map[c]] } }
                    }
                }
                return (w, h, out)
            }
        }
        let grey = channels == 1
        let space = grey ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let bpr = w * (grey ? 1 : 4)
        var buffer = [UInt8](repeating: 0, count: bpr * h)
        try buffer.withUnsafeMutableBytes { b in
            guard let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                      space: space, bitmapInfo: grey ? CGImageAlphaInfo.none.rawValue
                                        : CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ToolError("context") }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        if grey { return (w, h, buffer) }
        var rgb = [UInt8](repeating: 0, count: w * h * channels)
        for k in 0 ..< w * h { for c in 0 ..< channels { rgb[k * channels + c] = buffer[4 * k + c] } }
        return (w, h, rgb)
    }

    /// Encodes `side`² texels of 1 (grey) or 3 (RGB) channels as JPEG or PNG.
    static func encode(_ samples: [UInt8], side: Int, channels: Int, png: Bool, quality: Double) throws -> Data {
        let grey = channels == 1
        guard let provider = CGDataProvider(data: Data(samples) as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8 * channels,
                                  bytesPerRow: side * channels,
                                  space: grey ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ToolError("tile image")
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, (png ? "public.png" : "public.jpeg") as CFString, 1, nil) else {
            throw ToolError("image destination")
        }
        CGImageDestinationAddImage(dest, image, png ? nil : [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("encode tile") }
        return out as Data
    }
}

// MARK: Provenance

/// SOURCES.txt, as tools/fetch_planet_data.sh writes it: a block per file,
/// its path relative to the sources directory, then indented
/// "Key: value" lines (Dataset, URL, Licence, Credit, Retrieved, Size, sha256).
struct SourcesFile {
    var entries: [String: [String: String]] = [:]

    init(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var current: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if !line.hasPrefix(" ") {
                current = String(line).trimmingCharacters(in: .whitespaces)
                entries[current!] = [:]
            } else if let c = current, let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                entries[c]![key] = value
            }
        }
    }

    /// OSTILES1 metadata for a layer made from `files` (relative paths):
    /// source, url, sha256, date, licence, credit, the tool's line.
    func metadata(for files: [String], tool: String, extra: [String: String] = [:]) -> [String: String] {
        var source = [String](), url = [String](), sha = [String](), date = [String](), licence = [String](), credit = [String]()
        for f in files {
            let e = entries[f] ?? [:]
            let name = (f as NSString).lastPathComponent
            if let d = e["Dataset"], !source.contains(d) { source.append(d) }
            if let u = e["URL"] { url.append(u) }
            sha.append("\(name) \(e["sha256"] ?? "not recorded")")
            if let r = e["Retrieved"], !date.contains(r) { date.append(r) }
            if let l = e["Licence"], !licence.contains(l) { licence.append(l) }
            if let c = e["Credit"], !credit.contains(c) { credit.append(c) }
        }
        var m: [String: String] = [
            "source": source.isEmpty ? files.joined(separator: "; ") : source.joined(separator: "; "),
            "url": url.joined(separator: " "),
            "sha256": sha.joined(separator: "; "),
            "date": date.joined(separator: "; "),
            "licence": licence.joined(separator: "; "),
            "tool": tool,
        ]
        if !credit.isEmpty { m["credit"] = credit.joined(separator: "; ") }
        for (k, v) in extra { m[k] = v }
        return m
    }
}

/// "PlanetTiles <subcommand> (git <commit>), <date>".
func toolLine(_ what: String) -> String {
    let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    var commit = "unknown"
    if (try? p.run()) != nil {
        p.waitUntilExit()
        commit = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return "PlanetTiles \(what) (git \(commit)), \(date)"
}

// MARK: Work rasters

/// A raster pyramid in the work directory: level 0 `name-0.osrastr`, then
/// halvings down to `minimumWidth`, files mapped.
func buildPyramid(_ base: GeoRaster, name: String, work: URL, minimumWidth: Int = 1_024,
                  linearize: ((Float) -> Float)? = nil, delinearize: ((Float) -> Float)? = nil) throws -> GeoRasterPyramid {
    var levels = [base]
    var k = 1
    while levels.last!.grid.width > minimumWidth {
        let g = levels.last!.grid.halved
        let path = work.appendingPathComponent("\(name)-\(k).osrastr").path
        let file = try GeoRasterFile.create(path: path, grid: g, channels: base.channels, type: base.type,
                                            scale: base.scale, noData: base.noData)
        let half = levels.last!.halved(storage: file.storage, linearize: linearize, delinearize: delinearize)
        levels.append(half)
        k += 1
    }
    return GeoRasterPyramid(levels: levels)
}

/// sRGB bytes to and from linear light, for colour mips.
let srgbToLinear: (Float) -> Float = { SRGB.byteToLinear[Int(min(max($0, 0), 255))] }
let linearToSRGB: (Float) -> Float = { SRGB.fromLinear($0) * 255 }

/// Writes a layer: tiles made in parallel, written in id order, into
/// `<out>/<name>.partial`, renamed over `<name>` when complete.
func writeLayer(_ name: String, out: URL, layout: PlanetTileLayout, metadata: [String: String], keys: [TileKey],
                make: (TileKey) throws -> Data) throws {
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let partial = out.appendingPathComponent(name + ".partial"), final = out.appendingPathComponent(name)
    let writer = try PlanetTileWriter(url: partial, layout: layout, metadata: metadata)
    var done = 0, bytes = 0
    let start = Date()
    try PlanetTileBuilder.build(keys, batch: 256, make: make) { key, payload in
        try writer.add(key, payload: payload)
        done += 1
        bytes += payload.count
        if done % 4_096 == 0 || done == keys.count {
            log(String(format: "%@: %d/%d tiles, %.0f MB, %.0f s", name, done, keys.count, Double(bytes) / 1e6,
                       Date().timeIntervalSince(start)))
        }
    }
    try writer.finish()
    _ = try? FileManager.default.removeItem(at: final)
    try FileManager.default.moveItem(at: partial, to: final)
    let check = try PlanetTileFile(contentsOf: final)
    try check.verify()
    log(String(format: "wrote %@: %d tiles to level %d, %.1f MB", final.path, check.count, check.layout.maxLevel,
               Double(bytes) / 1e6))
}

/// `PlanetTiles tiff FILE...`: reads each TIFF with the tool's reader and,
/// for 8-bit images ImageIO also reads, checks every sample against it.
func checkTIFF(_ files: [String]) throws {
    for path in files {
        let url = URL(fileURLWithPath: path)
        let t = try openTIFF(url)
        print("\(path): \(t.width) × \(t.height) × \(t.samplesPerPixel), \(t.bitsPerSample)-bit format \(t.sampleFormat), "
              + "compression \(t.compression), predictor \(t.predictor), \(t.isTiled ? "tiles" : "strips") \(t.blockWidth) × \(t.blockHeight)")
        if let g = t.geoGrid {
            print("  grid: west \(g.west), north \(g.north), pixel \(g.pixelWidth) × \(g.pixelHeight)\(t.pixelIsPoint ? " (PixelIsPoint)" : "")")
        }
        let type: GeoSampleType = t.bitsPerSample == 8 ? .uint8 : t.bitsPerSample == 16 ? (t.sampleFormat == 2 ? .int16 : .uint16) : .float32
        let r = GeoRaster(grid: GeoGrid(width: t.width, height: t.height, west: 0, north: 0, pixelWidth: 1, pixelHeight: 1),
                          channels: t.samplesPerPixel, type: type)
        let start = Date()
        try t.read(into: r)
        print(String(format: "  read in %.2f s", Date().timeIntervalSince(start)))
        guard t.bitsPerSample == 8, t.samplesPerPixel == 1 || t.samplesPerPixel == 3 else { continue }
        let img = try ImageFiles.decode(url, channels: t.samplesPerPixel)
        var differ = 0
        img.pixels.withUnsafeBytes { p in
            let a = p.bindMemory(to: UInt8.self), b = r.storage.bytes.assumingMemoryBound(to: UInt8.self)
            for k in 0 ..< img.pixels.count where a[k] != b[k] { differ += 1 }
        }
        print("  against ImageIO: \(differ) of \(img.pixels.count) samples differ")
        if differ > 0 { throw ToolError("\(path): the reader and ImageIO disagree") }
    }
}
