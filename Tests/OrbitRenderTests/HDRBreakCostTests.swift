import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// What a break of the scene costs on the HDR plan, against the same frame
/// without one, in five cases: no effect; R6's effect slots drawing a small
/// slab, with the scene re-expanded after the break and with its samples
/// kept; and a pass that breaks the scene and draws nothing, both ways.
/// Whole frames' GPU times in one renderer, the five cases alternating
/// frame by frame (two renderers' queues overlap on the GPU), each round in
/// another order; then the profile's line for the pass that breaks the
/// scene. A performance run, which holds the GPU lock:
///
///     ORBITSIM_TIMINGS=1 scripts/test.sh fast --no-parallel --filter HDRBreakCostTests
///
/// 300 rounds at 3024×1964 unless ORBITSIM_TIMINGS_ROUNDS=N or
/// ORBITSIM_TIMINGS_SIZE=WxH say otherwise.
@MainActor
final class HDRBreakCostTests: XCTestCase {
    enum Case: String, CaseIterable {
        case off = "no effect", reExpanded = "effect, re-expanded", kept = "effect, samples kept"
        case breakReExpanded = "a break alone, re-expanded", breakKept = "a break alone, samples kept"
        var effect: Bool { self == .reExpanded || self == .kept }
        var breaks: Bool { self == .breakReExpanded || self == .breakKept }
        var keeps: Bool { self == .kept || self == .breakKept }
    }

    func testBreakCost() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ORBITSIM_TIMINGS"] != nil else { throw XCTSkip("a performance run: ORBITSIM_TIMINGS=1") }
        let lock = GPULock { print("HDRBreakCostTests: waiting for the GPU lock") }
        if lock == nil { print("HDRBreakCostTests: no GPU lock; timings may be disturbed") }
        defer { withExtendedLifetime(lock) {} }
        let size = (env["ORBITSIM_TIMINGS_SIZE"] ?? "3024x1964").split(separator: "x").compactMap { Int($0) }
        let (w, h) = (size.first ?? 3024, size.last ?? 1964)

        let device = try XCTUnwrap(RenderDevice.shared)
        let snapper = try SnapshotRenderer(device: device)
        var shot = EffectSlotsRenderTests.shot([EffectTestEmitter(.slab, size: 5)], backdrop: false, width: w,
                                               height: h)
        shot.settings.post.exposure.mode = .manual
        shot.settings.post.exposure.ev100 = 14
        let scene = shot.scene(try shot.prepare(system: snapper.system))
        // A pass that breaks the scene and draws nothing: the plan's part alone.
        let breaker = BreakTestPass()
        let r = try SceneRenderer(device: device, outputFormat: .bgra8Unorm_srgb,
                                  passes: SceneRenderer.defaultPasses(loadsUserTextures: false) + [breaker],
                                  plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
        XCTAssertEqual(r.failures, [:])
        r.setStars(snapper.stars)
        let plan = try XCTUnwrap(r.graph.plan as? HDRTargetPlan)
        let target = try XCTUnwrap(OffscreenTarget(device: device, width: w, height: h))
        func set(_ c: Case) {
            var s = shot.settings
            // R1's break and R6's slab alone: C2's clouds would draw through
            // R6's slots, so every case would break the scene.
            s.cloud.enabled = false
            if !c.effect { s.transparency.testEmitters = [] }
            r.settings = s
            breaker.active = c.breaks
            plan.resolvesAtBreaks = !c.keeps
        }
        func frame(_ c: Case) throws -> Double {
            set(c)
            let cb = try XCTUnwrap(r.renderAndWait(scene, into: target))
            XCTAssertNil(cb.error)
            return (cb.gpuEndTime - cb.gpuStartTime) * 1e3
        }
        func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        func quartiles(_ v: [Double]) -> (Double, Double) { (v.sorted()[v.count / 4], v.sorted()[3 * v.count / 4]) }

        let cases = Case.allCases
        for _ in 0..<15 { for c in cases { _ = try frame(c) } }
        var times: [Case: [Double]] = [:]
        let rounds = Int(env["ORBITSIM_TIMINGS_ROUNDS"] ?? "") ?? 300
        for k in 0..<rounds {
            // Each round in another order, so no case always follows another.
            for j in 0..<cases.count {
                let c = cases[(j + k) % cases.count]
                times[c, default: []].append(try frame(c))
            }
        }
        let off = median(times[.off] ?? [])
        print("HDRBreakCostTests at \(w)×\(h), \(rounds) frames each, GPU ms (median, quartiles):")
        for c in cases {
            let v = times[c] ?? [], m = median(v), q = quartiles(v)
            let extra = c == .off ? "" : String(format: ", %+.2f ms over no effect", m - off)
            print(String(format: "  %@: %.2f (%.2f-%.2f)%@", c.rawValue, m, q.0, q.1, extra))
        }
        for (kept, new) in [(Case.kept, Case.reExpanded), (.breakKept, .breakReExpanded)] {
            // The difference of the two cases within each round.
            let paired = zip(times[kept] ?? [], times[new] ?? []).map { $0 - $1 }
            print(String(format: "  saving, %@: %.2f ms (medians), %.2f ms paired by round (quartiles %.2f-%.2f)",
                         new.effect ? "effect" : "break alone",
                         median(times[kept] ?? []) - median(times[new] ?? []), median(paired),
                         quartiles(paired).0, quartiles(paired).1))
        }

        // The profile: the pass that broke the scene carries the resume.
        r.profiling = true
        r.profileInterval = 1
        for c in [Case.reExpanded, .kept] {
            var v: [Double] = []
            for _ in 0..<40 {
                _ = try frame(c)
                if let t = r.lastReport?.passes.first(where: { $0.pass == "Half-resolution transparents" }) {
                    v.append(t.seconds * 1e3)
                }
            }
            if !v.isEmpty { print(String(format: "  profile, %@: Half-resolution transparents %.2f ms", c.rawValue, median(v))) }
        }
        r.profiling = false
    }
}
