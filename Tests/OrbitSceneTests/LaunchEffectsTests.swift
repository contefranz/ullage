import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// P4's launch effects on the CPU: the ignition against the FER, the pad's
/// exhaust shares, the pre-aged pad at scenario start, a rebuilt history
/// against the frames that lead to it, the umbilicals' and the frost's
/// timing, and the trail drifting on AS-506's sounding.
final class LaunchEffectsTests: XCTestCase {
    static let system = try! SolarSystem.bundled()
    static let viewport = RenderScene.Viewport(width: 640, height: 400)

    // MARK: Helpers

    func open(_ id: String = "as506-pad") throws -> (Simulation, OrbitCamera) {
        let sim = try XCTUnwrap(Scenario.named(id)).build(Self.system)
        var camera = OrbitCamera()
        if let focus = sim.focus {
            camera.target = .vessel(focus.id)
            camera.distance = max(focus.boundingRadius * 3, 30)
        }
        camera.update(sim: sim)
        return (sim, camera)
    }

    /// Moves the simulation on by `seconds` of its own time.
    func advance(_ sim: Simulation, _ seconds: Double) {
        sim.paused = false
        sim.stepBudget = nil
        var left = seconds
        while left > 1e-9 {
            sim.advance(by: min(5, left) / sim.warp)
            left -= min(5, left)
        }
    }

    /// A session with P4's producer, and the frames it ran.
    final class Run {
        let sim: Simulation
        let camera: OrbitCamera
        let extractor = SceneExtractor()
        let effects = LaunchEffects()
        let session: EffectSession
        var realTime = 0.0
        var outputs: [EffectFrameOutput] = []

        init(_ sim: Simulation, _ camera: OrbitCamera) {
            self.sim = sim
            self.camera = camera
            session = EffectSession(producers: [effects])
        }

        @discardableResult
        func frame() -> EffectFrameOutput {
            var camera = self.camera
            camera.update(sim: sim)
            let out = session.frame(extractor.extract(sim: sim, camera: camera, viewport: LaunchEffectsTests.viewport,
                                                      realTime: realTime), settings: ParticleSettings())
            outputs.append(out)
            return out
        }

        func requests(_ material: String, in out: EffectFrameOutput? = nil) -> [EmitRequest] {
            let all = out.map { [$0] } ?? outputs
            return all.flatMap { o in o.requests.filter { o.materials[$0.material].name == material } }
        }

        func count(_ material: String) -> Int { requests(material).reduce(0) { $0 + $1.count } }
    }

    /// Runs frames every `step` s of simulation time to `until` s from now.
    func fly(_ run: Run, step: Double, for seconds: Double, test: LaunchEffectsTests) {
        var t = 0.0
        while t < seconds - 1e-9 {
            let h = min(step, seconds - t)
            test.advance(run.sim, h)
            run.realTime += h
            t += h
            run.frame()
        }
    }

    // MARK: The ignition

