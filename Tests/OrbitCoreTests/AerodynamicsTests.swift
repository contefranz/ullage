import XCTest
@testable import OrbitCore

/// The launch stack's aerodynamics and the launch-day atmosphere (datasheet
/// §11). External references: Boeing D5-15796-1 (the Saturn V flight
/// evaluation's axial-force method and data), REF504 / TM X-53517 (normal
/// force and centre of pressure), and the AS-506 Flight Evaluation Report's
/// Appendix A with PRA-63 (NASA TM X-53139) for the day's air and winds.
final class AerodynamicsTests: XCTestCase {
    let deg = Double.pi / 180
    let fullStack = AS506.aerodynamics[0]

    /// The model's loads at Mach `mach` and dynamic pressure `q` (Pa), at
    /// `altitude`, with the vehicle moving through the air at `alpha` from
    /// +x, the crossflow `phi` round from +z towards +y.
    func loads(_ model: AerodynamicModel, mach: Double, q: Double, altitude: Double, alpha: Double = 0,
               phi: Double = 0, powered: Bool = true, cpX: @escaping (Double) -> Double = { $0 },
               planform: (area: Double, x: Double) = (1, 0)) -> AerodynamicModel.Loads {
        var state = AS506.launchDayAtmosphere().state(altitude: altitude)
        let speed = mach * state.speedOfSound
        state.density = 2 * q / (speed * speed)
        let u = Vec3(speed * cos(alpha), speed * sin(alpha) * sin(phi), speed * sin(alpha) * cos(phi))
        return model.loads(air: u, atmosphere: state, altitude: altitude, powered: powered, centerOfPressureX: cpX,
                           planform: planform)
    }

    // The tables carry their sources' values: D5-15796-1 Fig 2-8's forebody
    // peak (0.562 at M 1.22-1.25) and subsonic plateau (0.141); Fig 2-7's
    // AS-503 base differential (-3.60 kPa near 6 km, zero at 9.6 km, +4.15
    // kPa at 17 km); REF504 Fig 3-3's C_Nα peak (0.1000 per degree at M
    // 0.98) and Fig 3-4's centre of pressure (2.795 calibers at M 0.95,
    // 4.453 at M 3); the 396 in reference diameter.
    func testTablesCarryTheirSources() {
        XCTAssertEqual(AS506.forebodyAxialCoefficient(1.25), 0.562, accuracy: 1e-9)
        XCTAssertEqual(AS506.forebodyAxialCoefficient(0.2), 0.141, accuracy: 1e-9)
        XCTAssertEqual(AS506.baseDifferential(5_900), -3_600, accuracy: 1e-9)
        XCTAssertEqual(AS506.baseDifferential(9_600), 0, accuracy: 1e-9)
        XCTAssertEqual(AS506.baseDifferential(17_000), 4_150, accuracy: 1e-9)
        XCTAssertEqual(AS506.normalForceSlopePerDegree(0.98), 0.1000, accuracy: 1e-9)
        XCTAssertEqual(AS506.centerOfPressureCalibers(0.95), 2.795, accuracy: 1e-9)
        XCTAssertEqual(AS506.centerOfPressureCalibers(3.0), 4.453, accuracy: 1e-9)
        XCTAssertEqual(fullStack.referenceDiameter, 10.0584, accuracy: 1e-4)
        XCTAssertEqual(fullStack.referenceArea, 79.46, accuracy: 0.01)
        XCTAssertEqual(fullStack.normalForceSlope(0.98), 0.1 / deg, accuracy: 1e-9)
    }

