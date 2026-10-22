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
        static let ids: [ResourceID] = [.sceneDepth, .halfResDepth, .halfResClouds, .halfResTransparent,
                                        .oitAccumulation, .oitRevealage, .halfResFronts]
        var images: [ResourceID: (width: Int, height: Int, format: MTLPixelFormat, buffer: MTLBuffer)] = [:]

        func encode(_ f: FrameContext, _ e: PassEncoding) {
            images = [:]
            guard let blit = f.makeBlitEncoder() else { return }
            for id in Self.ids {
                guard let t = f.textures[id] else { continue }
                let bpp: Int
                switch t.pixelFormat {
                case .rg32Float, .rgba16Float: bpp = 8
                case .r16Float: bpp = 2
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
            case .rg32Float:
                let p = i.buffer.contents().bindMemory(to: Float.self, capacity: 2 * n)
                return (i.width, i.height, (0..<n).map { [Double(p[2 * $0]), Double(p[2 * $0 + 1])] })
            case .rgba16Float:
                let p = i.buffer.contents().bindMemory(to: UInt16.self, capacity: 4 * n)
                return (i.width, i.height, (0..<n).map { t in (0..<4).map { Double(Float(Float16(bitPattern: p[4 * t + $0]))) } })
            case .r16Float:
                let p = i.buffer.contents().bindMemory(to: UInt16.self, capacity: n)
                return (i.width, i.height, (0..<n).map { [Double(Float(Float16(bitPattern: p[$0])))] })
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

    /// Renders `shot` with the default passes and a capture after them.
    func render(_ shot: SnapshotSpec.Shot, configure: ((SceneRenderer) -> Void)? = nil) throws -> Frame {
        let s = try snapper()
        let prepared = try shot.prepare(system: s.system)
        let scene = shot.scene(prepared)
        let capture = Capture()
        let r = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb,
                                  passes: SceneRenderer.defaultPasses(loadsUserTextures: false) + [capture],
                                  plan: DirectTargetPlan(colorFormat: .bgra8Unorm_srgb, sampleCount: 4))
        r.setStars(s.stars)
        r.settings = shot.settings
        configure?(r)
        XCTAssertEqual(r.failures, [:])
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
    /// the resolved scene depth, at half and full resolution.
    func testDepthDownsampleMatchesTheMaths() throws {
        for resolution in EffectResolution.allCases {
            let f = try render(Self.shot([Self.column, Self.slab], resolution: resolution))
            let scene = try XCTUnwrap(f.capture.values(.sceneDepth)), half = try XCTUnwrap(f.capture.values(.halfResDepth))
            let s = resolution.scale
            XCTAssertTrue(EffectSlots.targetSize(width: 160, height: 100, scale: s) == (half.width, half.height))
            var edges = 0
            for y in 0..<half.height {
                for x in 0..<half.width {
                    var quad: [Double] = []
                    for dy in 0..<s {
                        for dx in 0..<s where s * x + dx < scene.width && s * y + dy < scene.height {
                            quad.append(scene.texels[(s * y + dy) * scene.width + s * x + dx][0])
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

    /// Every pixel's composite is the maths' (upsample weights, the OIT
    /// resolve, the front order) over the frame without effects, at half
    /// and full resolution.
    func testCompositeMatchesTheMaths() throws {
        for resolution in EffectResolution.allCases {
            let opaque = try render(Self.shot([Self.column], resolution: resolution))
            let f = try render(Self.shot([Self.column, Self.slab, Self.cone, Self.sprites], resolution: resolution))
            let c = f.capture
            let scene = try XCTUnwrap(c.values(.sceneDepth)), depth = try XCTUnwrap(c.values(.halfResDepth))
            let clouds = try XCTUnwrap(c.values(.halfResClouds)), volumes = try XCTUnwrap(c.values(.halfResTransparent))
            let accumulation = try XCTUnwrap(c.values(.oitAccumulation)), revealage = try XCTUnwrap(c.values(.oitRevealage))
            let fronts = try XCTUnwrap(c.values(.halfResFronts))
            func p(_ v: [Double]) -> EffectSlots.Premultiplied { .init(v[0], v[1], v[2], v[3]) }
            var off = 0, covered = 0, worst = 0.0
            for y in 0..<100 {
                for x in 0..<160 {
                    let fp = EffectSlots.upsampleFootprint(pixelX: x, pixelY: y, scale: resolution.scale,
                                                           width: depth.width, height: depth.height)
                    let index = fp.texels.map { $0.y * depth.width + $0.x }
                    let weights = EffectSlots.upsampleWeights(bilinear: fp.bilinear, depths: index.map { depth.texels[$0][0] },
                                                              depth: scene.texels[y * 160 + x][0], tolerance: 0.1)
                    let texels = index.map { i in
                        EffectSlots.Texel(clouds: p(clouds.texels[i]), volumes: p(volumes.texels[i]),
                                          accumulation: p(accumulation.texels[i]), revealage: revealage.texels[i][0],
                                          fronts: Array(fronts.texels[i][0..<3]))
                    }
                    let mix = EffectSlots.compositePixel(texels, weights: weights, drawn: [.clouds, .volumes, .oit])
                    if mix.a > 0.01 { covered += 1 }
                    let i = 4 * (y * 160 + x)
                    // BGRA: the composite over the frame without effects.
                    for (k, channel) in [(2, mix.r), (1, mix.g), (0, mix.b)] {
                        let want = Self.srgb(channel + (1 - mix.a) * Self.linear(opaque.pixels[i + k]))
                        let error = abs(want - Double(f.pixels[i + k]))
                        worst = max(worst, error)
                        if error > 2.5 { off += 1 }
                    }
                }
            }
            XCTAssertGreaterThan(covered, 4_000, "\(resolution): the effects cover much of the frame")
            XCTAssertLessThanOrEqual(off, 40, "\(resolution): channels off by more than 2.5/255 (worst \(worst))")
        }
    }

    // MARK: Fronts

    /// The slab reports its front where it becomes visible, as
    /// `EffectSlots.homogeneousFront` puts it for its source radiance (its
    /// colour over its coverage, here read back), to the code's precision.
    func testSlabReportsItsFront() throws {
        let f = try render(Self.shot([Self.slab]))
        let fronts = try XCTUnwrap(f.capture.values(.halfResFronts))
        let clouds = try XCTUnwrap(f.capture.values(.halfResClouds))
        let slab = EffectTestScene.slab(Self.slab, in: EffectTargetFrame(scene: f.scene))
        let cam = f.scene.camera, t = tan(cam.fovY / 2)
        var checked = 0
        for (x, y) in [(40, 30), (25, 40), (60, 45), (10, 48), (70, 35)] {
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
            guard exit > enter, let front = EffectSlots.homogeneousFront(entry: enter, exit: exit,
                                                                         extinction: slab.extinction * dir.length,
                                                                         source: source)
            else {
                XCTAssertEqual(code, EffectSlots.noFront, "\(x), \(y): no front")
                continue
            }
            checked += 1
            XCTAssertEqual(EffectSlots.linearDepth(frontCode: code) / front, 1, accuracy: 0.004, "\(x), \(y)")
        }
        XCTAssertGreaterThanOrEqual(checked, 3)
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

    // MARK: OIT

    /// The sprites drawn last to first give the same frame: weighted-blended
    /// OIT is order-independent (to a half's rounding).
    func testOITIsOrderIndependent() throws {
        let shot = Self.shot([EffectTestEmitter(.sprites, size: 30, count: 24)])
        let forward = try render(shot)
        let backward = try render(shot) { r in
            let slots = r.graph.passes.compactMap { $0 as? HalfResTransparentPass }.first
            (slots?.effects.first as? EffectTestEmitters)?.reversesSprites = true
        }
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
        let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: 160, height: 100))
        r.renderAndWait(shot.scene(prepared), into: target)
        XCTAssertEqual(target.bytes(), with.pixels)
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