    /// The five F-1s' flow from the thrust buildup to first motion is FER
    /// Table 20-9's 39,307 kg (H), at the flow AS-506's engines have at
    /// first motion; the buildup starts at T−5.3 s and is complete before
    /// T+0.3 s.
    func testIgnitionBurnsTheFERsBuildup() throws {
        let v = VesselLibrary.saturnV()
        let engines = v.parts.flatMap(\.thrusters).filter { $0.name.hasPrefix("S-IC engine") }
        XCTAssertEqual(engines.count, 5)
        let flows = engines.map(\.currentRating.massFlow)
        let fm = LC39A.Countdown.apollo11.firstMotion
        XCTAssertEqual(fm, 0.30, accuracy: 1e-6)
        var mass = 0.0
        for (i, flow) in flows.enumerated() {
            // Each engine's own integral, numerically.
            var m = 0.0, t = PadIgnition.thrustBuildup - 1
            let h = 1e-3
            while t < fm {
                m += flow * PadIgnition.engineFraction(i, rangeTime: t + h / 2) * h
                t += h
            }
            mass += m
        }
        XCTAssertEqual(mass, 39_307, accuracy: 39_307 * 0.01, "FER Table 20-9's thrust buildup")
        let mean = flows.reduce(0, +) / 5
        XCTAssertEqual(PadIgnition.integral(from: PadIgnition.thrustBuildup, to: fm) * 5 * mean, mass,
                       accuracy: mass * 1e-3, "the analytic integral")
        XCTAssertEqual(PadIgnition.thrustFraction(rangeTime: PadIgnition.thrustBuildup - 1e-6), 0)
        XCTAssertEqual(PadIgnition.thrustFraction(rangeTime: fm), 1, "full flow by first motion")
        XCTAssertEqual(PadIgnition.thrustFraction(rangeTime: PadIgnition.thrustBuildup + 0.2), 0.2 / PadIgnition.rampTime / 5,
                       accuracy: 1e-12, "the centre engine first (1-2-2)")
    }

    /// Down the opening while the vehicle stands on the pad; onto the deck
    /// as the envelope outgrows it; faded out by 100-200 m of climb.
    func testPadExhaustShares() {
        let pad = PadExhaust.shares(exitHeight: PadExhaust.exitHeightOnPad)
        XCTAssertEqual(pad.trench, 1, accuracy: 1e-12)
        XCTAssertEqual(pad.deck, 0, accuracy: 1e-12)
        var last = pad
        for climb in stride(from: 5.0, through: 500, by: 5) {
            let s = PadExhaust.shares(exitHeight: PadExhaust.exitHeightOnPad + climb)
            XCTAssertLessThanOrEqual(s.total, last.total + 1e-12, "fades with climb")
            XCTAssertLessThanOrEqual(s.trench, last.trench + 1e-12)
            XCTAssert((0...1).contains(s.trench) && (0...1).contains(s.deck))
            last = s
        }
        XCTAssertGreaterThan(PadExhaust.shares(exitHeight: 30).deck, 0.2, "the deck takes a share at 30 m")
        XCTAssertLessThan(PadExhaust.shares(exitHeight: 100).total, 0.3)
        XCTAssertLessThan(PadExhaust.shares(exitHeight: 200).total, 0.06)
        XCTAssertEqual(PadExhaust.shares(exitHeight: 500).total, 0)
        XCTAssertEqual(PadExhaust.trenchExits.map(\.direction.x), [1, -1], "north and south")
    }

    // MARK: Pre-ageing and rebuilt histories

    /// AS-506's pad opens paused at first motion with the exhaust and steam
    /// of the thrust buildup already out of the trench, at their true ages
    /// (up to 5.6 s), as many as the rates give; nothing more while paused.
    func testPadOpensPreAged() throws {
        let (sim, camera) = try open()
        let run = Run(sim, camera)
        let out = run.frame()
        let exhaust = run.requests("p4 pad exhaust", in: out)
        XCTAssertFalse(exhaust.isEmpty)
        // The oldest puff: from the buildup's first second (5.6 s before
        // first motion), when the centre engine's rising flow gives the first.
        let oldest = exhaust.map(\.ages.upperBound).max()!
        let span = LC39A.Countdown.apollo11.firstMotion - PadIgnition.thrustBuildup
        XCTAssertLessThanOrEqual(oldest, span + 1e-6)
        XCTAssertGreaterThan(oldest, span - 1.2)
        XCTAssertEqual(exhaust.map(\.ages.lowerBound).min()!, 0, accuracy: 1e-6)
        let expected = 2 * PadExhaust.trenchPuffRate * PadIgnition.integral(from: PadIgnition.thrustBuildup,
                                                                           to: LC39A.Countdown.apollo11.firstMotion)
        XCTAssertEqual(Double(exhaust.reduce(0) { $0 + $1.count }), expected, accuracy: 2.5)
        XCTAssertGreaterThan(run.count("p4 deluge steam"), 20)
        XCTAssertGreaterThan(run.count("p4 cold vapour"), 50, "the LOX tank's fog and the umbilicals' trickle")
        XCTAssertGreaterThan(run.count("p4 ice slab") + run.count("p4 ice flake"), 0, "ice shaken off at ignition")
        XCTAssertEqual(run.count("p4 trail low"), 0, "no trail on the pad")
        // One anchor at the deck, fixed to the Earth.
        XCTAssertEqual(out.anchors.count, 1)
        let anchor = try XCTUnwrap(out.anchors.first?.frame)
        XCTAssertFalse(anchor.fallsFreely)
        XCTAssertEqual(anchor.altitude, LC39A.placement().height, accuracy: 0.5)
        // Paused: nothing more.
        sim.paused = true
        run.realTime += 1
        XCTAssertTrue(run.frame().requests.isEmpty)
    }

