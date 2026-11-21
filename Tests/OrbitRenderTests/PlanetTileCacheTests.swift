import ImageIO
import Metal
import XCTest
@testable import OrbitCore
@testable import OrbitRender
@testable import OrbitScene

/// Track E1's GPU cache on small synthetic tile sets: the shader's lookup
/// (indirection texture and deep table) against the CPU mirror, raw tiles
/// through Metal's IO queue and by copy, JPEG colour tiles decoded upright
/// into an sRGB atlas, and eviction while frames are in flight.
@MainActor
final class PlanetTileCacheTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func device() throws -> MTLDevice { try XCTUnwrap(RenderDevice.shared, "no Metal device") }

    /// Texel (i, j) of tile (face, level, x, y) is (10 i, 10 j, 40 level + face, (7x + 13y) mod 251).
    static func identityTexel(_ k: TileKey, _ i: Int, _ j: Int) -> [Int] {
        [10 * i, 10 * j, 40 * k.level + k.face.rawValue, (7 * k.x + 13 * k.y) % 251]
    }

    /// A raw RGBA8 layer whose texels name themselves, to `maxLevel`
    /// (`keys`: only those tiles and their ancestors).
    func identityLayer(_ name: String, maxLevel: Int, n: Int = 16, b: Int = 4, keys: [TileKey]? = nil) throws -> URL {
        let layout = PlanetTileLayout(format: .uint8, tileSize: n, border: b, channels: 4, maxLevel: maxLevel,
                                      bodyID: 399, figure: .wgs84)
        let url = dir.appendingPathComponent(name)
        let w = try PlanetTileWriter(url: url, layout: layout, metadata: ["source": "identity"])
        var all = Set<TileKey>()
        for k in keys ?? PlanetTileBuilder.keys(levels: 0 ... maxLevel, figure: .wgs84) {
            var a: TileKey? = k
            while let x = a { all.insert(x); a = x.parent }
        }
        let m = n + 2 * b
        for k in all.sorted() {
            var samples = [Int]()
            samples.reserveCapacity(m * m * 4)
            for j in 0 ..< m { for i in 0 ..< m { samples += Self.identityTexel(k, i, j) } }
            try w.add(k, rawSamples: samples)
        }
        try w.finish()
        return url
    }

    func cache(_ urls: [URL], slots: Int, maxTextureLevel: Int, pinnedLevel: Int = 0, color: Bool = false,
               io: Bool = true) throws -> PlanetTileCache {
        let files = try urls.map { ($0.lastPathComponent, try PlanetTileFile(contentsOf: $0)) }
        let catalog = try PlanetTileCatalog(files: files)
        return try PlanetTileCache(device: try device(), name: "test", catalog: catalog, color: color, slots: slots,
                                   maxTextureLevel: maxTextureLevel, pinnedLevel: pinnedLevel, useIOQueue: io,
                                   fileURLs: urls)
    }

    /// Runs the probe kernel over `probes` (direction, level) after `before`
    /// on one command buffer; the values and hits.
    func probe(_ c: PlanetTileCache, _ probes: [SIMD4<Float>], sampler: MTLSamplerState? = nil,
               commandBuffer: MTLCommandBuffer) throws -> (values: MTLBuffer, hits: MTLBuffer) {
        let device = try device()
        let lib = try ShaderLibrary(device: device).library(.planetTiles)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(lib.makeFunction(name: "planet_tile_probe")))
        let input = try XCTUnwrap(device.makeBuffer(bytes: probes, length: probes.count * 16, options: .storageModeShared))
        let values = try XCTUnwrap(device.makeBuffer(length: probes.count * 16, options: .storageModeShared))
        let hits = try XCTUnwrap(device.makeBuffer(length: probes.count * 16, options: .storageModeShared))
        let enc = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(input, offset: 0, index: 0)
        enc.setBuffer(values, offset: 0, index: 1)
        enc.setBuffer(hits, offset: 0, index: 2)
        c.bindCompute(enc, atlas: 0, indirection: 1, deep: 4, uniforms: 3)
        var count = UInt32(probes.count)
        enc.setBytes(&count, length: 4, index: 5)
        enc.setSamplerState(sampler ?? c.sampler, index: 0)
        enc.dispatchThreads(MTLSize(width: probes.count, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        enc.endEncoding()
        return (values, hits)
    }

    func nearestSampler() throws -> MTLSamplerState {
        let d = MTLSamplerDescriptor()
        d.minFilter = .nearest
        d.magFilter = .nearest
        d.sAddressMode = .clampToEdge
        d.tAddressMode = .clampToEdge
        return try XCTUnwrap(try device().makeSamplerState(descriptor: d))
    }

    /// Wants for tiles round `d` down to `level`: the 3 × 3 block there and its ancestors.
    func wants(around d: Vec3, level: Int, catalog: PlanetTileCatalog) -> [TileKey] {
        let centre = TileKey.containing(d, level: level)
        var keys = [centre]
        for e in TileKey.Edge.allCases { keys.append(centre.neighbor(e)) }
        for c in 0 ..< 4 { if let g = centre.diagonalNeighbor(corner: c) { keys.append(g.key) } }
        let tiles = keys.map { PlanetQuadtree.Tile(key: $0, distance: ($0.centre - d).length, morphStart: 0, morphEnd: 1, seams: 0) }
        return PlanetTileWants.ordered(tiles, finestAvailable: catalog.finestAvailable)
    }

    /// Random probes near `d` and anywhere, away from texel and face edges
    /// (where float and double may choose differently).
    func probes(near d: Vec3, count: Int, maxLevel: Int) -> [(Vec3, Int)] {
        var rng = SystemRandomNumberGenerator()
        return probes(near: d, count: count, maxLevel: maxLevel, using: &rng)
    }

    func probes<G: RandomNumberGenerator>(near d: Vec3, count: Int, maxLevel: Int, using rng: inout G) -> [(Vec3, Int)] {
        var out: [(Vec3, Int)] = []
        while out.count < count {
            let s = out.count % 2 == 0 ? 0.05 : 2.0
            let p = (d + Vec3(Double.random(in: -s ... s, using: &rng), Double.random(in: -s ... s, using: &rng),
                              Double.random(in: -s ... s, using: &rng))).normalized
            let a = [abs(p.x), abs(p.y), abs(p.z)].sorted()
            if a[2] - a[1] < 1e-4 { continue }
            out.append((p, Int.random(in: 0 ... maxLevel, using: &rng)))
        }
        return out
    }

    /// The texel a nearest sample at the probe's hit takes, if not too
    /// close to a texel edge to call.
    func expectedTexel(_ key: TileKey, _ d: Vec3, n: Int, b: Int) -> (Int, Int)? {
        let f = CubeSphere.faceCoordinates(d)
        let local = key.localCoordinates(u: f.u, v: f.v)
        let x = local.u * Double(n) + Double(b), y = local.v * Double(n) + Double(b)
        for v in [x, y] where abs(v - v.rounded()) < 0.02 { return nil }
        return (Int(x), Int(y))
    }

    func checkIdentity(_ c: PlanetTileCache, near d: Vec3, maxLevel: Int, n: Int = 16, b: Int = 4,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let queue = try XCTUnwrap(try device().makeCommandQueue())
        let ps = probes(near: d, count: 2_000, maxLevel: maxLevel)
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let (values, hits) = try probe(c, ps.map { SIMD4(Float($0.0.x), Float($0.0.y), Float($0.0.z), Float($0.1)) },
                                       sampler: try nearestSampler(), commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        let v = values.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        let h = hits.contents().assumingMemoryBound(to: SIMD4<UInt32>.self)
        var checked = 0
        for (k, (dir, level)) in ps.enumerated() {
            let want = try XCTUnwrap(c.residency.indirection.lookup(dir, level: level), file: file, line: line)
            // Directions within float's reach of a tile edge at the found level.
            let f = CubeSphere.faceCoordinates(dir)
            let local = want.key.localCoordinates(u: f.u, v: f.v)
            if min(local.u, 1 - local.u, local.v, 1 - local.v) < 1e-4 { continue }
            XCTAssertEqual(h[k], SIMD4(1, UInt32(want.slot), UInt32(want.key.level), UInt32(want.key.face.rawValue)),
                           "probe \(k) at level \(level)", file: file, line: line)
            guard let (i, j) = expectedTexel(want.key, dir, n: n, b: b) else { continue }
            let expected = Self.identityTexel(want.key, i, j).map { Float($0) / 255 }
            for ch in 0 ..< 4 { XCTAssertEqual(v[k][ch], expected[ch], accuracy: 0.5 / 255, file: file, line: line) }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 1_000, file: file, line: line)
    }

    // MARK: Tests

    func testRawLayerLookupMatchesTheCPUThroughTheIOQueueAndByCopy() throws {
        // Texture to level 2, the deep table for levels 3 and 4.
        let url = try identityLayer("identity.ostiles", maxLevel: 4)
        let device = try device()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let lc39 = Ellipsoid.wgs84.figureDirection(latitude: 28.6 * .pi / 180, longitude: -80.6 * .pi / 180)
        for io in [true, false] {
            let c = try cache([url], slots: 64, maxTextureLevel: 2, io: io)
            XCTAssertEqual(c.usesIOQueue, io)
            let cb = try XCTUnwrap(queue.makeCommandBuffer()), blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
            let w = wants(around: lc39, level: 4, catalog: c.catalog)
            c.update(current: w, commandBuffer: cb, blit: blit, synchronous: true)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            XCTAssertEqual(c.stats.missing, 0)
            XCTAssertEqual(c.stats.resident, Set(w + TileKey.roots).count, "the wants and the pinned roots")
            XCTAssertNil(c.residency.validate())
            XCTAssertGreaterThan(c.residency.indirection.hash.count, 0, "deep tiles resident")
            try checkIdentity(c, near: lc39, maxLevel: 4)
        }
    }

    func testJPEGColourTilesDecodeUprightIntoTheSRGBAtlas() throws {
        // Colour = (local v, local u, 0.5) in sRGB, so a flipped or turned
        // tile reads wrong; levels 0-2, 32-texel tiles with 4-texel borders.
        let n = 32, b = 4, m = n + 2 * b
        let layout = PlanetTileLayout(format: .jpeg, tileSize: n, border: b, channels: 3, maxLevel: 2, bodyID: 399,
                                      figure: .wgs84)
        let url = dir.appendingPathComponent("colour.ostiles")
        let w = try PlanetTileWriter(url: url, layout: layout)
        for k in PlanetTileBuilder.keys(levels: 0 ... 2, figure: .wgs84) {
            var rgb = [UInt8]()
            for j in 0 ..< m {
                for i in 0 ..< m {
                    let lu = PlanetTileBuilder.localCoordinate(i, tileSize: n, border: b)
                    let lv = PlanetTileBuilder.localCoordinate(j, tileSize: n, border: b)
                    rgb += [UInt8(max(0, min(255, (lv * 255).rounded()))), UInt8(max(0, min(255, (lu * 255).rounded()))), 128]
                }
            }
            try w.add(k, payload: try Self.jpeg(rgb, side: m))
        }
        try w.finish()
        let c = try cache([url], slots: 160, maxTextureLevel: 2, color: true)
        XCTAssertEqual(c.atlas.pixelFormat, .rgba8Unorm_srgb)
        XCTAssertEqual(c.atlas.mipmapLevelCount, 3)
        let queue = try XCTUnwrap(try device().makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer()), blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        let all = PlanetTileBuilder.keys(levels: 0 ... 2, figure: .wgs84)
        c.update(current: all, commandBuffer: cb, blit: blit, synchronous: true)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertEqual(c.stats.resident, all.count)
        // Probes at tile-local (0.25, 0.75) and (0.8, 0.1) of level-2 tiles.
        var ps: [SIMD4<Float>] = [], expected: [(Double, Double)] = []
        for k in all where k.level == 2 {
            for (lu, lv) in [(0.25, 0.75), (0.8, 0.1)] {
                let d = k.direction(localU: lu, localV: lv)
                ps.append(SIMD4(Float(d.x), Float(d.y), Float(d.z), 2))
                expected.append((lv, lu))
            }
        }
        let cb2 = try XCTUnwrap(queue.makeCommandBuffer())
        let (values, _) = try probe(c, ps, commandBuffer: cb2)
        cb2.commit()
        cb2.waitUntilCompleted()
        let v = values.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        var worst: Float = 0
        for (k, e) in expected.enumerated() {
            // The sRGB atlas reads in linear light.
            worst = max(worst, abs(v[k].x - SRGB.toLinear(Float(e.0))), abs(v[k].y - SRGB.toLinear(Float(e.1))))
            XCTAssertEqual(v[k].z, SRGB.toLinear(128 / 255), accuracy: 0.01)
        }
        XCTAssertLessThan(worst, 0.02, "JPEG at quality 0.95 and bilinear between texel centres")
    }

    /// The camera moves across the face edges with a small atlas, three
    /// frames in flight: every frame's probes, run on the GPU after its
    /// uploads, find what that frame's indirection said when it was encoded,
    /// although slots are reused all the time.
    ///
    /// Nothing here depends on how fast the machine is. Each frame's command
    /// buffer waits on a gate, which the test opens for frame n − 3 (and
    /// waits until the cache has seen it complete) before frame n updates, so
    /// the cache always has frames n − 2 and n − 1 committed and not yet run:
    /// any slot or staging buffer reused too soon is read by a frame that has
    /// not run. Each frame's loads finish before the next frame updates, and
    /// the probes are seeded. So the churn is the same on every run however
    /// loaded the machine (213 evictions, 21,897 probes checked); it once
    /// depended on how fast loads and frames came back.
    func testEvictionKeepsEveryFrameConsistentWithFramesInFlight() throws {
        let url = try identityLayer("moving.ostiles", maxLevel: 5)
        let c = try cache([url], slots: 48, maxTextureLevel: 3, pinnedLevel: 1)
        c.uploadsPerFrame = 4
        let device = try device()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let gate = try XCTUnwrap(device.makeSharedEvent())
        let inFlight = 3
        var frames: [(probes: [(Vec3, Int)], expected: [(TileKey, Int)?], values: MTLBuffer, hits: MTLBuffer)] = []
        var buffers: [MTLCommandBuffer] = []
        var evicted = 0
        var rng = SeededGenerator(seed: 0x711e)
        /// Opens the gate through frame `n` (the cache counts from 1) and
        /// waits until the cache has seen it complete.
        func complete(through n: Int) throws {
            guard n >= 1 else { return }
            gate.signaledValue = UInt64(n)
            buffers[n - 1].waitUntilCompleted()
            XCTAssertEqual(buffers[n - 1].status, .completed)
            let deadline = Date().addingTimeInterval(10)
            while (c.completion.completedThrough ?? 0) < UInt64(n), Date() < deadline { usleep(100) }
            XCTAssertEqual(c.completion.completedThrough, UInt64(n), "the cache sees exactly the frames let through")
        }
        for step in 0 ..< 120 {
            let n = step + 1
            try complete(through: n - inFlight)
            let a = Double(step) * 0.02
            let d = Vec3(cos(a), sin(a), 0.3 * sin(2 * a)).normalized
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            cb.encodeWaitForEvent(gate, value: UInt64(n))
            let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
            c.update(current: wants(around: d, level: 5, catalog: c.catalog), commandBuffer: cb, blit: blit)
            blit.endEncoding()
            evicted += c.stats.evicted
            let ps = probes(near: d, count: 200, maxLevel: 5, using: &rng)
            let expected = ps.map { c.residency.indirection.lookup($0.0, level: $0.1).map { ($0.key, $0.slot) } }
            let (values, hits) = try probe(c, ps.map { SIMD4(Float($0.0.x), Float($0.0.y), Float($0.0.z), Float($0.1)) },
                                           sampler: try nearestSampler(), commandBuffer: cb)
            cb.commit()
            buffers.append(cb)
            frames.append((ps, expected, values, hits))
            XCTAssertNil(c.residency.validate())
            // This frame's loads are in before the next frame takes them.
            c.loader.waitForAll()
        }
        try complete(through: buffers.count)
        XCTAssertGreaterThan(evicted, 50, "the atlas must churn")
        var checked = 0
        for f in frames {
            let v = f.values.contents().assumingMemoryBound(to: SIMD4<Float>.self)
            let h = f.hits.contents().assumingMemoryBound(to: SIMD4<UInt32>.self)
            for (k, (dir, _)) in f.probes.enumerated() {
                // Before the roots arrive nothing is found, on both sides.
                guard let (key, slot) = f.expected[k] else { XCTAssertEqual(h[k].x, 0); continue }
                let fc = CubeSphere.faceCoordinates(dir)
                let local = key.localCoordinates(u: fc.u, v: fc.v)
                if min(local.u, 1 - local.u, local.v, 1 - local.v) < 1e-4 { continue }
                XCTAssertEqual(h[k].y, UInt32(slot))
                guard let (i, j) = expectedTexel(key, dir, n: 16, b: 4) else { continue }
                let e = Self.identityTexel(key, i, j).map { Float($0) / 255 }
                // The slot holds this frame's tile: its level, face and position.
                XCTAssertEqual(v[k].z, e[2], accuracy: 0.5 / 255)
                XCTAssertEqual(v[k].w, e[3], accuracy: 0.5 / 255)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 10_000)
        print("PlanetTileCacheTests: \(evicted) evictions, \(checked) probes checked")
    }

    func testMemoryAndUniformsDescribeTheLayer() throws {
        let url = try identityLayer("small.ostiles", maxLevel: 3)
        let c = try cache([url], slots: 64, maxTextureLevel: 2)
        // 64 slots of 24² RGBA8 (raw: one mip), the indirection's 6 × (16 + 4 + 1) entries.
        XCTAssertEqual(c.memoryBytes, 64 * 24 * 24 * 4 + 4 * 6 * 21 + c.deepTable.length)
        let u = c.uniforms
        XCTAssertEqual(u.atlas, SIMD4(16, 4, 24, 0))
        XCTAssertEqual(u.levels.x, 3)
        XCTAssertEqual(u.levels.y, 2)
        XCTAssertEqual(MemoryLayout<PlanetTileLayerUniforms>.stride, 48)
        XCTAssertThrowsError(try cache([url], slots: 10, maxTextureLevel: 2), "fewer slots than the pinned tiles need")
    }

    nonisolated static func jpeg(_ rgb: [UInt8], side: Int, quality: Double = 0.95) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgb) as CFData))
        let image = try XCTUnwrap(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 24,
                                          bytesPerRow: side * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }
}
