import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// The live launch sequence in the scene: the pad scenarios open in the
/// terminal count's hold, running; LC-39A's moving elements and P4's effects
/// follow the count (`TerminalCount`), at any time of launch.
final class LaunchSequenceSceneTests: XCTestCase {
    static let system = try! SolarSystem.bundled()
    let viewport = RenderScene.Viewport(width: 320, height: 200)

    func open(_ id: String = "as506-pad") throws -> (Simulation, OrbitCamera) {
        let sim = try XCTUnwrap(Scenario.named(id)).build(Self.system)
        sim.stepBudget = nil
        var camera = OrbitCamera()
        camera.target = .vessel(try XCTUnwrap(sim.focus).id)
        camera.distance = 300
        camera.update(sim: sim)
        return (sim, camera)
    }

    func advance(_ sim: Simulation, to range: Double) {
        let count = sim.terminalCount!
        while count.rangeTime(at: sim.time) < range - 1e-6 {
            sim.advance(by: min(0.5, range - count.rangeTime(at: sim.time)))
        }
    }

    func angle(_ name: String, _ site: RenderScene.Site, at epoch: Epoch) -> Double {
        let c = site.countdown(at: epoch)
        return LC39A.elements.first { $0.name == name }!.angle(at: c.rangeTime(at: epoch), c) * 180 / .pi
    }

    // Every Saturn V pad scenario opens running, holding at T−35 s with the
    // F-1s off, and no scenario opens paused; Apollo 7's deorbit neither.
    func testPadScenariosOpenInTheHold() throws {
        for s in Scenario.all {
            let sim = s.build(Self.system)
            XCTAssertFalse(sim.paused, s.id)
            guard let count = sim.terminalCount else { continue }
            XCTAssertTrue(count.isHolding, s.id)
            XCTAssertEqual(count.rangeTime(at: sim.time), Scenario.padHold, s.id)
            XCTAssertTrue(sim.focus!.thrusters.allSatisfy { !$0.isDelivering }, s.id)
            if let zero = s.missionClockZero { XCTAssertEqual(count.plannedRangeZero, zero, s.id) }
        }
        XCTAssertEqual(Set(Scenario.all.compactMap { s in s.build(Self.system).terminalCount.map { _ in s.id } }),
                       ["as506-pad", "apollo8-pad", "as506-earth-orbit-return", "as506-apollo13", "as506-sic-engine1-out"])
    }

    // LC-39A stands in the count: while it holds, range time stands at
    // T−35 s however long it holds, the arms in place; resumed 100 s late,
    // the arms move on the count's own T−0: arm 1 from its command at T−30 s
    // (withdrawn 5.06 s, at its safe angle 9.9 s on), arm 2 from T−16.2 s, the
    // hold-down links at the release, the in-flight arms and tail service
    // masts at the liftoff switches the count found.
    func testSiteFollowsTheCount() throws {
        let (sim, camera) = try open()
        let extractor = SceneExtractor()
        let count = try XCTUnwrap(sim.terminalCount)
        func site() -> RenderScene.Site {
            extractor.extract(sim: sim, camera: camera, viewport: viewport, realTime: 0).sites.first { $0.name == "LC-39A" }!
        }
        sim.advance(by: 100)
        XCTAssertEqual(site().countdown(at: sim.time).rangeTime(at: sim.time), -35, accuracy: 1e-6)
        XCTAssertEqual(angle("Swing arm 1", site(), at: sim.time), 0)
        sim.stage(sim.focus!)
        XCTAssertEqual(count.rangeZero! - VesselLibrary.apollo11RangeZero, 100, accuracy: 1e-6, "100 s late")
        advance(sim, to: -27)
        XCTAssertEqual(angle("Swing arm 1", site(), at: sim.time), 0, "withdrawing")
        advance(sim, to: -22)
        let midway = angle("Swing arm 1", site(), at: sim.time)
        XCTAssert((10...80).contains(midway), "arm 1 swinging: \(midway)°")
        advance(sim, to: -19)
        XCTAssertEqual(angle("Swing arm 1", site(), at: sim.time), 90, accuracy: 1e-9)
        XCTAssertEqual(angle("Swing arm 2", site(), at: sim.time), 0)
        advance(sim, to: -8)
        XCTAssertEqual(angle("Swing arm 2", site(), at: sim.time), 90, accuracy: 1e-9)
        XCTAssertEqual(angle("Hold-down arm 1 link", site(), at: sim.time), 0)
        XCTAssertEqual(angle("Swing arm 4", site(), at: sim.time), 0)
        advance(sim, to: 1)
        let release = try XCTUnwrap(count.released), switches = try XCTUnwrap(count.liftoffSwitch)
        XCTAssertEqual(release - count.rangeZero!, 0.30, accuracy: 1e-6)
        XCTAssertEqual(angle("Hold-down arm 1 link", site(), at: sim.time), 90, accuracy: 1e-9)
        let c = site().countdown(at: sim.time)
        XCTAssertEqual(c.liftoffSwitch, switches - count.rangeZero!, accuracy: 1e-9)
        XCTAssertEqual(c.liftoffSwitch, 0.5, accuracy: 0.03, "0.2 s after the release, the controlled release")
        let arm4 = angle("Swing arm 4", site(), at: sim.time)
        XCTAssert(arm4 > 0 && arm4 < 90, "arm 4 retracting: \(arm4)°")
        advance(sim, to: 12)
        XCTAssertEqual(angle("Swing arm 8", site(), at: sim.time), 90, accuracy: 1e-9)
    }

