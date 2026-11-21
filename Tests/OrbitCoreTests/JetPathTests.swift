import XCTest
@testable import OrbitCore

/// The jet-in-a-stream model (`JetPath`) against its references: Pratte and
/// Baines's (1967) transverse-jet trajectory, the coflowing jet's weak-jet
/// asymptotes (Tennekes and Lumley 1972), the still jet, and continuity in
/// the stream's direction and speed.
final class JetPathTests: XCTestCase {
    /// z/(rd) at x/(rd) along a transverse jet's path at velocity ratio r,
    /// the stream along +x, the jet along +z, d = 1.
    func transverse(_ r: Double) -> [(x: Double, z: Double)] {
        let path = JetPath.path(diameter: 1, speed: r, direction: Vec3(0, 0, 1), stream: Vec3(1, 0, 0),
                                length: 12 * r)
        return path.map { ($0.position.x / r, $0.position.z / r) }
    }

    /// z at x on a path, linearly between its stations.
    func height(_ path: [(x: Double, z: Double)], atX x: Double) -> Double? {
        guard let k = path.firstIndex(where: { $0.x >= x }), k > 0 else { return nil }
        let a = path[k - 1], b = path[k]
        return a.z + (b.z - a.z) * (x - a.x) / max(b.x - a.x, 1e-12)
    }

    // The transverse jet follows Pratte and Baines's z/(rd) = 2.05
    // (x/(rd))^0.28 within 25 % over x/(rd) 0.5 to 4 at r 5, 10 and 20.
    func testTransverseJetFollowsPratteAndBaines() throws {
        for r in [5.0, 10, 20] {
            let path = transverse(r)
            var worst = 0.0
            for x in stride(from: 0.5, through: 4, by: 0.25) {
                let z = try XCTUnwrap(height(path, atX: x), "r \(r) x \(x)")
                let pb = 2.05 * pow(x, 0.28)
                worst = max(worst, abs(z / pb - 1))
                XCTAssertEqual(z / pb, 1, accuracy: 0.25, "r \(r), x/rd \(x)")
            }
            print(String(format: "JetPathTests: r %.0f, worst against Pratte and Baines %.1f %%", r, 100 * worst))
        }
    }

    // In still air the jet runs straight, its width grows linearly and its
    // speed and dilution fall as 1/s. With the stream along it (coflow) it
    // runs straight too, and far out its excess speed falls as s^(-2/3) and
    // its width grows as s^(1/3): the weak jet's asymptotes.
    func testStillAndCoflowingJets() throws {
        let still = JetPath.path(diameter: 1, speed: 100, direction: Vec3(0, 0, 1), stream: .zero, length: 400)
        let a = try XCTUnwrap(still.first { $0.distance >= 100 }), b = try XCTUnwrap(still.first { $0.distance >= 300 })
        XCTAssertEqual(a.position.x, 0, accuracy: 1e-9)
        XCTAssertEqual(log(b.velocity.length / a.velocity.length) / log(b.distance / a.distance), -1, accuracy: 0.03)
        XCTAssertEqual(log(b.halfWidth / a.halfWidth) / log(b.distance / a.distance), 1, accuracy: 0.03)
        XCTAssertEqual(log(b.dilution / a.dilution) / log(b.distance / a.distance), -1, accuracy: 0.03)

        let coflow = JetPath.path(diameter: 1, speed: 100, direction: Vec3(0, 0, 1), stream: Vec3(0, 0, 10),
                                  length: 50_000)
        let c = try XCTUnwrap(coflow.first { $0.distance >= 10_000 }), e = try XCTUnwrap(coflow.first { $0.distance >= 40_000 })
        XCTAssertEqual(c.position.x, 0, accuracy: 1e-9)
        let excess = { (s: JetPath.Station) in s.velocity.length - 10 }
        XCTAssertEqual(log(excess(e) / excess(c)) / log(e.distance / c.distance), -2.0 / 3, accuracy: 0.05)
        XCTAssertEqual(log(e.halfWidth / c.halfWidth) / log(e.distance / c.distance), 1.0 / 3, accuracy: 0.05)
    }

    // A jet at an angle to the stream turns into it, never past it, and
    // slows towards it; the path moves continuously with the stream's angle
    // and speed.
    func testTurnsIntoTheStreamContinuously() throws {
        func end(_ angle: Double, _ speed: Double) -> JetPath.Station {
            let stream = Vec3(sin(angle), 0, cos(angle)) * speed
            return JetPath.path(diameter: 1, speed: 100, direction: Vec3(0, 0, 1), stream: stream, length: 2_000).last!
        }
        let deg = Double.pi / 180
        let e = end(10 * deg, 20)
        let heading = atan2(e.velocity.x, e.velocity.z)
        XCTAssertGreaterThan(heading, 5 * deg)
        XCTAssertLessThanOrEqual(heading, 10 * deg + 1e-6)
        XCTAssertEqual(e.velocity.length, 20, accuracy: 4)
        // Every quarter degree from -10° to 10°: the end moves by about
        // the same each step (no jump: the steps' differences under 0.5 m
        // against steps of about 8 m).
        var ends: [Double] = []
        for a in stride(from: -10.0, through: 10, by: 0.25) { ends.append(end(a * deg, 20).position.x) }
        let steps = zip(ends.dropFirst(), ends).map { $0 - $1 }
        for (k, (a, b)) in zip(steps.dropFirst(), steps).enumerated() {
            XCTAssertEqual(a, b, accuracy: 0.5, "step \(k)")
        }
        // And with the stream's speed, 1 to 50 m/s (a 100 m/s jet, 200
        // diameters, at 10°): the end moves outwards, under 3 m a step.
        // (Towards none it moves steeply: far out a still jet is slower than
        // the faintest breeze, so any takes it.)
        func near(_ u: Double) -> Double {
            JetPath.path(diameter: 1, speed: 100, direction: Vec3(0, 0, 1),
                         stream: Vec3(sin(10 * deg), 0, cos(10 * deg)) * u, length: 200).last!.position.x
        }
        var last: Double?
        for u in stride(from: 1.0, through: 50, by: 0.5) {
            let x = near(u)
            if let last {
                XCTAssertGreaterThan(x, last, "speed \(u)")
                XCTAssertLessThan(x - last, 3, "speed \(u)")
            }
            last = x
        }
    }

