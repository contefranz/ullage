import XCTest
@testable import OrbitCore

/// The derived geometry of `OrbitalElements` on orbits built by hand from
/// their elements.
final class OrbitalElementsGeometryTests: XCTestCase {
    let mu = 3.986004418e14
    let deg = Double.pi / 180

    /// The state at true anomaly `nu` of the orbit (a, e, i, Ω, ω), in the
    /// frame whose rows are `frame` (ICRF -> reference), from the perifocal
    /// formulas.
    func state(a: Double, e: Double, i: Double, node: Double, argp: Double, nu: Double,
               frame: Mat3 = .identity) -> (r: Vec3, v: Vec3) {
        let p = a * (1 - e * e)
        let rPF = Vec3(cos(nu), sin(nu), 0) * (p / (1 + e * cos(nu)))
        let vPF = Vec3(-sin(nu), e + cos(nu), 0) * (mu / p).squareRoot()
        let m = frame.transposed * Mat3.rotZ(node) * Mat3.rotX(i) * Mat3.rotZ(argp)
        return (m * rPF, m * vPF)
    }

    func testDerivedAnglesAndAxes() {
        let a = 8_000_000.0, e = 0.2
        let s = state(a: a, e: e, i: 30 * deg, node: 40 * deg, argp: 60 * deg, nu: 100 * deg)
        let el = OrbitalElements(position: s.r, velocity: s.v, mu: mu)
        XCTAssertEqual(el.semiMinorAxis, a * (1 - e * e).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(el.semiLatusRectum, a * (1 - e * e), accuracy: 1e-6)
        XCTAssertEqual(el.argumentOfLatitude, 160 * deg, accuracy: 1e-12)
        XCTAssertEqual(el.longitudeOfPeriapsis, 100 * deg, accuracy: 1e-12)
        XCTAssertEqual(el.trueLongitude, 200 * deg, accuracy: 1e-12)
        // M from the eccentric anomaly, worked separately.
        let ea = 2 * atan(((1 - e) / (1 + e)).squareRoot() * tan(50 * deg))
        XCTAssertEqual(el.meanLongitude, 100 * deg + ea - e * sin(ea), accuracy: 1e-12)

        let b = el.perifocalBasis
        let m = Mat3.rotZ(40 * deg) * Mat3.rotX(30 * deg) * Mat3.rotZ(60 * deg)
        XCTAssertLessThan((b.p - m.c0).length, 1e-12)
        XCTAssertLessThan((b.q - m.c1).length, 1e-12)
        XCTAssertLessThan((b.w - s.r.cross(s.v).normalized).length, 1e-12)
        XCTAssertLessThan((el.position(atTrueAnomaly: el.trueAnomaly) - s.r).length, 1e-6)
        XCTAssertLessThan((el.velocity(atTrueAnomaly: el.trueAnomaly) - s.v).length, 1e-9)

        // Nodes: the ascending one along Ω on the equator, at radius
        // p / (1 + e cos(-ω)); the descending one opposite, p / (1 - e cos ω).
        let n = try! XCTUnwrap(el.ascendingNodeDirection)
        XCTAssertLessThan((n - Vec3(cos(40 * deg), sin(40 * deg), 0)).length, 1e-12)
        let an = try! XCTUnwrap(el.ascendingNode), dn = try! XCTUnwrap(el.descendingNode)
        let p = el.semiLatusRectum
        XCTAssertLessThan((an - n * (p / (1 + e * cos(60 * deg)))).length, 1e-6)
        XCTAssertLessThan((dn + n * (p / (1 - e * cos(60 * deg)))).length, 1e-6)

        // The radius the state is at, crossed going in (ν = 100° is outbound).
        let nus = try! XCTUnwrap(el.trueAnomalies(atRadius: s.r.length))
        XCTAssertEqual(nus.outbound, 100 * deg, accuracy: 1e-9)
        XCTAssertEqual(nus.inbound, 260 * deg, accuracy: 1e-9)
        XCTAssertNil(el.trueAnomalies(atRadius: el.apoapsisRadius * 1.001))
        XCTAssertNil(el.trueAnomalies(atRadius: el.periapsisRadius * 0.999))
    }

    /// With the Earth's pole of date as the reference, the angles are in that
    /// frame and the basis, nodes and positions come back in ICRF.
    func testTiltedReferencePole() throws {
        let system = try SolarSystem.bundled()
        let snap = system.snapshot(at: Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32))
        let pole = snap.orientation(system.earth).pole
        let probe = OrbitalElements(position: Vec3(7e6, 0, 0), velocity: Vec3(0, 7e3, 1e3), mu: mu, pole: pole)
        let frame = probe.referenceFrame
        XCTAssertLessThan((frame.r2 - pole).length, 1e-15)
        let s = state(a: 6_600_000, e: 0.01, i: 32.5 * deg, node: 123 * deg, argp: 200 * deg, nu: 33 * deg,
                      frame: frame)
        let el = OrbitalElements(position: s.r, velocity: s.v, mu: mu, pole: pole)
        XCTAssertEqual(el.inclination, 32.5 * deg, accuracy: 1e-12)
        XCTAssertEqual(el.longitudeOfAscendingNode, 123 * deg, accuracy: 1e-12)
        XCTAssertEqual(el.argumentOfLatitude, 233 * deg, accuracy: 1e-10)
        XCTAssertLessThan((el.position(atTrueAnomaly: el.trueAnomaly) - s.r).length, 1e-6)
        let an = try XCTUnwrap(el.ascendingNode)
        XCTAssertEqual(an.dot(pole), 0, accuracy: 1e-6)
        // The node's longitude from another reference direction: from the
        // frame's own x it is Ω; from the equinox of date it is the RAAN.
        XCTAssertEqual(try XCTUnwrap(el.longitudeOfAscendingNode(from: frame.r0)), 123 * deg, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(el.longitudeOfAscendingNode(from: frame.r1)), 33 * deg, accuracy: 1e-12)
        let equinox = EarthOrientation.biasPrecessionMatrix(tt: snap.time.tt).r0
        let raan = try XCTUnwrap(el.longitudeOfAscendingNode(from: equinox))
        let node = try XCTUnwrap(el.ascendingNodeDirection)
        XCTAssertEqual(cos(raan), node.dot(equinox) / (1 - pow(equinox.dot(pole), 2)).squareRoot(), accuracy: 1e-9)
        XCTAssertGreaterThan(sin(raan) * pole.cross(equinox).dot(node), 0)
        XCTAssertGreaterThan(an.dot(pole.cross(s.r.cross(s.v))), 0)
    }

