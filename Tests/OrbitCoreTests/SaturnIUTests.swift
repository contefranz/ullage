import XCTest
@testable import OrbitCore

/// The Saturn V Instrument Unit's flight program on Apollo 11 (`SaturnIU.as506()`,
/// M1 item 3, open loop; datasheet §8). External references: the Apollo 11
/// timeline (SP-4029; datasheet §1.2), the SA-504 guidance equations (Boeing
/// D5-15706-4, "GE504") and the SA-503 flight manual (MSFC-MAN-503, "MAN503").
final class SaturnIUTests: XCTestCase {
    let deg = Double.pi / 180

    /// Apollo 11 on LC-39A with the IU aboard and the F-1s lit, so the first
    /// step is first motion (range time 0.30 s).
    struct Flight {
        let sim: Simulation
        let v: Vessel
        let iu: SaturnIU
        let start: Epoch
        /// Range time now, s.
        func range() -> Double { sim.time - start + AS506.firstMotion }
        /// Range time of an IU log entry.
        func range(_ e: Epoch) -> Double { e - start + AS506.firstMotion }
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
        return Flight(sim: sim, v: v, iu: v.flightProgram as! SaturnIU, start: sim.time)
    }

    // The stack stands on the pad as Apollo 11 did: at LC-39A's geocentric
    // latitude (SP-4029, H), nose up, Position I (+z) east, the 90° pad
    // azimuth (TVC datasheet §7.1; GE504's initial roll A_Z - 90°), with the
    // IU armed and nothing commanded yet. Space is refused: it would drop the
    // S-IC on the pad.
    func testOnThePad() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo11OnPad(in: sim)
        let ll = v.latitudeLongitude(snapshot: sim.snapshot)
        XCTAssertEqual(ll.lat / deg, 28.4470, accuracy: 1e-9)
        XCTAssertEqual(ll.lon / deg, -80.6041, accuracy: 1e-9)
        let up = v.position.normalized, pole = sim.snapshot.orientation(sim.system.earth).pole
        let east = pole.cross(up).normalized
        XCTAssertGreaterThan(v.attitude.rotate(.unitX).dot(up), 1 - 1e-12)
        XCTAssertGreaterThan(v.attitude.rotate(.unitZ).dot(east), 1 - 1e-12)
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

