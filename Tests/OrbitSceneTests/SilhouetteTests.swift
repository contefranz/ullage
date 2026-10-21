import Foundation
import XCTest
@testable import OrbitCore

/// Today's Saturn V and CSM outlines (`Silhouette`) against
/// docs/SaturnV-CSM-exterior-datasheet.md, and the helpers' meaning on a
/// toy. The diameters are measured on the fin diagonals (θ = 45°, 135°,
/// 225°, 315°) at stations clear of the fins, fairings, tunnels, modules
/// and antennas the datasheet puts near the Positions, so that VG1-VG3's
/// added detail leaves them standing.
final class SilhouetteTests: XCTestCase {
    static let stack = Silhouette(VesselLibrary.saturnV())
    static let csm = VesselLibrary.apolloCSM(.apollo11)
    let inch = AS506.inch
    let diagonals = [1.0, 3, 5, 7].map { $0 * Double.pi / 4 }

    /// A cylinder of radius 1 with a box out to 1.5 at Position II.
    func testMeasuresOnAToy() throws {
        let body = VisualShape.frustum(from: .zero, length: 4, baseRadius: 1, topRadius: 1, color: (1, 1, 1))
        let marker = VisualShape.box(from: Vec3(1.5, -1.25, 0), length: 1, width: 0.5, height: 0.5, color: (1, 0, 0))
        let s = Silhouette(OrthoScene(shapes: [body, marker]))
        XCTAssertEqual(s.stations, 0...4)
        let ii = Double.pi / 2
        XCTAssertEqual(try XCTUnwrap(s.radius(at: 2, azimuth: ii)), 1.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(s.radius(at: 1, azimuth: ii)), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(s.radius(at: 2, azimuth: 0)), 1, accuracy: 1e-12)
        // The box's corners reach towards I in the outline, not on the ray.
        XCTAssertEqual(try XCTUnwrap(s.radius(at: 2, azimuth: ii - 0.4)), 1.5 * cos(0.4) + 0.25 * sin(0.4), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(s.reach(at: 2, azimuth: ii - 0.4)), 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(s.reach(at: 2, azimuth: ii)), 1.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(s.width(at: 2, viewedFrom: 0)), 2.5, accuracy: 1e-12)    // II plus IV
        XCTAssertEqual(try XCTUnwrap(s.width(at: 2, viewedFrom: ii)), 2, accuracy: 1e-12)     // III plus I
        XCTAssertEqual(try XCTUnwrap(s.radius(over: 0...1.6, azimuth: ii)), 1.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(s.radius(over: 0...1.4, azimuth: ii)), 1, accuracy: 1e-12)
        XCTAssertNil(s.radius(at: 5, azimuth: 0))
        XCTAssertNil(s.reach(at: -1, azimuth: 0))
    }

    /// §1: 33.0 ft (396 in) for the S-IC, the S-IC/S-II interstage and the
    /// S-II; 260 in for the S-IVB and the IU (§1, §7).
    func testStageDiameters() throws {
        let stations: [(String, Double, Double)] = [
            ("S-IC fuel tank", 450, 396), ("S-IC intertank", 750, 396), ("S-IC LOX tank", 1200, 396),
            ("S-IC forward skirt", 1500, 396), ("S-IC/S-II interstage", 1650, 396),
            ("S-II, above the feed-line fairings", 2100, 396), ("S-II", 2300, 396),
            ("S-IVB", 2900, 260), ("S-IVB", 3050, 260), ("IU", 3240, 260),
        ]
        for (name, sta, diameter) in stations {
            for azimuth in diagonals {
                let r = try XCTUnwrap(Self.stack.radius(at: AS506.station(sta), azimuth: azimuth), name)
                XCTAssertEqual(2 * r / inch, diameter, accuracy: 1, "\(name), STA \(sta), θ \(azimuth)")
            }
        }
    }

    /// §1: 363 ft from the F-1 exit plane (STA -115.36) to the LES's tip
    /// (STA 4240.79).
    func testOverallHeight() throws {
        let extent = try XCTUnwrap(Self.stack.stations)
        XCTAssertEqual((extent.upperBound - extent.lowerBound) / AS506.foot, 363, accuracy: 0.1)
        XCTAssertEqual(extent.lowerBound / inch, -115.36, accuracy: 0.5)
        XCTAssertEqual(extent.upperBound / inch, 4240.79, accuracy: 0.5)
    }

    /// §12 and VG3's list: the SLA runs 28 ft from 260 in at the IU to 154
    /// in at the SM.
    func testSLACone() throws {
        let low = 510.0, high = 830.0
        let rLow = try XCTUnwrap(Self.stack.radius(at: AS506.apolloStation(low), azimuth: Double.pi / 4))
        let rHigh = try XCTUnwrap(Self.stack.radius(at: AS506.apolloStation(high), azimuth: Double.pi / 4))
        let slope = (rHigh - rLow) / ((high - low) * inch)
        func diameter(at xa: Double) -> Double { 2 * (rLow + slope * (xa - low) * inch) / inch }
        XCTAssertEqual(diameter(at: 502), 260, accuracy: 1)
        XCTAssertEqual(diameter(at: 838), 154, accuracy: 1)
        XCTAssertEqual((838 - 502) * inch / AS506.foot, 28, accuracy: 0.01)
    }

    /// §9.1: the CM is 154 in across with its ablator; §10: so is the SM.
    func testCommandAndServiceModuleDiameters() throws {
        let cm = Silhouette(OrthoScene(Self.csm, where: { $0.name == "CM" }))
        let band = try XCTUnwrap(cm.stations)
        for azimuth in diagonals + [0, Double.pi / 2, Double.pi, 3 * Double.pi / 2] {
            let r = try XCTUnwrap(cm.radius(over: band, azimuth: azimuth))
            XCTAssertEqual(2 * r / inch, 154, accuracy: 0.5, "CM, θ \(azimuth)")
        }
        let sm = Silhouette(OrthoScene(Self.csm, where: { $0.name == "SM" }))
        for azimuth in diagonals {
            let r = try XCTUnwrap(sm.radius(at: AS506.apolloStation(900), azimuth: azimuth))
            XCTAssertEqual(2 * r / inch, 154, accuracy: 0.5, "SM, θ \(azimuth)")
        }
    }

    /// §6: the APS modules stand on the S-IVB's aft skirt at Positions I and
    /// III; at II and IV the ray meets the 260 in skirt.
    func testAPSModulesAtPositionsIAndIII() throws {
        let sIVB = try XCTUnwrap(VesselLibrary.saturnV().parts.first { $0.name == "S-IVB" })
        let stack = VesselLibrary.saturnV()
        let part = try XCTUnwrap(stack.parts.first { $0.name == "S-IVB" })
        let pitch = try XCTUnwrap(sIVB.thrusters.first { $0.name == "APS I pitch" })
        let x = (pitch.position + part.offset - stack.structureOrigin).x
        let skirt = 130.0
        for azimuth in [0, Double.pi] {
            XCTAssertGreaterThan(try XCTUnwrap(Self.stack.reach(at: x, azimuth: azimuth)) / inch, skirt + 10)
        }
        for azimuth in [Double.pi / 2, 3 * Double.pi / 2] {
            XCTAssertEqual(try XCTUnwrap(Self.stack.reach(at: x, azimuth: azimuth)) / inch, skirt, accuracy: 0.5)
        }
    }
}
