import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// The plume pass on the GPU (P2): the march against OrbitScene's
/// reference (`PlumeLook.march`) through the same rays, the plume lights
/// reaching R2's vessel pass, the readable floor, quality off drawing
/// nothing, and the SPS extension's glow on its drawn bell.
@MainActor
final class PlumeRenderTests: XCTestCase {
    static var snapper: SnapshotRenderer?

    func snapper() throws -> SnapshotRenderer {
        if let s = Self.snapper { return s }
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        Self.snapper = s
        return s
    }

    /// One engine on R6's black backdrop in low Earth orbit, side-on, no
    /// air, no clouds, manual exposure.
    static func lookDev(_ engines: [PlumeTestEngine], distance: Double = 150, ev: Double = 17,
                        configure: (inout PlumeSettings) -> Void = { _ in }) -> SnapshotSpec.Shot {
        var shot = SnapshotSpec.Shot(name: "p2-test", scenario: "leo",
                                     camera: SnapshotSpec.CameraSpec(yaw: 0, pitch: 0, distance: distance, fov: 45))
        shot.width = 320
        shot.height = 200
        shot.showOrbit = false
        shot.settings.post.exposure.mode = .manual
        shot.settings.post.exposure.ev100 = ev
        shot.settings.cloud.enabled = false
        shot.settings.atmosphere.enabled = false
        shot.settings.transparency.testBackdrop = true
        shot.settings.plume.testEngines = engines
        configure(&shot.settings.plume)
        return shot
    }

    /// The camera ray through pixel (x, y) of `scene`, world axes, unit.
    static func ray(_ scene: RenderScene, x: Double, y: Double) -> Vec3 {
        let c = scene.camera
        let w = c.viewport.width, h = c.viewport.height
        let t = tan(c.fovY / 2)
        let v = Vec3((2 * (x + 0.5) / w - 1) * t * w / h, (1 - 2 * (y + 0.5) / h) * t, -1)
        return (c.worldToView.transposed * v).normalized
    }

    /// The march against the reference through the same rays: an F-1 at
    /// the pad's air, turbulence off, side-on down its axis from 2 to 12
    /// exit diameters; their luminances agree within 25 % on average (R6's
    /// half resolution and upsample, the jitter, bloom, and the light the
    /// GPU adds from the Sun and the cluster's own light on its smoke).
    func testMarchMatchesTheReference() throws {
        let s = try snapper()
        let engine = PlumeTestEngine(engine: "F-1", position: [0, 0, 40], altitude: 0)
        let shot = Self.lookDev([engine]) { $0.turbulence = false }
        let out = try s.render(shot)
        let light = try XCTUnwrap(out.light)
        let scene = shot.scene(try shot.prepare(system: s.system))
        var settings = PlumeSettings()
        settings.turbulence = false
        let members = PlumeLook.members(engine, in: EffectTargetFrame(scene: scene), settings: settings)
        let m = try XCTUnwrap(members.first)
        var ratios: [Double] = []
        let column = Double(shot.width / 2)
        for row in 0..<shot.height {
            let d = Self.ray(scene, x: column, y: Double(row))
            // Where the ray passes the axis.
            let w0 = -m.exit, b = d.dot(m.axis), dd = d.dot(w0), e = m.axis.dot(w0)
            let t = (b * e - dd) / max(1 - b * b, 1e-9)
            let x = (d * t - m.exit).dot(m.axis)
            guard x > 2 * m.exitDiameter, x < 12 * m.exitDiameter else { continue }
            let reference = PlumeLook.march(members, from: .zero, direction: d, range: (t - 40)...(t + 40), steps: 4_000)
            let i = 4 * (row * shot.width + Int(column))
            let gpu = 0.2126 * Double(light[i]) + 0.7152 * Double(light[i + 1]) + 0.0722 * Double(light[i + 2])
            ratios.append(gpu / max(reference.radiance.luminance, 1e-9))
        }
        XCTAssertGreaterThan(ratios.count, 5)
        let mean = ratios.reduce(0, +) / Double(max(ratios.count, 1))
        print(String(format: "PlumeRenderTests: GPU over reference %.3f over %d rows (%.3f-%.3f)", mean, ratios.count,
                     ratios.min() ?? 0, ratios.max() ?? 0))
        XCTAssertEqual(mean, 1, accuracy: 0.25, "GPU over reference: \(ratios)")
    }

