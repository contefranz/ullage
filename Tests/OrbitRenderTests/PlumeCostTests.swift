import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// What P2's plumes cost on the GPU (the plan's line, at High: 1.5 ms on
/// the pad, inside the cloud, and 0.5 ms in LEO), in the shots of
/// docs/look/shots/p2-cost.json: one renderer with every default pass, the
/// plumes on (High) and off on alternate frames, each waited for, the
/// difference of the medians (the project's GPU cost method). C2's clouds
/// keep R6's slots running in both, so the difference is the plumes' own:
/// P0's planning and lights, the march, the impostors and glows, and
/// what their light costs R2's vessel pass. A performance run, which holds
/// the GPU lock:
///
///     ORBITSIM_TIMINGS=1 scripts/test.sh fast --no-parallel --filter PlumeCostTests
///
/// 120 rounds at 3024×1964 unless ORBITSIM_TIMINGS_ROUNDS=N or
/// ORBITSIM_TIMINGS_SIZE=WxH say otherwise.
@MainActor
final class PlumeCostTests: XCTestCase {
    final class Times: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int: Double] = [:]
        func set(_ k: Int, _ v: Double) { lock.withLock { values[k] = v } }
        var all: [Int: Double] { lock.withLock { values } }
    }

    func testCostReport() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ORBITSIM_TIMINGS"] != nil else { throw XCTSkip("a performance run: ORBITSIM_TIMINGS=1") }
        let lock = GPULock { print("PlumeCostTests: waiting for the GPU lock") }
        if lock == nil { print("PlumeCostTests: no GPU lock; timings may be disturbed") }
        defer { withExtendedLifetime(lock) {} }
        let size = (env["ORBITSIM_TIMINGS_SIZE"] ?? "3024x1964").split(separator: "x").compactMap { Int($0) }
        let (w, h) = (size.first ?? 3024, size.last ?? 1964)
        let rounds = Int(env["ORBITSIM_TIMINGS_ROUNDS"] ?? "") ?? 120

        let device = try XCTUnwrap(RenderDevice.shared)
        let snapper = try SnapshotRenderer(device: device)
        let spec = try SnapshotSpec.load(GoldenImageTests.shots.appendingPathComponent("p2-cost.json"))
        var lines: [String] = []
        for var shot in spec.shots {
            shot.width = w
            shot.height = h
            let r = try SceneRenderer(device: device, loadsUserTextures: false)
            r.setStars(snapper.stars)
            XCTAssertEqual(r.failures, [:])
            let target = try XCTUnwrap(OffscreenTarget(device: device, width: w, height: h))
            var scene = shot.scene(try shot.prepare(system: snapper.system))
            let start = scene.clock.simTime
            var on = shot.settings, off = shot.settings
            on.plume.quality = .high
            off.plume.quality = .off
            let times = Times()
            var frameCount = 0
            func frame(_ plumes: Bool) -> Int {
                frameCount += 1
                scene.clock.frameIndex = frameCount
                scene.clock.simTime = start + Double(frameCount) / 60
                scene.clock.simDt = 1.0 / 60
                scene.clock.realDt = 1.0 / 60
                scene.clock.temporalReset = false
                r.settings = plumes ? on : off
                let k = frameCount
                if let cb = r.renderAndWait(scene, into: target) { times.set(k, (cb.gpuEndTime - cb.gpuStartTime) * 1e3) }
                return k
            }
            for i in 0..<30 { _ = frame(i % 2 == 0) }
            var withPlumes: [Int] = [], without: [Int] = []
            for k in 0..<rounds {
                if k % 2 == 0 {
                    withPlumes.append(frame(true))
                    without.append(frame(false))
                } else {
                    without.append(frame(false))
                    withPlumes.append(frame(true))
                }
            }
            let all = times.all
            func median(_ ks: [Int]) -> Double {
                let v = ks.compactMap { all[$0] }.sorted()
                return v.isEmpty ? .nan : v[v.count / 2]
            }
            // Each pass's share from the split profiler (it overstates
            // render passes in encoders of their own).
            r.settings = on
            r.profiling = true
            r.profileInterval = 1
            var samples: [String: [Double]] = [:]
            for _ in 0..<30 {
                frameCount += 1
                scene.clock.frameIndex = frameCount
                _ = r.renderAndWait(scene, into: target)
                for t in r.lastReport?.passes ?? [] { samples[t.pass, default: []].append(t.seconds * 1e3) }
            }
            r.profiling = false
            let breakdown = ["Plume march", "Plumes", "Vessels", "Transparent composite"].compactMap { k -> String? in
                guard let v = samples[k]?.sorted(), !v.isEmpty else { return nil }
                return String(format: "%@ %.3f", k, v[v.count / 2])
            }.joined(separator: ", ")
            let system = r.graph.passes.compactMap { ($0 as? PlumePreparePass)?.system }.first
            let clusters = system?.lastClusters ?? []
            let line = String(format: "%@: plumes %.3f ms (on %.3f, off %.3f ms); clusters %d (marched %d, impostors %d)",
                              shot.name, median(withPlumes) - median(without), median(withPlumes), median(without),
                              clusters.count, clusters.filter { $0.detail == .march }.count,
                              clusters.filter { $0.detail == .impostor }.count)
            print("PlumeCostTests: \(line)")
            print("PlumeCostTests:   passes (ms, split profiler): \(breakdown)")
            lines.append(line)
        }
        XCTAssertEqual(lines.count, spec.shots.count)
    }
}