    // P4's effects run on the count: the LOX tank's fog while it holds; the
    // gas generators' smoke from engine 5's start command at T−6.4 s; the
    // TEA-TEB flash once at each engine's ignition, 1-2-2; the trench's jets
    // from the first ignition at T−3.05 s, as many as the engines' thrust in
    // the core gives (none while the count holds).
    func testEffectsFollowTheCount() throws {
        let (sim, camera) = try open()
        let run = LaunchEffectsTests.Run(sim, camera)
        run.frame()
        for _ in 0..<20 { sim.advance(by: 0.1); run.realTime += 0.1; run.frame() }
        XCTAssertGreaterThan(run.count("p4 cold vapour"), 20, "the fog while it holds")
        XCTAssertEqual(run.count("p4 pad exhaust") + run.count("p4 start smoke"), 0)
        sim.stage(sim.focus!)
        let zero = try XCTUnwrap(sim.terminalCount?.rangeZero)
        var flashes: [Double] = [], smokeFrom: Double?, jetsFrom: Double?
        while sim.time - zero < 1 {
            sim.advance(by: 1.0 / 30)
            run.realTime += 1.0 / 30
            let out = run.frame()
            let t = sim.time - zero
            for r in run.requests("p4 ignition flash", in: out) { flashes.append(t - r.ages.lowerBound) }
            if smokeFrom == nil, run.count("p4 start smoke") > 0 { smokeFrom = t }
            if jetsFrom == nil, run.count("p4 pad exhaust") > 0 { jetsFrom = t }
        }
        XCTAssertEqual(flashes.count, 5, "one flash per engine")
        let ignitions = [-3.05, -2.75, -2.75, -2.65, -2.55]
        for (f, i) in zip(flashes.sorted(), ignitions) { XCTAssertEqual(f, i, accuracy: 1e-3) }
        // The first whole particle: the smoke's at its rate, the jets' as the
        // thrust rises from nothing.
        XCTAssertEqual(try XCTUnwrap(smokeFrom), -6.4, accuracy: 0.25)
        XCTAssertEqual(try XCTUnwrap(jetsFrom), -3.05, accuracy: 0.35)
        XCTAssertGreaterThan(try XCTUnwrap(jetsFrom), -3.05)
        XCTAssertGreaterThan(run.count("p4 ground cloud"), 10)
    }

