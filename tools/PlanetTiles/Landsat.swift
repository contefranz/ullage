import CoreGraphics
import Foundation
import ImageIO
import OrbitCore
import OrbitScene

/// The Cape inset (decision 31, design §4 "Cape inset"): a Landsat 8/9
/// Collection 2 Level-1 scene, pan-sharpened to 15 m, its 1970s Shuttle
/// Landing Facility painted out by cloning scrub beside it, its colours
/// matched to the BMNG month it sits on, and feathered into BMNG at the
/// inset's edges, as the deep levels (8-12) of the albedo around LC-39.
enum Landsat {
    static let defaultScene = "LC09_L1TP_016040_20221209_20230318_02_T1"
    /// The inset: LC-39, the Cape's pads, the SLF, Titusville's shore.
    static let region = GeoRegion(south: 28.30, north: 28.85, west: -80.85, east: -80.45)
    /// How far inside the region the inset fades in from BMNG, m.
    static let featherMeters = 2_000.0
    static let levels = 8 ... 12

    /// A band on its UTM grid (metres), DN 0 being fill.
    struct Band {
        let raster: GeoRaster
        let view: RasterView
        let mult: Double, add: Double

        init(raster: GeoRaster, mult: Double, add: Double) {
            self.raster = raster; view = raster.view; self.mult = mult; self.add = add
        }

        /// Top-of-atmosphere reflectance at easting, northing; nil off the scene.
        func reflectance(_ e: Double, _ n: Double, sunSine: Double) -> Double? {
            let p = view.grid.position(latitudeDegrees: n, longitudeDegrees: e)
            guard p.x >= 0.5, p.y >= 0.5, p.x <= Double(view.grid.width) - 0.5, p.y <= Double(view.grid.height) - 0.5 else {
                return nil
            }
            let dn = Double(view.bilinear(x: p.x, y: p.y)[0])
            guard dn.isFinite, dn > 0 else { return nil }
            return (mult * dn + add) / sunSine
        }
    }

    struct Scene {
        let red: Band, green: Band, blue: Band, pan: Band
        let utm: TransverseMercator
        let sunSine: Double
        let files: [String]

        /// Pan-sharpened (Brovey) reflectance at a point (rad); nil off the scene.
        func colour(latitude: Double, longitude: Double) -> SIMD3<Double>? {
            let p = utm.forward(latitude: latitude, longitude: longitude)
            guard let r = red.reflectance(p.easting, p.northing, sunSine: sunSine),
                  let g = green.reflectance(p.easting, p.northing, sunSine: sunSine),
                  let b = blue.reflectance(p.easting, p.northing, sunSine: sunSine),
                  let pan = pan.reflectance(p.easting, p.northing, sunSine: sunSine) else { return nil }
            let i = (r + g + b) / 3
            let ratio = i > 1e-4 ? min(max(pan / i, 0.5), 2) : 1
            return SIMD3(r, g, b) * ratio
        }
    }

