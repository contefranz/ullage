import CryptoKit
import Foundation
import OrbitCore
import OrbitScene

/// `PlanetTiles earth ...` (M1.6 track E1): the Earth's OSTILES1 layers
/// from the sources tools/fetch_planet_data.sh fetched. Every layer is
/// sampled texel by texel at geodetic latitude and longitude, through
/// `Ellipsoid.geodeticCoordinates(figureDirection:)`, with 256-texel tiles
/// and 4-texel borders, on WGS 84.
enum Earth {
    static let tileSize = 256, border = 4
    static let figure = Ellipsoid.wgs84

    static let usage = """
    usage: PlanetTiles earth <step> [options]
      albedo --month MM     BMNG 2004 500 m, the 1960s Aral Sea and Lake Chad painted in → earth-bmng-2004-MM.ostiles
      water                 Natural Earth land, lakes and the historic lakes → earth-water.ostiles
      relief                ETOPO 2022 30" normals (water flattened) → earth-relief.ostiles
      cape                  the Landsat 15 m inset of the Cape, SLF painted out → earth-cape-landsat.ostiles
      all                   water, relief, then albedo for every month fetched and the Cape
      demo --image FILE     an albedo layer from one equirectangular image (e.g. Textures/earth.jpg) for tests
    options:
      --sources DIR         fetched data (default ~/Library/Application Support/OrbitSim/Sources/earth)
      --out DIR             tile files (default ~/Library/Application Support/OrbitSim/Tiles)
      --work DIR            scratch rasters, up to about 15 GB (default ~/Library/Application Support/OrbitSim/Work)
      --keep-work           keep the scratch rasters
      --max-level N         deepest level (albedo 7, water and relief 5, demo 3)
      --quality Q           JPEG quality (albedo 0.9)
      --match-month MM      the BMNG month the Cape inset is matched to and filled from (default 12, else 10, else 07)
      --scene ID            the Landsat scene (default \(Landsat.defaultScene))
      --preview FILE        cape: also write the painted-out inset as a PNG to look at
      cape-selftest         the Cape's processing on a synthetic scene (no download needed)
    usage: PlanetTiles info FILE...    header, metadata, tiles per level, checksums
    """

    struct Paths {
        var sources: URL
        var out: URL
        var work: URL
        var keepWork: Bool
        var sourcesFile: SourcesFile { SourcesFile(sources.appendingPathComponent("SOURCES.txt")) }
    }

    static func run(_ args: [String]) throws {
        guard let step = args.first else { throw ToolError(usage) }
        let o = try Options(Array(args.dropFirst()), flags: ["keep-work"])
        let paths = Paths(sources: o.path("sources", default: supportDirectory.appendingPathComponent("Sources/earth")),
                          out: o.path("out", default: supportDirectory.appendingPathComponent("Tiles")),
                          work: o.path("work", default: supportDirectory.appendingPathComponent("Work")),
                          keepWork: o.flags.contains("keep-work"))
        try FileManager.default.createDirectory(at: paths.work, withIntermediateDirectories: true)
        defer { if !paths.keepWork { cleanWork(paths.work) } }
        let quality = try o.double("quality", default: 0.9)
        switch step {
        case "albedo":
            guard let m = o.values["month"].flatMap(Int.init), (1 ... 12).contains(m) else { throw ToolError("albedo needs --month MM") }
            _ = try albedo(month: m, paths: paths, maxLevel: try o.int("max-level", default: 7), quality: quality)
        case "water":
            _ = try water(paths: paths, maxLevel: try o.int("max-level", default: 5))
        case "relief":
            try relief(paths: paths, maxLevel: try o.int("max-level", default: 5), water: nil)
        case "cape":
            let month = try matchMonth(o, paths)
            let bmng = try albedo(month: month, paths: paths, maxLevel: 7, quality: quality, writeTiles: false)
            try Landsat.cape(paths: paths, scene: o.values["scene"] ?? Landsat.defaultScene, bmng: bmng, month: month,
                             quality: quality, preview: o.values["preview"].map { URL(fileURLWithPath: $0) })
        case "all":
            // Water and relief first, their rasters dropped before the
            // albedo's 15 GB: the peak stays one month's mosaic.
            do {
                let w = try water(paths: paths, maxLevel: 5)
                try relief(paths: paths, maxLevel: 5, water: w)
            }
            if !paths.keepWork { cleanWork(paths.work, prefix: "etopo"); cleanWork(paths.work, prefix: "water") }
            let months = availableMonths(paths)
            guard !months.isEmpty else { throw ToolError("no BMNG months in \(paths.sources.path)/bmng") }
            let match = try matchMonth(o, paths)
            for m in months {
                let bmng = try albedo(month: m, paths: paths, maxLevel: 7, quality: quality)
                if m == match, FileManager.default.fileExists(atPath: paths.sources.appendingPathComponent("landsat").path) {
                    try Landsat.cape(paths: paths, scene: o.values["scene"] ?? Landsat.defaultScene, bmng: bmng, month: m,
                                     quality: quality, preview: o.values["preview"].map { URL(fileURLWithPath: $0) })
                }
                if !paths.keepWork { cleanWork(paths.work, prefix: "bmng-\(m)") }
            }
        case "cape-selftest":
            try Landsat.selfTest(keepPreview: o.values["preview"].map { URL(fileURLWithPath: $0) })
        case "demo":
            guard let image = o.values["image"] else { throw ToolError("demo needs --image FILE") }
            try demo(image: URL(fileURLWithPath: (image as NSString).expandingTildeInPath),
                     month: try o.int("month", default: 7), paths: paths, maxLevel: try o.int("max-level", default: 3),
                     quality: quality)
        default:
            throw ToolError(usage)
        }
    }

