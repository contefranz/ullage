import Metal
import QuartzCore
import XCTest
@testable import OrbitCore
@testable import OrbitRender
@testable import OrbitScene

/// The tile store's streaming cost (track E1): the parking orbit at 1×,
/// 10×, 100× and 1000×, paced at 60 frames a second with three frames in
/// flight, through PlanetTilePass's own frame logic and a real albedo
/// cache. A performance run: `ORBITSIM_TIMINGS=1`; it holds the GPU lock.
///
/// The albedo tiles are made for exactly the tiles the flight wants (with
/// their ancestors) as 264² JPEGs at quality 0.9 of coloured value noise,
/// about as heavy to decode as BMNG's land; BMNG's oceans decode faster.
@MainActor
final class PlanetTileTimingTests: XCTestCase {
    struct Sample {
        var refused = 0
        var phases: [Double] = []
        var main = 0.0, uploads = 0, uploadBytes = 0, readBytes = 0, decode = 0.0, missing = 0, requested = 0
        var gpu = 0.0
        var select = 0.0, prefetch = 0.0, wants = 0.0, update = 0.0
    }

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
        let figure = Ellipsoid.wgs84, maxLevel = 7
        let slots = Int(Double(settings.atlasMemoryMB) * 1_048_576 * PlanetTileLayerKind.albedo.memoryShare
                        / Double(PlanetTileCache.slotBytes(PlanetTileLayout(format: .jpeg, tileSize: 256, border: 4, channels: 3,
                                                                            maxLevel: maxLevel, bodyID: 399, figure: figure))))
        let warps = [1.0, 10, 100, 1_000], framesPerWarp = 360
        let views = flight(warps: warps, frames: framesPerWarp)

        // Which tiles the flight wants: the pass's selection and prefetch, dry.
        var keys = Set(PlanetTileBuilder.keys(levels: 0 ... 3, figure: figure))
        do {
            var predictor = PlanetTrackPredictor(mu: 3.986_004_418e14)
            let q = quadtree(settings, maxLevel: maxLevel, slots: slots)
            var previous: PlanetQuadtree.Selection?
            for (k, v) in views.enumerated() {
                predictor.observe(time: v.simTime, position: v.camera)
                let view = q.view(cameraPosition: v.camera, worldToView: v.worldToView, fovY: v.fovY, viewportWidth: v.width,
                                  viewportHeight: v.height, orientation: v.orientation, velocity: predictor.velocity ?? .zero,
                                  warp: v.warp, frameInterval: v.realDt)
                let sel = q.select(view, previous: previous)
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
                keys.formUnion(PlanetTileWants.ordered(tiles) { $0.ancestor(atLevel: min($0.level, maxLevel)) })
            }
        }
        let url = dir.appendingPathComponent("timing.ostiles")
        let made = try makeNoiseLayer(url, keys: keys.sorted(), maxLevel: maxLevel)
        print(String(format: "PlanetTileTimingTests: %d tiles, %.1f KB each on average", keys.count, made / Double(keys.count) / 1_000))

