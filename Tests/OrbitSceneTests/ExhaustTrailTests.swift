import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// Look round 2's LR5 PR1: the trail carries on P2's far field. Along
/// AS-506's flight at T+3, 8, 15, 30, 60 and 120 s:
/// - the hand-over's column is P2's cluster field there projected side-on
///   (a brute-force march across it), and λ is the F-1s' flow over the
///   airspeed;
/// - the puffs laid carry it on: their line's depth and cross-section are
///   the column's, its width within 10 % of the field's, its albedo the
///   column's;
/// - the trail's fade and the plume's sum to one at the joint;
/// - a rebuild's modelled column is the frames' within 5 %;
/// - the puffs are spread evenly along the path (no beads).
final class ExhaustTrailTests: XCTestCase {
    static let checkpoints: [Double] = [3, 8, 15, 30, 60, 120]

    struct Checkpoint {
        var t: Double
        var scene: RenderScene
        var head: PlumeAirflow.Handover
        var members: [PlumeMember]
        var vehicle: LaunchEffects.Vehicle
        /// The last frame's trail requests, and the last 40 frames' with
        /// their frames' times (s from range zero).
        var newest: [EmitRequest]
        var requests: [(request: EmitRequest, epoch: Double)]
        var fadeIn: Double
    }

    /// One flight at 2 Hz from first motion, kept at the checkpoints, with
    /// the trail's requests of the last 40 frames before each.
    static let flight: [Checkpoint] = {
        let sim = try! XCTUnwrap(Scenario.named("as506-first-motion")).build(LaunchEffectsTests.system)
        if let c = sim.terminalCount, c.isHolding { c.resume(at: sim.time, in: sim) }
        var camera = OrbitCamera()
        if let focus = sim.focus {
            camera.target = .vessel(focus.id)
            camera.distance = max(focus.boundingRadius * 3, 30)
        }
        camera.update(sim: sim)
        let run = LaunchEffectsTests.Run(sim, camera)
        run.frame()
        let zero = LaunchCountdown.epoch(0, in: .apollo11)
        sim.paused = false
        sim.stepBudget = nil
        var out: [Checkpoint] = []
        for at in checkpoints {
            // In equal steps of about half a second onto the checkpoint.
            let n = max(1, Int(((at - (sim.time - zero)) / 0.5).rounded()))
            let h = (at - (sim.time - zero)) / Double(n)
            for _ in 0..<n {
                sim.advance(by: h / sim.warp)
                run.realTime += h
                run.frame()
            }
            let scene = run.scene!
            let site = scene.sites.first { $0.name == LC39A.placement().name }!
            let own = scene.emitters.filter { $0.name.hasPrefix("S-IC engine") }
            let members = own.filter { !$0.isJet }.compactMap { PlumeLook.member($0, settings: PlumeSettings()) }
            let materials = run.effects.materials!
            let recent = zip(run.outputs, run.epochs).suffix(40).flatMap { o in
                run.requests(.trail, in: o.0).map { (request: $0, epoch: o.1 - zero) }
            }
            out.append(Checkpoint(t: at, scene: scene, head: PlumeAirflow.trailHandover(own)!, members: members,
                                  vehicle: LaunchEffects.vehicle(in: scene, site: site)!,
                                  newest: run.requests(.trail, in: run.outputs.last!), requests: recent,
                                  fadeIn: run.session.materials[materials.trail[0]].fadeIn))
        }
        return out
    }()

    /// The cluster's field at the camera-relative `p`, unfaded: the members
    /// and, beyond the merge, the merged far field, blended as P2's march
    /// blends them (`plume_march_fragment`).
    func field(_ cluster: PlumeCluster, at p: Vec3) -> PlumeMember.Sample {
        func unfaded(_ m: PlumeMember) -> PlumeMember {
            var m = m
            m.length = 1e9
            m.fadeStart = nil
            m.handoverFade = nil
            return m
        }
        let x = (p - cluster.origin).dot(cluster.axis)
        let wm = cluster.mergeX > 0 ? PlumeMember.smoothstep(cluster.mergeX, 1.15 * cluster.mergeX, x) : 0
        var s = PlumeMember.Sample()
        if wm < 1 { for m in cluster.members { s = s + unfaded(m).sample(at: p).scaled(by: 1 - wm) } }
        if wm > 0, let m = cluster.merged { s = s + unfaded(m).sample(at: p).scaled(by: wm) }
        return s
    }

