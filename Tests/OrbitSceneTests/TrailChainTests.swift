import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// LR5 PR2's trail column along AS-506's flight: its nodes 25 m apart, its
/// head carrying P2's hand-over, and the same column from frames at 2 Hz,
/// from 1000× warp's frames and from a rebuild.
final class TrailChainTests: XCTestCase {
    static let zero = LaunchCountdown.epoch(0, in: .apollo11)

    static func open() -> LaunchEffectsTests.Run {
        let sim = try! XCTUnwrap(Scenario.named("as506-first-motion")).build(LaunchEffectsTests.system)
        if let c = sim.terminalCount, c.isHolding { c.resume(at: sim.time, in: sim) }
        var camera = OrbitCamera()
        if let focus = sim.focus {
            camera.target = .vessel(focus.id)
            camera.distance = max(focus.boundingRadius * 3, 30)
        }
        camera.update(sim: sim)
        sim.paused = false
        sim.stepBudget = nil
        let run = LaunchEffectsTests.Run(sim, camera)
        run.frame()
        return run
    }

    /// Flies `run` on to range time `at` in frames about `step` s apart.
    static func fly(_ run: LaunchEffectsTests.Run, to at: Double, step: Double) {
        let n = max(1, Int(((at - (run.sim.time - zero)) / step).rounded()))
        let h = (at - (run.sim.time - zero)) / Double(n)
        for _ in 0..<n {
            run.sim.advance(by: h / run.sim.warp)
            run.realTime += h
            run.frame()
        }
    }

    /// The chain's nodes at range time `t` in each frame run: at 2 Hz, at
    /// 1000× warp's frames (16.7 s apart), and rebuilt there.
    struct Snapshot {
        var t: Double
        var framed: [TrailColumn.Node]
        var head: PlumeAirflow.Handover?
        var airspeed: Double
        var now: Epoch
        /// P2's own column's Gaussian width where its fade ends (x + w), m.
        var p2WidthAtEnd: Double?
        /// The S-IC's members, and the pad's anchor then.
        var members: [PlumeMember]
        var frame: AnchorFrame
    }

    static let fine: [Snapshot] = {
        let run = open()
        var out: [Snapshot] = []
        for t in [3.0, 8, 15, 30, 60, 75, 120] {
            fly(run, to: t, step: 0.5)
            let scene = run.scene!
            let own = scene.emitters.filter { $0.name.hasPrefix("S-IC engine") }
            let head = PlumeAirflow.trailHandover(own)
            var end: Double?
            let members = own.filter { !$0.isJet }.compactMap { PlumeLook.member($0, settings: PlumeSettings()) }
            if let h = head, let column = h.column, !members.isEmpty {
                let (origin, axis) = PlumeClusters.frame(members)
                if let m = PlumeClusters.merged(members, origin: origin, axis: axis) {
                    let x = h.x + h.window - (m.member.exit - origin).dot(axis)
                    let c = PlumeAirflow.column(m.member, atX: x, lineDensity: column.lineDensity)
                    end = c.crossSection / (c.depth * (2 * Double.pi).squareRoot())
                }
            }
            out.append(Snapshot(t: t, framed: run.effects.trail.chain.nodes, head: head,
                                airspeed: own.first?.relativeWind.length ?? 0, now: run.sim.time, p2WidthAtEnd: end,
                                members: members, frame: run.outputs.last!.anchors.first!.frame))
        }
        return out
    }()

    /// The extinction laid per 2 km of height (m² of cross-section), faded
    /// in at `now`.
    static func bands(_ nodes: [TrailColumn.Node], now: Epoch) -> [Int: Double] {
        var b: [Int: Double] = [:]
        for n in nodes {
            let band = Int((n.air.height / 2_000).rounded(.down))
            b[band, default: 0] += n.column.crossSection * n.spacing * n.fade(age: now - n.laid)
        }
        return b
    }

