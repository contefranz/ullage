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

    /// Sutton-Graves heating at the CM's 1.65 m effective radius:
    /// 1.7415e-4 sqrt(ρ / R_n) V^3, at the air-relative speed (here 70 km,
    /// ρ 8.283e-5 kg/m^3 from the 1976 table, 7.5 km/s: 520.5 kW/m^2).
    func testStagnationHeatFlux() throws {
        let (sim, v) = try commandModuleAtEntryInterface()
        sim.place(v, geodeticLatitude: 30, longitude: -90, height: 70_000, inertialSpeed: 7_900, flightPathAngle: -1,
                  azimuth: 90)
        let (air, _) = airAndUp(v, in: sim)
        let rho = USStandardAtmosphere1976().state(altitude: v.altitude).density
        XCTAssertEqual(v.altitude, 70_000, accuracy: 1e-6)
        XCTAssertEqual(rho, 8.283e-5, accuracy: 0.002e-5)
        XCTAssertEqual(v.heatFlux, 1.7415e-4 * (rho / 1.65).squareRoot() * pow(air.length, 3), accuracy: 1e-6)
        let reference = 1.7415e-4 * (8.283e-5 / 1.65).squareRoot() * pow(7_500, 3)
        XCTAssertEqual(reference, 520_546, accuracy: 1)
        // The heat load integrates the flux step by step (the trapezoid
        // rule): over 20 s of flight it is the sum of the samples (to the
        // 1e-7 s an epoch resolves in each step).
        var expected = v.heatLoad, last = v.heatFlux
        for _ in 0..<1000 {
            sim.step(0.02)
            expected += 0.5 * (last + v.heatFlux) * 0.02
            last = v.heatFlux
        }
        XCTAssertGreaterThan(v.heatLoad, 20 * 200_000)
        XCTAssertEqual(v.heatLoad, expected, accuracy: 1e-5 * expected)
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

    // MARK: The entry autopilot and the entry program (E2's command module)

    /// Apollo 7's CM (E2's parts, Mission Report row) with the CM model.
    func apollo7CM(_ calibration: CapsuleAerodynamics.Calibration = .flightConsistent) -> Vessel {
        let v = VesselLibrary.commandModule(.apollo7)
        v.aerodynamics = [.apolloCommandModule(calibration: calibration)]
        return v
    }

    /// The entry autopilot from lift up to a 55° bank at Mach 22 (65 km): it
    /// is within its 4° dead band of the command in under 5 s, rolling no
    /// faster than 20°/s about the stability axis, with the rates across it
    /// under 3.5°/s (its 2°/s dead band, the rate loop's lag and the CM's
    /// products of inertia; 3.04°/s at most) and the trim
    /// undisturbed (α' within 1°); then it holds the bank inside 5°, and
    /// rolling flies its rate.
    func testEntryAutopilotRollsAboutTheStabilityAxis() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = apollo7CM()
        sim.add(v)
        sim.place(v, geodeticLatitude: 30, longitude: -80, height: 65_000, inertialSpeed: 7_300, flightPathAngle: -1,
                  azimuth: 90)
        let capsule = v.activeAerodynamics!.capsule!
        v.attitude = CMEntryProgram.trimAttitude(of: v, capsule: capsule, bank: 0, in: sim)!
        sim.updateTelemetry(v, snapshot: sim.snapshot)
        XCTAssertEqual(v.bankAngle!, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(v.mach, 20)
        let trim = Double.pi - v.angleOfAttack
        let deg = Double.pi / 180
        v.autopilot = .entry
        v.entryCommand = .bank(55 * deg)
        var reached: Double?, fastest = 0.0, across = 0.0, offTrim = 0.0
        for i in 1...250 {
            sim.tick()
            let w = v.stabilityAxis, about = v.angularVelocity.dot(w)
            fastest = max(fastest, abs(about))
            across = max(across, (v.angularVelocity - w * about).length)
            offTrim = max(offTrim, abs((Double.pi - v.angleOfAttack) - trim))
            if reached == nil, abs(v.bankAngle! - 55 * deg) < EntryAutopilot.bankDeadband { reached = Double(i) * 0.02 }
        }
        XCTAssertLessThan(reached ?? .infinity, 5)
        XCTAssertLessThan(fastest, 20.5 * deg)
        XCTAssertGreaterThan(fastest, 15 * deg)
        XCTAssertLessThan(across, 3.5 * deg)
        XCTAssertLessThan(offTrim, 1 * deg)
        for _ in 0..<1000 {
            sim.tick()
            XCTAssertEqual(v.bankAngle!, 55 * deg, accuracy: 5 * deg)
        }
        v.entryCommand = .rolling(rate: -15 * deg)
        sim.run(seconds: 5)
        var turned = 0.0, last = v.bankAngle!
        for _ in 0..<500 {
            sim.tick()
            turned += EntryAutopilot.wrap(v.bankAngle! - last)
            last = v.bankAngle!
        }
        XCTAssertEqual(turned / 10, -15 * deg, accuracy: 1.5 * deg)
    }

    /// The program sleeps while the "SM" is aboard and wakes once it has
    /// gone: CM RCS on, ELS armed, the launch day's sounding dropped, the
    /// trim attitude held; the pilot's Space key is its own only while it
    /// sleeps. Manual mode rolls at the pilot's rate and holds where it is
    /// let go.
    func testEntryProgramWakesWhenTheServiceModuleLeaves() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = apollo7CM()
        let sm = VesselPart(name: "SM", dryMass: 6_000, offset: ApolloAxes.construction(xa: 950), length: 3.9, radius: 1.96,
                            staging: .event(7))
        v.parts.append(sm)
        v.recenter()
        for t in v.thrusters { t.isEnabled = false }
        sim.add(v)
        sim.atmospheres[sim.system.earth.id] = AS506.launchDayAtmosphere()
        let ei = Self.apollo7EntryInterface
        // Retrograde, heat shield first and heads down, as after the deorbit
        // burn.
        sim.place(v, geodeticLatitude: ei.latitude, longitude: ei.longitude, height: 160_000, inertialSpeed: 7_800,
                  flightPathAngle: -1.6, azimuth: ei.azimuth, attitude: Quat(w: 0, x: 0, y: 0, z: 1))
        let program = CMEntryProgram(mode: .bankHold(0))
        v.flightProgram = program
        sim.run(seconds: 1)
        XCTAssertEqual(program.phase, .dormant)
        XCTAssertTrue(program.allowsManualStaging(of: v))
        XCTAssertEqual(program.status, "ENTRY standby")
        XCTAssertNotNil(sim.atmospheres[sim.system.earth.id])
        XCTAssertFalse(v.thrusters.contains { $0.isEnabled })

        XCTAssertNotNil(sim.stage(v, event: 7))
        sim.tick()
        XCTAssertEqual(program.phase, .preEntry)
        XCTAssertNil(sim.atmospheres[sim.system.earth.id])
        XCTAssertTrue(v.thrusters.filter { $0.name.hasPrefix("CM RCS") }.allSatisfy(\.isEnabled))
        XCTAssertTrue(program.els.isArmed)
        XCTAssertEqual(v.autopilot, .attitudeHold)
        XCTAssertFalse(program.allowsManualStaging(of: v))
        XCTAssertTrue(program.status.hasPrefix("ENTRY hold lift up | ELS armed"), program.status)
        // From the separation attitude the hold turns it to trim, lift up,
        // inside its 2° dead band on each axis.
        sim.run(seconds: 60)
        let goal = CMEntryProgram.trimAttitude(of: v, capsule: v.activeAerodynamics!.capsule!, bank: 0, in: sim)!
        XCTAssertLessThan(rotationVector(v.attitude.conjugate * goal).length, 3.5 * Double.pi / 180)   // 2° per axis
        XCTAssertEqual(v.phasePlane, CMEntryProgram.holdLaw)
        XCTAssertEqual(v.bankAngle!, 0, accuracy: 4 * Double.pi / 180)
        XCTAssertNotNil(program.prediction)

        // Manual: the pilot's roll keys roll it, and it holds where they stop.
        program.mode = .manual
        let deg = Double.pi / 180
        XCTAssertEqual(program.command(v), .bank(v.bankAngle!))
        program.pilotRoll = 1
        XCTAssertEqual(program.command(v), .rolling(rate: 20 * deg))
        program.pilotRoll = 0
        if case .bank(let held) = program.command(v) { XCTAssertEqual(held, v.bankAngle!, accuracy: 1e-12) } else { XCTFail() }
    }

    /// Manual mode before 0.05 g: the pre-entry hold keeps the bank where
    /// the pilot left it. It used to aim at the bank of the moment, so a
    /// slow roll left over (here 0.7°/s) never stopped: in the app's Apollo
    /// 7 CM the bank went from -55° to +50° before 0.05 g. The RCS keys move
    /// the held bank, and the hold keeps the new one once they are let go.
    func testManualHoldsTheBankBeforeEntry() throws {
        let deg = Double.pi / 180
        let sim = try Simulation.forTests(perturbations: true)
        let v = apollo7CM()
        sim.add(v)
        let ei = Self.apollo7EntryInterface
        sim.place(v, geodeticLatitude: ei.latitude, longitude: ei.longitude, height: ei.height, inertialSpeed: ei.speed,
                  flightPathAngle: ei.flightPathAngle, azimuth: ei.azimuth)
        let program = CMEntryProgram(mode: .bankHold(-55 * deg))
        v.flightProgram = program
        v.attitude = CMEntryProgram.trimAttitude(of: v, capsule: v.activeAerodynamics!.capsule!, bank: -55 * deg, in: sim)!
        sim.run(seconds: 2)
        program.mode = .manual
        let start = v.bankAngle!
        v.angularVelocity += Vec3(0.7 * deg, 0, 0)
        var drift = 0.0
        sim.run(seconds: 80) { drift = max(drift, abs(v.bankAngle! - start)) }
        XCTAssertEqual(program.phase, .preEntry)
        XCTAssertLessThan(drift, 5 * deg, "the pre-entry hold let the bank drift")

        // Rolled by hand (the RCS keys), it holds the new bank.
        v.setPilotInput(rotation: RotationCommand(roll: -1, pitch: 0, yaw: 0), translation: .zero)
        sim.run(seconds: 1)
        v.setPilotInput(rotation: RotationCommand(), translation: .zero)
        sim.run(seconds: 3)
        let rolled = v.bankAngle!
        XCTAssertGreaterThan(rolled - start, 5 * deg, "a roll to the left about +X raises the bank")
        drift = 0
        sim.run(seconds: 40) { drift = max(drift, abs(v.bankAngle! - rolled)) }
        XCTAssertEqual(program.phase, .preEntry)
        XCTAssertLessThan(drift, 5 * deg)
    }

    /// From Apollo 7's entry interface as flown (the onboard computer's
    /// 25,846.4 ft/s at -2.072°, Mission Report §5.16, H; position and
    /// azimuth from 68-FM-184 Table IX(b)), lift up as the crew flew it to
    /// 0.2 g: the program senses 0.05 g and 0.2 g within 6 s of the flight's
    /// program changes, 132 s and 160 s after entry interface (259:55:38
    /// and 259:56:06 against 259:53:26 GET); and the landing-point
    /// predictor, at a constant 55° from 68-FM-184's entry interface,
    /// converges on where the flight at 55° reaches the drogues' 24,000 ft:
    /// within 100 km at entry interface (the 6-DOF flight's bank wanders in
    /// its 4° dead band), 50 km 300 s on and 5 km 450 s on (Mach 11).
    func testPointZeroFiveGAndThePredictor() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = apollo7CM(.operational)
        sim.add(v)
        let ei = Self.apollo7EntryInterface
        sim.place(v, geodeticLatitude: ei.latitude, longitude: ei.longitude, height: ei.height,
                  inertialSpeed: 25_846.4 * 0.3048, flightPathAngle: -2.072, azimuth: ei.azimuth)
        let program = CMEntryProgram(mode: .bankHold(0))
        v.flightProgram = program
        v.attitude = CMEntryProgram.trimAttitude(of: v, capsule: v.activeAerodynamics!.capsule!, bank: 0, in: sim)!
        sim.updateTelemetry(v, snapshot: sim.snapshot)
        let t0 = sim.time
        var pointTwo: Double?
        while pointTwo == nil && sim.time - t0 < 300 {
            sim.tick()
            if v.loadFactor >= 0.2 { pointTwo = sim.time - t0 }
        }
        XCTAssertEqual(program.pointZeroFiveG.map { $0 - t0 } ?? 0, 132, accuracy: 6)
        XCTAssertEqual(pointTwo ?? 0, 160, accuracy: 6)
        XCTAssertEqual(program.phase, .entry)
        XCTAssertEqual(v.autopilot, .entry)
        XCTAssertTrue(sim.events.contains { $0.message.hasSuffix("0.05 g") })

        // The predictor against the flight at 55° from 68-FM-184's entry interface.
        let (flight, cm) = (try Simulation.forTests(perturbations: true), apollo7CM(.operational))
        flight.add(cm)
        flight.place(cm, geodeticLatitude: ei.latitude, longitude: ei.longitude, height: ei.height,
                     inertialSpeed: ei.speed, flightPathAngle: ei.flightPathAngle, azimuth: ei.azimuth)
        let bank = 55 * Double.pi / 180
        let entry = CMEntryProgram(mode: .bankHold(bank))
        cm.flightProgram = entry
        cm.attitude = CMEntryProgram.trimAttitude(of: cm, capsule: cm.activeAerodynamics!.capsule!, bank: bank, in: flight)!
        flight.updateTelemetry(cm, snapshot: flight.snapshot)
        flight.tick()
        let start = flight.time
        var predictions = [try XCTUnwrap(entry.prediction)], due = [300.0, 450]
        while cm.altitude > LandingPointPredictor().endAltitude && flight.time - start < 1_500 {
            for x in flight.vessels { flight.prepareControls(x) }
            flight.step(min(1, flight.maxStep()))
            if let next = due.first, flight.time - start >= next, let p = entry.prediction {
                predictions.append(p)
                due.removeFirst()
            }
        }
        let ll = cm.latitudeLongitude(snapshot: flight.snapshot)
        let misses = predictions.map { p in
            acos(min(1, sin(ll.lat) * sin(p.latitude) + cos(ll.lat) * cos(p.latitude) * cos(ll.lon - p.longitude))) * 6_371
        }
        print("predictor at EI, 300 s and 450 s, km from the flight at 24,000 ft:", misses)
        XCTAssertEqual(misses.count, 3)
        XCTAssertLessThan(misses[0], 100)
        XCTAssertLessThan(misses[1], 50)
        XCTAssertLessThan(misses[2], 5)
        XCTAssertGreaterThan(predictions[0].peakLoadFactor, 3)
    }
}
