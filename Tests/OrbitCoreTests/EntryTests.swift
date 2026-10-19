import XCTest
@testable import OrbitCore

/// Entry flight: the telemetry an entry is flown on (the bank angle about
/// the air-relative velocity, the sensed load factor, Sutton-Graves heating).
final class EntryTests: XCTestCase {
    /// Apollo 7's entry interface, 68-FM-184 Table IX(b) (H; the longitude's
    /// sign M): 31.03° N, 98.83° W, 400,000 ft, 25,850.3 ft/s inertial at
    /// -1.759° and azimuth 83.64°.
    static let apollo7EntryInterface = (latitude: 31.03, longitude: -98.83, height: 121_920.0,
                                        speed: 25_850.3 * 0.3048, flightPathAngle: -1.759, azimuth: 83.64)

    /// A simulation with a command module (centre of mass on the Z_A side,
    /// `ya` off it) at Apollo 7's entry interface.
    func commandModuleAtEntryInterface(ya: Double = 0) throws -> (Simulation, Vessel) {
        let sim = try Simulation.forTests(perturbations: true)
        let v = testCommandModule(center: (1040.58, ya, 5.91))
        sim.add(v)
        let ei = Self.apollo7EntryInterface
        sim.place(v, geodeticLatitude: ei.latitude, longitude: ei.longitude, height: ei.height, inertialSpeed: ei.speed,
                  flightPathAngle: ei.flightPathAngle, azimuth: ei.azimuth)
        return (sim, v)
    }

    /// The velocity of `v` relative to the air (no wind: the standard
    /// atmosphere) and the local vertical, ICRF.
    func airAndUp(_ v: Vessel, in sim: Simulation) -> (air: Vec3, up: Vec3) {
        let o = sim.snapshot.orientation(v.reference)
        return (v.velocity - o.angularVelocity.cross(v.position), v.reference.vertical(at: v.position, orientation: o))
    }

    /// Turn `v` heat shield first, its velocity relative to the air `alphaPrime`
    /// off -x towards its centre of mass's side, that side banked `bank` rad
    /// from the local up about the air velocity (positive to the right looking
    /// along it); then update its telemetry.
    func orient(_ v: Vessel, in sim: Simulation, bank: Double, alphaPrime: Double = 0) {
        let (air, up) = airAndUp(v, in: sim)
        let f = air.normalized, u = (up - f * up.dot(f)).normalized, right = f.cross(u)
        let lift = u * cos(bank) + right * sin(bank)
        // The centre of mass is on the -z side (+Z_A) of the axis.
        let x = f * -cos(alphaPrime) + lift * sin(alphaPrime)
        let side = f * sin(alphaPrime) + lift * cos(alphaPrime)
        let z = -side, y = z.cross(x)
        v.attitude = Quat(matrix: Mat3(columns: x, y, z))
        sim.updateTelemetry(v, snapshot: sim.snapshot)
    }

    /// The bank angle: 0 lift up, ±180° lift down, +90° with the lift to the
    /// right of the air velocity (looking along it), whatever the trim angle;
    /// a positive turn about the air velocity raises it; the lift side is
    /// where the centre of mass is, so a centre of mass off Z_A by Y_A shows.
    func testBankGeometry() throws {
        let (sim, v) = try commandModuleAtEntryInterface()
        for alphaPrime in [0.0, 0.4] {
            for bank in [0.0, 0.3, 1.0, Double.pi / 2, -0.9599, 3.0] {
                orient(v, in: sim, bank: bank, alphaPrime: alphaPrime)
                XCTAssertEqual(v.bankAngle!, bank, accuracy: 1e-9, "bank \(bank), α' \(alphaPrime)")
            }
            orient(v, in: sim, bank: .pi, alphaPrime: alphaPrime)
            XCTAssertEqual(abs(v.bankAngle!), .pi, accuracy: 1e-9, "lift down")
        }
        // Lift up is the crew heads down: the lift side, +Z_A (body -z), is up.
        orient(v, in: sim, bank: 0, alphaPrime: 0.4)
        let (air, up) = airAndUp(v, in: sim)
        XCTAssertGreaterThan(v.attitude.rotate(-Vec3.unitZ).dot(up), 0.9)
        // Turning the vessel 10° about the air velocity raises the bank 10°.
        let turn = Quat(axis: air.normalized, angle: 10 * Double.pi / 180)
        v.attitude = (turn * v.attitude).normalized
        sim.updateTelemetry(v, snapshot: sim.snapshot)
        XCTAssertEqual(v.bankAngle!, 10 * Double.pi / 180, accuracy: 1e-9)

        // Table I(a)'s centre of mass, 0.11 in towards -Y_A (construction +y,
        // the left of the air velocity when heads down), puts the lift side
        // atan(0.11 / 5.91) = 1.07° to the left.
        let (sim2, offset) = try commandModuleAtEntryInterface(ya: -0.11)
        orient(offset, in: sim2, bank: 0)
        XCTAssertEqual(offset.bankAngle!, -atan(0.11 / 5.91), accuracy: 1e-9)
    }

    /// The load factor is what an accelerometer reads: zero coasting above
    /// the air, thrust over mass in a burn, 1 g of normal gravity standing on
    /// the ground (WGS-84's at 28.6° N: 9.79217 m/s^2), and the trim drag
    /// over mass in the air (Table I(a)'s C_D at its Mach 10 trim, which the
    /// flight-consistent calibration holds at entry interface's Mach 18).
    func testSensedAcceleration() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let coast = VesselLibrary.capsule()
        sim.add(coast)
        sim.placeInCircularOrbit(coast, around: sim.system.earth, altitude: 1_200_000, inclination: 30)
        sim.tick()
        XCTAssertEqual(coast.loadFactor, 0, accuracy: 1e-12)
        XCTAssertNil(coast.bankAngle)
        XCTAssertEqual(coast.heatFlux, 0)