    /// Nodes one spacing apart along the jet at the joint, laid in order,
    /// at T+15 and 60 s: through the air (the ground chord between two less
    /// the wind's drift between their epochs, as the wind carries them all)
    /// spacing V / (V + u) apart, u the jet's excess, along their tangent.
    func testNodesAreSpacedAlongThePathThroughTheAir() throws {
        for t in [15.0, 60] {
            let s = try XCTUnwrap(Self.fine.first { $0.t == t })
            let recent = s.framed.filter { s.now - $0.laid < 10 }
            XCTAssertGreaterThan(recent.count, t < 30 ? 3 : 20)
            var ground = 0.0
            for (a, b) in zip(recent, recent.dropFirst()) {
                XCTAssertGreaterThan(b.laid - a.laid, 0)
                let seen = (b.position - a.position) - (a.wind + b.wind) * (0.5 * (b.laid - a.laid))
                // At the joint the jet runs the excess u on from the air.
                let u = b.coflow.state(age: 0).excess
                XCTAssertEqual(seen.length + u * (b.laid - a.laid), TrailChain.spacing, accuracy: 0.02 * TrailChain.spacing,
                               "T+\(t) s")
                XCTAssertGreaterThan(seen.normalized.dot(b.tangent), 0.998, "T+\(t) s")
                XCTAssertEqual(b.spacing, TrailChain.spacing)
                ground += (b.position - a.position).length
            }
            print(String(format: "TrailChainTests: T+%.0f s: %d nodes in 10 s, %.1f m of ground path apart",
                         t, recent.count, ground / Double(recent.count - 1)))
        }
    }

    /// The head at T+3, 8, 15, 30, 60 and 120 s: the nodes laid this second
    /// carry the frame's own hand-over (its column, so P2's width at the
    /// joint, and its window); as it finishes crossing the window, fully in,
    /// it is as wide as P2's own field where its fade ends (x + w), within
    /// 25 %: past the hand-over (capped at 85 % of the plume's built
    /// length) the jet still runs 120 m/s over the air, and both go on
    /// spreading.
    func testHeadCarriesTheHandover() throws {
        var checked = 0
        for s in Self.fine where s.t != 75 {
            let newest = s.framed.filter { s.now - $0.laid < 1 }
            guard let head = s.head, let column = head.column, !newest.isEmpty else {
                print("TrailChainTests: T+\(s.t) s: no node yet (below the deck)")
                continue
            }
            let n = try XCTUnwrap(newest.last)
            XCTAssertEqual(n.column, column, "T+\(s.t) s")
            XCTAssertEqual(n.window, 2 * head.window, accuracy: 1e-9)
            XCTAssertEqual(n.spread(age: 0).principal.major, n.startWidth, accuracy: 1e-9 * n.startWidth,
                           "P2's width at the joint")
            // The newest node as it finishes crossing the window.
            let crossed = n
            let width = crossed.spread(age: crossed.fadeIn).principal.major
            let p2 = try XCTUnwrap(s.p2WidthAtEnd)
            XCTAssertEqual(crossed.fade(age: crossed.fadeIn), 1, accuracy: 1e-9)
            XCTAssertEqual(width, p2, accuracy: 0.25 * p2, "T+\(s.t) s")
            print(String(format: "TrailChainTests: T+%3.0f s: head σ %.1f m once in (P2's %.1f m at the joint, %.1f m at its fade's end), fade-in %.2f s over %.0f m, %d nodes",
                         s.t, width, crossed.startWidth, p2, crossed.fadeIn, crossed.window, s.framed.count))
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 4)
    }

