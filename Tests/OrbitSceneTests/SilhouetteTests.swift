import Foundation
import XCTest
@testable import OrbitCore

/// The Saturn V's and CSM's outlines (`Silhouette`) against
/// docs/SaturnV-CSM-exterior-datasheet.md, and the helpers' meaning on a
/// toy. The skins' diameters are measured along the fin diagonals (θ = 45°,
/// 135°, 225°, 315°) with the ray-local `diameter`, at stations clear of the
/// fins, so that the tunnels, fairings, modules and antennas VG1-VG3 put
/// beside the rays leave them standing: `radius`, the outline's support
/// function, picks those up from as far as 19° away (see `Silhouette` and
/// `testStageDiametersBesideTunnelsAndFairings`).
final class SilhouetteTests: XCTestCase {
    static let stack = Silhouette(VesselLibrary.saturnV())
    static let csm = VesselLibrary.apolloCSM(.apollo11)
    let inch = AS506.inch
    let diagonals = [1.0, 3, 5, 7].map { $0 * Double.pi / 4 }
    /// The two lines through the axis along the fin diagonals.
    let diagonalLines = [Double.pi / 4, 3 * Double.pi / 4]

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
        XCTAssertEqual(try XCTUnwrap(s.diameter(at: 2, azimuth: ii)), 2.5, accuracy: 1e-12)   // II plus IV
        // Off the box's line the outline is wider, the skin is not (to within the facets).
        let wider: Double = 1 + 1.5 * cos(0.4) + 0.25 * sin(0.4)
        XCTAssertEqual(try XCTUnwrap(s.width(at: 2, viewedFrom: 0.4)), wider, accuracy: 0.005)
        XCTAssertEqual(try XCTUnwrap(s.diameter(at: 2, azimuth: ii - 0.4)), 2, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(s.radius(over: 0...1.6, azimuth: ii)), 1.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(s.radius(over: 0...1.4, azimuth: ii)), 1, accuracy: 1e-12)
        XCTAssertNil(s.radius(at: 5, azimuth: 0))
        XCTAssertNil(s.reach(at: -1, azimuth: 0))
    }

    /// §1: 33.0 ft (396 in) for the S-IC, the S-IC/S-II interstage and the
    /// S-II; 260 in for the S-IVB and the IU (§1, §7).
    let stageDiameters: [(String, Double, Double)] = [
        ("S-IC fuel tank", 450, 396), ("S-IC intertank", 750, 396), ("S-IC LOX tank", 1200, 396),
        ("S-IC forward skirt", 1500, 396), ("S-IC/S-II interstage", 1650, 396),
        ("S-II, above the feed-line fairings", 2100, 396), ("S-II", 2300, 396),
        ("S-IVB", 2900, 260), ("S-IVB", 3050, 260), ("IU", 3240, 260),
    ]

    func testStageDiameters() throws {
        for (name, sta, diameter) in stageDiameters {
            for azimuth in diagonalLines {
                let d = try XCTUnwrap(Self.stack.diameter(at: AS506.station(sta), azimuth: azimuth), name)
                XCTAssertEqual(d / inch, diameter, accuracy: 1, "\(name), STA \(sta), θ \(azimuth)")
            }
        }
    }

    /// The pins stand beside the features that stand proud near fin A's
    /// diagonal: the S-II's systems tunnel (§4: semicircular, 22 in wide,
    /// between Positions I and II, close to I) and the S-II ullage motors'
    /// fairings on the S-IC/S-II interstage (§3: one round each 12.5 in
    /// motor). Rays swept round the diagonal find each feature where it
    /// stands. The outline beside them is wider: `radius` on the diagonal
    /// reads them, as the support function of what the rays find,
    /// max reach(θ) cos(45° - θ); for the tunnel, R cos Δ + 11 in.
    func testStageDiametersBesideTunnelsAndFairings() throws {
        let degree = Double.pi / 180, fin = Double.pi / 4
        /// At STA `sta`: the farthest of the rays every 0.02° from θ 20° to
        /// 70° (the feature: its azimuth and how far it stands proud of the
        /// 198 in skin, in) and `radius` on the diagonal (in), once the
        /// diameter there is checked and `radius` against the rays.
        func beside(_ sta: Double, _ name: String) throws -> (azimuth: Double, proud: Double, outline: Double) {
            let x = AS506.station(sta), cut = Self.stack.section(at: x)
            let rays = stride(from: 20.0, through: 70, by: 0.02).compactMap { a in
                cut.reach(azimuth: a * degree).map { (azimuth: a * degree, reach: $0) }
            }
            let feature = try XCTUnwrap(rays.max { $0.reach < $1.reach }, name)
            let diameter = try XCTUnwrap(Self.stack.diameter(at: x, azimuth: fin), name)
            let outline = try XCTUnwrap(cut.radius(azimuth: fin), name)
            let support = try XCTUnwrap(rays.map { $0.reach * cos(fin - $0.azimuth) }.max(), name)
            XCTAssertEqual(diameter / inch, 396, accuracy: 1, name)
            XCTAssertEqual(outline / inch, support / inch, accuracy: 0.05, name)
            XCTAssertGreaterThan((outline - diameter / 2) / inch, 5, "\(name): the outline is wider")
            return (feature.azimuth, feature.reach / inch - 198, outline / inch)
        }

        let tunnel = try beside(2300, "S-II systems tunnel")
        XCTAssertGreaterThan(tunnel.azimuth, 0)
        XCTAssertLessThan(tunnel.azimuth, fin)
        XCTAssertEqual(tunnel.proud, 11, accuracy: 0.25)
        XCTAssertEqual(tunnel.outline, 198 * cos(fin - tunnel.azimuth) + 11, accuracy: 0.1)

        let fairing = try beside(1650, "S-II ullage-motor fairing")
        XCTAssertGreaterThan(fairing.proud, 12.5)
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
        for azimuth in diagonalLines {
            let dLow = try XCTUnwrap(Self.stack.diameter(at: AS506.apolloStation(low), azimuth: azimuth))
            let dHigh = try XCTUnwrap(Self.stack.diameter(at: AS506.apolloStation(high), azimuth: azimuth))
            let slope = (dHigh - dLow) / ((high - low) * inch)
            func diameter(at xa: Double) -> Double { (dLow + slope * (xa - low) * inch) / inch }
            XCTAssertEqual(diameter(at: 502), 260, accuracy: 1, "θ \(azimuth)")
            XCTAssertEqual(diameter(at: 838), 154, accuracy: 1, "θ \(azimuth)")
        }
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
        for azimuth in diagonalLines {
            let d = try XCTUnwrap(sm.diameter(at: AS506.apolloStation(900), azimuth: azimuth))
            XCTAssertEqual(d / inch, 154, accuracy: 0.5, "SM, θ \(azimuth)")
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
