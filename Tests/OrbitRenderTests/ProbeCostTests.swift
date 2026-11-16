import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// What R3's environment probe costs on the GPU (the plan's budget: 0.3 ms
/// on the pad and in LEO at High on the M3 Pro, 3024×1964): one renderer
/// with every default pass, the probe on and off on alternate frames (one
/// queue, so frames do not overlap), the difference of the medians of
/// gpuEndTime − gpuStartTime, as CloudCostTests and LaunchEffectsCostTests
/// measure. The off frames light the vessels with R2's stand-in, so the
/// difference holds the vessels' cube reads too. A performance run, which
/// holds the GPU lock:
///
///     ORBITSIM_TIMINGS=1 scripts/test.sh fast --no-parallel --filter ProbeCostTests
///
/// 200 rounds unless ORBITSIM_TIMINGS_ROUNDS=N; ORBITSIM_TIMINGS_SIZE=WxH
/// for another size; ORBITSIM_PROBE_SHOTS=pad,leo for some shots;
/// ORBITSIM_PROBE_SETTINGS='{"clouds": false}' for the on frames' probe.
@MainActor
final class ProbeCostTests: XCTestCase {
    func testCostReport() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ORBITSIM_TIMINGS"] != nil else { throw XCTSkip("a performance run: ORBITSIM_TIMINGS=1") }
        let lock = GPULock { print("ProbeCostTests: waiting for the GPU lock") }
        if lock == nil { print("ProbeCostTests: no GPU lock; timings may be disturbed") }
        defer { withExtendedLifetime(lock) {} }
        let size = (env["ORBITSIM_TIMINGS_SIZE"] ?? "3024x1964").split(separator: "x").compactMap { Int($0) }
        let (w, h) = (size.first ?? 3024, size.last ?? 1964)
        let rounds = Int(env["ORBITSIM_TIMINGS_ROUNDS"] ?? "") ?? 200
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        let shots: [(String, String, SnapshotSpec.CameraSpec, [String])] = [
            ("pad", "as506-pad", SnapshotSpec.CameraSpec(yaw: -60, pitch: 4, distance: 210, fov: 38), []),
            ("ascent-60s", "as506-pad", SnapshotSpec.CameraSpec(yaw: 149, pitch: -25, distance: 400, fov: 60), ["met:60"]),
            ("leo", "as506-parking-orbit",
             SnapshotSpec.CameraSpec(target: "vessel:Apollo 11", frame: "vessel", yaw: 20, pitch: -12, distance: 14, fov: 40),
             ["stage", "wait:20"]),
        ]
        let only = env["ORBITSIM_PROBE_SHOTS"].map { $0.split(separator: ",").map(String.init) }
        for (name, scenario, camera, advance) in shots where only?.contains(name) ?? true {
            var shot = SnapshotSpec.Shot(name: name, scenario: scenario, advance: advance, camera: camera)
            shot.width = w
            shot.height = h
            shot.showOrbit = false
            let prepared = try shot.prepare(system: s.system)
            let base = shot.scene(prepared)
            let passes = SceneRenderer.defaultPasses(loadsUserTextures: false)
            let probe = try XCTUnwrap(passes.compactMap { $0 as? EnvironmentProbePass }.first)
            let r = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb, passes: passes,
                                      plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
            r.setStars(s.stars)
            XCTAssertEqual(r.failures, [:])
            var on = r.settings, off = r.settings
            on.particle.quality = .off
            off.particle.quality = .off
            off.probe.enabled = false
            // ORBITSIM_PROBE_SETTINGS: the probe's settings in the on frames (JSON).
            if let json = env["ORBITSIM_PROBE_SETTINGS"] {
                on.probe = try JSONDecoder().decode(ProbeSettings.self, from: Data(json.utf8))
            }
            let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: w, height: h))
            final class Times: @unchecked Sendable {
                let lock = NSLock()
                var a: [Double] = [], b: [Double] = []
            }
            let times = Times()
            var last: MTLCommandBuffer?
            var drawn = false
            for k in 0..<(2 * rounds + 40) {
                var scene = base
                scene.clock.frameIndex = k / 2 + 1
                scene.clock.temporalReset = k == 0
                let measure = k >= 40, isOn = k % 2 == 0
                r.settings = isOn ? on : off
                last = r.render(scene, to: target.texture) { cb in
                    guard measure else { return }
                    times.lock.withLock {
                        if isOn { times.a.append(cb.gpuEndTime - cb.gpuStartTime) } else { times.b.append(cb.gpuEndTime - cb.gpuStartTime) }
                    }
                }
                if isOn { drawn = probe.lastFrame.drawn }
            }
            last?.waitUntilCompleted()
            Thread.sleep(forTimeInterval: 0.2)
            XCTAssertTrue(drawn)
            func median(_ x: [Double]) -> Double { x.sorted()[x.count / 2] }
            let cost = (median(times.a) - median(times.b)) * 1_000
            print(String(format: "probe %@ at %dx%d: %.3f ms (frame %.2f ms, without the probe %.2f ms, %d rounds)",
                         name, w, h, cost, median(times.a) * 1_000, median(times.b) * 1_000, rounds))
        }
    }
}
