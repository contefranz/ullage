import XCTest
@testable import OrbitCore
@testable import OrbitScene

/// Track E1's pure-Swift parts: the latitude-longitude rasters, the polygon
/// rasteriser, the tile builder's sampling and seams, relief normals, the
/// TIFF reader, the transverse Mercator projection.
final class PlanetTileBuildTests: XCTestCase {
    let deg = Double.pi / 180

    /// A float raster of `f(lat, lon)` (degrees) at its pixel centres.
    func raster(width: Int, _ f: (Double, Double) -> Double) -> GeoRaster {
        let g = GeoGrid.global(width: width)
        let r = GeoRaster(grid: g, channels: 1, type: .float32)
        for row in 0 ..< g.height {
            for c in 0 ..< g.width {
                r.setRaw(c, row, 0, Float(f(g.north - (Double(row) + 0.5) * g.pixelHeight,
                                            g.west + (Double(c) + 0.5) * g.pixelWidth)))
            }
        }
        return r
    }

    // MARK: Rasters

    func testBilinearInterpolatesAndWrapsLongitude() {
        // Linear in latitude: bilinear is exact between pixel centres.
        let r = raster(width: 360) { lat, _ in lat }
        let p = r.grid.position(latitudeDegrees: 12.25, longitudeDegrees: 33.7)
        XCTAssertEqual(r.bilinear(x: p.x, y: p.y)[0], 12.25, accuracy: 1e-4)
        // Across the antimeridian: columns 359 and 0 blend.
        let s = raster(width: 360) { _, lon in lon < 0 ? 1 : 0 }
        let q = s.grid.position(latitudeDegrees: 0, longitudeDegrees: 180)
        XCTAssertEqual(s.bilinear(x: q.x, y: q.y)[0], 0.5, accuracy: 1e-6)
    }

    func testHalvingAveragesBlocksAndSkipsNoData() {
        let g = GeoGrid.global(width: 4)
        let r = GeoRaster(grid: g, channels: 1, type: .float32)
        for (k, v) in [1, 2, 3, 4, 5, 6, 7, 8].enumerated() { r.setRaw(k % 4, k / 4, 0, Float(v)) }
        r.noData = 8
        let h = r.halved()
        XCTAssertEqual(h.grid.width, 2)
        XCTAssertEqual(h.raw(0, 0), (1 + 2 + 5 + 6) / 4)
        XCTAssertEqual(h.raw(1, 0), (3 + 4 + 7) / 3)
    }

    func testRasterFileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("osrastr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("r.osrastr").path
        let grid = GeoGrid(width: 5, height: 3, west: 10, north: 50, pixelWidth: 0.5, pixelHeight: 0.25)
        do {
            let w = try GeoRasterFile.create(path: path, grid: grid, channels: 2, type: .int16, scale: 0.5, noData: -9999)
            for row in 0 ..< 3 { for c in 0 ..< 5 { w.setRaw(c, row, 1, Float(row * 10 + c)) } }
        }
        let r = try GeoRasterFile.open(path: path)
        XCTAssertEqual(r.grid, grid)
        XCTAssertEqual(r.channels, 2)
        XCTAssertEqual(r.type, .int16)
        XCTAssertEqual(r.noData, -9999)
        XCTAssertEqual(r.value(4, 2, 1), 12, "raw 24 × scale 0.5")
    }

    func testFootprintSamplingAveragesWhatATexelCovers() {
        // A checkerboard of single pixels averages to ½ over a wide footprint,
        // and reads 0 or 1 over a narrow one.
        let r = raster(width: 1024) { lat, lon in
            (Int(((lon + 180) / (360.0 / 1024)).rounded(.down)) + Int(((90 - lat) / (360.0 / 1024)).rounded(.down))) % 2 == 0 ? 1 : 0
        }
        let p = GeoRasterPyramid(r)
        let wide = p.sample(latitude: 10 * deg, longitude: 20 * deg, dLatitude: 4 * deg, dLongitude: 4 * deg)
        XCTAssertEqual(wide[0], 0.5, accuracy: 0.02)
        let cell = 360.0 / 1024
        let narrow = p.sample(latitude: (90 - 100.5 * cell) * deg, longitude: (-180 + 200.5 * cell) * deg,
                              dLatitude: 0.1 * cell * deg, dLongitude: 0.1 * cell * deg)
        XCTAssertEqual(narrow[0], 1, accuracy: 1e-5)
        // Near the pole a texel spans more longitude than latitude: taps along it.
        let polar = p.sample(latitude: 85 * deg, longitude: 0, dLatitude: 0.5 * deg, dLongitude: 6 * deg)
        XCTAssertEqual(polar[0], 0.5, accuracy: 0.05)
    }

    // MARK: Polygons

    func testPolygonCoverageAreaHolesAndEdges() {
        let grid = GeoGrid(width: 100, height: 100, west: 0, north: 10, pixelWidth: 0.1, pixelHeight: 0.1)
        // A 4° × 3° box with a 1° × 1° hole, its edges off the pixel grid.
        func ring(_ w: Double, _ s: Double, _ e: Double, _ n: Double) -> [GeoPoint] {
            [GeoPoint(longitude: w, latitude: s), GeoPoint(longitude: e, latitude: s),
             GeoPoint(longitude: e, latitude: n), GeoPoint(longitude: w, latitude: n)]
        }
        let box = GeoPolygon(rings: [ring(2.03, 3.07, 6.03, 6.07), ring(3.55, 4.55, 4.55, 5.55)])
        let cover = PolygonRasterizer.coverage([box], on: grid, subRows: 8)
        var area = 0.0
        for r in 0 ..< 100 { for c in 0 ..< 100 { area += Double(cover.value(c, r)) * 0.01 } }
        XCTAssertEqual(area, 4 * 3 - 1, accuracy: 0.02, "deg² (pixel 0.01 deg²)")
        func at(_ lon: Double, _ lat: Double) -> Float {
            let p = grid.position(latitudeDegrees: lat, longitudeDegrees: lon)
            return cover.value(Int(p.x), Int(p.y))
        }
        XCTAssertEqual(at(2.5, 3.5), 1)
        XCTAssertEqual(at(4.0, 5.0), 0, "inside the hole")
        XCTAssertEqual(at(1.5, 3.5), 0)
        // The west edge at 2.03 cuts column 20 (2.0-2.1) at 70 %.
        XCTAssertEqual(at(2.05, 4.0), 0.7, accuracy: 0.01)
        // An island in the hole is inside again (even-odd).
        let island = GeoPolygon(rings: [ring(3.85, 4.85, 4.25, 5.25)])
        let both = PolygonRasterizer.coverage([box, island], on: grid)
        let p = grid.position(latitudeDegrees: 5.0, longitudeDegrees: 4.0)
        XCTAssertEqual(both.value(Int(p.x), Int(p.y)), 1)
    }