    // No emission repeats itself: over the count, the start and the first
    // 20 s of flight every request of P4's has its own seed, and the jets'
    // and clouds' counts carry their fractions, so neither the particles nor
    // their noise fall into a period.
    func testEmissionNeverRepeats() throws {
        let (sim, camera) = try open()
        sim.stage(sim.focus!)
        let run = LaunchEffectsTests.Run(sim, camera)
        run.frame()
        while sim.terminalCount!.rangeTime(at: sim.time) < 20 {
            sim.advance(by: 1.0 / 20)
            run.realTime += 1.0 / 20
            run.frame()
        }
        let requests = run.outputs.flatMap(\.requests)
        XCTAssertGreaterThan(requests.count, 1_000)
        XCTAssertEqual(Set(requests.map(\.seed)).count, requests.count, "one seed per request")
        print(String(format: "optical depths: jets %.0f, clouds %.0f, start smoke %.0f; cloud albedo %.2f",
                     LaunchMaterials.jetOpticalDepth, LaunchMaterials.cloudOpticalDepth,
                     LaunchMaterials.startSmokeOpticalDepth, LaunchMaterials.cloudAlbedo))
    }

    // The scenario script's `met:` resumes a count holding short of it, so
    // shots and their goldens take a pad scenario's T−0 at the historic
    // range zero; `count` resumes it alone, and so do `ev:`, `liftoff` and
    // `t<n>`, whose waits never end while it holds; `wait:` leaves it holding.
    func testScriptResumesTheCount() throws {
        let (sim, _) = try open()
        try ScenarioScript(["met:-10"]).run(on: sim, missionClockZero: nil)
        XCTAssertEqual(sim.terminalCount?.rangeZero, VesselLibrary.apollo11RangeZero)
        XCTAssertEqual(sim.time - VesselLibrary.apollo11RangeZero, -10, accuracy: 1e-6)
        let (other, _) = try open()
        try ScenarioScript(["count", "wait:5"]).run(on: other, missionClockZero: nil)
        XCTAssertEqual(other.terminalCount!.rangeTime(at: other.time), -30, accuracy: 1e-6)
        let (held, _) = try open()
        try ScenarioScript(["wait:5"]).run(on: held, missionClockZero: nil)
        XCTAssertTrue(held.terminalCount!.isHolding)
        for script in [["liftoff"], ["ev:ignition sequence start"], ["t1"]] {
            let (pad, _) = try open()
            var s = try ScenarioScript(script)
            s.limit = 120
            try s.run(on: pad, missionClockZero: nil)
            XCTAssertEqual(pad.terminalCount?.rangeZero, VesselLibrary.apollo11RangeZero, "\(script)")
        }
    }

    /// Frames every `step` s of simulation time from now to range time `to`.
    func fly(_ run: LaunchEffectsTests.Run, step: Double, to range: Double) {
        let count = run.sim.terminalCount!
        while count.rangeTime(at: run.sim.time) < range - 1e-9 {
            run.sim.advance(by: step / run.sim.warp)
            run.realTime += step / run.sim.warp
            run.frame()
        }
    }

