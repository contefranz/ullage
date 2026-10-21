import Foundation
import Metal
import XCTest
import OrbitScene
@testable import OrbitRender

/// Renders every shot of the specs in docs/look/shots that have goldens and
/// compares it with `Goldens/<gpu family>/<shot>.png`: mean linear error
/// under 0.5 % and the 99.5th percentile of ΔE76 under 3. Look-dev goldens
/// fail the test; scene goldens are reported (and fail only with
/// ORBITSIM_STRICT_GOLDENS=1), as the plan's golden policy has it. Other GPU
/// families skip the comparison. ORBITSIM_UPDATE_GOLDENS=1 rewrites them.
@MainActor
final class GoldenImageTests: XCTestCase {
    static let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let shots = here.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/look/shots")

    func testGoldens() throws {
        let device = try XCTUnwrap(RenderDevice.shared, "no Metal device")
        let env = ProcessInfo.processInfo.environment
        let update = env["ORBITSIM_UPDATE_GOLDENS"] == "1", strict = env["ORBITSIM_STRICT_GOLDENS"] == "1"
        let goldens = Self.here.appendingPathComponent("Goldens/\(GPUFamily.name(device))")
        if !update, !FileManager.default.fileExists(atPath: goldens.path) {
            throw XCTSkip("no goldens for \(GPUFamily.name(device))")
        }
        let specs = try FileManager.default.contentsOfDirectory(at: Self.shots, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let snapper = try SnapshotRenderer(device: device)
        let failures = FileManager.default.temporaryDirectory.appendingPathComponent("orbitsim-golden-failures")
        var compared = 0
        for url in specs {
            let spec = try SnapshotSpec.load(url)
            guard spec.goldens != .none else { continue }
            for var shot in spec.shots {
                shot.aovs = []
                let out = try snapper.render(shot)
                let file = goldens.appendingPathComponent("\(shot.name).png")
                if update {
                    try FileManager.default.createDirectory(at: goldens, withIntermediateDirectories: true)
                    try ImageFiles.writePNG(out.pixels, width: shot.width, height: shot.height, order: .bgra, to: file)
                    continue
                }
                guard let golden = try? ImageFiles.readPNG(file) else {
                    XCTFail("\(url.lastPathComponent): no golden \(file.lastPathComponent)")
                    continue
                }
                let mine = ImageFiles.rgba(fromBGRA: out.pixels)
                XCTAssertEqual([golden.width, golden.height], [shot.width, shot.height], shot.name)
                guard golden.pixels.count == mine.count else { continue }
                compared += 1
                let c = ImageMetrics.compare(golden.pixels, mine)
                let summary = String(format: "%@ (%@ golden): mean %.4f%%, p99.5 ΔE %.2f, max ΔE %.1f, %d px differ",
                                     shot.name, spec.goldens.rawValue, c.meanLinearError * 100, c.p995DeltaE,
                                     c.maxDeltaE, c.differingPixels)
                print(summary)
                guard !c.withinGoldenTolerance else { continue }
                try FileManager.default.createDirectory(at: failures, withIntermediateDirectories: true)
                try ImageFiles.writePNG(mine, width: shot.width, height: shot.height, order: .rgba,
                                        to: failures.appendingPathComponent("\(shot.name).png"))
                try ImageFiles.writePNG(ImageMetrics.difference(golden.pixels, mine), width: shot.width,
                                        height: shot.height, order: .rgba,
                                        to: failures.appendingPathComponent("\(shot.name).diff.png"))
                if spec.goldens == .lookDev || strict {
                    XCTFail("out of tolerance: \(summary); render and diff in \(failures.path)")
                } else {
                    print("REPORT ONLY: scene golden out of tolerance: \(summary); render and diff in \(failures.path)")
                }
            }
        }
        if !update { XCTAssertGreaterThan(compared, 0, "no golden compared") }
    }
}
