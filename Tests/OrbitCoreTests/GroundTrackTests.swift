import XCTest
@testable import OrbitCore

final class GroundTrackTests: XCTestCase {
    let deg = Double.pi / 180
    let apollo11 = Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32)

    /// The capsule in a 185 km, 32.5° circular orbit at Apollo 11's launch
    /// epoch, with J2, the Sun, Moon and planets, and no air.
    func parkingOrbit() throws -> (Simulation, Vessel) {
        let system = try SolarSystem.bundled()
        let sim = Simulation(system: system, time: apollo11)
        sim.atmospheres[399] = NoAir()
        let v = VesselLibrary.capsule()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: system.earth, altitude: 185_000, inclination: 32.5,
                                 ascendingNode: 30, argumentOfLatitude: 10)
        return (sim, v)
    }

    // MARK: Secular J2

    /// Along an orbit integrated with J2, the mean elements built from each
    /// osculating state hold still (a to metres, where the osculating a swings
    /// by kilometres) and the node and mean longitude move at the secular
    /// rates: the check on the short-period terms' transcription.
    func testMeanElementsHoldAlongAJ2Orbit() throws {
        let (sim, v) = try parkingOrbit()
        let earth = sim.system.earth
        let pole = sim.snapshot.orientation(earth).pole
        let coast = VacuumCoast(body: earth, pole: pole)
        var s = Kepler.State(position: v.position, velocity: v.velocity)
        let first = SecularJ2Orbit(state: s, epoch: apollo11, body: earth, pole: pole)
        XCTAssertFalse(first.isTwoBody)
        var meanA: [Double] = [], oscA: [Double] = [], meanE: [Double] = [], meanI: [Double] = []
        var nodeError = 0.0, longitudeError = 0.0
        let dt = 120.0
        for k in 0...130 {
            let t = Double(k) * dt
            let orbit = SecularJ2Orbit(state: s, epoch: apollo11 + t, body: earth, pole: pole)
            meanA.append(orbit.meanSemiMajorAxis)
            meanE.append(orbit.meanEccentricity)
            meanI.append(orbit.meanInclination)
            oscA.append(OrbitalElements(position: s.position, velocity: s.velocity, mu: earth.gm).semiMajorAxis)
            let node = first.mean.node + first.nodeRate * t
            nodeError = max(nodeError, abs(remainder(orbit.mean.node - node, 2 * .pi)))
            let lambda0 = first.mean.node + first.mean.periapsis + first.mean.meanAnomaly
            let rate = first.nodeRate + first.periapsisRate + first.meanAnomalyRate
            let lambda = orbit.mean.node + orbit.mean.periapsis + orbit.mean.meanAnomaly
            longitudeError = max(longitudeError, abs(remainder(lambda - lambda0 - rate * t, 2 * .pi)))
            s = coast.propagate(s, by: dt)
        }
        func spread(_ x: [Double]) -> Double { x.max()! - x.min()! }
        print(String(format: "J2 mean elements over 3 orbits: a %.1f m (osculating %.0f m), e %.1e, i %.1e rad, "
                     + "node %.1e rad, mean longitude %.1e rad", spread(meanA), spread(oscA), spread(meanE),
                     spread(meanI), nodeError, longitudeError))
        XCTAssertGreaterThan(spread(oscA), 4_000)
        XCTAssertLessThan(spread(meanA), 20)
        XCTAssertLessThan(spread(meanE), 2e-5)
        XCTAssertLessThan(spread(meanI), 2e-6)
        // What is left in the mean longitude (3e-9 rad/s) is second order: the
        // first-order map defines a mean a some metres off Brouwer's.
        XCTAssertLessThan(nodeError, 2e-6)
        XCTAssertLessThan(longitudeError, 1e-4)
        // The orbit passes through its own state at its epoch.
        let back = first.state(at: apollo11)
        XCTAssertLessThan((back.position - v.position).length, 1e-3)
        XCTAssertLessThan((back.velocity - v.velocity).length, 1e-6)
    }

    // MARK: Prediction

    /// At 185 km and 32.5° the ascending node moves west by about 22.1° for
    /// the Earth's turn in one period and 0.47° for J2's regression,
    /// -3π J2 (R/p)² cos i per orbit (Vallado, Fundamentals of Astrodynamics
    /// and Applications, eq. 9-41), node to node along the predicted track.
    func testNodeDriftPerOrbit() throws {
        let (sim, v) = try parkingOrbit()
        let earth = sim.system.earth
        let a = earth.radius + 185_000
        let period = 2 * Double.pi * (a * a * a / earth.gm).squareRoot()
        let turn = EarthOrientation.rotationRate * period
        let regression = -3 * Double.pi * earth.j2 * (earth.radius / a) * (earth.radius / a) * cos(32.5 * deg)
        XCTAssertEqual(turn / deg, 22.1, accuracy: 0.05)
        XCTAssertEqual(regression / deg, -0.47, accuracy: 0.005)

        let track = GroundTrack.predict(v, snapshot: sim.snapshot, duration: 4.2 * period, step: 10)
        var nodes: [Double] = []
        for (p, q) in zip(track, track.dropFirst()) where p.latitude < 0 && q.latitude >= 0 {
            let f = -p.latitude / (q.latitude - p.latitude)
            nodes.append(p.longitude + f * remainder(q.longitude - p.longitude, 2 * .pi))
        }
        XCTAssertGreaterThanOrEqual(nodes.count, 4)
        let orbit = SecularJ2Orbit(state: Kepler.State(position: v.position, velocity: v.velocity), epoch: apollo11,
                                   body: earth, pole: sim.snapshot.orientation(earth).pole)
        let expected = -(EarthOrientation.rotationRate - orbit.nodeRate) * orbit.nodalPeriod
        for (n0, n1) in zip(nodes, nodes.dropFirst()) {
            let drift = remainder(n1 - n0, 2 * .pi)
            XCTAssertEqual(drift / deg, (-turn + regression) / deg, accuracy: 0.1)
            XCTAssertEqual(drift, expected, accuracy: 0.005 * deg)
        }
        print(String(format: "node drift per orbit: %.3f° (-22.1° - 0.47° at the Keplerian period: %.3f°)",
                     remainder(nodes[1] - nodes[0], 2 * .pi) / deg, (-turn + regression) / deg))
    }

    /// The predicted track against the simulator's full integration (J2,
    /// Sun, Moon, Venus and Jupiter, the Earth oriented by IAU 2006/2000B at
    /// every step) over three orbits: within 0.05°. The two-body conic alone
    /// is degrees off by then.
    func testAgainstFullIntegration() throws {
        let (sim, v) = try parkingOrbit()
        let period = v.elements(snapshot: sim.snapshot).period
        let track = GroundTrack.predict(v, snapshot: sim.snapshot, duration: 3 * period, step: 60)
        let kepler = GroundTrack.predict(v, snapshot: sim.snapshot, duration: 3 * period, step: 60, j2: false)
        XCTAssertEqual(track.count, kepler.count)
        var worst = 0.0, worstKepler = 0.0, worstHeight = 0.0
        for (p, k) in zip(track, kepler) {
            while p.time - sim.time > 1e-9 { sim.step(min(sim.maxStep(), p.time - sim.time)) }
            let g = sim.system.earth.geodetic(v.position, orientation: sim.snapshot.orientation(sim.system.earth))
            worst = max(worst, GreatCircle.angle(fromLatitude: p.latitude, longitude: p.longitude,
                                                 toLatitude: g.latitude, longitude: g.longitude))
            worstKepler = max(worstKepler, GreatCircle.angle(fromLatitude: k.latitude, longitude: k.longitude,
                                                             toLatitude: g.latitude, longitude: g.longitude))
            worstHeight = max(worstHeight, abs(p.height - g.height))
        }
        print(String(format: "ground track vs full integration over 3 orbits: %.4f° (height %.0f m); "
                     + "two-body %.2f°", worst / deg, worstHeight, worstKepler / deg))
        XCTAssertLessThan(worst, 0.05 * deg)
        XCTAssertGreaterThan(worstKepler, 0.5 * deg)
    }

    func testFirstPointIsTheVesselsSubPoint() throws {
        let (sim, v) = try parkingOrbit()
        let track = GroundTrack.predict(v, snapshot: sim.snapshot, duration: 600, step: 45)
        XCTAssertEqual(track.count, 15)
        XCTAssertEqual(track.last!.time - sim.time, 600, accuracy: 1e-9)
        let here = v.latitudeLongitude(snapshot: sim.snapshot)
        XCTAssertEqual(track[0].time, sim.time)
        XCTAssertEqual(track[0].latitude, here.lat, accuracy: 1e-10)
        XCTAssertEqual(track[0].longitude, here.lon, accuracy: 1e-10)
        XCTAssertEqual(track[0].height, v.altitude, accuracy: 1e-3)
    }

    /// After a deorbit burn the track stops at the first point under the surface.
    func testTrackEndsAtTheSurface() throws {
        let (sim, v) = try parkingOrbit()
        v.velocity = v.velocity * 0.97
        let track = GroundTrack.predict(v, snapshot: sim.snapshot, duration: 6_000, step: 20)
        XCTAssertLessThan(track.last!.height, 0)
        XCTAssertTrue(track.dropLast().allSatisfy { $0.height >= 0 })
        XCTAssertLessThan(track.last!.time - sim.time, 6_000)
    }

    // MARK: Sun

    /// The Sun's sub-point against JPL Horizons (DE441, ITRF93 with EOP),
    /// fetched 2026-10-19 from https://ssd.jpl.nasa.gov/api/horizons.api with
    /// COMMAND='399' CENTER='500@301' EPHEM_TYPE='OBSERVER' QUANTITIES='15,21'
    /// TIME_TYPE='UT' ANG_FORMAT='DEG' EXTRA_PREC='YES' and TLIST as below.
    /// Quantity 15 is the apparent planetodetic longitude and latitude of the
    /// centre of the Earth's disc seen from the Sun, light time and
    /// aberration included, for the Earth as the observer (on the Moon) saw it,
    /// one light time (quantity 21) before the print time. The test takes
    /// that line through the WGS 84 ellipsoid; the subsolar point proper,
    /// where the Sun is overhead, is nearer the equator by the difference of
    /// geodetic and geocentric latitude (0.13° in July).
    func testSubsolarPointAgainstHorizons() throws {
        let system = try SolarSystem.bundled()
        let rows: [(year: Int, month: Int, day: Int, hour: Int, minute: Int, lon: Double, lat: Double,
                    lightTime: Double)] = [
            (1968, 10, 22, 11, 12, 8.124372, -11.236425, 0.02014952),
            (1969, 7, 16, 13, 32, 338.494988, 21.475371, 0.02245443),
            (1969, 12, 21, 0, 0, 179.473465, -23.581858, 0.02201450),
        ]
        let figure = system.earth.figure
        var worst = 0.0
        for row in rows {
            let t = Epoch(utcYear: row.year, month: row.month, day: row.day, hour: row.hour, minute: row.minute)
                + -row.lightTime * 60
            let sun = GroundTrack.subsolarPoint(on: system.earth, sun: system.sun, snapshot: system.snapshot(at: t))
            let d = sun.direction
            let a = figure.equatorialRadius, b = figure.polarRadius
            let s = 1 / ((d.x * d.x + d.y * d.y) / (a * a) + d.z * d.z / (b * b)).squareRoot()
            let disc = figure.geodetic(d * s)
            let dLon = remainder(disc.longitude - row.lon * deg, 2 * .pi), dLat = disc.latitude - row.lat * deg
            worst = max(worst, abs(dLon), abs(dLat))
            XCTAssertEqual(dLon / deg, 0, accuracy: 0.001, "\(row.year)-\(row.month)-\(row.day)")
            XCTAssertEqual(dLat / deg, 0, accuracy: 0.001, "\(row.year)-\(row.month)-\(row.day)")

            // Overhead: the vertical at the subsolar point points at the Sun.
            let p = figure.bodyFixed(latitude: sun.latitude, longitude: sun.longitude, height: 0)
            let toSun = (d * 1.496e11 - p).normalized
            XCTAssertLessThan(angleBetween(figure.normal(latitude: sun.latitude, longitude: sun.longitude), toSun),
                              1e-4 * deg)
            XCTAssertEqual(sun.latitude, asin(d.z), accuracy: 0.003 * deg)     // parallax only
            XCTAssertLessThan(abs(sun.latitude), abs(disc.latitude))
        }
        print(String(format: "subsolar point vs Horizons: %.5f°", worst / deg))
    }

    func testTerminatorAndSolarElevation() throws {
        let system = try SolarSystem.bundled()
        let sun = GroundTrack.subsolarPoint(on: system.earth, sun: system.sun, snapshot: system.snapshot(at: apollo11))
        XCTAssertEqual(sun.solarElevation(latitude: sun.latitude, longitude: sun.longitude), .pi / 2, accuracy: 1e-7)
        XCTAssertEqual(sun.solarElevation(latitude: -sun.latitude, longitude: sun.longitude + .pi), -.pi / 2,
                       accuracy: 1e-7)
        let line = sun.terminator(points: 72)
        XCTAssertEqual(line.count, 73)
        XCTAssertEqual(line.first!.latitude, line.last!.latitude, accuracy: 1e-12)
        for p in line {
            XCTAssertEqual(sun.solarElevation(latitude: p.latitude, longitude: p.longitude), 0, accuracy: 1e-12)
        }
        for p in sun.terminator(points: 12, elevation: -0.833 * deg) {
            XCTAssertEqual(sun.solarElevation(latitude: p.latitude, longitude: p.longitude), -0.833 * deg,
                           accuracy: 1e-12)
        }
        for lon in stride(from: -180.0, through: 180, by: 15) {
            let lat = sun.terminatorLatitude(atLongitude: lon * deg)
            XCTAssertEqual(sun.solarElevation(latitude: lat, longitude: lon * deg), 0, accuracy: 1e-12)
        }
        // July: the north pole is in daylight.
        XCTAssertGreaterThan(sun.solarElevation(latitude: .pi / 2, longitude: 0), 0)
    }

    // MARK: Horizon

    func testHorizonCircle() {
        let r = 6_378_137.0
        XCTAssertEqual(GroundTrack.horizonAngle(height: 185_000, radius: r), acos(r / (r + 185_000)), accuracy: 1e-15)
        XCTAssertEqual(GroundTrack.horizonAngle(height: 185_000, radius: r) / deg, 13.64, accuracy: 0.01)
        XCTAssertEqual(GroundTrack.horizonAngle(height: 0, radius: r), 0)
        let circle = GroundTrack.horizonCircle(latitude: 0, longitude: 1, height: 185_000, figure: .wgs84, points: 36)
        XCTAssertEqual(circle.count, 37)
        for p in circle {
            XCTAssertEqual(GreatCircle.angle(fromLatitude: 0, longitude: 1, toLatitude: p.latitude,
                                             longitude: p.longitude), acos(r / (r + 185_000)), accuracy: 1e-12)
        }
        XCTAssertEqual(circle[0].latitude, acos(r / (r + 185_000)), accuracy: 1e-12)    // due north first
        let sphere = GroundTrack.horizonCircle(latitude: 0.7, longitude: -2, height: 1e6, figure: .sphere(r),
                                               points: 8)
        XCTAssertEqual(GreatCircle.angle(fromLatitude: 0.7, longitude: -2, toLatitude: sphere[3].latitude,
                                         longitude: sphere[3].longitude), acos(r / (r + 1e6)), accuracy: 1e-12)
    }

    // MARK: Recorder

    func testRecorder() {
        var rec = GroundTrackRecorder(capacity: 8, spacing: 1 * deg, interval: 100)
        let t0 = apollo11
        func point(_ t: Double, _ lon: Double) -> GroundTrack.Point {
            GroundTrack.Point(time: t0 + t, latitude: 0, longitude: lon * deg, height: 185_000)
        }
        rec.record(point(0, 0))
        rec.record(point(1, 0.1))
        XCTAssertEqual(rec.points.count, 2)
        rec.record(point(2, 0.2))           // the head is within 1° of the first: it moves
        XCTAssertEqual(rec.points.count, 2)
        XCTAssertEqual(rec.points.last!.longitude, 0.2 * deg, accuracy: 1e-15)
        rec.record(point(3, 1.5))
        XCTAssertEqual(rec.points.map(\.longitude).map { ($0 / deg * 10).rounded() / 10 }, [0, 1.5])
        rec.record(point(4, 1.6))           // the head is 1.5° on: kept, and a new head
        XCTAssertEqual(rec.points.count, 3)
        rec.record(point(200, 1.7))         // slow: the head moves...
        XCTAssertEqual(rec.points.count, 3)
        rec.record(point(201, 1.75))        // ...until it is the interval past the last kept point
        XCTAssertEqual(rec.points.count, 4)
        for k in 0..<20 { rec.record(point(300 + Double(k), 10 + 2 * Double(k))) }
        XCTAssertLessThanOrEqual(rec.points.count, 10)
        XCTAssertGreaterThanOrEqual(rec.points.count, 8)
        XCTAssertEqual(rec.points.last!.longitude, 48 * deg, accuracy: 1e-12)
        rec.record(point(50, 0))            // time went back: start again
        XCTAssertEqual(rec.points.count, 1)
        rec.reset()
        XCTAssertTrue(rec.points.isEmpty)
    }
}
