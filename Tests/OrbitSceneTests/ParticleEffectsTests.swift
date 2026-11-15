import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// P3's director on the CPU: the time rules, the emit sampler, the anchors
/// and the air they read, and a session driven by a real simulation's
/// journal.
final class ParticleEffectsTests: XCTestCase {
    static let system = try! SolarSystem.bundled()
    static let viewport = RenderScene.Viewport(width: 640, height: 400)

    // MARK: Time rules

    /// The turbulence clock is real dt × min(warp, 4), stopped by pause.
    func testTurbulenceClock() {
        XCTAssertEqual(EffectTimeRules.turbulenceDt(realDt: 1.0 / 60, warp: 1, paused: false), 1.0 / 60)
        XCTAssertEqual(EffectTimeRules.turbulenceDt(realDt: 1.0 / 60, warp: 2, paused: false), 2.0 / 60)
        XCTAssertEqual(EffectTimeRules.turbulenceDt(realDt: 1.0 / 60, warp: 1_000, paused: false), 4.0 / 60)
        XCTAssertEqual(EffectTimeRules.turbulenceDt(realDt: 1.0 / 60, warp: 100, paused: true), 0)
    }

    /// Bursts at their true age; a step backwards or past 600 s is a jump.
    func testBurstAgeAndTimeJumps() {
        let t = Epoch(tdbSecondsPastJ2000: 1e9)
        XCTAssertEqual(EffectTimeRules.burstAge(event: t, frame: t + 1.7), 1.7, accuracy: 1e-6)
        XCTAssertEqual(EffectTimeRules.burstAge(event: t + 1, frame: t), 0)
        XCTAssertTrue(EffectTimeRules.isTimeJump(-0.1))
        XCTAssertTrue(EffectTimeRules.isTimeJump(601))
        XCTAssertFalse(EffectTimeRules.isTimeJump(16.7))
    }

    /// A 0.64 s retro flash at 100× (1.7 s a frame) that ended within the
    /// frame still spawns, and is held for 3 frames at half its life's look;
    /// at 10× and below it is not.
    func testFlashHold() {
        let t = Epoch(tdbSecondsPastJ2000: 0)
        let fast = EffectClock(epoch: t, dt: 1.7, warp: 100), slow = EffectClock(epoch: t, dt: 0.17, warp: 10)
        XCTAssertTrue(EffectTimeRules.spawns(age: 1.2, lifetime: 0.64, isFlash: true, clock: fast))
        XCTAssertFalse(EffectTimeRules.spawns(age: 1.2, lifetime: 0.64, isFlash: false, clock: fast))
        XCTAssertFalse(EffectTimeRules.spawns(age: 2.5, lifetime: 0.64, isFlash: true, clock: fast), "ended before")
        XCTAssertFalse(EffectTimeRules.spawns(age: 1.2, lifetime: 0.64, isFlash: true, clock: slow))
        XCTAssertTrue(fast.holdsFlashes)
        XCTAssertFalse(slow.holdsFlashes)
        for shown in 0..<3 {
            XCTAssertTrue(FlashHold.isAlive(age: 3, lifetime: 0.64, framesShown: shown, isFlash: true, holds: true))
        }
        XCTAssertFalse(FlashHold.isAlive(age: 3, lifetime: 0.64, framesShown: 3, isFlash: true, holds: true))
        XCTAssertFalse(FlashHold.isAlive(age: 3, lifetime: 0.64, framesShown: 0, isFlash: true, holds: false))
        XCTAssertEqual(FlashHold.displayAge(age: 3, lifetime: 0.64), 0.32)
        XCTAssertEqual(FlashHold.displayAge(age: 0.1, lifetime: 0.64), 0.1)
    }

