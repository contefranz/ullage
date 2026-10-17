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
    /// `altitude`, with the air at `alpha` in the pitch plane (from below).
    func loads(_ model: AerodynamicModel, mach: Double, q: Double, altitude: Double, alpha: Double = 0,
               powered: Bool = true, cpX: @escaping (Double) -> Double = { $0 }, planform: (area: Double, x: Double) = (1, 0))
        -> AerodynamicModel.Loads {
        var state = AS506.launchDayAtmosphere().state(altitude: altitude)
        let speed = mach * state.speedOfSound
        state.density = 2 * q / (speed * speed)
        // The vehicle moves along +x and towards +z relative to the air.
        let u = Vec3(speed * cos(alpha), 0, speed * sin(alpha))
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
        XCTAssertEqual(-off.force.x, (AS506.forebodyAxialCoefficient(2.0) + 0.28) * 30_000 * s, accuracy: 1)
    }

    // The normal force opposes the crossflow, C_Nα sin α cos α q S at small
    // angles, and acts at the centre of pressure: forward of the centre of
    // mass, its moment turns the nose further from the airflow (the Saturn V
    // is aerodynamically unstable; REF504 Fig 3-4 against Fig 3-15). Beyond
    // 4° the viscous crossflow adds η C_dc A_p (sin²α - sin²4°) q; broadside
    // it is all there is.
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
        // Large angle: the crossflow term at the planform centroid.
        let wide = loads(fullStack, mach: 0.5, q: 2_000, altitude: 3_000, alpha: 30 * deg, cpX: { _ in 20 },
                         planform: (900, 5))
        let linear = fullStack.normalForceSlope(0.5) * sin(30 * deg) * cos(30 * deg) * 2_000 * s
        let viscous = 0.8 * 900 * (pow(sin(30 * deg), 2) - pow(sin(4 * deg), 2)) * 2_000
        XCTAssertEqual(-wide.force.z, linear + viscous, accuracy: 1e-6 * (linear + viscous))
        XCTAssertEqual(wide.torque.y, 20 * linear + 5 * viscous, accuracy: 1e-6 * (20 * linear))
        let broadside = loads(fullStack, mach: 0.3, q: 1_000, altitude: 1_000, alpha: 90 * deg, planform: (900, 5))
        XCTAssertEqual(-broadside.force.z, 0.8 * 900 * (1 - pow(sin(4 * deg), 2)) * 1_000, accuracy: 1e-3)
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
        XCTAssertEqual(day.state(altitude: 66_000), standard.state(altitude: 66_000))
        XCTAssertEqual(day.wind(altitude: 66_000).east, 0)
        let mid = day.state(altitude: 61_000).density / standard.state(altitude: 61_000).density
        let top = day.state(altitude: 56_000).density / standard.state(altitude: 56_000).density
        XCTAssertEqual(mid, 1 + (top - 1) / 2, accuracy: 1e-9)
    }
}