    /// The Earth's water: a modern lake inside its 1960s outline, both on
    /// land, is water in both; filled in one even-odd pass, the modern lake
    /// would be a hole (land).
    func testWaterMaskTakesNestedLakesAsWater() {
        let grid = GeoGrid(width: 100, height: 100, west: 0, north: 10, pixelWidth: 0.1, pixelHeight: 0.1)
        func box(_ w: Double, _ s: Double, _ e: Double, _ n: Double) -> GeoPolygon {
            GeoPolygon(rings: [[GeoPoint(longitude: w, latitude: s), GeoPoint(longitude: e, latitude: s),
                                GeoPoint(longitude: e, latitude: n), GeoPoint(longitude: w, latitude: n)]])
        }
        let land = [box(1, 1, 9, 9)], historic = [box(3, 3, 7, 7)], modern = [box(4, 4, 5, 5), box(5.5, 5.5, 6.5, 6.5)]
        let water = WaterMask.rasterize(land: land, waters: [modern, historic], on: grid)
        func at(_ lon: Double, _ lat: Double) -> Float {
            let p = grid.position(latitudeDegrees: lat, longitudeDegrees: lon)
            return water.value(Int(p.x), Int(p.y))
        }
        XCTAssertEqual(at(0.5, 0.5), 1, "open sea")
        XCTAssertEqual(at(2, 2), 0, "land")
        XCTAssertEqual(at(3.5, 3.5), 1, "the 1960s lake")
        XCTAssertEqual(at(4.5, 4.5), 1, "a modern lake inside it")
        XCTAssertEqual(at(6, 6), 1, "another")
        // The one-pass fill this replaces gets the nested lakes wrong.
        let onePass = PolygonRasterizer.coverage(modern + historic, on: grid)
        let p = grid.position(latitudeDegrees: 4.5, longitudeDegrees: 4.5)
        XCTAssertEqual(onePass.value(Int(p.x), Int(p.y)), 0)
    }

    /// A work raster is reused only when its build finished: an interrupted
    /// one leaves no file under its name, and a stale .partial is ignored.
    func testRasterBuildsReuseOnlyCompleteFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("osrastr-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("bmng-7-0.osrastr").path
        let grid = GeoGrid(width: 8, height: 4, west: -180, north: 90, pixelWidth: 45, pixelHeight: 45)
        struct Interrupted: Error {}
        // Interrupted half-way: rows 0-1 written, then the build stops.
        XCTAssertThrowsError(try GeoRasterFile.build(path: path, grid: grid, channels: 1, type: .uint8) { r in
            for x in 0 ..< 8 { r.setRaw(x, 0, 0, 9); r.setRaw(x, 1, 0, 9) }
            throw Interrupted()
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        // A killed run's .partial, half filled, is not taken for a mosaic.
        let stale = try GeoRasterFile.create(path: path + ".partial", grid: grid, channels: 1, type: .uint8)
        stale.setRaw(0, 0, 0, 9)
        var filled = 0
        let (r, reused) = try GeoRasterFile.build(path: path, grid: grid, channels: 1, type: .uint8) { r in
            for y in 0 ..< 4 { for x in 0 ..< 8 { r.setRaw(x, y, 0, Float(y * 8 + x)) } }
            filled += 1
        }
        XCTAssertFalse(reused)
        XCTAssertEqual(filled, 1)
        XCTAssertEqual(r.raw(7, 3), 31)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".partial"))
        // Complete: the next build reuses it without filling.
        let again = try GeoRasterFile.build(path: path, grid: grid, channels: 1, type: .uint8) { _ in filled += 1 }
        XCTAssertTrue(again.reused)
        XCTAssertEqual(filled, 1)
        XCTAssertEqual(again.raster.raw(7, 3), 31)
        // Another shape is rebuilt.
        let other = try GeoRasterFile.build(path: path, grid: grid, channels: 3, type: .uint8) { _ in filled += 1 }
        XCTAssertFalse(other.reused)
        XCTAssertEqual(filled, 2)
    }

