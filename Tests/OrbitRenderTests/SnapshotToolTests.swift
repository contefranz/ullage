import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

@MainActor
final class SnapshotToolTests: XCTestCase {
    static var snapper: SnapshotRenderer?

    func snapper() throws -> SnapshotRenderer {
        if let s = Self.snapper { return s }
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        Self.snapper = s
        return s
    }

    static let pad = SnapshotSpec.Shot(name: "pad", scenario: "as506-pad")

    /// Timing the passes splits the encoders; the image stays the same, and
    /// every pass that ran has a time, together near the frame's.
    func testProfilingKeepsThePixels() throws {
        let s = try snapper()
        var shot = Self.pad
        shot.width = 320
        shot.height = 200
        let plain = try s.render(shot)
        let timed = try s.render(shot, timingFrames: 3)
        XCTAssertEqual(timed.pixels, plain.pixels)
        // A split frame: every pass in its own encoder, the MSAA samples
        // stored and loaded between them, resolved each time.
        XCTAssertEqual(try XCTUnwrap(timed.profiledPixels), plain.pixels, "a profiled frame has the same pixels")
        guard try s.renderer(userTextures: false).profiler.isSupported else {
            throw XCTSkip("no timestamp counters on this GPU")
        }
        XCTAssertEqual(timed.timings.map(\.pass), ["Shadows", "Stars", "Planets", "Vessels", "Orbit line", "Plumes",
                                                   "Far points", "Markers", FrameProfile.splitOverhead])
        // Each render pass's vertex and fragment time less what splitting
        // costs (an empty encoder's time): small passes may read 0.
        for t in timed.timings { XCTAssertGreaterThanOrEqual(t.seconds, 0, t.pass) }
        XCTAssertGreaterThan(timed.timings.last!.seconds, 0, "the split overhead is measured")
        let sum = timed.timings.map(\.seconds).reduce(0, +)
        // The record's GPU time is an unsplit frame's: less than a split
        // frame's passes and overhead together.
        XCTAssertGreaterThan(timed.record.gpuMilliseconds, 0)
        XCTAssertLessThan(sum, 2 * timed.record.gpuMilliseconds / 1_000 + 2 * timed.timings.last!.seconds,
                          "\(timed.timings)")
    }

    /// The split overhead comes off the scene's continuations only: not
    /// off the scene's first encoder, nor a pass's own encoder (the debug
    /// view runs the same way unsplit), nor compute; spans not sampled read 0.
    func testSplitOverheadComesOffContinuationsOnly() {
        typealias K = FrameProfile.EncoderKind
        let labels = ["Stars", "Planets", "Debug view", FrameProfile.splitOverhead, "Probe"]
        let kinds: [K] = [.render, .sceneContinuation, .render, .sceneContinuation, .other]
        let stamps: [UInt64] = [10, 20, 30, 130,      // Stars: 10 + 100
                                100, 110, 200, 400,   // Planets: 10 + 200, less 50
                                500, 505, 600, 700,   // Debug view: 5 + 100
                                800, 801, 900, 949,   // the overhead: 1 + 49
                                1_000, 1_060, 0, 0]   // Probe: 60
        let t = FrameProfile.timings(labels: labels, kinds: kinds, stamps: stamps, secondsPerTick: 1)
        XCTAssertEqual(t.map(\.pass), labels)
        XCTAssertEqual(t.map(\.seconds), [110, 160, 105, 50, 60])
    }

