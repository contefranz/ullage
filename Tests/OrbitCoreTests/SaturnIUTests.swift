import XCTest
@testable import OrbitCore

/// The Saturn V Instrument Unit's flight program on Apollo 11 (`SaturnIU.as506()`,
/// M1 item 3; datasheet §8 and §10). External references: the Apollo 11
/// timeline (SP-4029; datasheet §1.2), AS-506's Flight Evaluation Report
/// (MPR-SAT-FE-69-9, "FER"), the SA-504 guidance equations (Boeing
/// D5-15706-4, "GE504") and the SA-503 flight manual (MSFC-MAN-503, "MAN503").
final class SaturnIUTests: XCTestCase {
    let deg = Double.pi / 180

    /// Apollo 11 on LC-39A with the IU aboard and the F-1s lit, so the first
    /// step is first motion (range time 0.30 s).
    struct Flight {
        let sim: Simulation
        let v: Vessel
        let iu: SaturnIU
        /// Range time now, s.
        func range() -> Double { sim.time - AS506.rangeZero }
        /// Range time of an IU log entry.
        func range(_ e: Epoch) -> Double { e - AS506.rangeZero }
        /// Fixed 0.02 s steps to `range` s; `each` runs after every step.
        func fly(to range: Double, each: () -> Void = {}) {
            while self.range() < range - 1e-9 {
                sim.tick()
                each()
            }
        }
    }

    func launch() throws -> Flight {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo11OnPad(in: sim)
        v.mainThrottle = 1
        return Flight(sim: sim, v: v, iu: v.flightProgram as! SaturnIU)
    }

    // The stack stands on the pad as Apollo 11 did (datasheet §15): at
    // LC-39A's geodetic latitude on the WGS-84 Earth (AS-506's launch
    // vertical, FER; GE504), its base 26 m above the ellipsoid, nose up
    // along the normal, Position I (+z) east, the 90° pad azimuth (TVC
    // datasheet §7.1; GE504's initial roll A_Z - 90°), with the IU armed and
    // nothing commanded yet. Independent checks of the placement: the
    // centre of mass is at SP-4029's geocentric latitude, 28.4470°, within
    // 0.0002°, and within 40 m of the radius of AS-506's postflight
    // trajectory at first motion, 6,373,355 m (PFT, H); the Earth's rotation
    // carries it at SP-4029's liftoff inertial velocity, 408.64 m/s
    // (1,340.7 ft/s) to the east. Space is refused: it would drop the S-IC
    // on the pad. Range zero, the app's GET zero, is 13:32:00 UTC, 0.30 s
    // before first motion (SP-4029).
    func testOnThePad() throws {
        let sim = try Simulation.forTests(perturbations: true)
        XCTAssertEqual(sim.time, VesselLibrary.apollo11FirstMotion)
        XCTAssertEqual(VesselLibrary.apollo11RangeZero.description, "1969-07-16 13:32:00.000 UTC")
        XCTAssertEqual(VesselLibrary.apollo11FirstMotion - VesselLibrary.apollo11RangeZero, 0.30, accuracy: 1e-6)
        let v = VesselLibrary.apollo11OnPad(in: sim)
        let ll = v.latitudeLongitude(snapshot: sim.snapshot)
        XCTAssertEqual(ll.lat / deg, 28.6084, accuracy: 1e-9)
        XCTAssertEqual(ll.lon / deg, -80.6041, accuracy: 1e-9)
        XCTAssertEqual(v.altitude, AS506.padElevation + v.baseHeight, accuracy: 1e-6)
        let o = sim.snapshot.orientation(sim.system.earth)
        let up = sim.system.earth.vertical(at: v.position, orientation: o), pole = o.pole
        let east = pole.cross(up).normalized
        XCTAssertGreaterThan(v.attitude.rotate(.unitX).dot(up), 1 - 1e-12)
        XCTAssertGreaterThan(v.attitude.rotate(.unitZ).dot(east), 1 - 1e-12)
        XCTAssertEqual(asin(v.position.normalized.dot(pole)) / deg, AS506.padGeocentricLatitude, accuracy: 0.0002)
        XCTAssertEqual(v.position.length, 6_373_355, accuracy: 40)
        XCTAssertEqual(v.velocity.length, 408.64, accuracy: 0.05)
        XCTAssertGreaterThan(v.velocity.normalized.dot(east), 1 - 1e-12)
        sim.run(seconds: 5)
        let iu = v.flightProgram as! SaturnIU
        XCTAssertEqual(v.status, .landed)
        XCTAssertNil(v.autopilot)
        XCTAssertNil(iu.timeBases[.t1])
        XCTAssertEqual(iu.status, "on the pad")
        let parts = v.parts.map(\.name)
        XCTAssertNil(sim.stage(v))
        XCTAssertEqual(v.parts.map(\.name), parts)
        XCTAssertEqual(sim.events.last?.message, "Apollo 11: staging inhibited by the flight program")
    }

    // GE504 Table 5-I, read from the page images: the four segments of
    // SA-504's pre-IGM pitch polynomial join (to within 0.05°; a misread
    // digit would break that), the command is near zero where the program
    // starts (12-13 s), the pitch rate never exceeds the 1°/s command limit,
    // and the command is -66.59° at SA-504's 153 s arrest and held there. It
    // follows AS-506's predicted command (MAN-506 Figure 2-2, read to about
    // 1°: -20° a minute after first motion, -56° at two minutes, -67.5° at
    // the arrest; first motion is T1 - 0.4 s there). The IU flies AS-506's
    // own command instead, reconstructed in the same form
    // (`AscentResidualTests.testFittedPitchProgramAgainstTheReconstruction`),
    // arrested at T1 + 159.37 s (FER: 160.0 s range) on AS-506's held -68.90°.
    func testPitchPolynomialTranscription() {
        let p = TiltProgram(boundaries: AS506.pitchSegmentBoundaries, coefficients: AS506.sa504PitchCoefficients,
                            arrest: 153)
        let as506 = AS506.tiltProgram
        XCTAssertEqual(as506.coefficients, AS506.pitchCoefficients)
        XCTAssertEqual(as506.boundaries, p.boundaries)
        XCTAssertEqual(as506.arrest, 160.0 - 0.63, accuracy: 1e-12)
        XCTAssertEqual(as506.pitch(at: 170) / deg, -68.90, accuracy: 1e-9)
        let unscaled = TiltProgram(boundaries: p.boundaries, coefficients: p.coefficients, arrest: as506.arrest)
        XCTAssertEqual(unscaled.pitch(at: 59.6) / deg, -20, accuracy: 2)
        XCTAssertEqual(unscaled.pitch(at: 119.6) / deg, -56, accuracy: 2)
        XCTAssertEqual(unscaled.pitch(at: 170) / deg, -67.5, accuracy: 2)
        func segment(_ k: Int, _ t: Double) -> Double {
            p.coefficients[k].reversed().reduce(0.0) { $0 * t + $1 }
        }
        for (k, b) in p.boundaries.enumerated() {
            XCTAssertEqual(segment(k, b), segment(k + 1, b), accuracy: 0.05, "boundary \(b) s")
        }
        XCTAssertEqual(p.pitch(at: 12) / deg, 0, accuracy: 0.1)
        XCTAssertEqual(p.pitch(at: 153) / deg, -66.59, accuracy: 0.01)
        XCTAssertEqual(p.pitch(at: 170), p.pitch(at: 153))
        // Rates within each segment (the joins are steps of a few hundredths).
        let edges = [12.0] + p.boundaries + [153.0]
        var worst = 0.0
        for k in 0..<edges.count - 1 {
            var t = edges[k]
            while t < edges[k + 1] {
                let rate = p.coefficients[k].enumerated().dropFirst().reduce(0.0) {
                    $0 + Double($1.offset) * $1.element * pow(t, Double($1.offset - 1))
                }
                worst = max(worst, abs(rate))
                t += 0.01
            }
        }
        XCTAssertLessThan(worst, 1)   // deg/s
    }