    func testGeoJSONReadsPolygonsAndMultiPolygonsWithProperties() throws {
        let json = """
        {"type":"FeatureCollection","features":[
         {"type":"Feature","properties":{"name":"Aral Sea","scalerank":3},
          "geometry":{"type":"Polygon","coordinates":[[[58,43],[62,43],[62,47],[58,43]]]}},
         {"type":"Feature","properties":{"name":"Lop Nur"},
          "geometry":{"type":"MultiPolygon","coordinates":[[[[90,40],[91,40],[91,41],[90,40]]],[[[92,40],[93,40],[93,41],[92,40]]]]}},
         {"type":"Feature","properties":{"name":"x"},"geometry":{"type":"Point","coordinates":[1,2]}}]}
        """
        let all = try GeoJSON.polygons(Data(json.utf8))
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0].properties["scalerank"], "3")
        let aral = try GeoJSON.polygons(Data(json.utf8)) { $0["name"] == "Aral Sea" }
        XCTAssertEqual(aral.count, 1)
        XCTAssertEqual(aral[0].bounds.east, 62)
    }

    // MARK: Tiles

    /// A smooth field of figure direction, in 0.1...0.9.
    func field(_ d: Vec3) -> Double { 0.5 + 0.25 * d.x * d.z + 0.15 * sin(3 * d.y) }

    /// The whole pyramid to `maxLevel`, sampled from `field`, as an 8-bit file.
    func fieldFile(maxLevel: Int, n: Int = 16, b: Int = 2) throws -> PlanetTileFile {
        let layout = PlanetTileLayout(format: .uint8, tileSize: n, border: b, maxLevel: maxLevel, bodyID: 399,
                                      figure: .wgs84, scale: 1.0 / 255)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("field-\(UUID().uuidString).ostiles")
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try PlanetTileWriter(url: url, layout: layout, metadata: ["source": "synthetic", "tool": "test"])
        let keys = PlanetTileBuilder.keys(levels: 0 ... maxLevel, figure: .wgs84)
        XCTAssertEqual(keys.count, (0 ... maxLevel).map { CubeSphere.tileCount(level: $0) }.reduce(0, +))
        try PlanetTileBuilder.build(keys, make: { key in
            PlanetTileBuilder.sample(key, tileSize: n, border: b, figure: .wgs84, channels: 1) { t in
                SIMD4(Float(self.field(t.direction)), 0, 0, 0)
            }
        }, write: { key, values in
            try w.add(key, values: values.map { Double($0) })
        })
        try w.finish()
        return try PlanetTileFile(data: Data(contentsOf: url))
    }

    func testBuiltTilesRoundTripAndMatchTheField() throws {
        let file = try fieldFile(maxLevel: 3)
        XCTAssertNoThrow(try file.verify())
        XCTAssertEqual(file.metadata["source"], "synthetic")
        var rng = SystemRandomNumberGenerator()
        var worst = 0.0
        for _ in 0 ..< 2_000 {
            let d = Vec3(Double.random(in: -1 ... 1, using: &rng), Double.random(in: -1 ... 1, using: &rng),
                         Double.random(in: -1 ... 1, using: &rng)).normalized
            for level in 0 ... 3 {
                let v = try XCTUnwrap(file.value(at: d, maxLevel: level))
                worst = max(worst, abs(v - field(d)))
            }
        }
        // Quantisation (1/510) plus bilinear error over a level-0 texel (5.6°).
        XCTAssertLessThan(worst, 0.006)
    }

    func testBordersRepeatTheNeighboursWithinAFaceAndAgreeAcrossFaceEdges() throws {
        let n = 16, b = 2, level = 2
        let file = try fieldFile(maxLevel: level, n: n, b: b)
        // Within a face: a border texel holds exactly the neighbour's texel.
        let key = TileKey(face: .posY, level: level, x: 1, y: 2)
        let tile = try XCTUnwrap(file.tile(key))
        let right = try XCTUnwrap(file.tile(key.neighbor(.maxU)))
        for j in 0 ..< n + 2 * b {
            for i in 0 ..< b {
                // Column n + b + i of this tile is column b + i of the next.
                XCTAssertEqual(tile.raw(column: n + b + i, row: j), right.raw(column: b + i, row: j))
            }
        }
        // Across every face edge: values read through the border on one side
        // match those read inside the tile on the other.
        var worst = 0.0
        for face in CubeSphere.Face.allCases {
            for x in 0 ..< 1 << level {
                let k = TileKey(face: face, level: level, x: x, y: (1 << level) - 1)
                let (other, _) = k.neighborAndEdge(.maxV)
                let a = try XCTUnwrap(file.tile(k)), o = try XCTUnwrap(file.tile(other))
                for s in stride(from: 0.05, through: 0.95, by: 0.1) {
                    // Just across the edge, on the other face.
                    let d = k.direction(localU: s, localV: 1 + 0.5 / Double(n))
                    let viaBorder = try XCTUnwrap(a.value(at: d)), inside = try XCTUnwrap(o.value(at: d))
                    worst = max(worst, abs(viaBorder - inside))
                    XCTAssertEqual(CubeSphere.faceCoordinates(d).face, other.face)
                }
            }
        }
        XCTAssertLessThan(worst, 0.006)
    }

    func testRegionKeysAreTheTilesThatTouchIt() {
        let cape = GeoRegion(south: 28.3, north: 28.85, west: -80.85, east: -80.45)
        let keys = PlanetTileBuilder.keys(levels: 8 ... 10, region: cape, figure: .wgs84)
        XCTAssertFalse(keys.isEmpty)
        let lc39 = Ellipsoid.wgs84.figureDirection(latitude: 28.608 * deg, longitude: -80.604 * deg)
        for level in 8 ... 10 { XCTAssertTrue(keys.contains(TileKey.containing(lc39, level: level))) }
        XCTAssertTrue(keys.allSatisfy { $0.face == .negY })
        // About 60 × 40 km over level-10 tiles of about 9.8 km: a few dozen.
        XCTAssertLessThan(keys.filter { $0.level == 10 }.count, 80)
        XCTAssertTrue(cape.contains(latitude: 28.5, longitude: -80.6))
        XCTAssertFalse(cape.contains(latitude: 28.5, longitude: 99.4))
        XCTAssertTrue(GeoRegion(south: 0, north: 1, west: 179, east: -179).contains(latitude: 0.5, longitude: -179.5))
    }

    func testTexelFootprintsMatchTheTexelSize() {
        let n = 64, b = 4
        let key = TileKey(face: .posX, level: 3, x: 3, y: 4)
        let texels = PlanetTileBuilder.texels(of: key, tileSize: n, border: b, figure: .wgs84)
        XCTAssertEqual(texels.count, (n + 2 * b) * (n + 2 * b))
        let nominal = CubeSphere.tileAngle(level: 3) / Double(n)
        for t in texels {
            XCTAssertGreaterThan(max(t.dLatitude, t.dLongitude * cos(t.latitude)), nominal * 0.5)
            XCTAssertLessThan(max(t.dLatitude, t.dLongitude * cos(t.latitude)), nominal * 2)
        }
        // Row j runs along u: the next texel in a row is the next column.
        XCTAssertEqual(texels[1].column, 1)
        XCTAssertEqual(texels[n + 2 * b].row, 1)
    }

    // MARK: Relief

    func testReliefNormalsOfASlopeAndTheirEncoding() {
        let f = Ellipsoid.wgs84
        // A plane rising 1 m per 100 m to the east (in ground distance).
        let lat0 = 30 * deg
        let n = f.primeVerticalRadius(latitude: lat0) * cos(lat0)
        let normal = ReliefNormals.normal(latitude: lat0, longitude: 0.3, step: 500, figure: f) { _, lon in
            (lon - 0.3) * n * 0.01
        }
        XCTAssertEqual(normal.x, -0.01 / (1 + 0.0001).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(normal.y, 0, accuracy: 1e-9)
        // North-facing slope: heights falling to the north tilt the normal north.
        let m = ReliefNormals.meridionalRadius(f, latitude: lat0)
        let north = ReliefNormals.normal(latitude: lat0, longitude: 0, step: 500, figure: f) { lat, _ in
            -(lat - lat0) * m * 0.1
        }
        XCTAssertEqual(north.y, 0.1 / (1.01).squareRoot(), accuracy: 1e-6)
        let (r, g, bb) = ReliefNormals.encode(Vec3(0, 0, 1))
        XCTAssertEqual([r, g, bb], [128, 128, 255])
        let back = ReliefNormals.decode(r, g, bb)
        XCTAssertEqual(back.z, 1, accuracy: 1e-9)
        XCTAssertEqual(back.x, 0, accuracy: 0.004)
    }

    // MARK: TIFF

    /// 37 × 11 RGB, written by macOS's `tiffutil -lzw`: big-endian, LZW,
    /// horizontal predictor (its ICC profile stripped). Pixel (x, y) is
    /// ((7x + 3y) % 256, (x² + y) % 256, (40⌊x/4⌋ + 20y) % 256).
    static let lzwTIFF = """
    TU0AKgAAAiCAACBAcAgADgODAWDAcUAcEwYFwYGwYHw0IwYJwYKwYLw0MwYNwYOwYPw0QwYRwYSwYTw0UwYVwYWwYXw0YwYZwYaw\
    Ybw0cwYdwYewYfw0gwYhwYiwYjigBgEKQSDQgDwoDwyHRCJRSLRiNRyPSCRSSTSiVSyXTCZTSbTidTyfUChUSjUilUwUAYBQ2Cwe\
    EwuGw8DxEDxMDxUDxcDxkDxsDx0Dx8DyEDyMDyUDycDykDysDy0Dy8DzEDzMDzUDzcDzkDzsDz0Dz8D0ED0MD0UD0cD0kD0sD00E\
    gMeVK/VXAVnB1vD13F1/H2HJ2PL2XN2fP2nR2vT23V2/X3HZ3Pb3Xd3ffigGAQocSqVasYLCYbEYrGY7IZLKZbMZrOZ7QNE0jTNQ\
    1TWNc2DZNo2zcN03jfKaB4CjI9i/quwKtMKrjEq8xqwMisTKrIzKzM6tDQrU0q2NStzWrg2K5Nqujcrs3q8AkAw8Qm40KuQ+MMvo\
    5z7w+/TqP7EsAO1AcVwM8EExjBjzKaCoDkZHL3Qs5MMOXDTmw458POjEDpxE6sSOvEzsxQ7cVO7Fjvxc8MYPHGTyxo84MAQUEquO\
    +DlPnDb7Og/MQv46z/xPATuQLFsEPFBcZwcFANgSWk9R3Pksz9LlAS/QUxUJMtDTRRE10VN1GTjR06UgDwFGRSr3wu+TmPrDr8Ok\
    /cRv87EAxTAjvQPF8FPJBq8ICAARAQAAAwAAAAEAJQAAAQEAAwAAAAEACwAAAQIAAwAAAAMAAAMOAQMAAwAAAAEABQAAAQYAAwAA\
    AAEAAgAAAQoAAwAAAAEAAQAAAREABAAAAAEAAAAIARIAAwAAAAEAAQAAARUAAwAAAAEAAwAAARYAAwAAAAEACwAAARcABAAAAAEA\
    AAIYARoABQAAAAEAAAL+ARsABQAAAAEAAAMGARwAAwAAAAEAAQAAASgAAwAAAAEAAgAAAT0AAwAAAAEAAgAAAVMAAwAAAAMAAAMU\
    AAAAAAAAAAAAAAAAAAAAAAAAAEgAAAABAAAASAAAAAEACAAIAAgAAQABAAE=
    """

    func testLZWBigEndianTIFFWithPredictor() throws {
        let data = try XCTUnwrap(Data(base64Encoded: Self.lzwTIFF))
        let t = try TIFFImage(data: data)
        XCTAssertEqual([t.width, t.height, t.samplesPerPixel, t.compression, t.predictor], [37, 11, 3, 5, 2])
        let r = GeoRaster(grid: GeoGrid(width: 37, height: 11, west: 0, north: 0, pixelWidth: 1, pixelHeight: 1),
                          channels: 3, type: .uint8)
        try t.read(into: r)
        for y in 0 ..< 11 {
            for x in 0 ..< 37 {
                XCTAssertEqual(r.raw(x, y, 0), Float((7 * x + 3 * y) % 256))
                XCTAssertEqual(r.raw(x, y, 1), Float((x * x + y) % 256))
                XCTAssertEqual(r.raw(x, y, 2), Float((x / 4 * 40 + y * 20) % 256))
            }
        }
    }

    /// A little-endian TIFF of `samples` (one channel), uncompressed, in
    /// `tile`² tiles or one-row strips, with the predictor applied.
    func makeTIFF(width: Int, height: Int, bits: Int, format: Int, predictor: Int, tile: Int?,
                  geo: (west: Double, north: Double, step: Double)? = nil, sample: (Int, Int) -> [UInt8]) -> Data {
        let bytes = bits / 8
        let bw = tile ?? width, bh = tile ?? 1
        let across = (width + bw - 1) / bw, down = (height + bh - 1) / bh
        var blocks: [Data] = []
        for by in 0 ..< down {
            for bx in 0 ..< across {
                var block = [UInt8]()
                for r in 0 ..< bh {
                    var row = [UInt8]()
                    for c in 0 ..< bw {
                        let x = bx * bw + c, y = by * bh + r
                        row += x < width && y < height ? sample(x, y) : [UInt8](repeating: 0, count: bytes)
                    }
                    if predictor == 2 && bytes == 2 {
                        var v = stride(from: 0, to: row.count, by: 2).map { UInt16(row[$0]) | UInt16(row[$0 + 1]) << 8 }
                        for i in stride(from: v.count - 1, to: 0, by: -1) { v[i] = v[i] &- v[i - 1] }
                        row = v.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
                    } else if predictor == 3 {
                        // Byte planes, most significant first, then differenced.
                        let count = row.count / bytes
                        var planes = [UInt8](repeating: 0, count: row.count)
                        for k in 0 ..< count { for p in 0 ..< bytes { planes[p * count + k] = row[k * bytes + bytes - 1 - p] } }
                        for i in stride(from: planes.count - 1, to: 0, by: -1) { planes[i] = planes[i] &- planes[i - 1] }
                        row = planes
                    }
                    block += row
                }
                blocks.append(Data(block))
            }
        }
        var entries: [(UInt16, UInt16, UInt32, UInt32)] = []
        var extra = Data()
        let headerAndIFD = 8 + 2 + 12 * 16 + 4
        func later(_ d: Data) -> UInt32 { let o = UInt32(headerAndIFD + extra.count); extra.append(d); return o }
        func doubles(_ v: [Double]) -> Data { Data(v.flatMap { withUnsafeBytes(of: $0.bitPattern.littleEndian, Array.init) }) }
        func longs(_ v: [Int]) -> Data { Data(v.flatMap { withUnsafeBytes(of: UInt32($0).littleEndian, Array.init) }) }
        let dataStart = headerAndIFD + 4096
        var offsets: [Int] = [], o = dataStart
        for b in blocks { offsets.append(o); o += b.count }
        entries.append((256, 4, 1, UInt32(width)))
        entries.append((257, 4, 1, UInt32(height)))
        entries.append((258, 3, 1, UInt32(bits)))
        entries.append((259, 3, 1, 1))
        entries.append((262, 3, 1, 1))
        entries.append((277, 3, 1, 1))
        entries.append((284, 3, 1, 1))
        entries.append((317, 3, 1, UInt32(predictor)))
        entries.append((339, 3, 1, UInt32(format)))
        if let tile {
            entries.append((322, 3, 1, UInt32(tile)))
            entries.append((323, 3, 1, UInt32(tile)))
            entries.append((324, 4, UInt32(blocks.count), blocks.count == 1 ? UInt32(offsets[0]) : later(longs(offsets))))
            entries.append((325, 4, UInt32(blocks.count), blocks.count == 1 ? UInt32(blocks[0].count) : later(longs(blocks.map(\.count)))))
        } else {
            entries.append((273, 4, UInt32(blocks.count), later(longs(offsets))))
            entries.append((278, 3, 1, 1))
            entries.append((279, 4, UInt32(blocks.count), later(longs(blocks.map(\.count)))))
        }
        if let geo {
            entries.append((33550, 12, 3, later(doubles([geo.step, geo.step, 0]))))
            entries.append((33922, 12, 6, later(doubles([0, 0, 0, geo.west, geo.north, 0]))))
        }
        entries.sort { $0.0 < $1.0 }
        var d = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        put(UInt16(entries.count))
        for e in entries {
            put(e.0); put(e.1); put(e.2)
            if e.1 == 3 && e.2 == 1 { put(UInt16(e.3)); put(UInt16(0)) } else { put(e.3) }
        }
        put(UInt32(0))
        d.append(Data(count: headerAndIFD - d.count))
        d.append(extra)
        d.append(Data(count: dataStart - d.count))
        for b in blocks { d.append(b) }
        return d
    }

    func testTiledFloatTIFFWithFloatingPointPredictorAndGeoGrid() throws {
        // ETOPO 2022's layout: float32, 256² tiles (here 16²), predictor 3.
        func h(_ x: Int, _ y: Int) -> Float { Float(x * 100 - y * 37) + 0.25 }
        let data = makeTIFF(width: 40, height: 20, bits: 32, format: 3, predictor: 3, tile: 16,
                            geo: (west: -180, north: 90, step: 9)) { x, y in
            withUnsafeBytes(of: h(x, y).bitPattern.littleEndian, Array.init)
        }
        let t = try TIFFImage(data: data)
        XCTAssertTrue(t.isTiled)
        XCTAssertEqual(t.blockCount, 3 * 2)
        let grid = try XCTUnwrap(t.geoGrid)
        XCTAssertEqual(grid, GeoGrid(width: 40, height: 20, west: -180, north: 90, pixelWidth: 9, pixelHeight: 9))
        XCTAssertTrue(grid.wrapsLongitude)
        let r = GeoRaster(grid: grid, channels: 1, type: .float32)
        try t.read(into: r)
        for y in 0 ..< 20 { for x in 0 ..< 40 { XCTAssertEqual(r.raw(x, y), h(x, y)) } }
    }

    func testStripUInt16TIFFWithHorizontalPredictor() throws {
        // Landsat bands: uint16 with predictor 2.
        func v(_ x: Int, _ y: Int) -> UInt16 { UInt16((x * 977 + y * 31_337) % 65_536) }
        let data = makeTIFF(width: 23, height: 7, bits: 16, format: 1, predictor: 2, tile: nil) { x, y in
            withUnsafeBytes(of: v(x, y).littleEndian, Array.init)
        }
        let t = try TIFFImage(data: data)
        let r = GeoRaster(grid: GeoGrid(width: 23, height: 7, west: 0, north: 0, pixelWidth: 1, pixelHeight: 1),
                          channels: 1, type: .uint16)
        try t.read(into: r)
        for y in 0 ..< 7 { for x in 0 ..< 23 { XCTAssertEqual(r.raw(x, y), Float(v(x, y))) } }
        XCTAssertThrowsError(try TIFFImage(data: Data("not a tiff".utf8)))
    }

    // MARK: Transverse Mercator

    func testTransverseMercatorAgainstSnyder() {
        // Snyder 1987, "Map Projections: A Working Manual", p. 269: Clarke
        // 1866, φ 40°30' N, λ 73°30' W, λ0 75° W, k0 0.9996 gives
        // x = 127,106.5 m, y = 4,484,124.4 m.
        let clarke = Ellipsoid(equatorialRadius: 6_378_206.4, inverseFlattening: 294.978_698_2)
        let tm = TransverseMercator(figure: clarke, centralMeridian: -75 * deg, scale: 0.9996)
        let p = tm.forward(latitude: 40.5 * deg, longitude: -73.5 * deg)
        XCTAssertEqual(p.easting, 127_106.5, accuracy: 0.2)
        XCTAssertEqual(p.northing, 4_484_124.4, accuracy: 0.2)
    }

    func testUTMRoundTripsOverTheCapeScene() {
        let utm = TransverseMercator.utm(zone: 17)
        for (lat, lon) in [(28.608, -80.604), (27.8, -82.4), (29.9, -80.07), (0.0, -81.0), (60.0, -78.5)] {
            let p = utm.forward(latitude: lat * deg, longitude: lon * deg)
            let g = utm.inverse(easting: p.easting, northing: p.northing)
            XCTAssertEqual(g.latitude / deg, lat, accuracy: 1e-9)
            XCTAssertEqual(g.longitude / deg, lon, accuracy: 1e-9)
        }
        // On the central meridian (81° W) the easting is the false easting.
        XCTAssertEqual(utm.forward(latitude: 28.5 * deg, longitude: -81 * deg).easting, 500_000, accuracy: 1e-6)
        // LC-39A is about 39.5 km east of it.
        XCTAssertEqual(utm.forward(latitude: 28.608 * deg, longitude: -80.604 * deg).easting, 538_700, accuracy: 300)
    }
}