    /// P2 writes the plume lights into the lighting uniforms in P0, as
    /// `PlumeLights` gives them: one for the five F-1s at first motion.
    func testPlumeLightsReachTheVesselPass() throws {
        let s = try snapper()
        var shot = SnapshotSpec.Shot(name: "p2-lights", scenario: "as506-pad", advance: ["met:2"],
                                     camera: SnapshotSpec.CameraSpec(yaw: 149, pitch: -2, distance: 62, fov: 62))
        shot.width = 160
        shot.height = 100
        shot.showOrbit = false
        _ = try s.render(shot)
        let r = try s.renderer(userTextures: false)
        let system = try XCTUnwrap(r.graph.passes.compactMap { ($0 as? PlumePreparePass)?.system }.first)
        XCTAssertEqual(system.frame.lights.count, 1, "the five F-1s as one light")
        let scene = shot.scene(try shot.prepare(system: s.system))
        let expected = try XCTUnwrap(PlumeLights.lights(scene).first)
        XCTAssertEqual(system.frame.lights[0].luminousIntensity, expected.luminousIntensity,
                       accuracy: 1e-3 * expected.luminousIntensity)
        XCTAssertTrue(system.lastClusters.contains { $0.detail == .march })
    }

    /// Quality off draws no plume; a J-2 in vacuum is nearly black, and
    /// readable it shows.
    func testOffAndReadable() throws {
        let s = try snapper()
        let j2 = PlumeTestEngine(engine: "J-2", position: [0, 0, 25], pressure: 0)
        func total(_ shot: SnapshotSpec.Shot) throws -> Double {
            let light = try XCTUnwrap(try s.render(shot).light)
            return stride(from: 0, to: light.count, by: 4).reduce(0.0) { $0 + Double(light[$1 + 1]) }
        }
        let physical = try total(Self.lookDev([j2], distance: 90, ev: 14))
        let readable = try total(Self.lookDev([j2], distance: 90, ev: 14) { $0.readable = true })
        let off = try total(Self.lookDev([j2], distance: 90, ev: 14) { $0.readable = true; $0.quality = .off })
        XCTAssertEqual(off, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(readable, 100 * max(physical, 1e-6))
    }

    /// Apollo 7's SPS a few seconds into its deorbit burn, at night: the
    /// extension glows on its drawn bell, warm, where it is on and not off.
    func testSPSExtensionGlows() throws {
        let s = try snapper()
        var shot = SnapshotSpec.Shot(name: "p2-sps", scenario: "apollo7-deorbit", advance: ["throttle:1", "wait:8"],
                                     camera: SnapshotSpec.CameraSpec(yaw: 200, pitch: 10, distance: 14, fov: 50))
        shot.width = 160
        shot.height = 100
        shot.showOrbit = false
        shot.settings.post.exposure.mode = .manual
        shot.settings.post.exposure.ev100 = 4
        let on = try XCTUnwrap(try s.render(shot).light)
        shot.settings.plume.nozzleGlow = false
        let off = try XCTUnwrap(try s.render(shot).light)
        var red = 0.0, blue = 0.0, lit = 0
        for i in stride(from: 0, to: on.count, by: 4) {
            let dr = Double(on[i] - off[i]), db = Double(on[i + 2] - off[i + 2])
            if dr > 1 { lit += 1 }
            red += dr
            blue += db
        }
        XCTAssertGreaterThan(lit, 20, "pixels of the bell glow")
        XCTAssertGreaterThan(red, 5 * max(blue, 0), "a dull red glow")
    }
}
