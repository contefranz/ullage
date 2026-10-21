import XCTest
@testable import OrbitCore

/// OSTILES1 (PlanetTileFormat.swift): synthetic files written and read back,
/// heights sampled at texel centres and between them, across tile and face
/// edges, through the deepest tile a file holds, and rejected when damaged.
final class PlanetTileFormatTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ostiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A Moon height layer: 8-texel tiles with 2-texel borders, in steps of
    /// 1/64 m (exact in binary), Int16.min for no data.
    func moonLayout(maxLevel: Int = 3) -> PlanetTileLayout {
        PlanetTileLayout(format: .int16, tileSize: 8, border: 2, maxLevel: maxLevel, bodyID: 301,
                         figure: .sphere(1_737_400), scale: 1.0 / 64, offset: 0, noData: Int(Int16.min))
    }

    /// A smooth synthetic terrain, m: a few hundred metres of relief over the sphere.
    func terrain(_ d: Vec3) -> Double {
        let d = d.normalized
        return 300 * d.x + 120 * d.y * d.z - 80 * d.z * d.z + 40 * sin(3 * d.x + 2 * d.y)
    }

    /// The tile's texel values of `f` at each texel centre, borders included,
    /// row by row.
    func samples(_ key: TileKey, _ layout: PlanetTileLayout, _ f: (Vec3) -> Double?) -> [Double?] {
        let m = layout.samplesAcross, n = Double(layout.tileSize), b = Double(layout.border)
        var out: [Double?] = []
        for j in 0 ..< m { for i in 0 ..< m {
            out.append(f(key.direction(localU: (Double(i) - b + 0.5) / n, localV: (Double(j) - b + 0.5) / n)))
        } }
        return out
    }

    func write(_ name: String, _ layout: PlanetTileLayout, metadata: [String: String] = [:],
               _ tiles: [TileKey], _ f: (Vec3) -> Double?) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let w = try PlanetTileWriter(url: url, layout: layout, metadata: metadata)
        for k in tiles { try w.add(k, values: samples(k, layout, f)) }
        try w.finish()
        return url
    }

    /// Every tile of `face` down to `level`.
    func pyramid(_ face: CubeSphere.Face, through level: Int) -> [TileKey] {
        (0 ... level).flatMap { l in
            (0 ..< (1 << l)).flatMap { y in (0 ..< (1 << l)).map { TileKey(face: face, level: l, x: $0, y: y) } }
        }
    }

    /// The layout, metadata and index read back as written; tiles added out
    /// of order are indexed by id; payloads start on 16-byte boundaries and
    /// match their checksums.
    func testRoundTrip() throws {
        let layout = moonLayout()
        let tiles = pyramid(.posZ, through: 2).reversed() + [TileKey(face: .negY, level: 3, x: 5, y: 2)]
        let url = try write("moon.ostiles", layout, metadata: ["source": "synthetic", "tool": "PlanetTileFormatTests"],
                            Array(tiles), terrain)
        let file = try PlanetTileFile(contentsOf: url)
        XCTAssertEqual(file.layout, layout)
        XCTAssertEqual(file.layout.figure, .sphere(1_737_400))
        XCTAssertEqual(file.metadata, ["source": "synthetic", "tool": "PlanetTileFormatTests"])
        XCTAssertEqual(file.count, 22)
        XCTAssertEqual(file.entries.map(\.key), tiles.sorted())
        for e in file.entries {
            XCTAssertEqual(e.offset % 16, 0)
            XCTAssertEqual(e.length, 12 * 12 * 2)
        }
        XCTAssertNoThrow(try file.verify())
        XCTAssertTrue(file.contains(.root(.posZ)))
        XCTAssertFalse(file.contains(.root(.posX)))
        XCTAssertNil(file.payload(.root(.posX)))
        // A WGS-84 figure round-trips exactly.
        var earth = moonLayout()
        earth.figure = .wgs84; earth.bodyID = 399; earth.noData = nil
        let e = try PlanetTileFile(contentsOf: try write("earth.ostiles", earth, [.root(.posX)], terrain))
        XCTAssertEqual(e.layout, earth)
        XCTAssertEqual(e.layout.figure.polarRadius, Ellipsoid.wgs84.polarRadius)
        XCTAssertEqual(e.metadata, [:])
    }

    /// Texel centres read back their values to the quantum (1/128 m), and
    /// each tile's index range bounds its samples, borders included.
    func testTexelValuesAndRanges() throws {
        let layout = moonLayout()
        let k = TileKey(face: .negY, level: 3, x: 5, y: 2)
        let file = try PlanetTileFile(contentsOf: try write("t.ostiles", layout, [k], terrain))
        let t = try XCTUnwrap(file.tile(k))
        let expected = samples(k, layout, terrain)
        var lo = Double.infinity, hi = -Double.infinity
        for j in 0 ..< 12 { for i in 0 ..< 12 {
            let v = try XCTUnwrap(t.value(column: i, row: j))
            XCTAssertEqual(v, expected[j * 12 + i]!, accuracy: 1.0 / 128)
            lo = min(lo, v); hi = max(hi, v)
        } }
        let e = try XCTUnwrap(file.entry(k))
        XCTAssertEqual(e.minimum, lo)
        XCTAssertEqual(e.maximum, hi)
        XCTAssertEqual(file.valueRange(k), lo ... hi)
        // Float32 bounds round outward.
        XCTAssertLessThanOrEqual(Double(PlanetTileWriter.float(0.1, .down)), 0.1)
        XCTAssertGreaterThanOrEqual(Double(PlanetTileWriter.float(0.1, .up)), 0.1)
    }

    /// The bilinear lookup reproduces a function bilinear in the tile's
    /// local coordinates exactly (its texel values are exact in 1/64 m),
    /// anywhere on the tile, edges and corners included, as a GPU's filter
    /// on texel centres would.
    func testBilinearIsExactForBilinearHeights() throws {
        let layout = moonLayout()
        let k = TileKey(face: .posX, level: 2, x: 1, y: 3)
        func f(_ u: Double, _ v: Double) -> Double { 100 + 40 * u - 25 * v + 8 * u * v }
        // Values at texel centres, in local coordinates.
        var values: [Double?] = []
        for j in 0 ..< 12 { for i in 0 ..< 12 { values.append(f((Double(i) - 1.5) / 8, (Double(j) - 1.5) / 8)) } }
        let url = directory.appendingPathComponent("b.ostiles")
        let w = try PlanetTileWriter(url: url, layout: layout)
        try w.add(k, values: values)
        try w.finish()
        let t = try XCTUnwrap(try PlanetTileFile(contentsOf: url).tile(k))
        for u in stride(from: 0.0, through: 1.0, by: 0.0625 / 3) {
            for v in [0.0, 0.03, 0.31, 0.5, 0.77, 1.0] {
                XCTAssertEqual(try XCTUnwrap(t.value(localU: u, localV: v)), f(u, v), accuracy: 1e-12, "\(u), \(v)")
            }
        }
        // Through its direction too.
        let d = k.direction(localU: 0.4, localV: 0.9)
        XCTAssertEqual(try XCTUnwrap(t.value(at: d)), f(0.4, 0.9), accuracy: 1e-9)
    }

    /// Heights are continuous across tile edges: within a face the border
    /// holds the neighbour's texels, so both tiles give the same value on
    /// their shared edge; across a face edge the border is the projection
    /// carried past the edge, so they agree to the interpolation error.
    func testContinuityAcrossTileAndFaceEdges() throws {
        let layout = moonLayout()
        let a = TileKey(face: .posX, level: 3, x: 7, y: 4)
        let b = a.neighbor(.minU), c = a.neighbor(.maxU)
        XCTAssertEqual(b.face, .posX)
        XCTAssertEqual(c.face, .posY)
        let file = try PlanetTileFile(contentsOf: try write("c.ostiles", layout, [a, b, c], terrain))
        let ta = try XCTUnwrap(file.tile(a)), tb = try XCTUnwrap(file.tile(b)), tc = try XCTUnwrap(file.tile(c))
        for v in stride(from: 0.0, through: 1.0, by: 0.05) {
            let inFace = a.direction(localU: 0, localV: v)
            XCTAssertEqual(try XCTUnwrap(ta.value(at: inFace)), try XCTUnwrap(tb.value(at: inFace)), accuracy: 1e-9)
            let acrossFaces = a.direction(localU: 1, localV: v)
            let va = try XCTUnwrap(ta.value(at: acrossFaces)), vc = try XCTUnwrap(tc.value(at: acrossFaces))
            XCTAssertEqual(va, vc, accuracy: 0.5)
            XCTAssertEqual(va, terrain(acrossFaces), accuracy: 0.5)
        }
    }

    /// A lookup reads the deepest tile the file holds there: level 3 where
    /// it has one, its level-2 parent elsewhere, at most `maxLevel` deep,
    /// and nil off the stored faces. Geodetic and body-fixed queries meet
    /// the same terrain, under a vessel 15 km up as at its foot.
    func testDeepestTileLookup() throws {
        let layout = moonLayout()
        let deep = TileKey(face: .posZ, level: 3, x: 2, y: 5)
        let file = try PlanetTileFile(contentsOf: try write("p.ostiles", layout, pyramid(.posZ, through: 2) + [deep],
                                                            terrain))
        let inDeep = deep.direction(localU: 0.3, localV: 0.6)
        let elsewhere = TileKey(face: .posZ, level: 3, x: 6, y: 1).direction(localU: 0.5, localV: 0.5)
        XCTAssertEqual(file.finestTile(containing: inDeep), deep)
        XCTAssertEqual(file.finestTile(containing: inDeep, maxLevel: 1), deep.ancestor(atLevel: 1))
        XCTAssertEqual(file.finestTile(containing: elsewhere), TileKey(face: .posZ, level: 2, x: 3, y: 0))
        XCTAssertNil(file.finestTile(containing: Vec3(1, 0, 0)))
        XCTAssertNil(file.value(at: Vec3(0, 0, -1)))
        XCTAssertEqual(file.finestAvailable(TileKey(face: .posZ, level: 3, x: 6, y: 1)),
                       TileKey(face: .posZ, level: 2, x: 3, y: 0))
        XCTAssertEqual(file.valueRange(TileKey(face: .posZ, level: 3, x: 6, y: 1)),
                       file.valueRange(TileKey(face: .posZ, level: 2, x: 3, y: 0)))
        for d in [inDeep, elsewhere] {
            XCTAssertEqual(try XCTUnwrap(file.value(at: d)), terrain(d), accuracy: 0.5)
        }
        // Geodetic and body-fixed queries on the Moon's sphere.
        let g = layout.figure.geodeticCoordinates(figureDirection: inDeep)
        let h = try XCTUnwrap(file.height(latitude: g.latitude, longitude: g.longitude))
        XCTAssertEqual(h, try XCTUnwrap(file.value(at: inDeep)), accuracy: 1e-9)
        let vessel = inDeep * (1_737_400 + 15_000)
        XCTAssertEqual(try XCTUnwrap(file.height(below: vessel)), h, accuracy: 1e-9)
    }

    /// No-data texels read as nil, a lookup touching one is nil, and the
    /// index's range leaves them out; values quantise to the nearest raw
    /// step and clamp to Int16.
    func testNoDataAndQuantisation() throws {
        let layout = moonLayout()
        let k = TileKey(face: .negX, level: 1, x: 0, y: 1)
        var values: [Double?] = Array(repeating: 10, count: 144)
        values[0] = nil              // the border's corner
        values[5 * 12 + 6] = nil     // an interior texel
        values[7] = 1e9              // clamps to Int16.max / 64
        values[8] = 3.0 / 256        // rounds to 1/64
        let url = directory.appendingPathComponent("n.ostiles")
        let w = try PlanetTileWriter(url: url, layout: layout)
        try w.add(k, values: values)
        try w.finish()
        let file = try PlanetTileFile(contentsOf: url)
        let t = try XCTUnwrap(file.tile(k))
        XCTAssertNil(t.value(column: 0, row: 0))
        XCTAssertNil(t.value(column: 6, row: 5))
        XCTAssertEqual(t.raw(column: 6, row: 5), Int(Int16.min))
        XCTAssertEqual(t.value(column: 7, row: 0), Double(Int16.max) / 64)
        XCTAssertEqual(t.value(column: 8, row: 0), 1.0 / 64)
        // Texel (6, 5) is centred at local ((6 - 1.5)/8, (5 - 1.5)/8).
        XCTAssertNil(t.value(localU: 4.6 / 8, localV: 3.4 / 8))
        XCTAssertEqual(t.value(localU: 0.9, localV: 0.9), 10)
        XCTAssertEqual(file.valueRange(k), 1.0 / 64 ... Double(Int16.max) / 64)
    }

    /// Multi-channel uint8 tiles (a horizon map's azimuths) interleave their
    /// channels; image layers keep their payload bytes as given.
    func testChannelsAndImages() throws {
        let layout = PlanetTileLayout(format: .uint8, tileSize: 4, border: 1, channels: 3, maxLevel: 0, bodyID: 301,
                                      figure: .sphere(1_737_400))
        let k = TileKey.root(.negZ)
        let raw = (0 ..< 6 * 6 * 3).map { $0 % 251 }
        let url = directory.appendingPathComponent("h.ostiles")
        let w = try PlanetTileWriter(url: url, layout: layout)
        try w.add(k, rawSamples: raw)
        try w.finish()
        let t = try XCTUnwrap(try PlanetTileFile(contentsOf: url).tile(k))
        XCTAssertEqual(t.raw(column: 2, row: 3, channel: 1), (3 * 6 + 2) * 3 + 1)
        XCTAssertEqual(t.value(column: 5, row: 5, channel: 2), Double(107))

        let jpeg = PlanetTileLayout(format: .jpeg, tileSize: 256, border: 4, channels: 3, maxLevel: 6, bodyID: 399,
                                    figure: .wgs84)
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0xFF, 0xD9])
        let iurl = directory.appendingPathComponent("i.ostiles")
        let iw = try PlanetTileWriter(url: iurl, layout: jpeg, metadata: ["month": "2004-12"])
        try iw.add(.root(.posY), payload: bytes)
        try iw.finish()
        let image = try PlanetTileFile(contentsOf: iurl)
        XCTAssertEqual(image.payload(.root(.posY)), bytes)
        XCTAssertNil(image.tile(.root(.posY)))
        XCTAssertEqual(image.entry(.root(.posY))?.minimum, 0)
        XCTAssertNoThrow(try image.verify())
    }

    /// The writer refuses duplicates, tiles past the pyramid, payloads of
    /// the wrong size and no data in a layer without a no-data value.
    func testWriterRefusesBadTiles() throws {
        var layout = moonLayout(maxLevel: 1)
        let w = try PlanetTileWriter(url: directory.appendingPathComponent("w.ostiles"), layout: layout)
        let ten = [Double?](repeating: 10, count: 144)
        try w.add(.root(.posX), values: ten)
        XCTAssertThrowsError(try w.add(.root(.posX), values: ten))
        XCTAssertThrowsError(try w.add(TileKey(face: .posX, level: 2, x: 0, y: 0), values: ten))
        XCTAssertThrowsError(try w.add(.root(.posY), values: Array(ten.dropLast())))
        XCTAssertThrowsError(try w.add(.root(.posY), payload: Data(count: 10)))
        XCTAssertThrowsError(try w.add(.root(.posY), rawSamples: Array(repeating: 40_000, count: 144)))
        try w.finish()
        XCTAssertThrowsError(try w.add(.root(.posZ), values: ten))
        layout.noData = nil
        let v = try PlanetTileWriter(url: directory.appendingPathComponent("v.ostiles"), layout: layout)
        XCTAssertThrowsError(try v.add(.root(.posX), values: [nil] + ten.dropLast()))
        layout.scale = 0
        XCTAssertThrowsError(try PlanetTileWriter(url: directory.appendingPathComponent("z.ostiles"), layout: layout))
    }

    /// Damaged files: a flipped payload byte fails `verify`, and a wrong
    /// magic, a truncated index, an unsorted index and a bad sample format
    /// fail to open.
    func testDamagedFiles() throws {
        let url = try write("d.ostiles", moonLayout(), pyramid(.negX, through: 1), terrain)
        let good = try Data(contentsOf: url)
        let file = try PlanetTileFile(data: good)
        XCTAssertNoThrow(try file.verify())

        var flipped = good
        flipped[file.entries[2].offset + 7] ^= 0x10
        XCTAssertThrowsError(try PlanetTileFile(data: flipped).verify()) {
            XCTAssertEqual($0 as? PlanetTileError, .badTile(file.entries[2].key, "checksum"))
        }
        var magic = good
        magic[3] = 0x41
        XCTAssertThrowsError(try PlanetTileFile(data: magic))
        XCTAssertThrowsError(try PlanetTileFile(data: good.prefix(good.count - 1)))
        XCTAssertThrowsError(try PlanetTileFile(data: good.prefix(100)))
        var format = good
        format[12] = 99
        XCTAssertThrowsError(try PlanetTileFile(data: format))
        // A tile size that would overflow the payload's length.
        var huge = good
        huge.replaceSubrange(16 ..< 20, with: [0xFF, 0xFF, 0xFF, 0x7F])
        XCTAssertThrowsError(try PlanetTileFile(data: huge))
        // Swap the first two index entries' ids.
        var unsorted = good
        let index = Int(LittleEndianReader(good).u64(80))
        let first = good.subdata(in: index ..< index + 8), second = good.subdata(in: index + 32 ..< index + 40)
        unsorted.replaceSubrange(index ..< index + 8, with: second)
        unsorted.replaceSubrange(index + 32 ..< index + 40, with: first)
        XCTAssertThrowsError(try PlanetTileFile(data: unsorted))
        // A slice of a larger buffer parses like the file itself.
        let slice = (Data([1, 2, 3]) + good).dropFirst(3)
        XCTAssertEqual(try PlanetTileFile(data: slice).entries, file.entries)
        XCTAssertEqual(try PlanetTileFile(data: slice).tile(.root(.negX))?.value(column: 3, row: 3),
                       file.tile(.root(.negX))?.value(column: 3, row: 3))
    }

    /// CRC-32's check value (the ASCII digits 1-9: 0xCBF43926).
    func testChecksum() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }
}