    /// "KEY = value" lines of an MTL file.
    static func mtl(_ url: URL) throws -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ToolError("\(url.path) missing") }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            out[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return out
    }

    static func open(_ dir: URL, scene id: String) throws -> Scene {
        let m = try mtl(dir.appendingPathComponent("\(id)_MTL.txt"))
        guard m["MAP_PROJECTION"] == "UTM", m["DATUM"] == "WGS84", let zone = m["UTM_ZONE"].flatMap(Int.init),
              let sun = m["SUN_ELEVATION"].flatMap(Double.init) else { throw ToolError("\(id)_MTL.txt: not a UTM WGS 84 scene") }
        var files = ["landsat/\(id)_MTL.txt"]
        func band(_ n: Int) throws -> Band {
            let name = "\(id)_B\(n).TIF"
            files.append("landsat/" + name)
            let tiff = try openTIFF(dir.appendingPathComponent(name))
            guard let g = tiff.geoGrid, tiff.bitsPerSample == 16, tiff.samplesPerPixel == 1 else {
                throw ToolError("\(name): not a 16-bit GeoTIFF band")
            }
            let r = GeoRaster(grid: g, channels: 1, type: .uint16)
            try tiff.read(into: r)
            r.noData = 0
            guard let mult = m["REFLECTANCE_MULT_BAND_\(n)"].flatMap(Double.init),
                  let add = m["REFLECTANCE_ADD_BAND_\(n)"].flatMap(Double.init) else { throw ToolError("MTL: band \(n) rescaling") }
            log(String(format: "%@: %d × %d at %.0f m", name, g.width, g.height, g.pixelWidth))
            return Band(raster: r, mult: mult, add: add)
        }
        let red = try band(4), green = try band(3), blue = try band(2), pan = try band(8)
        return Scene(red: red, green: green, blue: blue, pan: pan, utm: .utm(zone: zone), sunSine: sin(sun * .pi / 180),
                     files: files)
    }

    // MARK: Paint-out

    /// A strip to paint out (tools/data/cape_paintout.json): the segment
    /// from `from` to `to` (lat, lon degrees) lengthened by `extend` m at
    /// both ends, `halfWidth` m either side, faded over `feather` m, filled
    /// from the ground `clone` (east, north m) away.
    struct Strip: Decodable {
        let name: String
        let from: [Double], to: [Double]
        let extend: Double, halfWidth: Double, feather: Double
        let clone: [Double]

        /// 0 outside to 1 inside, at a point (rad).
        func weight(latitude: Double, longitude: Double) -> Double {
            // A local plane about the strip's start, metres east and north.
            let lat0 = from[0] * .pi / 180, lon0 = from[1] * .pi / 180
            let m = ReliefNormals.meridionalRadius(.wgs84, latitude: lat0)
            let n = Ellipsoid.wgs84.primeVerticalRadius(latitude: lat0) * cos(lat0)
            func local(_ la: Double, _ lo: Double) -> (Double, Double) { ((lo - lon0) * n, (la - lat0) * m) }
            let b = local(to[0] * .pi / 180, to[1] * .pi / 180), p = local(latitude, longitude)
            let length = (b.0 * b.0 + b.1 * b.1).squareRoot()
            let ux = b.0 / length, uy = b.1 / length
            let along = p.0 * ux + p.1 * uy, across = abs(-p.0 * uy + p.1 * ux)
            let outside = max(across - halfWidth, -extend - along, along - length - extend)
            return min(1, max(0, 1 - outside / feather))
        }

        /// The point `clone` metres away (rad).
        func source(latitude: Double, longitude: Double) -> (Double, Double) {
            let m = ReliefNormals.meridionalRadius(.wgs84, latitude: latitude)
            let n = Ellipsoid.wgs84.primeVerticalRadius(latitude: latitude) * cos(latitude)
            return (latitude + clone[1] / m, longitude + clone[0] / n)
        }
    }

    struct PaintOut: Decodable {
        let strips: [Strip]
    }

    static func paintOut(_ url: URL) throws -> PaintOut {
        try JSONDecoder().decode(PaintOut.self, from: Data(contentsOf: url))
    }

    /// The scene's reflectance at a point with the strips painted out.
    static func painted(_ s: Scene, _ p: PaintOut, latitude: Double, longitude: Double) -> SIMD3<Double>? {
        guard var c = s.colour(latitude: latitude, longitude: longitude) else { return nil }
        for strip in p.strips {
            let w = strip.weight(latitude: latitude, longitude: longitude)
            guard w > 0 else { continue }
            let src = strip.source(latitude: latitude, longitude: longitude)
            if let fill = s.colour(latitude: src.0, longitude: src.1) { c += (fill - c) * w }
        }
        return c
    }

    // MARK: The inset

    /// Builds earth-cape-landsat.ostiles from the scene in Sources/earth/landsat.
    static func cape(paths: Earth.Paths, scene id: String, bmng: GeoRasterPyramid, month: Int, quality: Double,
                     preview: URL?) throws {
        let dir = paths.sources.appendingPathComponent("landsat")
        let scene = try open(dir, scene: id)
        let paint = try paintOut(paintOutFile())
        let deg = Double.pi / 180
        func bmngLinear(_ la: Double, _ lo: Double, _ dLa: Double, _ dLo: Double) -> SIMD3<Double> {
            let v = bmng.sample(latitude: la, longitude: lo, dLatitude: dLa, dLongitude: dLo)
            return SIMD3((0 ..< 3).map { Double(SRGB.toLinear(v[$0] / 255)) })
        }
        // Colour match: per channel, BMNG's linear colour against Landsat's
        // reflectance averaged over each BMNG texel (15"), least squares,
        // clouds and fill left out.
        let step = 15.0 / 3_600
        var sx = SIMD3<Double>(), sy = sx, sxx = sx, sxy = sx, count = 0.0
        var la = region.south + step / 2
        while la < region.north {
            var lo = region.west + step / 2
            while lo < region.east {
                var acc = SIMD3<Double>(), n = 0.0
                for j in 0 ..< 4 {
                    for i in 0 ..< 4 {
                        let a = (la + (Double(j) - 1.5) * step / 4) * deg, b = (lo + (Double(i) - 1.5) * step / 4) * deg
                        if let c = painted(scene, paint, latitude: a, longitude: b) { acc += c; n += 1 }
                    }
                }
                if n == 16 && acc.max() / 16 < 0.4 {
                    let x = acc / 16, y = bmngLinear(la * deg, lo * deg, step * deg, step * deg)
                    sx += x; sy += y; sxx += x * x; sxy += x * y; count += 1
                }
                lo += step
            }
            la += step
        }
        guard count > 1_000 else { throw ToolError("the scene covers too little of the Cape (\(Int(count)) clear BMNG texels)") }
        let gain = (count * sxy - sx * sy) / (count * sxx - sx * sx), offset = (sy - gain * sx) / count
        log("cape: colour match over \(Int(count)) BMNG texels: gain \(gain), offset \(offset)")
        func matched(_ c: SIMD3<Double>) -> SIMD3<Double> { simdClamp(c * gain + offset, 0, 1) }
        let m0 = ReliefNormals.meridionalRadius(.wgs84, latitude: 28.6 * deg)
        let n0 = Ellipsoid.wgs84.primeVerticalRadius(latitude: 28.6 * deg) * cos(28.6 * deg)
        /// The inset's weight at a point: 1 well inside the region, fading over the feather.
        func inset(_ la: Double, _ lo: Double) -> Double {
            let d = min((la / deg - region.south) * m0 * deg, (region.north - la / deg) * m0 * deg,
                        (lo / deg - region.west) * n0 * deg, (region.east - lo / deg) * n0 * deg)
            let x = min(1, max(0, d / featherMeters))
            return x * x * (3 - 2 * x)
        }
        /// A texel's colour (sRGB bytes): the matched scene over its
        /// footprint, blended into BMNG at the region's edge and off the scene.
        func texel(_ t: TileTexel) -> [UInt8] {
            let base = bmngLinear(t.latitude, t.longitude, t.dLatitude, t.dLongitude)
            var w = inset(t.latitude, t.longitude)
            var c = base
            if w > 0 {
                let footprint = max(t.dLatitude * m0, t.dLongitude * n0)
                let taps = min(8, max(1, Int((footprint / 15).rounded(.up))))
                var acc = SIMD3<Double>(), n = 0.0
                for j in 0 ..< taps {
                    for i in 0 ..< taps {
                        let a = t.latitude + ((Double(j) + 0.5) / Double(taps) - 0.5) * t.dLatitude
                        let b = t.longitude + ((Double(i) + 0.5) / Double(taps) - 0.5) * t.dLongitude
                        if let s = painted(scene, paint, latitude: a, longitude: b) { acc += matched(s); n += 1 }
                    }
                }
                if n > 0 { c = acc / n } else { w = 0 }
                w *= n / Double(taps * taps)
                c = base + (c - base) * w
            }
            return (0 ..< 3).map { UInt8(min(255, max(0, (Double(SRGB.fromLinear(Float(c[$0]))) * 255).rounded()))) }
        }
        if let preview { try writePreview(preview, texel: texel) }
        let keys = PlanetTileBuilder.keys(levels: levels, region: region, figure: Earth.figure)
        let meta = paths.sourcesFile.metadata(
            for: scene.files, tool: toolLine("earth cape --scene \(id) --match-month \(month)"),
            extra: ["layer": "albedo inset", "scene": id, "matched to": String(format: "BMNG 2004-%02d", month),
                    "region": "\(region.south)...\(region.north) N, \(region.west)...\(region.east) E",
                    "painted out": paint.strips.map(\.name).joined(separator: "; ")])
        try writeLayer(EarthTileFiles.capeInset, out: paths.out,
                       layout: Earth.layout(.jpeg, channels: 3, maxLevel: levels.upperBound), metadata: meta, keys: keys) { key in
            var rgb = [UInt8]()
            for t in PlanetTileBuilder.texels(of: key, tileSize: Earth.tileSize, border: Earth.border, figure: Earth.figure) {
                rgb += texel(t)
            }
            return try ImageFiles.encode(rgb, side: Earth.tileSize + 2 * Earth.border, channels: 3, png: false, quality: quality)
        }
    }

    static func simdClamp(_ v: SIMD3<Double>, _ lo: Double, _ hi: Double) -> SIMD3<Double> {
        SIMD3(min(max(v.x, lo), hi), min(max(v.y, lo), hi), min(max(v.z, lo), hi))
    }

    /// tools/data/cape_paintout.json, found from the working directory or
    /// next to the tool's source.
    static func paintOutFile() throws -> URL {
        let candidates = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tools/data/cape_paintout.json"),
                          URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                              .appendingPathComponent("data/cape_paintout.json")]
        guard let u = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ToolError("tools/data/cape_paintout.json not found: run from the repository")
        }
        return u
    }

    /// The region at about 15 m as a PNG, north up, to look at.
    static func writePreview(_ url: URL, texel: (TileTexel) -> [UInt8]) throws {
        let deg = Double.pi / 180
        let step = 0.5 / 3_600
        let w = Int((region.east - region.west) / step), h = Int((region.north - region.south) / step)
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        rgb.withUnsafeMutableBufferPointer { out in
            let base = out.baseAddress!
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0 ..< w {
                    let la = (region.north - (Double(y) + 0.5) * step) * deg, lo = (region.west + (Double(x) + 0.5) * step) * deg
                    let t = TileTexel(column: 0, row: 0, direction: .zero, latitude: la, longitude: lo,
                                      dLatitude: step * deg, dLongitude: step * deg)
                    let c = texel(t)
                    for k in 0 ..< 3 { base[(y * w + x) * 3 + k] = c[k] }
                }
            }
        }
        // A wide image: encode as one PNG of w × h.
        try ImageFiles.encodeRect(rgb, width: w, height: h).write(to: url)
        log("cape preview: \(url.path) (\(w) × \(h))")
    }
}

extension ImageFiles {
    /// An RGB image of any shape as PNG.
    static func encodeRect(_ rgb: [UInt8], width: Int, height: Int) throws -> Data {
        guard let provider = CGDataProvider(data: Data(rgb) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ToolError("preview") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { throw ToolError("preview") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("preview") }
        return out as Data
    }
}