    // The first 45 s. The tower-clearance yaw commands chi_Z = 1.25° from T1
    // + 1.0 s to T1 + 8.75 s (GE504 Table 4-II), at the 1°/s command limit
    // (GE504 §2.1.2), so the manoeuvre ends at T1 + 10.0 s (the FER's
    // prediction; MAN503 lists its end at T1 + 9.0): the nose leans away from
    // the tower, which stands to the north. The roll and pitch programs start
    // when the stack has risen 137 m (GE504 §4.1.2; the 13 s backup is not
    // needed). The roll takes Position I from the 90° pad azimuth to the
    // 72.058° flight azimuth (SP-4029, H) at 1.00°/s. With the S-IC roll
    // gains (0.245 and 0.15 s, Boeing D5-15481-1 Table 3-IV: L) and its roll
    // attitude-gain filter 2.35/(s + 2.35) (§3.5: L) the start overshoots:
    // AS-506 peaked at a 0.92° roll error and a 1.38°/s roll rate (FER Table
    // 11-2, 0.6 and 1.2 s after its logged 13.2 s start), the model at 0.81°
    // and 1.24°/s, 1.3 and 2.0 s after its start. Without the filter the
    // loop on FER Table 20-10's roll inertia is near critically damped (zeta
    // 0.90): the error peaks at 0.59° (the steady lag) and the rate at
    // 1.00°/s, which both checks below reject; the 1.39°/s it gave before
    // came from a roll inertia 9.5 times too large (zeta 0.29). The model's
    // start is still more damped than AS-506's, a known deviation (datasheet
    // §13.4): FER Figure 11-3 dips to about 0.56°/s 2 s after the peak, the
    // model to 0.94°/s, and AS-506's rate carries an oscillation of
    // ±0.10-0.15°/s at about 0.25 Hz through the whole ramp, which neither
    // MSFC's post-flight simulation in the same figure nor this rigid-body
    // model has. The rate is checked against AS-506's 1.38°/s within 0.2°/s.
    // Later in the ramp the law tracks it (a1/a0) x 1°/s =
    // 0.61° behind, and the stack settles on the flight azimuth. No commanded
    // angle ever moves faster than 1°/s.
    func testTowerYawAndRollProgram() throws {
        let f = try launch()
        var lastChi: Vec3?, worstRate = 0.0, maxYaw = 0.0, northward = 1.0
        var riseAtStart: (before: Double, at: Double)?, rises = [0.0, 0.0], rollLag: [Double] = []
        var rollRate: [Double] = []
        var peakRollError = 0.0, peakRollRate = 0.0
        let r0 = f.v.position.length
        let north = { () -> Vec3 in
            let up = f.v.position.normalized, pole = f.sim.snapshot.orientation(f.sim.system.earth).pole
            return up.cross(pole.cross(up).normalized)
        }
        f.fly(to: 45) {
            // The IU acts at the start of a step, on the rise the last one left.
            if riseAtStart == nil && f.iu.programStarted != nil { riseAtStart = (rises[0], rises[1]) }
            rises = [rises[1], f.v.position.length - r0]
            guard f.iu.timeBases[.t1] != nil else { return }
            let chi = f.iu.chi
            if let last = lastChi {
                let d = chi - last
                worstRate = max(worstRate, abs(d.x), abs(d.y), abs(d.z))
            }
            lastChi = chi
            maxYaw = max(maxYaw, chi.z)
            let t = f.range()
            if t > 4 && t < 9 { northward = min(northward, -f.v.attitude.rotate(.unitX).dot(north())) }
            let t1 = t - AS506.liftoff
            guard let started = f.iu.programStarted, let actual = f.iu.eulerAngles(of: f.v.attitude) else { return }
            peakRollError = max(peakRollError, abs(chi.x - actual.x) / deg)
            peakRollRate = max(peakRollRate, abs(f.v.angularVelocity.x) / deg)
            if t1 > started + 9, t1 < started + 17 {
                rollLag.append((chi.x - actual.x) / deg)
                rollRate.append(f.v.angularVelocity.x / deg)
            }
        }
        // Yaw: up to 1.25°, nose to the south of the vertical (towards +Y,
        // azimuth 162°), back to zero by T1 + 10.0 s.
        XCTAssertEqual(maxYaw / deg, 1.25, accuracy: 1e-9)
        XCTAssertGreaterThan(northward, 0.01)   // southward lean of the nose, at least 0.57°
        XCTAssertLessThan(worstRate, 1 * deg * 0.02 + 1e-12)
        // Program start on the first step that sees a 137 m rise (a step
        // rises about 0.5 m then).
        let started = try XCTUnwrap(f.iu.programStarted)
        let rise = try XCTUnwrap(riseAtStart)
        XCTAssertLessThan(rise.before, 137)
        XCTAssertGreaterThanOrEqual(rise.at, 137)
        XCTAssertLessThan(rise.at - rise.before, 0.6)
        XCTAssertLessThan(started, AS506.programStartBackup)
        // Roll: the start's peaks, lag and rate late in the ramp, then
        // Position I on the flight azimuth.
        XCTAssertEqual(peakRollRate, 1.38, accuracy: 0.2)
        XCTAssertEqual(peakRollError, 0.92, accuracy: 0.2)
        XCTAssertFalse(rollLag.isEmpty)
        XCTAssertEqual(rollLag.reduce(0, +) / Double(rollLag.count), 0.15 / 0.245, accuracy: 0.03)
        for lag in rollLag { XCTAssertEqual(lag, 0.15 / 0.245, accuracy: 0.08) }
        for rate in rollRate { XCTAssertEqual(rate, 1, accuracy: 0.07) }
        // (The yaw holds 0.06° off: the FCC law, without an integral term,
        // holds the launch-day wind's moment with a steady error.)
        let angles = try XCTUnwrap(f.iu.eulerAngles(of: f.v.attitude))
        XCTAssertEqual(angles.x / deg, 0, accuracy: 0.05)
        XCTAssertEqual(f.iu.chi.x, 0, accuracy: 1e-12)
        XCTAssertEqual(angles.z / deg, 0, accuracy: 0.1)
    }

    // The S-IC ascent against Apollo 11's, flown through the launch day's air
    // and winds with the flight-evaluated aerodynamics (datasheet §11).
    // - At CECO (135.2 s) and OECO (161.63 s), FER Tables 4-1 and 4-2 with
    //   §5 C's tolerances: geodetic altitude (the FER's is over the Fischer
    //   ellipsoid, 30 m above WGS 84's surface at the Cape; datasheet §15),
    //   space-fixed velocity, flight-path angle and heading. None is
    //   fitted: the pitch program is AS-506's reconstructed command
    //   (datasheet §17); the headings check the space-fixed frame, flight
    //   azimuth and roll program in particular.
    // - Mach 1 at 66.3 s and max Q of 35.2 kPa at 83.0 s (FER Table 4-1; the
    //   model: 66.3 s, 35.3 kPa at 83.1 s), within 1 s and 2 %; the dynamic
    //   pressure every 10 s from 40 to 120 s within 5 % of FER Figure 4-4
    //   (digitised, M; the model is within 3 %).
    // - The climb above the pad and the Earth-fixed speed every 20 s against
    //   the postflight trajectory (PFT Table B-III, H; 59 m on the pad, the
    //   model's centre of mass 59 m): within 150 m and 0.5 % (the model is 2
    //   to 41 m high to 100 s and 125 m at 120 s, on AS-506's command without
    //   its late trim, and within 0.26 % in speed; datasheet §17).
    // - The aerodynamic axial force peaks at 1.36-1.38 MN near 72-75 s, as
    //   D5-15796-1's method gives along AS-506's trajectory (inferred, M).
    // - The thrust acceleration (ambient pressure included) against AS-506's
    //   total inertial acceleration (FER Figure 4-3, M) where drag is under
    //   0.3 % of thrust: 10.3, 147.4, 152.3 and 158.8 s, within 1 %.
    // The pitch program starts at T1 + 10.7 s rather than 12.6 s (datasheet
    // §8.5), so that time is not a target.
    func testSICAscentMatchesApollo11() throws {
        let f = try launch()
        let pad = f.v.altitude   // the centre of mass on the pad, geodetic
        var mach1: Double?, maxQ = (q: 0.0, t: 0.0), peakAxial = (f: 0.0, t: 0.0)
        var states: [(alt: Double, v: Double, gamma: Double, heading: Double)] = []
        var marks = [135.2, 161.63]
        var figure = [(10.3, 12.41), (147.4, 32.23), (152.3, 34.31), (158.8, 37.23)]
        var accelerations: [(model: Double, fer: Double)] = []
        // FER Fig 4-4 q (kPa) and PFT Table B-III climb (m above the pad) and
        // Earth-fixed speed (m/s).
        var qFigure = [(40.0, 8.71), (50, 14.90), (60, 22.9), (70, 30.0), (80, 34.3), (90, 32.4), (100, 23.6),
                       (110, 14.7), (120, 8.7)]
        var pft: [Double] = [20, 40, 60, 80, 100, 120]
        var qModel: [(Double, Double)] = [], pftModel: [(climb: Double, v: Double)] = []
        f.fly(to: 161.7) {
            if mach1 == nil && f.v.mach >= 1 { mach1 = f.range() }
            if f.v.dynamicPressure > maxQ.q { maxQ = (f.v.dynamicPressure, f.range()) }
            if let model = f.v.activeAerodynamics, let atm = f.sim.atmosphere(of: f.v.reference),
               f.v.altitude < 100_000 {
                let snap = f.sim.snapshot
                let air = f.sim.airVelocity(r: f.v.position, v: f.v.velocity, body: f.v.reference, atmosphere: atm,
                                            altitude: f.v.altitude, snapshot: snap)
                let l = model.loads(air: f.v.attitude.inverseRotate(air), atmosphere: f.v.atmosphere,
                                    altitude: f.v.altitude, powered: f.v.basePowered(model),
                                    centerOfPressureX: f.v.centerOfPressureX(model), planform: f.v.planform)
                if -l.force.x > peakAxial.f { peakAxial = (-l.force.x, f.range()) }
            }
            if let (t, q) = qFigure.first, f.range() >= t - 1e-9 {
                qFigure.removeFirst()
                qModel.append((f.v.dynamicPressure / 1000, q))
            }
            if let t = pft.first, f.range() >= t - 1e-9 {
                pft.removeFirst()
                pftModel.append((f.v.altitude - pad, f.v.surfaceVelocity(snapshot: f.sim.snapshot).length))
            }
            if let (t, a) = figure.first, f.range() >= t - 1e-9 {
                figure.removeFirst()
                accelerations.append((f.v.thrustAcceleration, a))
            }
            guard let m = marks.first, f.range() >= m - 1e-9 else { return }
            marks.removeFirst()
            let up = f.v.position.normalized, pole = f.sim.snapshot.orientation(f.sim.system.earth).pole
            let east = pole.cross(up).normalized, north = up.cross(east)
            states.append((f.v.altitude, f.v.velocity.length, asin(up.dot(f.v.velocity.normalized)) / deg,
                           atan2(f.v.velocity.dot(east), f.v.velocity.dot(north)) / deg))
        }
        XCTAssertEqual(try XCTUnwrap(mach1), 66.3, accuracy: 1)
        XCTAssertEqual(maxQ.q, 35_200, accuracy: 35_200 * 0.02)
        XCTAssertEqual(maxQ.t, 83.0, accuracy: 1)
        XCTAssertEqual(qModel.count, 9)
        for (model, fer) in qModel { XCTAssertEqual(model, fer, accuracy: fer * 0.05) }
        XCTAssertEqual(pftModel.count, 6)
        let pftRows: [(climb: Double, v: Double)] = [(537 - 59, 53.0), (2_364 - 59, 136.5), (6_153 - 59, 267.0),
                                                     (12_404 - 59, 466.0), (21_341 - 59, 768.0),
                                                     (33_115 - 59, 1_195.9)]
        for (model, ref) in zip(pftModel, pftRows) {
            XCTAssertEqual(model.climb, ref.climb, accuracy: 150)
            XCTAssertEqual(model.v, ref.v, accuracy: ref.v * 5e-3)
        }
        XCTAssertEqual(peakAxial.f, 1.37e6, accuracy: 0.08e6)
        XCTAssertEqual(peakAxial.t, 73.5, accuracy: 3)
        guard states.count == 2 else { return XCTFail("missing cutoff states") }
        let (ceco, oeco) = (states[0], states[1])
        XCTAssertEqual(ceco.alt, 44_000, accuracy: 2_500)
        XCTAssertEqual(ceco.v, 1_979.0, accuracy: 50)
        XCTAssertEqual(ceco.gamma, 22.957, accuracy: 1.5)
        XCTAssertEqual(ceco.heading, 76.315, accuracy: 0.5)
        XCTAssertEqual(oeco.alt, 66_100, accuracy: 2_500)
        XCTAssertEqual(oeco.v, 2_764.1, accuracy: 40)
        // AS-506's command leaves the S-IC 0.29° steep at OECO (19.407°): the
        // model's thrust flies 0.4-0.6° nose-up of AS-506's after 85 s, part
        // of it AS-506's late trim, which the model lacks (datasheet §14.1,
        // §17.3 item 1).
        XCTAssertEqual(oeco.gamma, 19.114, accuracy: 0.35)
        XCTAssertEqual(oeco.heading, 75.439, accuracy: 0.5)
        XCTAssertEqual(accelerations.count, 4)
        for (model, fer) in accelerations { XCTAssertEqual(model, fer, accuracy: fer * 0.01) }
    }

