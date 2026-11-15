import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// P3's particles on the GPU: the effects self-test (`OrbitSim --selftest
/// effects`), the passes running only on frames with particles (no smoke at
/// the Low tier), and finite light from every render class.
@MainActor
final class ParticleRenderTests: XCTestCase {
    static var snapper: SnapshotRenderer?

    func snapper() throws -> SnapshotRenderer {
        if let s = Self.snapper { return s }
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        Self.snapper = s
        return s
    }

    /// P3's look-dev shots, small.
    func shots() throws -> [SnapshotSpec.Shot] {
        let spec = try SnapshotSpec.load(GoldenImageTests.shots.appendingPathComponent("p3.json"))
        return spec.shots.map {
            var s = $0
            s.width = 160
            s.height = 100
            s.aovs = []
            return s
        }
    }

    /// The self-test passes: the modules compile, the kernels match the
    /// core's golden vectors and the CPU's sampling, slots are kept, flashes
    /// held, the budget kept.
    func testEffectsSelfTest() throws {
        let report = EffectsSelfTest.run(device: try XCTUnwrap(RenderDevice.shared))
        XCTAssertTrue(report.passed, report.text)
        XCTAssertGreaterThanOrEqual(report.checks.count, 11)
    }

    /// With bursts every particle pass runs; with none, after the frame that
    /// clears the last ones, none does (nor R6's slots); at the Low tier
    /// there is no smoke.
    func testPassesRunOnlyWithParticles() throws {
        let s = try snapper()
        var shot = try XCTUnwrap(try shots().first { $0.name == "p3-separation" })
        shot.settings.transparency.testEmitters = []
        let with = try s.render(shot, timingFrames: 1).timings.map(\.pass)
        for pass in ["Particle simulation", "Particle chunks", "Particle smoke", "Particles"] {
            XCTAssertTrue(with.contains(pass), "\(pass) in \(with)")
        }
        var low = shot
        low.settings.particle.quality = .low
        let lowPasses = try s.render(low, timingFrames: 1).timings.map(\.pass)
        XCTAssertFalse(lowPasses.contains("Particle smoke"))
        XCTAssertFalse(lowPasses.contains("Half-resolution transparents"))
        XCTAssertTrue(lowPasses.contains("Particles"))
        var none = shot
        none.settings.particle.testBursts = []
        let nonePasses = try s.render(none, timingFrames: 1).timings.map(\.pass)
        XCTAssertFalse(nonePasses.contains { $0.hasPrefix("Particle") }, "\(nonePasses)")
        XCTAssertFalse(nonePasses.contains("Half-resolution transparents"))
    }

    /// A small studio shot in the inertial frame, its camera `distance` m
    /// out from the target along `direction` (ICRF), at a manual EV.
    func studioShot(_ bursts: [ParticleTestBurst], from direction: Vec3, distance: Double, ev: Double) -> SnapshotSpec.Shot {
        var shot = SnapshotSpec.Shot(name: "p3-test", scenario: "leo")
        shot.width = 320
        shot.height = 200
        shot.showOrbit = false
        let deg = 180 / Double.pi, d = direction.normalized
        shot.camera = SnapshotSpec.CameraSpec(frame: "inertial", yaw: atan2(-d.y, d.x) * deg, pitch: asin(d.z) * deg,
                                              distance: distance, fov: 40)
        shot.settings.post.exposure.mode = .manual
        shot.settings.post.exposure.ev100 = ev
        shot.settings.transparency.testBackdrop = true
        shot.settings.particle.testBursts = bursts
        return shot
    }

    /// The frame's light summed over the image, cd/m² (the backdrop is black).
    func totalLight(_ shot: SnapshotSpec.Shot) throws -> Double {
        let out = try snapper().render(shot)
        let light = try XCTUnwrap(out.light)
        return stride(from: 0, to: light.count, by: 4).reduce(0.0) { $0 + Double(light[$1] + light[$1 + 1] + light[$1 + 2]) }
    }

