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