    /// The hand-over's column against the cluster's field marched across
    /// the axis there, side-on (a 2-D grid across the bent centreline), and
    /// λ against the F-1s' rated flow.
    func testColumnIsP2sFarFieldProjected() throws {
        for c in Self.flight {
            let col = try XCTUnwrap(c.head.column, "T+\(c.t) s")
            let cluster = PlumeClusters.cluster(c.members)
            XCTAssertGreaterThan(c.head.x, 1.15 * cluster.mergeX, "T+\(c.t) s: the merged far field alone")
            let merged = try XCTUnwrap(cluster.merged)
            let centre = merged.centre(atX: c.head.x - (merged.exit - cluster.origin).dot(cluster.axis))
            let extent = 1.2 * merged.fieldExtent(atX: c.head.x)
            let n = 160, d = 2 * extent / Double(n)
            var profile: [Double] = [], scattering = 0.0
            for i in 0..<n {
                let y = -extent + (Double(i) + 0.5) * d
                var tau = 0.0
                for j in 0..<n {
                    let z = -extent + (Double(j) + 0.5) * d
                    let s = field(cluster, at: centre + cluster.u * y + cluster.v * z)
                    tau += s.extinction * d
                    scattering += s.scattering * d * d
                }
                profile.append(tau)
            }
            let peak = profile.max()!, cross = profile.reduce(0, +) * d
            XCTAssertEqual(col.depth, peak, accuracy: 0.03 * peak, "T+\(c.t) s: depth")
            XCTAssertEqual(col.crossSection, cross, accuracy: 0.02 * cross, "T+\(c.t) s: cross-section")
            XCTAssertEqual(col.albedo, scattering / cross, accuracy: 0.01, "T+\(c.t) s: albedo")
            // λ: the F-1s' flow over the airspeed.
            let own = c.scene.emitters.filter { $0.name.hasPrefix("S-IC engine") && !$0.isJet }
            let flow = own.reduce(0) { $0 + $1.flowFraction } * ApolloExhaust.f1.ratedFlow
            XCTAssertEqual(col.lineDensity, flow / max(c.vehicle.airspeed, 1), accuracy: 1e-9 * col.lineDensity)
            let half = profile.filter { $0 >= 0.5 * peak }.count
            print(String(format: "ExhaustTrailTests: T+%3.0f s: hand-over at %.0f m (window %.0f m), column depth %.2f, width %.0f m (field's FWHM %.0f m), albedo %.3f, λ %.1f kg/m at %.0f m/s, soot %.3f %% (7.5 m²/g)",
                         c.t, c.head.x, c.head.window, col.depth, col.width, Double(half) * d, col.albedo,
                         col.lineDensity, c.vehicle.airspeed, 100 * col.sootYield(massExtinction: 7_500)))
        }
    }

    /// Decision 4's reference: the soot P2's photo fit implies. Its soot
    /// depth across the F-1's exit (8 per soot index) at 7.5 m²/g on the
    /// exit's density (P1's, at sea level) is 0.39 % of the exhaust, 0.096 %
    /// past the afterburning (25 % left): the study's "P2's implied 0.07 %"
    /// was its estimate of this. Its far field keeps the cross-section while
    /// the jet slows, so at the hand-over the soot is a smaller share of λ.
    func testP2sImpliedSoot() throws {
        let f1 = ApolloExhaust.f1
        let state = PlumeModel.state(f1.spec, flowFraction: 1, ambient: USStandardAtmosphere1976().state(altitude: 0),
                                     streamAlong: 0, streamAcross: 0)
        let sigma = PlumeLook.Optics.sootDepth * f1.spec.sootIndex / (2 * f1.spec.exitRadius)
        let exit = sigma / (7_500 * state.exitDensity), past = exit * PlumeLook.Optics.burntSoot
        print(String(format: "ExhaustTrailTests: P2's soot at the exit %.3f %%, past the afterburning %.3f %% (7.5 m²/g, exit density %.4f kg/m³)",
                     100 * exit, 100 * past, state.exitDensity))
        XCTAssertEqual(past, 0.00096, accuracy: 0.00003)
    }

    /// The puffs laid near the joint carry the column on: the line of
    /// `puffs` has its depth and cross-section (to rounding), the field's
    /// half-maximum width within 10 %, and the column's albedo by weight;
    /// the frames' requests use those puffs, laid where the ramp starts.
    func testPuffsCarryTheColumnOn() throws {
        for c in Self.flight {
            let col = try XCTUnwrap(c.head.column)
            let p = try XCTUnwrap(ExhaustTrail.puffs(col))
            let tau0 = ExhaustTrail.depthLevels[p.depthLevel]
            let depth = ExhaustTrail.lineDepthFactor * p.radius / p.spacing * tau0
            XCTAssertEqual(depth, col.depth, accuracy: 1e-9 * col.depth, "T+\(c.t) s")
            XCTAssertEqual(depth * ExhaustTrail.lineWidthFactor * p.radius, col.crossSection, accuracy: 1e-9 * col.crossSection)
            XCTAssertLessThanOrEqual(p.spacing, ExhaustTrail.spacingRadii * p.radius + 1e-9, "no beads: half a radius or nearer")
            XCTAssertEqual(p.albedo.reduce(0) { $0 + ExhaustTrail.albedoLevels[$1.level] * $1.weight },
                           min(max(col.albedo, 0.2), 0.95), accuracy: 1e-12)
            // The line's half-maximum width, 2 R √(1 − 2^(−2/5)), against the
            // column's Gaussian width.
            let lineWidth = 2 * p.radius * (1 - pow(2, -0.4)).squareRoot()
            XCTAssertEqual(lineWidth, col.width, accuracy: 0.1 * col.width, "T+\(c.t) s: width")
            // The frame's newest request (none while the joint is below the
            // deck): these radii.
            guard let newest = c.newest.min(by: { $0.ages.lowerBound < $1.ages.lowerBound }) else {
                print("ExhaustTrailTests: T+\(c.t) s: nothing laid yet (the joint below the deck)")
                continue
            }
            XCTAssertEqual(0.5 * (newest.radius.lowerBound + newest.radius.upperBound), p.radius, accuracy: 1e-9 * p.radius)
        }
    }