    // The flight-evaluation axial force, F_A = C_Af q S - 0.798 (P_b - P∞) S,
    // along AS-506's trajectory (h, M and q from the PFT; D5-15796-1's
    // method, worked through in the research notes): 207 kN at 40 s, 596 kN
    // at 60 s, the 1,362 kN peak at 75 s, 1,111 kN at max Q (83 s) and 828
    // kN at 90 s, within 1.5 %. Below about 10 km the base is under ambient
    // pressure (drag); above it the plume pressurises it (thrust).
    func testAxialForceAlongTheAS506Trajectory() {
        for (h, mach, q, fa) in [(2_360.0, 0.40, 8_860.0, 207e3), (6_150, 0.80, 22_900, 596e3),
                                 (10_600, 1.30, 32_520, 1_362e3), (13_570, 1.69, 35_200, 1_111e3),
                                 (16_520, 2.08, 32_410, 828e3)] {
            let l = loads(fullStack, mach: mach, q: q, altitude: h)
            XCTAssertEqual(-l.force.x, fa, accuracy: fa * 0.015, "\(h) m")
            XCTAssertEqual(l.force.y, 0)
            XCTAssertEqual(l.force.z, 0)
            XCTAssertEqual(l.torque.length, 0)
        }
        // Base: drag below 9.6 km, thrust above, nothing with no air.
        let s = fullStack.referenceArea
        let low = loads(fullStack, mach: 0.8, q: 22_900, altitude: 5_900)
        let high = loads(fullStack, mach: 2.1, q: 32_000, altitude: 17_000)
        XCTAssertEqual(-low.force.x - AS506.forebodyAxialCoefficient(0.8) * 22_900 * s, 0.798 * 3_600 * s, accuracy: 1)
        XCTAssertEqual(-high.force.x - AS506.forebodyAxialCoefficient(2.1) * 32_000 * s, -0.798 * 4_150 * s,
                       accuracy: 1)
        // With the F-1s off the base drags with the wind-tunnel coefficient.
        let off = loads(fullStack, mach: 2.0, q: 30_000, altitude: 17_000, powered: false)
        XCTAssertEqual(-off.force.x,
                       (AS506.forebodyAxialCoefficient(2.0) + AS506.unpoweredBaseCoefficient(2.0)) * 30_000 * s,
                       accuracy: 1)
    }

    // The normal force opposes the crossflow, C_Nα sin α cos α q S at small
    // angles, and acts at the centre of pressure: forward of the centre of
    // mass, its moment turns the nose further from the airflow (the Saturn V
    // is aerodynamically unstable; REF504 Fig 3-4 against Fig 3-15), in
    // pitch, in yaw and between them. Beyond the linear range the viscous
    // crossflow adds η C_dc A_p (sin²α - sin²α₀) q; broadside it is all
    // there is. (The checks take η C_dc and α₀ from the data: they test the
    // mechanism, not those generic values.)
    func testNormalForceAndMoment() {
        let q = 30_000.0, mach = 1.5, alpha = 2 * deg, s = fullStack.referenceArea
        // CP 20 m ahead of the CoM, the planform centroid 5 m ahead.
        let l = loads(fullStack, mach: mach, q: q, altitude: 12_000, alpha: alpha, cpX: { _ in 20 },
                      planform: (900, 5))
        let n = fullStack.normalForceSlope(mach) * sin(alpha) * cos(alpha) * q * s
        XCTAssertEqual(l.force.z, -n, accuracy: n * 1e-12)
        XCTAssertEqual(l.force.y, 0)
        XCTAssertEqual(l.angleOfAttack, alpha, accuracy: 1e-12)
        // The vehicle moves towards +z through the air. The torque about +y,
        // -x_cp F_z > 0, turns the nose towards -z, away from that motion: α
        // grows (the unstable sense).
        XCTAssertEqual(l.torque.y, 20 * n, accuracy: n * 1e-9)
        XCTAssertEqual(l.torque.x, 0)
        XCTAssertEqual(l.torque.z, 0)
        // Sideslip: moving towards +y, the force is -y and the torque about
        // z, x_cp F_y < 0, turns the nose towards -y, away from the motion.
        let side = loads(fullStack, mach: mach, q: q, altitude: 12_000, alpha: alpha, phi: 90 * deg,
                         cpX: { _ in 20 }, planform: (900, 5))
        XCTAssertEqual(side.force.y, -n, accuracy: n * 1e-12)
        XCTAssertEqual(side.force.z, 0, accuracy: n * 1e-12)
        XCTAssertEqual(side.torque.z, -20 * n, accuracy: n * 1e-9)
        XCTAssertEqual(side.torque.y, 0, accuracy: n * 1e-9)
        // Between them, the force against the crossflow and its moment.
        let oblique = loads(fullStack, mach: mach, q: q, altitude: 12_000, alpha: alpha, phi: 45 * deg,
                            cpX: { _ in 20 }, planform: (900, 5))
        XCTAssertEqual(oblique.force.y, -n * sin(45 * deg), accuracy: n * 1e-12)
        XCTAssertEqual(oblique.force.z, -n * cos(45 * deg), accuracy: n * 1e-12)
        XCTAssertEqual((oblique.torque - Vec3(0, -20 * oblique.force.z, 20 * oblique.force.y)).length, 0,
                       accuracy: n * 1e-9)
        // Large angle: the crossflow term at the planform centroid, in pitch
        // and in yaw.
        let (k, a0) = (AS506.crossflow.coefficient, AS506.crossflow.linearAngle)
        let linear = fullStack.normalForceSlope(0.5) * sin(30 * deg) * cos(30 * deg) * 2_000 * s
        let viscous = k * 900 * (pow(sin(30 * deg), 2) - pow(sin(a0), 2)) * 2_000
        for phi in [0.0, 90 * deg] {
            let wide = loads(fullStack, mach: 0.5, q: 2_000, altitude: 3_000, alpha: 30 * deg, phi: phi,
                             cpX: { _ in 20 }, planform: (900, 5))
            let along = phi == 0 ? -wide.force.z : -wide.force.y
            let turning = phi == 0 ? wide.torque.y : -wide.torque.z
            XCTAssertEqual(along, linear + viscous, accuracy: 1e-6 * (linear + viscous))
            XCTAssertEqual(turning, 20 * linear + 5 * viscous, accuracy: 1e-6 * (20 * linear))
        }
        let broadside = loads(fullStack, mach: 0.3, q: 1_000, altitude: 1_000, alpha: 90 * deg, planform: (900, 5))
        XCTAssertEqual(-broadside.force.z, k * 900 * (1 - pow(sin(a0), 2)) * 1_000, accuracy: 1e-3)
        XCTAssertEqual(broadside.force.x, 0.798 * AS506.baseDifferential(1_000) * s, accuracy: 1e-6)   // base only
    }