    /// The joint seen side-on along the axis, as drawn, from 2.5σ before
    /// P2's window to 2.5σ past it, at T+15, 30, 60 and 120 s: P2's merged
    /// far field fading out (`PlumeAirflow.trailFade`) and the trail's
    /// nodes fading in (`TrailChain.media`, each young node by where it is
    /// in the window), each line's depth through P2's centreline across the
    /// axis. The two fades sum to one: P2's 1 − R and the trail's own, its
    /// depth as drawn over the same nodes fully in (continued past the
    /// newest). Not exactly: the nodes widen across the window as the jet
    /// slows, so the trail's column falls along it, and the ramp seen
    /// through σ along a falling column is R less about σ² f′ τ′/τ (f′ =
    /// 1/2w): within 5.5 % at T+15 s (a 40 m window), 2.5 % at T+30 s and
    /// 1.5 % past it (0.3 % at T+120 s). Their columns differ across the
    /// window as P2's spreading and the coflow's do (P2's field thins
    /// faster there): at the window's middle within 15 %.
    func testJointsFadesSumToOneSideOn() throws {
        var checked = 0
        for s in Self.fine where [15.0, 30, 60, 120].contains(s.t) {
            let cluster = PlumeClusters.cluster(s.members)
            let merged = try XCTUnwrap(cluster.merged), head = try XCTUnwrap(s.head)
            let start = (merged.exit - cluster.origin).dot(cluster.axis)
            let window = try XCTUnwrap(merged.handoverFade), sigma = merged.handoverAlong
            XCTAssertEqual(sigma, TrailChain.jointAlong)
            XCTAssertEqual(window.lowerBound, head.x - head.window, accuracy: 1e-9)
            XCTAssertEqual(window.upperBound, head.x + head.window, accuracy: 1e-9)
            let drawn = TrailChain.media(s.framed, at: s.now, in: s.frame, head: head)
            // The line fully in, continued past its newest node towards
            // the vehicle (copies of it a spacing apart), as the weight R
            // of a line laid on is reckoned.
            var full = TrailChain.media(s.framed, at: s.now, in: s.frame, faded: false)
            if let newest = full.last {
                for k in 1...6 {
                    var g = newest
                    g.centre = g.centre - cluster.axis * (TrailChain.spacing * Double(k))
                    full.append(g)
                }
            }
            func p2(_ xm: Double, faded: Bool) -> Double {
                var m = merged
                if !faded {
                    m.length = 1e9
                    m.fadeStart = nil
                    m.handoverFade = nil
                }
                let e = m.fieldExtent(atX: xm), n = 96, dr = e / Double(n)
                return (0..<n).reduce(0.0) { t, i in t + 2 * m.sample(x: xm, r: (Double(i) + 0.5) * dr).extinction * dr }
            }
            func trail(_ media: [GaussianMedium], _ xm: Double) -> Double {
                let centre = merged.centre(atX: xm), far = 10 * merged.fieldExtent(atX: xm) + 500
                return media.reduce(0.0) { t, g in
                    t + g.depth(origin: centre - cluster.u * far, direction: cluster.u, from: 0, to: 2 * far)
                }
            }
            let lo = window.lowerBound - 2.5 * sigma, hi = window.upperBound + 2.5 * sigma
            var worst = 0.0
            for k in 0...60 {
                let x = lo + (hi - lo) * Double(k) / 60, xm = x - start
                let p2Fade = p2(xm, faded: true) / p2(xm, faded: false), whole = trail(full, xm)
                guard whole > 1e-6 else {
                    XCTAssertEqual(p2Fade, 1, accuracy: 0.015, "T+\(s.t) s, x \(x) m: no trail yet")
                    continue
                }
                worst = max(worst, abs(p2Fade + trail(drawn, xm) / whole - 1))
            }
            let mid = head.x - start, continuity = trail(full, mid) / p2(mid, faded: false)
            print(String(format: "TrailChainTests: T+%3.0f s: the joint's fades side-on, window %.0f-%.0f m ± 2.5σ: sum within %.4f; the trail's column at its middle %.3f of P2's",
                         s.t, window.lowerBound, window.upperBound, worst, continuity))
            XCTAssertLessThan(worst, s.t < 20 ? 0.055 : s.t < 45 ? 0.025 : 0.015, "T+\(s.t) s")
            XCTAssertEqual(continuity, 1, accuracy: 0.15, "T+\(s.t) s")
            checked += 1
        }
        XCTAssertEqual(checked, 4)
    }

    /// The same column at 1000× warp (frames 16.7 s apart) and rebuilt at
    /// T+75 s as from frames at 2 Hz: the nodes' count within 3 % (each
    /// node's step follows its hand-over's jet, the model's off the frames)
    /// and the
    /// extinction laid in each 2 km of height within 8 % (where the frames
    /// take the live hand-over the others take the model's, within 6 %).
    func testWarpAndRebuildLayTheSameColumn() throws {
        let fine = try XCTUnwrap(Self.fine.first { $0.t == 75 })
        let warped = Self.open()
        Self.fly(warped, to: 75, step: 1_000.0 / 60)
        let rebuilt = LaunchEffectsTests.Run(warped.sim, warped.camera)
        rebuilt.frame()
        let want = Self.bands(fine.framed, now: fine.now)
        for (label, nodes) in [("1000× warp", warped.effects.trail.chain.nodes), ("rebuilt", rebuilt.effects.trail.chain.nodes)] {
            XCTAssertEqual(Double(nodes.count), Double(fine.framed.count), accuracy: 0.03 * Double(fine.framed.count), label)
            let got = Self.bands(nodes, now: fine.now)
            for (band, w) in want where w > 0.05 * (want.values.max() ?? 0) {
                XCTAssertEqual(got[band] ?? 0, w, accuracy: 0.08 * w, "\(label), \(2 * band)-\(2 * band + 2) km")
            }
            print("TrailChainTests: \(label): \(nodes.count) nodes against \(fine.framed.count)")
        }
    }