    // On the live count, with the controlled release, the liftoff switches
    // close about 0.2 s after the release, later than the historic 0.16 s
    // after first motion: each in-flight umbilical bursts once, in the frame
    // whose interval holds the switch the count found (at the end of the
    // step that crossed it), at its true age, and the arms start there.
    func testUmbilicalsBurstOnceAtTheLiveSwitch() throws {
        let (sim, camera) = try open()
        sim.stage(sim.focus!)
        advance(sim, to: -1)
        let run = LaunchEffectsTests.Run(sim, camera)
        run.frame()
        var bursts: [(epoch: Epoch, request: EmitRequest)] = []
        var arm4: [(range: Double, angle: Double)] = []
        let count = try XCTUnwrap(sim.terminalCount)
        while count.rangeTime(at: sim.time) < 1.5 {
            sim.advance(by: 1.0 / 60)
            run.realTime += 1.0 / 60
            let out = run.frame()
            for r in run.requests("p4 cold vapour", in: out) where r.count == LaunchEffects.umbilicalBurst {
                bursts.append((sim.time, r))
            }
            let site = try XCTUnwrap(run.scene?.sites.first { $0.name == "LC-39A" })
            arm4.append((count.rangeTime(at: sim.time), angle("Swing arm 4", site, at: sim.time)))
        }
        let switchEpoch = try XCTUnwrap(count.liftoffSwitch)
        XCTAssertEqual(switchEpoch - count.rangeZero!, 0.5, accuracy: 0.03)
        XCTAssertEqual(bursts.count, LC39A.swingArms.filter(\.inFlight).count, "once each")
        for b in bursts {
            XCTAssertGreaterThanOrEqual(b.epoch - switchEpoch, 0)
            XCTAssertLessThan(b.epoch - switchEpoch, 1.0 / 60 + 1e-6, "in the frame that holds it")
            XCTAssertEqual(b.request.ages.lowerBound, b.epoch - switchEpoch, accuracy: 1e-6, "at its true age")
        }
        let switchRange = switchEpoch - count.rangeZero!
        for a in arm4 where a.range < switchRange { XCTAssertEqual(a.angle, 0, "arm 4 connected at \(a.range)") }
        XCTAssertGreaterThan(arm4.last!.angle, 0)
    }

    // An engine failed in the hold never starts: no gas generator smoke and
    // no ignition flash from it (four of each kind, not five), the launch
    // scrubs at T−0, and the pad's effects end the clouds' window after the
    // cutoff: the ground cloud is integrated no further, and a reset after a
    // long scrubbed hold rebuilds nothing. The stack stands loaded, so it
    // vents on: the LOX tank's fog and the umbilicals' trickle, then and
    // after the reset.
    func testAScrubbedLaunchsEffectsEnd() throws {
        func smoke(failing: Bool) throws -> (run: LaunchEffectsTests.Run, smoke: Int) {
            let (sim, camera) = try open()
            if failing { sim.focus!.thrusters.first { $0.name == "S-IC engine 2" }!.fail() }
            sim.stage(sim.focus!)
            advance(sim, to: -10)
            let run = LaunchEffectsTests.Run(sim, camera)
            run.frame()
            fly(run, step: 1.0 / 30, to: 1)
            return (run, run.count("p4 start smoke"))
        }
        let nominal = try smoke(failing: false), scrubbed = try smoke(failing: true)
        XCTAssertEqual(Double(scrubbed.smoke) / Double(nominal.smoke), 0.8, accuracy: 0.05, "four gas generators")
        let run = scrubbed.run, sim = run.sim, count = try XCTUnwrap(sim.terminalCount)
        XCTAssertEqual(run.requests("p4 ignition flash").count, 4, "no flash from engine 2")
        XCTAssertEqual(nominal.run.requests("p4 ignition flash").count, 5)
        let cutoff = try XCTUnwrap(count.scrub?.time)
        XCTAssertNil(count.released)
        let end = cutoff + LaunchEffects.cloudWindow + ParticleLifetimes.groundCloud.upperBound
        fly(run, step: 5, to: end - count.rangeZero! + 30)
        let cloud = try XCTUnwrap(run.effects.cloud)
        XCTAssertLessThan(cloud.time - end, 5.1, "integrated no further than the window")
        XCTAssertTrue(run.requests("p4 ground cloud", in: run.outputs.last!).isEmpty)
        XCTAssertFalse(run.requests("p4 cold vapour", in: run.outputs.last!).isEmpty, "it vents on")
        sim.advance(by: 3_600)
        let fresh = LaunchEffectsTests.Run(sim, scrubbed.run.camera)
        fresh.frame()
        XCTAssertNil(fresh.effects.cloud, "nothing rebuilt an hour after the window")
        XCTAssertEqual(fresh.count("p4 ground cloud"), 0)
        XCTAssertGreaterThan(fresh.count("p4 cold vapour"), 0, "it vents on an hour later")
    }

