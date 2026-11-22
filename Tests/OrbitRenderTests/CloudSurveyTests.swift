import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// The clouds as the app draws them (ORBITSIM_CLOUD_SURVEY=<dir>): each
/// scenario flown frame by frame through the app's own path (Simulation,
/// SceneExtractor, the default passes, auto exposure, reprojection), the
/// last frame written as `<flight>.png`, and at warp a second frame a tick
/// later (`<flight>-b.png`) with the two frames' mean difference printed,
/// for flicker. ORBITSIM_CLOUD_SURVEY_WEATHER (default "random") and
/// ORBITSIM_WEATHER_SEED (default 1) choose the sky;
/// ORBITSIM_CLOUD_SURVEY_ONLY a comma-separated list of flights;
/// ORBITSIM_CLOUD_SETTINGS other CloudSettings (JSON); ORBITSIM_CLOUD_SURVEY_FRAMES
/// frames to write as well (`<flight>-frame<k>.png`).
@MainActor
final class CloudSurveyTests: XCTestCase {
    struct Flight {
        var name: String
        var scenario: String
        var advance: [String] = []
        var camera: SnapshotSpec.CameraSpec
        var warp = 1.0
        var frames = 90
    }

    static let flights: [Flight] = [
        Flight(name: "pad", scenario: "as506-first-motion", camera: .init(yaw: -60, pitch: 12, distance: 300, fov: 60), frames: 60),
        Flight(name: "pad-up", scenario: "as506-first-motion", camera: .init(yaw: -60, pitch: -35, distance: 120, fov: 70), frames: 60),
        Flight(name: "ascent-10km", scenario: "as506-pad", advance: ["met:75"],
               camera: .init(yaw: 149, pitch: -15, distance: 400, fov: 60), frames: 60),
        Flight(name: "ascent-30km", scenario: "as506-pad", advance: ["met:118"],
               camera: .init(yaw: 149, pitch: -20, distance: 400, fov: 60), frames: 60),
        Flight(name: "ascent-60km", scenario: "as506-pad", advance: ["met:150"],
               camera: .init(yaw: 149, pitch: -25, distance: 400, fov: 60), frames: 60),
        Flight(name: "leo-day", scenario: "as506-parking-orbit", camera: .init(yaw: -34.4, pitch: 30, distance: 70, fov: 60)),
        Flight(name: "leo-down", scenario: "as506-parking-orbit", camera: .init(yaw: -34.4, pitch: 70, distance: 70, fov: 40)),
        Flight(name: "leo-terminator", scenario: "as506-parking-orbit", advance: ["wait:1650"],
               camera: .init(yaw: 0, pitch: 12, distance: 70, fov: 70)),
        Flight(name: "leo-night", scenario: "as506-parking-orbit", advance: ["wait:2400"],
               camera: .init(yaw: 0, pitch: 30, distance: 70, fov: 70)),
        Flight(name: "leo-100x", scenario: "as506-parking-orbit", camera: .init(yaw: -34.4, pitch: 30, distance: 70, fov: 60),
               warp: 100),
        Flight(name: "leo-1000x", scenario: "as506-parking-orbit", camera: .init(yaw: -34.4, pitch: 30, distance: 70, fov: 60),
               warp: 1000),
        Flight(name: "earth-8000km", scenario: "as506-parking-orbit",
               camera: .init(target: "body:399", frame: "inertial", yaw: 223.5, pitch: 22.9, distance: 14_378_000, fov: 60),
               frames: 30),
    ]

