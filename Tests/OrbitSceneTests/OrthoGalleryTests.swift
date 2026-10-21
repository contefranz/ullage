import Foundation
import XCTest
@testable import OrbitCore

/// The Linux ortho gallery: `ORBITSIM_ORTHO_DIR=<dir> swift test --filter
/// OrthoGallery` writes flat-lit orthographic PNGs of today's Saturn V and
/// CSMs into <dir>, which a cloud session opens with its Read tool, and
/// `index.txt` saying what each shows. Without the variable the test is
/// skipped. Each file is read back and must decode to the image written.
///
/// Side views have station ticks every 100 in STA (labelled every 500 in;
/// Xa = STA - 2756.56) and the Positions' numerals: the one facing the
/// viewer at the top, the ones seen edge-on at the sides.
final class OrthoGalleryTests: XCTestCase {
    struct Entry {
        let file: String
        let what: String
        let images: [OrthoImage]
    }

    func testOrthoGallery() throws {
        guard let path = ProcessInfo.processInfo.environment["ORBITSIM_ORTHO_DIR"], !path.isEmpty else {
            throw XCTSkip("set ORBITSIM_ORTHO_DIR to a directory to write the ortho gallery")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var entries: [Entry] = []
        let sta = AS506.station
        let stack = OrthoScene(VesselLibrary.saturnV())
        entries += vesselViews("saturn-v", "Saturn V (Apollo 11, AS-506), as on the pad", stack, side: 14, end: 40)
        let crops: [(String, String, ClosedRange<Double>, Double)] = [
            ("sic-base", "S-IC base and F-1s, STA -120 to 560", sta(-120)...sta(560), 50),
            ("sic-sii-interstage", "S-IC forward skirt, interstage, S-II aft skirt, STA 1400 to 1950",
             sta(1400)...sta(1950), 40),
            ("sii-sivb-interstage", "S-II forward skirt, interstage, S-IVB aft skirt and APS, STA 2450 to 2900",
             sta(2450)...sta(2900), 50),
            ("spacecraft", "IU, SLA, CSM and LES, STA 3150 to 4245", sta(3150)...sta(4245), 40),
        ]
        for (name, what, band, scale) in crops {
            entries.append(Entry(file: "saturn-v-\(name)-positions.png", what: "\(what), Positions I-IV",
                                 images: (1...4).map { OrthoRaster.render(stack, .position($0, scale: scale, stations: band)) }))
        }
        entries.append(Entry(file: "saturn-v-sic-base-bottom.png",
                             what: "S-IC base seen from below, cut at STA 130 (the engines and the base)",
                             images: [OrthoRaster.render(stack, OrthoView(.bottom, scale: 60, stations: sta(-120)...sta(130)))]))
        entries.append(Entry(file: "saturn-v-sic-section-top.png",
                             what: "S-IC seen from above, cut at STA 400 (the base region from above)",
                             images: [OrthoRaster.render(stack, OrthoView(.top, scale: 60, stations: sta(-120)...sta(400)))]))
        for mission in ApolloCM.Mission.allCases {
            let csm = OrthoScene(VesselLibrary.apolloCSM(mission))
            let slug = mission.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
            entries += vesselViews("csm-\(slug)", "The CSM alone (\(mission.rawValue)), after CSM/LV separation",
                                   csm, side: 80, end: 100)
        }

        var index = ["# Ortho gallery: file, what it shows, scale (px/m), each panel's top-left corner as",
                     "# (right, up) in the view's screen frame (m; a side view's up is construction x, STA = x / 0.0254).",
                     "# Panels of a sheet sit side by side, 8 px apart."]
        for entry in entries {
            let image = entry.images.count == 1
                ? entry.images[0].image : RGBImage.row(entry.images.map(\.image), fill: OrthoStyle().background)
            let url = dir.appendingPathComponent(entry.file)
            try PNG.write(image, to: url)
            XCTAssertEqual(try PNG.read(url), image, entry.file)
            let corners = entry.images.map { String(format: "(%.3f, %.3f)", $0.left, $0.top) }.joined(separator: " ")
            index.append("\(entry.file)\t\(entry.what)\t\(entry.images[0].view.scale) px/m\t\(corners)")
        }
        try (index.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("index.txt"), atomically: true,
                                                        encoding: .utf8)
        print("Ortho gallery: \(entries.count) files in \(dir.path)")
    }

    /// Positions I-IV side by side at `side` px/m, and the top and bottom
    /// at `end` px/m.
    func vesselViews(_ name: String, _ what: String, _ scene: OrthoScene, side: Double, end: Double) -> [Entry] {
        [Entry(file: "\(name)-positions.png", what: "\(what): Positions I-IV",
               images: (1...4).map { OrthoRaster.render(scene, .position($0, scale: side)) }),
         Entry(file: "\(name)-top.png", what: "\(what): from above, Position I at the bottom",
               images: [OrthoRaster.render(scene, OrthoView(.top, scale: end))]),
         Entry(file: "\(name)-bottom.png", what: "\(what): from below, Position I at the bottom",
               images: [OrthoRaster.render(scene, OrthoView(.bottom, scale: end))])]
    }
}
