import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// A pass that records what the graph does with it.
@MainActor
final class RecordingPass: RenderPass {
    final class Log {
        var entries: [String] = []
        var encoders: [String: ObjectIdentifier] = [:]
    }

    struct SetUpFailure: Error {}

    let name: String
    let stage: PassStage
    let order: Int
    var reads: Set<ResourceID> = []
    var writes: Set<ResourceID> = []
    var isEnabled = true
    var encodesOnCommandBuffer = false
    var failsSetUp = false
    var setUps = 0
    let log: Log
    /// Run during encode, with the frame (the history test's checks).
    var onEncode: ((FrameContext) -> Void)?

    init(_ name: String, _ stage: PassStage, _ order: Int = 0, log: Log) {
        self.name = name
        self.stage = stage
        self.order = order
        self.log = log
    }

    func setUp(_ s: PassSetup) throws {
        setUps += 1
        if failsSetUp { throw SetUpFailure() }
    }

    func encode(_ f: FrameContext, _ e: PassEncoding) {
        switch e {
        case .commandBuffer:
            log.entries.append("\(name):cb")
        case .render(let enc):
            log.entries.append("\(name):render")
            log.encoders[name] = ObjectIdentifier(enc)
        }
        onEncode?(f)
    }
}

@MainActor
final class FrameGraphTests: XCTestCase {
    func device() throws -> MTLDevice { try XCTUnwrap(RenderDevice.shared, "no Metal device") }

    /// A scene with nothing in it, for exercising the graph.
    nonisolated static func emptyScene(width: Int = 64, height: Int = 32, frame: Int = 1, reset: Bool = true) -> RenderScene {
        RenderScene(clock: RenderScene.Clock(simTime: Epoch(tdbSecondsPastJ2000: 0), frameIndex: frame, temporalReset: reset),
                    camera: RenderScene.Camera(position: .zero, worldToView: .identity, fovY: 1,
                                               viewport: RenderScene.Viewport(width: Double(width), height: Double(height)),
                                               target: .body(399)),
                    sun: RenderScene.Sun(position: Vec3(1.5e11, 0, 0), direction: .unitX, distance: 1.5e11,
                                         illuminance: 1.3e5, angularRadius: 0.0046))
    }

