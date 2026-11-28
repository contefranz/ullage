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

    /// Opens a scenario; a terminal count holding is resumed at once, so
    /// that its T−0 falls on the launch's historic range zero.
    func open(_ id: String = "as506-first-motion") throws -> (Simulation, OrbitCamera) {
        let sim = try XCTUnwrap(Scenario.named(id)).build(Self.system)
        if let c = sim.terminalCount, c.isHolding { c.resume(at: sim.time, in: sim) }
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
        /// Each output's epoch.
        var epochs: [Epoch] = []
        var scene: RenderScene?

        init(_ sim: Simulation, _ camera: OrbitCamera) {
            self.sim = sim
            self.camera = camera
            session = EffectSession(producers: [effects])
        }

        @discardableResult
        func frame() -> EffectFrameOutput {
            var camera = self.camera
            camera.update(sim: sim)
            let scene = extractor.extract(sim: sim, camera: camera, viewport: LaunchEffectsTests.viewport,
                                          realTime: realTime)
            self.scene = scene
            let out = session.frame(scene, settings: ParticleSettings())
            outputs.append(out)
            epochs.append(sim.time)
            return out
        }

        func requests(_ material: String, in out: EffectFrameOutput? = nil) -> [EmitRequest] {
            let all = out.map { [$0] } ?? outputs
            return all.flatMap { o in o.requests.filter { o.materials[$0.material].name == material } }
        }

        func count(_ material: String) -> Int { requests(material).reduce(0) { $0 + $1.count } }

        enum Kind { case trail }

        /// The trail's requests (every palette material's).
        func requests(_ kind: Kind, in out: EffectFrameOutput? = nil) -> [EmitRequest] {
            let all = out.map { [$0] } ?? outputs
            return all.flatMap { o in o.requests.filter { o.materials[$0.material].name.hasPrefix("p4 trail") } }
        }
    }

    /// The particles of `name` the frames emitted that are still alive now,
    /// each weighted by the chance it outlives its age (lifetimes uniform
    /// in `life`).
    func alive(_ run: Run, _ name: String, life: ClosedRange<Double>) -> Double {
        zip(run.outputs, run.epochs).reduce(0.0) { sum, o in
            let since = run.sim.time - o.1
            return sum + run.requests(name, in: o.0).reduce(0.0) { s, r in
                let age = since + 0.5 * (r.ages.lowerBound + r.ages.upperBound)
                return s + Double(r.count) * min(1, max(0, (life.upperBound - age) / (life.upperBound - life.lowerBound)))
            }
        }
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

    /// FER-506's start as the count plans it (`PadIgnition`, the core's
    /// `TerminalCount.Plan.as506`): the five F-1s' flow from their start
    /// commands to first motion is FER Table 20-9's 39,307 kg (H) at the
    /// flow AS-506's engines have at first motion, 32,563 kg of it with
    /// thrust; the first chamber lights at T−3.05 s, all are at full thrust
    /// by T−1.4 s, 1-2-2.
    func testIgnitionBurnsTheFERsBuildup() throws {
        let v = VesselLibrary.saturnV()
        let engines = v.parts.flatMap(\.thrusters).filter { $0.name.hasPrefix("S-IC engine") }
        XCTAssertEqual(engines.count, 5)
        let flow = engines[0].currentRating.massFlow
        let fm = LC39A.Countdown.apollo11.firstMotion
        XCTAssertEqual(fm, 0.30, accuracy: 1e-6)
        let plan = PadIgnition.plan
        var mass = 0.0, thrusting = 0.0
        for i in plan.starts.indices {
            var t = PadIgnition.firstCommand - 1
            let h = 1e-3
            while t < fm {
                mass += flow * plan.flowFraction(i, rangeTime: t + h / 2) * h
                thrusting += flow * plan.fraction(i, rangeTime: t + h / 2) * h
                t += h
            }
        }
        XCTAssertEqual(mass, 39_307, accuracy: 3, "FER Table 20-9's thrust buildup")
        XCTAssertEqual(thrusting, 32_563, accuracy: 3)
        XCTAssertEqual(PadIgnition.firstCommand, -6.4, accuracy: 1e-12)
        XCTAssertEqual(PadIgnition.thrustBuildup, -3.05, accuracy: 1e-12)
        XCTAssertEqual(PadIgnition.thrustFraction(rangeTime: -3.05 - 1e-6), 0)
        XCTAssertEqual(PadIgnition.thrustFraction(rangeTime: -1.4), 1, accuracy: 1e-12, "full thrust by T−1.4 s")
        XCTAssertEqual(PadIgnition.thrustFraction(rangeTime: -2.85), 0.2 / PadIgnition.rampTime / 5, accuracy: 1e-12,
                       "the centre engine first (1-2-2)")
        XCTAssertEqual(PadIgnition.integral(from: PadIgnition.thrustBuildup, to: fm) * 5 * flow, thrusting, accuracy: 3)
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

    /// The jets' eddies a second out of an exit at range time `t`, as the
    /// producer emits them at full flow on the pad (`GroundCloud`).
    static func jetRate(at t: Double) -> Double {
        let s = GroundCloud.Sources(exhaust: LiftoffRise.flow * PadIgnition.thrustFraction(rangeTime: t),
                                    thrust: LiftoffRise.thrust * PadIgnition.thrustFraction(rangeTime: t),
                                    trench: 1, deck: 0, trenchWater: PadExhaust.trenchWater * GroundCloud.gallon / 60,
                                    deckWater: 0)
        let air = Self.deckAir
        let f = GroundCloud.side(s, density: air.rho, ambient: air.temperature)
        let x = GroundCloud.exitDistance, eddy = LaunchEffects.jetEddy * GroundCloud.jetSpread * x
        return LaunchEffects.jetFill * GroundCloud.jetVolume * f.momentum.squareRoot() * x / (4 / 3 * .pi * pow(eddy, 3))
    }

    static let deckAir: (rho: Double, temperature: Double) = {
        let sim = Simulation(system: system, time: VesselLibrary.apollo11RangeZero)
        VesselLibrary.apollo11OnPad(in: sim)
        let a = AirProfile(sim.atmosphere(of: sim.system.earth)!).sample(altitude: LC39A.placement().height)
        return (a.density, a.temperature)
    }()

    /// AS-506's first-motion stand opens with what the count's start put
    /// out: the trench's jets since the first chamber lit (3.35 s before
    /// first motion), at their true ages, as many as the jets' volume flux
    /// gives; the gas generators' dark smoke since the first start command;
    /// the two clouds' eddies; the LOX tank's fog and the umbilicals'
    /// trickle; ice shaken off. Nothing more while paused.
    func testPadOpensPreAged() throws {
        let (sim, camera) = try open()
        let run = Run(sim, camera)
        let out = run.frame()
        let exhaust = run.requests("p4 pad exhaust", in: out)
        XCTAssertFalse(exhaust.isEmpty)
        let fm = LC39A.Countdown.apollo11.firstMotion
        let oldest = exhaust.map(\.ages.upperBound).max()!
        let span = fm - PadIgnition.thrustBuildup
        XCTAssertLessThanOrEqual(oldest, span + 1e-6)
        XCTAssertGreaterThan(oldest, span - 0.6)
        XCTAssertEqual(exhaust.map(\.ages.lowerBound).min()!, 0, accuracy: 1e-6)
        var expected = 0.0, t = PadIgnition.thrustBuildup
        while t < fm { expected += 2 * Self.jetRate(at: t + 5e-4) * 1e-3; t += 1e-3 }
        XCTAssertEqual(Double(exhaust.reduce(0) { $0 + $1.count }), expected, accuracy: max(3, 0.02 * expected))
        XCTAssertGreaterThan(run.count("p4 start smoke"), 50, "the gas generators' smoke")
        XCTAssertGreaterThan(run.count("p4 ground cloud"), 20, "the jets' clouds")
        XCTAssertGreaterThan(run.count("p4 cold vapour"), 50, "the LOX tank's fog and the umbilicals' trickle")
        XCTAssertGreaterThan(run.count("p4 ice slab") + run.count("p4 ice flake"), 0, "ice shaken off at ignition")
        XCTAssertEqual(run.requests(.trail).count, 0, "no trail on the pad")
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
    /// the jets' eddies the frames to it emitted, and the clouds'; the
    /// umbilicals burst once in both.
    func testRebuiltHistoryMatchesTheFrames() throws {
        let (sim, camera) = try open()
        let run = Run(sim, camera)
        run.frame()
        fly(run, step: 1.0 / 30, for: 8, test: self)
        let fresh = Run(sim, camera)
        let rebuilt = fresh.frame()
        for name in ["p4 pad exhaust", "p4 ground cloud"] {
            // The eddies alive now: the frames' that have not outlived their lives.
            let life = name == "p4 pad exhaust" ? ParticleLifetimes.padExhaust : ParticleLifetimes.groundCloud
            let framed = alive(run, name, life: life)
            let again = fresh.requests(name, in: rebuilt).reduce(0.0) { s, r in
                let age = 0.5 * (r.ages.lowerBound + r.ages.upperBound)
                return s + Double(r.count) * min(1, max(0, (life.upperBound - age) / (life.upperBound - life.lowerBound)))
            }
            XCTAssertEqual(again, framed, accuracy: max(6, 0.1 * framed), name)
            XCTAssertGreaterThan(again, 20, name)
            let oldest = fresh.requests(name, in: rebuilt).map(\.ages.upperBound).max()!
            XCTAssertLessThanOrEqual(oldest, 8 + LC39A.Countdown.apollo11.firstMotion - PadIgnition.firstCommand + 1e-6)
        }
        // The umbilicals' bursts are in both, once each.
        XCTAssertEqual(run.requests("p4 cold vapour").filter { $0.count == LaunchEffects.umbilicalBurst }.count, 5)
        XCTAssertEqual(fresh.requests("p4 cold vapour").filter { $0.count == LaunchEffects.umbilicalBurst }.count, 5)
    }

    /// Each in-flight umbilical bursts once, in the frame whose interval
    /// holds the liftoff switch, at its true age: where the count found the
    /// vehicle's 3/4 in of rise (`TerminalCount.liftoffSwitch`).
    func testUmbilicalBurstsAtTheLiftoffSwitch() throws {
        let (sim, camera) = try open()
        let run = Run(sim, camera)
        run.frame()
        var bursts: [(epoch: Epoch, request: EmitRequest)] = []
        for _ in 0..<30 {
            advance(sim, 0.1)
            run.realTime += 0.1
            let out = run.frame()
            for r in run.requests("p4 cold vapour", in: out) where r.count == LaunchEffects.umbilicalBurst {
                bursts.append((sim.time, r))
            }
        }
        let switchEpoch = try XCTUnwrap(sim.terminalCount?.liftoffSwitch)
        XCTAssertEqual(switchEpoch - VesselLibrary.apollo11FirstMotion, 0.14, accuracy: 0.03,
                       "3/4 in of rise at the model's 1.9 m/s²")
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

    /// The site's axes in the pad's anchor (columns: north, west, up).
    func siteAxes(_ scene: RenderScene) throws -> Mat3 {
        let site = try XCTUnwrap(scene.sites.first { $0.name == "LC-39A" })
        let body = try XCTUnwrap(scene.bodies.first { $0.id == site.bodyID })
        return body.orientation.icrfToBody * site.orientation
    }

    /// The trail's requests in `outputs`, with their anchor frame and air,
    /// the altitude of the middle of the piece they were laid along and its
    /// place in the site frame.
    struct Laid {
        var request: EmitRequest
        var frame: AnchorFrame
        var air: AirProfile
        var altitude: Double
        var site: Vec3
    }

    /// Where a trail request's puffs began, at its mean age: its origin
    /// (where a puff of age 0 would have begun) less the chord's motion.
    static func laidAt(_ r: EmitRequest) -> Vec3 {
        r.origin - r.sourceVelocity * (0.5 * (r.ages.lowerBound + r.ages.upperBound))
    }

    func trail(_ outputs: [EffectFrameOutput], _ run: Run, axes: Mat3) throws -> [Laid] {
        let materials = try XCTUnwrap(run.effects.materials)
        var laid: [Laid] = []
        for o in outputs {
            for r in o.requests where materials.trail.contains(r.material) {
                let a = try XCTUnwrap(o.anchors.first { $0.id == r.anchor }?.frame)
                let air = try XCTUnwrap(a.airProfile.map { o.airProfiles[$0] })
                let p = Self.laidAt(r)
                laid.append(Laid(request: r, frame: a, air: air, altitude: a.altitude(of: p), site: axes.transposed * p))
            }
        }
        return laid
    }

    /// The rebuilt trail against the frames': at each height of `heights`
    /// the count-weighted mean horizontal place of the puffs' origins within
    /// 500 m of it, apart by less than `tolerance` m, the rebuilt one moving
    /// away from the pad as it climbs. Returns the largest gap.
    @discardableResult
    func compareTrails(_ framed: [Laid], _ rebuilt: [Laid], heights: [Double], tolerance: Double,
                       _ label: String) throws -> Double {
        func mean(_ l: [Laid], _ h: Double) -> Vec3? {
            let near = l.filter { abs($0.altitude - h) < 500 }
            guard !near.isEmpty else { return nil }
            let w = near.reduce(0.0) { $0 + Double($1.request.count) }
            return near.reduce(Vec3.zero) { $0 + Vec3($1.site.x, $1.site.y, 0) * Double($1.request.count) } * (1 / w)
        }
        var away = 0.0, worst = 0.0
        for h in heights {
            let f = try XCTUnwrap(mean(framed, h), "\(label): frames at \(Int(h)) m")
            let g = try XCTUnwrap(mean(rebuilt, h), "\(label): rebuilt at \(Int(h)) m")
            print(String(format: "LaunchEffectsTests: %@ trail at %.0f m: frames %.0f m from the pad, rebuilt %.0f m, %.0f m apart",
                         label, h, f.length, g.length, (f - g).length))
            XCTAssertLessThan((f - g).length, tolerance, "\(label) at \(Int(h)) m")
            XCTAssertGreaterThan(g.length, away - 10, "\(label): away from the pad as it climbs, at \(Int(h)) m")
            away = g.length
            worst = max(worst, (f - g).length)
        }
        return worst
    }

    /// One flight, frame by frame at 2 Hz, and fresh sessions rebuilding
    /// the history from it as a snapshot does.
    /// - T+75 s: the rebuilt pad clouds stay at the pad (the vehicle is
    ///   3.5 km downrange); the rebuilt trail lies along the frames' to
    ///   within 100 m at every kilometre of height, moving away from the pad
    ///   as it climbs; the rebuilt frost's last second moves with the vehicle.
    /// - T+135 s: the trail was laid from the deck to 40 km; a puff laid at
    ///   about 10 km drifts on the launch day's wind there (AS-506's
    ///   sounding, datasheet §11): advanced two minutes by P3's physics in
    ///   the pad's anchor and air, it moves with the particles' air
    ///   (`AirProfile`) within 3 % (a piece of path, up to 100 m and some
    ///   70 m of height here, gives its puffs one velocity, the wind at its
    ///   middle), and so with the sounding's wind at its height within 8 % in
    ///   speed and 4° in direction (the profile's levels are about a
    ///   kilometre apart there, the sounding's finer); one laid lower drifts
    ///   differently (the shear).
    /// - T+170 s, after CECO and OECO: a rebuild has the frames' pad clouds
    ///   and trail, the S-IC's flow taken from the journal's cutoffs.
    func testFlightAndRebuiltHistories() throws {
        let (sim, camera) = try open()
        let run = Run(sim, camera)
        run.frame()
        let axes = try siteAxes(try XCTUnwrap(run.scene))

        // T+75 s.
        fly(run, step: 0.5, for: 75, test: self)
        let at75 = Run(sim, camera)
        let rebuilt75 = at75.frame()
        for name in ["p4 pad exhaust", "p4 ice slab"] {
            for r in at75.requests(name, in: rebuilt75) where r.sourceVelocity == .zero {
                let p = axes.transposed * r.origin
                XCTAssertLessThan(Vec3(p.x, p.y, 0).length, 100, "\(name) at the pad, not under the vehicle")
            }
        }
        XCTAssertGreaterThan(at75.count("p4 ground cloud"), 100)
        // The frost's last second, at the vehicle's velocity.
        let materials = try XCTUnwrap(run.effects.materials)
        let framedFrost = try XCTUnwrap(run.outputs.last?.requests.last { $0.material == materials.iceFlake })
        let rebuiltFrost = try XCTUnwrap(rebuilt75.requests.last { $0.material == materials.iceFlake })
        XCTAssertEqual((rebuiltFrost.sourceVelocity - framedFrost.sourceVelocity).length, 0, accuracy: 1,
                       "the vehicle's own velocity, \(framedFrost.sourceVelocity.length) m/s")
        // The rebuilt trail along the frames'.
        let framed = try trail(run.outputs, run, axes: axes), again = try trail([rebuilt75], at75, axes: axes)
        try compareTrails(framed, again, heights: Array(stride(from: 1_000.0, through: 9_000, by: 1_000)), tolerance: 100,
                          "T+75 s")
        let framedCount = framed.reduce(0) { $0 + $1.request.count }, againCount = again.reduce(0) { $0 + $1.request.count }
        XCTAssertEqual(Double(againCount), Double(framedCount), accuracy: 0.08 * Double(framedCount))

        // T+135 s: the whole trail, and its drift.
        fly(run, step: 0.5, for: 60, test: self)
        let earth = try XCTUnwrap(sim.system.bodies.first { $0.id == 399 })
        let sounding = try XCTUnwrap(sim.atmosphere(of: earth))
        let table = run.session.materials
        let laid = try trail(run.outputs, run, axes: axes)
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
            XCTAssertEqual((flat * (1.0 / 120) - profile).length, 0, accuracy: 0.03 * profile.length,
                           "with the particles' air at \(Int(h)) m")
            print(String(format: "LaunchEffectsTests: trail puff at %.0f m: drift %.2f m/s, sounding %.2f m/s, profile %.2f m/s",
                         h, (s.position - start).length / 120, (w.east * w.east + w.north * w.north).squareRoot(),
                         (a.windEast * a.windEast + a.windNorth * a.windNorth).squareRoot()))
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

        // T+170 s: CECO and OECO are past.
        fly(run, step: 0.5, for: 35, test: self)
        XCTAssertEqual(run.effects.cutoffs.count, 5, "the journal's five cutoffs")
        let at170 = Run(sim, camera)
        let rebuilt170 = at170.frame()
        XCTAssertEqual(at170.effects.cutoffs.count, 5, "delivered to the rebuild")
        // The clouds' eddies alive: the frames' still within their lives,
        // and the rebuild's.
        let life = ParticleLifetimes.groundCloud
        let framedClouds = alive(run, "p4 ground cloud", life: life)
        let rebuiltClouds = at170.requests("p4 ground cloud", in: rebuilt170).reduce(0.0) { s, r in
            let age = 0.5 * (r.ages.lowerBound + r.ages.upperBound)
            return s + Double(r.count) * min(1, max(0, (life.upperBound - age) / (life.upperBound - life.lowerBound)))
        }
        XCTAssertEqual(rebuiltClouds, framedClouds, accuracy: 0.15 * framedClouds, "the clouds")
        let framedTrail = try trail(run.outputs, run, axes: axes)
        let trailFramed = framedTrail.reduce(0) { $0 + $1.request.count }
        let heights = Array(stride(from: 2_000.0, through: 38_000, by: 4_000))
        // After OECO and the S-IC's separation the rebuilt trail ends at the
        // journal's last cutoff, not at the spent stage, which coasts on.
        for (seconds, label) in [(0.0, "T+170 s"), (30, "T+200 s"), (100, "T+300 s"), (150, "T+450 s")] {
            if seconds > 0 { fly(run, step: 2, for: seconds, test: self) }
            let late = Run(sim, camera)
            let rebuilt = late.frame()
            let again = try trail([rebuilt], late, axes: axes)
            let trailAgain = again.reduce(0) { $0 + $1.request.count }
            print("LaunchEffectsTests: trail puffs at \(label): frames \(trailFramed), rebuilt \(trailAgain)")
            XCTAssertEqual(Double(trailAgain), Double(trailFramed), accuracy: 0.05 * Double(trailFramed), label)
            try compareTrails(framedTrail, again, heights: heights, tolerance: 700, label)
        }
    }

    /// The trail fades in as P2's plume fades out, on one clock: a puff laid
    /// at the window's start, at rest in the air, lies V a further on at age
    /// a, and its fade there plus the plume's linear fade-out over the
    /// hand-over's window sums to one within 0.5 % (the share's 0.5 % steps),
    /// for a grid of windows and
    /// airspeeds to the S-IC's cutoff (2.4 km/s), and in flight from T+10 s
    /// to CECO, from the materials the frames set (the lifetime one value,
    /// so the share is its clock).
    func testTrailFadesInAsThePlumeFadesOut() throws {
        XCTAssertEqual(ExhaustTrail.lifetime.lowerBound, ExhaustTrail.lifetime.upperBound)
        func worst(_ share: Double, window w: Double, airspeed v: Double) -> Double {
            let seconds = share * ExhaustTrail.lifetime.upperBound
            var e = 0.0
            for k in 0...400 {
                let x = -w + 2 * w * Double(k) / 400          // from the window's middle
                let plume = 1 - min(max((x + w) / (2 * w), 0), 1)
                let age = (x + ExhaustTrail.rampHalfWidth * w) / v
                let trail = age <= 0 ? 0 : min(1, age / seconds)
                e = max(e, abs(plume + trail - 1))
            }
            return e
        }
        for w in [7.0, 20, 40, 67, 150] {
            for v in [20.0, 50, 100, 400, 800, 1_200, 1_460, 1_650, 2_400] {
                let share = ExhaustTrail.fadeIn(window: w, airspeed: v)
                guard 2 * ExhaustTrail.rampHalfWidth * w / v < ExhaustTrail.longestFadeIn else { continue }
                XCTAssertLessThan(worst(share, window: w, airspeed: v), 0.005, "window \(w) m at \(v) m/s")
            }
        }
        let (sim, camera) = try open()
        let run = Run(sim, camera)
        run.frame()
        let zero = LaunchCountdown.epoch(0, in: .apollo11)
        let materials = try XCTUnwrap(run.effects.materials)
        var checked = 0
        for t in [10.0, 30, 60, 90, 110, 125, 135] {
            fly(run, step: 0.5, for: t - (sim.time - zero), test: self)
            let scene = try XCTUnwrap(run.scene)
            let own = scene.emitters.filter { $0.name.hasPrefix("S-IC engine") }
            let head = try XCTUnwrap(PlumeAirflow.trailHandover(own), "T+\(t) s")
            let v = try XCTUnwrap(own.first).relativeWind.length
            for id in materials.trail {
                let share = run.session.materials[id].fadeIn
                XCTAssertEqual(share, ExhaustTrail.fadeIn(window: head.window, airspeed: v), "T+\(t) s")
            }
            let share = run.session.materials[materials.trail[0]].fadeIn
            XCTAssertLessThan(worst(share, window: head.window, airspeed: v), 0.005, "T+\(t) s")
            print(String(format: "LaunchEffectsTests: at T+%.0f s the trail fades in over %.0f m at %.0f m/s (%.3f s)",
                         t, 2 * ExhaustTrail.rampHalfWidth * head.window, v, share * ExhaustTrail.lifetime.upperBound))
            checked += 1
        }
        XCTAssertEqual(checked, 7)
    }

    /// An outboard F-1 out at range 60 s (`as506-sic-engine1-out`): a
    /// rebuild at T+100 s lays the trail after the failure at the four
    /// engines' flow, as the frames did, from the journal's cutoff.
    func testEngineOutRebuild() throws {
        let (sim, camera) = try open("as506-sic-engine1-out")
        let run = Run(sim, camera)
        run.frame()
        let axes = try siteAxes(try XCTUnwrap(run.scene))
        // From the count's T−35 s to T+100 s.
        fly(run, step: 0.5, for: 135, test: self)
        let at100 = Run(sim, camera)
        let rebuilt = at100.frame()
        let failure = try XCTUnwrap(at100.effects.cutoffs["S-IC engine 1"], "the journal's engine out")
        XCTAssertEqual(failure - LaunchCountdown.epoch(0, in: .apollo11), 60, accuracy: 0.1)
        XCTAssertEqual(LaunchEffects.flow(at: sim.time, cutoffs: Array(at100.effects.cutoffs.values), engines: 5), 0.8,
                       accuracy: 1e-12)
        let framed = try trail(run.outputs, run, axes: axes), again = try trail([rebuilt], at100, axes: axes)
        let framedCount = framed.reduce(0) { $0 + $1.request.count }, againCount = again.reduce(0) { $0 + $1.request.count }
        // Laid at full flow after the failure, the rebuild would have about
        // a tenth more: the margin tells the two apart.
        let after = zip(run.outputs, run.epochs).filter { $0.1 > failure + LaunchEffects.tailOff }.map(\.0)
        let laidAfter = try trail(after, run, axes: axes).reduce(0) { $0 + $1.request.count }
        print("LaunchEffectsTests: engine out at T+100 s: frames \(framedCount) (\(laidAfter) after the failure), rebuilt \(againCount)")
        XCTAssertEqual(Double(againCount), Double(framedCount), accuracy: 0.03 * Double(framedCount))
        XCTAssertGreaterThan(Double(laidAfter) * 0.25, 0.06 * Double(framedCount), "the failure's share is measurable")
        try compareTrails(framed, again, heights: Array(stride(from: 2_000.0, through: 18_000, by: 2_000)), tolerance: 200,
                          "engine out, T+100 s")
    }

    /// The journal's flow: five F-1s, one cut off, tailing off linearly
    /// over 0.66 s (the F-1's shutdown, FER §5.4).
    func testJournalFlow() {
        let e = Epoch(tdbSecondsPastJ2000: 1_000)
        XCTAssertEqual(LaunchEffects.flow(at: e + -1, cutoffs: [e], engines: 5), 1)
        XCTAssertEqual(LaunchEffects.flow(at: e + 0.33, cutoffs: [e], engines: 5), 0.9, accuracy: 1e-12)
        XCTAssertEqual(LaunchEffects.flow(at: e + 0.66, cutoffs: [e], engines: 5), 0.8, accuracy: 1e-12)
        XCTAssertEqual(LaunchEffects.flow(at: e + 30, cutoffs: [e], engines: 5), 0.8, accuracy: 1e-12)
        let all = (0..<5).map { e + Double($0) * 10 }
        XCTAssertEqual(LaunchEffects.flow(at: e + 50, cutoffs: all, engines: 5), 0)
        XCTAssertEqual(LaunchEffects.flow(at: e + 15, cutoffs: all, engines: 5), 0.6, accuracy: 1e-12)
    }

    /// The rebuilt rise is the model's climb (AS506-datasheet §8.5): 105 m at
    /// range 10 s and 473 m at 20 s, and the IU's 137 m program start at
    /// T1 + 10.7 s (T1 at range 0.63 s), 11.0 s after first motion; its flow
    /// is the vehicle's five F-1s' at first motion.
    func testLiftoffRiseIsTheModels() {
        let fm = 0.30
        XCTAssertEqual(LiftoffRise.rise(after: 10 - fm), 105, accuracy: 3)
        XCTAssertEqual(LiftoffRise.rise(after: 20 - fm), 473, accuracy: 4)
        XCTAssertEqual(LiftoffRise.programStart, 0.63 + 10.7 - fm, accuracy: 0.15)
        XCTAssertEqual(LiftoffRise.rise(after: LiftoffRise.programStart), LiftoffRise.programStartRise, accuracy: 1e-6)
        let flows = VesselLibrary.saturnV().parts.flatMap(\.thrusters).filter { $0.name.hasPrefix("S-IC engine") }
            .map(\.currentRating.massFlow)
        XCTAssertEqual(flows.reduce(0, +), LiftoffRise.flow, accuracy: 0.005 * LiftoffRise.flow)
        // Its speed is its rise's rate.
        let t = 15.0, h = 1e-4
        XCTAssertEqual(LiftoffRise.speed(after: t), (LiftoffRise.rise(after: t + h) - LiftoffRise.rise(after: t - h)) / (2 * h),
                       accuracy: 1e-5)
    }
}
