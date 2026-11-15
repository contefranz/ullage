import Foundation
import Metal
import QuartzCore
import OrbitCore
import OrbitScene

/// The Earth's tile store in the frame (P0, track E1): finds the layers'
/// files in Application Support/OrbitSim/Tiles (the albedo at the month
/// nearest the scenario's date), selects the tiles the camera needs through
/// the quadtree, predicts the track for prefetch, and runs each layer's
/// cache, whose uploads go into this frame's command buffer before P1.
/// E2's planet pass reads the caches (`layer(_:)`). Without the files the
/// pass does nothing and the Earth keeps its fallback look; `status` and
/// the console say why.
@MainActor
public final class PlanetTilePass: RenderPass {
    public let name = "Planet tiles"
    public let stage = PassStage.prepare
    public let order = 5

    /// Read the user's tiles (off for snapshots and goldens).
    public var loadsUserTiles: Bool
    public let directory: URL
    /// The live layers, once their files are open.
    public private(set) var layers: [PlanetTileLayerKind: PlanetTileCache] = [:]
    /// What the pass found, for the console and Help.
    public private(set) var status = "not started"
    /// The albedo's month (1-12) in use.
    public private(set) var month: Int?
    /// The last frame's selection (tests, timings).
    public private(set) var lastSelection: PlanetQuadtree.Selection?
    /// Main-thread seconds of the last frame: selection, prefetch and updates.
    public private(set) var lastFrameSeconds = 0.0

    private var device: MTLDevice?
    private var loading = false
    private var wantedMonth: Int?
    private var predictor = PlanetTrackPredictor(mu: 3.986_004_418e14)
    private var previous: PlanetQuadtree.Selection?
    private var prefetchTiles: [PlanetQuadtree.Tile] = []
    private var frames = 0
    private var statsWindow = StatsWindow()
    private var announced = false