    /// A snapshot's first frame at T+8 s rebuilds the pad's history: about
    /// the puffs the frames to it emitted, at the same ages.
    func testRebuiltHistoryMatchesTheFrames() throws {
        let (sim, camera) = try open()
        let run = Run(sim, camera)
        run.frame()
        fly(run, step: 1.0 / 30, for: 8, test: self)
        let fresh = Run(sim, camera)
        let rebuilt = fresh.frame()
        let span = 8 + LC39A.Countdown.apollo11.firstMotion - PadIgnition.thrustBuildup - 0.3
        for name in ["p4 pad exhaust", "p4 deluge steam"] {
            let framed = run.count(name), again = fresh.count(name)
            XCTAssertEqual(Double(again), Double(framed), accuracy: max(4, 0.06 * Double(framed)), name)
            let oldest = fresh.requests(name, in: rebuilt).map(\.ages.upperBound).max()!
            XCTAssertLessThanOrEqual(oldest, span + 0.3 + 1e-6, "back to the buildup")
            XCTAssertGreaterThan(oldest, span + 0.3 - 1.5)
            // The ignition's puffs (older than 8 s at the frame) are the same.
            let ignition = Double(run.outputs[0].requests.filter { run.outputs[0].materials[$0.material].name == name }
                .reduce(0) { $0 + $1.count })
            let older = fresh.requests(name, in: rebuilt).reduce(0.0) { sum, r in
                // The part of each slice older than first motion.
                let lo = r.ages.lowerBound, hi = r.ages.upperBound
                return sum + Double(r.count) * max(0, min(1, (hi - 8) / max(hi - lo, 1e-9)))
            }
            XCTAssertEqual(older, ignition, accuracy: max(3, 0.05 * ignition), name)
        }
        // The umbilicals' bursts are in both, once each.
        XCTAssertEqual(run.requests("p4 cold vapour").filter { $0.count == LaunchEffects.umbilicalBurst }.count, 5)
        XCTAssertEqual(fresh.requests("p4 cold vapour").filter { $0.count == LaunchEffects.umbilicalBurst }.count, 5)
    }

    /// Each in-flight umbilical bursts once, in the frame whose interval
    /// holds the liftoff switch (first motion + 0.16 s), at its true age.
    func testUmbilicalBurstsAtTheLiftoffSwitch() throws {
        let (sim, camera) = try open()
        let run = Run(sim, camera)
        run.frame()
        let switchEpoch = LaunchCountdown.epoch(LC39A.Countdown.apollo11.liftoffSwitch, in: .apollo11)
        var bursts: [(epoch: Epoch, request: EmitRequest)] = []
        for _ in 0..<30 {
            advance(sim, 0.1)
            run.realTime += 0.1
            let out = run.frame()
            for r in run.requests("p4 cold vapour", in: out) where r.count == LaunchEffects.umbilicalBurst {
                bursts.append((sim.time, r))
            }
        }
        XCTAssertEqual(bursts.count, LC39A.swingArms.filter(\.inFlight).count)
        for b in bursts {
            XCTAssertGreaterThanOrEqual(b.epoch - switchEpoch, 0)
            XCTAssertLessThan(b.epoch - switchEpoch, 0.1 + 1e-6, "in the frame that holds it")
            XCTAssertEqual(b.request.ages.lowerBound, b.epoch - switchEpoch, accuracy: 1e-6, "at its true age")
        }
    }