    /// 100 particles a second over a second of 1/60 s frames are 100, the
    /// fractions carried; at 100× a 0.5 s lifetime covers only the frame's
    /// last 0.5 s, and nothing older is carried.
    func testContinuousEmissionCoversTheLastLifetime() {
        var e = ContinuousEmission(), total = 0
        for _ in 0..<60 {
            let s = e.schedule(rate: 100, dt: 1.0 / 60, lifetime: 2)
            total += s.count
            XCTAssertEqual(s.ages.upperBound, 1.0 / 60, accuracy: 1e-12)
        }
        XCTAssertEqual(total, 100)
        var fast = ContinuousEmission()
        let s = fast.schedule(rate: 100, dt: 1.7, lifetime: 0.5)
        XCTAssertEqual(s.count, 50)
        XCTAssertEqual(s.ages, 0...0.5)
        XCTAssertEqual(fast.carry, 0, accuracy: 1e-12)
        XCTAssertEqual(fast.schedule(rate: 100, dt: 0, lifetime: 0.5).count, 0, "paused")
    }

    // MARK: Sampling

    func request(_ shape: EmitShape, _ direction: EmitDirection = .axis(spread: .pi), count: Int = 400) -> EmitRequest {
        var r = EmitRequest(anchor: EffectAnchorID(slot: 0, generation: 1), material: ParticleMaterialID(0), count: count)
        r.origin = Vec3(10, -5, 2)
        r.axis = Vec3(1, 1, 0).normalized
        r.shape = shape
        r.direction = direction
        r.speed = 2...4
        r.radius = 0.5...1.5
        r.lifetime = 3...9
        r.ages = 1...5
        r.seed = 42
        return r
    }

    /// Each shape keeps its particles where it says, ages fall one to each
    /// stratum, and the ranges hold.
    func testSamplerShapesAndStrata() {
        let axis = Vec3(1, 1, 0).normalized
        let shapes: [(EmitShape, (Vec3) -> Bool)] = [
            (.point, { $0.length < 1e-9 }),
            (.ball(radius: 3), { $0.length <= 3 + 1e-9 }),
            (.sphere(radius: 3), { abs($0.length - 3) < 1e-9 }),
            (.disc(radius: 3), { abs($0.dot(axis)) < 1e-9 && $0.length <= 3 + 1e-9 }),
            (.ring(radius: 3, width: 1), { abs($0.dot(axis)) < 1e-9 && $0.length >= 2.5 - 1e-9 && $0.length <= 3.5 + 1e-9 }),
            (.band(radius: 3, height: 2), {
                let along = $0.dot(axis)
                return abs(along) <= 1 + 1e-9 && abs(($0 - axis * along).length - 3) < 1e-9
            }),
            (.line(length: 4), { abs($0.length - $0.dot(axis)) < 1e-9 && $0.dot(axis) <= 4 + 1e-9 }),
        ]
        for (shape, inside) in shapes {
            let r = request(shape)
            for i in 0..<r.count {
                let p = EmitSampler.sample(r, index: i)
                // The source is still: the offset from the origin is the shape's.
                XCTAssertTrue(inside(p.position - r.origin), "\(shape) \(i): \(p.position - r.origin)")
                let stratum = 1 + 4 * Double(i) / Double(r.count)
                XCTAssertGreaterThanOrEqual(p.age, stratum - 1e-9)
                XCTAssertLessThan(p.age, stratum + 4.0 / Double(r.count))
                XCTAssertTrue((0.5...1.5).contains(p.radius))
                XCTAssertTrue((3...9).contains(p.lifetime))
                XCTAssertTrue((2.0 - 1e-9...4.0 + 1e-9).contains(p.velocity.length))
            }
        }
        // The same request draws the same particles; another seed others.
        XCTAssertEqual(EmitSampler.sample(request(.ball(radius: 3)), index: 7), EmitSampler.sample(request(.ball(radius: 3)), index: 7))
        var other = request(.ball(radius: 3))
        other.seed = 43
        XCTAssertNotEqual(EmitSampler.sample(other, index: 7).position, EmitSampler.sample(request(.ball(radius: 3)), index: 7).position)
    }