    // GE504 Table 5-I, read from the page images: the four segments of the
    // pre-IGM pitch polynomial join (to within 0.05°; a misread digit would
    // break that), the command is near zero where the program starts (12-13 s),
    // the pitch rate never exceeds the 1°/s command limit, and the command is
    // -66.59° at SA-504's 153 s arrest and held there. It follows AS-506's
    // commanded pitch (MAN-506 Figure 2-2, read to about 1°: -20° a minute
    // after first motion, -56° at two minutes, -67.5° at the arrest; first
    // motion is T1 - 0.4 s there). The IU flies it times `pitchScale`,
    // arrested at T1 + 159.37 s (FER: 160.0 s range).
    func testPitchPolynomialTranscription() {
        let p = TiltProgram(boundaries: AS506.pitchSegmentBoundaries, coefficients: AS506.pitchCoefficients,
                            arrest: 153)
        let as506 = AS506.tiltProgram
        XCTAssertEqual(as506.pitch(at: 150), AS506.pitchScale * p.pitch(at: 150), accuracy: 1e-12)
        XCTAssertEqual(as506.arrest, 160.0 - 0.63, accuracy: 1e-12)
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
    // gains (0.245 and 0.15 s, Boeing D5-15481-1 Table 3-IV: L) the start
    // overshoots: AS-506 peaked at a 0.92° roll error and a 1.38°/s roll rate
    // (FER Table 11-2), the model at 1.18° and 1.39°/s (2 and 3 s after the
    // start, against 0.6 and 1.2 s: its roll loop is slower than AS-506's).
    // Later in the ramp the law tracks it (a1/a0) x 1°/s =
    // 0.61° behind, and the stack settles on the flight azimuth. No commanded
    // angle ever moves faster than 1°/s.
    func testTowerYawAndRollProgram() throws {
        let f = try launch()
        var lastChi: Vec3?, worstRate = 0.0, maxYaw = 0.0, northward = 1.0
        var riseAtStart: Double?, previousRise = 0.0, rollLag: [Double] = [], rollRate: [Double] = []
        var peakRollError = 0.0, peakRollRate = 0.0
        let r0 = f.v.position.length
        let north = { () -> Vec3 in
            let up = f.v.position.normalized, pole = f.sim.snapshot.orientation(f.sim.system.earth).pole
            return up.cross(pole.cross(up).normalized)
        }
        f.fly(to: 45) {
            let rise = f.v.position.length - r0
            if riseAtStart == nil && f.iu.programStarted != nil { riseAtStart = previousRise }
            previousRise = rise
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
        // Program start at 137 m (one step's rise is about 0.3 m then).
        let started = try XCTUnwrap(f.iu.programStarted)
        XCTAssertEqual(try XCTUnwrap(riseAtStart), 137.15, accuracy: 0.15)
        XCTAssertLessThan(started, AS506.programStartBackup)
        // Roll: the start's peaks, lag and rate late in the ramp, then
        // Position I on the flight azimuth.
        XCTAssertEqual(peakRollRate, 1.38, accuracy: 0.1)
        XCTAssertEqual(peakRollError, 0.92, accuracy: 0.35)
        XCTAssertFalse(rollLag.isEmpty)
        XCTAssertEqual(rollLag.reduce(0, +) / Double(rollLag.count), 0.15 / 0.245, accuracy: 0.03)
        for lag in rollLag { XCTAssertEqual(lag, 0.15 / 0.245, accuracy: 0.08) }
        for rate in rollRate { XCTAssertEqual(rate, 1, accuracy: 0.07) }
        let angles = try XCTUnwrap(f.iu.eulerAngles(of: f.v.attitude))
        XCTAssertEqual(angles.x / deg, 0, accuracy: 0.05)
        XCTAssertEqual(f.iu.chi.x, 0, accuracy: 1e-12)
        XCTAssertEqual(angles.z / deg, 0, accuracy: 0.05)
    }

    // The S-IC ascent against Apollo 11's (FER Tables 4-1 and 4-2; datasheet
    // §5 C tolerances). At CECO (135.2 s) and OECO (161.63 s): altitude above
    // the pad (the model's pad sits 4.78 km further from the Earth's centre
    // than the real one, so radius would carry that offset), space-fixed
    // velocity, flight-path angle and heading. Only the OECO flight-path angle
    // was fitted (`pitchScale`); the rest are checks, the headings of the
    // space-fixed frame, flight azimuth and roll program in particular.
    // Mach 1 within 3 s of 66.3 s and a max Q of 28-36 kPa (US-1976 has no
    // July density excess). Max Q comes at 75 s rather than 83 s and the
    // pitch program starts at T1 + 10.4 s rather than 12.6 s: the model
    // climbs faster than the real stack in the first minute (datasheet §8).
    func testSICAscentMatchesApollo11() throws {
        let f = try launch()
        var mach1: Double?, maxQ = 0.0
        var states: [(alt: Double, v: Double, gamma: Double, heading: Double)] = []
        var marks = [135.2, 161.63]
        f.fly(to: 161.7) {
            if mach1 == nil && f.v.mach >= 1 { mach1 = f.range() }
            maxQ = max(maxQ, f.v.dynamicPressure)
            guard let m = marks.first, f.range() >= m - 1e-9 else { return }
            marks.removeFirst()
            let up = f.v.position.normalized, pole = f.sim.snapshot.orientation(f.sim.system.earth).pole
            let east = pole.cross(up).normalized, north = up.cross(east)
            states.append((f.v.altitude, f.v.velocity.length, asin(up.dot(f.v.velocity.normalized)) / deg,
                           atan2(f.v.velocity.dot(east), f.v.velocity.dot(north)) / deg))
        }
        XCTAssertEqual(try XCTUnwrap(mach1), 66.3, accuracy: 3)
        XCTAssertGreaterThan(maxQ, 28_000)
        XCTAssertLessThan(maxQ, 36_000)
        guard states.count == 2 else { return XCTFail("missing cutoff states") }
        let (ceco, oeco) = (states[0], states[1])
        XCTAssertEqual(ceco.alt, 44_000, accuracy: 2_500)
        XCTAssertEqual(ceco.v, 1_979.0, accuracy: 50)
        XCTAssertEqual(ceco.gamma, 22.957, accuracy: 1.5)
        XCTAssertEqual(ceco.heading, 76.315, accuracy: 0.5)
        XCTAssertEqual(oeco.alt, 66_100, accuracy: 2_500)
        XCTAssertEqual(oeco.v, 2_764.1, accuracy: 40)
        XCTAssertEqual(oeco.gamma, 19.114, accuracy: 0.2)
        XCTAssertEqual(oeco.heading, 75.439, accuracy: 0.5)
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
    // §8.6: c 0.898 s^-2, wn 0.90 rad/s, zeta 0.345, a 32 % overshoot at
    // 3.7 s). Mass properties frozen; self-consistency of law, gains and model.
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
        XCTAssertEqual(c, 0.898, accuracy: 0.005)
        XCTAssertEqual(wn, 0.90, accuracy: 0.005)
    }

    // One flight, first motion to T5 + 87 s, against AS-506's sequence of
    // events (FER Tables 2-1 and 2-2). Timed events are logged at their
    // scheduled time and act within a step (0.02 s); T2-T5 start when the IU
    // sees the cutoff, one or two steps after it (the LVDC took 0.03-0.23 s).
    // The propellant model puts the S-IC burnout at 161.63 s and the S-II's
    // at 548.28 s (its J-2s light at 164.04 s, the model being calibrated
    // from 164.00). The stack ends as S-IVB, IU, SLA, LM and CSM, with every
    // spent part its own vessel, the S-II on its low mixture ratio, and the
    // APS ullage burn over. IGM is not modelled, so the S-IVB cuts off as
    // long after T4 as on the flight (T4 + 151.10 s).
    func testFlightSequenceFollowsTheApollo11Timeline() throws {
        let f = try launch()
        var ullage = 0.0
        f.fly(to: 787) {
            if f.v.thrusters.contains(where: { $0.name.hasSuffix("ullage") && $0.level > 0 }) { ullage += 0.02 }
        }
        // Range times from FER Table 2-2 (actual), or the time base plus the
        // FER's offset where the model's time base differs by a step.
        let t3 = 161.63, t4 = 548.22, t5 = 699.34
        let expected: [(String, Double, Double)] = [
            ("T1: liftoff", 0.63, 1e-6),
            ("S-IC flight control gains", 0.63, 1e-6),
            ("S-IC outboard engine cant", 20.63, 1e-6),            // FER 20.6, T1 + 20.0
            ("S-IC flight control gains", 105.63, 1e-6),
            ("S-IC flight control gains", 130.63, 1e-6),
            ("S-IC centre engine cutoff", 135.20, 0.02),           // FER 135.20
            ("T2: centre engine cutoff sensed", 135.27, 0.06),     // FER Table 2-1, sensed 0.07 s later
            ("tilt arrest", 160.0, 1e-6),                          // FER 160.0
            ("T3: S-IC outboard engine cutoff sensed", 161.66, 0.2),  // FER Table 2-1
            ("S-IC outboard engine cutoff", t3, 0.2),
            ("S-IC/S-II separation", t3 + 0.7, 0.2),
            ("S-II flight control gains", t3 + 2.4, 0.2),
            ("S-II ignition", 164.0, 0.2),                         // FER 164.0, T3 + 2.4
            ("S-II aft interstage jettison", 192.3, 0.2),          // FER 192.3
            ("launch escape tower jettison", 197.9, 0.2),          // FER 197.9
            ("IGM phase 1 (not modelled: attitude held)", 204.1, 0.2),  // FER 204.1, T3 + 42.4
            ("S-II flight control gains", t3 + 61.4, 0.2),         // SA-507 ICD switch point 3
            ("S-II flight control gains", t3 + 191.4, 0.2),        // switch point 4
            ("S-II centre engine cutoff", 460.6, 0.2),             // FER 460.6
            ("S-II mixture ratio shift", 491.0, 0.2),              // the model's (FER 494.8, §8)
            ("T4: S-II outboard engine cutoff sensed", 548.24, 0.3),  // FER Table 2-1
            ("S-II outboard engine cutoff", t4, 0.3),
            ("S-II/S-IVB separation", t4 + 0.8, 0.3),
            ("S-IVB flight control law", 552.2, 0.3),
            ("S-IVB ignition", 552.2, 0.3),                        // FER 552.2
            ("S-IVB cutoff (Apollo 11's burn time: IGM not modelled)", 699.34, 0.3),  // FER 699.34
            ("T5: S-IVB cutoff sensed", t5, 0.3),                  // FER 699.57: 0.23 s sensing
            ("APS ullage on", t5 + 0.3, 0.3),                      // FER 699.8
            ("orbital guidance: local horizontal", t5 + 19.8, 0.3),  // FER 719.3
            ("APS ullage off", t5 + 87.0, 0.3),                    // FER 786.5
        ]
        let log = f.iu.log.filter { $0.event != "roll and pitch program" }
        XCTAssertEqual(log.map(\.event), expected.map(\.0))
        for (entry, (name, time, tolerance)) in zip(log, expected) {
            XCTAssertEqual(f.range(entry.time), time, accuracy: tolerance, name)
        }
        XCTAssertEqual(f.v.parts.map(\.name), ["S-IVB", "IU", "SLA", "LM", "CSM"])
        XCTAssertEqual(f.sim.vessels.map(\.name), ["Apollo 11", "Apollo 11 – S-IC", "Apollo 11 – S-IC/S-II interstage",
                                                  "Apollo 11 – LES", "Apollo 11 – S-II"])
        let sII = f.sim.vessels[4].parts[0]
        XCTAssertEqual(sII.thrusters.filter { $0.groups.contains(.main) }.map(\.rating.name),
                       Array(repeating: "J-2 EMR 4.7", count: 5))
        XCTAssertFalse(f.sim.vessels[1].thrusters.first { $0.name == "S-IC engine 5" }!.isEnabled)
        XCTAssertFalse(sII.thrusters.first { $0.name == "S-II engine 5" }!.isEnabled)
        XCTAssertNil(f.v.fccGains)
        XCTAssertEqual(f.v.mainThrottle, 0)
        XCTAssertEqual(ullage, 87.0 - 0.3, accuracy: 0.03)
        XCTAssertEqual(f.v.translationInput, .zero)
        XCTAssertEqual(f.v.autopilot, .attitudeHold)
        XCTAssertTrue(f.iu.status.hasPrefix("T5+"), f.iu.status)

        // Orbital guidance (GE504 §4.1.11): +x along the local horizontal in
        // the direction of motion, +z towards the Earth. The APS slews there
        // from the attitude held since the tilt arrest and holds it within
        // the dead band, offset by the switching line's 5 s times the
        // orbital rate (0.07°/s: 0.33°), so within (1 + 0.33)° on each of two
        // axes.
        let aps = f.v.tanks.dropFirst(2), before = aps.reduce(0) { $0 + $1.mass }
        for _ in 0..<400 { f.sim.advance(by: 1) }
        let up = f.v.position.normalized
        let horizontal = (f.v.velocity - up * f.v.velocity.dot(up)).normalized
        XCTAssertLessThan(angleBetween(f.v.attitude.rotate(.unitX), horizontal), 1.9 * deg)
        XCTAssertLessThan(angleBetween(f.v.attitude.rotate(.unitZ), -up), 1.9 * deg)
        XCTAssertLessThan(before - aps.reduce(0) { $0 + $1.mass }, 5)
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
    // pending events (IGM note, gain switches, centre engine cutoff, mixture
    // ratio shift) never fire into the S-IVB, which keeps its own law.
    func testEarlierTimeBaseEventsDropWhenTheNextStarts() throws {
        let f = try launch()
        f.fly(to: 200)
        for _ in 0..<3 where f.v.parts.contains(where: { $0.name == "S-II" }) { f.sim.stage(f.v) }
        XCTAssertFalse(f.v.parts.contains { $0.name == "S-II" })
        f.fly(to: 260)
        let t4 = try XCTUnwrap(f.iu.timeBases[.t4])
        XCTAssertEqual(f.range(t4), 200, accuracy: 0.03)
        XCTAssertEqual(f.iu.log.filter { $0.time >= t4 }.map(\.event),
                       ["T4: S-II outboard engine cutoff sensed", "S-II outboard engine cutoff",
                        "S-II/S-IVB separation (nothing to do: gone)", "S-IVB flight control law", "S-IVB ignition"])
        XCTAssertNil(f.v.fccGains)
        XCTAssertEqual(f.v.mainThrottle, 1)
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
    // 5 s and 0.06 s minimum on-time, placeholders): a hold command 20° away
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
    // would empty both modules (298 kg, the FER-507 load) within the hour,
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
    // app's 1/60 s frames, the APS works as little at 10,000x as at 1x
    // (under 1 kg/h; 47 kg/h at 10,000x with steps up to 60 s), and the
    // error stays inside the dead band plus one pulse.
    func testAPSHoldAtTimeWarp() throws {
        var perHour: [Double] = [], worst: [Double] = []
        for (warp, seconds) in [(1.0, 900.0), (10_000, 7200)] {
            let sim = try Simulation.forTests(perturbations: false)
            let v = sIVBInOrbit(sim)
            sim.placeInFreeSpace(v)
            v.autopilot = .attitudeHold
            sim.tick()
            v.attitudeCommand = AttitudeCommand(attitude: v.attitude * Quat(axis: .unitY, angle: 20 * deg)
                                                * Quat(axis: .unitX, angle: 30 * deg))
            sim.run(seconds: 600)
            let aps = v.tanks.dropFirst(2), before = aps.reduce(0) { $0 + $1.mass }
            let start = sim.time
            var error = 0.0
            sim.warp = warp
            while sim.time - start < seconds {
                sim.advance(by: 1.0 / 60)
                let e = rotationVector(v.attitude.conjugate * v.attitudeCommand!.attitude)
                error = max(error, abs(e.x), abs(e.y), abs(e.z))
            }
            perHour.append((before - aps.reduce(0) { $0 + $1.mass }) * 3600 / (sim.time - start))
            worst.append(error)
        }
        XCTAssertLessThan(perHour[0], 1.5)
        XCTAssertEqual(perHour[1], perHour[0], accuracy: 0.25 * perHour[0])
        for e in worst { XCTAssertLessThan(e, 1.1 * deg) }
    }

    // A minimum pulse lasts the minimum on-time (0.06 s) whatever the frame
    // rate: the simulation ends a step where a pulse ends. One pulse from
    // rest, flown in the app's 1/60 s frames and in 1 ms frames, leaves the
    // same rate (four 1/60 s steps, 0.067 s, without that).
    func testAPSPulseLastsTheMinimumOnTimeAtAnyFrameRate() throws {
        var rates: [Double] = [], pulses: [Int] = []
        for frame in [1.0 / 60, 0.001] {
            let sim = try Simulation.forTests(perturbations: false)
            let v = sIVBInOrbit(sim)
            sim.placeInFreeSpace(v)
            v.autopilot = .attitudeHold
            sim.tick()
            v.attitudeCommand = AttitudeCommand(attitude: v.attitude * Quat(axis: .unitY, angle: 1.02 * deg))
            var on = false, count = 0
            for _ in 0..<Int((0.5 / frame).rounded()) {
                sim.advance(by: frame)
                let firing = v.thrusters.contains { $0.name.hasSuffix("pitch") && $0.level > 0 }
                if firing && !on { count += 1 }
                on = firing
            }
            rates.append(v.angularVelocity.y)
            pulses.append(count)
        }
        XCTAssertEqual(pulses, [1, 1])
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