        coast.mainThrottle = 1
        sim.tick()
        let thrust = coast.thrusters.filter { $0.groups.contains(.main) }.map { $0.thrust(ambientPressure: 0, seaLevelPressure: 0) }
            .reduce(0, +)
        XCTAssertEqual(coast.sensedAcceleration.x, thrust / coast.mass, accuracy: 1e-9)
        XCTAssertEqual(coast.loadFactor, thrust / coast.mass / 9.80665, accuracy: 1e-9)

        let pad = VesselLibrary.capsule()
        sim.add(pad)
        sim.placeLanded(pad, on: sim.system.earth, latitude: 28.6, longitude: -80.6)
        XCTAssertEqual(pad.loadFactor, 9.792168 / 9.80665, accuracy: 1e-4)
        let up = pad.reference.vertical(at: pad.position, orientation: sim.snapshot.orientation(pad.reference))
        XCTAssertGreaterThan(pad.attitude.rotate(pad.sensedAcceleration.normalized).dot(up), 0.99999)

        let (entry, cm) = try commandModuleAtEntryInterface(ya: -0.11)
        orient(cm, in: entry, bank: 0, alphaPrime: .pi - CapsuleAerodynamics.apollo7TrimTable[12].angleOfAttack)
        XCTAssertGreaterThan(cm.mach, 10)
        let q = cm.dynamicPressure * CapsuleAerodynamics.apolloReferenceArea / cm.mass
        let drag = -cm.sensedAcceleration.dot(cm.attitude.inverseRotate(airAndUp(cm, in: entry).air.normalized))
        XCTAssertEqual(drag / q, 1.2307, accuracy: 1e-6)
        XCTAssertEqual(cm.loadFactor, q * (0.42515 * 0.42515 + 1.2307 * 1.2307).squareRoot() / 9.80665,
                       accuracy: 1e-9 * cm.loadFactor)
    }

    /// Sutton-Graves heating at the capsule's 184.8 in heat-shield radius:
    /// 1.7415e-4 sqrt(ρ / R_n) V^3, at the air-relative speed (here 70 km,
    /// ρ 8.283e-5 kg/m^3 from the 1976 table, 7.5 km/s: 308.6 kW/m^2).
    func testStagnationHeatFlux() throws {
        let (sim, v) = try commandModuleAtEntryInterface()
        sim.place(v, geodeticLatitude: 30, longitude: -90, height: 70_000, inertialSpeed: 7_900, flightPathAngle: -1,
                  azimuth: 90)
        let (air, _) = airAndUp(v, in: sim)
        let rho = USStandardAtmosphere1976().state(altitude: v.altitude).density
        XCTAssertEqual(v.altitude, 70_000, accuracy: 1e-6)
        XCTAssertEqual(rho, 8.283e-5, accuracy: 0.002e-5)
        XCTAssertEqual(v.heatFlux, 1.7415e-4 * (rho / 4.69392).squareRoot() * pow(air.length, 3), accuracy: 1e-6)
        let reference = 1.7415e-4 * (8.283e-5 / 4.69392).squareRoot() * pow(7_500, 3)
        XCTAssertEqual(reference, 308_627, accuracy: 1)
        // Out of the air there is none.
        sim.place(v, geodeticLatitude: 30, longitude: -90, height: 1_100_000, inertialSpeed: 7_300, flightPathAngle: 0,
                  azimuth: 90)
        XCTAssertEqual(v.heatFlux, 0)
        XCTAssertNotNil(v.bankAngle)
    }

    /// Flown through `Simulation` from Apollo 7's entry interface with no
    /// control, the CM holds the trim its centre of mass gives, lift on that
    /// side: through peak deceleration α stays within 2° of the trim, and
    /// when a CM entering lift down has fallen to 40 km, one entering lift
    /// up is still above 60 km.
    func testFliesTrimmedOnItsCentreOfMassSide() throws {
        var flights: [(sim: Simulation, v: Vessel, trim: Double)] = []
        for bank in [Double.pi, 0] {
            let (sim, v) = try commandModuleAtEntryInterface(ya: -0.11)
            let trim = v.activeAerodynamics!.capsule!.trim(mach: 10, centerOfMass: v.structuralCenterOfMass)!.alphaPrime
            orient(v, in: sim, bank: bank, alphaPrime: trim)
            flights.append((sim, v, trim))
        }
        var worst = [0.0, 0.0], peak = [0.0, 0.0], steps = 0
        while flights[0].v.altitude > 40_000 && steps < 30_000 {
            for (k, f) in flights.enumerated() {
                f.sim.step(0.02)
                if f.v.loadFactor > 0.5 { worst[k] = max(worst[k], abs((Double.pi - f.v.angleOfAttack) - f.trim)) }
                peak[k] = max(peak[k], f.v.loadFactor)
            }
            steps += 1
        }
        XCTAssertLessThan(flights[0].v.altitude, 40_000)
        XCTAssertGreaterThan(flights[1].v.altitude, 60_000, "lift up after \(Double(steps) * 0.02) s")
        for k in 0..<2 {
            XCTAssertLessThan(worst[k] * 180 / .pi, 2, "α off trim")
            XCTAssertGreaterThan(peak[k], 0.5)
        }
    }
}