    // A stack released but left standing on the rods (here two F-1s lost
    // after commit, the three left lifting it only after about 140 s) keeps
    // the pad's windows open while an F-1 burns there, its first motion not
    // found: the trench jets are still fed 100 s after the release. Once the
    // last has stopped (here the three lost in the sit) the windows run from
    // there: the ground cloud is integrated no further than its window. The
    // stack still vents.
    func testAStackOnTheRodsKeepsItsWindowsWhileAnF1Burns() throws {
        let (sim, camera) = try open()
        let v = try XCTUnwrap(sim.focus)
        func fail(_ n: Int) { v.thrusters.first { $0.name == "S-IC engine \(n)" }!.fail() }
        sim.stage(v)
        advance(sim, to: 0.1)
        let count = try XCTUnwrap(sim.terminalCount)
        XCTAssertNotNil(count.committed)
        fail(1)
        fail(2)
        advance(sim, to: 1)
        let release = try XCTUnwrap(count.released)
        let run = LaunchEffectsTests.Run(sim, camera)
        run.frame()
        fly(run, step: 5, to: release - count.rangeZero! + 100)
        XCTAssertNotNil(v.landed)
        XCTAssertNil(count.firstMotion)
        XCTAssertEqual(count.plan.starts.indices.filter { count.record.fraction($0, at: sim.time) > 0 }.count, 3)
        XCTAssertFalse(run.requests("p4 pad exhaust", in: run.outputs.last!).isEmpty, "the trench fed")
        XCTAssertFalse(run.requests("p4 ground cloud", in: run.outputs.last!).isEmpty)
        let fresh = LaunchEffectsTests.Run(sim, camera)
        XCTAssertFalse(fresh.requests("p4 pad exhaust", in: fresh.frame()).filter { $0.ages.lowerBound < 1 }.isEmpty,
                       "and on a rebuilt history")
        for n in 3...5 { fail(n) }
        let last = sim.time
        let end = last + LaunchEffects.cloudWindow + ParticleLifetimes.groundCloud.upperBound
        fly(run, step: 5, to: end - count.rangeZero! + 30)
        XCTAssertNotNil(v.landed)
        XCTAssertNil(count.firstMotion)
        let cloud = try XCTUnwrap(run.effects.cloud)
        XCTAssertLessThan(cloud.time - end, 5.1, "integrated no further than the window")
        XCTAssertTrue(run.requests("p4 ground cloud", in: run.outputs.last!).isEmpty)
        XCTAssertTrue(run.requests("p4 pad exhaust", in: run.outputs.last!).isEmpty)
        XCTAssertFalse(run.requests("p4 cold vapour", in: run.outputs.last!).isEmpty, "it vents on")
    }

