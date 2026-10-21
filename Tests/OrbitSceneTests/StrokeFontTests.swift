import XCTest
@testable import OrbitScene

/// The lettering's stroke font and its layout against VD2's measured
/// letters (docs/data/markings/README.md: letter boxes from the
/// registrations, tolerance ±0.25 m in station as for every boundary).
final class StrokeFontTests: XCTestCase {
    /// ±0.25 m (owner decision 10), in.
    static let tolerance = 0.25 / 0.0254

    /// It draws "UNITED STATES" and "USA", and every text the tables ask
    /// for: the plates' numerals and the stencils.
    func testCoversTheLettering() throws {
        XCTAssertTrue(StrokeFont.covers("UNITED STATES"))
        XCTAssertTrue(StrokeFont.covers("USA"))
        for name in MarkingTable.bundledNames {
            for row in try MarkingTable.bundled(name) where row.kind == .decal {
                for key in ["text", "lines"] {
                    if let text = row.params[key] {
                        XCTAssertTrue(StrokeFont.covers(text.replacingOccurrences(of: "/", with: " ")), "\(row.id): \(text)")
                    }
                }
            }
        }
        for numeral in ["I", "II", "III", "IV"] { XCTAssertTrue(StrokeFont.covers(numeral)) }
        XCTAssertFalse(StrokeFont.covers("NASA!"))
        XCTAssertNil(StrokeFont.glyph("Q", width: 10, height: 10))
    }