    // MARK: Frost

    /// The frost shed from the thrust buildup to CECO is FER Table 20-1's
    /// (H): 295 kg off the S-IC, 204 off the S-II, 90 off the S-IVB; the
    /// buildup takes the burst share (L).
    func testFrostScheduleIsTheFERs() {
        let fm = LC39A.Countdown.apollo11.firstMotion
        let lo = PadIgnition.thrustBuildup - fm
        for (band, mass) in [(FrostShedding.Band.sIC, 295.0), (.sII, 204), (.sIVB, 90)] {
            XCTAssertEqual(LaunchEffects.shed(band, from: lo - 10, to: FrostShedding.cutoffTime + 50, firstMotionRange: fm),
                           mass, accuracy: 1e-6)
            XCTAssertEqual(LaunchEffects.shed(band, from: lo, to: 0, firstMotionRange: fm), mass * FrostShedding.burstShare,
                           accuracy: 1e-9)
            // Intervals add up.
            let a = LaunchEffects.shed(band, from: lo, to: 7, firstMotionRange: fm)
            let b = LaunchEffects.shed(band, from: 7, to: 60, firstMotionRange: fm)
            XCTAssertEqual(a + b, LaunchEffects.shed(band, from: lo, to: 60, firstMotionRange: fm), accuracy: 1e-9)
        }
    }

    /// Over the frames to T+20 s the producer sheds the schedule's mass as
    /// flakes and slabs at its visual densities.
    func testFrostIsShedOnTheSchedule() throws {
        let (sim, camera) = try open()
        let run = Run(sim, camera)
        run.frame()
        fly(run, step: 0.25, for: 20, test: self)
        let fm = LC39A.Countdown.apollo11.firstMotion
        let lo = PadIgnition.thrustBuildup - fm
        var flakes = 0.0, slabs = 0.0
        for zone in Frost.zones {
            let band = try XCTUnwrap(FrostShedding.Band(rawValue: zone.stage.rawValue))
            let share = zone.weightedArea / Frost.weightedArea(zone.stage)
            let m = LaunchEffects.shed(band, from: lo, to: sim.time - LaunchCountdown.epoch(fm, in: .apollo11),
                                       firstMotionRange: fm) * share
            flakes += m * FrostShedding.flakeShare * LaunchEffects.flakesPerKilogram
            slabs += m * (1 - FrostShedding.flakeShare) * LaunchEffects.slabsPerKilogram
        }
        // Each source's carry may hold back less than a particle.
        XCTAssertEqual(Double(run.count("p4 ice flake")), flakes, accuracy: 8)
        XCTAssertEqual(Double(run.count("p4 ice slab")), slabs, accuracy: 8)
        XCTAssertGreaterThan(flakes, 1_000)
    }

    // MARK: The trail