    /// The default directory: ~/Library/Application Support/OrbitSim/Tiles.
    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("OrbitSim/Tiles", isDirectory: true)
    }

    public init(loadsUserTiles: Bool = true, directory: URL? = nil) {
        self.loadsUserTiles = loadsUserTiles
        self.directory = directory ?? Self.defaultDirectory
    }

    /// The layer's cache, if its files were found.
    public func layer(_ kind: PlanetTileLayerKind) -> PlanetTileCache? { layers[kind] }

    public func setUp(_ s: PassSetup) throws {
        device = s.device
    }

    public func isActive(in f: FrameContext) -> Bool {
        loadsUserTiles && f.settings.planetTile.enabled && f.scene.bodies.contains { $0.id == AtmosphereFrame.planetID }
    }

    public func encode(_ f: FrameContext, _ e: PassEncoding) {
        guard case .commandBuffer(let cb) = e, let device,
              let earth = f.scene.bodies.first(where: { $0.id == AtmosphereFrame.planetID }) else { return }
        let settings = f.settings.planetTile
        let month = f.scene.clock.simTime.utc.month
        if wantedMonth != month && !loading {
            wantedMonth = month
            open(month: month, device: device, settings: settings, synchronous: settings.synchronous)
        }
        guard !layers.isEmpty else { return }
        let start = CACurrentMediaTime()
        frames += 1
        let clock = f.scene.clock, cam = f.scene.camera
        let camera = -earth.position
        predictor.observe(time: clock.simTime.tdb, position: camera, reset: clock.temporalReset)
        let tileSize = layers.values.first!.catalog.layout.tileSize
        let deepest = layers.values.map(\.catalog.maxLevel).max() ?? 0
        let budget = layers.values.map { Int(Double($0.slots) * settings.selectionShare) }.min() ?? 64
        let quadtree = PlanetQuadtree(.init(figure: earth.figure, maxLevel: deepest, samplesPerTile: tileSize,
                                            pixelError: settings.pixelError, tileBudget: budget))
        let view = quadtree.view(cameraPosition: camera, worldToView: cam.worldToView, fovY: cam.fovY,
                                 viewportWidth: cam.viewport.width, viewportHeight: cam.viewport.height,
                                 orientation: earth.orientation, velocity: predictor.velocity ?? .zero,
                                 warp: clock.warp, frameInterval: min(max(clock.realDt, 1.0 / 240), 0.25))
        let selection = quadtree.select(view, previous: clock.temporalReset ? nil : previous)
        previous = selection
        lastSelection = selection
        // Prefetch: the views along the predicted track, every few frames,
        // when the ground moves far enough in that time to matter.
        let horizon = settings.prefetchSeconds.max() ?? 0
        if settings.prefetchSeconds.isEmpty || view.groundSpeed * clock.warp * horizon < 1_000 {
            prefetchTiles = []
        } else if frames % max(settings.prefetchInterval, 1) == 1 || settings.prefetchInterval <= 1 {
            var tiles: [PlanetQuadtree.Tile] = []
            for seconds in settings.prefetchSeconds {
                guard let v = predictor.predictedView(after: seconds * clock.warp, position: camera,
                                                      forward: -cam.worldToView.r2, up: cam.worldToView.r1,
                                                      fovY: cam.fovY, aspect: cam.aspect, orientation: earth.orientation,
                                                      figure: earth.figure, current: view) else { continue }
                tiles += quadtree.select(v).tiles
            }
            prefetchTiles = tiles
        }
        guard let blit = f.makeBlitEncoder() else { return }
        for kind in PlanetTileLayerKind.allCases {
            guard let cache = layers[kind] else { continue }
            cache.uploadsPerFrame = settings.uploadsPerFrame
            cache.maxPendingLoads = settings.maxPendingLoads
            let current = PlanetTileWants.ordered(selection.tiles, finestAvailable: cache.catalog.finestAvailable)
            let now = Set(current)
            let ahead = PlanetTileWants.ordered(prefetchTiles, finestAvailable: cache.catalog.finestAvailable)
                .filter { !now.contains($0) }
            cache.update(current: current, prefetch: ahead, commandBuffer: cb, blit: blit, synchronous: settings.synchronous)
        }
        blit.endEncoding()
        lastFrameSeconds = CACurrentMediaTime() - start
        if ProcessInfo.processInfo.environment["ORBITSIM_TILE_STATS"] != nil {
            statsWindow.add(self)
            if let line = statsWindow.report(every: 2) { NSLog("OrbitSim: tiles: %@", line) }
        }
    }

    /// Opens the layers for `month`, off the main thread (or now, when
    /// `synchronous`), and makes their caches.
    private func open(month: Int, device: MTLDevice, settings: PlanetTileSettings, synchronous: Bool) {
        let dir = directory
        let finish: @MainActor (PlanetTileCatalogSet) -> Void = { [weak self] found in
            self?.install(found, device: device, settings: settings)
        }
        if synchronous {
            finish(PlanetTileCatalogSet(PlanetTileCatalog.earthLayers(in: dir, month: month), directory: dir))
            return
        }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = PlanetTileCatalogSet(PlanetTileCatalog.earthLayers(in: dir, month: month), directory: dir)
            DispatchQueue.main.async { MainActor.assumeIsolated { finish(found) } }
        }
    }

    private func install(_ found: PlanetTileCatalogSet, device: MTLDevice, settings: PlanetTileSettings) {
        loading = false
        for p in found.problems { NSLog("OrbitSim: Earth tiles: %@", p) }
        // The same month already in use: keep the caches.
        if found.month == month && !layers.isEmpty { return }
        layers = [:]
        previous = nil
        month = found.month
        var lines: [String] = []
        for kind in PlanetTileLayerKind.allCases {
            guard let catalog = found.layers[kind] else { continue }
            let perSlot = PlanetTileCache.slotBytes(catalog.layout, color: kind.isColor)
            guard perSlot > 0 else { continue }
            let budget = Double(settings.atlasMemoryMB) * 1_048_576 * kind.memoryShare
            let slots = min(2_048, max(96, Int(budget / Double(perSlot))))
            do {
                let urls = catalog.names.map { found.directory.appendingPathComponent($0) }
                let cache = try PlanetTileCache(device: device, name: "Earth \(kind.rawValue)", catalog: catalog,
                                                color: kind.isColor, slots: slots,
                                                maxTextureLevel: settings.maxTextureLevel, fileURLs: urls)
                layers[kind] = cache
                lines.append(String(format: "%@ %@ (%d tiles to level %d), %d slots, %.0f MB", kind.rawValue,
                                    catalog.names.joined(separator: " + "), catalog.count, catalog.maxLevel, slots,
                                    Double(cache.memoryBytes) / 1_048_576))
            } catch {
                NSLog("OrbitSim: Earth tiles: %@: %@", kind.rawValue, "\(error)")
            }
        }
        if layers.isEmpty {
            status = "no Earth tiles in \(found.directory.path): the Earth keeps its fallback look (earth.jpg or the "
                + "plain ocean). To make them, run tools/fetch_planet_data.sh, then swift run -c release PlanetTiles earth all."
        } else {
            status = "Earth tiles: " + lines.joined(separator: "; ")
        }
        if !announced || !layers.isEmpty {
            NSLog("OrbitSim: %@", status)
            announced = true
        }
    }

    /// One line of the layers' per-frame costs, averaged over a window.
    @MainActor
    struct StatsWindow {
        var frames = 0, uploads = 0, uploadBytes = 0, readBytes = 0, requested = 0, evicted = 0
        var decode = 0.0, main = 0.0, worstMain = 0.0
        var start = CACurrentMediaTime()

        mutating func add(_ pass: PlanetTilePass) {
            frames += 1
            main += pass.lastFrameSeconds
            worstMain = max(worstMain, pass.lastFrameSeconds)
            for c in pass.layers.values {
                uploads += c.stats.uploaded
                uploadBytes += c.stats.uploadBytes + c.stats.indirectionBytes
                readBytes += c.stats.readBytes
                requested += c.stats.requested
                evicted += c.stats.evicted
                decode += c.stats.decodeSeconds
            }
        }

        mutating func report(every seconds: Double) -> String? {
            let now = CACurrentMediaTime()
            guard now - start >= seconds, frames > 0 else { return nil }
            let n = Double(frames)
            let line = String(format: "%d frames: per frame %.2f uploads (%.2f MB), %.2f MB read, %.2f ms decode (worker), "
                              + "%.3f ms main (worst %.3f), %d requested, %d evicted",
                              frames, Double(uploads) / n, Double(uploadBytes) / n / 1_048_576, Double(readBytes) / n / 1_048_576,
                              decode / n * 1_000, main / n * 1_000, worstMain * 1_000, requested, evicted)
            self = StatsWindow()
            return line
        }
    }
}

/// What `PlanetTileCatalog.earthLayers` found, carried to the main thread.
struct PlanetTileCatalogSet: @unchecked Sendable {
    let layers: [PlanetTileLayerKind: PlanetTileCatalog]
    let month: Int?
    let problems: [String]
    let directory: URL

    init(_ found: (layers: [PlanetTileLayerKind: PlanetTileCatalog], month: Int?, problems: [String]), directory: URL) {
        layers = found.layers
        month = found.month
        problems = found.problems
        self.directory = directory
    }
}
