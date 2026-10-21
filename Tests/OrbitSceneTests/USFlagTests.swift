import XCTest
@testable import OrbitScene

/// The flag against Executive Order 10834 and its places on the vehicles
/// against VD2's measured boxes.
final class USFlagTests: XCTestCase {
    /// EO 10834's proportions: hoist 1, fly 1.9, union 0.5385 by 0.76, star
    /// spacings 0.054 and 0.063, star diameter 0.0616, stripes 1/13.
    func testExecutiveOrderProportions() {
        XCTAssertEqual(USFlag.fly / USFlag.hoist, 1.9)
        XCTAssertEqual(USFlag.unionHoist, 7.0 / 13, accuracy: 1e-4)
        XCTAssertEqual(USFlag.stripe, 1.0 / 13, accuracy: 1e-4)
        XCTAssertEqual(USFlag.unionFly, 0.76)
        XCTAssertEqual(USFlag.starDiameter, 0.0616)
        // The outer rows and columns sit as far from the union's edges as
        // their spacing (within the order's rounding).
        let xs = USFlag.starCentres.map(\.x), ys = USFlag.starCentres.map(\.y)
        XCTAssertEqual(xs.min()!, USFlag.starColumnSpacing, accuracy: 1e-12)
        XCTAssertEqual(USFlag.unionFly - xs.max()!, USFlag.starColumnSpacing, accuracy: 0.005)
        XCTAssertEqual(ys.min()!, USFlag.starRowSpacing, accuracy: 1e-12)
        XCTAssertEqual(USFlag.unionHoist - ys.max()!, USFlag.starRowSpacing, accuracy: 0.002)
    }

    /// Fifty stars in nine rows alternately six and five, the rows of five
    /// staggered between those of six.
    func testFiftyStarsInRowsOfSixAndFive() {
        XCTAssertEqual(USFlag.starCentres.count, 50)
        let rows = Dictionary(grouping: USFlag.starCentres) { ($0.y / USFlag.starRowSpacing).rounded() }
        XCTAssertEqual(rows.keys.sorted().map { rows[$0]!.count }, [6, 5, 6, 5, 6, 5, 6, 5, 6])
        let six = rows[1]!.map(\.x).sorted(), five = rows[2]!.map(\.x).sorted()
        for (k, x) in five.enumerated() { XCTAssertEqual(x, (six[k] + six[k + 1]) / 2, accuracy: 1e-12) }
        // Every star is white at its centre and inside the union.
        for c in USFlag.starCentres {
            XCTAssertEqual(USFlag.colour(x: c.x, y: c.y), .flagWhite)
            XCTAssertLessThan(c.x + USFlag.starDiameter / 2, USFlag.unionFly)
            XCTAssertLessThan(c.y + USFlag.starDiameter / 2, USFlag.unionHoist)
        }
    }

    /// Each star is a regular pentagram 0.0616 across its points, point up;
    /// the union's white is fifty of them.
    func testStars() {
        let r = USFlag.starDiameter / 2
        XCTAssertEqual(USFlag.star(x: 0, y: -r, radius: r), 0, accuracy: 1e-12)   // the top point
        XCTAssertLessThan(USFlag.star(x: 0, y: -0.9 * r, radius: r), 0)
        XCTAssertGreaterThan(USFlag.star(x: 0, y: 0.9 * r, radius: r), 0)          // between the lower points
        XCTAssertLessThan(USFlag.star(x: 0, y: 0, radius: r), 0)
        // Area: ten triangles of sides R and r_inner at 36°.
        let inner = r * sin(18 * Double.pi / 180) / sin(126 * Double.pi / 180)
        let starArea = 10 * 0.5 * r * inner * sin(36 * Double.pi / 180)
        let n = 600, dx = USFlag.unionFly / Double(n), dy = USFlag.unionHoist / Double(n)
        var white = 0
        for i in 0..<n {
            for j in 0..<n where USFlag.colour(x: (Double(i) + 0.5) * dx, y: (Double(j) + 0.5) * dy) == .flagWhite {
                white += 1
            }
        }
        XCTAssertEqual(Double(white) * dx * dy, 50 * starArea, accuracy: 0.02 * 50 * starArea)
    }

    /// Thirteen stripes, seven red and six white, red at the top and foot;
    /// the union blue between the stars.
    func testStripesAndUnion() {
        var colours: [PaintColour] = []
        for k in 0..<13 { colours.append(USFlag.colour(x: 1.5, y: (Double(k) + 0.5) / 13)!) }
        XCTAssertEqual(colours.filter { $0 == .flagRed }.count, 7)
        XCTAssertEqual(colours.filter { $0 == .flagWhite }.count, 6)
        XCTAssertEqual(colours.first, .flagRed)
        XCTAssertEqual(colours.last, .flagRed)
        for (a, b) in zip(colours, colours.dropFirst()) { XCTAssertNotEqual(a, b) }
        XCTAssertEqual(USFlag.colour(x: 0.01, y: 0.01), .flagBlue)
        XCTAssertEqual(USFlag.colour(x: 0.063 * 1.5, y: 0.054 * 1.5), .flagBlue)
        XCTAssertEqual(USFlag.colour(x: 0.77, y: 0.01), .flagRed)    // just past the union's fly
        XCTAssertNil(USFlag.colour(x: 1.91, y: 0.5))
        XCTAssertNil(USFlag.colour(x: 0.5, y: -0.01))
    }

