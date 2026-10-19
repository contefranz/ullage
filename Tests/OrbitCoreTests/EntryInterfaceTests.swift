import XCTest
@testable import OrbitCore

final class EntryInterfaceTests: XCTestCase {
    let deg = Double.pi / 180

    /// On a spherical, non-rotating body without J2, EI is where the conic
    /// meets R + 121,920 m: γ = -acos(h / (r v)) by vis-viva, at the time
    /// Kepler's equation gives.
    func testClosedFormOnASphere() {
        let mu = 3.986004418e14, radius = 6_378_137.0
        let body = CelestialBody(id: 1, name: "Sphere", gm: mu, radius: radius, rotation: .none,
                                 soiRadius: .infinity)
        let rp = radius + 50_000, ra = radius + 300_000, a = (rp + ra) / 2
        let start = Kepler.State(position: Vec3(0, -ra, 0), velocity: Vec3((mu * (2 / ra - 1 / a)).squareRoot(), 0, 0))
        let identity = BodyOrientation(icrfToBody: .identity, angularVelocity: .zero)
        let t0 = Epoch(tdbSecondsPastJ2000: 0)
        let ei = try! XCTUnwrap(EntryInterface.predict(from: start, around: body, orientation: identity, at: t0,
                                                       j2: false))
        let r = radius + EntryInterface.standardHeight
        let v = (mu * (2 / r - 1 / a)).squareRoot(), h = (mu * a * (1 - pow((ra - rp) / (ra + rp), 2))).squareRoot()
        XCTAssertEqual(ei.inertialFlightPathAngle, -acos(h / (r * v)), accuracy: 1e-9)
        XCTAssertEqual(ei.inertialSpeed, v, accuracy: 1e-5)
        XCTAssertEqual(ei.state.position.length, r, accuracy: 1e-4)
        XCTAssertEqual(ei.height, EntryInterface.standardHeight, accuracy: 1e-4)
        let el = OrbitalElements(position: start.position, velocity: start.velocity, mu: mu)
        let nu = try! XCTUnwrap(el.trueAnomalies(atRadius: r)).inbound
        XCTAssertEqual(ei.timeFromStart, try! XCTUnwrap(el.timeTo(trueAnomaly: nu)), accuracy: 1e-5)
        XCTAssertEqual(ei.time - t0, ei.timeFromStart, accuracy: 1e-9)
        XCTAssertEqual(ei.sweptAngle, nu - .pi, accuracy: 1e-9)
        // No rotation: relative is inertial.
        XCTAssertEqual(ei.relativeFlightPathAngle, ei.inertialFlightPathAngle, accuracy: 1e-12)
        XCTAssertEqual(ei.relativeSpeed, ei.inertialSpeed, accuracy: 1e-9)
        XCTAssertEqual(ei.groundRange, ei.sweptAngle * radius, accuracy: 1e-3)
        // In the plane z = 0 heading +x from -y, the motion is due east of a
        // +z pole and the EI point on the equator.
        XCTAssertEqual(ei.latitude, 0, accuracy: 1e-12)
    }

    /// Against the simulator stepping through 121.92 km in vacuum (J2, Sun,
    /// Moon and planets, the Earth oriented by IAU 2006/2000B at every step)
    /// after a 60 m/s retrograde burn from the 185 km parking orbit: within
    /// 0.1 s and 0.01°.
    func testAgainstSteppedVacuumCoast() throws {
        let system = try SolarSystem.bundled()
        let sim = Simulation(system: system, time: Epoch(utcYear: 1968, month: 10, day: 22, hour: 11, minute: 0))
        sim.atmospheres[399] = NoAir()
        let v = VesselLibrary.capsule()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: system.earth, altitude: 185_000, inclination: 31.6,
                                 ascendingNode: 200, argumentOfLatitude: 60)
        v.velocity -= v.velocity.normalized * 60
        let ei = try XCTUnwrap(EntryInterface.predict(v, snapshot: sim.snapshot))
        XCTAssertGreaterThan(ei.timeFromStart, 600)