    // The configuration follows the parts aboard: the full stack until the
    // S-IC goes, then the S-II's (REF504's S-II flight configuration), then
    // the S-IVB's free-molecular drag; a jettisoned S-IC flies the generic
    // drag. The centre of pressure sits at its station: REF504 Fig 3-4's
    // 3.50 calibers forward of STA 100 at liftoff, 37.74 m above STA 0,
    // which is 7.5 m (0.75 caliber) ahead of the stack's centre of mass.
    func testConfigurationsAndCentreOfPressure() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo11OnPad(in: sim)
        XCTAssertEqual(v.activeAerodynamics?.name, "Apollo/Saturn V, S-IC flight configuration")
        let cp = v.centerOfPressureX(fullStack)(3.50) - v.structureOrigin.x
        XCTAssertEqual(cp, (100 + 3.50 * 396) * 0.0254, accuracy: 1e-9)
        XCTAssertEqual(v.centerOfPressureX(fullStack)(3.50) / fullStack.referenceDiameter, 0.75, accuracy: 0.1)
        let s1 = try XCTUnwrap(v.separate(parts: [v.parts[0]], name: "S-IC"))
        XCTAssertNil(s1.activeAerodynamics)
        XCTAssertEqual(v.activeAerodynamics?.name, "Apollo/Saturn V, S-II flight configuration")
        _ = v.separate(parts: v.parts.filter { $0.name.hasPrefix("S-II") || $0.name.hasPrefix("S-IC") }, name: "S-II")
        XCTAssertEqual(v.activeAerodynamics?.name, "S-IVB stage, free-molecular flow")
    }

    // The launch-day atmosphere: PRA-63 times the FER's deviations. At the
    // surface 101,905 Pa and 302.0 K against the 102,030 Pa and 302.6 K
    // measured at launch (FER Table A-1); at AS-506's max-Q state (13.567
    // km, 500.7 m/s through the air) q = 35.16 kPa against Table 4-1's
    // 35.2 kPa; 15 % denser than US-1976 there. The wind peaks near 11.3 km
    // at 9.4 m/s from 297° (Table A-4: 9.6 m/s from 297° at 11.40 km).
    // Above the 56 km sounding the day's ratios fade into US-1976 by 66 km.
    func testLaunchDayAtmosphere() {
        let day = AS506.launchDayAtmosphere(), standard = USStandardAtmosphere1976()
        let surface = day.state(altitude: 0)
        XCTAssertEqual(surface.pressure, 102_030, accuracy: 200)
        XCTAssertEqual(surface.temperature, 302.6, accuracy: 0.7)
        let maxQ = day.state(altitude: 13_567)
        XCTAssertEqual(0.5 * maxQ.density * 500.7 * 500.7, 35_200, accuracy: 100)
        XCTAssertEqual(maxQ.density / standard.state(altitude: 13_567).density, 1.15, accuracy: 0.01)
        let w = day.wind(altitude: 11_300)
        XCTAssertEqual((w.east * w.east + w.north * w.north).squareRoot(), 9.6, accuracy: 0.3)
        var from = atan2(-w.east, -w.north) / deg
        if from < 0 { from += 360 }
        XCTAssertEqual(from, 297, accuracy: 3)
        // The fade above the sounding (its length is the model's own choice).
        let top = 56_000.0, end = top + day.blend
        XCTAssertEqual(day.state(altitude: end), standard.state(altitude: end))
        XCTAssertEqual(day.wind(altitude: end).east, 0)
        let mid = day.state(altitude: top + day.blend / 2).density / standard.state(altitude: top + day.blend / 2).density
        let atTop = day.state(altitude: top).density / standard.state(altitude: top).density
        XCTAssertEqual(mid, 1 + (atTop - 1) / 2, accuracy: 1e-9)
    }

    // The S-IVB's free-molecular drag (REF504 §3.1): C_D 2.8024 on 33.47 m²
    // along the relative wind at any attitude, no lift and no moment.
    func testSIVBDragAlongTheWind() {
        let model = AS506.aerodynamics[2]
        for alpha in [0.0, 45 * deg, 90 * deg] {
            let l = loads(model, mach: 25, q: 0.01, altitude: 185_000, alpha: alpha, phi: 30 * deg)
            let u = Vec3(cos(alpha), sin(alpha) * sin(30 * deg), sin(alpha) * cos(30 * deg))
            XCTAssertEqual((l.force + u * (2.8024 * 0.01 * 33.47)).length, 0, accuracy: 1e-12, "\(alpha)")
            XCTAssertEqual(l.torque, .zero)
        }
    }

    // The simulation applies the loads: one 0.02 s step of the unpowered
    // stack at 12 km, 500 m/s through still air at 2° in pitch, in yaw and
    // between them. The body rate it gains is I⁻¹ τ h for the model's moment,
    // and its velocity change differs from the same step with the generic
    // drag by the normal and axial forces' share, within 2 %; without the
    // model it gains no rate.
    func testSimulationAppliesTheLoads() throws {
        for phi in [0.0, 90.0, 45.0] {
            func step(aero: Bool) throws -> (v: Vessel, dv: Vec3, torque: Vec3, acceleration: Vec3) {
                let sim = try Simulation.forTests(perturbations: false)
                let v = VesselLibrary.saturnV()
                if !aero { v.aerodynamics = [] }
                sim.add(v)
                sim.placeInCircularOrbit(v, around: sim.system.earth, altitude: 12_000)
                let a = 2 * deg, p = phi * deg
                let u = Vec3(cos(a), sin(a) * sin(p), sin(a) * cos(p)) * 500
                let omega = sim.snapshot.orientation(sim.system.earth).angularVelocity
                v.velocity = v.attitude.rotate(u) + omega.cross(v.position)
                sim.updateTelemetry(v, snapshot: sim.snapshot)
                XCTAssertEqual(v.angleOfAttack, a, accuracy: 1e-9)
                var torque = Vec3.zero, acceleration = Vec3.zero
                if let model = v.activeAerodynamics {
                    let l = model.loads(air: u, atmosphere: v.atmosphere, altitude: v.altitude, powered: false,
                                        centerOfPressureX: v.centerOfPressureX(model), planform: v.planform)
                    torque = l.torque
                    acceleration = v.attitude.rotate(l.force) / v.mass
                }
                let v0 = v.velocity
                sim.tick()
                return (v, v.velocity - v0, torque, acceleration)
            }
            let on = try step(aero: true), off = try step(aero: false)
            let h = 0.02, w = on.v.inertia.inverse * on.torque * h
            XCTAssertGreaterThan(on.torque.length, 1e6)
            XCTAssertEqual((on.v.angularVelocity - w).length, 0, accuracy: 0.02 * w.length, "\(phi)")
            XCTAssertEqual(off.v.angularVelocity.length, 0, accuracy: 1e-12)
            let air = on.v.attitude.rotate(Vec3(cos(2 * deg), sin(2 * deg) * sin(phi * deg),
                                                sin(2 * deg) * cos(phi * deg)) * 500)
            let generic = air * (-0.5 * on.v.atmosphere.density * air.length * off.v.dragArea / off.v.mass)
            let expected = (on.acceleration - generic) * h
            XCTAssertEqual((on.dv - off.dv - expected).length, 0, accuracy: 0.02 * expected.length, "\(phi)")
        }
    }
}