    /// Directions stay in their cone about the axis, or about the outward
    /// direction for `.radial`; the uniforms are spread evenly.
    func testSamplerDirections() {
        let axis = Vec3(1, 1, 0).normalized
        let cone = request(.point, .axis(spread: 0.3))
        for i in 0..<cone.count {
            let d = EmitSampler.sample(cone, index: i).velocity.normalized
            XCTAssertLessThanOrEqual(angleBetween(d, axis), 0.3 + 1e-9)
        }
        let ring = request(.ring(radius: 3, width: 0), .radial(spread: 0))
        for i in 0..<ring.count {
            let p = EmitSampler.sample(ring, index: i)
            XCTAssertEqual(angleBetween(p.velocity, p.position - ring.origin), 0, accuracy: 1e-6)
        }
        var state: UInt32 = 1, sum = 0.0
        for _ in 0..<10_000 { sum += ParticleRandom.uniform(&state) }
        XCTAssertEqual(sum / 10_000, 0.5, accuracy: 0.01)
    }

    /// A particle of age a from a moving, accelerating source started where
    /// the source was then, moving as it moved then.
    func testSourceMotionIsUndone() {
        var r = request(.point, .axis(spread: 0), count: 10)
        r.speed = 0...0
        r.sourceVelocity = Vec3(100, 0, 0)
        r.sourceAcceleration = Vec3(0, 0, 30)
        for i in 0..<r.count {
            let p = EmitSampler.sample(r, index: i)
            let a = p.age
            XCTAssertEqual((p.position - (r.origin - Vec3(100 * a, 0, -15 * a * a))).length, 0, accuracy: 1e-9)
            XCTAssertEqual((p.velocity - Vec3(100, 0, -30 * a)).length, 0, accuracy: 1e-9)
        }
    }

    // MARK: Air and anchors

    /// The profile is the atmosphere at its levels, US76 between them
    /// within 1 % (density and pressure log-linear), and vacuum at the top.
    func testAirProfileFollowsTheAtmosphere() {
        let us76 = USStandardAtmosphere1976()
        let air = AirProfile(us76)
        for i in [0, 5, 20, 40, 60] {
            let h = AirProfile.altitude(i), s = air.sample(altitude: h), e = us76.state(altitude: h)
            XCTAssertEqual(s.density, e.density, accuracy: 1e-9 * e.density)
            XCTAssertEqual(s.temperature, e.temperature, accuracy: 1e-9)
        }
        for h in [137.0, 1_234, 7_777, 11_500, 33_333, 71_000] {
            let s = air.sample(altitude: h), e = us76.state(altitude: h)
            XCTAssertEqual(s.density, e.density, accuracy: 0.01 * e.density, "h \(h)")
            XCTAssertEqual(s.pressure, e.pressure, accuracy: 0.01 * e.pressure, "h \(h)")
            XCTAssertEqual(s.temperature, e.temperature, accuracy: 0.01 * e.temperature, "h \(h)")
        }
        XCTAssertEqual(air.sample(altitude: 100_001).density, 0)
        XCTAssertEqual(AirProfile.altitude(1), 100_000.0 / 3_969, accuracy: 1e-9)
    }