    /// conicPoints lie on r = p / (1 + e cos ν): a closed ellipse even in
    /// eccentric anomaly; a hyperbola's arc and an ellipse cut at a radius.
    func testConicPoints() {
        let s = state(a: 9_000_000, e: 0.3, i: 50 * deg, node: 10 * deg, argp: 300 * deg, nu: 2)
        let el = OrbitalElements(position: s.r, velocity: s.v, mu: mu)
        let b = el.perifocalBasis
        func onConic(_ x: Vec3, _ el: OrbitalElements) {
            XCTAssertEqual(x.dot(b.w), 0, accuracy: 1e-6)
            let nu = atan2(x.dot(b.q), x.dot(b.p))
            XCTAssertEqual(x.length, el.radius(atTrueAnomaly: nu), accuracy: 1e-6)
        }
        let pts = el.conicPoints(64)
        XCTAssertEqual(pts.count, 65)
        XCTAssertLessThan((pts[0] - b.p * el.periapsisRadius).length, 1e-6)
        XCTAssertLessThan((pts[64] - pts[0]).length, 1e-6)
        XCTAssertLessThan((pts[32] + b.p * el.apoapsisRadius).length, 1e-6)
        for x in pts { onConic(x, el) }

        let cut = el.conicPoints(40, maxRadius: 8_000_000)
        XCTAssertEqual(cut.count, 41)
        XCTAssertEqual(cut.map(\.length).max()!, 8_000_000, accuracy: 1e-3)
        XCTAssertEqual(cut.first!.length, 8_000_000, accuracy: 1e-3)
        for x in cut { onConic(x, el) }
        XCTAssertTrue(el.conicPoints(10, maxRadius: 1e6).isEmpty)

        let hyp = OrbitalElements(position: Vec3(6_700_000, 0, 0), velocity: Vec3(0, 10_000, 6_000), mu: mu)
        let arc = hyp.conicPoints(50, maxRadius: 5e7)
        XCTAssertEqual(arc.map(\.length).max()!, 5e7, accuracy: 1)
        let hb = hyp.perifocalBasis
        for x in arc {
            let nu = atan2(x.dot(hb.q), x.dot(hb.p))
            XCTAssertEqual(x.length, hyp.radius(atTrueAnomaly: nu), accuracy: 1e-3)
        }
        XCTAssertEqual(hyp.semiMinorAxis, abs(hyp.semiMajorAxis) * (hyp.eccentricity * hyp.eccentricity - 1)
            .squareRoot(), accuracy: 1e-6)
        let open = hyp.conicPoints(20)
        XCTAssertEqual(open.count, 21)
        XCTAssertTrue(open.allSatisfy { $0.length.isFinite && $0.length > 0 })
    }

    /// A circular orbit's perifocal P is its ascending node; a radius does
    /// not fix its anomaly; an equatorial orbit has no nodes.
    func testCircularAndEquatorial() {
        let r = 6_563_137.0, speed = (mu / r).squareRoot()
        let s = state(a: r, e: 0, i: 32.5 * deg, node: 70 * deg, argp: 0, nu: 45 * deg)
        let el = OrbitalElements(position: s.r, velocity: s.v, mu: mu)
        XCTAssertEqual(el.argumentOfLatitude, 45 * deg, accuracy: 1e-9)
        XCTAssertLessThan((el.perifocalBasis.p - el.ascendingNodeDirection!).length, 1e-9)
        XCTAssertNil(el.trueAnomalies(atRadius: r))
        let flat = OrbitalElements(position: Vec3(r, 0, 0), velocity: Vec3(0, speed, 0), mu: mu)
        XCTAssertNil(flat.ascendingNodeDirection)
        XCTAssertNil(flat.ascendingNode)
        XCTAssertNil(flat.descendingNode)
    }
}
