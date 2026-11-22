import XCTest
@testable import OrbitCore

/// Water and land: the Earth's land mask (Natural Earth's 1:10m land
/// polygons, `tools/make_landmask.py`), sea level on the WGS-84 ellipsoid,
/// and the contact rules: a vessel comes to rest under its impact limit for
/// what it hits, afloat on water (Stable I, apex up) or on land; over it,
/// the vessel is a wreck and its engines stop where they are.
final class SplashdownTests: XCTestCase {
    let deg = Double.pi / 180

    // Known points: LC-39A, the Sahara, Antarctica and London are land, and
    // so is Lake Superior (Natural Earth's land holds the lakes); Apollo 7's
    // recovery point (27.54° N, 64.07° W, Mission Report §5.16), its planned
    // point (29.8° N, 67.0° W, 68-FM-184 §5.4.3), Apollo 11's target
    // (13°19' N, 169°10' W), the Caspian and the open Pacific are water.
    // Weighted by area, 28.8 % of the cells are land, against the Earth's
    // 29.2 % (148.9 of 510.1 million km^2).
    func testLandMaskAtKnownPoints() throws {
        let mask = try XCTUnwrap(SurfaceMask.earth)
        XCTAssertEqual(mask.columns, 1_440)
        XCTAssertEqual(mask.rows, 720)
        let points: [(String, Double, Double, SurfaceKind)] = [
            ("LC-39A", AS506.padLatitude, AS506.padLongitude, .land), ("Sahara", 23, 13, .land),
            ("Antarctica", -85, 0, .land), ("London", 51.5, -0.1, .land), ("Lake Superior", 47.7, -87.5, .land),
            ("Apollo 7 recovery", 27.54, -64.07, .water), ("Apollo 7 planned", 29.8, -67.0, .water),
            ("Apollo 11 target", 13 + 19.0 / 60, -(169 + 10.0 / 60), .water), ("Caspian", 42, 51, .water),
            ("Pacific", 0, -150, .water),
        ]
        let earth = try SolarSystem.bundled().earth
        for (name, lat, lon, kind) in points {
            XCTAssertEqual(mask.kind(latitude: lat * deg, longitude: lon * deg), kind, name)
            XCTAssertEqual(earth.surfaceKind(latitude: lat * deg, longitude: lon * deg), kind, name)
            XCTAssertEqual(mask.kind(latitude: lat * deg, longitude: (lon + 360) * deg), kind, name)
        }
        XCTAssertEqual(try SolarSystem.bundled().moon.surfaceKind(latitude: 0, longitude: 0), .land)

        var land = 0.0, total = 0.0
        for row in 0..<mask.rows {
            let lat = (-90 + (Double(row) + 0.5) * 0.25) * deg
            for column in 0..<mask.columns where mask.kind(latitude: lat, longitude: (-180 + (Double(column) + 0.5) * 0.25) * deg) == .land {
                land += cos(lat)
            }
            total += Double(mask.columns) * cos(lat)
        }
        XCTAssertEqual(land / total, 0.292, accuracy: 0.01)
    }

    /// `v` coming down at `speed` m/s over the rotating surface at
    /// `latitude`, `longitude` (degrees), +x up, one step above contact.
    /// Returns the simulation once it has stepped through the contact.
    func drop(_ v: Vessel, latitude: Double, longitude: Double, speed: Double) throws -> Simulation {
        let sim = try Simulation.forTests(perturbations: false)
        sim.add(v)
        let clearance = min(v.baseHeight, v.boundingRadius)
        sim.place(v, geodeticLatitude: latitude, longitude: longitude, height: clearance * 0.9 + 0.05,
                  inertialSpeed: 100, flightPathAngle: -90, azimuth: 0)
        let o = sim.snapshot.orientation(v.reference)
        let up = v.reference.vertical(at: v.position, orientation: o)
        let east = o.pole.cross(up).normalized, north = up.cross(east)
        // Tilted 20° about north, as a CM hangs under its mains.
        let tilted = Quat(axis: north, angle: 20 * deg)
        v.attitude = (tilted * Quat(matrix: Mat3(columns: up, east, north))).normalized
        v.velocity = o.angularVelocity.cross(v.position) - up * speed
        sim.updateTelemetry(v, snapshot: sim.snapshot)
        sim.step(0.02)
        XCTAssertNotEqual(v.status, .flying)
        return sim
    }

    func speed(in message: String) -> Double? {
        let words = message.split(separator: " ")
        guard let i = words.firstIndex(of: "at"), i + 1 < words.count else { return nil }
        return Double(words[i + 1])
    }

