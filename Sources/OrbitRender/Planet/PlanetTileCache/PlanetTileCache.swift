import Foundation
import Metal
import QuartzCore
import OrbitCore
import OrbitScene

/// A tile load in flight on Metal's IO queue: its tile and staging buffer,
/// which only the completion handler reads until the loader has them back.
private struct IOLoad: @unchecked Sendable {
    let key: TileKey
    let staging: MTLBuffer
}

/// Swift mirror of PlanetTileCommon's `PlanetTileLayer`.
public struct PlanetTileLayerUniforms: Equatable {
    /// x: tile size n, y: border b, z: n + 2b, w: the atlas's deepest mip.
    public var atlas: SIMD4<Float>
    /// x: the layer's deepest level, y: the indirection texture's, z: the
    /// deep table's mask, w: its longest probe.
    public var levels: SIMD4<Int32>
    /// x: scale, y: offset, z: 1 when live, w: 1 for colour.
    public var value: SIMD4<Float>
}

/// One tile layer on the GPU (M1.6 design §3, track E1): a 2D-array atlas
/// of tile slots, the per-face indirection texture with its mips that
/// gives every point its finest resident tile, and the deep table for
/// tiles deeper than that texture. Each frame `update` takes the tiles the
/// quadtree's selection wants (and those prefetched along the predicted
/// track), starts loading the missing ones on background threads, and
/// encodes the uploads of those that are ready and the indirection's
/// changes into the frame's command buffer, so they are ordered with the
/// frames that read them. Evicted slots wait until the GPU has finished
/// every frame that could sample them (`PlanetTileResidency`).
///
/// Memory: `slots` × (n + 2b)² × texel size × 4/3 (three mips for images)
/// for the atlas, plus 4 bytes × 6 × 4^L × 4/3 for the indirection.
@MainActor
public final class PlanetTileCache {
    public struct Stats: Equatable {
        /// Tiles requested, uploaded and evicted in the last frame.
        public var requested = 0
        public var uploaded = 0
        public var evicted = 0
        /// Ready tiles that found no free slot.
        public var refused = 0
        /// Bytes blitted to the atlas and the indirection in the last frame.
        public var uploadBytes = 0
        public var indirectionBytes = 0
        /// Payload bytes read and decode (or copy) seconds of the loads that
        /// finished in the last frame, summed over the background threads.
        public var readBytes = 0
        public var decodeSeconds = 0.0
        /// Main-thread seconds `update` took in the last frame.
        public var updateSeconds = 0.0
        public var resident = 0
        public var pending = 0
        /// Wanted tiles not resident after the update (current only).
        public var missing = 0
        /// Main-thread seconds of the update's phases: bookkeeping, taking
        /// finished loads, admitting and uploading, requesting, the indirection.
        public var phases = [Double](repeating: 0, count: 5)
    }

    public let name: String
    public let catalog: PlanetTileCatalog
    public let device: MTLDevice
    public let slots: Int
    public let isColor: Bool
    public let atlas: MTLTexture
    public let indirection: MTLTexture
    public let sampler: MTLSamplerState
    /// The deep table the next frames read (replaced, never written, while in flight).
    public private(set) var deepTable: MTLBuffer
    public private(set) var residency: PlanetTileResidency
    public private(set) var stats = Stats()
    public var uploadsPerFrame = 12
    public var maxPendingLoads = 24

    let atlasChannels: Int
    let texelBytes: Int
    let mipLevels: Int
    let across: Int
    let loader: PlanetTileLoader
    let completion = FrameCompletion()
    private var ioQueue: MTLIOCommandQueue?
    private var ioHandles: [MTLIOFileHandle] = []
    private var freeStaging: [MTLBuffer] = []
    private var busyStaging: [(buffer: MTLBuffer, frame: UInt64)] = []
    private let stagingSize: Int
    private var pending = Set<TileKey>()
    private var ready: [TileKey: PlanetTileLoader.Result] = [:]
    private var frame: UInt64 = 0
    /// The stored tiles at the pinned levels: always wanted, first.
    private let pinnedKeys: [TileKey]
    /// Allocate staging without the streaming cap (a synchronous frame).
    private var unbounded = false

    public enum Failure: Error, CustomStringConvertible {
        case unsupported(String), noResources

        public var description: String {
            switch self {
            case .unsupported(let s): return "tile cache: \(s)"
            case .noResources: return "tile cache: could not allocate GPU memory"
            }
        }
    }

