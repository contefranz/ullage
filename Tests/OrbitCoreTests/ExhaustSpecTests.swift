import XCTest
@testable import OrbitCore

/// `ExhaustSpec` and the `ExhaustLibrary` seam, which the exhaust physics
/// track fills.
final class ExhaustSpecTests: XCTestCase {
    // The exhaust library is the plume track's to fill: so far it knows no
    // thruster, and a spec keeps what it is given.
    func testExhaustLibraryIsEmpty() {
        for p in VesselLibrary.saturnV().parts {
            for t in p.thrusters { XCTAssertNil(ExhaustLibrary.spec(for: t, in: p), t.name) }
        }
        let spec = ExhaustSpec(family: .hydrogenLOX, chamberPressure: 5.26e6, areaRatio: 27.5, exitRadius: 0.979,
                               lipHalfAngle: 0.2, exitGamma: 1.23, molarMass: 0.0135, chamberTemperature: 3_200,
                               exitTemperature: 1_100, source: "test", grade: "L")
        XCTAssertEqual(spec.family, .hydrogenLOX)
        XCTAssertNil(spec.film)
        XCTAssertEqual(spec.aluminaFraction, 0)
    }
}