    // The CM on the water under its mains' 9.5 m/s: "splashdown at x m/s",
    // afloat in Stable I (apex up) at sea level, which is the ellipsoid, and
    // riding the rotating Earth from then on.
    func testSplashdownOnWater() throws {
        let v = VesselLibrary.commandModule(.apollo7)
        let sim = try drop(v, latitude: 29.8, longitude: -67, speed: 9.5)
        XCTAssertEqual(v.status, .landed)
        let landed = try XCTUnwrap(v.landed)
        XCTAssertEqual(landed.surface, .water)
        let message = try XCTUnwrap(sim.events.last?.message)
        XCTAssertTrue(message.hasPrefix("Apollo 7: splashdown at "), message)
        XCTAssertEqual(try XCTUnwrap(speed(in: message)), 9.7, accuracy: 0.1)
        let o = sim.snapshot.orientation(v.reference)
        let up = v.reference.vertical(at: v.position, orientation: o)
        XCTAssertEqual(v.attitude.rotate(.unitX).dot(up), 1, accuracy: 1e-12)
        let fixed = landed.bodyFixedPosition
        for _ in 0..<6 { sim.advance(by: 10) }
        XCTAssertEqual(v.status, .landed)
        XCTAssertEqual((try XCTUnwrap(v.landed).bodyFixedPosition - fixed).length, 0, accuracy: 1e-6)
        XCTAssertEqual(v.altitude, v.baseHeight, accuracy: 1e-6)
        XCTAssertEqual(v.surfaceVelocity(snapshot: sim.snapshot).length, 0, accuracy: 1e-6)
    }

    // The same CM at the same speed on land crashes (5 m/s), and so does one
    // hitting the water above its 15 m/s.
    func testWaterVersusLand() throws {
        let onLand = VesselLibrary.commandModule(.apollo7)
        let sahara = try drop(onLand, latitude: 23, longitude: 13, speed: 9.5)
        XCTAssertEqual(onLand.status, .crashed)
        XCTAssertEqual(onLand.landed?.surface, .land)
        XCTAssertEqual(sahara.events.last?.message, "Apollo 7: impact at 10 m/s")

        let fast = VesselLibrary.commandModule(.apollo7)
        let atlantic = try drop(fast, latitude: 29.8, longitude: -67, speed: 20)
        XCTAssertEqual(fast.status, .crashed)
        XCTAssertEqual(fast.landed?.surface, .water)
        XCTAssertEqual(atlantic.events.last?.message, "Apollo 7: water impact at 20 m/s")
    }

    /// The readouts the vehicle panel and the MFDs show from a vessel's
    /// telemetry: thrust acceleration (m/s^2), load factor (g), airspeed,
    /// dynamic pressure, Mach number and altitude.
    struct Readouts: Equatable {
        var thrust, load, airspeed, q, mach, altitude: Double
        init(_ v: Vessel) {
            (thrust, load, airspeed, q, mach) = (v.thrustAcceleration, v.loadFactor, v.airspeed, v.dynamicPressure, v.mach)
            altitude = v.altitude
        }
    }

    /// A Saturn V (no flight program) coming down on the Sahara at 30 m/s
    /// through still air, under S-IC thrust, with its S-II ullage motors lit
    /// and its SM's -X jets firing (as they do from CM/SM separation),
    /// stepped through the impact. Returns the simulation, the stack, those
    /// thirteen engines, the engines delivering into the impact step and the
    /// readouts then. The Earth keeps its J2 (`forTests` without
    /// perturbations drops it), so the wreck rests in normal gravity.
    func crashUnderThrust() throws -> (sim: Simulation, stack: Vessel, lit: [Thruster], running: [Thruster],
                                       before: Readouts) {
        let sim = try Simulation.forTests(perturbations: false)
        sim.system.earth.j2 = try SolarSystem.bundled().earth.j2
        let stack = VesselLibrary.saturnV()
        stack.flightProgram = nil
        sim.add(stack)
        let clearance = min(stack.baseHeight, stack.boundingRadius)
        sim.place(stack, geodeticLatitude: 23, longitude: 13, height: clearance + 20, inertialSpeed: 30,
                  flightPathAngle: -90, azimuth: 0)
        // Falling at 30 m/s through still air, not the inertial frame.
        let o = sim.snapshot.orientation(stack.reference)
        let up = stack.reference.vertical(at: stack.position, orientation: o)
        stack.velocity = o.angularVelocity.cross(stack.position) - up * 30
        sim.updateTelemetry(stack, snapshot: sim.snapshot)
        let f1s = stack.thrusters.filter { $0.name.hasPrefix("S-IC engine") }
        let solids = stack.thrusters.filter { $0.name.hasPrefix("S-II ullage motor") }
        let jets = stack.thrusters.filter { $0.sequence?.start == 0 }
        XCTAssertEqual([f1s.count, solids.count, jets.count], [5, 4, 4])
        for m in solids { XCTAssertTrue(m.ignite(), m.name) }
        for j in jets { XCTAssertTrue(j.startSequence(), j.name) }
        stack.mainThrottle = 1
        var running: [Thruster] = [], before = Readouts(stack)
        let start = sim.time
        while stack.status == .flying, sim.time - start < 10 {
            (running, before) = (stack.thrusters.filter(\.isDelivering), Readouts(stack))
            step(sim)
        }
        XCTAssertEqual(stack.status, .crashed)
        return (sim, stack, f1s + solids + jets, running, before)
    }

