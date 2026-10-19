import XCTest
@testable import OrbitCore

/// The navball's frames, angles and markers (design report
/// docs/m15/design-navball-hud.md, tests 1-11), against the 3-2-1 DCM as
/// NASA writes it out, AS-506's pad and postflight trajectory, WGS 84 and
/// spherical trigonometry.
final class NavballTests: XCTestCase {
    let deg = Double.pi / 180
    typealias P = AS506Postflight

    /// Crew axes on a vessel built in Saturn construction axes, as track C
    /// sets `controlFrame` on every vessel carrying the CM (owner decision 6).
    let crew = ApolloAxes.rotation

    /// A seeded generator, so the random angles are the same every run.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func angles(_ v: Vessel, _ sim: Simulation, frame: VelocityFrame = .orbit) -> (Navball, Double, Double, Double) {
        let ball = Navball(vessel: v, in: sim, snapshot: sim.snapshot, frame: frame)
        return (ball, ball.angles.heading / deg, ball.angles.pitch / deg, ball.angles.roll / deg)
    }

    // 1: the heading/pitch/roll convention against the 3-2-1 direction cosine
    // matrix written out in D. M. Henderson, "Euler angles, quaternions, and
    // transformation matrices for space shuttle analysis" (NASA CR,
    // NTRS 19770019231; also NASA-TM-74839): T = R1(φ) R2(θ) R3(ψ), NED to
    // body. For 50 random attitudes away from the vertical the attitude's
    // matrix matches it to 1e-12 and the angles come back to 1e-12; θ > 0
    // puts the nose above the horizon and φ > 0 the right wing down.
    func testEulerConventionAgainstTheWrittenOutDCM() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let o = sim.snapshot.orientation(sim.system.earth)
        let r = o.toInertial(sim.system.earth.figure.bodyFixed(latitude: 0.4, longitude: -1.2, height: 1000))
        let h = LocalHorizon.geodetic(at: r, body: sim.system.earth, orientation: o)
        var rng = SplitMix(state: 1969)
        for _ in 0..<50 {
            let psi = Double.random(in: 0..<(2 * .pi), using: &rng)
            let theta = Double.random(in: (-85 * deg)...(85 * deg), using: &rng)
            let phi = Double.random(in: (-.pi)...(.pi), using: &rng)
            let (cs, ss, ct, st, cf, sf) = (cos(psi), sin(psi), cos(theta), sin(theta), cos(phi), sin(phi))
            let t: [[Double]] = [
                [ct * cs, ct * ss, -st],
                [sf * st * cs - cf * ss, sf * st * ss + cf * cs, sf * ct],
                [cf * st * cs + sf * ss, cf * st * ss - sf * cs, cf * ct],
            ]
            let q = HorizonAttitude(heading: psi, pitch: theta, roll: phi).attitude(in: h)
            let c = h.nedToInertial.transposed * q.matrix   // body -> NED: T's transpose
            for i in 0..<3 { for j in 0..<3 { XCTAssertEqual(c[i, j], t[j][i], accuracy: 1e-12) } }
            let back = HorizonAttitude(attitude: q, in: h)
            XCTAssertEqual(back.heading, psi, accuracy: 1e-12)
            XCTAssertEqual(back.pitch, theta, accuracy: 1e-12)
            XCTAssertEqual(back.roll, phi, accuracy: 1e-12)
        }
        // Nose up, right wing down.
        let q = HorizonAttitude(heading: 30 * deg, pitch: 10 * deg, roll: 20 * deg).attitude(in: h)
        XCTAssertGreaterThan(q.rotate(.unitX).dot(h.up), 0)
        XCTAssertLessThan(q.rotate(.unitY).dot(h.up), 0)
        // The vertical reads the head's azimuth and roll 0, both ways.
        for pitch in [90.0, -90.0] {
            let v = HorizonAttitude(heading: 40 * deg, pitch: pitch * deg, roll: 0)
            let qv = v.attitude(in: h)
            XCTAssertEqual(h.elevationAzimuth(of: qv.rotate(Vec3(0, 0, -1))).azimuth / deg, 40, accuracy: 1e-9)
            let back = HorizonAttitude(attitude: qv, in: h)
            XCTAssertEqual(back.heading / deg, 40, accuracy: 1e-9)
            XCTAssertEqual(back.pitch / deg, pitch, accuracy: 1e-9)
            XCTAssertEqual(back.roll, 0)
        }
    }

    // 2: the Saturn on LC-39A, in crew axes (owner decision 6, plan.md
    // correction 2): pitch 90.000°, heading 090 (the crew's heads east,
    // Position I at the 90° pad azimuth, datasheet §15) and roll 0. Turned
    // to the 72.058° flight azimuth it reads 072.058; pitched over towards
    // the heads it reads roll 180, heads down.
    func testSaturnOnThePadInCrewAxes() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo11OnPad(in: sim)
        XCTAssertEqual(v.controlFrame, crew)
        var (ball, heading, pitch, roll) = angles(v, sim)
        XCTAssertEqual(pitch, 90, accuracy: 1e-9)
        XCTAssertEqual(heading, 90, accuracy: 1e-9)
        XCTAssertEqual(roll, 0)
        // The ball's top is the crew's head: east, on the horizon.
        XCTAssertEqual(ball.elevationAzimuth(of: Vec3(0, 0, -1)).elevation, 0, accuracy: 1e-9)

        // The roll program: Position I swings from east towards north.
        let up = ball.horizon.up
        v.attitude = Quat(axis: up, angle: (90 - 72.058) * deg) * v.attitude
        (_, heading, pitch, roll) = angles(v, sim)
        XCTAssertEqual(pitch, 90, accuracy: 1e-9)
        XCTAssertEqual(heading, 72.058, accuracy: 1e-9)
        XCTAssertEqual(roll, 0)

        // The pitch program tilts the nose towards +z (Position I), the
        // crew's heads: downrange, heads down.
        v.attitude = v.attitude * Quat(axis: .unitY, angle: -30 * deg)
        (ball, heading, pitch, roll) = angles(v, sim)
        XCTAssertEqual(pitch, 60, accuracy: 1e-9)
        XCTAssertEqual(heading, 72.058, accuracy: 1e-9)
        XCTAssertEqual(abs(roll), 180, accuracy: 1e-9)
        XCTAssertLessThan(ball.elevationAzimuth(of: Vec3(0, 0, -1)).elevation, 0)
    }

    // 3: AS-506's postflight trajectory (PFT Table B-II rows, PACSS 13, with
    // the Earth's axis from the pad's 28.6084° geodetic latitude and the
    // 72.058° azimuth). The prograde marker's elevation and azimuth on a
    // geocentric ball equal FER Table 4-2's flight-path angle and heading
    // within 0.002° at S-IC CECO, S-IC OECO and S-II CECO, and within
    // 0.015° at S-II OECO and S-IVB ECO, whose Table 4-2 states lie off the
    // rows (Table 10-2's offsets, AscentResidualTests).
    func testProgradeAgainstFERTable4_2() throws {
        let tight: Set<P.Event> = [.sICCenterCutoff, .sICCutoff, .sIICenterCutoff]
        for e in [P.Event.sICCenterCutoff, .sICCutoff, .sIICenterCutoff, .sIICutoff, .sIVBCutoff] {
            let fer = try XCTUnwrap(P.cutoffEvents[e]).actual
            let row = try XCTUnwrap(P.row(at: e.time))
            let h = LocalHorizon.geocentric(at: row.position, pole: P.pole)
            // Any attitude: the marker's place on the ball does not depend on it.
            let attitude = Quat(axis: Vec3(0.2, -0.7, 0.4), angle: 1.1)
            let ball = Navball(attitude: attitude, horizon: h, position: row.position, velocity: row.velocity,
                               frame: .orbit, frameVelocity: row.velocity)
            let prograde = try XCTUnwrap(ball.marker(.prograde))
            let (el, az) = ball.elevationAzimuth(of: prograde.body)
            let tolerance = tight.contains(e) ? 0.002 : 0.015
            XCTAssertEqual(el / deg, fer.flightPathAngle, accuracy: tolerance, "\(e)")
            XCTAssertEqual(az / deg, fer.heading, accuracy: tolerance, "\(e)")
        }
    }

    // 4: on the pad the orbit mode reads the Earth's rotation, 408.636 m/s
    // due east on the horizon (datasheet §15.2; SP-4029: 408.64 m/s, heading
    // 90°); the surface mode reads 0 with no prograde marker, and the
    // automatic mode is the surface.
    func testPadVelocity() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo11OnPad(in: sim)
        let orbit = Navball(vessel: v, in: sim, snapshot: sim.snapshot, frame: .orbit)
        XCTAssertEqual(orbit.speed, 408.636, accuracy: 0.001)
        let prograde = try XCTUnwrap(orbit.marker(.prograde))
        let (el, az) = orbit.elevationAzimuth(of: prograde.body)
        XCTAssertEqual(el / deg, 0, accuracy: 1e-9)
        XCTAssertEqual(az / deg, 90, accuracy: 1e-9)
        let surface = Navball(vessel: v, in: sim, snapshot: sim.snapshot, frame: .surface)
        XCTAssertEqual(surface.speed, 0, accuracy: 1e-6)
        XCTAssertNil(surface.marker(.prograde))
        XCTAssertNil(surface.marker(.retrograde))
        XCTAssertEqual(Navball.autoFrame(previous: .orbit, vessel: v, snapshot: sim.snapshot), .surface)
    }

    // 5: the deviation of the vertical at LC-39A on the ellipsoid: the
    // geodetic and geocentric horizons differ by φ - atan((1 - e²) tan φ),
    // 0.1615° at 28.6084° (WGS 84, NIMA TR8350.2), and the radial-out marker
    // sits that far from the navball's zenith.
    func testDeviationOfTheVertical() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let earth = sim.system.earth, o = sim.snapshot.orientation(earth)
        let lat = AS506.padLatitude * deg, lon = AS506.padLongitude * deg
        let r = o.toInertial(earth.figure.bodyFixed(latitude: lat, longitude: lon, height: 0))
        let geodetic = LocalHorizon.geodetic(at: r, body: earth, orientation: o)
        let geocentric = LocalHorizon.geocentric(at: r, pole: o.pole)
        let e2 = 6.69437999014e-3   // TR8350.2 Table 3.3
        let expected = (lat - atan((1 - e2) * tan(lat))) / deg
        XCTAssertEqual(expected, 0.1615, accuracy: 0.00005)
        XCTAssertEqual(angleBetween(geodetic.up, geocentric.up) / deg, expected, accuracy: 1e-9)
        XCTAssertEqual(geodetic.east.dot(geocentric.east), 1, accuracy: 1e-15)
        let ball = Navball(attitude: .identity, horizon: geodetic, position: r, velocity: .zero, frame: .orbit,
                           frameVelocity: .zero)
        let radial = try XCTUnwrap(ball.marker(.radialOut))
        let (el, az) = ball.elevationAzimuth(of: radial.body)
        XCTAssertEqual(90 - el / deg, expected, accuracy: 1e-9)
        XCTAssertEqual(az / deg, 180, accuracy: 1e-9)   // the radius leans towards the equator
    }

    // 6: spherical trigonometry on a circular orbit inclined 32.5°, the
    // vessel prograde and upright: at the ascending node heading 57.5° (90° -
    // i), pitch and roll 0; at argument of latitude u the heading from
    // cos A = sin i cos u / cos φ, sin φ = sin i sin u; at u = 90° due east,
    // pitch 0 and rolled right by the deviation of the vertical (the head,
    // the radius, leans towards the equator of the geodetic up). Prograde
    // sits at the ball's centre, normal on its left rim (north of an
    // eastward track) and radial out at its top.
    func testCircularOrbitHeadings() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.rocket()
        sim.add(v)
        let i = 32.5 * deg
        for u in [0.0, 45, 90] {
            sim.placeInCircularOrbit(v, around: sim.system.earth, altitude: 185_000, inclination: 32.5,
                                     ascendingNode: 40, argumentOfLatitude: u)
            let (ball, heading, pitch, roll) = angles(v, sim)
            let phi = asin(sin(i) * sin(u * deg))
            let expected = acos(sin(i) * cos(u * deg) / cos(phi)) / deg
            XCTAssertEqual(heading, expected, accuracy: 0.001, "u = \(u)")
            if u == 0 {   // on the equator the geodetic horizon is the geocentric one
                XCTAssertEqual(pitch, 0, accuracy: 1e-9)
                XCTAssertEqual(roll, 0, accuracy: 1e-9)
            } else if u == 90 {
                XCTAssertEqual(pitch, 0, accuracy: 1e-9)
                XCTAssertEqual(roll, angleBetween(ball.horizon.up, v.position) / deg, accuracy: 1e-9)
                XCTAssertEqual(roll, 0.17, accuracy: 0.01)
            }
            let p = Navball.project(try XCTUnwrap(ball.marker(.prograde)).body)
            XCTAssertEqual(p.x, 0, accuracy: 1e-12)
            XCTAssertEqual(p.y, 0, accuracy: 1e-12)
            XCTAssertTrue(p.front)
            let n = Navball.project(try XCTUnwrap(ball.marker(.normal)).body)
            XCTAssertEqual(n.x, -1, accuracy: 1e-12)
            XCTAssertEqual(n.y, 0, accuracy: 1e-12)
            let rOut = Navball.project(try XCTUnwrap(ball.marker(.radialOut)).body)
            XCTAssertEqual(rOut.x, 0, accuracy: 1e-12)
            XCTAssertEqual(rOut.y, 1, accuracy: 1e-12)
        }
        XCTAssertEqual(acos(sin(i)) / deg, 57.5, accuracy: 1e-9)
    }

    // 7: marker algebra on an eccentric, climbing state: retrograde opposes
    // prograde, normal is perpendicular to both prograde and radial, every
    // marker is a unit vector, the ball's matrix is a rotation; the
    // projection of the six body axes, and the rim pointer's angle for a
    // marker behind the ball.
    func testMarkerAlgebraAndProjection() throws {
        let r = Vec3(6_500_000, 1_000_000, -300_000), vel = Vec3(1_200, 7_400, 2_100)
        let attitude = Quat(axis: Vec3(1, 2, 3), angle: 0.8)
        let h = LocalHorizon.geocentric(at: r, pole: .unitZ)
        let ball = Navball(attitude: attitude, horizon: h, position: r, velocity: vel, frame: .orbit,
                           frameVelocity: vel)
        let pro = try XCTUnwrap(ball.marker(.prograde)).body, retro = try XCTUnwrap(ball.marker(.retrograde)).body
        let normal = try XCTUnwrap(ball.marker(.normal)).body, anti = try XCTUnwrap(ball.marker(.antinormal)).body
        let out = try XCTUnwrap(ball.marker(.radialOut)).body, inward = try XCTUnwrap(ball.marker(.radialIn)).body
        XCTAssertEqual((pro + retro).length, 0, accuracy: 1e-15)
        XCTAssertEqual((normal + anti).length, 0, accuracy: 1e-15)
        XCTAssertEqual((out + inward).length, 0, accuracy: 1e-15)
        XCTAssertEqual(pro.dot(normal), 0, accuracy: 1e-15)
        XCTAssertEqual(out.dot(normal), 0, accuracy: 1e-15)
        XCTAssertGreaterThan(pro.dot(out), 0)   // climbing
        for m in ball.markers { XCTAssertEqual(m.body.length, 1, accuracy: 1e-15) }
        XCTAssertEqual(attitude.rotate(pro).dot(vel.normalized), 1, accuracy: 1e-15)
        let c = ball.bodyToNED, ctc = c.transposed * c
        for i in 0..<3 { for j in 0..<3 { XCTAssertEqual(ctc[i, j], i == j ? 1 : 0, accuracy: 1e-15) } }
        XCTAssertEqual(c.determinant, 1, accuracy: 1e-15)

        let axes: [(Vec3, Double, Double, Bool)] = [(.unitX, 0, 0, true), (-.unitX, 0, 0, false),
                                                    (.unitY, 1, 0, false), (-.unitY, -1, 0, false),
                                                    (.unitZ, 0, -1, false), (-.unitZ, 0, 1, false)]
        for (b, x, y, front) in axes {
            let p = Navball.project(b)
            XCTAssertEqual(p.x, x)
            XCTAssertEqual(p.y, y)
            XCTAssertEqual(p.front, front)
        }
        // Behind the ball, up and to the right: the pointer at 45°.
        XCTAssertEqual(Navball.edgeAngle(Vec3(-0.5, 0.5, -0.5).normalized) / deg, 45, accuracy: 1e-12)
        XCTAssertEqual(Navball.edgeAngle(Vec3(-0.9, 0, 0.1)) / deg, -90, accuracy: 1e-12)
    }

    // 8: the thrust marker on the S-II: at null gimbal the stage's thrust
    // axis; with one J-2 deflected, Thruster.thrustDirection's tilt (the null
    // direction plus tan(angle) towards the actuator's tilt); with an engine
    // failed, the other four; with the engines off, none.
    func testThrustMarker() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.saturnV()
        _ = v.jettisonNextStage()   // the S-IC
        v.controlFrame = .identity   // body axes (a separation sets the crew's again)
        sim.add(v)
        sim.placeInFreeSpace(v)
        v.mainThrottle = 1
        let j2s = try XCTUnwrap(v.activeStage).thrusters.filter { $0.groups.contains(.main) }
        XCTAssertEqual(j2s.count, 5)
        let ramp = j2s.compactMap { $0.transients.map { $0.startDelay + $0.startRise } }.max() ?? 0
        sim.run(seconds: ramp + 0.02)
        XCTAssertTrue(j2s.allSatisfy(\.isDelivering))

        func marker() -> Vec3? { Navball(vessel: v, in: sim, snapshot: sim.snapshot, frame: .orbit).marker(.thrust)?.body }
        func mean(_ engines: [Thruster], direction: (Thruster) -> Vec3 = { $0.direction }) -> Vec3 {
            engines.reduce(Vec3.zero) { $0 + direction($1) * $1.thrust(ambientPressure: 0, seaLevelPressure: 0) }
                .normalized
        }
        for e in j2s { for k in e.gimbal.indices { e.gimbal[k].angle = 0 } }
        XCTAssertLessThan((try XCTUnwrap(marker()) - mean(j2s)).length, 1e-15)
        XCTAssertEqual(try XCTUnwrap(marker()).x, 1, accuracy: 1e-12)

        let deflected = try XCTUnwrap(j2s.first { !$0.gimbal.isEmpty })
        deflected.gimbal[0].angle = 2 * deg
        let tilted = (deflected.direction + deflected.gimbal[0].tilt * tan(2 * deg)).normalized
        let expected = mean(j2s) { $0 === deflected ? tilted : $0.direction }
        XCTAssertLessThan((try XCTUnwrap(marker()) - expected).length, 1e-15)
        XCTAssertGreaterThan(angleBetween(try XCTUnwrap(marker()), .unitX), 0.3 * deg)
        deflected.gimbal[0].angle = 0

        let failed = j2s[0]
        failed.fail()
        sim.run(seconds: 2)
        XCTAssertFalse(failed.isDelivering)
        XCTAssertLessThan((try XCTUnwrap(marker()) - mean(Array(j2s.dropFirst()))).length, 1e-12)

        v.mainThrottle = 0
        sim.run(seconds: 2)
        XCTAssertNil(marker())
    }

    // 9: the command marker and the attitude error. A hold 5° nose-up of the
    // attitude reads an error of +5° in pitch (the sign the FCC law flies,
    // Autopilot.swift) and its marker sits 5° above the ball's centre; in
    // crew axes, whose up is the Saturn's -z, the same command is 5° below.
    // Under prograde the marker is the prograde target; kill rotation shows
    // none.
    func testCommandMarkerAndAttitudeError() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.rocket()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: sim.system.earth, altitude: 185_000, inclination: 32.5)
        v.autopilot = .attitudeHold
        v.attitudeCommand = AttitudeCommand(attitude: v.attitude * Quat(axis: .unitY, angle: 5 * deg))
        var ball = Navball(vessel: v, in: sim, snapshot: sim.snapshot, frame: .orbit)
        let error = try XCTUnwrap(ball.attitudeError)
        XCTAssertEqual(error.y / deg, 5, accuracy: 1e-12)
        XCTAssertEqual(error.x, 0, accuracy: 1e-15)
        XCTAssertEqual(error.z, 0, accuracy: 1e-15)
        let p = Navball.project(try XCTUnwrap(ball.marker(.command)).body)
        XCTAssertEqual(p.x, 0, accuracy: 1e-15)
        XCTAssertEqual(asin(p.y) / deg, 5, accuracy: 1e-12)
        XCTAssertTrue(p.front)

        v.controlFrame = crew
        ball = Navball(vessel: v, in: sim, snapshot: sim.snapshot, frame: .orbit)
        XCTAssertEqual(try XCTUnwrap(ball.attitudeError).y / deg, -5, accuracy: 1e-12)
        XCTAssertEqual(asin(Navball.project(try XCTUnwrap(ball.marker(.command)).body).y) / deg, -5, accuracy: 1e-12)
        v.controlFrame = .identity

        v.autopilot = .prograde
        ball = Navball(vessel: v, in: sim, snapshot: sim.snapshot, frame: .orbit)
        let command = try XCTUnwrap(ball.marker(.command)).body
        XCTAssertLessThan((command - (try XCTUnwrap(ball.marker(.prograde)).body)).length, 1e-15)
        XCTAssertEqual(try XCTUnwrap(ball.attitudeError).length, 0, accuracy: 1e-12)

        v.autopilot = .killRotation
        ball = Navball(vessel: v, in: sim, snapshot: sim.snapshot, frame: .orbit)
        XCTAssertNil(ball.marker(.command))
        XCTAssertNil(ball.attitudeError)
    }

    // 10: the aerodynamic angles in the launch day's air, winds included
    // (datasheet §11): cos α cos β is the cosine of the vessel's total angle
    // of attack; in crew axes α and β change sign.
    func testAeroAngles() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let earth = sim.system.earth
        let atmosphere = AS506.launchDayAtmosphere()
        sim.atmospheres[earth.id] = atmosphere
        let v = VesselLibrary.saturnV()
        v.controlFrame = .identity   // body axes first
        sim.add(v)
        sim.place(v, geodeticLatitude: 28.75, longitude: -80.3, height: 12_000, inertialSpeed: 900,
                  flightPathAngle: 35, azimuth: 76, attitude: Quat(axis: Vec3(0.3, 0.5, 0.8), angle: 0.08))
        let wind = atmosphere.wind(altitude: v.altitude)
        XCTAssertGreaterThan(hypot(wind.east, wind.north), 5)
        XCTAssertGreaterThan(v.angleOfAttack, 1 * deg)
        let body = try XCTUnwrap(Navball(vessel: v, in: sim, snapshot: sim.snapshot, frame: .surface).aero)
        XCTAssertEqual(cos(body.alpha) * cos(body.beta), cos(v.angleOfAttack), accuracy: 1e-9)
        v.controlFrame = crew
        let crewAxes = try XCTUnwrap(Navball(vessel: v, in: sim, snapshot: sim.snapshot, frame: .surface).aero)
        XCTAssertEqual(crewAxes.alpha, -body.alpha, accuracy: 1e-12)
        XCTAssertEqual(crewAxes.beta, -body.beta, accuracy: 1e-12)

        // Out of the air there are none.
        sim.placeInFreeSpace(v)
        sim.updateTelemetry(v, snapshot: sim.snapshot)
        XCTAssertNil(Navball(vessel: v, in: sim, snapshot: sim.snapshot, frame: .orbit).aero)
    }

    // 11: the automatic speed mode's hysteresis: climbing it changes to the
    // orbit at 50 km, descending to the surface at 40 km, and in between it
    // keeps what it had; landed it is the surface.
    func testAutoFrameHysteresis() {
        func auto(_ previous: VelocityFrame?, _ km: Double, _ climb: Double, landed: Bool = false) -> VelocityFrame {
            Navball.autoFrame(previous: previous, altitude: km * 1000, verticalSpeed: climb, landed: landed)
        }
        // Climbing from the pad.
        var f = VelocityFrame.surface
        for km in stride(from: 0.0, through: 49.9, by: 0.1) { f = auto(f, km, 1_000) }
        XCTAssertEqual(f, .surface)
        f = auto(f, 50.1, 1_000)
        XCTAssertEqual(f, .orbit)
        // Coming down.
        for km in stride(from: 120.0, through: 40.1, by: -0.1) { f = auto(f, km, -1_000) }
        XCTAssertEqual(f, .orbit)
        f = auto(f, 39.9, -1_000)
        XCTAssertEqual(f, .surface)
        // Between the thresholds the previous mode stays, whichever way.
        XCTAssertEqual(auto(.orbit, 45, 100), .orbit)
        XCTAssertEqual(auto(.surface, 45, -100), .surface)
        XCTAssertEqual(auto(.orbit, 30, 100), .orbit)
        XCTAssertEqual(auto(.surface, 80, -100), .surface)
        // Landed, and starting with none.
        XCTAssertEqual(auto(.orbit, 0, 0, landed: true), .surface)
        XCTAssertEqual(auto(nil, 185, -1), .orbit)
        XCTAssertEqual(auto(nil, 30, 1), .surface)
    }
}
