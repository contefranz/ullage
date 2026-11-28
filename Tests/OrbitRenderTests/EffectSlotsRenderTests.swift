import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// R6's effect slots on the GPU, against OrbitScene's maths: the depth
/// downsample, the composite (upsample, OIT resolve, order), the fronts,
/// OIT's order independence, the upsample at an edge, the cone's proxy,
/// and no cost on frames without effects.
@MainActor
final class EffectSlotsRenderTests: XCTestCase {
    static var snapper: SnapshotRenderer?

    func snapper() throws -> SnapshotRenderer {
        if let s = Self.snapper { return s }
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        Self.snapper = s
        return s
    }

    /// Reads the frame's textures back after the scene (P4).
    final class Capture: RenderPass {
        let name = "Capture"
        let stage = PassStage.post
        let order = 2_000
        var reads: Set<ResourceID> { [.sceneDepth] }
        static let ids: [ResourceID] = [.sceneDepth, .halfResDepth, .halfResPixelDepths, .halfResClouds,
                                        .halfResTransparent, .oitAccumulation, .oitRevealage, .halfResFronts,
                                        .halfResClips]
        var images: [ResourceID: (width: Int, height: Int, format: MTLPixelFormat, buffer: MTLBuffer)] = [:]

        func encode(_ f: FrameContext, _ e: PassEncoding) {
            images = [:]
            guard let blit = f.makeBlitEncoder() else { return }
            for id in Self.ids {
                guard let t = f.textures[id] else { continue }
                let bpp: Int
                switch t.pixelFormat {
                case .rgba32Float: bpp = 16
                case .rg32Float, .rgba16Float: bpp = 8
                case .r16Float, .rg8Unorm: bpp = 2
                default: bpp = 4
                }
                guard let b = f.device.makeBuffer(length: t.width * t.height * bpp, options: .storageModeShared) else {
                    continue
                }
                blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                          sourceSize: MTLSize(width: t.width, height: t.height, depth: 1), to: b, destinationOffset: 0,
                          destinationBytesPerRow: t.width * bpp, destinationBytesPerImage: t.width * t.height * bpp)
                images[id] = (t.width, t.height, t.pixelFormat, b)
            }
            blit.endEncoding()
        }

