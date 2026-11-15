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
    /// The last frame's selection of each layer (tests, timings).
    public private(set) var lastSelections: [PlanetTileLayerKind: PlanetQuadtree.Selection] = [:]
    /// Main-thread seconds of the last frame: selection, prefetch and updates.
    public private(set) var lastFrameSeconds = 0.0
    /// Its parts: the selection, the prefetch views' selections, the wanted
    /// lists, and the layers' updates.
    public private(set) var lastFrameParts = (select: 0.0, prefetch: 0.0, wants: 0.0, update: 0.0)

    private var device: MTLDevice?
    private var loading = false
    private var wantedMonth: Int?
    private var predictor = PlanetTrackPredictor(mu: 3.986_004_418e14)
    /// Each layer's prefetch wants, made when the prefetch views change.
    private var prefetchWants: [PlanetTileLayerKind: [TileKey]] = [:]
    /// The views along the predicted track, refreshed every few frames.
    private var prefetchViews: [PlanetQuadtree.View] = []
    /// Each layer's last selection of each prefetch view, to start the next from.
    private var prefetchSelections: [PlanetTileLayerKind: [PlanetQuadtree.Selection]] = [:]
    private var frames = 0
    private var statsWindow = StatsWindow()
    private var announced = false

    /// The default directory: ~/Library/Application Support/OrbitSim/Tiles,
    /// or `ORBITSIM_TILES_DIR` (tests, harness flights on demo tiles).
    public static var defaultDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["ORBITSIM_TILES_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("OrbitSim/Tiles", isDirectory: true)
    }

    public init(loadsUserTiles: Bool = true, directory: URL? = nil) {
        self.loadsUserTiles = loadsUserTiles
        self.directory = directory ?? Self.defaultDirectory
    }

    /// The layer's cache, if its files were found.
    public func layer(_ kind: PlanetTileLayerKind) -> PlanetTileCache? { layers[kind] }

    /// Off without the user's tiles (snapshots, goldens): the slot is empty.
    public var isEnabled: Bool { loadsUserTiles }

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
        let clock = f.scene.clock, cam = f.scene.camera
        let view = PlanetTileView(camera: -earth.position, worldToView: cam.worldToView, fovY: cam.fovY,
                                  width: cam.viewport.width, height: cam.viewport.height, orientation: earth.orientation,
                                  figure: earth.figure, simTime: clock.simTime.tdb, warp: clock.warp, realDt: clock.realDt,
                                  reset: clock.temporalReset)
        guard let blit = f.makeBlitEncoder() else { return }
        frame(view, settings: settings, commandBuffer: cb, blit: blit)
        blit.endEncoding()
    }

    /// What one frame of the pass needs to know of the camera and the Earth.
    struct PlanetTileView {
        /// The camera relative to the Earth's centre, ICRF, m.
        var camera: Vec3
        var worldToView: Mat3
        var fovY: Double, width: Double, height: Double
        var orientation: BodyOrientation
        var figure: Ellipsoid
        /// Simulation seconds (TDB past J2000), the warp, real seconds of the frame.
        var simTime: Double, warp: Double, realDt: Double
        var reset: Bool
    }

    /// One frame: each layer's own selection (its depth, its stored tiles,
    /// its budget), the prefetch views every few frames, and each layer's
    /// update into `blit` on `commandBuffer`.
    func frame(_ v: PlanetTileView, settings: PlanetTileSettings, commandBuffer cb: MTLCommandBuffer,
               blit: MTLBlitCommandEncoder) {
        let start = CACurrentMediaTime()
        frames += 1
        predictor.observe(time: v.simTime, position: v.camera, reset: v.reset)
        if v.reset { lastSelections = [:]; prefetchSelections = [:] }
        // Prefetch views: along the predicted track, every few frames, when
        // the ground moves far enough in that time to matter.
        let motionProbe = PlanetQuadtree(.init(figure: v.figure, maxLevel: 0))
        let current = motionProbe.view(cameraPosition: v.camera, worldToView: v.worldToView, fovY: v.fovY,
                                       viewportWidth: v.width, viewportHeight: v.height, orientation: v.orientation,
                                       velocity: predictor.velocity ?? .zero, warp: v.warp,
                                       frameInterval: min(max(v.realDt, 1.0 / 240), 0.25))
        let horizon = settings.prefetchSeconds.max() ?? 0
        var newPrefetch = false
        if settings.prefetchSeconds.isEmpty || current.groundSpeed * v.warp * horizon < 1_000 {
            if !prefetchViews.isEmpty { prefetchViews = []; newPrefetch = true }
        } else if frames % max(settings.prefetchInterval, 1) == 1 || settings.prefetchInterval <= 1 {
            prefetchViews = settings.prefetchSeconds.compactMap { seconds in
                predictor.predictedView(after: seconds * v.warp, position: v.camera, forward: -v.worldToView.r2,
                                        up: v.worldToView.r1, fovY: v.fovY, aspect: v.width / max(v.height, 1),
                                        orientation: v.orientation, figure: v.figure, current: current)
            }
            newPrefetch = true
        }
        if newPrefetch && prefetchViews.isEmpty { prefetchWants = [:] }
        var select = 0.0, prefetch = 0.0, wants = 0.0, updates = 0.0
        let interval = max(settings.prefetchInterval, 1)
        for (index, kind) in PlanetTileLayerKind.allCases.enumerated() {
            guard let cache = layers[kind] else { continue }
            cache.uploadsPerFrame = settings.uploadsPerFrame
            cache.maxPendingLoads = settings.maxPendingLoads
            let catalog = cache.catalog
            let t0 = CACurrentMediaTime()
            // The layer's own selection: to its depth, refining only where
            // finer tiles are stored, within its own share of its atlas.
            let quadtree = PlanetQuadtree(.init(figure: v.figure, maxLevel: catalog.maxLevel,
                                                samplesPerTile: catalog.layout.tileSize, pixelError: settings.pixelError,
                                                tileBudget: Int(Double(cache.slots) * settings.selectionShare),
                                                refinable: catalog.hasStoredChildren))
            let selection = quadtree.select(current, previous: lastSelections[kind])
            lastSelections[kind] = selection
            let t1 = CACurrentMediaTime()
            // Each layer selects its prefetch views on a frame of its own,
            // so the layers' prefetch selections do not land together.
            if prefetchWants[kind] == nil || (!prefetchViews.isEmpty && (frames + index) % interval == 0) {
                var tiles: [PlanetQuadtree.Tile] = [], selections: [PlanetQuadtree.Selection] = []
                let last = prefetchSelections[kind] ?? []
                for (i, p) in prefetchViews.enumerated() {
                    let sel = quadtree.select(p, previous: i < last.count ? last[i] : nil)
                    selections.append(sel)
                    tiles += sel.tiles
                }
                prefetchSelections[kind] = selections
                prefetchWants[kind] = PlanetTileWants.ordered(tiles, finestAvailable: catalog.finestAvailable)
            }
            let t2 = CACurrentMediaTime()
            let wanted = PlanetTileWants.ordered(selection.tiles, finestAvailable: catalog.finestAvailable)
            let t3 = CACurrentMediaTime()
            cache.update(current: wanted, prefetch: prefetchWants[kind] ?? [], commandBuffer: cb, blit: blit,
                         synchronous: settings.synchronous)
            select += t1 - t0
            prefetch += t2 - t1
            wants += t3 - t2
            updates += CACurrentMediaTime() - t3
        }
        lastFrameParts = (select, prefetch, wants, updates)
        lastFrameSeconds = CACurrentMediaTime() - start
        if ProcessInfo.processInfo.environment["ORBITSIM_TILE_STATS"] != nil {
            statsWindow.add(self)
            if let line = statsWindow.report(every: 2) { NSLog("OrbitSim: tiles: %@", line) }
        }
    }

    /// Installs layers made elsewhere (tests, timings).
    func install(_ caches: [PlanetTileLayerKind: PlanetTileCache]) {
        layers = caches
        lastSelections = [:]
        prefetchSelections = [:]
        prefetchWants = [:]
        loading = false
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
        lastSelections = [:]
        prefetchSelections = [:]
        prefetchWants = [:]
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