    /// Far from the camera runs of nodes are drawn as one (`TrailChain.lod`):
    /// a straight line of 1,200 nodes 25 m apart (σ 15 m along, 40 and
    /// 30 m across), 100 m to 30 km long:
    /// - from a camera beside its start looking down it, it is drawn in a
    ///   tenth as many media, the nearest as nodes; every merged run keeps
    ///   its extinction, albedo and asymmetry; a ray down the line within
    ///   a few degrees of its axis crosses at most 40 boxes, against
    ///   hundreds of nodes: four runs a doubling of the distance (8.5
    ///   doublings from 100 m to 30 km; the plan's estimate of 25 took
    ///   fewer), and the nearest nodes;
    /// - seen side-on from 30 km, its runs are at most about two of its
    ///   widths long, and its depth along it is the nodes' within 3 % up to
    ///   two runs from its ends;
    /// - the runs are aligned on the serials: dropping the first node
    ///   changes no run but the first's.
    func testFarNodesMergeAsOneLine() throws {
        var items: [(serial: Int, drawn: TrailChain.Drawn)] = []
        func mass(_ g: GaussianMedium) -> Double { g.peakExtinction * pow(2 * Double.pi, 1.5) * g.sigma.x * g.sigma.y * g.sigma.z }
        var line = 0.0
        for k in 0..<1_200 {
            let g = GaussianMedium(centre: Vec3(100 + 25 * Double(k), 0, 0), axisU: .unitX, axisV: .unitY,
                                   sigma: Vec3(15, 40, 30), peakExtinction: 2e-3, albedo: Spectrum3(repeating: 0.6),
                                   asymmetry: 0.35)
            line = mass(g) / 25 / (2 * Double.pi * 40 * 30)
            items.append((k + 7, TrailChain.Drawn(medium: g, linePeak: line)))
        }
        let before = items.reduce(0) { $0 + mass($1.drawn.medium) }, nodes = items.map(\.drawn.medium)
        // Down the line.
        let down = Vec3(0, -50, 0), drawn = TrailChain.lod(items, camera: down), merged = drawn.map(\.medium)
        for d in drawn { XCTAssertEqual(d.linePeak, line, accuracy: 1e-9 * line, "a uniform line's line, merged or not") }
        XCTAssertEqual(merged.reduce(0) { $0 + mass($1) }, before, accuracy: 1e-9 * before)
        XCTAssertLessThan(merged.count, items.count / 10)
        XCTAssertEqual(merged.first?.sigma.x, 15, "near the camera, the nodes themselves")
        for g in merged {
            XCTAssertEqual(g.albedo.g, 0.6, accuracy: 1e-12)
            XCTAssertEqual(g.asymmetry, 0.35, accuracy: 1e-12)
        }
        for angle in [0.5, 1.0, 2.0] {
            let d = Vec3(cos(angle * .pi / 180), sin(angle * .pi / 180), 0)
            let crossed = merged.filter { $0.box(origin: down, direction: d) != nil }.count
            print("TrailChainTests: a ray \(angle)° off the line crosses \(crossed) of \(merged.count) boxes (\(nodes.filter { $0.box(origin: down, direction: d) != nil }.count) nodes)")
            XCTAssertLessThanOrEqual(crossed, 40)
        }
        // Side-on.
        let side = Vec3(15_000, -30_000, 0), across = TrailChain.lod(items, camera: side).map(\.medium)
        XCTAssertEqual(across.reduce(0) { $0 + mass($1) }, before, accuracy: 1e-9 * before)
        let longest = across.map(\.sigma.x).max() ?? 0
        XCTAssertLessThan(longest, 0.6 * 2 * 40 / 0.89 + 1, "side-on, runs about two widths long")
        func depth(_ media: [GaussianMedium], _ x: Double) -> Double {
            media.reduce(0) { $0 + $1.depth(origin: Vec3(x, -500, 0), direction: .unitY, from: 0, to: 1_000) }
        }
        var worst = 0.0
        for x in stride(from: 100 + 4 * longest, through: 30_075 - 4 * longest, by: 10) {
            worst = max(worst, abs(depth(across, x) / depth(nodes, x) - 1))
        }
        print(String(format: "TrailChainTests: %d nodes drawn as %d media down the line, %d side-on; side-on within %.4f of the nodes' line",
                     items.count, merged.count, across.count, worst))
        XCTAssertLessThan(worst, 0.03)
        let shifted = TrailChain.lod(Array(items.dropFirst()), camera: down).map(\.medium)
        XCTAssertEqual(Array(shifted.suffix(merged.count - 1)), Array(merged.suffix(merged.count - 1)))
    }

}