    /// The atlas's pixel format and channels for a layer's samples.
    static func atlasFormat(_ l: PlanetTileLayout, color: Bool) throws -> (MTLPixelFormat, channels: Int, bytes: Int) {
        switch (l.format, l.channels) {
        case (.jpeg, 3), (.png, 3), (.heic, 3), (.jpeg, 4), (.png, 4), (.heic, 4):
            return (color ? .rgba8Unorm_srgb : .rgba8Unorm, 4, 4)
        case (.jpeg, 1), (.png, 1), (.heic, 1): return (.r8Unorm, 1, 1)
        case (.uint8, 1): return (.r8Unorm, 1, 1)
        case (.uint8, 2): return (.rg8Unorm, 2, 2)
        case (.uint8, 4): return (.rgba8Unorm, 4, 4)
        case (.int16, 1): return (.r16Snorm, 1, 2)
        case (.int16, 2): return (.rg16Snorm, 2, 4)
        case (.int16, 4): return (.rgba16Snorm, 4, 8)
        default: throw Failure.unsupported("\(l.format) with \(l.channels) channels")
        }
    }

    /// Bytes of GPU memory a slot takes for this layout.
    public static func slotBytes(_ l: PlanetTileLayout, color: Bool = true) -> Int {
        guard let f = try? atlasFormat(l, color: color) else { return 0 }
        let m = l.samplesAcross, mips = mipCount(l)
        return TileTexelMips.totalSize(across: m, channels: f.bytes, levels: mips)
    }

    /// Image layers get mips down to a one-texel border; raw layers none.
    static func mipCount(_ l: PlanetTileLayout) -> Int {
        guard l.format.bytesPerSample == nil, l.border > 0 else { return 1 }
        return Int(log2(Double(l.border))) + 1
    }

    /// A cache of `slots` tiles for `catalog`'s layer. `color`: an sRGB
    /// atlas. `pinnedLevel`: levels never evicted. Raw layers load through
    /// Metal's IO queue when `useIOQueue` and the files are on disk.
    public init(device: MTLDevice, name: String, catalog: PlanetTileCatalog, color: Bool, slots: Int,
                maxTextureLevel: Int = 9, pinnedLevel: Int = 1, useIOQueue: Bool = true, fileURLs: [URL] = []) throws {
        let layout = catalog.layout
        let (format, channels, texel) = try Self.atlasFormat(layout, color: color)
        let pinned = (0 ... max(pinnedLevel, 0)).map { CubeSphere.tileCount(level: $0) }.reduce(0, +)
        guard slots > pinned + 8, slots <= 2048 else { throw Failure.unsupported("\(slots) slots (\(pinned) pinned, at most 2,048)") }
        self.device = device
        self.name = name
        self.catalog = catalog
        self.slots = slots
        isColor = color
        atlasChannels = channels
        texelBytes = texel
        across = layout.samplesAcross
        mipLevels = Self.mipCount(layout)
        // The indirection texture covers the levels stored everywhere;
        // deeper ones (an inset's) go through the deep table.
        residency = PlanetTileResidency(slots: slots, maxLevel: catalog.maxLevel, pinnedLevel: pinnedLevel,
                                        maxTextureLevel: max(0, min(maxTextureLevel, catalog.completeLevel)))
        var pinnedKeys: [TileKey] = []
        var frontier = TileKey.roots.filter(catalog.contains)
        for _ in 0 ... max(pinnedLevel, 0) {
            pinnedKeys += frontier
            frontier = frontier.flatMap(\.children).filter(catalog.contains)
        }
        self.pinnedKeys = pinnedKeys
        let ad = MTLTextureDescriptor()
        ad.textureType = .type2DArray
        ad.pixelFormat = format
        ad.width = across
        ad.height = across
        ad.mipmapLevelCount = mipLevels
        ad.arrayLength = slots
        ad.storageMode = .private
        ad.usage = .shaderRead
        let top = residency.indirection.textureMaxLevel
        let id = MTLTextureDescriptor()
        id.textureType = .type2DArray
        id.pixelFormat = .r32Uint
        id.width = 1 << top
        id.height = 1 << top
        id.mipmapLevelCount = top + 1
        id.arrayLength = 6
        id.storageMode = .private
        id.usage = .shaderRead
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = mipLevels > 1 ? .linear : .notMipmapped
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sd.maxAnisotropy = mipLevels > 1 ? 8 : 1
        sd.lodMaxClamp = Float(mipLevels - 1)
        guard let a = device.makeTexture(descriptor: ad), let i = device.makeTexture(descriptor: id),
              let s = device.makeSamplerState(descriptor: sd) else { throw Failure.noResources }
        a.label = "\(name) atlas"
        i.label = "\(name) indirection"
        atlas = a
        indirection = i
        sampler = s
        stagingSize = TileTexelMips.totalSize(across: across, channels: texel, levels: mipLevels)
        loader = PlanetTileLoader(format: layout.format, across: across, channels: channels, mipLevels: mipLevels, srgb: color)
        let empty = residency.indirection.hash.buckets
        guard let deep = device.makeBuffer(bytes: empty, length: empty.count * 4, options: .storageModeShared) else {
            throw Failure.noResources
        }
        deepTable = deep
        residency.markIndirectionDirty()
        if useIOQueue, layout.format.bytesPerSample != nil, fileURLs.count == catalog.files.count {
            let qd = MTLIOCommandQueueDescriptor()
            qd.type = .concurrent
            qd.priority = .normal
            if let q = try? device.makeIOCommandQueue(descriptor: qd) {
                let handles = fileURLs.compactMap { try? device.makeIOFileHandle(url: $0) }
                if handles.count == fileURLs.count { ioQueue = q; ioHandles = handles }
            }
        }
    }