    /// The ink of every letter fills its box, `letter_w` by `letter_h` (an
    /// I its stroke's width); digits fill their height.
    func testInkFillsTheLetterBox() throws {
        let width = 44.0, height = 57.0, step = 0.25
        for c in StrokeFont.characters {
            let g = try XCTUnwrap(StrokeFont.glyph(c, width: width, height: height))
            var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
            for x in stride(from: -2.0, through: width + 2, by: step) {
                for y in stride(from: -2.0, through: height + 2, by: step) where g.distance(x: x, y: y) <= 0 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            XCTAssertGreaterThanOrEqual(minX, 0, "\(c)")
            XCTAssertLessThanOrEqual(maxX, g.width, "\(c)")
            XCTAssertGreaterThanOrEqual(minY, 0, "\(c)")
            XCTAssertLessThanOrEqual(maxY, height, "\(c)")
            if c == "-" { continue }
            XCTAssertEqual(minY, 0, accuracy: 2 * step, "\(c) foot")
            XCTAssertEqual(maxY, height, accuracy: 2 * step, "\(c) top")
            if "UNITEDSAVC".contains(c) {
                XCTAssertEqual(minX, 0, accuracy: 2 * step, "\(c) left")
                XCTAssertEqual(maxX, g.width, accuracy: 2 * step, "\(c) right")
            }
        }
        XCTAssertEqual(StrokeFont.glyph("I", width: width, height: height)?.width, height * StrokeFont.strokeRatio)
        XCTAssertEqual(StrokeFont.glyph("U", width: width, height: height)?.width, width)
    }

    /// The distance is negative inside the strokes and positive in the
    /// counters and outside, and is a true distance along a straight stroke.
    func testDistanceSign() throws {
        let w = 44.0, h = 57.0, s = h * StrokeFont.strokeRatio
        let i = try XCTUnwrap(StrokeFont.glyph("I", width: w, height: h))
        XCTAssertEqual(i.distance(x: s / 2, y: h / 2), -s / 2, accuracy: 1e-9)
        XCTAssertEqual(i.distance(x: s + 3, y: h / 2), 3, accuracy: 1e-9)
        XCTAssertEqual(i.distance(x: s / 2, y: h + 2), 2, accuracy: 1e-9)
        let u = try XCTUnwrap(StrokeFont.glyph("U", width: w, height: h))
        XCTAssertGreaterThan(u.distance(x: w / 2, y: h * 0.6), 0)   // the counter
        XCTAssertLessThan(u.distance(x: w / 2, y: s / 2), 0)        // the bowl's foot
        XCTAssertLessThan(u.distance(x: s / 2, y: h * 0.8), 0)      // the left stem
        let sGlyph = try XCTUnwrap(StrokeFont.glyph("S", width: w, height: h))
        XCTAssertLessThan(sGlyph.distance(x: w / 2, y: h / 2), 0)   // the middle stroke
        XCTAssertGreaterThan(sGlyph.distance(x: w / 2, y: h * 0.75), 0)
        XCTAssertGreaterThan(sGlyph.distance(x: w / 2, y: h * 0.25), 0)
        let a = try XCTUnwrap(StrokeFont.glyph("A", width: w, height: h))
        XCTAssertLessThan(a.distance(x: w / 2, y: 0.3 * h), 0)      // the bar
        XCTAssertGreaterThan(a.distance(x: w / 2, y: 0.5 * h), 0)   // the counter
        XCTAssertGreaterThan(a.distance(x: w / 2, y: 0.05 * h), 0)  // between the legs
        let t = try XCTUnwrap(StrokeFont.glyph("T", width: w, height: h))
        XCTAssertGreaterThan(t.distance(x: s, y: h / 2), 0)
        XCTAssertLessThan(t.distance(x: s / 2, y: h - s / 2), 0)
        // Outside, the distance grows like the distance (1-Lipschitz) and
        // reaches it along a straight edge.
        for c in StrokeFont.characters {
            let g = try XCTUnwrap(StrokeFont.glyph(c, width: w, height: h))
            for k in 0..<200 {
                let x = Double(k % 20) * 3 - 5, y = Double(k / 20) * 7 - 5
                let d0 = g.distance(x: x, y: y), d1 = g.distance(x: x + 0.1, y: y)
                XCTAssertLessThanOrEqual(abs(d1 - d0), 0.1 + 1e-9, "\(c) at \(x), \(y)")
            }
        }
    }

    /// AS-503's S-II lettering (503-122), read letter by letter on
    /// S68-55424: every letter's top and foot as laid out, letters 31 in
    /// tall at the pitch that fills the box, within ±0.25 m.
    func testUnitedStatesAgainstTheMeasuredLetters() throws {
        let decal = try XCTUnwrap(Markings.scheme("AS-503")?.decals.first { $0.id == "503-122" })
        // (top, foot) of each letter, STA; T, E and D were read as one block.
        let measured: [(Double?, Double?)] = [
            (2374.5, 2345.5), (2342.9, 2310.0), (2303.4, 2278.4), (2270.5, nil), (nil, nil), (nil, 2167.7),
            (2138.8, 2107.2), (2103.2, 2074.2), (2066.3, 2037.3), (2032.1, 2000.5), (1995.2, 1962.3), (1959.6, 1924.0),
        ]
        XCTAssertEqual(String(decal.glyphs.map(\.glyph.character)), "UNITEDSTATES")
        for (g, m) in zip(decal.glyphs, measured) {
            let foot = decal.stations.lowerBound + g.y, top = foot + g.glyph.height
            XCTAssertEqual(g.glyph.height, 31, accuracy: 1e-9)
            if let t = m.0 { XCTAssertEqual(top, t, accuracy: Self.tolerance, "\(g.glyph.character) top") }
            if let f = m.1 { XCTAssertEqual(foot, f, accuracy: Self.tolerance, "\(g.glyph.character) foot") }
        }
        // The pitch that fills the box against the one measured, and the
        // word gap kept.
        XCTAssertEqual(try XCTUnwrap(decal.pitch), 35, accuracy: 2)
        let d = decal.glyphs[5], s = decal.glyphs[6]
        XCTAssertEqual(d.y - (s.y + s.glyph.height), 29, accuracy: 1e-9)
    }

    /// The USA columns (U, S and A read on three registrations): each
    /// letter's top and foot within ±0.25 m, and the S-II's letters as wide
    /// as their boxes at the S-II's radius.
    func testUSAAgainstTheMeasuredLetters() throws {
        let rows: [(String, [(Double, Double)])] = [
            ("503-100", [(589.8, 526.8), (505.5, 445.6), (423.0, 367.4)]),
            ("503-101", [(596.2, 539.0), (515.7, 458.8), (436.8, 376.8)]),
            ("503-103", [(592.5, 536.9), (509.1, 451.0), (.nan, 368.6)]),
            ("506-102", [(588.7, 535.3), (507.4, 452.3), (417.1, 371.9)]),
        ]
        for (id, letters) in rows {
            let vehicle = id.hasPrefix("503") ? "AS-503" : "AS-506"
            let decal = try XCTUnwrap(Markings.scheme(vehicle)?.decals.first { $0.id == id }, id)
            XCTAssertEqual(String(decal.glyphs.map(\.glyph.character)), "USA")
            for (g, m) in zip(decal.glyphs, letters) {
                let foot = decal.stations.lowerBound + g.y, top = foot + g.glyph.height
                if !m.0.isNaN { XCTAssertEqual(top, m.0, accuracy: Self.tolerance, "\(id) \(g.glyph.character) top") }
                XCTAssertEqual(foot, m.1, accuracy: Self.tolerance, "\(id) \(g.glyph.character) foot")
            }
            // The column is centred on the box's middle azimuth.
            let u = decal.glyphs[0]
            XCTAssertEqual(u.x + u.glyph.width / 2, decal.width / 2, accuracy: 1e-9)
            if let pitch = decal.params["pitch"].flatMap(Double.init) {
                XCTAssertEqual(try XCTUnwrap(decal.pitch), pitch, accuracy: 4, id)
            }
        }
        for id in ["503-120", "503-122"] {
            let decal = try XCTUnwrap(Markings.scheme("AS-503")?.decals.first { $0.id == id })
            let letterWidth = try XCTUnwrap(decal.params["letter_w"].flatMap(Double.init))
            XCTAssertEqual(decal.width, letterWidth, accuracy: 1, id)
            XCTAssertEqual(decal.glyphs[0].glyph.width, letterWidth, id)
        }
    }

    /// Rows that do not measure their letters take the mean of those that
    /// do: 57 in by 44 for USA, 31 by 22 for UNITED STATES, a 29 in word gap.
    func testUnmeasuredRowsTakeTheMeasuredMean() throws {
        let usa = try XCTUnwrap(Markings.measuredLetters("USA"))
        XCTAssertEqual(usa.height, 56.8, accuracy: 0.05)
        XCTAssertEqual(usa.width, 43.4, accuracy: 0.05)
        let us = try XCTUnwrap(Markings.measuredLetters("UNITED STATES"))
        XCTAssertEqual(us.height, 31, accuracy: 1e-9)
        XCTAssertEqual(us.wordGap, 29, accuracy: 1e-9)
        let b = try XCTUnwrap(Markings.scheme("AS-503")?.decals.first { $0.id == "503-121" })
        XCTAssertEqual(b.glyphs.first?.glyph.height, 31)
        XCTAssertEqual(b.glyphs.count, 12)
    }

    /// The SM's two lines (107-011): UNITED over STATES, 7 in tall, 26 in
    /// wide, filling the box from its top to its foot.
    func testServiceModuleLines() throws {
        let decal = try XCTUnwrap(Markings.scheme("CSM-107")?.decals.first { $0.id == "107-011" })
        let first = decal.glyphs.prefix(6), second = decal.glyphs.suffix(6)
        XCTAssertEqual(String(first.map(\.glyph.character)), "UNITED")
        XCTAssertEqual(String(second.map(\.glyph.character)), "STATES")
        XCTAssertEqual(first.first!.y + 7, decal.height, accuracy: 1e-9)
        XCTAssertEqual(second.first!.y, 0, accuracy: 1e-9)
        let left = second.first!.x, right = second.last!.x + second.last!.glyph.width
        XCTAssertEqual(right - left, 26 - 0.2 * 26 / 6, accuracy: 1e-9)   // six cells less the margins
        XCTAssertEqual((left + right) / 2, decal.width / 2, accuracy: 1e-9)
    }
}