    /// A spark's light is the same however it moves relative to the line of
    /// sight: straight at the camera (a round dot, at the centre and near
    /// the frame's corner), at 45° and across it (a streak). The capsule is drawn across the line of sight and its flux
    /// spread over what is drawn. (A dim exposure keeps every sample far
    /// below the MSAA resolve's highlight weighting.)
    func testStreakFluxDoesNotDependOnTheViewAngle() throws {
        let s = try snapper()
        let probe = studioShot([], from: Vec3(1, 0.3, 0.2), distance: 30, ev: 20)
        let scene = probe.scene(try probe.prepare(system: s.system))
        let t = EffectTargetFrame(scene: scene)
        let ray = t.origin.normalized                      // camera to target
        let view = Vec3(ray.dot(t.east), ray.dot(t.north), ray.dot(t.up))
        var across = view.cross(Vec3(0, 0, 1))
        if across.length < 1e-3 { across = view.cross(Vec3(1, 0, 0)) }
        across = across.normalized
        // Near the frame's corner, moving straight at the camera along its
        // own line of sight (the dot faces that, not the view's axis).
        func enu(_ w: Vec3) -> Vec3 { Vec3(w.dot(t.east), w.dot(t.north), w.dot(t.up)) }
        let right = enu(scene.camera.worldToView.r0), screenUp = enu(scene.camera.worldToView.r1)
        let reach = 30 * tan(20 * Double.pi / 180) * 0.85
        let corner = right * (reach * 1.6) + screenUp * reach
        let lineOfSight = (corner + view * 30).normalized
        var sums: [Double] = []
        for (direction, at) in [(-view, Vec3.zero), ((-view + across).normalized, .zero), (across, .zero),
                                (-lineOfSight, corner)] {
            var b = ParticleTestBurst()
            b.material = "spark"
            b.count = 1
            b.position = [at.x, at.y, at.z]
            b.axis = [direction.x, direction.y, direction.z]
            b.spread = 0
            b.speed = [60, 60]
            b.radius = [0.005, 0.005]
            b.lifetime = [2, 2]
            b.ages = [0, 0]
            b.temperature = 2_600
            sums.append(try totalLight(studioShot([b], from: Vec3(1, 0.3, 0.2), distance: 30, ev: 20)))
        }
        XCTAssertGreaterThan(sums[2], 0)
        for (angle, sum) in zip(["0°", "45°"], [sums[0], sums[1]]) {
            XCTAssertEqual(sum, sums[2], accuracy: 0.1 * sums[2], "at \(angle) to the line of sight: \(sums)")
        }
        // Off the axis by α a pixel subtends cos³α of the solid angle and the
        // spark is 1/cos α farther: the same light sums to 1/cos α more. (A
        // dot facing the view's axis instead would lose cos α of its flux.)
        let cosAlpha = 30 / (corner + view * 30).length
        XCTAssertEqual(sums[3] * cosAlpha, sums[2], accuracy: 0.07 * sums[2], "head-on at the corner: \(sums)")
    }

    /// Chunks are lit on one side, as the vessels: seen against the Sun,
    /// their faces turned from it get only the sky (none above the air) and
    /// the floor, not sunlight.
    func testBacklitChunksAreDark() throws {
        let s = try snapper()
        let probe = studioShot([], from: Vec3(1, 0, 0), distance: 25, ev: 15)
        let sun = probe.scene(try probe.prepare(system: s.system)).sun.direction
        var b = ParticleTestBurst()
        b.material = "debris"
        b.count = 200
        b.shape = "ball"
        b.size = 5
        b.radius = [0.3, 0.6]
        b.lifetime = [60, 60]
        b.ages = [1, 1]
        let front = try totalLight(studioShot([b], from: sun, distance: 25, ev: 15))
        let back = try totalLight(studioShot([b], from: -sun, distance: 25, ev: 15))
        XCTAssertGreaterThan(front, 0)
        XCTAssertLessThan(back, 0.2 * front, "backlit \(back) against front-lit \(front)")
    }

