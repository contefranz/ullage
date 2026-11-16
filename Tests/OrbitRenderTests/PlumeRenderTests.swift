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
    /// air, no clouds, no probe, manual exposure.
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
        shot.settings.probe.enabled = false
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
    /// exit diameters; their luminances agree within 10 % on average (R6's
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
        XCTAssertEqual(mean, 1, accuracy: 0.1, "GPU over reference: \(ratios)")
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

    /// An impostor's stations are the light the reference march gives along
    /// the camera's own ray through the axis there, Sun in front of the
    /// camera or behind it: the same phase as the march (whose convention
    /// the GPU shares, `testMarchMatchesTheReference`), so a cluster does
    /// not change brightness as it crosses from impostor to march. A
    /// sunlit S-IC retro in vacuum (alumina smoke, g 0.6), side-on 60 m
    /// ahead; the ambient a mean radiance, which the impostor's fragment
    /// adds through the station's response, as the march takes it.
    func testImpostorLightsAsTheMarch() throws {
        let spec = ApolloExhaust.sICRetro.spec
        let state = PlumeModel.state(spec, flowFraction: 1, ambient: .vacuum)
        let m = PlumeLook.member(spec, state: state, exit: Vec3(-3, 0, -60), axis: Vec3(1, 0, 0),
                                 exitRadius: spec.exitRadius, ambient: .vacuum)
        let lux = Photometry.sunColor.scaled(by: 1.3e5), ambient = Photometry.RGB(300, 330, 380)
        var seen: [Double] = []
        for toSun in [Vec3(0.3, 0.2, -1).normalized, Vec3(0.3, 0.2, 1).normalized] {
            var strip: [PlumeVertex] = []
            Plumes.impostor(m, sun: (toSun, lux), to: &strip)
            // The station at a fifth of the length: its two vertices.
            let station = strip[6 * 4 + 2]
            let p = Vec3(Double(station.position.x), Double(station.position.y), Double(station.position.z))
            let x = (p - m.exit).dot(m.axis)
            let c = m.exit + m.axis * x, view = c.normalized
            let e = m.extent(atX: x)
            let reference = PlumeLook.march([m], from: c - view * (2 * e), direction: view, range: 0...(4 * e),
                                            steps: 400, sun: (toSun, lux), ambient: ambient.scaled(by: 4 * Double.pi))
            // The fragment adds the ambient's in-scatter (isotropic here: its
            // mean radiance) times the station's response.
            let got = 0.2126 * Double(station.color.x) + 0.7152 * Double(station.color.y) + 0.0722 * Double(station.color.z)
                + Double(station.shape.z) * ambient.luminance
            XCTAssertEqual(got / reference.radiance.luminance, 1, accuracy: 0.1, "Sun \(toSun)")
            seen.append(got)
        }
        // Forward scatter (the Sun ahead) is the brighter, by far.
        XCTAssertGreaterThan(seen[0], 3 * seen[1])
    }

    /// R2's line light clipped to the receiver's horizon (Karis 2013): a
    /// vertical jet passing below an up-facing surface h off its axis,
    /// reaching a above it and b below, of intensity I spread along it,
    /// lights it as the part above does, (I/L)(1/h - 1/√(h² + a²)); one
    /// wholly above as the whole; one wholly below not at all. The pad's
    /// deck and hardstand at first motion.
    func testLineLightLightsFromAboveTheHorizon() throws {
        let device = try XCTUnwrap(RenderDevice.shared)
        let module = ShaderModule(name: "LineLightTest", headers: [.shadowCommon, .lightingCommon], source: """
            kernel void line_light_test(const device LocalLight *lights [[buffer(0)]], device float4 *out [[buffer(1)]],
                                        uint i [[thread_position_in_grid]]) {
                OrbitShadingPoint p;
                p.n = float3(0.0, 0.0, 1.0);
                p.v = float3(0.0, 0.0, 1.0);
                p.nv = 1.0;
                p.alpha = 0.5;
                p.roughness = sqrt(0.5);
                p.f0 = float3(0.0);
                p.diffuse = float3(1.0);
                p.dfg = float2(0.0);
                p.energy = float3(0.0);
                p.specularWeight = float3(0.0);
                p.diffuseWeight = float3(0.0);
                p.diffuseLobe = float3(1.0);
                out[i] = float4(orbit_lineLight(p, float3(0.0), lights[i]) * ORBIT_PI, 0.0);
            }
            """)
        let library = try ShaderLibrary(device: device).library(module)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "line_light_test")))
        let h = 10.0, intensity = 1e6
        let cases: [(a: Double, b: Double)] = [(10, 30), (30, 10), (20, 0), (40, 2), (-5, 40)]
        let lights = cases.map { c -> LocalLight in
            var l = LocalLight()
            l.positionRadius = SIMD4(Float(h), 0, Float(0.5 * (c.a - c.b)), 1e-3)
            l.axisLength = SIMD4(0, 0, 1, Float(c.a + c.b))
            l.intensity = SIMD4(Float(intensity), Float(intensity), Float(intensity), 0)
            return l
        }
        let stride = MemoryLayout<LocalLight>.stride
        let inBuffer = try XCTUnwrap(device.makeBuffer(bytes: lights, length: stride * lights.count, options: .storageModeShared))
        let outBuffer = try XCTUnwrap(device.makeBuffer(length: 16 * lights.count, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer()), enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(inBuffer, offset: 0, index: 0)
        enc.setBuffer(outBuffer, offset: 0, index: 1)
        enc.dispatchThreads(MTLSize(width: lights.count, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: lights.count, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let out = outBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: lights.count)
        for (i, c) in cases.enumerated() {
            // The part from the surface's plane up to a lights it.
            let expected = c.a <= 0 ? 0 : intensity / (c.a + c.b) * (1 / h - 1 / (h * h + c.a * c.a).squareRoot())
            XCTAssertEqual(Double(out[i].y), expected, accuracy: 0.01 * max(expected, 1), "a \(c.a), b \(c.b)")
        }
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