    // An F-1 lost after commit and before the release: the journal has no
    // cutoff for it (only the release put the F-1s under the throttle), so
    // `engineCutoffs` reckons it −∞ from the count's record, and the
    // trail's modelled hand-over (the paths no frame saw) carries the four
    // that burn, as the live emitters do, not five: its cross-section about
    // 0.8 of five's.
    func testAnF1LostBeforeTheReleaseLeavesTheTrailsModel() throws {
        let (sim, camera) = try open()
        let v = try XCTUnwrap(sim.focus)
        sim.stage(v)
        advance(sim, to: 0.1)
        let count = try XCTUnwrap(sim.terminalCount)
        XCTAssertNotNil(count.committed)
        v.thrusters.first { $0.name == "S-IC engine 1" }!.fail()
        advance(sim, to: 1)
        XCTAssertNotNil(count.released)
        let reckoned = LaunchEffects.engineCutoffs(journal: [:], record: count.record)
        XCTAssertEqual(Set(reckoned.keys), ["S-IC engine 1"])
        XCTAssertEqual(reckoned["S-IC engine 1"]?.tdb, -.infinity)
        XCTAssertEqual(LaunchEffects.engineCutoffs(journal: [:], record: nil), [:])
        let run = LaunchEffectsTests.Run(sim, camera)
        run.frame()
        fly(run, step: 0.5, to: 4)
        let scene = try XCTUnwrap(run.scene)
        let site = try XCTUnwrap(scene.sites.first { $0.name == LC39A.placement().name })
        let vehicle = try XCTUnwrap(LaunchEffects.vehicle(in: scene, site: site))
        let own = scene.emitters.filter { $0.name.hasPrefix("S-IC engine") }
        XCTAssertEqual(own.filter { !$0.isJet && $0.flowFraction > 0 }.count, 4)
        let cutoffs = LaunchEffects.engineCutoffs(journal: run.effects.cutoffs, record: count.record)
        XCTAssertEqual(cutoffs["S-IC engine 1"]?.tdb, -.infinity)
        let air = try XCTUnwrap(own.first).ambient, now = sim.time
        func model(_ flow: @escaping (String) -> Double) throws -> PlumeAirflow.Column {
            try XCTUnwrap(ExhaustTrail.modelColumn(vehicle.vessel, flow: flow, density: air.density,
                                                   temperature: air.temperature, pressure: air.pressure,
                                                   airspeed: vehicle.airspeed))
        }
        let four = try model { ExhaustTrail.engineFlow($0, at: now, cutoffs: cutoffs) }
        let five = try model { _ in 1 }
        print(String(format: "LaunchSequenceSceneTests: an F-1 lost before the release: the model's cross-section %.3f of five's",
                     four.crossSection / five.crossSection))
        XCTAssertEqual(four.crossSection / five.crossSection, 0.8, accuracy: 0.04)
        if let live = PlumeAirflow.trailHandover(own)?.column {
            XCTAssertEqual(four.crossSection, live.crossSection, accuracy: 0.05 * live.crossSection, "the live four")
            XCTAssertEqual(four.depth, live.depth, accuracy: 0.05 * live.depth, "the live four")
        } else {
            XCTFail("no live hand-over on the rods")
        }
    }

    // A stack on the rods (one F-1 lost after commit) whose F-1s the
    // throttle shuts down after the release (the pilot's X, a script's
    // `throttle:0`) feeds the trench and the clouds only through their
    // tail-off: after the release the pad's flow is the emitters', on a
    // rebuilt history the journal's cutoffs, not the count's record. The
    // count records the cut, so the windows close from it.
    func testAThrottleCutOnTheRodsStopsThePadsFlow() throws {
        let (sim, camera) = try open()
        let v = try XCTUnwrap(sim.focus)
        sim.stage(v)
        advance(sim, to: 0.1)
        let count = try XCTUnwrap(sim.terminalCount)
        v.thrusters.first { $0.name == "S-IC engine 1" }!.fail()
        advance(sim, to: 1)
        XCTAssertNotNil(count.released)
        let run = LaunchEffectsTests.Run(sim, camera)
        run.frame()
        fly(run, step: 1.0 / 30, to: 4)
        XCTAssertFalse(run.requests("p4 pad exhaust", in: run.outputs.last!).isEmpty)
        let cut = sim.time, zero = try XCTUnwrap(count.rangeZero)
        v.mainThrottle = 0
        func trench(_ c: GroundCloud) -> [GroundCloud.Lobe] {
            c.lobes.filter { if case .trench = $0.kind { true } else { false } }
        }
        fly(run, step: 1.0 / 30, to: cut - zero + 0.3)
        XCTAssertTrue(trench(try XCTUnwrap(run.effects.cloud)).allSatisfy { $0.jet.momentum > 0 }, "the tail-off")
        fly(run, step: 1.0 / 30, to: cut - zero + 2)
        let cloud = try XCTUnwrap(run.effects.cloud)
        XCTAssertEqual(trench(cloud).count, 2)
        XCTAssertTrue(cloud.lobes.allSatisfy { $0.jet.momentum == 0 })
        XCTAssertTrue(run.requests("p4 pad exhaust", in: run.outputs.last!).isEmpty)
        let exhaust = cloud.lobes.map(\.exhaust)
        fly(run, step: 1.0 / 30, to: cut - zero + 3)
        XCTAssertEqual(try XCTUnwrap(run.effects.cloud).lobes.map(\.exhaust), exhaust, "no exhaust after the cut")
        let fresh = LaunchEffectsTests.Run(sim, camera)
        let rebuilt = fresh.frame()
        XCTAssertTrue(try XCTUnwrap(fresh.effects.cloud).lobes.allSatisfy { $0.jet.momentum == 0 })
        let after = sim.time - cut - LaunchEffects.tailOff
        XCTAssertFalse(fresh.requests("p4 pad exhaust", in: rebuilt).isEmpty)
        XCTAssertTrue(fresh.requests("p4 pad exhaust", in: rebuilt).allSatisfy { $0.ages.upperBound > after },
                      "none born after the tail-off")
        XCTAssertTrue(count.plan.starts.indices.allSatisfy { count.record.stop($0) != nil }, "the count's cut")
        let end = cut + LaunchEffects.cloudWindow + ParticleLifetimes.groundCloud.upperBound
        fly(run, step: 5, to: end - zero + 30)
        XCTAssertLessThan(try XCTUnwrap(run.effects.cloud).time - end, 5.1, "integrated no further than the window")
        XCTAssertTrue(run.requests("p4 ground cloud", in: run.outputs.last!).isEmpty)
        XCTAssertFalse(run.requests("p4 cold vapour", in: run.outputs.last!).isEmpty, "it vents on")
    }