    // The outboard F-1 cant starts at T1 + 20.0 s (range 20.63 s; FER
    // sequence table, EL: M) and ramps (0.2°/s, a placeholder) to each thrust
    // line 2° radially inwards (EL, EH 8.13: M), with no net lateral thrust.
    func testOutboardCantSchedule() throws {
        let f = try launch()
        let outboard = f.v.parts[0].thrusters.filter { !$0.gimbal.isEmpty }
        var firstBias: Double?
        f.fly(to: 32) {
            if firstBias == nil && outboard[0].gimbal[0].bias != 0 { firstBias = f.range() }
        }
        XCTAssertEqual(try XCTUnwrap(firstBias), 20.63 + 0.02, accuracy: 0.021)
        for e in outboard {
            var d = e.direction
            for a in e.gimbal { d += a.tilt * tan(a.bias) }
            let inwards = -Vec3(0, e.position.y, e.position.z).normalized
            XCTAssertEqual(angleBetween(d, .unitX) / deg, 2, accuracy: 1e-9, e.name)
            XCTAssertGreaterThan(d.normalized.dot(inwards), 0, e.name)
        }
    }

    // The FCC law at liftoff mass in free space with the S-IC band-1 gains
    // (a0 0.9, a1 0.69 s; TN D-5869 Table 3): a 0.5° pitch command step is a
    // second-order response with wn = sqrt(a0 c) and zeta = a1 c / (2 wn),
    // c = 4 F L / Iyy from the model's own geometry, in vacuum (datasheet
    // §8.6: c 0.947 s^-2, wn 0.923 rad/s, zeta 0.354, a 30 % overshoot at
    // 3.6 s, with FER Table 20-10's pitch inertia and the S-IC's feed lines;
    // 0.955 s^-2 without the lines, 0.887 s^-2 before the table). Since §17
    // the F-1's thrust at first motion is FER Figure 5-3's at AS-506's
    // measured level, 0.77 % more: c 0.955 s^-2, wn 0.927 rad/s.
    // Mass properties frozen; self-consistency of law, gains and model.
    func testFlightControlStepResponse() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.saturnV()
        sim.add(v)
        sim.placeInFreeSpace(v)
        v.mainThrottle = 1
        v.autopilot = .attitudeHold
        v.fccGains = FCCGains(a0: 0.9, a1: 0.69)
        let q0 = v.attitude, step = 0.5 * deg
        v.attitudeCommand = AttitudeCommand(attitude: q0 * Quat(axis: .unitY, angle: step))
        let full = v.tanks.map(\.mass)
        v.applyThrottles()
        let e = v.parts[0].thrusters[0]
        let L = -(e.position.x + v.parts[0].offset.x)
        let c = 4 * e.maxThrustVacuum * L / v.inertia[1, 1]
        let wn = (0.9 * c).squareRoot(), zeta = 0.69 * c / (2 * wn), wd = wn * (1 - zeta * zeta).squareRoot()
        var t = 0.0, pitch: [(Double, Double)] = []
        sim.run(seconds: 12) {
            t += 0.02
            for (tank, m) in zip(v.tanks, full) { tank.mass = m }
            v.recenter()
            pitch.append((t, rotationVector(q0.conjugate * v.attitude).y))
        }
        let peak = pitch.max { $0.1 < $1.1 }!
        XCTAssertEqual(peak.0, Double.pi / wd, accuracy: 0.1 * Double.pi / wd)
        XCTAssertEqual(peak.1 / step - 1, exp(-zeta * Double.pi / (1 - zeta * zeta).squareRoot()), accuracy: 0.05)
        XCTAssertEqual(c, 0.955, accuracy: 0.005)
        XCTAssertEqual(wn, 0.927, accuracy: 0.005)
    }

    // The FCC's shaping filters (Boeing D5-15481-1 §3.5: the S-IC roll
    // attitude-gain filter 2.35/(s + 2.35), and the S-IC pitch and yaw lag
    // network 0.4(s + 0.095)/(s + 0.038), which the model does not fly) are
    // stepped exactly for an input linear between samples: a ramp through
    // the roll filter and a step through the lag network land on their
    // closed forms at any step, 1 s ones included. Static gain 1 in both.
    // Flown by the law, the roll filter gives the same 0.5° roll-step
    // response at 0.01, 0.02 and 1/60 s steps, and makes it overshoot (the
    // unfiltered roll loop at full S-IC thrust is near critically damped).
    func testFCCFiltersAreExactAtAnyStep() throws {
        let roll = AS506.sICRollAttitudeFilter, lag = FCCFilter(gain: 0.4, zero: 0.095, pole: 0.038)
        XCTAssertEqual(roll.staticGain, 1, accuracy: 1e-15)
        XCTAssertEqual(lag.staticGain, 1, accuracy: 1e-15)
        for h in [0.01, 0.02, 1.0 / 60, 0.5, 1] {
            var x = 0.0, t = 0.0
            while t < 3 - 1e-9 {
                x = roll.advance(x, from: t, to: t + h, dt: h)
                t += h
            }
            XCTAssertEqual(roll.output(t, state: x), t - (1 - exp(-2.35 * t)) / 2.35, accuracy: 1e-12, "ramp, h \(h)")
            var y = 0.0, s = 0.0
            XCTAssertEqual(lag.output(1, state: y), 0.4, accuracy: 1e-15)   // the step's first instant
            while s < 30 - 1e-9 {
                y = lag.advance(y, from: 1, to: 1, dt: h)
                s += h
            }
            XCTAssertEqual(lag.output(1, state: y), 1 - 0.6 * exp(-0.038 * s), accuracy: 1e-12, "step, h \(h)")
        }

        func rollStep(_ filter: FCCFilter?, dt: Double) throws -> (t: Double, overshoot: Double) {
            let sim = try Simulation.forTests(perturbations: false)
            let v = VesselLibrary.saturnV()
            sim.add(v)
            sim.placeInFreeSpace(v)
            v.mainThrottle = 1
            v.autopilot = .attitudeHold
            v.fccGains = FCCGains(a0: 0.9, a1: 0.69, rollA0: AS506.sICRollGains.a0, rollA1: AS506.sICRollGains.a1,
                                  rollAttitudeFilter: filter)
            let q0 = v.attitude, step = 0.5 * deg
            v.attitudeCommand = AttitudeCommand(attitude: q0 * Quat(axis: .unitX, angle: step))
            let full = v.tanks.map(\.mass)
            v.applyThrottles()
            var t = 0.0, peak = (t: 0.0, angle: 0.0)
            while t < 6 - 1e-9 {
                sim.tick(dt)
                t += dt
                for (tank, m) in zip(v.tanks, full) { tank.mass = m }
                v.recenter()
                let angle = rotationVector(q0.conjugate * v.attitude).x
                if angle > peak.angle { peak = (t, angle) }
            }
            return (peak.t, peak.angle / step - 1)
        }
        let unfiltered = try rollStep(nil, dt: 0.02)
        XCTAssertLessThan(unfiltered.overshoot, 0.02)
        let reference = try rollStep(roll, dt: 0.02)
        XCTAssertGreaterThan(reference.overshoot, 0.15)
        for dt in [0.01, 1.0 / 60] {
            let r = try rollStep(roll, dt: dt)
            XCTAssertEqual(r.overshoot, reference.overshoot, accuracy: 0.01, "dt \(dt)")
            XCTAssertEqual(r.t, reference.t, accuracy: 0.05, "dt \(dt)")
        }
    }

    // The FCC filters' state: a filter starts at rest when the law first
    // flies it (its output 0 for the 2.35/(s + 2.35) lag), carries on across
    // a gain switch that keeps it (the S-IC's at T1 + 105 and 130 s), and is
    // dropped when the gains have none (the S-II's) or the attitude reference
    // is reset (a hand-back, a mode change); it then starts at rest again.
    func testFCCFilterStateAcrossGainSwitches() {
        let v = VesselLibrary.saturnV()
        let roll = AS506.sICRollAttitudeFilter, e = Vec3(0.01, 0.002, -0.003)
        let band1 = FCCGains(a0: 0.9, a1: 0.69, rollA0: 0.245, rollA1: 0.15, rollAttitudeFilter: roll)
        let band2 = FCCGains(a0: 0.45, a1: 0.438, rollA0: 0.245, rollA1: 0.15, rollAttitudeFilter: roll)
        let sII = FCCGains(a0: 0.81, a1: 0.97, rollA0: 0.25, rollA1: 0.20)
        func shaped(_ g: FCCGains, after dt: Double) -> Vec3 {
            v.fccFilter?.elapsed = dt
            return v.shapedAttitudeError(e, g)
        }
        XCTAssertEqual(shaped(band1, after: 0).x, 0, "at rest")
        XCTAssertEqual(shaped(band1, after: 1).x, 0.01 * (1 - exp(-2.35)), accuracy: 1e-15)
        let y = shaped(band2, after: 1)
        XCTAssertEqual(y.x, 0.01 * (1 - exp(-4.7)), accuracy: 1e-15, "carried across the switch")
        XCTAssertEqual(y.y, e.y, "pitch unfiltered")
        XCTAssertEqual(y.z, e.z, "yaw unfiltered")
        XCTAssertEqual(shaped(sII, after: 1), e, "no filter in the S-II's gains")
        XCTAssertNil(v.fccFilter)
        XCTAssertEqual(shaped(band1, after: 1).x, 0, "at rest again")
        v.resetAttitudeReference()
        XCTAssertNil(v.fccFilter)
    }

    // One flight, first motion to T5 + 87 s, against AS-506's sequence of
    // events (FER Tables 2-1, 2-2 and 10-4). Timed events are logged at their
    // scheduled time and act within a step (0.02 s); T2-T5 start when the IU
    // sees the cutoff, one or two steps after it (the LVDC took 0.03-0.23 s);
    // the IGM's own events come on its 1.7 s cycles, so within a cycle. The
    // propellant model puts the S-IC burnout at 161.64 s and the S-II's within
    // the step before 548.24 s (the S-II's flow is fitted to AS-506's 548.22
    // s), so the S-IVB lights at about 552.24 s. The IGM commands the EMR
    // shift on its cycle that holds AS-506's 494.83 s (its preset is
    // AS-506's, from the PFT), the PU valve step following 2.8 s later, and
    // cuts the S-IVB off on velocity within 1 s of AS-506 (0.42 s earlier;
    // datasheet §17): the IGM's phase 3
    // is timed from the model's own T4, and its terminal events and those
    // after the cutoff from the model's own cutoff and T5, as the FER's are
    // from AS-506's. The
    // stack ends as S-IVB, IU, SLA, LM and CSM, with every spent part its
    // own vessel, the S-II on its low mixture ratio, and the APS ullage burn
    // over. The IU's HUD line says "IGM done" through the coast after the
    // IGM's cutoff.
    func testFlightSequenceFollowsTheApollo11Timeline() throws {
        let f = try launch()
        var ullage = 0.0, lastCommand: (q: Quat, at: Epoch)?, commandRate = Vec3.zero, pitchError: [Double] = []
        var slew: Double?, t5Lines: [String] = []
        f.fly(to: 795) {
            if f.v.thrusters.contains(where: { $0.name.hasSuffix("ullage") && $0.level > 0 }) { ullage += 0.02 }
            if f.iu.timeBases[.t5] != nil, let clock = f.iu.status.firstIndex(of: " ") {
                let line = String(f.iu.status[f.iu.status.index(after: clock)...])
                if t5Lines.last != line { t5Lines.append(line) }
            }
            guard f.iu.log.contains(where: { $0.event == "orbital guidance: local horizontal" }),
                  let q = f.v.attitudeCommand?.attitude, let t5 = f.iu.timeBases[.t5] else { return }
            if slew == nil {
                // From the attitude at the turn to the local horizontal's target.
                let up = f.v.position.normalized
                let x = (f.v.velocity - up * f.v.velocity.dot(up)).normalized
                let target = Quat(matrix: Mat3(columns: x, (-up).cross(x), -up))
                slew = rotationVector(f.v.attitude.conjugate * target).length
            }
            if let last = lastCommand {
                let d = rotationVector(last.q.conjugate * q) / (f.sim.time - last.at)
                commandRate = Vec3(max(commandRate.x, abs(d.x)), max(commandRate.y, abs(d.y)),
                                   max(commandRate.z, abs(d.z)))
            }
            lastCommand = (q, f.sim.time)
            for m in [21.4, 27.4] where abs(f.sim.time - t5 - m) < 0.01 {
                pitchError.append(rotationVector(f.v.attitude.conjugate * q).y)
            }
        }
        // Range times from FER Table 2-2 (actual), or the time base plus the
        // FER's offset where the model's time base differs by a step.
        let t3 = 161.63, t4 = 548.22, cycle = AS506.igmCycle
        let cutoff = f.range(try XCTUnwrap(f.iu.log.first { $0.event == "S-IVB velocity cutoff (IGM)" }).time)
        let t4Sensed = f.range(try XCTUnwrap(f.iu.timeBases[.t4]))
        let t5 = f.range(try XCTUnwrap(f.iu.timeBases[.t5]))
        let expected: [(String, Double, Double)] = [
            ("T1: liftoff", 0.63, 1e-6),
            ("S-IC flight control gains", 0.63, 1e-6),
            ("S-IC outboard engine cant", 20.63, 1e-6),            // FER 20.6, T1 + 20.0
            ("S-IC flight control gains", 105.63, 1e-6),
            ("S-IC flight control gains", 130.63, 1e-6),
            ("S-IC centre engine cutoff", 135.20, 0.02),           // FER 135.20
            ("T2: centre engine cutoff sensed", 135.27, 0.06),     // FER Table 2-1, sensed 0.07 s later
            ("tilt arrest", 160.0, 1e-6),                          // FER 160.0
            ("T3: S-IC outboard engine cutoff sensed", 161.66, 0.05),  // FER Table 2-1
            ("S-IC outboard engine cutoff", t3, 0.05),
            ("S-II ullage motor ignition", 162.1, 0.1),            // FER 162.1
            ("S-IC/S-II separation", t3 + 0.7, 0.1),               // FER 162.3
            ("S-II flight control gains", t3 + 2.4, 0.1),
            ("S-II ignition", 164.0, 0.1),                         // FER 164.0, T3 + 2.4
            ("S-II ullage motor burn end", 166.1, 0.1),            // FER 166.1 (thrust decay)
            ("S-II high EMR select", 168.5, 0.1),                  // FER 168.5, T3 + 6.9
            ("S-II aft interstage jettison", 192.3, 0.1),          // FER 192.3
            ("launch escape tower jettison", 197.9, 0.1),          // FER 197.9
            ("IGM phase 1", 204.07, 0.1),                          // FER Table 10-4, T3 + 42.4
            ("S-II flight control gains", t3 + 61.4, 0.1),         // SA-507 ICD switch point 3
            ("S-II flight control gains", t3 + 191.4, 0.1),        // switch point 4
            ("S-II centre engine cutoff", 460.6, 0.1),             // FER 460.6
            ("EMR shift command (IGM phase 2)", 494.83, cycle),    // FER Table 10-4: on the cycle (the PFT's preset)
            ("S-II low EMR (PU valve step)", 497.6, cycle),        // FER Table 6-2, 497.60: 2.8 s later
            ("T4: S-II outboard engine cutoff sensed", 548.24, 0.1),  // FER Table 2-1
            ("S-II outboard engine cutoff", t4, 0.1),
            ("S-IVB ullage motor ignition", t4 + 0.7, 0.1),        // FER 548.9
            ("S-II/S-IVB separation", t4 + 0.8, 0.1),
            ("IGM phase 3: steering frozen", t4Sensed + cycle / 2, cycle / 2 + 0.03),  // FER Table 10-4: T4's cycle
            ("S-IVB flight control law", 552.2, 0.1),
            ("S-IVB ignition", 552.2, 0.1),                        // FER 552.2
            ("IGM steering on the S-IVB", 555.57, cycle),          // FER Table 10-4, artificial tau start
            ("S-IVB ullage case jettison", t4 + 12.8, 0.1),        // FER 561.0
            ("terminal guidance", cutoff - 34.19, cycle),          // FER 665.15, 34.19 s before the cutoff
            ("chi freeze: high-speed cutoff loop", cutoff - 7.70, cycle),  // FER 691.64, 7.70 s before
            ("S-IVB velocity cutoff (IGM)", 699.34, 1),            // FER 699.34
            ("T5: S-IVB cutoff sensed", cutoff, 0.03),             // the next step (FER: 0.23 s)
            ("APS ullage on", t5 + 0.3, 0.1),                      // FER T5 + 0.3
            ("orbital guidance: local horizontal", t5 + 19.8, 0.1),  // FER T5 + 19.8
            ("APS ullage off", t5 + 87.0, 0.1),                    // FER T5 + 87.0
        ]
        let log = f.iu.log.filter { $0.event != "roll and pitch program" }
        XCTAssertEqual(log.map(\.event), expected.map(\.0))
        for (entry, (name, time, tolerance)) in zip(log, expected) {
            XCTAssertEqual(f.range(entry.time), time, accuracy: tolerance, name)
        }
        func logged(_ event: String) throws -> Epoch { try XCTUnwrap(f.iu.log.first { $0.event == event }).time }
        XCTAssertEqual(try logged("S-II low EMR (PU valve step)") - logged("EMR shift command (IGM phase 2)"),
                       AS506.sIIMixtureRatioShiftDelay, accuracy: 1e-6)
        // The IGM cycles every 1.7 s (GE504 Δt): phase 3 falls a whole number
        // of cycles after the shift command.
        let cycles = try (logged("IGM phase 3: steering frozen") - logged("EMR shift command (IGM phase 2)")) / cycle
        XCTAssertEqual(cycles, cycles.rounded(), accuracy: 0.01)
        XCTAssertEqual(f.v.parts.map(\.name), ["S-IVB", "IU", "SLA", "LM", "CSM"])
        XCTAssertEqual(f.sim.vessels.map(\.name), ["Apollo 11", "Apollo 11 – S-IC", "Apollo 11 – S-IC/S-II interstage",
                                                  "Apollo 11 – LES", "Apollo 11 – S-II",
                                                  "Apollo 11 – S-IVB ullage rockets"])
        let sII = f.sim.vessels[4].parts[0]
        XCTAssertEqual(sII.thrusters.filter { $0.groups.contains(.main) }.map(\.rating.name),
                       Array(repeating: "J-2 S-II low EMR", count: 5))
        XCTAssertFalse(f.sim.vessels[1].thrusters.first { $0.name == "S-IC engine 5" }!.isEnabled)
        XCTAssertFalse(sII.thrusters.first { $0.name == "S-II engine 5" }!.isEnabled)
        XCTAssertNil(f.v.fccGains)
        XCTAssertEqual(f.v.mainThrottle, 0)
        XCTAssertEqual(ullage, 87.0 - 0.3, accuracy: 0.03)
        XCTAssertEqual(f.v.translationInput, .zero)
        XCTAssertEqual(f.v.autopilot, .attitudeHold)
        XCTAssertTrue(f.iu.status.hasPrefix("T5+"), f.iu.status)
        XCTAssertEqual(t5Lines, ["S-IVB cutoff, IGM done", "APS ullage, IGM done",
                                 "local horizontal, parking orbit, IGM done"])

        // Orbital guidance (GE504 §4.1.11): +x along the local horizontal in
        // the direction of motion, +z towards the Earth. The IU's command
        // slews there from the IGM's cutoff attitude within the orbital rate
        // limits, 0.4°/s in pitch and yaw and 0.6°/s in roll (Astrionics
        // System Handbook Table 3.1-3), reaching them; the pitch error grows
        // at about 0.35°/s from T5 + 21.4 to T5 + 27.4 s, as AS-506's did from
        // 721 to 727 s (0.33-0.37°/s, FER Figure 11-12 digitised: L-M). The
        // slew is a few degrees, as AS-506's (about 6° in all). The APS then
        // holds the local horizontal within the dead band, offset by the
        // switching line's 5 s times the orbital rate (0.07°/s: 0.33°), so
        // within (1 + 0.33)° on each of two axes.
        XCTAssertGreaterThan(try XCTUnwrap(slew), 3 * deg)
        XCTAssertLessThan(try XCTUnwrap(slew), 10 * deg)
        XCTAssertLessThan(commandRate.x, 0.6 * deg + 1e-9)
        XCTAssertLessThan(commandRate.y, 0.4 * deg + 1e-9)
        XCTAssertLessThan(commandRate.z, 0.4 * deg + 1e-9)
        XCTAssertGreaterThan(commandRate.y, 0.399 * deg)
        guard pitchError.count == 2 else { return XCTFail("missing local-horizontal errors") }
        XCTAssertEqual(abs(pitchError[1] - pitchError[0]) / 6 / deg, 0.35, accuracy: 0.05)
        let aps = f.v.tanks.dropFirst(2), before = aps.reduce(0) { $0 + $1.mass }
        for _ in 0..<400 { f.sim.advance(by: 1) }
        let up = f.v.position.normalized
        let horizontal = (f.v.velocity - up * f.v.velocity.dot(up)).normalized
        XCTAssertLessThan(angleBetween(f.v.attitude.rotate(.unitX), horizontal), 1.9 * deg)
        XCTAssertLessThan(angleBetween(f.v.attitude.rotate(.unitZ), -up), 1.9 * deg)
        XCTAssertLessThan(before - aps.reduce(0) { $0 + $1.mass }, 5)

        // A hand-back in orbit: the pilot rolls the stack by hand for 5 s
        // (the hold stays selected). On release the command restarts from
        // the attitude and returns to the local horizontal within the
        // orbital rate limits. The two roll engines (4,577 N m) turn the
        // stack's FER roll inertia (2.01e5 kg m²) at 1.31°/s², so 5 s leave
        // 6.5°/s, and the APS stops the roll about 33° off (α t²); it then
        // rolls back at its 0.5°/s clip-limited rate, inside the 100 s below.
        f.v.rotationInput = RotationCommand(roll: 1, pitch: 0, yaw: 0)
        for _ in 0..<250 { f.sim.tick() }
        let off = rotationVector(f.v.attitude.conjugate * f.v.attitudeCommand!.attitude).length
        f.v.rotationInput = RotationCommand()
        f.sim.tick()
        XCTAssertTrue(f.iu.log.last?.event == "attitude back to the IU")
        var last = try XCTUnwrap(f.v.attitudeCommand?.attitude), worst = Vec3.zero, lastTime = f.sim.time
        XCTAssertLessThan(rotationVector(f.v.attitude.conjugate * last).length, 0.7 * deg)
        for _ in 0..<5_000 {
            f.sim.tick()
            let q = f.v.attitudeCommand!.attitude, d = rotationVector(last.conjugate * q) / (f.sim.time - lastTime)
            worst = Vec3(max(worst.x, abs(d.x)), max(worst.y, abs(d.y)), max(worst.z, abs(d.z)))
            last = q
            lastTime = f.sim.time
        }
        XCTAssertGreaterThan(off, 5 * deg)
        XCTAssertLessThan(worst.x, 0.6 * deg + 1e-9)
        XCTAssertLessThan(max(worst.y, worst.z), 0.4 * deg + 1e-9)
        let upNow = f.v.position.normalized
        XCTAssertLessThan(angleBetween(f.v.attitude.rotate(.unitZ), -upNow), 1.9 * deg)
    }

    // In the app, `Simulation.advance` cuts each frame into steps; at 10x
    // warp a 1/60 s frame is eight 0.02 s steps and a remainder. The IU ends
    // a step on the IGM's next cycle, so the cycles stay 1.7 s apart (GE504
    // Δt) at any warp, as in fixed steps.
    func testIGMCyclesStay1Point7SecondsApartAtTimeWarp() throws {
        let f = try launch()
        f.fly(to: 230)
        var cycles: [Epoch] = [], last = f.iu.guidance?.totalTime
        while f.range() < 250 {
            // One frame, stepped as `advance` steps it.
            var remaining = 10.0 / 60
            while remaining > 1e-9 {
                for w in f.sim.vessels { f.sim.prepareControls(w) }
                if let t = f.iu.guidance?.totalTime, t != last {
                    cycles.append(f.sim.time)
                    last = t
                }
                let h = min(remaining, f.sim.maxStep())
                f.sim.step(h)
                remaining -= h
            }
        }
        XCTAssertGreaterThanOrEqual(cycles.count, 11)
        for (a, b) in zip(cycles, cycles.dropFirst()) { XCTAssertEqual(b - a, AS506.igmCycle, accuracy: 1e-4) }
    }

    // Iterative guidance on the model's Apollo 11 (datasheet §10), against
    // AS-506's own (FER §10). Its commanded pitch follows AS-506's
    // operational trajectory (FER Figure 10-4, OT, digitised: M) within 2°
    // from IGM start to cutoff, and its yaw within 0.8° (the LVDC's own ran
    // up to 0.5° off the OT; the model's runs 0.2-0.6° below it, datasheet
    // §10.4). Its space-fixed X_S is the plumb line at the pad, as AS-506's
    // (PACSS 13) was the geodetic vertical at 28.6084° (FER; GE504's sin φ_L
    // 0.478814 gives 28.608°). At S-II OECO its state is AS-506's (FER Table
    // 10-2, guidance) within the model's speed deficit; at the velocity cutoff it
    // is the LVDC's (Table 10-2, first S-IVB ECO: 6,563,335 m, 7,791.43 m/s,
    // γ -0.0015°); and 10 s later, at insertion, its orbit is the LVDC's
    // (Table 10-5 and the Table 10-2 state: i 32.532°, descending node
    // 123.102° from the launch meridian at guidance reference release,
    // 186.0 x 185.2 km above the 6,378,165 m sphere, e 0.00006, 88.20 min).
    func testIGMFliesApollo11ToItsParkingOrbit() throws {
        let f = try launch()
        let ot: [(t: Double, pitch: Double, yaw: Double)] = [
            (212, -62.5, -0.08), (240, -65.1, 0.18), (300, -70.8, 0.36), (400, -81.6, 0.551), (450, -87.5, 0.590),
            (500, -91.0, 0.44), (548, -96.5, 0.507), (580, -100.7, 0.60), (600, -103.4, 0.79), (650, -108.7, 0.767),
            (680, -112.6, 0.806)]
        var marks = ot, commands: [(pitch: Double, yaw: Double)] = []
        var sIIOut: (r: Vec3, v: Vec3)?, cutoff: (t: Double, r: Vec3, v: Vec3, pitch: Double)?
        var cutoffSpeed: Double?, coast: [(pitch: Double, yaw: Double)] = []
        while cutoff.map({ f.range() < $0.t + 10 - 1e-9 }) ?? (f.range() < 760) {
            // The IU acts at the start of a step: the cutoff state is the one before it.
            let before = (t: f.range(), r: f.v.position, v: f.v.velocity)
            if let g = f.iu.guidance, g.highSpeedLoop {
                // In the high-speed loop, step as the app does: the step ends
                // on the IU's predicted cutoff.
                cutoffSpeed = g.terminalVelocity - g.presettings.cutoffVelocityBias
                for w in f.sim.vessels { f.sim.prepareControls(w) }
                f.sim.step(min(0.02, f.sim.maxStep()))
            } else {
                f.sim.tick()
            }
            if let m = marks.first, f.range() >= m.t - 1e-9, let c = f.iu.guidanceCommand {
                marks.removeFirst()
                commands.append(c)
            }
            if sIIOut == nil && f.iu.timeBases[.t4] != nil { sIIOut = (f.v.position, f.v.velocity) }
            if f.iu.guidance?.stage == .coast, let c = f.iu.guidanceCommand { coast.append(c) }
            if cutoff == nil && f.iu.log.last?.event == "S-IVB velocity cutoff (IGM)" {
                cutoff = (before.t, before.r, before.v, f.iu.guidanceCommand?.pitch ?? .nan)
            }
        }
        let c = try XCTUnwrap(cutoff), s2 = try XCTUnwrap(sIIOut)
        // The steering is frozen through the S-II/S-IVB coast (GE504's GATE).
        XCTAssertGreaterThan(coast.count, 100)
        XCTAssertTrue(coast.allSatisfy { $0.pitch == coast[0].pitch && $0.yaw == coast[0].yaw })
        XCTAssertEqual(commands.count, ot.count)
        for (cmd, ref) in zip(commands, ot) {
            XCTAssertEqual(cmd.pitch / deg, ref.pitch, accuracy: 2, "\(ref.t) s")
            XCTAssertEqual(cmd.yaw / deg, ref.yaw, accuracy: 0.8, "\(ref.t) s")
        }
        XCTAssertEqual(c.pitch / deg, -112.4, accuracy: 2)   // OT at cutoff (LVDC -113.6)
        func gamma(_ r: Vec3, _ v: Vec3) -> Double { asin(r.normalized.dot(v.normalized)) / deg }
        // S-II OECO: AS-506's 6,559,961 m, 6,915.96 m/s, 0.614°. With the
        // residuals closed (datasheet §17) the model is 395 m higher, 0.26
        // m/s faster and 0.07° steeper: the S-IC's 0.29° at OECO, which the
        // IGM takes out over the S-II.
        XCTAssertEqual(s2.r.length, 6_559_961, accuracy: 1_000)
        XCTAssertEqual(s2.v.length, 6_915.96, accuracy: 5)
        XCTAssertEqual(gamma(s2.r, s2.v), 0.614, accuracy: 0.15)
        // Cutoff: on V_T - ΔV_B; the LVDC's radius and flight-path angle, and
        // its speed to the two cutoff biases' difference (1.46 m/s here, 1.6
        // on AS-506).
        XCTAssertEqual(c.v.length, try XCTUnwrap(cutoffSpeed), accuracy: 0.01)
        XCTAssertEqual(c.r.length, 6_563_335, accuracy: 50)
        XCTAssertEqual(c.v.length, 7_791.43, accuracy: 0.25)
        XCTAssertEqual(gamma(c.r, c.v), -0.0015, accuracy: 0.005)
        // The orbit 10 s after the cutoff, in the IU's space-fixed frame.
        let frame = try XCTUnwrap(f.iu.spaceFixed)
        let pole = frame.conjugate.rotate(f.sim.snapshot.orientation(f.sim.system.earth).pole)
        XCTAssertEqual(asin(pole.x) / deg, 28.6084, accuracy: 0.001)   // X_S: the plumb line
        let r = frame.conjugate.rotate(f.v.position), v = frame.conjugate.rotate(f.v.velocity)
        let h = r.cross(v).normalized, meridian = (Vec3.unitX - pole * pole.x).normalized
        let node = -pole.cross(h).normalized
        var nodeAngle = atan2(node.dot(pole.cross(meridian)), node.dot(meridian)) / deg
        if nodeAngle < 0 { nodeAngle += 360 }
        let el = f.v.elements(snapshot: f.sim.snapshot), sphere = 6_378_165.0
        XCTAssertEqual(acos(h.dot(pole)) / deg, 32.532, accuracy: 0.003)
        XCTAssertEqual(nodeAngle, 123.102, accuracy: 0.006)
        // Insertion: AS-506's vents left the LVDC 0.22 m/s over circular
        // speed (186.0 x 185.2 km); the model inserts at circular speed.
        XCTAssertEqual((el.apoapsisRadius - sphere) / 1000, 186.0, accuracy: 1)
        XCTAssertEqual((el.periapsisRadius - sphere) / 1000, 185.2, accuracy: 0.5)
        XCTAssertLessThan(el.eccentricity, 2e-4)
        XCTAssertEqual(el.period / 60, 88.20, accuracy: 0.02)
    }

    // Before T3 the IU refuses Space: it would drop the S-IC full and
    // burning. From T3 a pilot's Space press does not upset the IU, which
    // stages by part: the aft interstage jettisoned by hand at 170 s, the
    // IU's own jettison at 192.3 s finds nothing to separate and says so, and
    // the LET still goes at 197.9 s. A pilot who takes the attitude (kill
    // rotation) leaves the sequence running.
    func testIUStagesByPartAfterAManualSpacePress() throws {
        let f = try launch()
        f.fly(to: 100)
        XCTAssertNil(f.sim.stage(f.v))
        XCTAssertEqual(f.v.parts.first?.name, "S-IC")
        f.fly(to: 170)
        XCTAssertEqual(f.sim.stage(f.v)?.parts.map(\.name), ["S-IC/S-II interstage"])
        f.v.autopilot = .killRotation
        f.fly(to: 199)
        XCTAssertEqual(f.sim.vessels.map(\.name), ["Apollo 11", "Apollo 11 – S-IC", "Apollo 11 – S-IC/S-II interstage",
                                                  "Apollo 11 – LES"])
        XCTAssertTrue(f.v.parts.contains { $0.name == "S-II" })
        XCTAssertTrue(f.iu.log.contains { $0.event == "S-II aft interstage jettison (nothing to do: gone)" })
        XCTAssertTrue(f.iu.log.contains { $0.event == "launch escape tower jettison" })
        XCTAssertTrue(f.iu.status.hasSuffix("(attitude: pilot)"), f.iu.status)
    }

    // The LVDC leaves a time base's table when the next one starts: the S-II
    // dropped by hand at 200 s (T3 + 38 s) starts T4 at once, and the S-II's
    // pending events (gain switches, centre engine cutoff) never fire into
    // the S-IVB, which keeps its own law. The IGM still starts on its own
    // timer (T3 + 42.4 s, GE504 Fig 4-1) and steers the S-IVB. (An S-IVB
    // lit at 204 s cannot reach orbit, and the IGM's T3 iteration does not
    // converge: whether it logs terminal guidance then depends on the
    // S-IVB's exhaust velocity, so that entry is left out.)
    func testEarlierTimeBaseEventsDropWhenTheNextStarts() throws {
        let f = try launch()
        f.fly(to: 200)
        for _ in 0..<3 where f.v.parts.contains(where: { $0.name == "S-II" }) { f.sim.stage(f.v) }
        XCTAssertFalse(f.v.parts.contains { $0.name == "S-II" })
        f.fly(to: 260)
        let t4 = try XCTUnwrap(f.iu.timeBases[.t4])
        XCTAssertEqual(f.range(t4), 200, accuracy: 0.03)
        XCTAssertEqual(f.iu.log.filter { $0.time >= t4 && $0.event != "terminal guidance" }.map(\.event),
                       ["T4: S-II outboard engine cutoff sensed", "S-II outboard engine cutoff",
                        "S-IVB ullage motor ignition", "S-II/S-IVB separation (nothing to do: gone)",
                        "S-IVB flight control law", "S-IVB ignition", "IGM phase 1", "IGM phase 3: steering frozen",
                        "IGM steering on the S-IVB", "S-IVB ullage case jettison"])
        XCTAssertNil(f.v.fccGains)
        XCTAssertEqual(f.v.mainThrottle, 1)
    }

    // The S-IVB cut before the IGM's start (the S-II dropped by hand at
    // 163 s, which starts T4, and the S-IVB cut at 180 s): T5 drops the
    // IGM's start with the earlier tables, so no IGM runs after the cutoff,
    // and the IU's line does not say "IGM done".
    func testSIVBCutoffBeforeTheIGMStartLeavesNoIGM() throws {
        let f = try launch()
        f.fly(to: 163)
        for _ in 0..<3 where f.v.parts.contains(where: { $0.name == "S-II" }) { f.sim.stage(f.v) }
        f.fly(to: 180)
        XCTAssertTrue(f.v.thrusters.contains { $0.name == "S-IVB engine" && $0.isDelivering })
        f.v.mainThrottle = 0
        f.fly(to: 230)
        XCTAssertEqual(f.range(try XCTUnwrap(f.iu.timeBases[.t5])), 180, accuracy: 0.05)
        XCTAssertFalse(f.iu.log.contains { $0.event.contains("IGM") }, "\(f.iu.log.map(\.event))")
        XCTAssertNil(f.iu.guidance)
        XCTAssertNil(f.iu.guidanceCommand)
        XCTAssertFalse(f.iu.status.contains("IGM"), f.iu.status)
    }

    // From the S-IVB cutoff (T5) the LVDC limits its commanded angles to its
    // coast rates (Astrionics System Handbook Table 3.1-3, "Coast": 0.4°/s
    // in pitch and yaw, 0.6°/s in roll), against 1°/s in powered flight. The
    // pilot rolls the stack by hand for 3 s in the coast before the turn to
    // the local horizontal (T5 + 19.8 s); released, the command returns at
    // 0.6°/s. The two roll engines turn the stack's FER roll inertia
    // (2.01e5 kg m²) at 1.30°/s², so 3 s roll it 5.9° (6.8° off the command
    // with the error it had), which the command undoes in 11 s, before the
    // turn. (The S-II
    // dropped at 200 s and the S-IVB cut by hand at 240 s bring T5 forward,
    // to save flying time. The IGM steered the S-IVB but did not cut it off,
    // so the IU's line does not say "IGM done".)
    func testCoastCommandRateFromTheSIVBCutoff() throws {
        let f = try launch()
        f.fly(to: 200)
        for _ in 0..<3 where f.v.parts.contains(where: { $0.name == "S-II" }) { f.sim.stage(f.v) }
        f.fly(to: 240)
        f.v.mainThrottle = 0
        while f.iu.timeBases[.t5] == nil && f.range() < 400 { f.sim.tick() }
        let t5 = f.range(try XCTUnwrap(f.iu.timeBases[.t5]))
        f.fly(to: t5 + 1)
        f.v.rotationInput = RotationCommand(roll: 1, pitch: 0, yaw: 0)
        f.fly(to: t5 + 4)
        f.v.rotationInput = RotationCommand()
        let off = abs(try XCTUnwrap(f.iu.eulerAngles(of: f.v.attitude)).x - f.iu.chi.x)
        f.sim.tick()   // the hand-back: the command restarts from the attitude
        var last = f.iu.chi, lastTime = f.sim.time, worst = 0.0
        f.fly(to: t5 + 19) {
            worst = max(worst, abs(f.iu.chi.x - last.x) / (f.sim.time - lastTime))
            last = f.iu.chi
            lastTime = f.sim.time
        }
        XCTAssertGreaterThan(off, 2 * deg)
        XCTAssertTrue(f.iu.log.contains { $0.event == "attitude back to the IU" })
        XCTAssertEqual(worst, 0.6 * deg, accuracy: 1e-6 * deg)
        XCTAssertEqual(f.iu.chi.x, 0, accuracy: 1e-12)
        XCTAssertTrue(f.iu.log.contains { $0.event == "IGM steering on the S-IVB" })
        XCTAssertFalse(f.iu.status.contains("IGM"), f.iu.status)
    }

    // The pilot takes the attitude (kill rotation) at 40 s and hands it back
    // (8) at 60 s, 13° off the program. The IU restarts its command from the
    // attitude then and returns to the program at the 1°/s command limit, so
    // the stack turns back at about that rate (1.3°/s at most) rather than
    // swinging back on the whole error at once (7.7°/s near max Q without it).
    func testAttitudeHandBackReturnsAtTheCommandRate() throws {
        let f = try launch()
        f.fly(to: 40)
        f.v.autopilot = .killRotation
        f.fly(to: 60)
        let command = try XCTUnwrap(f.v.attitudeCommand?.attitude)
        let offProgram = rotationVector(f.v.attitude.conjugate * command).length
        f.v.autopilot = .attitudeHold
        var worstRate = 0.0
        f.fly(to: 120) { worstRate = max(worstRate, f.v.angularVelocity.length) }
        XCTAssertGreaterThan(offProgram, 3 * deg)
        XCTAssertTrue(f.iu.log.contains { $0.event == "attitude back to the IU" })
        XCTAssertLessThan(worstRate, 1.5 * deg)
        // Back on the program (the IU's last update was a step ago).
        let angles = try XCTUnwrap(f.iu.eulerAngles(of: f.v.attitude))
        XCTAssertEqual(f.iu.chi.y, AS506.tiltProgram.pitch(at: f.range() - 0.02 - AS506.liftoff), accuracy: 1e-6)
        XCTAssertEqual(f.iu.chi.x, 0, accuracy: 1e-12)
        XCTAssertEqual(f.iu.chi.z, 0, accuracy: 1e-12)
        XCTAssertEqual(angles.y, f.iu.chi.y, accuracy: 1 * deg)
    }

    // A full roll input for 0.6 or 1 s at 40 or 60 s, then the hand-back. On
    // FER Table 20-10's roll inertia the tap leaves the stack spinning at
    // 45-120°/s. Restarting the command from the attitude while it still
    // spins would let the FCC law swing it back past 180°, where the attitude
    // error wraps into pitch and yaw, the gimbals saturate there and the
    // allocation leaves no roll torque: without what follows, the 0.6 s taps
    // end 27-34° off their command, and other taps tumbled the stack near
    // max Q. The IU instead keeps restarting its command from the attitude
    // until the body rate is under twice the command limit, so only the rate
    // term flies: the spin stops within a few seconds, the nose stays within
    // 2° of an untouched flight's, and the vehicle then tracks its command.
    func testRollTapHandBackInTheSICBurn() throws {
        let reference = try launch()
        var nose: [Int: Vec3] = [:]
        reference.fly(to: 85) { nose[Int((reference.range() * 50).rounded())] = reference.v.attitude.rotate(.unitX) }
        for (start, tap) in [(40.0, 0.6), (40, 1.0), (60, 0.6), (60, 1.0)] {
            let f = try launch()
            f.fly(to: start)
            f.v.rotationInput = RotationCommand(roll: 1, pitch: 0, yaw: 0)
            f.fly(to: start + tap)
            f.v.rotationInput = RotationCommand()
            var worstNose = 0.0, damped: Double?
            f.fly(to: start + 25) {
                if let n = nose[Int((f.range() * 50).rounded())] {
                    worstNose = max(worstNose, angleBetween(f.v.attitude.rotate(.unitX), n))
                }
                if damped == nil && f.v.angularVelocity.length < 1 * deg { damped = f.range() - start - tap }
            }
            let run = "tap of \(tap) s at \(start) s"
            XCTAssertTrue(f.iu.log.contains { $0.event == "attitude back to the IU" }, run)
            XCTAssertLessThan(try XCTUnwrap(damped), 6, run)
            XCTAssertLessThan(worstNose, 2 * deg, run)
            let error = rotationVector(f.v.attitude.conjugate * f.v.attitudeCommand!.attitude).length
            XCTAssertLessThan(error, 1.5 * deg, run)
        }
    }

    // An IU attached to a stack already flying (here coasting in orbit) takes
    // its first update as first motion and its rise from there: the roll and
    // pitch programs wait for the 137 m rise or the 13 s backup rather than
    // start with T1.
    func testIUStartedInFlightWaitsForTheProgramStart() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.saturnV()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: sim.system.earth, altitude: 185_000, inclination: 32.5)
        let iu = SaturnIU.as506()
        v.flightProgram = iu
        let start = sim.time
        sim.run(seconds: 20)
        let t1 = try XCTUnwrap(iu.timeBases[.t1])
        XCTAssertEqual(t1 - start, AS506.liftoff - AS506.firstMotion, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(iu.programStarted), AS506.programStartBackup, accuracy: 0.021)
    }

    /// The S-IVB stack just after the first burn (147.13 s; SP-4029), in
    /// orbit; `light` leaves the S-IVB and IU alone with residual propellant,
    /// as after TLI and spacecraft separation.
    func sIVBInOrbit(_ sim: Simulation, light: Bool = false) -> Vessel {
        let v = VesselLibrary.saturnV()
        for _ in 0..<4 { v.jettisonNextStage() }
        let j2 = v.thrusters.first { $0.name == "S-IVB engine" }!
        j2.level = 1
        for _ in 0..<Int((147.13 / 0.02).rounded()) { v.consumePropellant(dt: 0.02) }
        j2.level = 0
        for _ in 0..<25 { v.consumePropellant(dt: 0.02) }   // the tail-off
        if light {
            for t in v.tanks.prefix(2) { t.mass = t.unusableMass }
            v.recenter()
            v.separate(parts: v.parts.filter { ["SLA", "LM", "CSM"].contains($0.name) }, name: "CSM/LM")
        }
        v.recenter()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: sim.system.earth, altitude: 185_000, inclination: 32.5)
        return v
    }

    // The APS phase-plane logic (TVC datasheet §7.2: dead band ±1°, error
    // limits 2.5° pitch/yaw and 3.5° roll, EH 8.30: M; switching line slope
    // 5 s, Astrionics System Handbook Figures 3.4-5 and 3.4-6: M, "typical";
    // 0.06 s minimum on-time, derived): a hold command 20° away
    // in pitch and 30° in roll slews at (limit - dead band) / 5 s, 0.30°/s in
    // pitch and 0.50°/s in roll (plus at most one pulse's increment), every
    // pulse lasts at least the minimum on-time, and each axis settles inside
    // the dead band plus one pulse.
    func testAPSPhasePlaneSlewsAndHolds() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = sIVBInOrbit(sim)
        sim.placeInFreeSpace(v)
        v.autopilot = .attitudeHold
        sim.tick()
        v.attitudeCommand = AttitudeCommand(attitude: v.attitude * Quat(axis: .unitY, angle: 20 * deg)
                                            * Quat(axis: .unitX, angle: 30 * deg))
        var t = 0.0, pitchRates: [Double] = [], rollRates: [Double] = [], pulses: [Double] = [], on = 0.0
        sim.run(seconds: 200) {
            t += 0.02
            if t > 25 && t < 45 { pitchRates.append(v.angularVelocity.y / deg) }
            if t > 15 && t < 35 { rollRates.append(v.angularVelocity.x / deg) }
            if v.thrusters.contains(where: { $0.name.hasSuffix("pitch") && $0.level > 0 }) {
                on += 0.02
            } else if on > 0 {
                pulses.append(on)
                on = 0
            }
        }
        for w in pitchRates { XCTAssertEqual(w, 0.30, accuracy: 0.005) }
        for w in rollRates { XCTAssertEqual(w, 0.51, accuracy: 0.015) }
        XCTAssertGreaterThan(pulses.count, 3)
        XCTAssertGreaterThanOrEqual(pulses.min()!, 0.06 - 1e-9)
        let e = rotationVector(v.attitude.conjugate * v.attitudeCommand!.attitude)
        XCTAssertLessThan(max(abs(e.x), abs(e.y), abs(e.z)), 1.1 * deg)
    }

    // The fix for the APS drain in the pointing modes: on the light S-IVB
    // after TLI, Prograde under M0's law (no dead band, fractional levels)
    // would empty both modules (298.5 kg, AS-506's load: FER Table 7-5) within the hour,
    // while the phase-plane logic uses under 1 kg an hour and keeps the nose
    // within the dead band of the velocity.
    func testAPSDoesNotDrainHoldingPrograde() throws {
        var perHour: [Double] = []
        for (law, seconds) in [(true, 3600), (false, 300)] {
            let sim = try Simulation.forTests(perturbations: false)
            let v = sIVBInOrbit(sim, light: true)
            if !law { v.phasePlane = nil }
            v.autopilot = .prograde
            let aps = v.tanks.dropFirst(2), before = aps.reduce(0) { $0 + $1.mass }
            for _ in 0..<seconds { sim.advance(by: 1) }
            perHour.append((before - aps.reduce(0) { $0 + $1.mass }) * 3600 / Double(seconds))
            if law { XCTAssertLessThan(angleBetween(v.attitude.rotate(.unitX), v.velocity), 1.5 * deg) }
        }
        XCTAssertLessThan(perHour[0], 1)
        XCTAssertGreaterThan(perHour[1], 298)
    }

    // The phase plane decides once a step, so the simulation ends a coasting
    // step where an axis reaches the switching line. Holding in free space
    // (no orbital-period cap on the step) after the slew above, with the
    // app's 1/60 s frames, at 1x and at 10,000x over 1,000 s (at 10,000x six
    // frames end exactly there) and over 7,333 s at 10,000x, the error stays
    // inside the dead band plus one pulse. With nothing to disturb it the
    // hold is a minimum-impulse limit cycle in roll: a pulse of the two roll
    // engines changes the roll rate by Δω = 4,577 N m × 0.06 s / 2.01e5 kg m²
    // (the stack's roll inertia, FER Table 20-10: no liquid spins with the
    // tanks) = 0.078°/s, so the rate
    // alternates between some a and Δω - a across the dead band, one pulse
    // per crossing of 2 δ - K Δω = 1.61°; at worst (a = Δω / 2) 87 pulses of
    // 33 g an hour, 2.85 kg/h. Each run stays within that and a few pitch or
    // yaw pulses (2.66-2.82 kg/h), and under AS-506's 4.71 kg/h holding the
    // local horizontal in its parking orbit, disturbances and all (FER Table
    // 7-5: 11.11 kg from the end of the first ullage burn, 786.5 s, Table
    // 2-2, to T6, 9,278.24 s, Table 2-1). The runs are not
    // compared pulse for pulse: the switching-line prediction leaves out the
    // error's kinematic drift (-ω × e / 2), so at 10,000x a crossing can come
    // a coasting step late, and the pulse timing then drifts by up to a pulse
    // (datasheet §13.4 item 8); with a roll inertia 0.04 % larger the 1x and
    // 10,000x runs already part within the 1,000 s. The long run is a guard
    // against draining.
    func testAPSHoldAtTimeWarp() throws {
        var perHour: [Double] = [], worst: [Double] = [], limitCycle = 0.0, pulse = 0.0
        // App frames of 1/60 s: 60,000 at 1x and 6 at 10,000x make 1,000 s;
        // 44 at 10,000x make 7,333 s.
        for (warp, frames) in [(1.0, 60_000), (10_000, 6), (10_000, 44)] {
            let sim = try Simulation.forTests(perturbations: false)
            let v = sIVBInOrbit(sim)
            sim.placeInFreeSpace(v)
            let law = try XCTUnwrap(v.phasePlane)
            let dw = v.rotationAuthority().x * law.minimumOnTime / v.inertia[0, 0]
            let flow = try XCTUnwrap(v.thrusters.first { $0.name.hasSuffix("roll/yaw +t") }).rating.massFlow
            pulse = 2 * flow * law.minimumOnTime
            limitCycle = 3600 * dw / (2 * (2 * law.deadband - law.rateGain * dw)) * pulse
            v.autopilot = .attitudeHold
            sim.tick()
            v.attitudeCommand = AttitudeCommand(attitude: v.attitude * Quat(axis: .unitY, angle: 20 * deg)
                                                * Quat(axis: .unitX, angle: 30 * deg))
            sim.run(seconds: 600)
            let aps = v.tanks.dropFirst(2), before = aps.reduce(0) { $0 + $1.mass }
            let start = sim.time
            var error = 0.0
            sim.warp = warp
            for _ in 0..<frames {
                sim.advance(by: 1.0 / 60)
                let e = rotationVector(v.attitude.conjugate * v.attitudeCommand!.attitude)
                error = max(error, abs(e.x), abs(e.y), abs(e.z))
            }
            let seconds = sim.time - start
            XCTAssertEqual(seconds, Double(frames) * warp / 60, accuracy: 1e-3)
            perHour.append((before - aps.reduce(0) { $0 + $1.mass }) * 3600 / seconds)
            worst.append(error)
        }
        let as506 = 11.11 / (9_278.24 - 786.5) * 3600
        for rate in perHour {
            XCTAssertLessThan(rate, limitCycle + 3 * pulse * 3600 / 1_000)
            XCTAssertLessThan(rate, as506)
        }
        for e in worst { XCTAssertLessThan(e, 1.1 * deg) }
    }

    // A minimum pulse lasts the minimum on-time (0.06 s) whatever the frame
    // rate: the simulation ends a step where a pulse ends. A command 1.005°
    // away, just past the dead band, takes one pulse from rest. In 1 ms
    // frames (one step each) the pitch engine is on for exactly 0.06 s; in
    // the app's 1/60 s frames the same pulse leaves the same rate (four 1/60 s
    // steps, 0.067 s, without the step end).
    func testAPSPulseLastsTheMinimumOnTimeAtAnyFrameRate() throws {
        var rates: [Double] = [], onTime: [Double] = []
        for frame in [1.0 / 60, 0.001] {
            let sim = try Simulation.forTests(perturbations: false)
            let v = sIVBInOrbit(sim)
            sim.placeInFreeSpace(v)
            v.autopilot = .attitudeHold
            sim.tick()
            v.attitudeCommand = AttitudeCommand(attitude: v.attitude * Quat(axis: .unitY, angle: 1.005 * deg))
            var on = 0.0
            for _ in 0..<Int((0.5 / frame).rounded()) {
                sim.advance(by: frame)
                if v.thrusters.contains(where: { $0.name.hasSuffix("pitch") && $0.level > 0 }) { on += frame }
            }
            rates.append(v.angularVelocity.y)
            onTime.append(on)
        }
        XCTAssertEqual(onTime[1], AS506.apsMinimumOnTime, accuracy: 1e-9)
        XCTAssertGreaterThan(rates[1], 0)
        XCTAssertEqual(rates[0], rates[1], accuracy: 1e-3 * rates[1])
    }

    // The pointing modes set no roll attitude, so the APS damps roll rates
    // there (M0's rate loop) instead of leaving any rate under the phase
    // plane's dead band / rate gain (0.2°/s) to run on: a 0.15°/s roll in
    // Prograde on the light S-IVB dies out.
    func testAPSDampsRollInThePointingModes() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = sIVBInOrbit(sim, light: true)
        v.autopilot = .prograde
        sim.run(seconds: 120)
        v.angularVelocity.x += 0.15 * deg
        sim.run(seconds: 60)
        XCTAssertLessThan(abs(v.angularVelocity.x), 0.02 * deg)
        XCTAssertLessThan(angleBetween(v.attitude.rotate(.unitX), v.velocity), 1.5 * deg)
    }

    /// A program with one timed event, to test the simulation's hooks.
    final class OneEvent: FlightProgram {
        let at: Epoch
        var updates: [Epoch] = []
        init(at: Epoch) { self.at = at }
        func update(_ vessel: Vessel, in sim: Simulation) { updates.append(sim.time) }
        func timeToNextEvent(at now: Epoch) -> Double? { at - now > 0 ? at - now : nil }
        var status: String { "" }
    }

    // The simulation ends a step on a flight program's next event, so the
    // program acts on time at any warp: a capsule coasting in orbit (steps of
    // several seconds), or standing on the pad (10 s steps), still gets an
    // update at the event's exact epoch.
    func testStepsEndOnFlightProgramEvents() throws {
        for landed in [false, true] {
            let sim = try Simulation.forTests(perturbations: false)
            let v = VesselLibrary.capsule()
            sim.add(v)
            if landed {
                sim.placeLanded(v, on: sim.system.earth, latitude: 28.6, longitude: -80.6)
            } else {
                sim.placeInCircularOrbit(v, around: sim.system.earth, altitude: 200_000)
            }
            let program = OneEvent(at: sim.time + 7.123)
            v.flightProgram = program
            sim.warp = 100
            sim.advance(by: 0.5)
            XCTAssertTrue(program.updates.contains { abs($0 - program.at) < 1e-6 }, "landed \(landed)")
            XCTAssertGreaterThan(program.updates.count, 2, "landed \(landed)")
        }
    }
}
