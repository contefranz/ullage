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
        guard try s.renderer(userTextures: false).profiler.isSupported else {
            throw XCTSkip("no timestamp counters on this GPU")
        }
        XCTAssertEqual(timed.timings.map(\.pass), ["Stars", "Planets", "Vessels", "Orbit line", "Plumes", "Far points",
                                                   "Markers", FrameProfile.splitOverhead])
        // Each render pass's vertex and fragment time less what splitting
        // costs (an empty encoder's time): small passes may read 0.
        for t in timed.timings { XCTAssertGreaterThanOrEqual(t.seconds, 0, t.pass) }
        XCTAssertGreaterThan(timed.timings.last!.seconds, 0, "the split overhead is measured")
        let sum = timed.timings.map(\.seconds).reduce(0, +)
        XCTAssertLessThan(sum, 2 * timed.record.gpuMilliseconds / 1_000, "\(timed.timings)")
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
        let stem = png.deletingPathExtension().lastPathComponent
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(files, [stem + ".png", stem + ".pfm", stem + ".depth.png", stem + ".normals.png",
                               stem + ".luminance.png", stem + ".json"])
        let back = try ImageFiles.readPNG(png)
        XCTAssertEqual([back.width, back.height], [160, 100])
        XCTAssertEqual(r.settings, RenderSettings(), "the renderer's settings are put back")
    }
}
