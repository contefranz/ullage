import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// What P4's launch effects add on the GPU on AS-506's pad and through
/// liftoff (the plan's particle line: 1.0 ms on the pad at High, of which
/// P3's own cost shot already reads 1.16 ms). The scenario flies on at
/// 1/60 s a frame from each phase, P4's producer emitting as in the app;
/// frames hold only the particle passes (with R6's slots and composite,
/// which the smoke wakes, and R1's resolve and post), the particles on and
/// off, alternating frame by frame, each waited for; the difference of the
/// medians, as ParticleCostTests does. Each phase twice: with the slots
/// running only for P4's smoke, and with them running anyway (C2's clouds
/// wake them in every Earth scene), which is P4's own share. A performance
/// run, which holds the GPU lock:
///
///     ORBITSIM_TIMINGS=1 scripts/test.sh fast --no-parallel --filter LaunchEffectsCostTests
///
/// 200 rounds at 3024×1964 unless ORBITSIM_TIMINGS_ROUNDS=N or
/// ORBITSIM_TIMINGS_SIZE=WxH say otherwise.
@MainActor
final class LaunchEffectsCostTests: XCTestCase {
    final class Times: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int: Double] = [:]
        func set(_ k: Int, _ v: Double) { lock.withLock { values[k] = v } }
        var all: [Int: Double] { lock.withLock { values } }
    }

    /// The phases: mission time (range time, s) and the shot whose camera
    /// they use.
    static let phases: [(met: Double?, shot: String)] = [
        (nil, "p4-pad-ignition"), (nil, "p4-liftoff"), (4, "p4-liftoff"), (8, "p4-liftoff"), (15, "p4-liftoff"),
        (30, "p4-liftoff"),
    ]

    func testCostReport() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ORBITSIM_TIMINGS"] != nil else { throw XCTSkip("a performance run: ORBITSIM_TIMINGS=1") }
        let lock = GPULock { print("LaunchEffectsCostTests: waiting for the GPU lock") }
        if lock == nil { print("LaunchEffectsCostTests: no GPU lock; timings may be disturbed") }
        defer { withExtendedLifetime(lock) {} }
        let size = (env["ORBITSIM_TIMINGS_SIZE"] ?? "3024x1964").split(separator: "x").compactMap { Int($0) }
        let (w, h) = (size.first ?? 3024, size.last ?? 1964)
        let rounds = Int(env["ORBITSIM_TIMINGS_ROUNDS"] ?? "") ?? 200

        let device = try XCTUnwrap(RenderDevice.shared)
        let snapper = try SnapshotRenderer(device: device)
        let spec = try SnapshotSpec.load(GoldenImageTests.shots.appendingPathComponent("p4.json"))
        var lines: [String] = []
        for (phase, slotsAlways) in Self.phases.flatMap({ p in [(p, false), (p, true)] }) {
            var shot = try XCTUnwrap(spec.shots.first { $0.name == phase.shot })
            shot.width = w
            shot.height = h
            if let met = phase.met { shot.advance = ["met:\(met)"] } else if phase.shot == "p4-liftoff" { shot.advance = [] }
            let effects = LaunchEffects()
            let system = ParticleSystem(director: EffectDirector(producers: [effects]))
            let slots = HalfResTransparentPass(effects: [ParticleSmokeEffect(system: system), EffectTestEmitters()])
            let post = PostPass()
            let passes: [RenderPass] = [ParticleSimulationPass(system: system), ParticleChunkPass(system: system), slots,
                                        TransparentCompositePass(slots: slots), ParticleDrawPass(system: system),
                                        post.resolvePass, post]
            let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb, passes: passes,
                                      plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
            XCTAssertEqual(r.failures, [:])
            let target = try XCTUnwrap(OffscreenTarget(device: device, width: w, height: h))
            let prepared = try shot.prepare(system: snapper.system)
            let sim = prepared.sim
            sim.paused = false
            sim.stepBudget = nil
            var camera = prepared.camera
            var settings = shot.settings
            let tier = settings.particle.quality
            if slotsAlways {
                settings.transparency.testEmitters = [EffectTestEmitter(.sprites, position: [5_000, 0, 0], size: 0.1, count: 1)]
            }
            let times = Times()
            let start = sim.time - VesselLibrary.apollo11RangeZero
            var frameCount = 0, realTime = 0.0
            func frame(_ on: Bool) -> Int {
                frameCount += 1
                if frameCount > 1 {
                    sim.advance(by: 1.0 / 60)
                    realTime += 1.0 / 60
                }
                camera.update(sim: sim)
                let scene = prepared.extractor.extract(sim: sim, camera: camera, viewport: shot.viewport,
                                                       realTime: realTime)
                settings.particle.quality = on ? tier : .off
                r.settings = settings
                let k = frameCount
                if let cb = r.renderAndWait(scene, into: target) { times.set(k, (cb.gpuEndTime - cb.gpuStartTime) * 1e3) }
                return k
            }
            _ = frame(true)
            for i in 0..<30 { _ = frame(i % 2 == 0) }
            var on: [Int] = [], off: [Int] = []
            for k in 0..<rounds {
                if k % 2 == 0 {
                    on.append(frame(true))
                    off.append(frame(false))
                } else {
                    off.append(frame(false))
                    on.append(frame(true))
                }
            }
            let all = times.all
            func median(_ ks: [Int]) -> Double {
                let v = ks.compactMap { all[$0] }.sorted()
                return v.isEmpty ? .nan : v[v.count / 2]
            }
            let counts = system.readCounters()
            let alive = system.current == 0 ? counts[.aliveA] ?? 0 : counts[.aliveB] ?? 0
            let end = sim.time - VesselLibrary.apollo11RangeZero
            let line = String(format: "%@ T+%.1f to %.1f s (%@, %@): P4 %.3f ms (on %.3f, off %.3f ms); alive %d, drawn streaks %d, smoke %d, chunks %d",
                              shot.name, start, end, tier.rawValue, slotsAlways ? "slots running anyway" : "slots for P4's smoke alone",
                              median(on) - median(off), median(on), median(off), alive, counts[.drawStreak] ?? 0,
                              counts[.drawSmoke] ?? 0, counts[.drawChunk] ?? 0)
            print("LaunchEffectsCostTests: \(line)")
            lines.append(line)
        }
        XCTAssertEqual(lines.count, 2 * Self.phases.count)
    }
}
