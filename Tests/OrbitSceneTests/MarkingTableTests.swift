import XCTest
import OrbitCore
@testable import OrbitScene

/// VD2's markings tables as the paint evaluator reads them.
final class MarkingTableTests: XCTestCase {
    /// docs/data/markings, from this file's place in the source tree.
    static let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/data/markings")

    /// Each bundled table is a byte-for-byte copy of docs/data/markings'.
    func testBundledTablesMatchTheDocs() throws {
        for name in MarkingTable.bundledNames {
            let original = Self.docs.appendingPathComponent(name)
            guard let docs = try? Data(contentsOf: original) else { throw XCTSkip("\(original.path) not found") }
            let url = try XCTUnwrap(MarkingTable.bundledURL(name))
            XCTAssertEqual(try Data(contentsOf: url), docs, "Resources/markings/\(name) differs from docs/data/markings")
        }
    }

    /// Every row parses, with its stations in order and a known element.
    func testEveryRowParses() throws {
        var count = 0, vehicles = Set<String>()
        for name in MarkingTable.bundledNames {
            let rows = try MarkingTable.bundled(name)
            XCTAssertFalse(rows.isEmpty, name)
            for row in rows {
                XCTAssertNotNil(Markings.element(of: row), "\(row.id): \(row.element)")
                XCTAssertLessThanOrEqual(row.stations.lowerBound, row.stations.upperBound, row.id)
                XCTAssertFalse(row.copies.isEmpty, row.id)
                vehicles.insert(row.vehicle)
            }
            count += rows.count
        }
        XCTAssertEqual(count, 16 + 15 + 75 + 49 + 42)
        XCTAssertEqual(vehicles, ["AS-501", "AS-502", "AS-503", "AS-506", "CSM-101", "CSM-103", "CSM-107"])
    }

    /// The CSV reader: quoted fields with commas and doubled quotes, and
    /// comment lines.
    func testCSVFields() throws {
        let text = """
        # a comment, "quoted"
        id,vehicle,element,kind,feature,frame,sta_from,sta_to,az_from,az_to,paint,params,photos,sources,grade,note
        x-1,AS-503,S-IC,region,"a, b",STA,1,2,357,3,black,copies=357-3/87-93;face=inner,P1;P2,,M,"say ""hi"", twice"
        """
        let rows = try MarkingTable.rows(text)
        XCTAssertEqual(rows.count, 1)
        let r = rows[0]
        XCTAssertEqual(r.feature, "a, b")
        XCTAssertEqual(r.note, "say \"hi\", twice")
        XCTAssertEqual(r.photos, ["P1", "P2"])
        XCTAssertEqual(r.face, .inner)
        XCTAssertEqual(r.copies, [AzimuthRange(357, 3), AzimuthRange(87, 93)])
        XCTAssertEqual(r.grade, .medium)
        XCTAssertThrowsError(try MarkingTable.rows(text.replacingOccurrences(of: ",black,", with: ",mauve,")))
    }

    /// Azimuth ranges wrap through 0, and 0 to 360 is all round.
    func testAzimuthRanges() {
        let wrap = AzimuthRange(357, 3)
        XCTAssertEqual(wrap.width, 6, accuracy: 1e-12)
        XCTAssertEqual(wrap.centre, 0, accuracy: 1e-12)
        XCTAssertTrue(wrap.contains(359) && wrap.contains(1) && wrap.contains(-1) && wrap.contains(363))
        XCTAssertFalse(wrap.contains(4) || wrap.contains(356))
        let all = AzimuthRange(0, 360)
        XCTAssertEqual(all.width, 360)
        XCTAssertTrue(all.contains(0) && all.contains(359.99) && all.contains(180))
        let toTop = AzimuthRange(317.9, 360)
        XCTAssertEqual(toTop.width, 42.1, accuracy: 1e-9)
        XCTAssertTrue(toTop.contains(359.9) && toTop.contains(320))
        XCTAssertFalse(toTop.contains(300))
    }
}
