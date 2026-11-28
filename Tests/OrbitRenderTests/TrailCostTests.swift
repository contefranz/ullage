import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// What LR5's trail (TrailPass) costs on the GPU in whole frames, as the app
/// draws them (every default pass, High): the trail chase at T+75 s
/// (`p4-trail-chase`) and the frame ledger's max-Q chase (T+80 s, 300 m,
/// 35° down: the trail seen down its length) and the same at T+120 s. The
/// frame is held at its instant, the trail drawn and not, alternating frame
/// by frame, each waited for; the difference of the medians, as the
/// ledger's shares are (docs/look/frame-ledger.md). A performance run,
/// which holds the GPU lock:
///
///     ORBITSIM_TIMINGS=1 scripts/test.sh fast --no-parallel --filter TrailCostTests
///
/// 100 rounds at 3024×1964 unless ORBITSIM_TIMINGS_ROUNDS=N or
/// ORBITSIM_TIMINGS_SIZE=WxH say otherwise.
@MainActor
final class TrailCostTests: XCTestCase {
    static let frames: [(name: String, advance: [String], camera: SnapshotSpec.CameraSpec?)] = [
        ("p4-trail-chase t+75", ["met:75"], nil),
        ("max-q t+80", ["met:80"], SnapshotSpec.CameraSpec(yaw: 170, pitch: -35, distance: 300, fov: 60)),
        ("max-q t+120", ["met:120"], SnapshotSpec.CameraSpec(yaw: 170, pitch: -35, distance: 300, fov: 60)),
    ]

    func testCostReport() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ORBITSIM_TIMINGS"] != nil else { throw XCTSkip("a performance run: ORBITSIM_TIMINGS=1") }
        let lock = GPULock { print("TrailCostTests: waiting for the GPU lock") }
        if lock == nil { print("TrailCostTests: no GPU lock; timings may be disturbed") }
        defer { withExtendedLifetime(lock) {} }
        let size = (env["ORBITSIM_TIMINGS_SIZE"] ?? "3024x1964").split(separator: "x").compactMap { Int($0) }
        let (w, h) = (size.first ?? 3024, size.last ?? 1964)
        let rounds = Int(env["ORBITSIM_TIMINGS_ROUNDS"] ?? "") ?? 100
        let device = try XCTUnwrap(RenderDevice.shared)
        let snapper = try SnapshotRenderer(device: device)
        let spec = try SnapshotSpec.load(GoldenImageTests.shots.appendingPathComponent("p4.json"))
        var lines: [String] = []
        for frame in Self.frames {
            var shot = try XCTUnwrap(spec.shots.first { $0.name == "p4-trail-chase" })
            shot.width = w
            shot.height = h
            shot.advance = frame.advance
            if let c = frame.camera { shot.camera = c }
            // The app's settings: clouds, probe and atmosphere on.
            shot.settings = RenderSettings()
            let particles = ParticleSystem()
            let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb,
                                      passes: SceneRenderer.defaultPasses(particles: particles),
                                      plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
            XCTAssertEqual(r.failures, [:])
            let target = try XCTUnwrap(OffscreenTarget(device: device, width: w, height: h))
            let prepared = try shot.prepare(system: snapper.system)
            let camera = prepared.camera
            var settings = shot.settings
            let scene = prepared.extractor.extract(sim: prepared.sim, camera: camera, viewport: shot.viewport, realTime: 0)
            var times: [Bool: [Double]] = [true: [], false: []]
            func draw(_ on: Bool) -> Double? {
                settings.particle.trail = on
                r.settings = settings
                guard let cb = r.renderAndWait(scene, into: target) else { return nil }
                return (cb.gpuEndTime - cb.gpuStartTime) * 1e3
            }
            for i in 0..<20 { _ = draw(i % 2 == 0) }
            for k in 0..<rounds {
                for on in (k % 2 == 0 ? [true, false] : [false, true]) {
                    if let t = draw(on) { times[on]!.append(t) }
                }
            }
            func median(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }
            let media = particles.output?.media.count ?? 0
            let line = String(format: "%@: the trail %.3f ms (on %.3f, off %.3f ms), %d media",
                              frame.name, median(times[true]!) - median(times[false]!), median(times[true]!),
                              median(times[false]!), media)
            print("TrailCostTests: \(line)")
            lines.append(line)
        }
        XCTAssertEqual(lines.count, Self.frames.count)
    }
}