    func testSurvey() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["ORBITSIM_CLOUD_SURVEY"] else { throw XCTSkip("set ORBITSIM_CLOUD_SURVEY=<dir> to fly") }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let only = env["ORBITSIM_CLOUD_SURVEY_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let dump = Set((env["ORBITSIM_CLOUD_SURVEY_FRAMES"] ?? "").split(separator: ",").compactMap { Int($0) })
        let s = try SnapshotRenderer(device: try XCTUnwrap(RenderDevice.shared))
        let width = 1280, height = 800
        let viewport = RenderScene.Viewport(width: Double(width), height: Double(height), pointScale: 2)
        for f in Self.flights where only?.contains(f.name) ?? true {
            let scenario = try XCTUnwrap(Scenario.named(f.scenario))
            let sim = scenario.build(s.system)
            if !f.advance.isEmpty { try ScenarioScript(f.advance).run(on: sim, missionClockZero: scenario.missionClockZero) }
            sim.paused = false
            sim.warp = f.warp
            var camera = OrbitCamera()
            try f.camera.apply(to: &camera, sim: sim)
            let extractor = SceneExtractor()
            let capture = CloudRenderTests.Capture()
            let r = try SceneRenderer(device: s.device, outputFormat: .bgra8Unorm_srgb,
                                      passes: SceneRenderer.defaultPasses(loadsUserTextures: false) + [capture],
                                      plan: HDRTargetPlan(outputFormat: .bgra8Unorm_srgb, sampleCount: 4))
            r.setStars(s.stars)
            r.settings.cloud.weather = env["ORBITSIM_CLOUD_SURVEY_WEATHER"] ?? "random"
            r.settings.cloud.seed = Int(env["ORBITSIM_WEATHER_SEED"] ?? "") ?? 1
            r.settings.particle.quality = .off
            if env["ORBITSIM_CLOUD_SURVEY_NO_AIR"] != nil { r.settings.atmosphere.enabled = false }
            if let json = env["ORBITSIM_CLOUD_SETTINGS"] {
                var c = try JSONDecoder().decode(CloudSettings.self, from: Data(json.utf8))
                c.weather = r.settings.cloud.weather
                c.seed = r.settings.cloud.seed
                r.settings.cloud = c
            }
            let target = try XCTUnwrap(OffscreenTarget(device: s.device, width: width, height: height))
            var previous: [UInt8]?
            let start = Date()
            for k in 0..<f.frames {
                if k > 0 { sim.advance(by: 1.0 / 60) }
                camera.update(sim: sim)
                let scene = extractor.extract(sim: sim, camera: camera, viewport: viewport, realTime: Double(k) / 60,
                                              options: SceneExtractor.Options(showOrbit: false))
                _ = r.renderAndWait(scene, into: target)
                if k == f.frames - 2 { previous = target.bytes() }
                if dump.contains(k) {
                    try ImageFiles.writePNG(target.bytes(), width: width, height: height, order: .bgra,
                                            to: out.appendingPathComponent("\(f.name)-frame\(k).png"))
                }
            }
            let last = target.bytes()
            try ImageFiles.writePNG(last, width: width, height: height, order: .bgra,
                                    to: out.appendingPathComponent("\(f.name).png"))
            // The march's resolved layer and R6's half-resolution clouds: their
            // luminance (over its 99th percentile) in red and green, their
            // opacity in blue.
            for (id, label) in [(ResourceID.cloudLayer, "march"), (.halfResClouds, "halfres")] {
                guard let v = capture.values(id) else { continue }
                var grey = [UInt8](repeating: 255, count: 4 * v.width * v.height)
                let lum = v.texels.map { $0.count == 4 ? 0.2126 * $0[0] + 0.7152 * $0[1] + 0.0722 * $0[2] : 0 }
                let top = max(lum.sorted()[lum.count * 99 / 100], 1e-9)
                for (i, t) in v.texels.enumerated() where t.count == 4 {
                    let g = UInt8(min(max(lum[i] / top, 0), 1) * 255)
                    grey[4 * i] = g
                    grey[4 * i + 1] = g
                    grey[4 * i + 2] = UInt8(min(max(t[3], 0), 1) * 255)
                }
                try ImageFiles.writePNG(grey, width: v.width, height: v.height, order: .bgra,
                                        to: out.appendingPathComponent("\(f.name)-\(label).png"))
            }
            // The march's depths (log2 of the linear depth): front, mean and
            // entry as red, green and blue over their range.
            if let v = capture.values(.cloudDepth) {
                var img = [UInt8](repeating: 255, count: 4 * v.width * v.height)
                let finite = v.texels.flatMap { $0.prefix(3) }.filter { $0 < 59 }
                let lo = finite.min() ?? 0, hi = max(finite.max() ?? 1, lo + 1e-3)
                for (i, t) in v.texels.enumerated() where t.count == 4 {
                    func c(_ x: Double) -> UInt8 { x >= 59 ? 0 : UInt8(min(max((x - lo) / (hi - lo), 0), 1) * 254 + 1) }
                    img[4 * i + 2] = c(t[0])
                    img[4 * i + 1] = c(t[1])
                    img[4 * i] = c(t[2])
                }
                print(String(format: "SURVEY %@ depths: log2 %.2f-%.2f", f.name, lo, hi))
                try ImageFiles.writePNG(img, width: v.width, height: v.height, order: .bgra,
                                        to: out.appendingPathComponent("\(f.name)-depths.png"))
            }
            var flicker = ""
            if let previous, f.warp > 1 {
                try ImageFiles.writePNG(previous, width: width, height: height, order: .bgra,
                                        to: out.appendingPathComponent("\(f.name)-b.png"))
                var sum = 0.0
                for i in stride(from: 0, to: last.count, by: 4) {
                    sum += abs(Double(last[i]) - Double(previous[i])) + abs(Double(last[i + 1]) - Double(previous[i + 1]))
                        + abs(Double(last[i + 2]) - Double(previous[i + 2]))
                }
                flicker = String(format: ", frame-to-frame %.2f/255", sum / Double(3 * width * height))
            }
            print(String(format: "SURVEY %@: %d frames in %.1f s%@", f.name, f.frames, Date().timeIntervalSince(start), flicker))
        }
    }
}