/// The tile cache's bookkeeping (PlanetTileIndirection, PlanetTileResidency,
/// PlanetTileWants) and the ground-track prediction it prefetches along.
final class PlanetTileResidencyTests: XCTestCase {
    let deg = Double.pi / 180

    /// The finest resident tile at `level` or coarser that holds `d`, by brute force.
    func expected(_ resident: [TileKey: Int], _ d: Vec3, level: Int) -> (TileKey, Int)? {
        for l in stride(from: level, through: 0, by: -1) {
            let k = TileKey.containing(d, level: l)
            if let s = resident[k] { return (k, s) }
        }
        return nil
    }

    func testHashTableMatchesADictionaryUnderInsertsAndRemovals() {
        var table = TileHashTable(capacity: 64)
        var truth: [UInt64: UInt32] = [:]
        var rng = SystemRandomNumberGenerator()
        for step in 0 ..< 5_000 {
            let id = TileKey(face: .negY, level: 12, x: Int.random(in: 1000 ..< 1040, using: &rng),
                             y: Int.random(in: 2000 ..< 2002, using: &rng)).id
            if truth.count < 30 && Bool.random(using: &rng) {
                table.insert(id, UInt32(step)); truth[id] = UInt32(step)
            } else {
                table.remove(id); truth[id] = nil
            }
            XCTAssertEqual(table.count, truth.count)
        }
        for x in 1000 ..< 1040 {
            for y in 2000 ..< 2002 {
                let id = TileKey(face: .negY, level: 12, x: x, y: y).id
                XCTAssertEqual(table.find(id), truth[id])
            }
        }
    }