    func renderer(_ passes: [RenderPass]) throws -> SceneRenderer {
        let device = try device()
        return try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb, passes: passes,
                                 plan: DirectTargetPlan(colorFormat: .bgra8Unorm_srgb, sampleCount: 4))
    }

    func render(_ r: SceneRenderer, _ scene: RenderScene = emptyScene()) throws {
        let target = try XCTUnwrap(OffscreenTarget(device: r.device, width: 64, height: 32))
        let cb = try XCTUnwrap(r.renderAndWait(scene, into: target))
        XCTAssertEqual(cb.status, .completed)
        XCTAssertNil(cb.error)
    }

    /// Slots in order P0-P5, and each pass's order within its slot; the
    /// render stages share the scene encoder while there is no post pass.
    func testPassesRunInSlotOrder() throws {
        let log = RecordingPass.Log()
        let passes = [RecordingPass("marker", .overlay, log: log), RecordingPass("plume", .transparent, 5, log: log),
                      RecordingPass("vessel", .opaque, 2, log: log), RecordingPass("probe", .prepare, log: log),
                      RecordingPass("star", .opaque, 1, log: log), RecordingPass("sky", .composite, log: log)]
        let r = try renderer(passes)
        XCTAssertEqual(r.graph.passes.map(\.name), ["probe", "star", "vessel", "sky", "plume", "marker"])
        try render(r)
        XCTAssertEqual(log.entries, ["probe:cb", "star:render", "vessel:render", "sky:render", "plume:render",
                                     "marker:render"])
        XCTAssertEqual(Set(log.encoders.values).count, 1, "one scene encoder")
    }

    /// A pass whose set-up throws (its module does not compile) is disabled
    /// alone; the frame renders without it.
    func testFailedPassIsDisabledAlone() throws {
        let log = RecordingPass.Log()
        let broken = RecordingPass("broken", .opaque, 1, log: log)
        broken.failsSetUp = true
        let r = try renderer([RecordingPass("first", .opaque, 0, log: log), broken,
                              RecordingPass("last", .transparent, log: log)])
        XCTAssertEqual(r.graph.active.map(\.name), ["first", "last"])
        XCTAssertNotNil(r.failures["broken"])
        try render(r)
        XCTAssertEqual(log.entries, ["first:render", "last:render"])
    }

    /// A broken shader module in a real pass disables that pass only.
    func testBrokenShaderModuleDisablesItsPass() throws {
        final class BrokenShaderPass: RenderPass {
            let name = "Broken shader"
            let stage = PassStage.transparent
            let order = 99
            func setUp(_ s: PassSetup) throws {
                _ = try s.shaders.library(ShaderModule(name: "BrokenModule", source: "this is not MSL"))
            }
            func encode(_ f: FrameContext, _ e: PassEncoding) { XCTFail("a disabled pass is never encoded") }
        }
        var passes = SceneRenderer.defaultPasses(loadsUserTextures: false)
        passes.append(BrokenShaderPass())
        let r = try renderer(passes)
        XCTAssertEqual(r.graph.failures.keys.sorted(), ["Broken shader"])
        XCTAssertNotNil(r.shaders.errors["BrokenModule"])
        try render(r)
    }

    /// Reads must be written by an earlier pass, be persistent, or be the
    /// target plan's own; a disabled slot is never set up or encoded.
    func testReadsAreValidated() throws {
        let log = RecordingPass.Log()
        let orphan = RecordingPass("orphan", .transparent, log: log)
        orphan.reads = ["nobodyWritesThis"]
        let writer = RecordingPass("writer", .prepare, log: log)
        writer.writes = [.cloudLayer]
        let reader = RecordingPass("reader", .composite, log: log)
        reader.reads = [.cloudLayer, .sceneDepth, .exposure]
        let early = RecordingPass("early", .prepare, -1, log: log)
        early.reads = [.cloudLayer]
        let stub = RecordingPass("stub", .opaque, log: log)
        stub.isEnabled = false
        let r = try renderer([orphan, writer, reader, early, stub])
        XCTAssertEqual(r.graph.active.map(\.name), ["writer", "reader"])
        XCTAssertTrue(r.failures["orphan"]?.contains("nobodyWritesThis") ?? false)
        XCTAssertNotNil(r.failures["early"], "it runs before the writer")
        XCTAssertEqual(stub.setUps, 0)
        try render(r)
        XCTAssertEqual(log.entries, ["writer:cb", "reader:render"])
    }

    /// History targets: last frame's texture comes back as `previous`, valid
    /// from the second frame until a temporal reset.
    func testHistoryTargetsSwapEachFrame() throws {
        let log = RecordingPass.Log()
        let pass = RecordingPass("temporal", .prepare, log: log)
        var seen: [(current: ObjectIdentifier, previous: ObjectIdentifier, valid: Bool)] = []
        pass.onEncode = { f in
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 8, height: 8, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let p = f.history.pair("cloudHistory", descriptor: d) else { return XCTFail("no history") }
            seen.append((ObjectIdentifier(p.current), ObjectIdentifier(p.previous), p.valid))
        }
        let r = try renderer([pass])
        try render(r, Self.emptyScene(frame: 1, reset: true))
        try render(r, Self.emptyScene(frame: 2, reset: false))
        try render(r, Self.emptyScene(frame: 3, reset: true))
        XCTAssertEqual(seen.map(\.valid), [false, true, false])
        XCTAssertEqual(seen[1].current, seen[0].previous)
        XCTAssertEqual(seen[1].previous, seen[0].current)
    }

    /// The transient pool hands a texture to one pass per frame and reuses
    /// it the next frame.
    func testTexturePoolReusesByDescriptor() throws {
        let log = RecordingPass.Log()
        var ids: [[ObjectIdentifier]] = []
        let pass = RecordingPass("transient", .prepare, log: log)
        pass.onEncode = { f in
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 16, height: 16, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            ids.append([f.pool.texture(d), f.pool.texture(d)].compactMap { $0.map(ObjectIdentifier.init) })
        }
        let r = try renderer([pass])
        try render(r)
        try render(r)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids[0]).count, 2, "two holders, two textures")
        XCTAssertEqual(Set(ids[0]), Set(ids[1]), "reused the next frame")
    }

    /// The shared uniforms are bound in every render stage at the reserved
    /// slots, and the frame's camera reaches FrameUniforms.
    func testFrameUniformsFollowTheScene() throws {
        let log = RecordingPass.Log()
        var frame: FrameUniforms?
        let pass = RecordingPass("probe", .prepare, log: log)
        pass.onEncode = { f in frame = f.frame }
        let r = try renderer([pass])
        try render(r, Self.emptyScene(width: 64, height: 32, frame: 7, reset: false))
        let u = try XCTUnwrap(frame)
        XCTAssertEqual(u.viewport, SIMD4(64, 32, 1 / 64, 1 / 32))
        XCTAssertEqual(u.camera.x, 0.25)
        XCTAssertEqual(u.camera.y, Float(tan(0.5)), accuracy: 1e-7)
        XCTAssertEqual(u.camera.z, 2)
        XCTAssertEqual(u.frame.x, 7)
        XCTAssertEqual(u.sunDirection, SIMD4(1, 0, 0, 0.0046))
        XCTAssertEqual(u.exposure.x, 1, "pre-exposure 1 until R1")
    }
}

