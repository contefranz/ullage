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
    /// sight: straight at the camera (a round dot), at 45° and across it (a
    /// streak). The capsule is drawn across the line of sight and its flux
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
        var sums: [Double] = []
        for direction in [-view, (-view + across).normalized, across] {
            var b = ParticleTestBurst()
            b.material = "spark"
            b.count = 1
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
        for (angle, sum) in zip([0, 45], sums) {
            XCTAssertEqual(sum, sums[2], accuracy: 0.1 * sums[2], "at \(angle)° to the line of sight: \(sums)")
        }
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