    // The clouds' eddies are born moving with their lobe (`sourceVelocity`,
    // nothing added on), and a rebuilt history fills each slice from the
    // lobe as it was then: its eddies the size the frames gave them, not
    // the present cloud's.
    func testCloudEddiesFollowTheirLobesThenAndNow() throws {
        let (sim, camera) = try open()
        sim.stage(sim.focus!)
        advance(sim, to: -10)
        let run = LaunchEffectsTests.Run(sim, camera)
        run.frame()
        fly(run, step: 0.1, to: 15)
        func isBall(_ r: EmitRequest) -> Bool { if case .ball = r.shape { true } else { false } }
        let live = run.requests("p4 ground cloud", in: run.outputs.last!).filter(isBall)
        XCTAssertFalse(live.isEmpty)
        for r in live {
            XCTAssertEqual(r.velocity, .zero)
            XCTAssertGreaterThan(r.sourceVelocity.length, 1)
        }
        let life = ParticleLifetimes.groundCloud
        func survival(_ age: Double) -> Double { min(1, max(0, (life.upperBound - age) / (life.upperBound - life.lowerBound))) }
        // The eddies' mean radius now, by count and survival: the frames'
        // against a rebuild's.
        var framed = (sum: 0.0, n: 0.0)
        for (o, epoch) in zip(run.outputs, run.epochs) {
            for r in run.requests("p4 ground cloud", in: o) where isBall(r) {
                let w = Double(r.count) * survival(sim.time - epoch + 0.5 * (r.ages.lowerBound + r.ages.upperBound))
                framed = (framed.sum + w * 0.5 * (r.radius.lowerBound + r.radius.upperBound), framed.n + w)
            }
        }
        let fresh = LaunchEffectsTests.Run(sim, camera)
        let rebuilt = fresh.frame()
        var again = (sum: 0.0, n: 0.0)
        let balls = fresh.requests("p4 ground cloud", in: rebuilt).filter(isBall)
        for r in balls {
            let w = Double(r.count) * survival(0.5 * (r.ages.lowerBound + r.ages.upperBound))
            again = (again.sum + w * 0.5 * (r.radius.lowerBound + r.radius.upperBound), again.n + w)
        }
        XCTAssertEqual(again.sum / again.n, framed.sum / framed.n, accuracy: 0.1 * framed.sum / framed.n)
        let oldest = try XCTUnwrap(balls.max { $0.ages.lowerBound < $1.ages.lowerBound })
        let youngest = try XCTUnwrap(balls.min { $0.ages.lowerBound < $1.ages.lowerBound })
        XCTAssertLessThan(oldest.radius.upperBound, 0.7 * youngest.radius.upperBound, "the young cloud's eddies")
    }