extension FrameGraphTests {
    /// On the direct plan nothing writes `hdrColor`, so a post pass reading
    /// it (R1's) is disabled; one that reads the scene's own resolves runs,
    /// and the overlay after it is left out (its pipelines are the scene's).
    func testPostPassesOnTheDirectPlan() throws {
        let log = RecordingPass.Log()
        let tonemap = RecordingPass("tonemap", .post, log: log)
        tonemap.reads = [.hdrColor]
        let r = try renderer([tonemap, RecordingPass("marker", .overlay, log: log)])
        XCTAssertNotNil(r.failures["tonemap"])
        try render(r)
        XCTAssertEqual(log.entries, ["marker:render"])

        let log2 = RecordingPass.Log()
        let debug = RecordingPass("debug", .post, log: log2)
        debug.reads = [.sceneDepth]
        var resolved = false
        debug.onEncode = { f in resolved = f.textures[.sceneDepth] != nil }
        let r2 = try renderer([RecordingPass("vessel", .opaque, log: log2), debug, RecordingPass("marker", .overlay, log: log2)])
        XCTAssertEqual(r2.failures, [:])
        try render(r2)
        XCTAssertEqual(log2.entries, ["vessel:render", "debug:cb"])
        XCTAssertTrue(resolved, "the depth resolved for it")
    }
}

extension FrameGraphTests {
    /// A render-stage pass on the command buffer ends the scene's encoder;
    /// the passes after it draw in the resumed scene, the overlay too.
    func testPassOnTheCommandBufferBreaksTheScene() throws {
        let log = RecordingPass.Log()
        let halfRes = RecordingPass("halfRes", .transparent, 1, log: log)
        halfRes.encodesOnCommandBuffer = true
        var broken = false
        halfRes.onEncode = { f in broken = f.breaksScene }
        let r = try renderer([RecordingPass("vessel", .opaque, log: log), RecordingPass("plume", .transparent, 0, log: log),
                              halfRes, RecordingPass("composite", .transparent, 2, log: log),
                              RecordingPass("marker", .overlay, log: log)])
        try render(r)
        XCTAssertEqual(log.entries, ["vessel:render", "plume:render", "halfRes:cb", "composite:render", "marker:render"])
        XCTAssertTrue(broken, "the plan was told")
        XCTAssertEqual(log.encoders["plume"], log.encoders["vessel"])
        XCTAssertNotEqual(log.encoders["composite"], log.encoders["vessel"], "the scene resumed in a new encoder")
        XCTAssertEqual(log.encoders["marker"], log.encoders["composite"])
    }