    /// A free-fall anchor in a circular orbit of the J2-less Earth comes back
    /// to its start after one period, to 10 m; with J2 its energy holds to
    /// 1e-7 over an hour of 10 s RK4 steps.
    func testFreeFallAnchorPropagation() throws {
        let earth = Self.system.earth
        let (sim, camera) = try open("leo")
        let scene = SceneExtractor().extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 0)
        var body = try XCTUnwrap(scene.bodies.first { $0.id == earth.id })
        XCTAssertEqual(body.gm, earth.gm)
        XCTAssertEqual(body.j2, earth.j2)
        body.position = .zero
        body.j2 = 0
        let r = 6_571_000.0, v = (earth.gm / r).squareRoot(), period = 2 * Double.pi * r / v
        let t0 = Epoch(tdbSecondsPastJ2000: 0)
        let a = EffectAnchor.freeFall(bodyID: earth.id, position: Vec3(r, 0, 0), velocity: Vec3(0, v, 0), epoch: t0)
        guard case let .freeFall(_, p, _, t) = a.propagated(to: t0 + period, body: body) else { return XCTFail() }
        XCTAssertEqual((p - Vec3(r, 0, 0)).length, 0, accuracy: 10)
        XCTAssertEqual(t, t0 + period)
        body.j2 = earth.j2
        let tilted = EffectAnchor.freeFall(bodyID: earth.id, position: Vec3(r, 0, 0), velocity: Vec3(0, v * 0.8, v * 0.6),
                                           epoch: t0)
        func energy(_ a: EffectAnchor) -> Double {
            guard case let .freeFall(_, p, u, _) = a else { return .nan }
            let z = p.dot(body.orientation.icrfToBody.r2) / p.length
            return 0.5 * u.lengthSquared - earth.gm / p.length
                + earth.gm * earth.j2 * earth.radius * earth.radius / (2 * pow(p.length, 3)) * (3 * z * z - 1)
        }
        let later = tilted.propagated(to: t0 + 3_600, body: body)
        XCTAssertEqual(energy(later), energy(tilted), accuracy: 1e-7 * abs(energy(tilted)))
    }

    // MARK: A session on a real simulation

    /// Records the events it saw and bursts steam at liftoff.
    final class Recorder: EffectProducer {
        let name = "recorder"
        var steam = ParticleMaterialID(0), spark = ParticleMaterialID(0)
        var events: [EffectEvent] = []
        var resets = 0
        var continuousRate = 0.0
        func registerMaterials(_ table: ParticleMaterialTable) {
            steam = table.register(.steam)
            spark = table.register(.spark)
        }
        func handle(_ e: EffectEvent, in f: EffectFrame) {
            events.append(e)
            guard e.kind == .liftoff, let a = f.freeFallAnchor(for: e) else { return }
            var r = EmitRequest(anchor: a, material: steam, count: 100)
            r.lifetime = 60...60
            if let p = f.place(Vec3(-30, 0, 0), of: e, in: a) { r.origin = p.position }
            f.burst(r, at: e.epoch)
        }
        func update(_ f: EffectFrame) {
            guard continuousRate > 0, let v = f.scene.vessels.first, let a = f.vesselAnchor(v.id) else { return }
            var r = EmitRequest(anchor: a, material: spark, count: 0)
            r.lifetime = 0.5...0.5
            if let p = f.place(.zero, of: v, in: a) {
                r.origin = p.position
                r.sourceVelocity = p.velocity
            }
            f.emitContinuous("sparks", rate: continuousRate, r)
        }
        func reset() { resets += 1 }
    }

    func open(_ id: String) throws -> (Simulation, OrbitCamera) {
        let sim = try XCTUnwrap(Scenario.named(id)).build(Self.system)
        var camera = OrbitCamera()
        if let focus = sim.focus {
            camera.target = .vessel(focus.id)
            camera.distance = max(focus.boundingRadius * 3, 30)
        }
        camera.update(sim: sim)
        return (sim, camera)
    }

    func advance(_ sim: Simulation, _ seconds: Double) {
        sim.paused = false
        sim.stepBudget = nil
        var left = seconds
        while left > 1e-9 {
            sim.advance(by: min(5, left))
            left -= min(5, left)
        }
    }

    /// AS-506's liftoff burst is spawned once, at its true age, in a
    /// free-fall anchor at the vehicle's state then, wherever the frame
    /// lands; a frame drawn again spawns nothing; a new simulation resets.
    func testSessionBurstsAtTrueAge() throws {
        let (sim, camera) = try open("as506-pad")
        let x = SceneExtractor(), recorder = Recorder(), session = EffectSession(producers: [recorder])
        _ = session.frame(x.extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 0),
                          settings: ParticleSettings())
        advance(sim, 3)
        var scene = x.extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 3)
        let out = session.frame(scene, settings: ParticleSettings())
        let liftoff = try XCTUnwrap(recorder.events.first { $0.kind == .liftoff })
        let burst = try XCTUnwrap(out.requests.first)
        XCTAssertEqual(burst.ages.lowerBound, sim.time - liftoff.epoch, accuracy: 1e-9)
        XCTAssertGreaterThan(burst.ages.lowerBound, 1, "the liftoff was seconds before this frame")
        XCTAssertEqual(out.drawn, [.smoke])
        XCTAssertEqual(out.anchors.count, 1)
        // The anchor is at the vehicle's state at liftoff carried on in free
        // fall: below where the vehicle has climbed to under thrust.
        let anchor = try XCTUnwrap(out.anchors.first?.frame)
        let vessel = try XCTUnwrap(scene.vessels.first)
        let earth = try XCTUnwrap(scene.bodies.first { $0.id == 399 })
        let climbed = (vessel.position - earth.position).length - (anchor.origin - earth.position).length
        XCTAssertGreaterThan(climbed, 1, "the vehicle rose away from the free-falling anchor")
        XCTAssertNotNil(anchor.airProfile, "the Earth's air")
        XCTAssertEqual(anchor.gravity, .zero)

        // Drawn again: nothing new, time stands still.
        let again = session.frame(scene, settings: ParticleSettings())
        XCTAssertTrue(again.requests.isEmpty)
        XCTAssertEqual(again.clock.dt, 0)
        XCTAssertFalse(again.resets)
        // On: the event is not handled twice.
        advance(sim, 0.5)
        scene = x.extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 3.5)
        let on = session.frame(scene, settings: ParticleSettings())
        XCTAssertEqual(on.clock.dt, 0.5, accuracy: 1e-6)
        XCTAssertEqual(recorder.events.filter { $0.kind == .liftoff }.count, 1)
        XCTAssertTrue(on.requests.isEmpty)
        // A new simulation resets everything.
        let (sim2, camera2) = try open("as506-pad")
        let fresh = session.frame(SceneExtractor().extract(sim: sim2, camera: camera2, viewport: Self.viewport, realTime: 0),
                                  settings: ParticleSettings())
        XCTAssertTrue(fresh.resets)
        XCTAssertTrue(fresh.anchors.isEmpty)
        XCTAssertGreaterThanOrEqual(recorder.resets, 2)
    }

    /// A continuous emitter at 1× gives rate × dt with stratified ages in a
    /// tracking anchor; at 1,000× it stops; a step past 600 s resets.
    func testSessionContinuousEmitter() throws {
        let (sim, camera) = try open("as506-parking-orbit")
        let x = SceneExtractor(), recorder = Recorder(), session = EffectSession(producers: [recorder])
        recorder.continuousRate = 600
        var t = 0.0
        func frame(_ dt: Double, warp: Double = 1) -> EffectFrameOutput {
            sim.warp = warp
            advance(sim, dt)
            t += dt / warp
            return session.frame(x.extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: t),
                                 settings: ParticleSettings())
        }
        _ = frame(0)
        var count = 0
        for _ in 0..<30 { count += frame(1.0 / 60).requests.reduce(0) { $0 + $1.count } }
        XCTAssertEqual(count, 300, accuracy: 1)
        // At 100× a 1.7 s frame: only its last 0.5 s, the sparks' lifetime.
        let warped = frame(1.7, warp: 100)
        let r = try XCTUnwrap(warped.requests.first)
        XCTAssertEqual(r.count, 300, accuracy: 1)
        XCTAssertEqual(r.ages.upperBound, 0.5, accuracy: 1e-9)
        XCTAssertTrue(frame(16.7, warp: 1_000).requests.isEmpty, "suspended at 1,000×")
        let jumped = frame(700, warp: 1_000)
        XCTAssertTrue(jumped.resets)
    }

    /// Look-dev bursts are spawned afresh every frame in the studio, in its
    /// own air, whatever the scenario.
    func testStudioBursts() throws {
        let (sim, camera) = try open("leo")
        var settings = ParticleSettings()
        var b = ParticleTestBurst()
        b.material = "steam"
        b.count = 50
        b.ages = [2, 2]
        b.lifetime = [5, 5]
        settings.testBursts = [b]
        settings.studio = .seaLevel
        let session = EffectSession()
        let scene = SceneExtractor().extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 0)
        let one = session.frame(scene, settings: settings), two = session.frame(scene, settings: settings)
        XCTAssertTrue(one.resets && two.resets)
        // The same particles each frame, in a new anchor each time.
        func same(_ r: EmitRequest) -> EmitRequest {
            var r = r
            r.anchor = EffectAnchorID(slot: r.anchor.slot, generation: 0)
            return r
        }
        XCTAssertEqual(one.requests.map(same), two.requests.map(same))
        XCTAssertEqual(one.requests.first?.ages, 2...2)
        let a = try XCTUnwrap(one.anchors.first?.frame)
        XCTAssertEqual(a.gravity, Vec3(0, 0, -9.80665))
        let density = try XCTUnwrap(a.airProfile.map { one.airProfiles[$0].sample(altitude: 1_000).density })
        XCTAssertEqual(density, 1.225, accuracy: 1e-12)
        XCTAssertEqual((a.origin - EffectTargetFrame(scene: scene).origin).length, 0)
    }

    // MARK: Materials and settings

    func testMaterialTable() {
        let t = ParticleMaterialTable()
        let a = t.register(.smoke), b = t.register(.spark)
        XCTAssertEqual([a.index, b.index], [0, 1])
        let r = t.revision
        XCTAssertEqual(t.register(.smoke), a)
        XCTAssertEqual(t.revision, r, "the same material again changes nothing")
        var darker = ParticleMaterial.smoke
        darker.albedo = ParticleColor(gray: 0.1)
        XCTAssertEqual(t.register(darker), a)
        XCTAssertEqual(t.revision, r + 1)
        XCTAssertEqual(t[a].albedo.r, 0.1)
        XCTAssertEqual(Set(ParticleMaterial.library.map(\.name)).count, ParticleMaterial.library.count)
    }

    func testSettingsDecode() throws {
        let json = """
        {"quality": "low", "studio": {"gravity": 9.8, "airDensity": 1.2, "airPressure": 100000},
         "testBursts": [{"material": "mine", "count": 10, "shape": "ring", "size": 4, "width": 1, "radial": true,
                         "spread": 10, "custom": {"name": "mine", "renderClass": "streak", "emission": [1, 2, 3]}}]}
        """
        let s = try JSONDecoder().decode(ParticleSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.quality, .low)
        XCTAssertFalse(s.quality.drawsSmoke)
        XCTAssertEqual(s.studio.gravity, 9.8)
        let b = try XCTUnwrap(s.testBursts.first)
        let m = try XCTUnwrap(b.resolvedMaterial)
        XCTAssertEqual(m.renderClass, .streak)
        XCTAssertEqual(m.emission, ParticleColor(1, 2, 3))
        XCTAssertEqual(m.coolingTime, .infinity)
        let r = b.request(anchor: EffectAnchorID(slot: 0, generation: 1), material: ParticleMaterialID(0))
        XCTAssertEqual(r.shape, .ring(radius: 4, width: 1))
        XCTAssertEqual(r.direction, .radial(spread: 10 * Double.pi / 180))
        // A material round-trips, its infinite cooling time as none.
        let back = try JSONDecoder().decode(ParticleMaterial.self, from: JSONEncoder().encode(ParticleMaterial.steam))
        XCTAssertEqual(back, .steam)
        let spark = try JSONDecoder().decode(ParticleMaterial.self, from: JSONEncoder().encode(ParticleMaterial.flash))
        XCTAssertEqual(spark, .flash)
        XCTAssertEqual(try JSONDecoder().decode(RenderSettings.self, from: Data("{}".utf8)).particle, ParticleSettings())
    }
}
