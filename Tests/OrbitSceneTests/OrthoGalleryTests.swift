import Foundation
import XCTest
@testable import OrbitCore

/// The Linux ortho gallery: `ORBITSIM_ORTHO_DIR=<dir> swift test --filter
/// OrthoGallery` writes flat-lit orthographic PNGs of today's Saturn V and
/// CSMs into <dir>, which a cloud session opens with its Read tool, and
/// `index.txt` saying what each shows and where each panel sits in its
/// file (`OrthoSheet`), so that pixels map back to stations. Without the
/// variable the test is skipped. Each file is read back and must decode to
/// the image written.
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

        var index = OrthoSheet.indexHeader
        for entry in entries {
            let sheet = OrthoSheet(entry.images)
            let url = dir.appendingPathComponent(entry.file)
            try PNG.write(sheet.image, to: url)
            XCTAssertEqual(try PNG.read(url), sheet.image, entry.file)
            index.append(sheet.indexLine(file: entry.file, what: entry.what))
        }
        try (index.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("index.txt"), atomically: true,
                                                        encoding: .utf8)
        print("Ortho gallery: \(entries.count) files in \(dir.path)")
    }

    /// What a session reading the gallery does, on a toy: it finds a red
    /// marker's pixels in a sheet of Positions I-IV, takes the panel each
    /// lies in and its numbers from the sheet's `index.txt` line, and maps
    /// them back by the header's formula. They land on the marker's
    /// stations and sides in every panel that sees it; the border and
    /// gutters show the panels' edges; a single image is its own panel.
    func testIndexLineMapsSheetPixelsBack() throws {
        // A cylinder of radius 1 from x = 0 to 4, and a red box from x = 1.5
        // to 2.5 at Position II, y from -1.5 to -1, z from -0.25 to 0.25.
        let body = VisualShape.frustum(from: .zero, length: 4, baseRadius: 1, topRadius: 1, color: (0.8, 0.8, 0.8))
        let marker = VisualShape.box(from: Vec3(1.5, -1.25, 0), length: 1, width: 0.5, height: 0.5, color: (1, 0, 0))
        let scene = OrthoScene(shapes: [body, marker])
        let k = 20.0
        let style = OrthoStyle(lighting: .albedo, outlines: false, annotations: true)
        let sheet = OrthoSheet((1...4).map { OrthoRaster.render(scene, .position($0, scale: k), style: style) })

        // The line as a session reads it: n, X0, Y0, width, height, left, top a panel.
        let fields = sheet.indexLine(file: "toy.png", what: "a toy").components(separatedBy: "\t")
        XCTAssertEqual(Array(fields.prefix(3)), ["toy.png", "a toy", "20.0 px/m"])
        let panels = fields.dropFirst(3).map(numbers)
        XCTAssertEqual(panels.count, 4)
        for (i, p) in panels.enumerated() { XCTAssertEqual(p.count, 7, fields[3 + i]) }
        guard panels.allSatisfy({ $0.count == 7 }) else { return }
        XCTAssertEqual(panels[0][1...2], [8, 8], "the first panel sits inside the 8 px border")

        // Each red pixel's panel, from the line's rectangles, and its place:
        // per panel the least and most right, then up, of the pixels' centres.
        var extent = [[Double]?](repeating: nil, count: 4)
        for y in 0..<sheet.image.height {
            for x in 0..<sheet.image.width where sheet.image[x, y] == (255, 0, 0) {
                let column = Double(x), row = Double(y)
                let inside = panels.indices.filter { i in
                    let p = panels[i]
                    let across = column >= p[1] && column < p[1] + p[3]
                    return across && row >= p[2] && row < p[2] + p[4]
                }
                XCTAssertEqual(inside.count, 1, "pixel (\(x), \(y)) is in one panel")
                guard let i = inside.first else { continue }
                let p = panels[i]
                let right: Double = p[5] + (column - p[1] + 0.5) / k
                let up: Double = p[6] - (row - p[2] + 0.5) / k
                let s = try XCTUnwrap(sheet.screen(x, y))
                XCTAssertEqual(s.panel, i)
                XCTAssertEqual(s.right, right, accuracy: 1e-3)
                XCTAssertEqual(s.up, up, accuracy: 1e-3)
                let e = extent[i] ?? [right, right, up, up]
                extent[i] = [min(e[0], right), max(e[1], right), min(e[2], up), max(e[3], up)]
            }
        }
        // Seen from I, II on the right; from II, facing; from III, on the
        // left; from IV, hidden. From x = 1.5 to 2.5 in all of them.
        let sides: [[Double]?] = [[1, 1.5], [-0.25, 0.25], [-1.5, -1], nil]
        for (i, side) in sides.enumerated() {
            guard let side else {
                XCTAssertNil(extent[i], "Position \(i + 1)")
                continue
            }
            let e = try XCTUnwrap(extent[i], "Position \(i + 1)")
            for (measured, expected) in zip(e, side + [1.5, 2.5]) {
                XCTAssertEqual(measured, expected, accuracy: 1 / k, "Position \(i + 1)")
            }
        }

        // The border and the gutters are not the background.
        let g = OrthoSheet.gutter
        XCTAssertTrue(g != style.background)
        XCTAssertTrue(sheet.image[0, 0] == g)
        for i in 1..<4 {
            let x = Int(panels[i][1]) - 1
            XCTAssertTrue((0..<sheet.image.height).allSatisfy { sheet.image[x, $0] == g }, "the gutter before panel \(i + 1)")
        }

        let single = OrthoSheet([OrthoRaster.render(scene, OrthoView(.top, scale: k), style: style)])
        XCTAssertEqual(single.image, single.panels[0].image)
        let field = try XCTUnwrap(single.indexLine(file: "toy-top.png", what: "a toy").components(separatedBy: "\t").last)
        XCTAssertEqual(numbers(field)[0...2], [1, 0, 0])
    }

    /// The numbers in `text`, in order.
    func numbers(_ text: String) -> [Double] {
        let pattern = try! NSRegularExpression(pattern: "-?[0-9]+(\\.[0-9]+)?")
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).flatMap { Double(text[$0]) }
        }
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