    func testIndirectionLookupIsTheFinestResidentAncestor() {
        // Texture to level 3, deep table to level 6.
        var ind = PlanetTileIndirection(maxLevel: 6, slots: 64, maxTextureLevel: 3)
        XCTAssertEqual(ind.textureLevels, 4)
        var resident: [TileKey: Int] = [:]
        var slot = 0
        func add(_ k: TileKey) { ind.insert(k, slot: slot); resident[k] = slot; slot += 1 }
        for r in TileKey.roots { add(r) }
        // A chain down to level 6 near LC-39, and some siblings.
        let lc39 = Ellipsoid.wgs84.figureDirection(latitude: 28.6 * deg, longitude: -80.6 * deg)
        for l in 1 ... 6 { add(TileKey.containing(lc39, level: l)) }
        add(TileKey.containing(lc39, level: 2).neighbor(.minU))
        add(TileKey.containing(lc39, level: 5).neighbor(.maxV))
        var rng = SystemRandomNumberGenerator()
        func check() {
            for _ in 0 ..< 3_000 {
                // Points near the chain and anywhere.
                let near = Bool.random(using: &rng)
                let d = near ? (lc39 + Vec3(Double.random(in: -0.02 ... 0.02, using: &rng),
                                            Double.random(in: -0.02 ... 0.02, using: &rng),
                                            Double.random(in: -0.02 ... 0.02, using: &rng))).normalized
                    : Vec3(Double.random(in: -1 ... 1, using: &rng), Double.random(in: -1 ... 1, using: &rng),
                           Double.random(in: -1 ... 1, using: &rng)).normalized
                let level = Int.random(in: 0 ... 6, using: &rng)
                let got = ind.lookup(d, level: level)
                let want = expected(resident, d, level: level)
                XCTAssertEqual(got?.key, want?.0)
                XCTAssertEqual(got?.slot, want?.1)
            }
        }
        check()
        // Remove leaves from the bottom up, checking each time.
        for l in stride(from: 6, through: 4, by: -1) {
            let k = TileKey.containing(lc39, level: l)
            if l == 5 { let s = k.neighbor(.maxV); ind.remove(s); resident[s] = nil }
            if l == 4 { continue }
            ind.remove(k); resident[k] = nil
            check()
        }
        let (regions, hash) = ind.takeDirty()
        XCTAssertTrue(hash, "the deep table changed")
        XCTAssertFalse(regions.isEmpty)
        XCTAssertTrue(ind.takeDirty().regions.isEmpty)
    }