    /// The stars' signed distance holds wherever the atlas may bake it:
    /// over the whole flag and a margin round it (a decal's bounds), it is
    /// the nearest of the fifty stars', the union's outer ones off it.
    func testStarDistanceEverywhere() {
        let r = USFlag.starDiameter / 2
        func nearest(_ x: Double, _ y: Double) -> Double {
            USFlag.starCentres.map { USFlag.star(x: x - $0.x, y: y - $0.y, radius: r) }.min()!
        }
        var worst = 0.0, at = (0.0, 0.0), count = 0
        for x in stride(from: -0.25, through: USFlag.fly + 0.25, by: 0.0123) {
            for y in stride(from: -0.25, through: USFlag.hoist + 0.25, by: 0.0117) {
                let e = abs(USFlag.starDistance(x: x, y: y) - nearest(x, y))
                if e > worst || e.isNaN { worst = e.isNaN ? .infinity : e; at = (x, y) }
                count += 1
            }
        }
        XCTAssertEqual(worst, 0, accuracy: 1e-12, "at \(at)")
        XCTAssertGreaterThan(count, 20_000)
        // Past the union's fly and below its foot (the review's points).
        XCTAssertEqual(USFlag.starDistance(x: 1.0, y: 0.3), nearest(1.0, 0.3), accuracy: 1e-12)
        XCTAssertEqual(USFlag.starDistance(x: 0.5, y: 0.8), nearest(0.5, 0.8), accuracy: 1e-12)
        XCTAssertGreaterThan(USFlag.starDistance(x: 1.0, y: 0.3), 0.25)
        XCTAssertEqual(USFlag.starDistance(x: 1e6, y: -1e6), nearest(1e6, -1e6), accuracy: 1e-6)
        XCTAssertEqual(USFlag.starDistance(x: .infinity, y: 0.2), .infinity)
        XCTAssertTrue(USFlag.starDistance(x: .nan, y: 0.2).isNaN)
    }

    /// Old Glory Red and Blue at the State Department's sRGB (ECA Design
    /// Guidelines: #B31942 and #0A3161), through IEC 61966-2-1's transfer
    /// function to linear; the Saturn's red lettering is the flag's red.
    func testOldGloryColours() {
        let red = PaintColour.flagRed.linear, blue = PaintColour.flagBlue.linear
        let expected: [(Float, Float)] = [(red.r, 0.450786), (red.g, 0.009721), (red.b, 0.054480),
                                          (blue.r, 0.003035), (blue.g, 0.030713), (blue.b, 0.119538)]
        for (k, (value, linear)) in expected.enumerated() { XCTAssertEqual(value, linear, accuracy: 2e-6, "channel \(k)") }
        XCTAssertEqual(PaintColour.red.linear, red)
        // Navy, not a purple-grey: blue well above red and green.
        XCTAssertGreaterThan(blue.b, 3 * blue.g)
        XCTAssertGreaterThan(blue.g, 5 * blue.r)
    }

    /// Every flag on the vehicles keeps EO 10834's ratio, its union at the
    /// upper hoist on the low-azimuth side, its hoist edge on the measured
    /// one, and misses the measured hoist and fly by under 10 %.
    func testFlagsAgainstTheMeasuredBoxes() throws {
        var count = 0
        for vehicle in ["AS-501", "AS-502", "AS-503", "AS-506", "CSM-101", "CSM-103", "CSM-107"] {
            let scheme = try XCTUnwrap(Markings.scheme(vehicle))
            for d in scheme.decals where d.paint == .flag {
                let f = try XCTUnwrap(d.flag, d.id)
                XCTAssertEqual(f.fly / f.hoist, 1.9, accuracy: 1e-12)
                XCTAssertTrue(f.hoistAtLeft, d.id)
                XCTAssertEqual(f.hoistX, 0, d.id)
                guard case let .flag(_, hoist, fly) = d.content else { return XCTFail(d.id) }
                // Measured flags; CSM-103's (L) takes CSM-101's box, an
                // envelope 9 in tall round a 7 by 13 in flag, unmeasured.
                if d.grade != .low {
                    XCTAssertEqual(f.hoist, hoist ?? d.height, accuracy: 0.1 * (hoist ?? d.height), d.id)
                    XCTAssertEqual(f.fly, fly ?? d.width, accuracy: 0.1 * (fly ?? d.width), d.id)
                }
                // Union at the upper hoist: blue just inside that corner.
                let corner = d.stations.lowerBound + f.y + 0.99 * f.hoist
                let azimuth = d.azimuths.from + 0.01 * f.hoist / d.radius * 180 / Double.pi
                XCTAssertEqual(d.colour(station: corner, azimuth: azimuth), .flagBlue, d.id)
                count += 1
            }
        }
        // AS-501/502: 4 each; AS-503: 4; AS-506: 2 + 1 + 1; the three SMs.
        XCTAssertEqual(count, 4 + 4 + 4 + 4 + 3)
    }
}