    /// The fade at the checkpoints: the frames' share against the plume's
    /// window, summing to one within 3.5 % (the minimax ramp's 3.08 % and
    /// the share's 0.5 % steps), unless the pad's slow start caps it.
    func testFadesSumToOneAtTheJoint() {
        for c in Self.flight {
            let w = c.head.window, v = c.vehicle.airspeed
            XCTAssertEqual(c.fadeIn, ExhaustTrail.fadeIn(window: w, airspeed: v), "T+\(c.t) s")
            let seconds = c.fadeIn * ExhaustTrail.lifetime.upperBound
            guard 2 * ExhaustTrail.rampHalfWidth * w / v < ExhaustTrail.longestFadeIn else {
                print("ExhaustTrailTests: T+\(c.t) s: the fade-in capped at \(ExhaustTrail.longestFadeIn) s")
                continue
            }
            var worst = 0.0
            for k in 0...200 {
                let x = -w + 2 * w * Double(k) / 200
                let trail = min(1, max(0, (x + ExhaustTrail.rampHalfWidth * w) / v / seconds))
                worst = max(worst, abs(1 - PlumeMember.smoothstep(-w, w, x) + trail - 1))
            }
            XCTAssertLessThan(worst, 0.035, "T+\(c.t) s")
        }
    }

    /// A rebuild's column (`modelColumn`: the F-1s as the scene gives them,
    /// along their axes in the air at the vehicle) against the frames'.
    func testModelColumnIsTheFrames() throws {
        for c in Self.flight {
            let col = try XCTUnwrap(c.head.column)
            let air = try XCTUnwrap(c.scene.emitters.first { $0.name.hasPrefix("S-IC engine") }).ambient
            let own = c.scene.emitters.filter { $0.name.hasPrefix("S-IC engine") && !$0.isJet }
            let flow = own.reduce(0) { $0 + $1.flowFraction } / Double(own.count)
            let model = try XCTUnwrap(ExhaustTrail.modelColumn(c.vehicle.vessel, flow: { _ in flow },
                                                               density: air.density, temperature: air.temperature,
                                                               pressure: air.pressure, airspeed: c.vehicle.airspeed))
            XCTAssertEqual(model.depth, col.depth, accuracy: 0.05 * col.depth, "T+\(c.t) s: depth")
            XCTAssertEqual(model.crossSection, col.crossSection, accuracy: 0.03 * col.crossSection, "T+\(c.t) s: cross-section")
            XCTAssertEqual(model.albedo, col.albedo, accuracy: 0.02, "T+\(c.t) s: albedo")
        }
    }

    /// The puffs of the last 40 frames lie evenly along the path: all of
    /// them, sampled as the emit kernel samples them and placed at their
    /// spawn, in the order they were laid. Stratified, each puff jittered
    /// within its own stratum, a step from one to the next is the stratum
    /// times 1 + u − u′, at most two of them (2.6 means, with the strata
    /// varying from piece to piece), and over 1.8 means for 2 % of them;
    /// random places along a line, as `.line` laid them, step an
    /// exponential: over 1.8 means for 17 % of them, and over five means
    /// somewhere in a few hundred.
    func testPuffsAreSpreadEvenly() throws {
        var checked = 0
        for c in Self.flight where c.t >= 30 {
            var puffs: [(laid: Double, at: Vec3)] = []
            for (r, epoch) in c.requests {
                for i in 0..<r.count {
                    let p = EmitSampler.sample(r, index: i)
                    puffs.append((epoch - p.age, p.position))
                }
            }
            puffs.sort { $0.laid < $1.laid }
            let steps = zip(puffs.dropFirst(), puffs).map { ($0.at - $1.at).length }
            let mean = steps.reduce(0, +) / Double(steps.count)
            let long = Double(steps.filter { $0 > 1.8 * mean }.count) / Double(steps.count)
            print(String(format: "ExhaustTrailTests: T+%.0f s: %d puffs, steps: mean %.1f m, %.1f %% over 1.8 means, largest %.2f means",
                         c.t, puffs.count, mean, 100 * long, steps.max()! / mean))
            XCTAssertGreaterThan(puffs.count, 40, "T+\(c.t) s")
            XCTAssertLessThan(steps.max()!, 2.6 * mean, "T+\(c.t) s")
            XCTAssertLessThan(long, 0.06, "T+\(c.t) s")
            checked += 1
        }
        XCTAssertEqual(checked, 3)
    }
}