    /// Breaking the scene keeps the image: the direct plan stores the MSAA
    /// samples and resolves again where the scene resumes. Also while
    /// timing, with the break in P1 (opaque passes draw after it), and with
    /// nothing drawing after the break (the frame's end resolves). The
    /// resolved depth a later pass reads is the same too.
    func testBreakingTheSceneKeepsThePixels() throws {
        final class Gap: RenderPass {
            let name = "Gap"
            let stage: PassStage
            let order: Int
            var encodesOnCommandBuffer: Bool { true }
            var encoded = 0
            init(_ stage: PassStage, _ order: Int) {
                self.stage = stage
                self.order = order
            }
            func encode(_ f: FrameContext, _ e: PassEncoding) {
                guard case .commandBuffer = e else { return XCTFail("a pass on the command buffer") }
                encoded += 1
            }
        }
        /// Copies the resolved scene depth (P4).
        final class DepthReader: RenderPass {
            let name = "Depth reader"
            let stage = PassStage.post
            let order = 0
            var reads: Set<ResourceID> { [.sceneDepth] }
            var buffer: MTLBuffer?
            func encode(_ f: FrameContext, _ e: PassEncoding) {
                guard let t = f.textures[.sceneDepth], let blit = f.makeBlitEncoder(),
                      let b = f.device.makeBuffer(length: 4 * t.width * t.height, options: .storageModeShared) else { return }
                blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                          sourceSize: MTLSize(width: t.width, height: t.height, depth: 1), to: b, destinationOffset: 0,
                          destinationBytesPerRow: 4 * t.width, destinationBytesPerImage: 4 * t.width * t.height)
                blit.endEncoding()
                buffer = b
            }
            var bytes: [UInt8] { buffer.map { Array(UnsafeRawBufferPointer(start: $0.contents(), count: $0.length)) } ?? [] }
        }
        let scenario = try XCTUnwrap(Scenario.named("as506-pad"))
        let sim = scenario.build(SceneRendererTests.system)
        var camera = OrbitCamera()
        let v = try XCTUnwrap(sim.focus)
        camera.target = .vessel(v.id)
        camera.distance = max(v.boundingRadius * 3, 30)
        camera.update(sim: sim)
        let scene = SceneExtractor().extract(sim: sim, camera: camera,
                                             viewport: RenderScene.Viewport(width: 320, height: 200), realTime: 0)
        let stars = try StarCatalog.bundled()
        func image(_ extra: [RenderPass], timing: Bool = false) throws -> [UInt8] {
            let device = try device()
            let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb,
                                      passes: SceneRenderer.defaultPasses(loadsUserTextures: false) + extra,
                                      plan: DirectTargetPlan(colorFormat: .bgra8Unorm_srgb, sampleCount: 4))
            r.setStars(stars)
            r.profiling = timing
            r.profileInterval = 1
            let target = try XCTUnwrap(OffscreenTarget(device: device, width: 320, height: 200))
            r.renderAndWait(scene, into: target)
            return target.bytes()
        }
        let plain = try image([])
        for (stage, order) in [(PassStage.transparent, 15), (.opaque, 15), (.overlay, 100)] {
            let gap = Gap(stage, order)
            XCTAssertEqual(try image([gap]), plain, "a break in \(stage)")
            XCTAssertEqual(try image([gap], timing: true), plain, "a break in \(stage), timed")
            XCTAssertEqual(gap.encoded, 2)
        }
        let plainDepth = DepthReader()
        _ = try image([plainDepth])
        XCTAssertFalse(plainDepth.bytes.isEmpty)
        for (stage, order) in [(PassStage.transparent, 15), (.opaque, 15)] {
            let depth = DepthReader()
            _ = try image([Gap(stage, order), depth])
            XCTAssertEqual(depth.bytes, plainDepth.bytes, "the resolved depth with a break in \(stage)")
        }
    }

    /// The plan is told which resume is the scene's last: after the frame's
    /// last break, from P2 on, without timing. That one resolves the colour
    /// and stores no samples; the others keep them.
    func testTheLastResumeOnlyResolves() throws {
        final class Watching: SceneTargetPlan {
            let inner = DirectTargetPlan(colorFormat: .bgra8Unorm_srgb, sampleCount: 4)
            var resumes: [String] = []
            func formats(for stage: PassStage) -> SceneFormats { inner.formats(for: stage) }
            var provides: Set<ResourceID> { inner.provides }
            func resize(_ size: RenderSize, device: MTLDevice) { inner.resize(size, device: device) }
            func renderPass(for stage: PassStage, _ f: FrameContext) -> MTLRenderPassDescriptor? {
                inner.renderPass(for: stage, f)
            }
            func continuation(_ f: FrameContext) -> MTLRenderPassDescriptor? {
                let d = inner.continuation(f)
                if let d {
                    let c = d.colorAttachments[0].storeAction, z = d.depthAttachment.storeAction
                    resumes.append("\(f.resumesLast ? "last" : "more") \(c == .multisampleResolve ? "resolve" : "store+resolve") "
                                   + "\(z == .dontCare ? "no depth" : "depth")")
                }
                return d
            }
        }
        func resumes(_ passes: [RenderPass], timing: Bool = false) throws -> [String] {
            let plan = Watching()
            let r = try SceneRenderer(device: try device(), outputFormat: .bgra8Unorm_srgb, passes: passes, plan: plan)
            r.profiling = timing
            r.profileInterval = 1
            try render(r)
            return plan.resumes
        }
        func breaker(_ name: String, _ stage: PassStage, _ order: Int, _ log: RecordingPass.Log) -> RecordingPass {
            let p = RecordingPass(name, stage, order, log: log)
            p.encodesOnCommandBuffer = true
            return p
        }
        let log = RecordingPass.Log()
        // Two breaks in P3: the first resume keeps the samples for the second.
        XCTAssertEqual(try resumes([RecordingPass("vessel", .opaque, log: log), breaker("a", .transparent, 0, log),
                                    RecordingPass("plume", .transparent, 1, log: log), breaker("b", .transparent, 2, log),
                                    RecordingPass("composite", .transparent, 3, log: log),
                                    RecordingPass("marker", .overlay, log: log)]),
                       ["more store+resolve depth", "last resolve no depth"])
        // A break in P1: opaque passes after it still write depth.
        XCTAssertEqual(try resumes([RecordingPass("planet", .opaque, 0, log: log), breaker("a", .opaque, 1, log),
                                    RecordingPass("vessel", .opaque, 2, log: log)]),
                       ["more store+resolve depth"])
        // Nothing draws after the break: the frame's end resolves.
        XCTAssertEqual(try resumes([RecordingPass("vessel", .opaque, log: log), breaker("a", .transparent, 0, log)]),
                       ["last resolve no depth"])
        // Timing keeps every sample.
        XCTAssertFalse(try resumes([RecordingPass("vessel", .opaque, log: log), breaker("a", .transparent, 0, log),
                                    RecordingPass("composite", .transparent, 1, log: log)], timing: true)
            .contains { $0.hasPrefix("last") })
    }

    /// A plan that opens a render pass of its own for P3: a pass on the
    /// command buffer at the start of P3 costs no continuation, and the
    /// stage's render pass opens for the first pass that draws in it.
    func testStageOpensItsOwnPassAfterABreak() throws {
        final class StagedPlan: SceneTargetPlan {
            var continuations = 0
            var depth: MTLTexture?
            func formats(for stage: PassStage) -> SceneFormats {
                SceneFormats(color: .bgra8Unorm_srgb, depth: .depth32Float, sampleCount: 1, output: .bgra8Unorm_srgb)
            }
            var provides: Set<ResourceID> { [.sceneColor, .sceneDepth, .output] }
            func resize(_ size: RenderSize, device: MTLDevice) {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: size.width,
                                                                 height: size.height, mipmapped: false)
                d.usage = .renderTarget
                d.storageMode = .private
                depth = device.makeTexture(descriptor: d)
            }
            func renderPass(for stage: PassStage, _ f: FrameContext) -> MTLRenderPassDescriptor? {
                guard stage == .opaque || stage == .transparent else { return nil }
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = f.output
                pass.colorAttachments[0].loadAction = stage == .opaque ? .clear : .load
                pass.colorAttachments[0].storeAction = .store
                pass.depthAttachment.texture = depth
                pass.depthAttachment.loadAction = stage == .opaque ? .clear : .load
                pass.depthAttachment.clearDepth = 0
                pass.depthAttachment.storeAction = .store
                return pass
            }
            func continuation(_ f: FrameContext) -> MTLRenderPassDescriptor? {
                continuations += 1
                return nil
            }
        }
        let log = RecordingPass.Log()
        let halfRes = RecordingPass("halfRes", .transparent, 0, log: log)
        halfRes.encodesOnCommandBuffer = true
        let plan = StagedPlan()
        let device = try device()
        let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb,
                                  passes: [RecordingPass("vessel", .opaque, log: log), halfRes,
                                           RecordingPass("plume", .transparent, 1, log: log)], plan: plan)
        try render(r)
        XCTAssertEqual(log.entries, ["vessel:render", "halfRes:cb", "plume:render"])
        XCTAssertEqual(plan.continuations, 0)
        XCTAssertNotEqual(log.encoders["plume"], log.encoders["vessel"])
    }
}

