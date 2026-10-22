import Foundation
import Metal
import XCTest
import OrbitCore
import OrbitScene
@testable import OrbitRender

/// Track R2's look-dev goldens, hard tests (the plan's golden policy): the
/// material spheres and the Saturn V's side, `LookDevScenes`, rendered as
/// the app renders (4× MSAA into the drawable's format) and compared with
/// `Goldens/<gpu family>/r2-*.png`: mean linear error under 0.5 % and the
/// 99.5th percentile of ΔE76 under 3. Other GPU families skip the
/// comparison. ORBITSIM_UPDATE_GOLDENS=1 rewrites them; ORBITSIM_LOOKDEV_DIR
/// writes the renders and a contact sheet there.
@MainActor
final class ShadingLookDevTests: XCTestCase {
    static let goldens = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Goldens")

    /// Ambient occlusion baked before the frame, as the app bakes it (its
    /// rays are seeded: one result in every build), and a fixed exposure,
    /// EV 15 ("sunny 16"), through R1's default tone curve.
    static var settings: RenderSettings {
        var s = RenderSettings()
        s.shading.waitForAmbientOcclusion = true
        s.post.exposure.mode = .manual
        s.post.exposure.ev100 = 15
        return s
    }

    func testLookDevGoldens() throws {
        let device = try XCTUnwrap(RenderDevice.shared, "no Metal device")
        let env = ProcessInfo.processInfo.environment
        let update = env["ORBITSIM_UPDATE_GOLDENS"] == "1"
        let folder = Self.goldens.appendingPathComponent(GPUFamily.name(device))
        let r = try SceneRenderer(device: device, loadsUserTextures: false)
        r.settings = Self.settings
        var sheet = ContactSheet()
        var compared = 0
        for (name, scene) in [("r2-material-spheres", LookDevScenes.materialSpheres()),
                              ("r2-saturn-v-side", LookDevScenes.saturnVSide())] {
            let w = Int(scene.camera.viewport.width), h = Int(scene.camera.viewport.height)
            let target = try XCTUnwrap(OffscreenTarget(device: device, width: w, height: h))
            r.renderAndWait(scene, into: target)
            XCTAssertEqual(r.failures, [:])
            let pixels = target.bytes()
            if let dir = env["ORBITSIM_LOOKDEV_DIR"] {
                let url = URL(fileURLWithPath: dir)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try ImageFiles.writePNG(pixels, width: w, height: h, order: .bgra,
                                        to: url.appendingPathComponent("\(name).png"))
                if let image = ImageFiles.cgImage(pixels, width: w, height: h, order: .bgra) {
                    sheet.rows.append([ContactSheet.Cell(image: image, caption: name)])
                }
            }
            let file = folder.appendingPathComponent("\(name).png")
            if update {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try ImageFiles.writePNG(pixels, width: w, height: h, order: .bgra, to: file)
                continue
            }
            guard FileManager.default.fileExists(atPath: folder.path) else {
                throw XCTSkip("no goldens for \(GPUFamily.name(device))")
            }
            let golden = try ImageFiles.readPNG(file)
            XCTAssertEqual([golden.width, golden.height], [w, h], name)
            let c = ImageMetrics.compare(golden.pixels, ImageFiles.rgba(fromBGRA: pixels))
            print(String(format: "%@ (lookdev golden): mean %.4f%%, p99.5 ΔE %.2f, max ΔE %.1f, %d px differ", name,
                         c.meanLinearError * 100, c.p995DeltaE, c.maxDeltaE, c.differingPixels))
            XCTAssertTrue(c.withinGoldenTolerance, "\(name): mean \(c.meanLinearError), p99.5 ΔE \(c.p995DeltaE)")
            compared += 1
        }
        if let dir = env["ORBITSIM_LOOKDEV_DIR"], !sheet.rows.isEmpty {
            try sheet.write(to: URL(fileURLWithPath: dir).appendingPathComponent("contact.jpg"))
        }
        if !update { XCTAssertEqual(compared, 2) }
    }
}