    /// The trail is laid from the deck up while the S-IC fires below 40 km.
    /// A puff laid at about 10 km drifts on the launch day's wind there
    /// (AS-506's sounding, datasheet §11): advanced two minutes by P3's
    /// physics in the pad's anchor and air, it moves with the sounding's
    /// wind at its height, within 5 % in speed and 3° in direction; one
    /// laid lower drifts differently (the shear).
    func testTrailDriftsOnTheSoundingWind() throws {
        let (sim, camera) = try open()
        let run = Run(sim, camera)
        run.frame()
        fly(run, step: 0.5, for: 135, test: self)
        let earth = try XCTUnwrap(sim.system.bodies.first { $0.id == 399 })
        let sounding = try XCTUnwrap(sim.atmosphere(of: earth))
        let materials = try XCTUnwrap(run.effects.materials)
        let table = run.session.materials
        var laid: [(request: EmitRequest, frame: AnchorFrame, air: AirProfile, altitude: Double)] = []
        for o in run.outputs {
            for r in o.requests where materials.trail.contains(r.material) {
                let a = try XCTUnwrap(o.anchors.first { $0.id == r.anchor }?.frame)
                let air = try XCTUnwrap(a.airProfile.map { o.airProfiles[$0] })
                laid.append((r, a, air, a.altitude(of: r.origin)))
            }
        }
        XCTAssertGreaterThan(laid.count, 100)
        let highest = laid.map(\.altitude).max()!
        XCTAssertLessThan(highest, ExhaustTrail.ceiling + 1_000, "nothing laid above 40 km")
        XCTAssertGreaterThan(highest, 38_000, "laid to the ceiling")
        XCTAssertGreaterThan(laid.map(\.altitude).min()!, LC39A.placement().height, "from the deck up")
        XCTAssertGreaterThan(run.effects.trail.laid, 1_000)

        func drift(near h: Double) throws -> (moved: Vec3, wind: Vec3, frame: AnchorFrame) {
            let l = try XCTUnwrap(laid.min { abs($0.altitude - h) < abs($1.altitude - h) })
            let p = EmitSampler.sample(l.request, index: 0)
            let m = table[l.request.material]
            let h = l.frame.altitude(of: p.position)
            var s = ParticlePhysics.State(position: p.position, velocity: p.velocity, radius: p.radius,
                                          temperature: l.air.sample(altitude: h).temperature)
            // Age it to two minutes, in steps, in the anchor's air.
            let start = s.position
            for _ in 0..<120 {
                s = ParticlePhysics.advance(s, material: m.physics, environment: l.frame.environment, dt: 1) {
                    l.frame.air(at: $0, profile: l.air)
                }
            }
            let w = sounding.wind(altitude: h), a = l.air.sample(altitude: h)
            let profile = l.frame.east * a.windEast + l.frame.north * a.windNorth
            let flat = (s.position - start) - l.frame.up * (s.position - start).dot(l.frame.up)
            // Within 3 %: a piece of path (up to 100 m, some 70 m of height
            // here) gives its puffs one velocity, the wind at its middle.
            XCTAssertEqual((flat * (1.0 / 120) - profile).length, 0, accuracy: 0.03 * profile.length,
                           "with the particles' air at \(Int(h)) m")
            print(String(format: "LaunchEffectsTests: trail puff at %.0f m: drift %.2f m/s, sounding %.2f m/s, profile %.2f m/s",
                         h, (s.position - start).length / 120, (w.east * w.east + w.north * w.north).squareRoot(),
                         { let a = l.air.sample(altitude: h); return (a.windEast * a.windEast + a.windNorth * a.windNorth).squareRoot() }()))
            return (s.position - start, l.frame.east * w.east + l.frame.north * w.north, l.frame)
        }
        let high = try drift(near: 10_000)
        let up = high.frame.up
        let horizontal = high.moved - up * high.moved.dot(up)
        XCTAssertGreaterThan(high.wind.length, 5, "the day had wind at 10 km")
        XCTAssertEqual(horizontal.length / 120, high.wind.length, accuracy: 0.08 * high.wind.length)
        let angle = acos(min(1, horizontal.normalized.dot(high.wind.normalized))) * 180 / Double.pi
        XCTAssertLessThan(angle, 4)
        XCTAssertLessThan(abs(high.moved.dot(up)), 0.1 * horizontal.length, "it stays at its height")
        let low = try drift(near: 2_000)
        XCTAssertGreaterThan((low.moved - high.moved).length, 120 * 2, "the shear between 2 and 10 km")
    }
}