    func testResidencyKeepsParentsFirstEvictsLeavesAndQuarantinesSlots() {
        var r = PlanetTileResidency(slots: 12, maxLevel: 4, pinnedLevel: 0)
        r.beginFrame(1, completedThrough: nil)
        for k in TileKey.roots { XCTAssertNotNil(r.admit(k, current: true)) }
        let a = TileKey(face: .posX, level: 1, x: 0, y: 0)
        let a1 = a.children[0]
        XCTAssertFalse(r.canAdmit(a1), "parent not resident")
        XCTAssertNotNil(r.admit(a, current: true))
        XCTAssertNotNil(r.admit(a1, current: true))
        XCTAssertNil(r.validate())
        // Fill the rest; then a new frame wants none of the level-1 tiles.
        let others = a.neighbor(.maxU)
        for k in [others, others.neighbor(.maxV), a.neighbor(.maxV), a1.neighbor(.maxU)] {
            XCTAssertNotNil(r.admit(k, current: true), "\(k)")
        }
        XCTAssertEqual(r.freeCount, 0)
        r.beginFrame(2, completedThrough: 0)
        for k in TileKey.roots { r.touch(k, current: true) }
        let evicted = r.reserve(2)
        XCTAssertEqual(evicted.count, 2)
        // Leaves only: a1's parent a stays while a1 does.
        for k in evicted { XCTAssertFalse(r.residentKeys.contains { k.contains($0) && $0 != k }) }
        XCTAssertNil(r.validate())
        XCTAssertEqual(r.quarantinedCount, 2)
        XCTAssertEqual(r.freeCount, 0, "not free until the GPU is past frame 2")
        r.beginFrame(3, completedThrough: 1)
        XCTAssertEqual(r.freeCount, 0)
        r.beginFrame(4, completedThrough: 2)
        XCTAssertEqual(r.freeCount, 2)
        // Pinned roots are never evicted.
        r.beginFrame(10, completedThrough: 9)
        while r.reserve(r.slotCount).count > 0 {}
        XCTAssertEqual(Set(r.residentKeys), Set(TileKey.roots))
        XCTAssertNil(r.validate())
    }

    func testCurrentTilesTakeSlotsFromPrefetchedOnes() {
        var r = PlanetTileResidency(slots: 8, maxLevel: 3, pinnedLevel: 0)
        r.beginFrame(1, completedThrough: nil)
        for k in TileKey.roots { _ = r.admit(k, current: true) }
        let pre = TileKey(face: .negZ, level: 1, x: 1, y: 1)
        _ = r.admit(pre, current: false)
        _ = r.admit(pre.neighbor(.minU), current: false)
        r.beginFrame(2, completedThrough: 1)
        for k in TileKey.roots { r.touch(k, current: true) }
        r.touch(pre, current: false)
        r.touch(pre.neighbor(.minU), current: false)
        // A current tile finds no slot: a prefetched leaf goes, freeing one later.
        let want = TileKey(face: .posZ, level: 1, x: 0, y: 0)
        XCTAssertNil(r.admit(want, current: true))
        XCTAssertEqual(r.quarantinedCount, 1)
        // A prefetched tile never evicts a tile wanted this frame.
        XCTAssertNil(r.admit(TileKey(face: .posZ, level: 1, x: 1, y: 0), current: false))
        XCTAssertEqual(r.quarantinedCount, 1)
        r.beginFrame(3, completedThrough: 2)
        XCTAssertNotNil(r.admit(want, current: true))
        XCTAssertNil(r.validate())
    }

    /// A pass along the parking orbit at warp with a small atlas, the GPU
    /// two frames behind: the invariants hold every frame, no slot is reused
    /// while a frame that saw its old tile is in flight, and the indirection
    /// always finds a tile.
    func testSimulatedFlightKeepsInvariantsAndSlotSafety() {
        let figure = Ellipsoid.wgs84
        let q = PlanetQuadtree(.init(figure: figure, maxLevel: 7, tileBudget: 120))
        var r = PlanetTileResidency(slots: 160, maxLevel: 7, pinnedLevel: 1)
        // Which frame last saw each slot's tile through its indirection.
        var lastSeen: [Int: (frame: UInt64, key: TileKey)] = [:]
        var pending: [TileKey: UInt64] = [:]      // loads finishing at a frame
        let inFlight: UInt64 = 2
        var frame: UInt64 = 0
        var previous: PlanetQuadtree.Selection?
        for step in 0 ..< 400 {
            frame += 1
            let completed = frame > inFlight ? frame - inFlight - 1 : nil
            r.beginFrame(frame, completedThrough: completed)
            // 185 km circular, 30 s of orbit per frame.
            let angle = Double(step) * 30 * 0.00114
            let position = Vec3(cos(angle), sin(angle) * 0.85, sin(angle) * 0.53).normalized * (figure.equatorialRadius + 185_000)
            let forward = (Vec3(-sin(angle), cos(angle) * 0.85, cos(angle) * 0.53).normalized * 0.7 - position.normalized * 0.7).normalized
            let up = forward.cross(position).cross(forward).normalized
            let view = PlanetQuadtree.View(position: position,
                                           frustum: .init(apex: position, forward: forward, up: up, fovY: 50 * deg, aspect: 1.5),
                                           pixelAngle: 50 * deg / 1000, groundSpeed: 7_800, warp: 30, frameInterval: 1.0 / 60)
            let sel = q.select(view, previous: previous)
            previous = sel
            let wants = PlanetTileWants.ordered(sel.tiles) { $0 }
            for k in wants { r.touch(k, current: true) }
            r.reserve(16)
            // Loads complete two frames after their request; at most 16 admitted a frame.
            var admitted = 0
            for k in wants where !r.isResident(k) {
                if let ready = pending[k], ready <= frame, admitted < 16, r.canAdmit(k) {
                    if let s = r.admit(k, current: true) {
                        // The slot's previous tile must be out of every in-flight frame.
                        if let seen = lastSeen[s], seen.key != k {
                            XCTAssertLessThanOrEqual(seen.frame, completed ?? 0, "slot \(s) reused while frame \(seen.frame) may read it")
                        }
                        pending[k] = nil
                        admitted += 1
                    }
                } else if pending[k] == nil {
                    pending[k] = frame + 2
                }
            }
            if let problem = r.validate() { XCTFail(problem); return }
            for (k, s) in r.residentSlot { lastSeen[s] = (frame, k) }
            // The roots load first, so every direction finds a tile from here on.
            if step > 3 {
                for t in sel.tiles.prefix(20) { XCTAssertNotNil(r.indirection.lookup(t.key.centre, level: t.key.level)) }
            }
        }
        XCTAssertGreaterThan(r.takeCounters().evicted, 0, "the atlas was too big to test eviction")
    }