extension FrameGraphTests {
    /// While timing, the scene's resume after a break is measured whole,
    /// under the pass that broke the scene: the plain frame loads and
    /// stores the targets there too. The pass after it draws in a
    /// continuation, which loses the split overhead as usual.
    func testTimingChargesTheBreakToItsPass() throws {
        let log = RecordingPass.Log()
        let halfRes = RecordingPass("halfRes", .transparent, 1, log: log)
        halfRes.encodesOnCommandBuffer = true
        let composite = RecordingPass("composite", .transparent, 2, log: log)
        var profile: FrameProfile?
        composite.onEncode = { f in profile = f.profile }
        let r = try renderer([RecordingPass("vessel", .opaque, log: log), RecordingPass("plume", .transparent, 0, log: log),
                              halfRes, composite, RecordingPass("marker", .overlay, log: log)])
        guard r.profiler.isSupported else { throw XCTSkip("no timestamp counters on this GPU") }
        r.profiling = true
        r.profileInterval = 1
        try render(r)
        let p = try XCTUnwrap(profile, "a timed frame")
        XCTAssertEqual(zip(p.labels, p.kinds).map { "\($0) \($1)" },
                       ["vessel render", "plume sceneContinuation", "\(FrameProfile.splitOverhead) sceneContinuation",
                        "halfRes render", "composite sceneContinuation", "marker sceneContinuation"])
        XCTAssertEqual(log.entries, ["vessel:render", "plume:render", "halfRes:cb", "composite:render", "marker:render"])

        // Its timings: the resume's load and store stay with the pass that
        // broke the scene, and the continuations lose the overhead.
        let stamps: [UInt64] = [1, 11, 20, 120,       // vessel: 10 + 100
                                120, 125, 130, 210,   // plume: 5 + 80, less 50
                                210, 211, 220, 269,   // the overhead: 1 + 49
                                300, 301, 310, 359,   // the resume: 1 + 49, kept
                                360, 370, 380, 480,   // composite: 10 + 100, less 50
                                480, 481, 490, 560]   // marker: 1 + 70, less 50
        let t = FrameProfile.timings(labels: p.labels, kinds: p.kinds, stamps: stamps, secondsPerTick: 1)
        XCTAssertEqual(t.map(\.pass), ["vessel", "plume", FrameProfile.splitOverhead, "halfRes", "composite", "marker"])
        XCTAssertEqual(t.map(\.seconds), [110, 35, 50, 50, 60, 21])
    }
}