    static func cleanWork(_ work: URL, prefix: String = "") {
        for f in (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
            where (f.hasSuffix(".osrastr") || f.hasSuffix(".osrastr.partial")) && f.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: work.appendingPathComponent(f))
        }
    }

    static func layout(_ format: PlanetTileSampleFormat, channels: Int, maxLevel: Int) -> PlanetTileLayout {
        PlanetTileLayout(format: format, tileSize: tileSize, border: border, channels: channels, maxLevel: maxLevel,
                         bodyID: 399, figure: figure)
    }

    /// Bytes of a texel's samples (fractions, or raw 0...255).
    static func bytes(_ v: SIMD4<Float>, _ channels: Int, raw: Bool) -> [UInt8] {
        (0 ..< channels).map { c in
            let x = raw ? v[c] : v[c] * 255
            return x.isFinite ? UInt8(min(255, max(0, x.rounded()))) : 0
        }
    }

    // MARK: Albedo

    static let bmngTiles = ["A1", "A2", "B1", "B2", "C1", "C2", "D1", "D2"]

    static func availableMonths(_ paths: Paths) -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.sources.appendingPathComponent("bmng").path)) ?? []
        return (1 ... 12).filter { m in
            bmngTiles.allSatisfy { t in names.contains { $0.hasPrefix(String(format: "world.2004%02d.3x21600x21600.%@", m, t)) } }
        }
    }

    static func matchMonth(_ o: Options, _ paths: Paths) throws -> Int {
        if let m = o.values["match-month"].flatMap(Int.init) { return m }
        let months = availableMonths(paths)
        guard let m = [12, 10, 7].first(where: months.contains) ?? months.first else {
            throw ToolError("no BMNG month in \(paths.sources.path)/bmng to match the Cape to")
        }
        return m
    }

    /// The month's BMNG mosaic (86,400 × 43,200, 11 GB in the work
    /// directory) with the historic lakes painted in, its pyramid, and
    /// (unless `writeTiles` is false) its tile layer.
    static func albedo(month: Int, paths: Paths, maxLevel: Int, quality: Double, writeTiles: Bool = true) throws -> GeoRasterPyramid {
        let dir = paths.sources.appendingPathComponent("bmng")
        let grid = GeoGrid.global(width: 86_400)
        let base = paths.work.appendingPathComponent("bmng-\(month)-0.osrastr")
        let files = bmngTiles.map { "bmng/" + (bmngFile(dir, month, $0)?.lastPathComponent ?? $0) }
        // Written as .partial and renamed when every tile is in and the
        // lakes are painted: an interrupted run's mosaic is never reused.
        let (raster, reused) = try GeoRasterFile.build(path: base.path, grid: grid, channels: 3, type: .uint8) { raster in
            for t in bmngTiles {
                guard let url = bmngFile(dir, month, t) else {
                    throw ToolError(String(format: "BMNG month %02d tile %@ missing in %@", month, t, dir.path))
                }
                let column = (Int(t.prefix(1).unicodeScalars.first!.value) - 65) * 21_600
                let row = t.hasSuffix("1") ? 0 : 21_600
                log("reading \(url.lastPathComponent)")
                if url.pathExtension.lowercased().hasPrefix("tif") {
                    let tiff = try openTIFF(url)
                    guard tiff.width == 21_600, tiff.height == 21_600, tiff.samplesPerPixel == 3, tiff.bitsPerSample == 8 else {
                        throw ToolError("\(url.lastPathComponent): \(tiff.width) × \(tiff.height) × \(tiff.samplesPerPixel), not BMNG's")
                    }
                    if let g = tiff.geoGrid {
                        // The tie point must agree with the name's place.
                        guard abs(g.west - (-180 + Double(column) / 240)) < 1e-6, abs(g.north - (90 - Double(row) / 240)) < 1e-6 else {
                            throw ToolError("\(url.lastPathComponent): tie point \(g.west), \(g.north) is not tile \(t)'s")
                        }
                    }
                    try tiff.read(into: raster, column: column, row: row)
                } else {
                    let img = try ImageFiles.decode(url, channels: 3)
                    guard img.width == 21_600, img.height == 21_600 else { throw ToolError("\(url.lastPathComponent): size") }
                    img.pixels.withUnsafeBytes { src in
                        for r in 0 ..< 21_600 {
                            (raster.storage.bytes + (row + r) * raster.bytesPerRow + column * 3)
                                .copyMemory(from: src.baseAddress! + r * 21_600 * 3, byteCount: 21_600 * 3)
                        }
                    }
                }
            }
            try paintHistoricLakes(into: raster, paths: paths)
        }
        if reused { log("reusing the complete mosaic \(base.lastPathComponent)") }
        log("BMNG \(String(format: "%02d", month)): building the pyramid")
        let pyramid = try buildPyramid(raster, name: "bmng-\(month)", work: paths.work, linearize: srgbToLinear,
                                       delinearize: linearToSRGB)
        guard writeTiles else { return pyramid }
        let keys = PlanetTileBuilder.keys(levels: 0 ... maxLevel, figure: figure)
        let meta = paths.sourcesFile.metadata(
            for: files + Water.files, tool: toolLine("earth albedo --month \(month)"),
            extra: ["month": String(format: "%02d", month), "layer": "albedo",
                    "note": "BMNG 2004 with the late-1950s Aral Sea and early-1960s Lake Chad (Natural Earth historic lakes) painted in"])
        try writeLayer(EarthTileFiles.albedo(month: month), out: paths.out,
                       layout: layout(.jpeg, channels: 3, maxLevel: maxLevel), metadata: meta, keys: keys) { key in
            let samples = PlanetTileBuilder.sample(key, tileSize: tileSize, border: border, figure: figure, channels: 3) { t in
                pyramid.sample(latitude: t.latitude, longitude: t.longitude, dLatitude: t.dLatitude, dLongitude: t.dLongitude)
            }
            return try ImageFiles.encode(samples.map { UInt8(min(255, max(0, $0.isFinite ? $0.rounded() : 0))) },
                                         side: tileSize + 2 * border, channels: 3, png: false, quality: quality)
        }
        return pyramid
    }

    static func bmngFile(_ dir: URL, _ month: Int, _ tile: String) -> URL? {
        let stem = String(format: "world.2004%02d.3x21600x21600.%@", month, tile)
        for ext in ["_geo.tif", ".tif", ".png", ".jpg"] {
            let u = dir.appendingPathComponent(stem + ext)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// Paints the 1960s Aral Sea and Lake Chad (Natural Earth's historic
    /// lakes, decision 33) into the BMNG mosaic where 2004 shows dry land:
    /// each lake in the colour of its own 2004 water, the darkest 30 % of
    /// the texels Natural Earth's lakes layer calls water inside it (or a
    /// deep-lake colour if that is not water-like), blended by coverage.
    static func paintHistoricLakes(into raster: GeoRaster, paths: Paths) throws {
        let historic = try Water.historicLakes(paths)
        let lakes = try Water.polygons(paths, "ne_10m_lakes.geojson")
        for lake in historic {
            let b = lake.bounds
            let g = raster.grid
            let x0 = max(0, Int(((b.west - 0.1) - g.west) / g.pixelWidth)), x1 = min(g.width, Int(((b.east + 0.1) - g.west) / g.pixelWidth) + 1)
            let y0 = max(0, Int((g.north - (b.north + 0.1)) / g.pixelHeight)), y1 = min(g.height, Int((g.north - (b.south - 0.1)) / g.pixelHeight) + 1)
            let window = GeoGrid(width: x1 - x0, height: y1 - y0, west: g.west + Double(x0) * g.pixelWidth,
                                 north: g.north - Double(y0) * g.pixelHeight, pixelWidth: g.pixelWidth, pixelHeight: g.pixelHeight)
            let then = PolygonRasterizer.coverage([lake], on: window)
            let nearby = lakes.filter { l in
                let lb = l.bounds
                return lb.east >= window.west && lb.west <= window.west + Double(window.width) * window.pixelWidth
                    && lb.north >= window.north - Double(window.height) * window.pixelHeight && lb.south <= window.north
            }
            let now = PolygonRasterizer.coverage(nearby, on: window)
            // The lake's colour: its own 2004 water, darkest first.
            var water: [(Float, [Float])] = []
            for y in 0 ..< window.height {
                for x in 0 ..< window.width where then.value(x, y) > 0.5 && now.value(x, y) > 0.9 {
                    let c = (0 ..< 3).map { raster.raw(x0 + x, y0 + y, $0) }
                    water.append((c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722, c))
                }
            }
            water.sort { $0.0 < $1.0 }
            let dark = water.prefix(max(1, water.count * 3 / 10))
            var colour: [Float] = [24, 44, 58]
            if water.count >= 20 {
                let median = (0 ..< 3).map { c in dark.map { $0.1[c] }.sorted()[dark.count / 2] }
                // Water-like: bluer than it is red.
                if median[2] >= median[0] { colour = median }
            }
            log("painting \(lake.properties["name"] ?? "?") (\(lake.properties["date"] ?? "")): sRGB \(colour.map { Int($0) }), from \(water.count) texels of 2004 water")
            for y in 0 ..< window.height {
                for x in 0 ..< window.width {
                    let w = then.value(x, y) * (1 - now.value(x, y))
                    guard w > 0 else { continue }
                    for c in 0 ..< 3 {
                        let old = SRGB.byteToLinear[Int(raster.raw(x0 + x, y0 + y, c))]
                        let new = SRGB.byteToLinear[Int(colour[c])]
                        raster.setRaw(x0 + x, y0 + y, c, SRGB.fromLinear(old + (new - old) * w) * 255)
                    }
                }
            }
        }
    }

    // MARK: Water

    enum Water {
        static let files = ["natural-earth/ne_10m_land.geojson", "natural-earth/ne_10m_lakes.geojson",
                            "natural-earth/ne_10m_lakes_historic.geojson"]
        /// Decision 33: the 1960s Aral Sea and Lake Chad only (the layer
        /// also holds Lake Texcoco of the 1500s and Lop Nur of the 1970s).
        static let historicNames: Set<String> = ["Aral Sea", "Lake Chad"]

        static func polygons(_ paths: Paths, _ name: String, include: ([String: String]) -> Bool = { _ in true }) throws -> [GeoPolygon] {
            let url = paths.sources.appendingPathComponent("natural-earth").appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { throw ToolError("\(url.path) missing") }
            return try GeoJSON.polygons(data, include: include)
        }

        static func historicLakes(_ paths: Paths) throws -> [GeoPolygon] {
            let h = try polygons(paths, "ne_10m_lakes_historic.geojson") { historicNames.contains($0["name"] ?? "") }
            guard Set(h.compactMap { $0.properties["name"] }) == historicNames else {
                throw ToolError("ne_10m_lakes_historic.geojson lacks \(historicNames.sorted())")
            }
            return h
        }
    }

    /// The water fraction on a 30" grid (43,200 × 21,600): not land, or a
    /// lake, or a historic lake; and its layer.
    static func water(paths: Paths, maxLevel: Int) throws -> GeoRasterPyramid {
        let grid = GeoGrid.global(width: 43_200)
        let path = paths.work.appendingPathComponent("water-0.osrastr").path
        let file = try GeoRasterFile.create(path: path, grid: grid, channels: 1, type: .uint8, scale: 1.0 / 255)
        let land = try Water.polygons(paths, "ne_10m_land.geojson")
        let lakes = try Water.polygons(paths, "ne_10m_lakes.geojson"), historic = try Water.historicLakes(paths)
        log("water: \(land.count) land polygons, \(lakes.count) lakes, the Aral Sea and Lake Chad as in the 1960s")
        // Each set in a pass of its own: the modern lakes lie inside their 1960s outlines.
        let raster = WaterMask.rasterize(land: land, waters: [lakes, historic], on: grid, storage: file.storage)
        let pyramid = try buildPyramid(raster, name: "water", work: paths.work)
        let meta = paths.sourcesFile.metadata(for: Water.files, tool: toolLine("earth water"),
                                              extra: ["layer": "water", "values": "water fraction, 0 land to 255 water"])
        try writeLayer(EarthTileFiles.water, out: paths.out, layout: layout(.png, channels: 1, maxLevel: maxLevel),
                       metadata: meta, keys: PlanetTileBuilder.keys(levels: 0 ... maxLevel, figure: figure)) { key in
            let s = PlanetTileBuilder.sample(key, tileSize: tileSize, border: border, figure: figure, channels: 1) { t in
                pyramid.sample(latitude: t.latitude, longitude: t.longitude, dLatitude: t.dLatitude, dLongitude: t.dLongitude)
            }
            return try ImageFiles.encode(PlanetTileBuilder.bytes(s), side: tileSize + 2 * border, channels: 1, png: true, quality: 1)
        }
        return pyramid
    }

    // MARK: Relief

    static let etopo = "etopo/ETOPO_2022_v1_30s_N90W180_surface.tif"

    /// Normals from ETOPO 2022's 30" surface heights, in the local east,
    /// north, up frame, encoded as RGB; flat over water (`water`, or the
    /// water layer rebuilt).
    static func relief(paths: Paths, maxLevel: Int, water given: GeoRasterPyramid?) throws {
        let url = paths.sources.appendingPathComponent(etopo)
        let tiff = try openTIFF(url)
        guard let g = tiff.geoGrid, tiff.sampleFormat == 3, tiff.bitsPerSample == 32, tiff.samplesPerPixel == 1 else {
            throw ToolError("\(url.lastPathComponent): not ETOPO 2022's float GeoTIFF")
        }
        let path = paths.work.appendingPathComponent("etopo-0.osrastr").path
        let raster = try GeoRasterFile.create(path: path, grid: g, channels: 1, type: .float32,
                                              noData: tiff.noData.map(Float.init))
        log("relief: reading \(tiff.width) × \(tiff.height) heights")
        try tiff.read(into: raster)
        let heights = try buildPyramid(raster, name: "etopo", work: paths.work)
        let water = try given ?? self.water(paths: paths, maxLevel: 5)
        let meta = paths.sourcesFile.metadata(
            for: [etopo] + Water.files, tool: toolLine("earth relief"),
            extra: ["layer": "relief", "values": "unit normal (east, north, up) in the local geodetic frame, [-1, 1] as 0-255; flat over water"])
        try writeLayer(EarthTileFiles.relief, out: paths.out, layout: layout(.png, channels: 3, maxLevel: maxLevel),
                       metadata: meta, keys: PlanetTileBuilder.keys(levels: 0 ... maxLevel, figure: figure)) { key in
            var out = [UInt8]()
            out.reserveCapacity((tileSize + 2 * border) * (tileSize + 2 * border) * 3)
            for t in PlanetTileBuilder.texels(of: key, tileSize: tileSize, border: border, figure: figure) {
                func wet(_ la: Double, _ lo: Double) -> Bool {
                    water.sample(latitude: la, longitude: lo, dLatitude: t.dLatitude, dLongitude: t.dLongitude)[0] > 0.5
                }
                func h(_ la: Double, _ lo: Double) -> Double {
                    let v = Double(heights.sample(latitude: la, longitude: lo, dLatitude: t.dLatitude, dLongitude: t.dLongitude)[0])
                    return v.isFinite ? v : 0
                }
                let n: Vec3
                if wet(t.latitude, t.longitude) {
                    n = Vec3(0, 0, 1)
                } else {
                    let centre = h(t.latitude, t.longitude)
                    // A texel's ground size; water around takes the centre's height.
                    let step = max(t.dLatitude * ReliefNormals.meridionalRadius(figure, latitude: t.latitude),
                                   t.dLongitude * figure.primeVerticalRadius(latitude: t.latitude) * cos(t.latitude)) / 2
                    n = ReliefNormals.normal(latitude: t.latitude, longitude: t.longitude, step: max(step, 100), figure: figure) { la, lo in
                        wet(la, lo) ? centre : h(la, lo)
                    }
                }
                let e = ReliefNormals.encode(n)
                out += [e.0, e.1, e.2]
            }
            return try ImageFiles.encode(out, side: tileSize + 2 * border, channels: 3, png: true, quality: 1)
        }
    }

    // MARK: Demo and info

    /// An albedo layer from one equirectangular image (180° W at the left,
    /// north up), for trying the store without the big fetch.
    static func demo(image: URL, month: Int, paths: Paths, maxLevel: Int, quality: Double) throws {
        let img = try ImageFiles.decode(image, channels: 3)
        guard img.width == 2 * img.height else { throw ToolError("\(image.lastPathComponent): not 2:1 equirectangular") }
        let raster = GeoRaster(grid: .global(width: img.width), channels: 3, type: .uint8)
        img.pixels.withUnsafeBytes { raster.storage.bytes.copyMemory(from: $0.baseAddress!, byteCount: img.pixels.count) }
        let pyramid = GeoRasterPyramid(raster, linearize: srgbToLinear, delinearize: linearToSRGB)
        let data = try Data(contentsOf: image, options: .alwaysMapped)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let meta: [String: String] = [
            "source": "demo: \(image.lastPathComponent), \(img.width) × \(img.height)",
            "url": "file://\(image.path)", "sha256": "\(image.lastPathComponent) \(sha)",
            "date": String(ISO8601DateFormatter().string(from: Date()).prefix(10)), "tool": toolLine("earth demo"),
            "licence": "as the image's", "month": String(format: "%02d", month), "layer": "albedo",
        ]
        try writeLayer(EarthTileFiles.albedo(month: month), out: paths.out, layout: layout(.jpeg, channels: 3, maxLevel: maxLevel),
                       metadata: meta, keys: PlanetTileBuilder.keys(levels: 0 ... maxLevel, figure: figure)) { key in
            let s = PlanetTileBuilder.sample(key, tileSize: tileSize, border: border, figure: figure, channels: 3) { t in
                pyramid.sample(latitude: t.latitude, longitude: t.longitude, dLatitude: t.dLatitude, dLongitude: t.dLongitude)
            }
            return try ImageFiles.encode(s.map { UInt8(min(255, max(0, $0.isFinite ? $0.rounded() : 0))) },
                                         side: tileSize + 2 * border, channels: 3, png: false, quality: quality)
        }
    }

    /// `PlanetTiles tile FILE (FACE/LEVEL/X/Y | LAT,LON,LEVEL) OUT`: one
    /// tile's payload as it is stored (an image file for image layers), to
    /// look at; LAT,LON (degrees) picks the stored tile there.
    static func extract(_ args: [String]) throws {
        guard args.count == 3 else { throw ToolError("usage: PlanetTiles tile FILE (posX/3/2/5 | 28.6,-80.6,7) OUT") }
        let f = try PlanetTileFile(contentsOf: URL(fileURLWithPath: args[0]))
        let spec = args[1]
        let key: TileKey?
        if spec.contains(",") {
            let p = spec.split(separator: ",").compactMap { Double($0) }
            guard p.count == 3 else { throw ToolError("LAT,LON,LEVEL") }
            key = f.finestTile(containing: figure.figureDirection(latitude: p[0] * .pi / 180, longitude: p[1] * .pi / 180),
                               maxLevel: Int(p[2]))
        } else {
            let p = spec.split(separator: "/")
            guard p.count == 4, let face = CubeSphere.Face.allCases.first(where: { "\($0)" == p[0] }),
                  let l = Int(p[1]), let x = Int(p[2]), let y = Int(p[3]) else { throw ToolError("FACE/LEVEL/X/Y, e.g. posX/3/2/5") }
            key = TileKey(face: face, level: l, x: x, y: y)
        }
        guard let key, let payload = f.payload(key) else { throw ToolError("no such tile in \(args[0])") }
        try payload.write(to: URL(fileURLWithPath: args[2]))
        print("\(key): \(payload.count) bytes to \(args[2])")
    }

    static func info(_ files: [String]) throws {
        for path in files {
            let f = try PlanetTileFile(contentsOf: URL(fileURLWithPath: path))
            let l = f.layout
            print("\(path)")
            print("  \(l.format), \(l.tileSize)² + \(l.border) border, \(l.channels) channels, to level \(l.maxLevel), body \(l.bodyID)")
            var perLevel: [Int: (count: Int, bytes: Int)] = [:]
            for e in f.entries { perLevel[e.key.level, default: (0, 0)].count += 1; perLevel[e.key.level]!.bytes += e.length }
            for level in perLevel.keys.sorted() {
                let p = perLevel[level]!
                print(String(format: "  level %2d: %7d tiles, %8.1f MB, %6.1f KB each", level, p.count, Double(p.bytes) / 1e6,
                             Double(p.bytes) / Double(p.count) / 1e3))
            }
            for k in f.metadata.keys.sorted() { print("  \(k): \(f.metadata[k]!)") }
            try f.verify()
            print("  checksums: all \(f.count) good")
        }
    }
}