    /// A layer stored to level 7 with an inset to 12 over the Cape: refining
    /// only where tiles are stored keeps the budget for level 7 away from
    /// the Cape (no bias where unrefined refinement would need one), and
    /// still goes to 12 over it.
    func testRefiningOnlyWhereTilesAreStored() {
        let f = Ellipsoid.wgs84
        let inset = Set(PlanetTileBuilder.keys(levels: 8 ... 12, region: GeoRegion(south: 28.3, north: 28.85, west: -80.85,
                                                                                  east: -80.45), figure: f))
        let parents = Set(inset.compactMap(\.parent))
        func q(_ refinable: ((TileKey) -> Bool)?) -> PlanetQuadtree {
            PlanetQuadtree(.init(figure: f, maxLevel: 12, tileBudget: 110, refinable: refinable))
        }
        /// 50 km up, looking east along the horizon, or at `target` (lat, lon).
        func look(lat: Double, lon: Double, at target: (Double, Double)? = nil) -> PlanetQuadtree.View {
            let p = f.bodyFixed(latitude: lat * deg, longitude: lon * deg, height: 50_000)
            let up = f.normal(latitude: lat * deg, longitude: lon * deg)
            let east = Vec3.unitZ.cross(up).normalized
            let forward = target.map { (f.bodyFixed(latitude: $0.0 * deg, longitude: $0.1 * deg, height: 0) - p).normalized } ?? east
            let fr = PlanetQuadtree.Frustum(apex: p, forward: forward, up: up, fovY: 50 * deg, aspect: 3024.0 / 1964)
            return PlanetQuadtree.View(position: p, frustum: fr, pixelAngle: 50 * deg / 1964)
        }
        let stored: (TileKey) -> Bool = { $0.level < 7 || parents.contains($0) }
        // Over the Pacific at 50 km, looking along the horizon.
        let pacific = look(lat: 5, lon: -150)
        let everywhere = q(nil).select(pacific), whereStored = q(stored).select(pacific)
        XCTAssertGreaterThan(everywhere.lodBias, 0, "refining to 12 everywhere overruns the budget")
        XCTAssertEqual(whereStored.lodBias, 0)
        XCTAssertEqual(whereStored.tiles.map(\.key.level).max(), 7)
        // Over the Cape the inset's levels are selected.
        let cape = q(stored).select(look(lat: 28.6, lon: -81.0, at: (28.6, -80.6)))
        XCTAssertGreaterThanOrEqual(cape.tiles.map(\.key.level).max() ?? 0, 10)
        // Deeper than 8 only over the inset or in the balancing ring round it:
        // within a level-8 tile of it.
        let inset8 = inset.filter { $0.level == 8 }
        let deep = cape.tiles.filter { $0.key.level > 8 }
        XCTAssertFalse(deep.isEmpty)
        for t in deep {
            let a = t.key.ancestor(atLevel: 8)
            let near = inset8.contains(a) || TileKey.Edge.allCases.contains { inset8.contains(a.neighbor($0)) }
                || (0 ..< 4).contains { c in a.diagonalNeighbor(corner: c).map { inset8.contains($0.key) } ?? false }
            XCTAssertTrue(near, "\(t.key) away from the inset")
        }
    }

    func testWantsAreCoarseToFineWithAncestors() {
        let a = TileKey(face: .posX, level: 3, x: 2, y: 5), b = TileKey(face: .posX, level: 3, x: 3, y: 5)
        let tiles = [PlanetQuadtree.Tile(key: b, distance: 5, morphStart: 0, morphEnd: 1, seams: 0),
                     PlanetQuadtree.Tile(key: a, distance: 2, morphStart: 0, morphEnd: 1, seams: 0)]
        // The file stops at level 2.
        let w = PlanetTileWants.ordered(tiles) { $0.level > 2 ? $0.ancestor(atLevel: 2) : $0 }
        XCTAssertEqual(w, [a.ancestor(atLevel: 0), a.ancestor(atLevel: 1), a.ancestor(atLevel: 2)])
        let full = PlanetTileWants.ordered(tiles) { $0 }
        XCTAssertEqual(Array(full.suffix(2)), [a, b], "nearest first within a level")
    }

    // MARK: Track prediction

    func testPredictedOrbitAndViewFollowTheTrack() throws {
        let mu = 3.986_004_418e14, radius = 6_378_137.0 + 185_000
        let speed = (mu / radius).squareRoot()
        var p = PlanetTrackPredictor(mu: mu)
        func state(_ t: Double) -> (Vec3, Vec3) {
            let w = speed / radius
            return (Vec3(cos(w * t), sin(w * t), 0) * radius, Vec3(-sin(w * t), cos(w * t), 0) * speed)
        }
        p.observe(time: 0, position: state(0).0)
        p.observe(time: 1.0 / 60, position: state(1.0 / 60).0)
        let v = try XCTUnwrap(p.velocity)
        XCTAssertEqual((v - state(1.0 / 120).1).length, 0, accuracy: 0.01)
        let (r1, _) = p.propagate(state(0).0, state(0).1, 1_000)
        XCTAssertEqual((r1 - state(1_000).0).length, 0, accuracy: 5, "m after 1,000 s")
        // A body that does not spin, the camera looking ahead and down: the
        // view in 600 s looks the same way relative to the track.
        let still = BodyOrientation(icrfToBody: .identity, angularVelocity: .zero)
        let forward = (state(1.0 / 60).1.normalized - state(1.0 / 60).0.normalized).normalized
        let up = state(1.0 / 60).0.normalized
        let now = PlanetQuadtree.View(position: state(1.0 / 60).0,
                                      frustum: .init(apex: state(1.0 / 60).0, forward: forward, up: up, fovY: 0.8, aspect: 1.5),
                                      pixelAngle: 0.001)
        let later = try XCTUnwrap(p.predictedView(after: 600, position: state(1.0 / 60).0, forward: forward, up: up,
                                                  fovY: 0.8, aspect: 1.5, orientation: still, figure: .wgs84, current: now))
        let (r600, v600) = state(600 + 1.0 / 60)
        XCTAssertEqual((later.position - r600).length, 0, accuracy: 10)
        let f600 = (v600.normalized - r600.normalized).normalized
        let expectedFrustum = PlanetQuadtree.Frustum(apex: r600, forward: f600, up: r600.normalized, fovY: 0.8, aspect: 1.5)
        for (a, b) in zip(try XCTUnwrap(later.frustum).normals, expectedFrustum.normals) {
            XCTAssertEqual((a - b).length, 0, accuracy: 1e-5)
        }
    }