    /// GPU memory the atlas and indirection take, bytes.
    public var memoryBytes: Int {
        let top = residency.indirection.textureMaxLevel
        let ind = (0 ... top).reduce(0) { $0 + 4 * 6 * (1 << (2 * $1)) }
        return slots * stagingSize + ind + deepTable.length
    }

    /// Whether raw tiles load through Metal's IO queue.
    public var usesIOQueue: Bool { ioQueue != nil }

    /// The layer's uniforms for this frame.
    public var uniforms: PlanetTileLayerUniforms {
        let l = catalog.layout
        let h = residency.indirection.hash
        return PlanetTileLayerUniforms(
            atlas: SIMD4(Float(l.tileSize), Float(l.border), Float(l.samplesAcross), Float(mipLevels - 1)),
            levels: SIMD4(Int32(catalog.maxLevel), Int32(residency.indirection.textureMaxLevel), Int32(h.capacity - 1),
                          Int32(h.maxProbe)),
            value: SIMD4(l.format.bytesPerSample == nil ? 1 : Float(l.scale * (l.format == .int16 ? 32_767 : 255)),
                         Float(l.offset), residency.residentCount > 0 ? 1 : 0, isColor ? 1 : 0))
    }

    /// Binds the layer for a fragment shader: atlas, indirection, deep
    /// table and uniforms at the given indices.
    public func bindFragment(_ enc: MTLRenderCommandEncoder, atlas a: Int, indirection i: Int, deep d: Int, uniforms u: Int) {
        enc.setFragmentTexture(atlas, index: a)
        enc.setFragmentTexture(indirection, index: i)
        enc.setFragmentBuffer(deepTable, offset: 0, index: d)
        var v = uniforms
        enc.setFragmentBytes(&v, length: MemoryLayout<PlanetTileLayerUniforms>.stride, index: u)
    }

    /// The same for a compute kernel.
    public func bindCompute(_ enc: MTLComputeCommandEncoder, atlas a: Int, indirection i: Int, deep d: Int, uniforms u: Int) {
        enc.setTexture(atlas, index: a)
        enc.setTexture(indirection, index: i)
        enc.setBuffer(deepTable, offset: 0, index: d)
        var v = uniforms
        enc.setBytes(&v, length: MemoryLayout<PlanetTileLayerUniforms>.stride, index: u)
    }

    // MARK: The frame