    /// Culling changes nothing on screen: particles straddling the frame's
    /// edges (plates whose corners reach past their radius, streaks whose
    /// caps and least width reach past their trail, puffs, faint glinting
    /// flakes) render the same with it on and off.
    func testCullingIsNeutral() throws {
        func burst(_ material: String, _ count: Int, radius: [Double], speed: [Double], seed: Int) -> ParticleTestBurst {
            var b = ParticleTestBurst()
            b.material = material
            b.count = count
            b.shape = "ball"
            b.size = 40
            b.radius = radius
            b.speed = speed
            b.lifetime = [100, 100]
            b.ages = [0.5, 0.5]
            b.temperature = material == "spark" ? 2_600 : 0
            b.seed = seed
            return b
        }
        let bursts = [burst("debris", 400, radius: [0.5, 1.5], speed: [0, 1], seed: 1),
                      burst("spark", 400, radius: [0.003, 0.01], speed: [20, 80], seed: 2),
                      burst("steam", 150, radius: [2, 5], speed: [0, 1], seed: 3),
                      burst("ice flake", 2_000, radius: [0.0005, 0.002], speed: [0, 2], seed: 4)]
        var shot = studioShot(bursts, from: Vec3(1, 0.3, 0.2), distance: 12, ev: 15)
        let on = try snapper().render(shot), again = try snapper().render(shot)
        shot.settings.particle.culls = false
        let off = try snapper().render(shot)
        // The smoke's and the streaks' sums follow the GPU's append order:
        // two culled frames already differ by a code or two here and there.
        func differ(_ a: [UInt8], _ b: [UInt8]) -> (most: Int, over1: Int) {
            let d = zip(a, b).map { abs(Int($0) - Int($1)) }
            return (d.max() ?? 0, d.filter { $0 > 1 }.count)
        }
        let noise = differ(on.pixels, again.pixels), culling = differ(on.pixels, off.pixels)
        XCTAssertLessThanOrEqual(culling.most, max(noise.most, 1) + 1, "culling \(culling), run to run \(noise)")
        XCTAssertLessThanOrEqual(culling.over1, noise.over1 + 16, "culling \(culling), run to run \(noise)")
        XCTAssertGreaterThan(Set(on.pixels).count, 100, "the particles are drawn")
    }

    /// The faint-streak cut is where `ParticleSystem.faintestStreak` puts it:
    /// sparks whose brightest pre-exposed light (a dot 3 pixels wide: π r²
    /// over π/3 h², times the emission and the pre-exposure 1/(1.2 · 2^EV))
    /// is three times the threshold are all drawn, a third of it none. An
    /// image cannot show this cut on a black backdrop under the tone
    /// curve's toe; the drawn count does.
    func testFaintestStreakCut() throws {
        let s = try snapper()
        let ev = 15.0, distance = 30.0, r = 0.001, count = 50
        let pixel = distance * 2 * tan(20 * Double.pi / 180) / 200
        let h = 0.5 * 3 * pixel
        let perEmission = 3 * r * r / (h * h) / (1.2 * pow(2, ev))
        func drawn(_ factor: Double) throws -> Int {
            var m = ParticleMaterial(name: "probe spark", renderClass: .streak)
            m.albedo = .black
            m.emission = ParticleColor(gray: factor * ParticleSystem.faintestStreak / perEmission)
            m.fadeIn = 0
            m.fadeOut = 0
            m.density = 3_950
            var b = ParticleTestBurst()
            b.material = m.name
            b.custom = m
            b.count = count
            b.shape = "ball"
            b.size = 0.3
            b.radius = [r, r]
            b.lifetime = [10, 10]
            b.ages = [0, 0]
            _ = try s.render(studioShot([b], from: Vec3(1, 0.3, 0.2), distance: distance, ev: ev))
            let r = try s.renderer(userTextures: false)
            let system = try XCTUnwrap((r.graph.pass(named: "Particle simulation") as? ParticleSimulationPass)?.system)
            return system.readCounters()[.drawStreak] ?? -1
        }
        // The cut drops nothing a display could show: at most a tenth of
        // sRGB's first 8-bit step near black, (1/255)/12.92.
        XCTAssertLessThanOrEqual(ParticleSystem.faintestStreak, 0.1 / 255 / 12.92)
        XCTAssertEqual(try drawn(3), count, "three times the faintest: all drawn")
        XCTAssertEqual(try drawn(1.0 / 3), 0, "a third of it: none")
    }

    /// Every look-dev shot's light is finite and not negative, and each
    /// draws something over its black backdrop.
    func testLightIsFiniteAndDrawn() throws {
        let s = try snapper()
        for shot in try shots() {
            let out = try s.render(shot)
            let light = try XCTUnwrap(out.light, shot.name)
            XCTAssertTrue(light.allSatisfy { $0.isFinite && $0 >= 0 }, shot.name)
            let lit = stride(from: 0, to: light.count, by: 4).filter { light[$0] + light[$0 + 1] + light[$0 + 2] > 1 }.count
            XCTAssertGreaterThan(lit, 50, "\(shot.name): pixels brighter than 1 cd/m²")
            XCTAssertEqual(out.record.failures, [:], shot.name)
        }
    }
}