        let catalog = try PlanetTileCatalog(files: [("timing", try PlanetTileFile(contentsOf: url))])
        let cache = try PlanetTileCache(device: device, name: "timing albedo", catalog: catalog, color: true, slots: slots,
                                        maxTextureLevel: settings.maxTextureLevel)
        let pass = PlanetTilePass(loadsUserTiles: false)
        pass.install([.albedo: cache])
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let inFlight = DispatchSemaphore(value: 3)
        let gpuTimes = GPUTimes(count: views.count)
        var samples = [Sample](repeating: Sample(), count: views.count)
        let frameTime = 1.0 / 60
        var next = CACurrentMediaTime()
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
            let s = cache.stats
            samples[k] = Sample(refused: s.refused, phases: s.phases, main: pass.lastFrameSeconds, uploads: s.uploaded, uploadBytes: s.uploadBytes + s.indirectionBytes,
                                readBytes: s.readBytes, decode: s.decodeSeconds, missing: s.missing, requested: s.requested,
                                select: pass.lastFrameParts.select, prefetch: pass.lastFrameParts.prefetch,
                                wants: pass.lastFrameParts.wants, update: pass.lastFrameParts.update)
            next += frameTime
            let wait = next - CACurrentMediaTime()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) } else { next = CACurrentMediaTime() }
        }
        for _ in 0 ..< 3 { inFlight.wait() }
        for _ in 0 ..< 3 { inFlight.signal() }
        print(String(format: "PlanetTileTimingTests: albedo atlas %d slots, %.0f MB (atlas and indirection)", slots,
                     Double(cache.memoryBytes) / 1_048_576))
        print("warp | main ms mean/max | uploads/frame mean/max | upload MB/frame | read MB/frame | decode ms/frame (workers) | GPU ms mean/max | missing mean/max | frames short")
        for (w, warp) in warps.enumerated() {
            // The first frames of the first warp load the pinned levels and the first view.
            let range = (w * framesPerWarp + (w == 0 ? 60 : 0)) ..< ((w + 1) * framesPerWarp)
            let s = range.map { samples[$0] }, g = range.map { gpuTimes.get($0) }
            let n = Double(s.count)
            func mean(_ f: (Sample) -> Double) -> Double { s.map(f).reduce(0, +) / n }
            func most(_ f: (Sample) -> Double) -> Double { s.map(f).max() ?? 0 }
            print(String(format: "%5.0f× | %.3f / %.3f | %.2f / %.0f | %.2f | %.2f | %.2f | %.3f / %.3f | %.1f / %.0f | %d",
                         warp, mean { $0.main } * 1_000, most { $0.main } * 1_000, mean { Double($0.uploads) },
                         most { Double($0.uploads) }, mean { Double($0.uploadBytes) } / 1_048_576,
                         mean { Double($0.readBytes) } / 1_048_576, mean { $0.decode } * 1_000,
                         g.reduce(0, +) / n * 1_000, (g.max() ?? 0) * 1_000, mean { Double($0.missing) },
                         most { Double($0.missing) }, s.filter { $0.missing > 0 }.count))
            print(String(format: "       refused for want of a slot: %d tiles", s.map(\.refused).reduce(0, +)))
            if let worst = s.max(by: { $0.update < $1.update }) {
                print("       worst update's phases, ms: " + worst.phases.map { String(format: "%.3f", $0 * 1_000) }.joined(separator: ", ")
                      + String(format: " (%d uploads)", worst.uploads))
            }
            print(String(format: "       main ms: selection %.3f, prefetch %.3f (max %.3f), wants %.3f, update %.3f (max %.3f)",
                         mean { $0.select } * 1_000, mean { $0.prefetch } * 1_000, most { $0.prefetch } * 1_000,
                         mean { $0.wants } * 1_000, mean { $0.update } * 1_000, most { $0.update } * 1_000))
        }
        XCTAssertNil(cache.residency.validate())
    }

    /// GPU times of the frames, set on Metal's completion threads.
    final class GPUTimes: @unchecked Sendable {
        private var times: [Double]
        private let lock = NSLock()
        init(count: Int) { times = [Double](repeating: 0, count: count) }
        func set(_ k: Int, _ t: Double) { lock.lock(); times[k] = t; lock.unlock() }
        func get(_ k: Int) -> Double { lock.lock(); defer { lock.unlock() }; return times[k] }
    }

    func quadtree(_ s: PlanetTileSettings, maxLevel: Int, slots: Int) -> PlanetQuadtree {
        PlanetQuadtree(.init(figure: .wgs84, maxLevel: maxLevel, samplesPerTile: 256, pixelError: s.pixelError,
                             tileBudget: Int(Double(slots) * s.selectionShare)))
    }

    /// The parking orbit (185 km, 32.5°), the camera on the vehicle looking
    /// 20° below the horizontal ahead, 50° high on 3024 × 1964, with the
    /// Earth turning; `frames` at 60 a second for each warp in turn.
    func flight(warps: [Double], frames: Int) -> [PlanetTilePass.PlanetTileView] {
        let deg = Double.pi / 180, mu = 3.986_004_418e14, omega = 7.292_115e-5
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
                let up = (p.normalized - forward * p.normalized.dot(forward)).normalized
                let right = forward.cross(up)
                let orientation = BodyOrientation(icrfToBody: Mat3.rotZ(-omega * t), angularVelocity: Vec3(0, 0, omega))
                out.append(.init(camera: p, worldToView: Mat3(rows: right, up, -forward), fovY: 50 * deg, width: 3_024,
                                 height: 1_964, orientation: orientation, figure: .wgs84, simTime: t, warp: warp,
                                 realDt: 1.0 / 60, reset: out.isEmpty))
                t += warp / 60
            }
        }
        return out
    }

    /// A JPEG layer of `keys`: coloured value noise in four octaves, so
    /// each tile decodes about as BMNG's land does. Returns its payload bytes.
    func makeNoiseLayer(_ url: URL, keys: [TileKey], maxLevel: Int) throws -> Double {
        let n = 256, b = 4, m = n + 2 * b
        let layout = PlanetTileLayout(format: .jpeg, tileSize: n, border: b, channels: 3, maxLevel: maxLevel, bodyID: 399,
                                      figure: .wgs84)
        let w = try PlanetTileWriter(url: url, layout: layout)
        var bytes = 0.0
        func hash(_ x: Int, _ y: Int, _ s: Int) -> Double {
            var h = UInt64(bitPattern: Int64(x &* 73_856_093 ^ y &* 19_349_663 ^ s &* 83_492_791))
            h ^= h >> 33; h = h &* 0xFF51_AFD7_ED55_8CCD; h ^= h >> 33
            return Double(h & 0xFFFF) / 65_535
        }
        try PlanetTileBuilder.build(keys, batch: 128, make: { key -> Data in
            var rgb = [UInt8](repeating: 0, count: m * m * 3)
            for j in 0 ..< m {
                for i in 0 ..< m {
                    var v = 0.0, amp = 0.5
                    for o in 0 ..< 4 {
                        let s = 32 >> o
                        let gx = (key.x * n + i) / max(s, 1), gy = (key.y * n + j) / max(s, 1)
                        v += amp * hash(gx, gy, o + key.level * 7 + key.face.rawValue * 131)
                        amp *= 0.5
                    }
                    let k = (j * m + i) * 3
                    rgb[k] = UInt8(60 + 90 * v); rgb[k + 1] = UInt8(70 + 70 * v); rgb[k + 2] = UInt8(40 + 50 * v)
                }
            }
            return try PlanetTileCacheTests.jpeg(rgb, side: m, quality: 0.9)
        }, write: { key, payload in
            bytes += Double(payload.count)
            try w.add(key, payload: payload)
        })
        try w.finish()
        return bytes
    }
}