    func testPadCameraStaysPutAndJumpsReset() {
        // On the ground the camera turns with the Earth: body-fixed it stays.
        let omega = 7.292_115e-5
        let pad = Ellipsoid.wgs84.bodyFixed(latitude: 28.6 * deg, longitude: -80.6 * deg, height: 50)
        func orientation(_ t: Double) -> BodyOrientation {
            BodyOrientation(icrfToBody: Mat3.rotZ(-omega * t), angularVelocity: Vec3(0, 0, omega))
        }
        var p = PlanetTrackPredictor(mu: 3.986e14)
        for k in 0 ..< 3 {
            let t = Double(k) / 60
            p.observe(time: t, position: orientation(t).toInertial(pad))
        }
        let t = 2.0 / 60
        let up = orientation(t).toInertial(pad.normalized)
        let view = PlanetQuadtree.View(position: pad, pixelAngle: 0.001)
        let later = p.predictedView(after: 100, position: orientation(t).toInertial(pad), forward: up, up: Vec3.unitZ,
                                    fovY: 0.8, aspect: 1.5, orientation: orientation(t), figure: .wgs84, current: view)
        XCTAssertEqual((later!.position - pad).length, 0, accuracy: 0.1)
        // A jump of 1,000 km in a frame is a new camera, not motion.
        p.observe(time: t + 1.0 / 60, position: orientation(t).toInertial(pad) + Vec3(1e6, 0, 0))
        XCTAssertNil(p.velocity)
    }
}

/// A layer's files as one catalog (PlanetTileCatalog), and finding the
/// Earth's layers in a directory.
final class PlanetTileCatalogTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func write(_ name: String, keys: [TileKey], maxLevel: Int, value: Int, tileSize: Int = 4) throws -> PlanetTileFile {
        let layout = PlanetTileLayout(format: .uint8, tileSize: tileSize, border: 1, maxLevel: maxLevel, bodyID: 399, figure: .wgs84)
        let url = dir.appendingPathComponent(name)
        let w = try PlanetTileWriter(url: url, layout: layout, metadata: ["source": name])
        for k in keys { try w.add(k, rawSamples: [Int](repeating: value, count: (tileSize + 2) * (tileSize + 2))) }
        try w.finish()
        return try PlanetTileFile(contentsOf: url)
    }

    func testInsetOverBaseAndOrphansDropped() throws {
        let base = try write("base", keys: PlanetTileBuilder.keys(levels: 0 ... 2, figure: .wgs84), maxLevel: 2, value: 1)
        let lc39 = Ellipsoid.wgs84.figureDirection(latitude: 28.6 * .pi / 180, longitude: -80.6 * .pi / 180)
        let deep3 = TileKey.containing(lc39, level: 3), deep4 = TileKey.containing(lc39, level: 4)
        // An orphan: a level-4 tile elsewhere, its level-3 parent stored nowhere.
        let orphan = TileKey.containing(Vec3(1, 0.2, 0.1).normalized, level: 4)
        let inset = try write("inset", keys: [deep3, deep4, orphan, TileKey.roots[3]], maxLevel: 4, value: 2)
        let c = try PlanetTileCatalog(files: [("base", base), ("inset", inset)])
        XCTAssertEqual(c.maxLevel, 4)
        XCTAssertEqual(c.finestAvailable(deep4.children[0]), deep4)
        XCTAssertNil(c.entry(orphan), "dropped")
        XCTAssertTrue(c.notes.contains { $0.contains("1 tiles") })
        // The later file wins where both hold a tile.
        XCTAssertEqual(c.entry(TileKey.roots[3])?.file, 1)
        XCTAssertEqual(c.entry(TileKey.roots[2])?.file, 0)
        XCTAssertEqual(c.payload(deep3)?.first, 2)
        // A file of another shape is left out.
        let other = try write("other", keys: [TileKey.roots[0]], maxLevel: 0, value: 3, tileSize: 8)
        let d = try PlanetTileCatalog(files: [("base", base), ("other", other)])
        XCTAssertEqual(d.files.count, 1)
        XCTAssertTrue(d.notes.contains { $0.contains("other") })
    }

    func testEarthLayersFindTheNearestMonthAndTheirFiles() throws {
        let keys = PlanetTileBuilder.keys(levels: 0 ... 1, figure: .wgs84)
        try write(EarthTileFiles.albedo(month: 7), keys: keys, maxLevel: 1, value: 7)
        try write(EarthTileFiles.albedo(month: 12), keys: keys, maxLevel: 1, value: 12)
        try write(EarthTileFiles.water, keys: keys, maxLevel: 1, value: 0)
        try Data("not a tile file".utf8).write(to: dir.appendingPathComponent(EarthTileFiles.relief))
        let oct = PlanetTileCatalog.earthLayers(in: dir, month: 10)
        XCTAssertEqual(oct.month, 12, "October is nearer December than July")
        XCTAssertEqual(oct.layers[.albedo]?.payload(TileKey.roots[0])?.first, 12)
        XCTAssertNotNil(oct.layers[.water])
        XCTAssertNil(oct.layers[.relief])
        XCTAssertTrue(oct.problems.contains { $0.hasPrefix(EarthTileFiles.relief) })
        XCTAssertEqual(PlanetTileCatalog.earthLayers(in: dir, month: 8).month, 7)
        XCTAssertEqual(EarthTileFiles.nearestMonth(to: 1, available: [7, 12]), 12, "round the year")
        XCTAssertNil(EarthTileFiles.nearestMonth(to: 3, available: []))
        let empty = PlanetTileCatalog.earthLayers(in: dir.appendingPathComponent("none"), month: 7)
        XCTAssertTrue(empty.layers.isEmpty)
    }

    func testTexelMipsAverageInLinearLightForColour() {
        // A 4-texel RGBA tile, half black and half white: sRGB mips average light, not codes.
        var t = [UInt8](repeating: 0, count: TileTexelMips.totalSize(across: 4, channels: 4, levels: 3))
        for y in 0 ..< 4 { for x in 0 ..< 4 { for c in 0 ..< 4 { t[(y * 4 + x) * 4 + c] = x % 2 == 0 ? 255 : 0 } } }
        t.withUnsafeMutableBytes { TileTexelMips.generate($0.baseAddress!, across: 4, channels: 4, levels: 3, srgb: true) }
        let mip1 = 4 * 4 * 4
        XCTAssertEqual(t[mip1], 188, "half of the light is sRGB 188")
        XCTAssertEqual(t[mip1 + 3], 128, "alpha as it is")
        var d = [UInt8](repeating: 0, count: TileTexelMips.totalSize(across: 4, channels: 1, levels: 2))
        for x in 0 ..< 16 { d[x] = x % 2 == 0 ? 200 : 100 }
        d.withUnsafeMutableBytes { TileTexelMips.generate($0.baseAddress!, across: 4, channels: 1, levels: 2, srgb: false) }
        XCTAssertEqual(d[16], 150)
    }
}
