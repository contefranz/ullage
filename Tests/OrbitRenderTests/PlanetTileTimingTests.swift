import Metal
import QuartzCore
import XCTest
@testable import OrbitCore
@testable import OrbitRender
@testable import OrbitScene

/// The tile store's streaming cost (track E1), in the app's configuration:
/// the albedo with the Cape inset over it, the water and the relief, each
/// with the slots `PlanetTilePass` gives it at the default 256 MB, through
/// PlanetTilePass's own frame logic (each layer its own selection). The
/// parking orbit at 1×, 10×, 100× and 1000×, then 30 km over the Cape where
/// the inset streams, paced at 60 frames a second with three frames in
/// flight. A performance run: `ORBITSIM_TIMINGS=1`; it holds the GPU lock.
///
/// Tiles are coloured value noise about as heavy to decode as BMNG's land
/// (JPEG q 0.9 for the albedo and the inset, PNG for the water and the
/// relief): full pyramids to level 5, and the albedo's levels 6-7 where the
/// flight wants them (so its indirection texture stops at level 5 here,
/// where BMNG's goes to 7), the inset at levels 8-12 over the Cape.
@MainActor
final class PlanetTileTimingTests: XCTestCase {
    struct Sample {
        var main = 0.0, uploads = 0, uploadBytes = 0, readBytes = 0, decode = 0.0, missing = 0, requested = 0
        var refused = 0, gpu = 0.0
        var phases: [String: [Double]] = [:]
        var select = 0.0, prefetch = 0.0, wants = 0.0, update = 0.0
    }

    struct Segment { let name: String; let views: Range<Int> }

    func testStreamingCostAlongTheParkingOrbit() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ORBITSIM_TIMINGS"] != nil else { throw XCTSkip("a performance run: ORBITSIM_TIMINGS=1") }
        let lock = GPULock { print("PlanetTileTimingTests: waiting for the GPU lock") }
        defer { withExtendedLifetime(lock) {} }
        let device = try XCTUnwrap(RenderDevice.shared)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tile-timing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let settings = PlanetTileSettings()
        let figure = Ellipsoid.wgs84
        func layout(_ f: PlanetTileSampleFormat, _ c: Int, _ maxLevel: Int) -> PlanetTileLayout {
            PlanetTileLayout(format: f, tileSize: 256, border: 4, channels: c, maxLevel: maxLevel, bodyID: 399, figure: figure)
        }
        func slots(_ kind: PlanetTileLayerKind, _ l: PlanetTileLayout) -> Int {
            min(2_048, max(96, Int(Double(settings.atlasMemoryMB) * 1_048_576 * kind.memoryShare
                                   / Double(PlanetTileCache.slotBytes(l, color: kind.isColor)))))
        }
        var views = flight(warps: [1, 10, 100, 1_000], frames: 360)
        var segments = (0 ..< 4).map { Segment(name: ["1×", "10×", "100×", "1000×"][$0], views: $0 * 360 ..< ($0 + 1) * 360) }
        let cape = capeViews(frames: 240, after: views.last!.simTime + 1)
        segments.append(Segment(name: "Cape, 30 km, 1×", views: views.count ..< views.count + cape.count))
        views += cape