    /// One frame: `current` are the selection's wants (ordered coarse to
    /// fine, `PlanetTileWants.ordered`), `prefetch` the predicted views'.
    /// The pinned levels' tiles are always wanted, before both.
    /// Loads start for what is missing; uploads and the indirection's
    /// changes go into `blit`, on `commandBuffer`, whose completion frees
    /// what this frame dropped. `synchronous` loads every wanted tile now.
    public func update(current selected: [TileKey], prefetch: [TileKey] = [], commandBuffer: MTLCommandBuffer,
                       blit: MTLBlitCommandEncoder, synchronous: Bool = false) {
        let start = CACurrentMediaTime()
        let pinnedSet = Set(pinnedKeys)
        let current = pinnedKeys + selected.filter { !pinnedSet.contains($0) }
        frame += 1
        let done = completion.completedThrough
        residency.beginFrame(frame, completedThrough: done)
        if let done {
            var kept: [(buffer: MTLBuffer, frame: UInt64)] = []
            for b in busyStaging { if b.frame <= done { freeStaging.append(b.buffer) } else { kept.append(b) } }
            busyStaging = kept
        }
        var s = Stats()
        var mark = start
        func phase(_ i: Int) { let now = CACurrentMediaTime(); s.phases[i] = now - mark; mark = now }
        // Prefetch only what the atlas can hold beside the current wants.
        let wantedCurrent = Set(current)
        let room = max(0, slots - wantedCurrent.count - 3 * uploadsPerFrame)
        let prefetch = Array(prefetch.lazy.filter { !wantedCurrent.contains($0) }.prefix(room))
        for k in prefetch { residency.touch(k, current: false) }
        for k in current { residency.touch(k, current: true) }
        residency.reserve(uploadsPerFrame * 2)
        phase(0)

        // What finished loading since the last frame.
        func collect() {
            for r in loader.drain() {
                pending.remove(r.key)
                s.readBytes += r.bytes
                s.decodeSeconds += r.seconds
                if r.ok { ready[r.key] = r } else { freeStaging.append(r.staging) }
            }
        }
        collect()
        let wanted = wantedCurrent.union(prefetch)
        let all = current + prefetch
        // Drop what is no longer wanted.
        for (k, r) in ready where !wanted.contains(k) {
            ready[k] = nil
            freeStaging.append(r.staging)
        }

        var uploads = 0
        func admitReady(limit: Int) {
            for k in all where uploads < limit {
                guard let r = ready[k], residency.canAdmit(k) else { continue }
                guard let slot = residency.admit(k, current: wantedCurrent.contains(k)) else { continue }
                ready[k] = nil
                upload(r.staging, slot: slot, blit: blit)
                busyStaging.append((r.staging, frame))
                uploads += 1
                s.uploadBytes += stagingSize
            }
        }

        func request() {
            for k in all where pending.count < maxPendingLoads {
                guard !residency.isResident(k), !pending.contains(k), ready[k] == nil else { continue }
                // Its parent must be on its way, or the child would only wait.
                if let p = k.parent, !residency.isResident(p), !pending.contains(p), ready[p] == nil { continue }
                guard let staging = takeStaging() else { break }
                load(k, into: staging)
                s.requested += 1
            }
        }

        phase(1)
        if synchronous {
            // Load everything wanted now, coarse to fine, as many passes as
            // the levels need.
            unbounded = true
            defer { unbounded = false }
            var rounds = 0
            while rounds < 32 {
                rounds += 1
                request()
                loader.waitForAll()
                collect()
                let before = uploads
                admitReady(limit: Int.max)
                if uploads == before && pending.isEmpty { break }
            }
        } else {
            admitReady(limit: uploadsPerFrame)
            phase(2)
            request()
            phase(3)
        }

        s.indirectionBytes = uploadIndirection(blit: blit)
        phase(4)
        let c = residency.takeCounters()
        s.uploaded = c.admitted
        s.evicted = c.evicted
        s.refused = c.refused
        s.resident = residency.residentCount
        s.pending = pending.count + ready.count
        s.missing = current.filter { !residency.isResident($0) }.count
        let f = frame, tracker = completion
        commandBuffer.addCompletedHandler { _ in tracker.complete(f) }
        s.updateSeconds = CACurrentMediaTime() - start
        stats = s
    }

    /// Starts over, as a new cache would (`SceneRenderer.startOver`, with
    /// no frame in flight): no tile is resident, the pinned levels' neither,
    /// so the next update loads what it wants afresh (a snapshot's at once)
    /// and no tile of an earlier shot is drawn or keeps its tiles out. Loads
    /// in flight finish and are dropped; the staging buffers are kept.
    func startOver() {
        loader.waitForAll()
        for r in loader.drain() { freeStaging.append(r.staging) }
        for r in ready.values { freeStaging.append(r.staging) }
        ready = [:]
        pending = []
        freeStaging += busyStaging.map(\.buffer)
        busyStaging = []
        residency = PlanetTileResidency(slots: slots, maxLevel: catalog.maxLevel, pinnedLevel: residency.pinnedLevel,
                                        maxTextureLevel: residency.indirection.textureMaxLevel)
        // The whole indirection and the deep table go up again, empty.
        residency.markIndirectionDirty()
    }

