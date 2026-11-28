import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// Look round 2's LR5: the trail carries on P2's far field. Along AS-506's
/// flight at T+3, 8, 15, 30, 60 and 120 s:
/// - the hand-over's column is P2's cluster field there projected side-on
///   (a brute-force march across it), and λ is the F-1s' flow over the
///   airspeed;
/// - P2 fades out as the complement of the trail's nodes fading in
///   (`TrailChainTests` holds the joint's sum side-on);
/// - a rebuild's modelled column is the frames' within 5 %.
final class ExhaustTrailTests: XCTestCase {
    static let checkpoints: [Double] = [3, 8, 15, 30, 60, 120]

    struct Checkpoint {
        var t: Double
        var scene: RenderScene
        var head: PlumeAirflow.Handover
        var members: [PlumeMember]
        var vehicle: LaunchEffects.Vehicle
        /// The pad's anchor at the checkpoint.
        var anchor: AnchorFrame
    }

    /// One flight at 2 Hz from first motion, kept at the checkpoints.
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
            // P4's one anchor, at the deck.
            let anchor = run.outputs.last!.anchors.first!.frame
            out.append(Checkpoint(t: at, scene: scene, head: PlumeAirflow.trailHandover(own)!, members: members,
                                  vehicle: LaunchEffects.vehicle(in: scene, site: site)!, anchor: anchor))
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
            // The trail's Gaussian line (`TrailColumn.Node.startWidth`, σ =
            // C / (τ √(2π))), its depth and cross-section the column's, is
            // as wide at half its depth as the marched field within 15 %:
            // 2 √(2 ln 2) σ against the profile's (12 % narrower at T+120 s,
            // where P2's field is flatter than a Gaussian).
            let sigma = col.crossSection / (col.depth * (2 * Double.pi).squareRoot())
            let fieldWidth = Double(profile.filter { $0 >= 0.5 * peak }.count) * d
            XCTAssertEqual(2 * (2 * log(2.0)).squareRoot() * sigma, fieldWidth, accuracy: 0.15 * fieldWidth,
                           "T+\(c.t) s: the line's width")
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

    /// Decision 4's knob: `PlumeSettings.sootScale` scales P2's kerosene
    /// soot, so the hand-over's soot, and reaches the trail through the
    /// frame's plume settings (`LaunchEffects.vehicle`); it is coded and
    /// decoded with the settings.
    func testSootScaleReachesTheTrail() throws {
        let c = try XCTUnwrap(Self.flight.first { $0.t == 60 })
        let own = c.scene.emitters.filter { $0.name.hasPrefix("S-IC engine") }
        var settings = PlumeSettings()
        settings.sootScale = 5
        let base = try XCTUnwrap(PlumeAirflow.trailHandover(own)?.column)
        let sooty = try XCTUnwrap(PlumeAirflow.trailHandover(own, settings: settings)?.column)
        XCTAssertEqual(sooty.sootCrossSection, 5 * base.sootCrossSection, accuracy: 1e-9 * sooty.sootCrossSection)
        XCTAssertLessThan(sooty.albedo, base.albedo)
        let site = try XCTUnwrap(c.scene.sites.first { $0.name == LC39A.placement().name })
        let vehicle = try XCTUnwrap(LaunchEffects.vehicle(in: c.scene, site: site, plumes: settings))
        XCTAssertEqual(vehicle.trailHead?.column, sooty)
        let decoded = try JSONDecoder().decode(PlumeSettings.self, from: try JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.sootScale, 5)
        XCTAssertEqual(try JSONDecoder().decode(PlumeSettings.self, from: Data("{}".utf8)).sootScale, 1)
    }

    /// P2's hand-over fade is the complement of the trail's nodes fading
    /// in over the window, seen through their σ along the path
    /// (`PlumeAirflow.trailFade`): the merged far field sampled with and
    /// without it, along the axis from 2.5σ before the window to 2.5σ past
    /// it, at T+60 s; the plume as built reaches that far; and the window
    /// ends 2.5σ before the built length's end where that is short.
    func testHandoverFadeIsTheTrailsComplement() throws {
        let c = try XCTUnwrap(Self.flight.first { $0.t == 60 })
        let cluster = PlumeClusters.cluster(c.members)
        var m = try XCTUnwrap(cluster.merged)
        let window = try XCTUnwrap(m.handoverFade), sigma = m.handoverAlong
        XCTAssertEqual(sigma, TrailChain.jointAlong)
        XCTAssertEqual(window, c.head.fadeWindow)
        let reach = window.upperBound + PlumeAirflow.trailFadeReach * sigma
        XCTAssertLessThanOrEqual(reach, (c.members.map(\.builtLength).max() ?? 0) + 1e-9)
        XCTAssertEqual(cluster.members.map(\.length).max() ?? 0, reach, accuracy: 1e-9)
        m.fadeStart = nil
        m.length = 1e9
        var unfaded = m
        unfaded.handoverFade = nil
        for k in 0...20 {
            let x = window.lowerBound - 2.5 * sigma + (reach - window.lowerBound + 2.5 * sigma) * Double(k) / 20
            let ratio = m.sample(x: x, r: 0).extinction / unfaded.sample(x: x, r: 0).extinction
            XCTAssertEqual(ratio, PlumeAirflow.trailFade(x, window: window, along: sigma), accuracy: 1e-9, "x \(x) m")
        }
        // The complement of the ramp seen through σ: R = ramp ⊛ G by
        // quadrature, and its reach.
        for x in stride(from: window.lowerBound - 40, through: reach + 40, by: 7.0) {
            let n = 4_000, lo = -6 * sigma, du = 12 * sigma / Double(n)
            var r = 0.0
            for i in 0..<n {
                let u = lo + (Double(i) + 0.5) * du
                let ramp = min(max((x - u - window.lowerBound) / (window.upperBound - window.lowerBound), 0), 1)
                r += ramp * exp(-0.5 * u * u / (sigma * sigma)) * du / (sigma * (2 * Double.pi).squareRoot())
            }
            XCTAssertEqual(PlumeAirflow.trailFade(x, window: window, along: sigma), 1 - r, accuracy: 2e-6, "x \(x) m")
        }
        let tail = 2.1e-3 * sigma / (window.upperBound - window.lowerBound)
        XCTAssertLessThan(PlumeAirflow.trailFade(reach, window: window, along: sigma), tail)
        XCTAssertEqual(PlumeAirflow.trailFade(window.lowerBound - 2.5 * sigma, window: window, along: sigma), 1, accuracy: tail)
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
}
