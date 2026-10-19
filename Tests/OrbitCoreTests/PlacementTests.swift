import XCTest
@testable import OrbitCore

/// `Simulation.place`: a vessel in flight from its geodetic position, inertial
/// speed, flight-path angle and azimuth, as Apollo's trajectory listings give
/// them.
final class PlacementTests: XCTestCase {
    typealias FlightState = (latitude: Double, longitude: Double, height: Double, speed: Double,
                             flightPathAngle: Double, azimuth: Double)

    /// The geodetic latitude, longitude and height of `v`, its inertial
    /// speed, and its flight-path angle and azimuth in the geocentric
    /// horizontal (degrees, m, m/s), from its state.
    func readBack(_ v: Vessel, in sim: Simulation) -> FlightState {
        let o = sim.snapshot.orientation(v.reference)
        let g = v.reference.geodetic(v.position, orientation: o)
        let up = v.position.normalized, east = o.pole.cross(up).normalized, north = up.cross(east)
        let u = v.velocity.normalized, deg = 180 / Double.pi
        let azimuth = atan2(u.dot(east), u.dot(north)) * deg
        return (g.latitude * deg, g.longitude * deg, g.height, v.velocity.length, asin(u.dot(up)) * deg,
                azimuth < 0 ? azimuth + 360 : azimuth)
    }

    // The state `place` builds reads back to what it was given, within 1e-6
    // (degrees, m, m/s): an entry interface, a climb near the pole, a
    // descent, and the ground on the equator.
    func testRoundTrip() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.capsule()
        sim.add(v)
        let cases: [FlightState] = [(29.8, -67.0, 121_920, 7_830, -2.0, 120),
                                    (-45, 170, 185_000, 7_793, 0, 300),
                                    (89, 10, 50_000, 3_000, 30, 5),
                                    (10, -100, 400_000, 7_700, -80, 45),
                                    (0, 0, 0, 408.6, 0, 90)]
        for c in cases {
            sim.place(v, geodeticLatitude: c.latitude, longitude: c.longitude, height: c.height,
                      inertialSpeed: c.speed, flightPathAngle: c.flightPathAngle, azimuth: c.azimuth)
            let s = readBack(v, in: sim)
            let label = "\(c)"
            XCTAssertEqual(s.latitude, c.latitude, accuracy: 1e-6, label)
            XCTAssertEqual(s.longitude, c.longitude, accuracy: 1e-6, label)
            XCTAssertEqual(s.height, c.height, accuracy: 1e-6, label)
            XCTAssertEqual(s.speed, c.speed, accuracy: 1e-6, label)
            XCTAssertEqual(s.flightPathAngle, c.flightPathAngle, accuracy: 1e-6, label)
            XCTAssertEqual(s.azimuth, c.azimuth, accuracy: 1e-6, label)
            XCTAssertEqual(v.status, .flying)
            XCTAssertNil(v.landed)
            XCTAssertEqual(v.angularVelocity, .zero)
            // The flight-path frame: +x along the velocity, +z towards the body.
            XCTAssertEqual((v.attitude.rotate(.unitX) - v.velocity.normalized).length, 0, accuracy: 1e-12, label)
            XCTAssertEqual(v.attitude.rotate(.unitZ).dot(v.position.normalized),
                           -cos(c.flightPathAngle * Double.pi / 180), accuracy: 1e-12, label)
        }
        XCTAssertEqual(v.altitude, 0, accuracy: 1e-6)
    }

    // Given what `placeInCircularOrbit` built, read back, `place` builds the
    // same position, velocity and attitude (prograde, +z down).
    func testAgreesWithCircularOrbit() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let a = VesselLibrary.capsule(), b = VesselLibrary.capsule()
        sim.add(a)
        sim.add(b)
        sim.placeInCircularOrbit(a, around: sim.system.earth, altitude: 185_000, inclination: 32.5, ascendingNode: 40,
                                 argumentOfLatitude: 70)
        let s = readBack(a, in: sim)
        XCTAssertEqual(s.flightPathAngle, 0, accuracy: 1e-9)
        sim.place(b, around: sim.system.earth, geodeticLatitude: s.latitude, longitude: s.longitude, height: s.height,
                  inertialSpeed: s.speed, flightPathAngle: s.flightPathAngle, azimuth: s.azimuth)
        XCTAssertEqual((b.position - a.position).length, 0, accuracy: 1e-6)
        XCTAssertEqual((b.velocity - a.velocity).length, 0, accuracy: 1e-6)
        for axis in [Vec3.unitX, .unitY, .unitZ] {
            XCTAssertEqual((b.attitude.rotate(axis) - a.attitude.rotate(axis)).length, 0, accuracy: 1e-9)
        }
    }

    // `attitude` turns the vessel from the flight-path frame: a half turn
    // about +z faces it retrograde.
    func testAttitudeFromTheFlightPathFrame() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.capsule()
        sim.add(v)
        sim.place(v, geodeticLatitude: 29.8, longitude: -67, height: 121_920, inertialSpeed: 7_830,
                  flightPathAngle: -2, azimuth: 120, attitude: Quat(w: 0, x: 0, y: 0, z: 1))
        XCTAssertEqual((v.attitude.rotate(.unitX) + v.velocity.normalized).length, 0, accuracy: 1e-12)
        XCTAssertLessThan(v.attitude.rotate(.unitZ).dot(v.position), 0)
    }
}