        // Step to EI, finely over the last half minute, and interpolate.
        let earth = system.earth
        while ei.time - sim.time > 30 { sim.step(min(sim.maxStep(), ei.time - sim.time - 30)) }
        var before = (t: sim.time, h: v.altitude, r: v.position, v: v.velocity)
        while v.altitude > EntryInterface.standardHeight {
            before = (sim.time, v.altitude, v.position, v.velocity)
            sim.step(0.01)
        }
        let f = (before.h - EntryInterface.standardHeight) / (before.h - v.altitude)
        let time = before.t + f * (sim.time - before.t)
        let r = before.r + (v.position - before.r) * f, vel = before.v + (v.velocity - before.v) * f
        let gamma = EntryInterface.flightPathAngle(position: r, velocity: vel)
        let g = earth.geodetic(r, orientation: sim.snapshot.orientation(earth))
        let o = sim.snapshot.orientation(earth)
        let relative = EntryInterface.flightPathAngle(position: r, velocity: vel - o.angularVelocity.cross(r))
        print(String(format: "EI vs stepped vacuum coast: %.3f s, γ %.5f°, γ rel %.5f°, lat %.5f°, lon %.5f°; "
                     + "EI %.0f s after the burn at γ %.3f°", ei.time - time,
                     (ei.inertialFlightPathAngle - gamma) / deg, (ei.relativeFlightPathAngle - relative) / deg,
                     (ei.latitude - g.latitude) / deg, remainder(ei.longitude - g.longitude, 2 * .pi) / deg,
                     ei.timeFromStart, ei.inertialFlightPathAngle / deg))
        XCTAssertEqual(ei.time - time, 0, accuracy: 0.1)
        XCTAssertEqual(ei.inertialFlightPathAngle, gamma, accuracy: 0.01 * deg)
        XCTAssertEqual(ei.relativeFlightPathAngle, relative, accuracy: 0.01 * deg)
        XCTAssertEqual(ei.latitude, g.latitude, accuracy: 0.01 * deg)
        XCTAssertEqual(remainder(ei.longitude - g.longitude, 2 * .pi), 0, accuracy: 0.01 * deg)
        XCTAssertEqual(ei.inertialSpeed, vel.length, accuracy: 0.5)
        XCTAssertEqual(ei.inertialAzimuth, EntryInterface.azimuth(position: r, velocity: vel, pole: o.pole),
                       accuracy: 0.01 * deg)
        // The ground range is about the swept angle less the Earth's turn under it.
        XCTAssertLessThan(ei.groundRange, ei.sweptAngle * 6_371_000)
        XCTAssertGreaterThan(ei.groundRange, 0.9 * ei.sweptAngle * 6_371_000)
    }

    /// No EI from a circular parking orbit, a receding hyperbola, or a
    /// trajectory already below EI and falling.
    func testNoEntry() throws {
        let system = try SolarSystem.bundled()
        let sim = Simulation(system: system, time: Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32))
        let v = VesselLibrary.capsule()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: system.earth, altitude: 185_000, inclination: 32.5)
        XCTAssertNil(EntryInterface.predict(v, snapshot: sim.snapshot))
        v.velocity = v.velocity * 1.5
        XCTAssertNil(EntryInterface.predict(v, snapshot: sim.snapshot))
        v.position = v.position.normalized * (system.earth.radius + 100_000)
        v.velocity = -v.position.normalized * 1_000
        XCTAssertNil(EntryInterface.predict(v, snapshot: sim.snapshot))
        // Climbing from 100 km on a sub-orbital arc: it comes back down through EI.
        v.velocity = v.position.normalized * 2_000
        let ei = try XCTUnwrap(EntryInterface.predict(v, snapshot: sim.snapshot))
        XCTAssertEqual(ei.inertialFlightPathAngle, -90 * deg, accuracy: 0.01)
    }

    /// Ed Williams's Aviation Formulary worked examples (edwilliams.org/
    /// avform147.htm, fetched 2026-10-19): LAX (33°57'N 118°24'W) to JFK
    /// (40°38'N 73°47'W) is 0.623585 rad, the initial course 1.150035 rad (66°);
    /// D (34°30'N 116°30'W) is 0.00216747 rad right of that course and
    /// 0.0289691 rad along it. The page works with rounded intermediate values
    /// (D to seven figures in radians, its courses to six), which moves its
    /// cross-track figure by 3e-7 rad (2 m).
    func testGreatCirclesAgainstTheAviationFormulary() {
        func dm(_ d: Double, _ m: Double) -> Double { (d + m / 60) * deg }
        let lax = (lat: dm(33, 57), lon: -dm(118, 24)), jfk = (lat: dm(40, 38), lon: -dm(73, 47))
        let d = (lat: dm(34, 30), lon: -dm(116, 30))
        XCTAssertEqual(GreatCircle.angle(fromLatitude: lax.lat, longitude: lax.lon, toLatitude: jfk.lat,
                                         longitude: jfk.lon), 0.623585, accuracy: 1e-6)
        let course = GreatCircle.bearing(fromLatitude: lax.lat, longitude: lax.lon, toLatitude: jfk.lat,
                                         longitude: jfk.lon)
        XCTAssertEqual(course, 1.150035, accuracy: 1e-6)
        XCTAssertEqual(GreatCircle.crossTrackAngle(fromLatitude: lax.lat, longitude: lax.lon, bearing: course,
                                                   toLatitude: d.lat, longitude: d.lon), 0.00216747, accuracy: 5e-7)
        XCTAssertEqual(GreatCircle.alongTrackAngle(fromLatitude: lax.lat, longitude: lax.lon, bearing: course,
                                                   toLatitude: d.lat, longitude: d.lon), 0.0289691, accuracy: 1e-7)
        // Out along the course by the distance lands on JFK.
        let there = GreatCircle.destination(fromLatitude: lax.lat, longitude: lax.lon, bearing: course,
                                            angle: 0.6235846)
        XCTAssertEqual(there.latitude, jfk.lat, accuracy: 1e-6)
        XCTAssertEqual(there.longitude, jfk.lon, accuracy: 1e-6)
        XCTAssertEqual(GreatCircle.distance(fromLatitude: 0, longitude: 0, toLatitude: 0, longitude: .pi / 2,
                                            radius: 2), .pi, accuracy: 1e-12)
        XCTAssertEqual(GreatCircle.meanRadius(of: .wgs84), 6_371_008.77, accuracy: 0.01)
        // Behind the start, along-track is negative.
        XCTAssertLessThan(GreatCircle.alongTrackAngle(fromLatitude: 0, longitude: 0, bearing: .pi / 2,
                                                      toLatitude: 0.01, longitude: -0.2), 0)
    }
}