        // The tiles: full pyramids to 5; the albedo's 6 and 7 where the
        // flight wants them (a dry run of its selection and prefetch); the
        // inset's 8-12 over the Cape.
        let pyramid = Set(PlanetTileBuilder.keys(levels: 0 ... 5, figure: figure))
        let inset = Set(PlanetTileBuilder.keys(levels: 8 ... 12, region: GeoRegion(south: 28.30, north: 28.85, west: -80.85,
                                                                                  east: -80.45), figure: figure))
        let insetParents = Set(inset.compactMap(\.parent))
        let albedoSlots = slots(.albedo, layout(.jpeg, 3, 12))
        var deep = Set<TileKey>()
        do {
            var predictor = PlanetTrackPredictor(mu: 3.986_004_418e14)
            let q = PlanetQuadtree(.init(figure: figure, maxLevel: 12, samplesPerTile: 256, pixelError: settings.pixelError,
                                         tileBudget: Int(Double(albedoSlots) * settings.selectionShare),
                                         refinable: { $0.level < 7 || insetParents.contains($0) }))
            var previous: PlanetQuadtree.Selection?
            for (k, v) in views.enumerated() {
                predictor.observe(time: v.simTime, position: v.camera, reset: v.reset)
                let view = q.view(cameraPosition: v.camera, worldToView: v.worldToView, fovY: v.fovY, viewportWidth: v.width,
                                  viewportHeight: v.height, orientation: v.orientation, velocity: predictor.velocity ?? .zero,
                                  warp: v.warp, frameInterval: v.realDt)
                let sel = q.select(view, previous: v.reset ? nil : previous)
                previous = sel
                var tiles = sel.tiles
                if k % settings.prefetchInterval == 0 {
                    for s in settings.prefetchSeconds {
                        if let p = predictor.predictedView(after: s * v.warp, position: v.camera, forward: -v.worldToView.r2,
                                                           up: v.worldToView.r1, fovY: v.fovY, aspect: v.width / v.height,
                                                           orientation: v.orientation, figure: figure, current: view) {
                            tiles += q.select(p).tiles
                        }
                    }
                }
                for t in tiles where t.key.level >= 6 {
                    var a: TileKey? = t.key.ancestor(atLevel: min(t.key.level, 7))
                    while let x = a, x.level >= 6 { deep.insert(x); a = x.parent }
                }
            }
        }
        let files: [(String, PlanetTileLayout, Set<TileKey>)] = [
            ("base", layout(.jpeg, 3, 7), pyramid.union(deep)),
            ("inset", layout(.jpeg, 3, 12), inset),
            ("water", layout(.png, 1, 5), pyramid),
            ("relief", layout(.png, 3, 5), pyramid),
        ]
        var urls: [String: URL] = [:]
        for (name, l, keys) in files {
            let url = dir.appendingPathComponent("\(name).ostiles")
            let bytes = try makeNoiseLayer(url, keys: keys.sorted(), layout: l)
            urls[name] = url
            print(String(format: "PlanetTileTimingTests: %@: %d tiles, %.1f KB each", name, keys.count,
                         bytes / Double(keys.count) / 1_000))
        }
        func cache(_ kind: PlanetTileLayerKind, _ names: [String]) throws -> PlanetTileCache {
            let catalog = try PlanetTileCatalog(files: try names.map { ($0, try PlanetTileFile(contentsOf: urls[$0]!)) })
            XCTAssertTrue(catalog.notes.isEmpty, "\(catalog.notes)")
            return try PlanetTileCache(device: device, name: kind.rawValue, catalog: catalog, color: kind.isColor,
                                       slots: slots(kind, catalog.layout), maxTextureLevel: settings.maxTextureLevel,
                                       fileURLs: names.map { urls[$0]! })
        }
        let caches: [PlanetTileLayerKind: PlanetTileCache] = [.albedo: try cache(.albedo, ["base", "inset"]),
                                                              .water: try cache(.water, ["water"]),
                                                              .relief: try cache(.relief, ["relief"])]
        for (kind, c) in caches.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print(String(format: "PlanetTileTimingTests: %@: %d slots, to level %d, indirection to level %d: %.1f MB",
                         kind.rawValue, c.slots, c.catalog.maxLevel, c.residency.indirection.textureMaxLevel,
                         Double(c.memoryBytes) / 1_048_576))
        }
        let pass = PlanetTilePass(loadsUserTiles: false)
        pass.install(caches)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let inFlight = DispatchSemaphore(value: 3)
        let gpuTimes = GPUTimes(count: views.count)
        var samples = [Sample](repeating: Sample(), count: views.count)
        let frameTime = 1.0 / 60
        var next = CACurrentMediaTime()
        var deepestAtCape = 0
        for (k, v) in views.enumerated() {
            inFlight.wait()
            let cb = try XCTUnwrap(queue.makeCommandBuffer()), blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
            pass.frame(v, settings: settings, commandBuffer: cb, blit: blit)
            blit.endEncoding()
            cb.addCompletedHandler { b in
                gpuTimes.set(k, b.gpuEndTime - b.gpuStartTime)
                inFlight.signal()
            }
            cb.commit()
            var s = Sample(main: pass.lastFrameSeconds, select: pass.lastFrameParts.select,
                           prefetch: pass.lastFrameParts.prefetch, wants: pass.lastFrameParts.wants,
                           update: pass.lastFrameParts.update)
            for c in caches.values {
                let t = c.stats
                s.uploads += t.uploaded; s.uploadBytes += t.uploadBytes + t.indirectionBytes; s.readBytes += t.readBytes
                s.decode += t.decodeSeconds; s.missing += t.missing; s.requested += t.requested; s.refused += t.refused
                s.phases[c.name] = t.phases + [Double(t.uploaded), Double(t.evicted), Double(t.requested)]
            }
            samples[k] = s
            if k >= segments[4].views.lowerBound {
                deepestAtCape = max(deepestAtCape, caches[.albedo]!.residency.residentKeys.map(\.level).max() ?? 0)
            }
            next += frameTime
            let wait = next - CACurrentMediaTime()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) } else { next = CACurrentMediaTime() }
        }
        for _ in 0 ..< 3 { inFlight.wait() }
        for _ in 0 ..< 3 { inFlight.signal() }
        let total = caches.values.reduce(0) { $0 + $1.memoryBytes }
        print(String(format: "PlanetTileTimingTests: atlases and indirections %.0f MB in all", Double(total) / 1_048_576))
        print("segment | main ms mean/max | uploads/frame mean/max | upload MB/frame | read MB/frame | decode CPU ms/frame | GPU ms mean/max | wanted not resident mean/max | frames with any")
        for seg in segments {
            // The first frames of a segment load what its first view needs.
            let range = (seg.views.lowerBound + 60) ..< seg.views.upperBound
            let s = range.map { samples[$0] }, g = range.map { gpuTimes.get($0) }
            let n = Double(s.count)
            func mean(_ f: (Sample) -> Double) -> Double { s.map(f).reduce(0, +) / n }
            func most(_ f: (Sample) -> Double) -> Double { s.map(f).max() ?? 0 }
            print(String(format: "%@ | %.3f / %.3f | %.2f / %.0f | %.2f | %.2f | %.2f | %.3f / %.3f | %.1f / %.0f | %d of %d",
                         seg.name, mean { $0.main } * 1_000, most { $0.main } * 1_000, mean { Double($0.uploads) },
                         most { Double($0.uploads) }, mean { Double($0.uploadBytes) } / 1_048_576,
                         mean { Double($0.readBytes) } / 1_048_576, mean { $0.decode } * 1_000,
                         g.reduce(0, +) / n * 1_000, (g.max() ?? 0) * 1_000, mean { Double($0.missing) },
                         most { Double($0.missing) }, s.filter { $0.missing > 0 }.count, s.count))
            print(String(format: "    main ms: selections %.3f, prefetch %.3f (max %.3f), wants %.3f, updates %.3f (max %.3f); refused %d",
                         mean { $0.select } * 1_000, mean { $0.prefetch } * 1_000, most { $0.prefetch } * 1_000,
                         mean { $0.wants } * 1_000, mean { $0.update } * 1_000, most { $0.update } * 1_000,
                         s.map(\.refused).reduce(0, +)))
            if let worst = s.max(by: { $0.update < $1.update }) {
                for (name, ph) in worst.phases.sorted(by: { $0.key < $1.key }) {
                    print("    worst update, \(name): phases ms " + ph.prefix(5).map { String(format: "%.3f", $0 * 1_000) }.joined(separator: ", ")
                          + String(format: "; %.0f uploads, %.0f evictions, %.0f requests", ph[5], ph[6], ph[7]))
                }
            }
        }
        if let a = pass.lastSelections[.albedo] {
            print("PlanetTileTimingTests: the albedo's last selection: \(a.tiles.count) tiles, bias \(a.lodBias), deepest \(a.tiles.map(\.key.level).max() ?? 0)")
        }
        print("PlanetTileTimingTests: the deepest albedo tile resident over the Cape: level \(deepestAtCape)")
        XCTAssertGreaterThanOrEqual(deepestAtCape, 11, "the inset streamed in")
        for c in caches.values { XCTAssertNil(c.residency.validate()) }
    }

    /// GPU times of the frames, set on Metal's completion threads.
    final class GPUTimes: @unchecked Sendable {
        private var times: [Double]
        private let lock = NSLock()
        init(count: Int) { times = [Double](repeating: 0, count: count) }
        func set(_ k: Int, _ t: Double) { lock.lock(); times[k] = t; lock.unlock() }
        func get(_ k: Int) -> Double { lock.lock(); defer { lock.unlock() }; return times[k] }
    }

    /// The parking orbit (185 km, 32.5°), the camera on the vehicle looking
    /// 20° below the horizontal ahead, 50° high on 3024 × 1964, with the
    /// Earth turning; `frames` at 60 a second for each warp in turn.
    func flight(warps: [Double], frames: Int) -> [PlanetTilePass.PlanetTileView] {
        let deg = Double.pi / 180, mu = 3.986_004_418e14
        let r = 6_378_137 + 185_000.0, n = (mu / (r * r * r)).squareRoot()
        let inc = 32.5 * deg
        var t = 0.0
        var out: [PlanetTilePass.PlanetTileView] = []
        for warp in warps {
            for _ in 0 ..< frames {
                let u = n * t
                let p = Vec3(cos(u), sin(u) * cos(inc), sin(u) * sin(inc)) * r
                let v = Vec3(-sin(u), cos(u) * cos(inc), cos(u) * sin(inc))
                let down = -p.normalized
                let forward = (v * cos(20 * deg) + down * sin(20 * deg)).normalized
                out.append(view(p, forward: forward, t: t, warp: warp, reset: out.isEmpty))
                t += warp / 60
            }
        }
        return out
    }

    /// 30 km over the Cape, turning with the Earth, looking at LC-39 from 40 km west.
    func capeViews(frames: Int, after t0: Double) -> [PlanetTilePass.PlanetTileView] {
        let deg = Double.pi / 180, omega = 7.292_115e-5
        let f = Ellipsoid.wgs84
        let site = f.bodyFixed(latitude: 28.6 * deg, longitude: -80.6 * deg, height: 0)
        let eye = f.bodyFixed(latitude: 28.6 * deg, longitude: -81.0 * deg, height: 30_000)
        return (0 ..< frames).map { k in
            let t = t0 + Double(k) / 60
            let toInertial = Mat3.rotZ(-omega * t).transposed
            return view(toInertial * eye, forward: (toInertial * (site - eye)).normalized, t: t, warp: 1, reset: k == 0)
        }
    }

    func view(_ p: Vec3, forward: Vec3, t: Double, warp: Double, reset: Bool) -> PlanetTilePass.PlanetTileView {
        let omega = 7.292_115e-5
        let up = (p.normalized - forward * p.normalized.dot(forward)).normalized
        let right = forward.cross(up)
        let orientation = BodyOrientation(icrfToBody: Mat3.rotZ(-omega * t), angularVelocity: Vec3(0, 0, omega))
        return .init(camera: p, worldToView: Mat3(rows: right, up, -forward), fovY: 50 * Double.pi / 180, width: 3_024,
                     height: 1_964, orientation: orientation, figure: .wgs84, simTime: t, warp: warp, realDt: 1.0 / 60,
                     reset: reset)
    }

    /// A layer of `keys`: coloured value noise in four octaves, so each
    /// tile decodes about as BMNG's land does. Returns its payload bytes.
    func makeNoiseLayer(_ url: URL, keys: [TileKey], layout: PlanetTileLayout) throws -> Double {
        let n = layout.tileSize, m = layout.samplesAcross, channels = layout.channels
        let w = try PlanetTileWriter(url: url, layout: layout)
        var bytes = 0.0
        func hash(_ x: Int, _ y: Int, _ s: Int) -> Double {
            var h = UInt64(bitPattern: Int64(x &* 73_856_093 ^ y &* 19_349_663 ^ s &* 83_492_791))
            h ^= h >> 33; h = h &* 0xFF51_AFD7_ED55_8CCD; h ^= h >> 33
            return Double(h & 0xFFFF) / 65_535
        }
        let png = layout.format == .png
        try PlanetTileBuilder.build(keys, batch: 128, make: { key -> Data in
            var px = [UInt8](repeating: 0, count: m * m * channels)
            for j in 0 ..< m {
                for i in 0 ..< m {
                    var v = 0.0, amp = 0.5
                    for o in 0 ..< 4 {
                        let s = 32 >> o
                        v += amp * hash((key.x * n + i) / s, (key.y * n + j) / s, o + key.level * 7 + key.face.rawValue * 131)
                        amp *= 0.5
                    }
                    let k = (j * m + i) * channels
                    if channels == 1 {
                        px[k] = v > 0.5 ? 255 : 0
                    } else {
                        px[k] = UInt8(60 + 90 * v); px[k + 1] = UInt8(70 + 70 * v); px[k + 2] = UInt8(40 + 50 * v)
                    }
                }
            }
            return png ? try Self.png(px, side: m, channels: channels) : try PlanetTileCacheTests.jpeg(px, side: m, quality: 0.9)
        }, write: { key, payload in
            bytes += Double(payload.count)
            try w.add(key, payload: payload)
        })
        try w.finish()
        return bytes
    }

    nonisolated static func png(_ px: [UInt8], side: Int, channels: Int) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(px) as CFData))
        let image = try XCTUnwrap(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8 * channels,
                                          bytesPerRow: side * channels,
                                          space: channels == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }
}