        /// The image's channels as Double, texel by texel (row-major).
        func values(_ id: ResourceID) -> (width: Int, height: Int, texels: [[Double]])? {
            guard let i = images[id] else { return nil }
            let n = i.width * i.height
            switch i.format {
            case .rgba32Float:
                let p = i.buffer.contents().bindMemory(to: Float.self, capacity: 4 * n)
                return (i.width, i.height, (0..<n).map { t in (0..<4).map { Double(p[4 * t + $0]) } })
            case .rg32Float:
                let p = i.buffer.contents().bindMemory(to: Float.self, capacity: 2 * n)
                return (i.width, i.height, (0..<n).map { [Double(p[2 * $0]), Double(p[2 * $0 + 1])] })
            case .rgba16Float:
                let p = i.buffer.contents().bindMemory(to: UInt16.self, capacity: 4 * n)
                return (i.width, i.height, (0..<n).map { t in (0..<4).map { Double(Float(Float16(bitPattern: p[4 * t + $0]))) } })
            case .r16Float:
                let p = i.buffer.contents().bindMemory(to: UInt16.self, capacity: n)
                return (i.width, i.height, (0..<n).map { [Double(Float(Float16(bitPattern: p[$0])))] })
            case .rg8Unorm:
                // The clip codes, as bytes (0...255).
                let p = i.buffer.contents().bindMemory(to: UInt8.self, capacity: 2 * n)
                return (i.width, i.height, (0..<n).map { [Double(p[2 * $0]), Double(p[2 * $0 + 1])] })
            default:
                let p = i.buffer.contents().bindMemory(to: Float.self, capacity: n)
                return (i.width, i.height, (0..<n).map { [Double(p[$0])] })
            }
        }
    }

    /// Low Earth orbit, the camera 150 m from the capsule, which the
    /// backdrop wipes: only the test emitters show.
    static func shot(_ emitters: [EffectTestEmitter], backdrop: Bool = true, resolution: EffectResolution = .half,
                     tolerance: Double = 0.1, width: Int = 160, height: Int = 100) -> SnapshotSpec.Shot {
        var shot = SnapshotSpec.Shot(name: "r6-test", scenario: "leo",
                                     camera: SnapshotSpec.CameraSpec(yaw: 30, pitch: 20, distance: 150, fov: 40))
        shot.width = width
        shot.height = height
        shot.showOrbit = false
        shot.settings.transparency.testEmitters = emitters
        shot.settings.transparency.testBackdrop = backdrop
        shot.settings.transparency.resolution = resolution
        shot.settings.transparency.upsampleTolerance = tolerance
        return shot
    }

    static let column = EffectTestEmitter(.column, position: [0, 0, -40], size: 80)
    static let slab = EffectTestEmitter(.slab, size: 70)
    static let sprites = EffectTestEmitter(.sprites, position: [-30, 20, 25], size: 20, count: 12)
    static let cone = EffectTestEmitter(.cone, position: [20, -10, 45], size: 60, axis: [0.3, 0, -1])

    struct Frame {
        let pixels: [UInt8]
        let capture: Capture
        let scene: RenderScene
        let renderer: SceneRenderer
    }

    /// Renders `shot` with the default passes and a capture after them, on
    /// the direct plan (whose output the LDR maths can check) or, with
    /// `shipping`, the HDR plan the renderer ships.
    func render(_ shot: SnapshotSpec.Shot, shipping: Bool = false,
                configure: ((SceneRenderer) -> Void)? = nil) throws -> Frame {
        let s = try snapper()
        let prepared = try shot.prepare(system: s.system)
        let scene = shot.scene(prepared)
        let capture = Capture()
        let plan: SceneTargetPlan = shipping ? HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4)
                                             : DirectTargetPlan(colorFormat: .bgra8Unorm_srgb, sampleCount: 4)
        let r = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb,
                                  passes: SceneRenderer.defaultPasses(loadsUserTextures: false) + [capture],
                                  plan: plan)
        r.setStars(s.stars)
        r.settings = shot.settings
        configure?(r)
        // R6's passes set up; others may need another plan's targets (R1's
        // post on this direct plan, which keeps the LDR maths checkable).
        let r6 = ["Half-resolution transparents", "Transparent composite", "Effect slots debug view",
                  "Effect test opaque", "Effect test sparks"]
            + [ShaderModule.halfResTransparent, .transparentComposite, .effectTest].map(\.name)
        XCTAssertEqual(r.failures.filter { r6.contains($0.key) }, [:])
        XCTAssertEqual(r.graph.passes.compactMap { $0 as? HalfResTransparentPass }.first?.effectFailures, [:])
        let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: shot.width, height: shot.height))
        let cb = try XCTUnwrap(r.renderAndWait(scene, into: target))
        XCTAssertNil(cb.error)
        return Frame(pixels: target.bytes(), capture: capture, scene: scene, renderer: r)
    }

    static func linear(_ byte: UInt8) -> Double {
        let c = Double(byte) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func srgb(_ linear: Double) -> Double {
        let c = min(max(linear, 0), 1)
        return 255 * (c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
    }

    // MARK: Depth

    /// The test depth and its other extreme are the maths' checkerboard of
    /// the resolved scene depth, at half and full resolution; the
    /// composite's copy of the depth holds each pixel exactly.
    func testDepthDownsampleMatchesTheMaths() throws {
        for resolution in EffectResolution.allCases {
            let f = try render(Self.shot([Self.column, Self.slab], resolution: resolution))
            let scene = try XCTUnwrap(f.capture.values(.sceneDepth)), half = try XCTUnwrap(f.capture.values(.halfResDepth))
            let pixels = try XCTUnwrap(f.capture.values(.halfResPixelDepths))
            let s = resolution.scale
            XCTAssertTrue(EffectSlots.targetSize(width: 160, height: 100, scale: s) == (half.width, half.height))
            var edges = 0
            for y in 0..<half.height {
                for x in 0..<half.width {
                    var quad: [Double] = []
                    for dy in 0..<s {
                        for dx in 0..<s where s * x + dx < scene.width && s * y + dy < scene.height {
                            let d = scene.texels[(s * y + dy) * scene.width + s * x + dx][0]
                            quad.append(d)
                            XCTAssertEqual(pixels.texels[y * half.width + x][2 * dy + dx], d, "\(resolution) pixel copy")
                        }
                    }
                    let want = EffectSlots.halfResDepth(quad, x: x, y: y), got = half.texels[y * half.width + x]
                    XCTAssertEqual(got[0], want.test, "\(resolution) \(x), \(y)")
                    XCTAssertEqual(got[1], want.other, "\(resolution) \(x), \(y)")
                    if want.test != want.other { edges += 1 }
                }
            }
            if resolution == .half { XCTAssertGreaterThan(edges, 20, "the column's edges are in the frame") }
        }
    }

    // MARK: Composite

    /// What the composite reads of a frame's texels to tell where their
    /// effects ended, decoded once per frame.
    struct Ends {
        let depth: [[Double]], fronts: [[Double]], clips: [[Double]]
        let near: Double

        @MainActor init(_ f: Frame) throws {
            depth = try XCTUnwrap(f.capture.values(.halfResDepth)).texels
            fronts = try XCTUnwrap(f.capture.values(.halfResFronts)).texels
            clips = try XCTUnwrap(f.capture.values(.halfResClips)).texels
            near = f.scene.camera.near
        }

        /// The texels' ends as the composite reads them
        /// (`EffectSlots.texelEnded`) for a pixel of reversed-Z depth z,
        /// every layer drawn and reconstructed.
        func ended(texels index: [Int], pixel z: Double) -> [Bool] {
            index.map { i in
                EffectSlots.texelEnded(back: fronts[i][3], clouds: Int(clips[i][0]), oit: Int(clips[i][1]),
                                       texel: EffectSlots.linearDepth(reversedZ: depth[i][0], near: near, pixel: false),
                                       pixel: EffectSlots.linearDepth(reversedZ: z, near: near, pixel: true),
                                       drawn: [.clouds, .volumes, .oit], reconstructed: [.clouds, .volumes, .oit])
            }
        }
    }

    /// The GPU's composite against the maths', pixel by pixel.
    struct CompositeReport {
        var off = 0, covered = 0, worst = 0.0
        /// Covered pixels by how they were reconstructed.
        var kinds: [EffectSlots.Reconstruction: Int] = [:]
        /// Covered pixels whose four texels' depths differ beyond the
        /// tolerance, by how they were reconstructed, and how depth alone
        /// would have.
        var acrossDepths: [EffectSlots.Reconstruction: Int] = [:]
        var acrossDepthsAlone: [EffectSlots.Reconstruction: Int] = [:]
    }

    /// Each pixel of `f` against `EffectSlots.compositePixel` over `opaque`
    /// (the frame without effects), the weights from the depths and the
    /// writers' codes (`ended`).
    func composite(_ f: Frame, over opaque: Frame, scale: Int, width: Int = 160, height: Int = 100) throws -> CompositeReport {
        let c = f.capture
        let scene = try XCTUnwrap(c.values(.sceneDepth)), depth = try XCTUnwrap(c.values(.halfResDepth))
        let clouds = try XCTUnwrap(c.values(.halfResClouds)), volumes = try XCTUnwrap(c.values(.halfResTransparent))
        let accumulation = try XCTUnwrap(c.values(.oitAccumulation)), revealage = try XCTUnwrap(c.values(.oitRevealage))
        let fronts = try XCTUnwrap(c.values(.halfResFronts))
        func p(_ v: [Double]) -> EffectSlots.Premultiplied { .init(v[0], v[1], v[2], v[3]) }
        let ends = try Ends(f)
        var out = CompositeReport()
        for y in 0..<height {
            for x in 0..<width {
                let fp = EffectSlots.upsampleFootprint(pixelX: x, pixelY: y, scale: scale, width: depth.width,
                                                       height: depth.height)
                let index = fp.texels.map { $0.y * depth.width + $0.x }
                let z = scene.texels[y * width + x][0], depths = index.map { depth.texels[$0][0] }
                let r = EffectSlots.reconstruction(bilinear: fp.bilinear, depths: depths, depth: z, tolerance: 0.1,
                                                   ended: ends.ended(texels: index, pixel: z))
                let texels = index.map { i in
                    EffectSlots.Texel(clouds: p(clouds.texels[i]), volumes: p(volumes.texels[i]),
                                      accumulation: p(accumulation.texels[i]), revealage: revealage.texels[i][0],
                                      fronts: Array(fronts.texels[i][0..<3]))
                }
                let mix = EffectSlots.compositePixel(texels, weights: r.weights, drawn: [.clouds, .volumes, .oit])
                if mix.a > 0.01 {
                    out.covered += 1
                    out.kinds[r.kind, default: 0] += 1
                    let alone = EffectSlots.reconstruction(bilinear: fp.bilinear, depths: depths, depth: z, tolerance: 0.1,
                                                           ended: [false, false, false, false])
                    if scale > 1 && alone.kind != .bilinear {
                        out.acrossDepths[r.kind, default: 0] += 1
                        out.acrossDepthsAlone[alone.kind, default: 0] += 1
                    }
                }
                let i = 4 * (y * width + x)
                // BGRA: the composite over the frame without effects.
                for (k, channel) in [(2, mix.r), (1, mix.g), (0, mix.b)] {
                    let want = Self.srgb(channel + (1 - mix.a) * Self.linear(opaque.pixels[i + k]))
                    let error = abs(want - Double(f.pixels[i + k]))
                    out.worst = max(out.worst, error)
                    if error > 2.5 { out.off += 1 }
                }
            }
        }
        return out
    }

    /// Every pixel's composite is the maths' (the reconstruction's weights
    /// from the depths and the writers' codes, the OIT resolve, the front
    /// order) over the frame without effects, at half and full resolution,
    /// around the column and over a floor.
    func testCompositeMatchesTheMaths() throws {
        let floor = EffectTestEmitter(.floor, position: [0, 0, -45], size: 4_000)
        for resolution in EffectResolution.allCases {
            let opaque = try render(Self.shot([Self.column, floor], resolution: resolution))
            let f = try render(Self.shot([Self.column, floor, Self.slab, Self.cone, Self.sprites], resolution: resolution))
            XCTAssertEqual(f.renderer.graph.passes.compactMap { $0 as? HalfResTransparentPass }.first?.reconstructed,
                           [.clouds, .volumes, .oit])
            let r = try composite(f, over: opaque, scale: resolution.scale)
            print("Composite at \(resolution): \(r.covered) pixels covered, by kind \(r.kinds)")
            XCTAssertGreaterThan(r.covered, 4_000, "\(resolution): the effects cover much of the frame")
            XCTAssertLessThanOrEqual(r.off, 40, "\(resolution): channels off by more than 2.5/255 (worst \(r.worst))")
            if resolution == .half {
                XCTAssertGreaterThan(r.kinds[.renormalised] ?? 0, 0, "the column's edges")
                XCTAssertGreaterThan(r.kinds[.bilinear] ?? 0, 3 * ((r.kinds[.renormalised] ?? 0) + (r.kinds[.nearest] ?? 0)))
            }
        }
    }

    /// LR0's ramp: a floor seen from 10 m above it, 1.5° down, its depth
    /// changing 15 % a row and more toward the horizon, the slab (clouds), the
    /// cone (volumes) and sprites (OIT) wholly in front of it. Every
    /// covered pixel whose texels' depths differ is reconstructed exactly
    /// bilinearly from the writers' codes, where depth alone would have
    /// taken the stairs; and the GPU's composite is the maths'.
    func testExactlyBilinearInFrontOfARamp() throws {
        let emitters = Self.rampEmitters
        var shot = Self.shot(emitters, width: 160, height: 100)
        shot.camera = SnapshotSpec.CameraSpec(yaw: 30, pitch: 1.5, distance: 150, fov: 40)
        var bare = shot
        bare.settings.transparency.testEmitters = [emitters[0]]
        let f = try render(shot), opaque = try render(bare)
        // The ramp: depth from row to row across the floor.
        let scene = try XCTUnwrap(f.capture.values(.sceneDepth))
        var steep = 0, steeper = 0
        for y in 1..<100 where scene.texels[y * 160 + 80][0] > 0 && scene.texels[(y - 1) * 160 + 80][0] > 0 {
            let ratio = scene.texels[y * 160 + 80][0] / scene.texels[(y - 1) * 160 + 80][0]
            if ratio > 1.15 { steep += 1 }
            if ratio > 1.3 { steeper += 1 }
        }
        XCTAssertGreaterThanOrEqual(steep, 6, "rows whose depth changes over 15 %")
        XCTAssertGreaterThanOrEqual(steeper, 2, "rows whose depth changes over 30 %")
        let r = try composite(f, over: opaque, scale: 2)
        let across = r.acrossDepths.values.reduce(0, +)
        print("Ramp: \(r.covered) covered, across depths \(r.acrossDepths), by depth alone \(r.acrossDepthsAlone)")
        XCTAssertGreaterThan(across, 300, "covered pixels whose texels' depths differ")
        XCTAssertEqual(r.acrossDepths[.bilinear] ?? 0, across, "exactly bilinear")
        XCTAssertLessThan(r.acrossDepthsAlone[.bilinear] ?? 0, 1, "depth alone: never bilinear there")
        XCTAssertLessThanOrEqual(r.off, 20, "channels off by more than 2.5/255 (worst \(r.worst))")
    }

    /// The ramp's emitters: the floor 6 m below the target, the slab 4 m
    /// above it, the cone level beside it (half a metre above it at its
    /// widest), sprites over them.
    static let rampEmitters = [
        EffectTestEmitter(.floor, position: [0, 0, -6], size: 20_000),
        EffectTestEmitter(.slab, position: [0, 0, 0], size: 20),
        EffectTestEmitter(.cone, position: [-30, 15, 2], size: 30, axis: [1, 0, 0]),
        EffectTestEmitter(.sprites, position: [10, -10, 5], size: 6, count: 8),
    ]

    /// The writers' codes against the geometry: the slab's clip code is its
    /// far face in front of the texel's scene, rounded down (cut where the
    /// column lies in front of that); the cone's back lies behind its last
    /// visible step and in front of the texel's scene, or is cut; the
    /// sprites' clip codes where their fade starts.
    func testWritersReportWhereTheirEffectsEnded() throws {
        let f = try render(Self.shot([Self.column, Self.slab, Self.cone, Self.sprites], width: 320, height: 200))
        let depth = try XCTUnwrap(f.capture.values(.halfResDepth)), fronts = try XCTUnwrap(f.capture.values(.halfResFronts))
        let clips = try XCTUnwrap(f.capture.values(.halfResClips)), clouds = try XCTUnwrap(f.capture.values(.halfResClouds))
        let volumes = try XCTUnwrap(f.capture.values(.halfResTransparent))
        let slab = EffectTestScene.slab(Self.slab, in: EffectTargetFrame(scene: f.scene))
        let cam = f.scene.camera, t = tan(cam.fovY / 2), near = cam.near
        let aspect = Double(depth.width) / Double(depth.height)
        var slabCodes = 0, slabCut = 0, coneBacks = 0, coneCut = 0
        for y in 0..<depth.height {
            for x in 0..<depth.width {
                let i = y * depth.width + x
                let z = depth.texels[i][0], s = z > 0 ? near / z : EffectSlots.skyDistance
                // The texel's ray, metres per metre of depth.
                let vx = (2 * (Double(x) + 0.5) / Double(depth.width) - 1) * t * aspect
                let vy = (1 - 2 * (Double(y) + 0.5) / Double(depth.height)) * t
                let ray = cam.worldToView.transposed * Vec3(vx, vy, -1)
                if let exit = Self.boxExit(ray, slab), clouds.texels[i][3] > 1e-3 || clips.texels[i][0] == 0 {
                    let want = EffectSlots.clipCode(endsAt: exit, sceneDepth: s)
                    XCTAssertLessThanOrEqual(abs(Int(clips.texels[i][0]) - want), 1, "slab at \(x), \(y)")
                    if want == 0 { slabCut += 1 } else { slabCodes += 1 }
                }
                let back = fronts.texels[i][3]
                if volumes.texels[i][3] > 0.01 {
                    if back >= EffectSlots.noFront {
                        coneCut += 1
                    } else {
                        XCTAssertLessThanOrEqual(back, log2(s) + 2 * EffectSlots.backMargin, "cone at \(x), \(y)")
                        XCTAssertGreaterThan(back, fronts.texels[i][1], "behind its front")
                        coneBacks += 1
                    }
                }
            }
        }
        print("Writers: slab \(slabCodes) coded, \(slabCut) cut; cone \(coneBacks) backs, \(coneCut) cut")
        XCTAssertGreaterThan(slabCodes, 500)
        XCTAssertGreaterThan(slabCut, 20, "the column cuts the slab")
        XCTAssertGreaterThan(coneBacks, 200)
        XCTAssertGreaterThan(clips.texels.filter { $0[1] > 0 && $0[1] < 255 }.count, 50, "the sprites' codes")
    }

    /// Where a ray (metres per metre of depth, camera-relative) leaves the
    /// slab's box, in linear depth; nil if it misses.
    static func boxExit(_ ray: Vec3, _ b: EffectTestScene.Slab) -> Double? {
        let axes = [b.axes.0, b.axes.1, b.axes.2], h = [b.halfExtents.x, b.halfExtents.y, b.halfExtents.z]
        var enter = 0.0, exit = Double.infinity
        for k in 0..<3 {
            let o = -b.center.dot(axes[k]), d = ray.dot(axes[k])
            if abs(d) < 1e-12 {
                if abs(o) > h[k] { return nil }
                continue
            }
            let t0 = (-h[k] - o) / d, t1 = (h[k] - o) / d
            enter = max(enter, min(t0, t1))
            exit = min(exit, max(t0, t1))
        }
        return exit > enter ? exit : nil
    }

    // MARK: Fronts

    /// The slab reports its front where it becomes visible, as
    /// `EffectSlots.homogeneousFront` puts it for its source radiance (its
    /// colour over its coverage, here read back), to the code's precision:
    /// a dense slab, and an optically thin, bright one, whose radiance
    /// brings its front well before its coverage would (or gives it one
    /// where its coverage never reaches 2 %).
    func testSlabReportsItsFront() throws {
        var movedByRadiance = 0
        for emitter in [Self.slab, EffectTestEmitter(.slab, size: 70, opticalDepth: 0.05)] {
            let f = try render(Self.shot([emitter]))
            let fronts = try XCTUnwrap(f.capture.values(.halfResFronts))
            let clouds = try XCTUnwrap(f.capture.values(.halfResClouds))
            let slab = EffectTestScene.slab(emitter, in: EffectTargetFrame(scene: f.scene))
            let cam = f.scene.camera, t = tan(cam.fovY / 2)
            var checked = 0
            for y in stride(from: 3, to: fronts.height, by: 6) {
                for x in stride(from: 3, to: fronts.width, by: 6) {
                    // The texel's centre ray, z = -1 in view axes: s along it is s metres deep.
                    let px = (Double(x) + 0.5) * 2, py = (Double(y) + 0.5) * 2
                    let view = Vec3((2 * px / 160 - 1) * t * cam.aspect, (1 - 2 * py / 100) * t, -1)
                    let dir = cam.worldToView.transposed * view
                    var enter = 0.0, exit = Double.infinity
                    for (axis, h) in [(slab.axes.east, slab.halfExtents.x), (slab.axes.north, slab.halfExtents.y),
                                      (slab.axes.up, slab.halfExtents.z)] {
                        let o = (-slab.center).dot(axis), d = dir.dot(axis)
                        let t0 = (-h - o) / d, t1 = (h - o) / d
                        enter = max(enter, min(t0, t1))
                        exit = min(exit, max(t0, t1))
                    }
                    let code = fronts.texels[y * fronts.width + x][0], c = clouds.texels[y * clouds.width + x]
                    let source = c[3] > 0 ? c[0..<3].max()! / c[3] : 0
                    let extinction = slab.extinction * dir.length
                    // Skip texels within a quarter texel of the slab's edge, where its ray barely enters.
                    guard exit > enter + 1, let front = EffectSlots.homogeneousFront(entry: enter, exit: exit,
                                                                                     extinction: extinction,
                                                                                     source: source)
                    else {
                        if exit <= enter { XCTAssertEqual(code, EffectSlots.noFront, "\(x), \(y): no front") }
                        continue
                    }
                    checked += 1
                    XCTAssertEqual(EffectSlots.linearDepth(frontCode: code) / front, 1, accuracy: 0.004,
                                   "\(emitter.opticalDepth): \(x), \(y)")
                    let byCoverage = EffectSlots.homogeneousFront(entry: enter, exit: exit, extinction: extinction)
                    if byCoverage.map({ $0 / front - 1 > 0.015 }) ?? true { movedByRadiance += 1 }
                }
            }
            XCTAssertGreaterThanOrEqual(checked, 20, "optical depth \(emitter.opticalDepth)")
        }
        XCTAssertGreaterThanOrEqual(movedByRadiance, 10, "the radiance brings fronts forward by over 1.5 %")
    }

    /// A bright, optically thin volume in front of a dense one: the cone's
    /// rim and tips, under 2 % coverage but visibly bright, report their
    /// fronts, nearer than the slab behind them, so they go over it.
    func testABrightThinVolumeReportsItsFront() throws {
        let f = try render(Self.shot([EffectTestEmitter(.cone, position: [0, 30, 45], size: 36), Self.slab]))
        let volumes = try XCTUnwrap(f.capture.values(.halfResTransparent))
        let clouds = try XCTUnwrap(f.capture.values(.halfResClouds))
        let fronts = try XCTUnwrap(f.capture.values(.halfResFronts))
        var thin = 0
        for i in volumes.texels.indices {
            let v = volumes.texels[i], radiance = v[0..<3].max()!
            guard v[3] > 0, v[3] < EffectSlots.frontOpacity, radiance >= 2 * EffectSlots.frontRadiance,
                  clouds.texels[i][3] > 0.5 else { continue }
            thin += 1
            XCTAssertLessThan(fronts.texels[i][1], fronts.texels[i][0], "texel \(i): the glow in front of the deck")
        }
        XCTAssertGreaterThan(thin, 20, "thin, bright texels before the deck")
    }

    /// Two bright cones in one place, at a manual EV -2 on the shipping plan:
    /// each is held below 6e4, but over each other they pass it in the
    /// volumes layer (this GPU's half-float blend saturates at 65504; another
    /// may overflow to +inf). The frame stays bright where one cone alone is
    /// bright: no hole.
    func testOverlappingBrightVolumesSaturate() throws {
        func shot(_ cones: Int) -> SnapshotSpec.Shot {
            var s = Self.shot(Array(repeating: EffectTestEmitter(.cone, position: [0, 0, 32], size: 64), count: cones))
            s.camera = SnapshotSpec.CameraSpec(yaw: 30, pitch: 10, distance: 120, fov: 40)
            s.settings.post.exposure.mode = .manual
            s.settings.post.exposure.ev100 = -2
            return s
        }
        let one = try render(shot(1), shipping: true), two = try render(shot(2), shipping: true)
        let volumes = try XCTUnwrap(two.capture.values(.halfResTransparent))
        let past = volumes.texels.filter { $0[0] > EffectSlots.maxRadiance }.count
        XCTAssertGreaterThan(past, 20, "the two cones' sum passes 6e4")
        func luma(_ p: [UInt8], _ i: Int) -> Int { (Int(p[i]) + 2 * Int(p[i + 1]) + Int(p[i + 2])) / 4 }
        var bright = 0
        for i in stride(from: 0, to: one.pixels.count, by: 4) where luma(one.pixels, i) > 200 {
            bright += 1
            XCTAssertGreaterThanOrEqual(luma(two.pixels, i), luma(one.pixels, i) - 8, "pixel \(i / 4): no hole")
        }
        XCTAssertGreaterThan(bright, 200)
    }

    /// An effect writes +inf, NaN and an ordinary colour into the volumes
    /// layer, a third of the frame each. The composite saturates +inf (white),
    /// takes NaN for no light (the black scene shows), and composites the
    /// rest as it is: an overflow is never a hole.
    func testTheCompositeTakesNonFiniteLayersAsR1Does() throws {
        final class Injector: HalfResEffect {
            let name = "Injector"
            var pipeline: MTLRenderPipelineState?
            func setUpHalfRes(_ s: HalfResSetup) throws {
                let library = try s.shaders.library(ShaderModule(name: "EffectInjector", headers: [.effectSlots], source: """
                    struct InjectorOut { float4 position [[position]]; };
                    vertex InjectorOut injector_vertex(uint vid [[vertex_id]]) {
                        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
                        InjectorOut o;
                        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
                        return o;
                    }
                    fragment EffectVolumeOut injector_fragment(InjectorOut in [[stage_in]],
                                                               constant EffectSlotUniforms &e [[buffer(ORBIT_EFFECT_BUFFER_SLOTS)]]) {
                        float third = e.target.x / 3.0;
                        float inf = as_type<float>(0x7f800000u), nan = as_type<float>(0x7fc00000u);
                        EffectVolumeOut o;
                        o.color = in.position.x < third ? float4(inf, inf, inf, 0.5)
                                : (in.position.x < 2.0 * third ? float4(nan, nan, nan, 0.5) : float4(0.5, 0.25, 0.1, 0.5));
                        o.front = float4(orbit_frontCode(10.0));
                        return o;
                    }
                    """))
                pipeline = try s.pipeline(library, vertex: "injector_vertex", fragment: "injector_fragment", layer: .volumes)
            }
            func halfResLayers(in f: FrameContext) -> HalfResLayers { .volumes }
            func encodeHalfRes(_ f: FrameContext, _ slots: HalfResSlots, _ enc: MTLRenderCommandEncoder) {
                guard let pipeline else { return }
                enc.setRenderPipelineState(pipeline)
                enc.setDepthStencilState(slots.noDepth)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }
        let device = try XCTUnwrap(RenderDevice.shared)
        let slots = HalfResTransparentPass(effects: [Injector()])
        let capture = Capture()
        let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb,
                                  passes: [slots, TransparentCompositePass(slots: slots), capture],
                                  plan: DirectTargetPlan(colorFormat: .bgra8Unorm_srgb, sampleCount: 4))
        XCTAssertEqual(r.failures, [:])
        XCTAssertEqual(slots.effectFailures, [:])
        let target = try XCTUnwrap(OffscreenTarget(device: device, width: 96, height: 32))
        r.renderAndWait(FrameGraphTests.emptyScene(width: 96, height: 32), into: target)
        let volumes = try XCTUnwrap(capture.values(.halfResTransparent))
        XCTAssertTrue(volumes.texels[0][0].isInfinite, "the layer holds +inf")
        XCTAssertTrue(volumes.texels[volumes.width / 2][0].isNaN, "and NaN")
        let p = target.bytes()
        func pixel(_ x: Int) -> [Int] { (0..<3).map { Int(p[4 * (16 * 96 + x) + 2 - $0]) } }   // RGB
        XCTAssertEqual(pixel(8), [255, 255, 255], "+inf saturates")
        XCTAssertEqual(pixel(48), [0, 0, 0], "NaN is no light")
        let finite = pixel(88)
        XCTAssertEqual(Double(finite[0]), EffectSlotsRenderTests.srgb(0.5), accuracy: 1.5)
        XCTAssertEqual(Double(finite[1]), EffectSlotsRenderTests.srgb(0.25), accuracy: 1.5)
    }

    // MARK: OIT

    /// The sprites drawn last to first give the same frame: weighted-blended
    /// OIT is order-independent (to a half's rounding).
    func testOITIsOrderIndependent() throws {
        let shot = Self.shot([EffectTestEmitter(.sprites, size: 30, count: 24)])
        let forward = try render(shot)
        var reversed = false
        let backward = try render(shot) { r in
            // The test emitters wherever they stand among the effects
            // (clouds and P3's smoke come first).
            let slots = r.graph.passes.compactMap { $0 as? HalfResTransparentPass }.first
            let emitters = slots?.effects.compactMap { $0 as? EffectTestEmitters }.first
            emitters?.reversesSprites = true
            reversed = emitters != nil
        }
        XCTAssertTrue(reversed, "the backward frame drew the sprites last to first")
        let differ = zip(forward.pixels, backward.pixels).map { abs(Int($0) - Int($1)) }
        XCTAssertLessThanOrEqual(differ.max() ?? 0, 1)
        XCTAssertGreaterThan(Set(forward.pixels).count, 50, "the sprites are drawn")
    }

    // MARK: Upsample at an edge

    /// The column standing in front of the slab, at half resolution, matches
    /// the full-resolution frame around the column: no slab on the column,
    /// no dark halo beside it. A plain bilinear upsample (a tolerance
    /// past any depth ratio) misses many more pixels.
    func testUpsampleAtTheColumnsEdge() throws {
        let emitters = [EffectTestEmitter(.column, position: [0, 60, -40], size: 100), Self.slab]
        let full = try render(Self.shot(emitters, resolution: .full, width: 320, height: 200))
        let depth = try XCTUnwrap(full.capture.values(.sceneDepth))
        func misses(_ tolerance: Double) throws -> Int {
            let half = try render(Self.shot(emitters, tolerance: tolerance, width: 320, height: 200))
            var n = 0
            for y in 0..<200 {
                for x in 0..<320 {
                    // Near the column: within 3 px of a pixel on it.
                    let near = (-3...3).contains { dy in
                        (-3...3).contains { dx in
                            let qx = min(max(x + dx, 0), 319), qy = min(max(y + dy, 0), 199)
                            return depth.texels[qy * 320 + qx][0] > 0
                        }
                    }
                    guard near else { continue }
                    let i = 4 * (y * 320 + x)
                    if (0..<3).contains(where: { abs(Int(half.pixels[i + $0]) - Int(full.pixels[i + $0])) > 6 }) { n += 1 }
                }
            }
            return n
        }
        // The sky against the column is about 90 apart in log2 depth.
        let r6 = try misses(0.1), plain = try misses(1e30)
        print("Pixels near the column off the full-resolution frame: R6 \(r6), bilinear \(plain)")
        XCTAssertGreaterThan(plain, 100)
        XCTAssertLessThanOrEqual(r6 * 5, plain)
    }

    // MARK: The cone's proxy

    /// With the camera inside the cone, its back faces still draw it, and
    /// the march starts at the camera: the centre texel's coverage is the
    /// optical depth from the camera to where the ray leaves, integrated
    /// here (24 jittered steps on the GPU). Front faces alone would draw
    /// nothing; a march from behind the camera would add the cone there.
    func testCameraInsideTheCone() throws {
        let emitter = EffectTestEmitter(.cone, position: [0, 0, 2_000], size: 4_000)
        let f = try render(Self.shot([emitter]))
        let cone = EffectTestScene.cone(emitter, in: EffectTargetFrame(scene: f.scene))
        let k = cone.radius / cone.length
        func inside(_ p: Vec3) -> Bool {
            let v = p - cone.apex, x = v.dot(cone.axis)
            return x >= 0 && x <= cone.length && (v - cone.axis * x).length <= x * k
        }
        // The camera is at the origin, well inside the cone (and its proxy, which is larger).
        let v = -cone.apex, x = v.dot(cone.axis)
        XCTAssertTrue(inside(.zero))
        XCTAssertLessThan((v - cone.axis * x).length, 0.5 * x * k, "the camera well inside")

        // The centre texel's ray (the shader's density, extinction 0.5 / radius).
        let volumes = try XCTUnwrap(f.capture.values(.halfResTransparent))
        let tx = volumes.width / 2, ty = volumes.height / 2
        let cam = f.scene.camera, t = tan(cam.fovY / 2)
        let px = (Double(tx) + 0.5) * 2, py = (Double(ty) + 0.5) * 2
        let dir = cam.worldToView.transposed * Vec3((2 * px / 160 - 1) * t * cam.aspect, (1 - 2 * py / 100) * t, -1)
        func extinction(_ p: Vec3) -> Double {
            guard inside(p) else { return 0 }
            let v = p - cone.apex, x = v.dot(cone.axis), xi = x / cone.length
            let r = (v - cone.axis * x).length, rx = max(x * k, 1e-3)
            let density = exp(-3 * (r / rx) * (r / rx)) * pow(1 - xi, 1.5) * (1 - exp(-xi * 40))
            return density * 0.5 / cone.radius
        }
        func opacity(from s0: Double) -> Double {
            let ds = 0.5
            var tau = 0.0, s = s0
            while s < 20_000 {
                tau += extinction(dir * (s + ds / 2)) * ds * dir.length
                s += ds
            }
            return 1 - exp(-tau)
        }
        // Where the ray, run backwards, leaves the cone behind the camera.
        var back = 0.0
        while inside(dir * (back - 1)) { back -= 1 }
        XCTAssertLessThan(back, -100, "the cone runs on behind the camera")
        let fromCamera = opacity(from: 0), fromBehind = opacity(from: back)
        let gpu = volumes.texels[ty * volumes.width + tx][3]
        print(String(format: "Inside the cone: coverage %.4f on the GPU, %.4f from the camera, %.4f from behind it",
                     gpu, fromCamera, fromBehind))
        XCTAssertGreaterThan(fromCamera, 0.05)
        XCTAssertEqual(gpu, fromCamera, accuracy: 0.1 * fromCamera)
        XCTAssertGreaterThan(abs(fromBehind - fromCamera), 0.2 * fromCamera, "the two marches differ enough to tell")
        XCTAssertLessThan(5 * abs(gpu - fromCamera), abs(gpu - fromBehind))
    }

    // MARK: Cost

    /// Without effects the slots are not encoded and the frame is the one
    /// the renderer drew without R6's passes.
    func testNoEffectsNoSlots() throws {
        var shot = SnapshotToolTests.pad
        shot.width = 160
        shot.height = 100
        // No effect at all: C2's clouds and P4's pad smoke off too.
        shot.settings.cloud.enabled = false
        shot.settings.particle.quality = .off
        let with = try render(shot)
        XCTAssertNil(with.capture.images[.halfResDepth], "the slots did not run")
        let s = try snapper()
        let prepared = try shot.prepare(system: s.system)
        let r6: [Any.Type] = [HalfResTransparentPass.self, TransparentCompositePass.self, EffectDebugViewPass.self,
                              EffectTestOpaquePass.self, EffectTestSparksPass.self]
        let passes = SceneRenderer.defaultPasses(loadsUserTextures: false).filter { p in
            !r6.contains { $0 == type(of: p) }
        } + [Capture()]
        let r = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb, passes: passes,
                                  plan: DirectTargetPlan(colorFormat: .bgra8Unorm_srgb, sampleCount: 4))
        r.setStars(s.stars)
        r.settings = shot.settings
        let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: 160, height: 100))
        r.renderAndWait(shot.scene(prepared), into: target)
        XCTAssertEqual(target.bytes(), with.pixels)
    }

    /// Effects hold their radiance below 6e4, short of half's 65504, in the
    /// helper every output goes through, OIT fragments included.
    func testEffectRadianceIsHeldBelowHalfsLimit() throws {
        let device = try XCTUnwrap(RenderDevice.shared)
        let module = ShaderModule(name: "EffectClamp", headers: [.effectSlots], source: """
            kernel void effect_clamp(device float4 *out [[buffer(0)]], constant EffectSlotUniforms &e [[buffer(1)]]) {
                out[0] = float4(orbit_effectRadiance(float3(1e9, 5e4, 0.25)), 0.0);
                out[1] = orbit_oitOutput(float4(1e9, 1e9, 1e9, 1.0), 10.0, 1.0, e).accumulation;
            }
            """)
        let library = try ShaderLibrary(device: device).library(module)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "effect_clamp")))
        let out = try XCTUnwrap(device.makeBuffer(length: 32, options: .storageModeShared))
        var u = EffectSlotUniforms(size: RenderSize(width: 4, height: 4), scale: 2, layers: .oit,
                                   settings: TransparencySettings(), reference: 10)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer()), enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(out, offset: 0, index: 0)
        enc.setBytes(&u, length: MemoryLayout<EffectSlotUniforms>.stride, index: 1)
        enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let v = out.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2)
        XCTAssertEqual(v[0], SIMD4(6e4, 5e4, 0.25, 0))
        for k in 0..<3 { XCTAssertLessThanOrEqual(v[1][k], Float(EffectSlots.oitMaxAccumulation)) }
        XCTAssertTrue(v[1].x.isFinite)
    }

    /// The downsample's depth attachment, which sprites test against, is
    /// the farthest depth of each texel's upsample footprint
    /// (`EffectSlots.footprintFarthest` over `footprintPixels`), gathered
    /// four pixels at a time, on an odd-sized frame whose edges clamp.
    func testDepthDownsampleWritesTheFootprintsFarthest() throws {
        let device = try XCTUnwrap(RenderDevice.shared)
        let (w, h) = (37, 23)
        let shaders = ShaderLibrary(device: device)
        // A scene depth of distinct values: a fullscreen pass writing them.
        let fill = ShaderModule(name: "DepthFill", headers: [], source: """
            struct FillOut { float4 position [[position]]; };
            vertex FillOut fill_vertex(uint vid [[vertex_id]]) {
                float2 p = float2(float((vid << 1) & 2), float(vid & 2));
                FillOut o;
                o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
                return o;
            }
            struct FillDepth { float depth [[depth(any)]]; };
            fragment FillDepth fill_fragment(FillOut in [[stage_in]]) {
                uint2 p = uint2(in.position.xy);
                FillDepth o;
                o.depth = 0.05 + 0.9 * float((p.x * 7919u + p.y * 104729u) % 997u) / 997.0;
                return o;
            }
            """)
        func depthTexture(_ width: Int, _ height: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height,
                                                             mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        func color(_ format: MTLPixelFormat, _ width: Int, _ height: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        let (tw, th) = EffectSlots.targetSize(width: w, height: h, scale: 2)
        let scene = try XCTUnwrap(depthTexture(w, h)), test = try XCTUnwrap(depthTexture(tw, th))
        let depths = try XCTUnwrap(color(HalfResFormats.sceneDepth, tw, th))
        let pixels = try XCTUnwrap(color(HalfResFormats.pixelDepths, tw, th))
        let fillLibrary = try shaders.library(fill), library = try shaders.library(.halfResTransparent)
        let fd = MTLRenderPipelineDescriptor()
        fd.vertexFunction = fillLibrary.makeFunction(name: "fill_vertex")
        fd.fragmentFunction = fillLibrary.makeFunction(name: "fill_fragment")
        fd.depthAttachmentPixelFormat = .depth32Float
        let fillPipeline = try device.makeRenderPipelineState(descriptor: fd)
        let dd = MTLRenderPipelineDescriptor()
        dd.vertexFunction = library.makeFunction(name: "effect_fullscreen_vertex")
        dd.fragmentFunction = library.makeFunction(name: "effect_depth_fragment")
        dd.colorAttachments[0].pixelFormat = HalfResFormats.sceneDepth
        dd.colorAttachments[1].pixelFormat = HalfResFormats.pixelDepths
        dd.depthAttachmentPixelFormat = HalfResFormats.depth
        let downsample = try device.makeRenderPipelineState(descriptor: dd)
        let always = MTLDepthStencilDescriptor()
        always.depthCompareFunction = .always
        always.isDepthWriteEnabled = true
        let write = try XCTUnwrap(device.makeDepthStencilState(descriptor: always))
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        let sampler = try XCTUnwrap(device.makeSamplerState(descriptor: sd))
        var u = EffectSlotUniforms(size: RenderSize(width: tw, height: th), scale: 2, layers: [.oit],
                                   settings: TransparencySettings(), reference: 100)

        let queue = try XCTUnwrap(device.makeCommandQueue()), cb = try XCTUnwrap(queue.makeCommandBuffer())
        let p1 = MTLRenderPassDescriptor()
        p1.depthAttachment.texture = scene
        p1.depthAttachment.loadAction = .clear
        p1.depthAttachment.storeAction = .store
        let e1 = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: p1))
        e1.setRenderPipelineState(fillPipeline)
        e1.setDepthStencilState(write)
        e1.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e1.endEncoding()
        let p2 = MTLRenderPassDescriptor()
        p2.colorAttachments[0].texture = depths
        p2.colorAttachments[0].storeAction = .store
        p2.colorAttachments[1].texture = pixels
        p2.colorAttachments[1].storeAction = .store
        p2.depthAttachment.texture = test
        p2.depthAttachment.loadAction = .dontCare
        p2.depthAttachment.storeAction = .store
        let e2 = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: p2))
        e2.setRenderPipelineState(downsample)
        e2.setDepthStencilState(write)
        e2.setFragmentBytes(&u, length: MemoryLayout<EffectSlotUniforms>.stride, index: HalfResTransparentPass.uniformsIndex)
        e2.setFragmentSamplerState(sampler, index: Binding.linearClampSampler)
        e2.setFragmentTexture(scene, index: 0)
        e2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e2.endEncoding()
        let sceneOut = try XCTUnwrap(device.makeBuffer(length: w * h * 4, options: .storageModeShared))
        let testOut = try XCTUnwrap(device.makeBuffer(length: tw * th * 4, options: .storageModeShared))
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: scene, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: sceneOut, destinationOffset: 0,
                  destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        blit.copy(from: test, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: tw, height: th, depth: 1), to: testOut, destinationOffset: 0,
                  destinationBytesPerRow: tw * 4, destinationBytesPerImage: tw * th * 4)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error)
        let z = sceneOut.contents().bindMemory(to: Float.self, capacity: w * h)
        let got = testOut.contents().bindMemory(to: Float.self, capacity: tw * th)
        XCTAssertGreaterThan(Set((0..<(w * h)).map { z[$0] }).count, 400, "distinct depths")
        for ty in 0..<th {
            for tx in 0..<tw {
                let footprint = EffectSlots.footprintPixels(x: tx, y: ty, scale: 2, width: w, height: h)
                let want = EffectSlots.footprintFarthest(footprint.map { Double(z[$0.y * w + $0.x]) })
                XCTAssertEqual(Double(got[ty * tw + tx]), want, "texel \(tx), \(ty)")
            }
        }
    }

    /// A layer is reconstructed across depths only when every effect that
    /// draws it reports where its effects ended.
    func testReconstructedLayers() {
        XCTAssertEqual(HalfResTransparentPass.reconstructed([([.clouds, .volumes], [.clouds, .volumes]), ([.volumes], [])]),
                       [.clouds])
        XCTAssertEqual(HalfResTransparentPass.reconstructed([([.oit], [.oit, .clouds])]), [.oit])
        XCTAssertEqual(HalfResTransparentPass.reconstructed([]), [])
    }

    /// The slots' and the test emitters' Swift mirrors have MSL's sizes.
    func testStructLayoutsMatchMSL() throws {
        let device = try XCTUnwrap(RenderDevice.shared)
        let module = ShaderModule(name: "EffectSizes", headers: [.effectSlots], source: effectTestShaderSource + """
            kernel void effect_sizes(device uint *out [[buffer(0)]]) {
                out[0] = sizeof(EffectSlotUniforms);
                out[1] = sizeof(EffectTestUniforms);
                out[2] = sizeof(EffectTestSprite);
                out[3] = sizeof(EffectTestSpark);
                out[4] = sizeof(EffectTestColumnVertex);
            }
            """)
        let library = try ShaderLibrary(device: device).library(module)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "effect_sizes")))
        let out = try XCTUnwrap(device.makeBuffer(length: 5 * 4, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer()), enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(out, offset: 0, index: 0)
        enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let v = out.contents().bindMemory(to: UInt32.self, capacity: 5)
        XCTAssertEqual(Int(v[0]), MemoryLayout<EffectSlotUniforms>.stride)
        XCTAssertEqual(Int(v[1]), MemoryLayout<EffectTestUniforms>.stride)
        XCTAssertEqual(Int(v[2]), MemoryLayout<EffectTestEmitters.Sprite>.stride)
        XCTAssertEqual(Int(v[3]), MemoryLayout<EffectTestSparksPass.Spark>.stride)
        XCTAssertEqual(Int(v[4]), 2 * MemoryLayout<SIMD4<Float>>.stride)
    }
}
