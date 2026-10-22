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
        let r = try SceneRenderer(device: try device(), outputFormat: .bgra8Unorm_srgb, passes: passes,
                                  plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
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