    func step(_ sim: Simulation) {
        for v in sim.vessels { sim.prepareControls(v) }
        sim.step(0.02)
    }

    // An impact stops every engine where it stands. The simulation steps a
    // wreck no more, so nothing else would end a running F-1's shutdown
    // ramp, put out a lit solid or close an SM jet's firing sequence: each
    // would keep the impact step's output for the plumes, the navball's
    // thrust marker and the panels.
    func testImpactStopsTheEngines() throws {
        let (sim, stack, lit, running, _) = try crashUnderThrust()
        // All three kinds were delivering into the impact step.
        for t in lit { XCTAssertTrue(running.contains { $0 === t }, t.name) }
        for _ in 0..<3 {
            for t in stack.thrusters {
                XCTAssertFalse(t.isDelivering, t.name)
                XCTAssertFalse(t.isCommanded, t.name)
            }
            step(sim)
        }
    }

    // A wreck's telemetry reads it at rest where it lies, its engines
    // stopped, as a landed vessel's does, and holds. The simulation steps a
    // wreck no more, so it would otherwise keep the impact step's thrust,
    // load factor and air data for the vehicle panel's TWR and the MFDs
    // (SURFACE's THR, ACC, TAS, q and M; ENTRY's G). At rest, in still air,
    // the load factor is the support against normal gravity: 9.788213 m/s^2
    // on the WGS-84 ellipsoid at 23° N (Somigliana's formula), less the
    // free-air gradient, 3.086e-6 s^-2, over the 33 m the centre of mass
    // stands above it (1.0e-4 m/s^2). Without J2 it would be 9.7794 m/s^2.
    func testWreckTelemetryAtRest() throws {
        let (sim, stack, _, _, before) = try crashUnderThrust()
        XCTAssertGreaterThan(before.thrust / standardGravity, 1)
        XCTAssertGreaterThan(before.load, 1)
        XCTAssertGreaterThan(before.airspeed, 20)
        let atRest = Readouts(stack)
        XCTAssertEqual(atRest.thrust, 0)
        let s2 = pow(sin(23 * deg), 2)
        let normal = 9.7803253359 * (1 + 0.00193185265241 * s2) / (1 - 0.00669437999013 * s2).squareRoot()
        XCTAssertEqual(atRest.load, (normal - 3.086e-6 * atRest.altitude) / standardGravity, accuracy: 2e-5)
        XCTAssertEqual(atRest.airspeed, 0, accuracy: 1e-6)
        XCTAssertEqual(atRest.q, 0, accuracy: 1e-6)
        XCTAssertEqual(atRest.mach, 0, accuracy: 1e-6)
        XCTAssertEqual(atRest.altitude, min(stack.baseHeight, stack.boundingRadius), accuracy: 1e-3)
        for _ in 0..<3 {
            step(sim)
            XCTAssertEqual(Readouts(stack), atRest)
        }
    }

    // M0's rule is unchanged for every other vessel: 5 m/s on any surface,
    // logged "touchdown" on land; a vessel placed on the pad rests on land.
    func testM0LimitsUnchanged() throws {
        XCTAssertEqual(ImpactLimits.standard, ImpactLimits(water: 5, land: 5))
        XCTAssertEqual(VesselLibrary.capsule().impactLimits, .standard)
        for (latitude, longitude, kind) in [(23.0, 13.0, SurfaceKind.land), (29.8, -67.0, .water)] {
            let slow = VesselLibrary.capsule()
            let sim = try drop(slow, latitude: latitude, longitude: longitude, speed: 4.5)
            XCTAssertEqual(slow.status, .landed)
            XCTAssertEqual(slow.landed?.surface, kind)
            let word = kind == .land ? "touchdown" : "splashdown"
            XCTAssertEqual(sim.events.last?.message, "Capsule: \(word) at 4.7 m/s")
            let hard = VesselLibrary.capsule()
            _ = try drop(hard, latitude: latitude, longitude: longitude, speed: 5.5)
            XCTAssertEqual(hard.status, .crashed)
        }
        let sim = try Simulation.forTests(perturbations: false)
        let pad = VesselLibrary.capsule()
        sim.add(pad)
        sim.placeLanded(pad, on: sim.system.earth, latitude: AS506.padLatitude, longitude: AS506.padLongitude)
        XCTAssertEqual(pad.landed?.surface, .land)
    }
}