    // The live count's climb against the first-motion stand's: the rods
    // leave the stack behind by what `LiftoffRise`'s closed form of their
    // stroke says, and start its roll and pitch program that much later,
    // all on one zero point (first motion, T1 = first motion + 0.33 s, range
    // time). A rebuilt history climbs as the count flew.
    func testTheLiveClimbIsTheRebuiltOneWithTheRods() throws {
        func fly(_ id: String) throws -> (rises: [Double], start: Double, firstMotion: Double, t1: Double, zero: Epoch,
                                         release: TerminalCount.ControlledRelease?) {
            let (sim, _) = try open(id)
            let v = try XCTUnwrap(sim.focus), count = try XCTUnwrap(sim.terminalCount)
            if count.isHolding { sim.stage(v) }
            let iu = try XCTUnwrap(v.flightProgram as? SaturnIU)
            let marks = [2.0, 5, 10]
            var rises: [Double?] = marks.map { _ in nil }
            while iu.programStarted == nil {
                sim.advance(by: 0.02)
                guard let fm = count.firstMotion else { continue }
                for (k, t) in marks.enumerated() where rises[k] == nil && sim.time - fm >= t - 1e-9 {
                    rises[k] = count.rise(of: v, snapshot: sim.snapshot)! - (sim.time - fm - t) * v.surfaceVelocity(snapshot: sim.snapshot).length
                }
            }
            let fm = try XCTUnwrap(count.firstMotion), t1 = try XCTUnwrap(iu.timeBases[.t1])
            return (rises.map { $0! }, t1 + iu.programStarted! - fm, fm - count.rangeZero!, t1 - fm, count.rangeZero!,
                    count.plan.controlledRelease)
        }
        let live = try fly("as506-pad"), stand = try fly("as506-first-motion")
        let rods = try XCTUnwrap(live.release)
        XCTAssertNil(stand.release)
        XCTAssertEqual(live.firstMotion, 0.30, accuracy: 1e-6)
        XCTAssertEqual(live.t1, 0.33, accuracy: 1e-6)
        for (k, t) in [2.0, 5, 10].enumerated() {
            let deficit = LiftoffRise.rise(after: t) - LiftoffRise.rise(after: t, release: rods)
            XCTAssertEqual(stand.rises[k] - live.rises[k], deficit, accuracy: 0.05 + 0.05 * deficit, "at FM + \(t) s")
        }
        let model = LiftoffRise.programStart(release: rods) - LiftoffRise.programStart
        XCTAssertEqual(live.start - stand.start, model, accuracy: 0.03)
        XCTAssertEqual(live.start, LiftoffRise.programStart(release: rods), accuracy: 0.15)
        print(String(format: "roll and pitch program: live FM + %.2f s (T1 + %.2f s, range %.2f s); "
                     + "first-motion stand FM + %.2f s (T1 + %.2f s, range %.2f s); LiftoffRise %.2f and %.2f s; "
                     + "the rods' stroke ends FM + %.3f s, %.3f m/s and %.3f m behind",
                     live.start, live.start - live.t1, live.start + live.firstMotion,
                     stand.start, stand.start - stand.t1, stand.start + stand.firstMotion,
                     LiftoffRise.programStart(release: rods), LiftoffRise.programStart,
                     LiftoffRise.stroke(rods).time, LiftoffRise.stroke(rods).speedDeficit,
                     LiftoffRise.stroke(rods).riseDeficit))
    }

    // Above 10× each TEA-TEB flash is held into the frame after it ended, so
    // at 100× (1.7 s a frame at 60 fps) all five show, once each.
    func testIgnitionFlashesShowAtTimeWarp() throws {
        let (sim, camera) = try open()
        sim.stage(sim.focus!)
        advance(sim, to: -12)
        let run = LaunchEffectsTests.Run(sim, camera)
        run.frame()
        sim.warp = 100
        fly(run, step: 100.0 / 60, to: 1)
        XCTAssertEqual(run.requests("p4 ignition flash").count, 5)
    }
}
