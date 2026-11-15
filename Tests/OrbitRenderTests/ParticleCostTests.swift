import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// What P3's particles cost on the GPU (the plan's line, at the High tier:
/// 1.0 ms on the pad, inside the cloud, and 0.3 ms in LEO), in the cost
/// shots of docs/look/shots/p3-cost.json. Frames that hold only P3's passes
/// (with R6's slots and composite, which its smoke wakes, and R1's resolve
/// and post, which every frame has), the particles on and off, alternating
/// frame by frame, each waited for; the difference of the medians (the method of the project's GPU cost notes:
/// whole frames' differences drown in the rest of the frame). The particles
/// are emitted once by a producer and then live and move at 1/60 s a frame
/// (the steady state, not the look-dev studio's respawn). Smoke's share
/// includes the slots' depth downsample, composite and the scene's break.
/// A performance run, which holds the GPU lock:
///
///     ORBITSIM_TIMINGS=1 scripts/test.sh fast --no-parallel --filter ParticleCostTests
///
/// 200 rounds at 3024×1964 unless ORBITSIM_TIMINGS_ROUNDS=N or
/// ORBITSIM_TIMINGS_SIZE=WxH say otherwise.
@MainActor
final class ParticleCostTests: XCTestCase {
    /// Emits a shot's look-dev bursts once, in the studio, and lets them live.
    final class OnceProducer: EffectProducer {
        let name = "cost bursts"
        let bursts: [ParticleTestBurst]
        let studio: StudioAnchor
        var ids: [ParticleMaterialID] = []
        var emitted = false

        init(bursts: [ParticleTestBurst], studio: StudioAnchor) {
            self.bursts = bursts
            self.studio = studio
        }

        func registerMaterials(_ table: ParticleMaterialTable) {
            ids = bursts.compactMap { $0.resolvedMaterial.map(table.register) }
        }

        func update(_ f: EffectFrame) {
            guard !emitted, let a = f.anchor(.studio(studio)) else { return }
            emitted = true
            for (b, id) in zip(bursts, ids) {
                var r = b.request(anchor: a, material: id)
                r.lifetime = r.lifetime.lowerBound...max(r.lifetime.upperBound, 600)
                f.emit(r)
            }
        }

        func reset() { emitted = false }
    }

    /// Thread-safe GPU times by frame.
    final class Times: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int: Double] = [:]
        func set(_ k: Int, _ v: Double) { lock.withLock { values[k] = v } }
        var all: [Int: Double] { lock.withLock { values } }
    }

    func testCostReport() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ORBITSIM_TIMINGS"] != nil else { throw XCTSkip("a performance run: ORBITSIM_TIMINGS=1") }
        let lock = GPULock { print("ParticleCostTests: waiting for the GPU lock") }
        if lock == nil { print("ParticleCostTests: no GPU lock; timings may be disturbed") }
        defer { withExtendedLifetime(lock) {} }
        let size = (env["ORBITSIM_TIMINGS_SIZE"] ?? "3024x1964").split(separator: "x").compactMap { Int($0) }
        let (w, h) = (size.first ?? 3024, size.last ?? 1964)
        let rounds = Int(env["ORBITSIM_TIMINGS_ROUNDS"] ?? "") ?? 200

        let device = try XCTUnwrap(RenderDevice.shared)
        let snapper = try SnapshotRenderer(device: device)
        let spec = try SnapshotSpec.load(GoldenImageTests.shots.appendingPathComponent("p3-cost.json"))
        var lines: [String] = []
        for (var shot, slotsAlways) in spec.shots.flatMap({ [($0, false), ($0, true)] }) {
            shot.width = w
            shot.height = h
            let bursts = shot.settings.particle.testBursts
            let tier = shot.settings.particle.quality
            let producer = OnceProducer(bursts: bursts, studio: shot.settings.particle.studio.anchor)
            let system = ParticleSystem(director: EffectDirector(producers: [producer]))
            // R6's test emitters keep the slots running in both cases with
            // `slotsAlways` (as C2's clouds do in an Earth scene): then the
            // difference is P3's own; without, it includes what the slots
            // and the scene's break cost a frame that has no other effect.
            let slots = HalfResTransparentPass(effects: [ParticleSmokeEffect(system: system), EffectTestEmitters()])
            let post = PostPass()
            let passes: [RenderPass] = [ParticleSimulationPass(system: system), ParticleChunkPass(system: system), slots,
                                        TransparentCompositePass(slots: slots), ParticleDrawPass(system: system),
                                        post.resolvePass, post]
            let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb, passes: passes,
                                      plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
            XCTAssertEqual(r.failures, [:])
            let target = try XCTUnwrap(OffscreenTarget(device: device, width: w, height: h))
            var scene = shot.scene(try shot.prepare(system: snapper.system))
            let start = scene.clock.simTime
            var settings = shot.settings
            settings.particle.testBursts = []
            if slotsAlways {
                // One sprite, far off to the side: the slots run, drawing next to nothing.
                settings.transparency.testEmitters = [EffectTestEmitter(.sprites, position: [5_000, 0, 0], size: 0.1, count: 1)]
            }
            let times = Times()
            var frameCount = 0
            func frame(_ on: Bool) -> Int {
                frameCount += 1
                scene.clock.frameIndex = frameCount
                scene.clock.simTime = start + Double(frameCount) / 60
                scene.clock.simDt = 1.0 / 60
                scene.clock.realDt = 1.0 / 60
                scene.clock.temporalReset = false
                settings.particle.quality = on ? tier : .off
                r.settings = settings
                let k = frameCount
                if let cb = r.renderAndWait(scene, into: target) { times.set(k, (cb.gpuEndTime - cb.gpuStartTime) * 1e3) }
                return k
            }
            for i in 0..<30 { _ = frame(i % 2 == 0) }
            var on: [Int] = [], off: [Int] = []
            for k in 0..<rounds {
                // Each round in another order.
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
            // Each pass's share from the split profiler (it overstates
            // render passes in encoders of their own; the compute
            // simulation's is exact).
            r.settings = { var x = settings; x.particle.quality = tier; return x }()
            r.profiling = true
            r.profileInterval = 1
            var samples: [String: [Double]] = [:]
            for _ in 0..<40 {
                frameCount += 1
                scene.clock.frameIndex = frameCount
                scene.clock.simTime = start + Double(frameCount) / 60
                _ = r.renderAndWait(scene, into: target)
                for t in r.lastReport?.passes ?? [] { samples[t.pass, default: []].append(t.seconds * 1e3) }
            }
            r.profiling = false
            let breakdown = samples.keys.sorted().map { k -> String in
                let v = samples[k]!.sorted()
                return String(format: "%@ %.3f", k, v[v.count / 2])
            }.joined(separator: ", ")
            let alive = system.readCounters()
            let line = String(format: "%@ (%@, %@): particles %.3f ms (on %.3f, off %.3f ms); alive %d, drawn streaks %d, smoke %d, chunks %d",
                              shot.name, tier.rawValue, slotsAlways ? "slots running anyway" : "slots for the smoke alone",
                              median(on) - median(off), median(on), median(off),
                              system.current == 0 ? alive[.aliveA] ?? 0 : alive[.aliveB] ?? 0, alive[.drawStreak] ?? 0,
                              alive[.drawSmoke] ?? 0, alive[.drawChunk] ?? 0)
            print("ParticleCostTests: \(line)")
            print("ParticleCostTests:   passes (ms, split profiler): \(breakdown)")
            lines.append(line)
        }
        XCTAssertEqual(lines.count, 2 * spec.shots.count)
    }
}