    private func takeStaging() -> MTLBuffer? {
        if let b = freeStaging.popLast() { return b }
        // Enough for every load in flight and three frames of uploads.
        guard unbounded || freeStaging.count + busyStaging.count + pending.count + ready.count < maxPendingLoads + 3 * uploadsPerFrame + 8,
              let b = device.makeBuffer(length: stagingSize, options: .storageModeShared) else { return nil }
        b.label = "\(name) staging"
        return b
    }

    private func load(_ key: TileKey, into staging: MTLBuffer) {
        pending.insert(key)
        guard let (file, entry) = catalog.entry(key) else {
            loader.submit(.init(key: key, staging: staging, payload: nil))
            return
        }
        if let io = ioQueue {
            let cb = io.makeCommandBuffer()
            cb.load(staging, offset: 0, size: entry.length, sourceHandle: ioHandles[file], sourceHandleOffset: entry.offset)
            let loader = self.loader, start = CACurrentMediaTime(), length = entry.length
            // The load's tile and buffer, handed to Metal's completion thread
            // and back; nothing else touches them meanwhile.
            let load = IOLoad(key: key, staging: staging)
            loader.enterIO()
            cb.addCompletedHandler { b in
                loader.finish(.init(key: load.key, staging: load.staging, ok: b.status == .complete,
                                    seconds: CACurrentMediaTime() - start, bytes: length))
            }
            cb.commit()
            return
        }
        loader.submit(.init(key: key, staging: staging, payload: catalog.payload(key)))
    }

    /// Blits a decoded tile's mips into its slot.
    private func upload(_ staging: MTLBuffer, slot: Int, blit: MTLBlitCommandEncoder) {
        var offset = 0
        for level in 0 ..< mipLevels {
            let side = max(1, across >> level)
            blit.copy(from: staging, sourceOffset: offset, sourceBytesPerRow: side * texelBytes,
                      sourceBytesPerImage: side * side * texelBytes, sourceSize: MTLSize(width: side, height: side, depth: 1),
                      to: atlas, destinationSlice: slot, destinationLevel: level,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            offset += side * side * texelBytes
        }
    }

    /// Blits the indirection's changed rectangles; replaces the deep table
    /// if it changed. Returns the bytes uploaded.
    private func uploadIndirection(blit: MTLBlitCommandEncoder) -> Int {
        let (regions, hash) = residency.takeIndirectionChanges()
        if hash {
            let b = residency.indirection.hash.buckets
            if let buffer = device.makeBuffer(bytes: b, length: b.count * 4, options: .storageModeShared) {
                buffer.label = "\(name) deep table"
                deepTable = buffer
            }
        }
        guard !regions.isEmpty else { return hash ? deepTable.length : 0 }
        let total = regions.reduce(0) { $0 + ($1.x1 - $1.x0) * ($1.y1 - $1.y0) * 4 }
        guard let staging = device.makeBuffer(length: total, options: .storageModeShared) else { return 0 }
        let top = residency.indirection.textureMaxLevel
        var offset = 0
        let base = staging.contents()
        for r in regions {
            let w = r.x1 - r.x0, h = r.y1 - r.y0, side = 1 << r.level
            residency.indirection.table[r.face][r.level].withUnsafeBytes { src in
                for y in 0 ..< h {
                    (base + offset + y * w * 4).copyMemory(from: src.baseAddress! + ((r.y0 + y) * side + r.x0) * 4,
                                                           byteCount: w * 4)
                }
            }
            blit.copy(from: staging, sourceOffset: offset, sourceBytesPerRow: w * 4, sourceBytesPerImage: w * h * 4,
                      sourceSize: MTLSize(width: w, height: h, depth: 1), to: indirection, destinationSlice: r.face,
                      destinationLevel: top - r.level, destinationOrigin: MTLOrigin(x: r.x0, y: r.y0, z: 0))
            offset += w * h * 4
        }
        return total + (hash ? deepTable.length : 0)
    }
}
