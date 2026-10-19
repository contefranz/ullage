import XCTest
@testable import OrbitCore

/// `VesselLibrary.dressSaturnV`, the Saturn V's shapes.
final class ApolloShapesTests: XCTestCase {
    // Every part is dressed as `saturnV()` dressed it inline before the
    // shapes moved: one shape per body section and one per main engine.
    // The spacecraft's parts since track C (the SLA ring and panels, the SM
    // and the command module's parts) have none until track G1's shapes.
    // Dressing again replaces the shapes.
    func testSaturnVShapes() {
        let stack = VesselLibrary.saturnV()
        var counts = ["S-IC": 6, "S-IC/S-II interstage": 1, "S-II": 6, "S-II/S-IVB interstage": 1, "S-IVB": 2,
                      "S-IVB ullage rockets": 0, "IU": 1, "LES": 3]
        for name in SaturnVDataTests.spacecraft { counts[name] = 0 }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: stack.parts.map { ($0.name, $0.shapes.count) }), counts)
        let origins = stack.parts.map { $0.shapes.map(\.origin) }
        VesselLibrary.dressSaturnV(stack)
        XCTAssertEqual(stack.parts.map { $0.shapes.map(\.origin) }, origins)
    }
}