    // Straight into an opposing stream a jet penetrates it by a distance
    // linear in the velocity ratio, as measured (Lam and Chan 1997; the
    // coefficient is not checked: here about 2 r d for r 5 to 20, the same
    // within 15 %), then turns back and is swept downstream, still
    // shearing against the stream and diluting.
    func testCounterflowPenetration() throws {
        var reach: [Double] = []
        for r in [5.0, 10, 20] {
            let path = JetPath.path(diameter: 1, speed: r, direction: Vec3(0, 0, 1), stream: Vec3(0, 0, -1),
                                    length: 40 * r)
            let deepest = try XCTUnwrap(path.map(\.position.z).max())
            reach.append(deepest / r)
            let last = try XCTUnwrap(path.last)
            XCTAssertLessThan(last.velocity.z, 0, "turned back, r \(r)")
            XCTAssertLessThan(last.dilution, path[path.count / 2].dilution, "still diluting, r \(r)")
        }
        print("JetPathTests: counterflow penetration over r d at r 5, 10, 20: \(reach.map { String(format: "%.2f", $0) })")
        for x in reach { XCTAssertEqual(x / reach[1], 1, accuracy: 0.15) }
        XCTAssertGreaterThan(reach[1], 1.5)
        XCTAssertLessThan(reach[1], 2.5)
    }

    // A coflow lengthens a jet flame, a crossflow shortens it; none, no
    // change; it grows continuously with the coflow.
    func testFlameLengthening() {
        XCTAssertEqual(JetPath.flameLengthening(stillLength: 50, diameter: 1, speed: 1_000, streamAlong: 0,
                                                streamAcross: 0), 1)
        var last = 1.0
        for u in stride(from: 10.0, through: 300, by: 10) {
            let k = JetPath.flameLengthening(stillLength: 50, diameter: 1, speed: 1_000, streamAlong: u, streamAcross: 0)
            XCTAssertGreaterThan(k, last, "coflow \(u)")
            XCTAssertLessThan(k - last, 0.08, "coflow \(u)")
            last = k
        }
        XCTAssertLessThan(JetPath.flameLengthening(stillLength: 50, diameter: 1, speed: 1_000, streamAlong: 0,
                                                   streamAcross: 100), 1)
        // A counterflow never lengthens it (straight against the jet, or
        // with a little or more crossflow), down to the jet's penetration
        // into the stream: it shortens as the stream grows, and the factor
        // moves continuously with the stream from -500 to 500 m/s (the old
        // clamp on the shear jumped from 0.67 to the cap of 20 between -60
        // and -65 m/s).
        for across in [0.0, 5, 50] {
            var last: Double?
            for along in stride(from: -500.0, through: 500, by: 10) {
                let k = JetPath.flameLengthening(stillLength: 50, diameter: 1, speed: 1_000, streamAlong: along,
                                                 streamAcross: across)
                if along <= 0 { XCTAssertLessThanOrEqual(k, 1 + 1e-9, "counterflow \(along), across \(across)") }
                if let last { XCTAssertLessThan(abs(k - last), 0.15, "along \(along), across \(across)") }
                last = k
            }
        }
        XCTAssertLessThan(JetPath.flameLengthening(stillLength: 50, diameter: 1, speed: 1_000, streamAlong: -500,
                                                   streamAcross: 0), 0.1, "to the penetration, about 4 diameters")
        // Nor does a weak crossflow (the jet at most as fast as the stream)
        // for Apollo's exhausts (stoichiometric mixture fractions 0.38 for
        // the J-2 to 0.76 for the solids: still flames of 23/fs momentum
        // diameters).
        for fs in [0.38, 0.43, 0.57, 0.63, 0.76] {
            for r in [0.25, 0.5, 1] {
                let k = JetPath.flameLengthening(stillLength: 23 / fs, diameter: 1, speed: 1_000, streamAlong: 0,
                                                 streamAcross: 1_000 / r)
                XCTAssertLessThan(k, 1, "fs \(fs), r \(r)")
            }
        }
        print(String(format: "JetPathTests: flame lengthening at coflow 0.02, 0.1, 0.2 of the jet: %.3f, %.3f, %.3f",
                     JetPath.flameLengthening(stillLength: 50, diameter: 1, speed: 1_000, streamAlong: 20, streamAcross: 0),
                     JetPath.flameLengthening(stillLength: 50, diameter: 1, speed: 1_000, streamAlong: 100, streamAcross: 0),
                     JetPath.flameLengthening(stillLength: 50, diameter: 1, speed: 1_000, streamAlong: 200, streamAcross: 0)))
    }
}