    /// Only unsplit frames give F10's GPU time and `times`: a timed frame
    /// gives its passes and nothing else.
    func testSplitFramesNeverSetTheFrameTime() throws {
        let times = FrameTimes(), reports = ReportBox()
        SceneRenderer.record(gpu: 0.009, passes: [PassTiming(pass: "Vessels", seconds: 0.004)], times: times,
                             reports: reports)
        XCTAssertNil(reports.gpu)
        XCTAssertEqual(times.gpu, 0)
        SceneRenderer.record(gpu: 0.002, passes: nil, times: times, reports: reports)
        XCTAssertEqual(reports.gpu, 0.002)
        XCTAssertEqual(times.gpu, 0.002)
        SceneRenderer.record(gpu: 0.009, passes: [PassTiming(pass: "Planets", seconds: 0.003)], times: times,
                             reports: reports)
        XCTAssertEqual(reports.gpu, 0.002)
        XCTAssertEqual(times.gpu, 0.002)
        XCTAssertEqual(reports.passes.map(\.pass), ["Planets"])

        // And through a renderer: timing every frame leaves no frame time.
        let device = try XCTUnwrap(RenderDevice.shared)
        let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb,
                                  passes: [RecordingPass("vessel", .opaque, log: RecordingPass.Log())],
                                  plan: DirectTargetPlan(colorFormat: .bgra8Unorm_srgb, sampleCount: 4))
        guard r.profiler.isSupported else { throw XCTSkip("no timestamp counters on this GPU") }
        let target = try XCTUnwrap(OffscreenTarget(device: device, width: 64, height: 32))
        r.profiling = true
        r.profileInterval = 1
        for _ in 0..<3 { r.renderAndWait(FrameGraphTests.emptyScene(), into: target) }
        XCTAssertNil(r.lastReport, "no unsplit frame yet")
        XCTAssertEqual(r.times.gpu, 0)
        r.profiling = false
        r.renderAndWait(FrameGraphTests.emptyScene(), into: target)
        XCTAssertGreaterThan(try XCTUnwrap(r.lastReport).gpu, 0)
        XCTAssertEqual(r.lastReport?.passes, [], "no passes once timing is off")
    }

    /// The record's GPU time is the main frame's, not an AOV frame's.
    func testRecordTakesTheMainFramesGPUTime() throws {
        let s = try snapper()
        let saved = s.frameGPUTime
        defer { s.frameGPUTime = saved }
        var frames = 0.0
        s.frameGPUTime = { _ in
            frames += 1
            return frames      // 1 s for the first frame rendered, 2 for the next...
        }
        var shot = Self.pad
        shot.width = 160
        shot.height = 100
        shot.aovs = [.depth, .normals]
        let out = try s.render(shot)
        XCTAssertEqual(frames, 3)
        XCTAssertEqual(out.record.gpuMilliseconds, 1_000)
    }

    /// With a debug view on (a P4 pass ends the scene's encoders), timing
    /// still measures the split overhead and times the view's own encoder.
    func testTimingWithADebugView() throws {
        let s = try snapper()
        guard try s.renderer(userTextures: false).profiler.isSupported else {
            throw XCTSkip("no timestamp counters on this GPU")
        }
        var shot = Self.pad
        shot.width = 320
        shot.height = 200
        shot.settings.debug.view = .normals
        let timed = try s.render(shot, timingFrames: 2)
        let names = timed.timings.map(\.pass)
        XCTAssertTrue(names.contains(FrameProfile.splitOverhead), "\(names)")
        XCTAssertTrue(names.contains("Debug view"), "\(names)")
        XCTAssertFalse(names.contains("Markers"), "the overlay is left out under a debug view")
        XCTAssertEqual(try XCTUnwrap(timed.profiledPixels), timed.pixels)
    }

    /// Timing keeps stored MSAA targets; they go once it has been off a while.
    func testStoredTargetsAreReleased() throws {
        let device = try XCTUnwrap(RenderDevice.shared)
        let plan = DirectTargetPlan(colorFormat: .bgra8Unorm_srgb, sampleCount: 4)
        let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb,
                                  passes: [RecordingPass("vessel", .opaque, log: RecordingPass.Log())], plan: plan)
        guard r.profiler.isSupported else { throw XCTSkip("no timestamp counters on this GPU") }
        let target = try XCTUnwrap(OffscreenTarget(device: device, width: 64, height: 32))
        r.profiling = true
        r.profileInterval = 1
        r.renderAndWait(FrameGraphTests.emptyScene(), into: target)
        XCTAssertNotNil(plan.stored.depth)
        r.profiling = false
        for _ in 0..<31 { r.renderAndWait(FrameGraphTests.emptyScene(), into: target) }
        XCTAssertNil(plan.stored.depth)
        XCTAssertNil(plan.stored.color)
    }

    /// The debug views replace the image (and leave the markers out); the
    /// image afterwards is the plain one again.
    func testDebugViews() throws {
        let s = try snapper()
        var shot = SnapshotSpec.Shot(name: "orbit", scenario: "as506-parking-orbit")
        shot.width = 320
        shot.height = 200
        shot.aovs = [.depth, .normals, .luminance]
        let out = try s.render(shot)
        XCTAssertEqual(out.aovs.map(\.view), [.depth, .normals, .luminance])
        for aov in out.aovs {
            XCTAssertNotEqual(aov.pixels, out.pixels, "\(aov.view)")
        }
        XCTAssertEqual(Set(out.aovs.map(\.pixels)).count, 3)
        XCTAssertEqual(try s.render(shot).pixels, out.pixels)
        // Depth: the black sky at the top left (stars and space at infinity).
        let depth = out.aovs[0].pixels
        XCTAssertEqual(Array(depth[0..<3]), [0, 0, 0])
    }

    /// PNGs round-trip exactly; PFMs hold the linear light.
    func testImageFilesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orbitsim-image-files")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var bgra: [UInt8] = []
        for i in 0..<(16 * 8) { bgra += [UInt8(i), UInt8(255 - i), UInt8((i * 7) % 256), 255] }
        let png = dir.appendingPathComponent("t.png")
        try ImageFiles.writePNG(bgra, width: 16, height: 8, order: .bgra, to: png)
        let back = try ImageFiles.readPNG(png)
        XCTAssertEqual([back.width, back.height], [16, 8])
        XCTAssertEqual(back.pixels, ImageFiles.rgba(fromBGRA: bgra))
        let pfm = dir.appendingPathComponent("t.pfm")
        try ImageFiles.writePFM(bgra, width: 16, height: 8, order: .bgra, to: pfm)
        let data = try Data(contentsOf: pfm)
        let header = "PF\n16 8\n-1.0\n"
        XCTAssertEqual(String(data: data.prefix(header.utf8.count), encoding: .utf8), header)
        XCTAssertEqual(data.count, header.utf8.count + 16 * 8 * 3 * 4)
        // The first float is the bottom-left pixel's red: row 7, column 0.
        let red = data.dropFirst(header.utf8.count).prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        XCTAssertEqual(Double(red), ImageMetrics.linear[Int(bgra[4 * (7 * 16) + 2])], accuracy: 1e-7)
    }

    /// The scene goldens' spec reads, and its shots exist.
    func testBaselineSpec() throws {
        let spec = try SnapshotSpec.load(GoldenImageTests.shots.appendingPathComponent("f0.json"))
        XCTAssertEqual(spec.goldens, .scene)
        XCTAssertGreaterThanOrEqual(spec.shots.count, 8)
        XCTAssertEqual(Set(spec.shots.map(\.name)).count, spec.shots.count)
        for shot in spec.shots { XCTAssertNotNil(Scenario.named(shot.scenario), shot.name) }
    }

    /// F12's files: the PNG, its PFM, a PNG per debug view and the record.
    func testAppSnapshotWritesItsFiles() throws {
        let s = try snapper()
        let shot = SnapshotSpec.Shot(name: "f12", scenario: "leo")
        let prepared = try shot.prepare(system: s.system)
        var small = shot
        small.width = 160
        small.height = 100
        let scene = small.scene(prepared)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orbitsim-f12-\(UUID().uuidString)")
        setenv("ORBITSIM_SNAPSHOT_DIR", dir.path, 1)
        defer { unsetenv("ORBITSIM_SNAPSHOT_DIR") }
        let r = try s.renderer(userTextures: false)
        let png = try AppSnapshot.write(scene, renderer: r)
        let second = try AppSnapshot.write(scene, renderer: r)
        XCTAssertNotEqual(second, png, "a second snapshot in the same second does not overwrite the first")
        for suffix in [".png", ".pfm", ".depth.png", ".normals.png", ".luminance.png", ".sunShadow.png", ".json"] {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(second.deletingPathExtension().lastPathComponent + suffix))
        }
        let stem = png.deletingPathExtension().lastPathComponent
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(files, [stem + ".png", stem + ".pfm", stem + ".depth.png", stem + ".normals.png",
                               stem + ".luminance.png", stem + ".sunShadow.png", stem + ".json"])
        let back = try ImageFiles.readPNG(png)
        XCTAssertEqual([back.width, back.height], [160, 100])
        XCTAssertEqual(r.settings, RenderSettings(), "the renderer's settings are put back")
    }
}
