import XCTest
@testable import OrbitCore

/// A command module for the aerodynamics: one part, its mass at `center`
/// (Apollo station and offsets, in), built in Apollo axes, with the Apollo
/// CM model (`calibration`). Inertia is Apollo 7's at entry interface
/// (Mission Report Table A.5-I row 20, products left out).
func testCommandModule(center: (xa: Double, ya: Double, za: Double) = (1040.58, -0.11, 5.91),
                       calibration: CapsuleAerodynamics.Calibration = .flightConsistent) -> Vessel {
    let com = ApolloAxes.construction(xa: center.xa, ya: center.ya, za: center.za)
    let cm = VesselPart(name: "CM", dryMass: 5_604.6, offset: ApolloAxes.construction(xa: 1060), length: 3.5,
                        radius: 1.9558, dryCenterOfMass: com - ApolloAxes.construction(xa: 1060),
                        dryInertia: .diagonal(Vec3(7_857.0, 7_061.1, 6_432.0)), staging: .fixed)
    let v = Vessel(name: "CM", parts: [cm], reference: VesselLibrary.placeholderBody)
    v.aerodynamics = [.apolloCommandModule(calibration: calibration)]
    return v
}

final class CapsuleAerodynamicsTests: XCTestCase {
    let table = CapsuleAerodynamics.apollo7TrimTable

    /// Air at Mach `mach` with a dynamic pressure of 10 kPa.
    func air(mach: Double) -> (state: AtmosphereState, speed: Double) {
        let a = 300.0, speed = mach * a
        return (AtmosphereState(temperature: 224, pressure: 1, density: 20_000 / (speed * speed), speedOfSound: a), speed)
    }

    /// The vessel's velocity relative to the air at α, heat shield first,
    /// its crossflow towards body direction `side` (unit, across the axis).
    func velocity(alpha: Double, speed: Double, side: Vec3) -> Vec3 {
        (Vec3.unitX * cos(alpha) + side * sin(alpha)) * speed
    }

    /// The data in the model are tools/data's transcription of 68-FM-184
    /// Table I(a), row for row.
    func testTrimTableIsTheTranscription() throws {
        let rows = try toolsData("68fm184_table1a_cm_trim.csv")
        XCTAssertEqual(rows.count, table.count)
        for (row, point) in zip(rows, table) {
            XCTAssertEqual(point.mach, row.number("mach")!)
            XCTAssertEqual(point.lift, row.number("c_l")!)
            XCTAssertEqual(point.drag, row.number("c_d")!)
            XCTAssertEqual(point.angleOfAttack * 180 / .pi, row.number("alpha_deg")!, accuracy: 1e-12)
        }
    }

    /// Every row of Table I(a), through `AerodynamicModel.loads` on a CM
    /// built in Apollo axes with its centre of mass at the table's (X 1040.58,
    /// Y -0.11, Z 5.91 in): at the row's α the pitching moment vanishes, and
    /// the lift and drag are the table's to 1e-9. The crossflow is put on the
    /// side the centre of mass is (+Z_A, construction -z, slightly -Y_A), so
    /// this also pins where the lift points: towards +Z_A, the crew's feet.
    func testEveryRowTrimsAtItsTableCentreOfMass() {
        for calibration in [CapsuleAerodynamics.Calibration.operational, .flightConsistent] {
            let v = testCommandModule(calibration: calibration)
            let model = v.activeAerodynamics!
            let side = ApolloAxes.direction(xa: 0, ya: -0.11, za: 5.91).normalized
            XCTAssertLessThan(side.z, -0.99)   // +Z_A is construction -z
            for row in table where calibration == .operational || row.mach <= 10 {
                let (atm, speed) = air(mach: row.mach)
                let u = velocity(alpha: row.angleOfAttack, speed: speed, side: side)
                let l = model.loads(air: u, atmosphere: atm, altitude: 0, powered: false, centerOfPressureX: { $0 },
                                    planform: (0, 0))
                let qs = 0.5 * atm.density * speed * speed * CapsuleAerodynamics.apolloReferenceArea
                let back = -u.normalized
                let drag = l.force.dot(back), liftVector = l.force - back * drag
                XCTAssertEqual(drag / qs, row.drag, accuracy: 1e-9, "C_D at Mach \(row.mach)")
                XCTAssertEqual(liftVector.length / qs, row.lift, accuracy: 1e-9, "C_L at Mach \(row.mach)")
                // Across the axis the lift points at the centre of mass's side.
                let across = Vec3(0, liftVector.y, liftVector.z).normalized
                XCTAssertGreaterThan(across.dot(side), 1 - 1e-9, "lift towards +Z_A at Mach \(row.mach)")
                XCTAssertLessThan(across.z, -0.99, "lift on construction -z at Mach \(row.mach)")
                XCTAssertEqual(l.torque.length / (qs * CapsuleAerodynamics.apolloReferenceDiameter), 0, accuracy: 1e-9,
                               "moment at trim, Mach \(row.mach)")
                XCTAssertEqual(l.angleOfAttack, row.angleOfAttack, accuracy: 1e-12)
            }
        }
    }

    /// Trim is statically stable at every Mach row: the pitching moment
    /// about the centre of mass falls through zero (Cmα < 0) at the row's α.
    func testStaticallyStableAtTrim() {
        let v = testCommandModule(calibration: .operational)
        let model = v.activeAerodynamics!
        let side = ApolloAxes.direction(xa: 0, ya: -0.11, za: 5.91).normalized
        let axis = Vec3.unitX.cross(side)   // a positive moment about it raises α'
        let d = 0.5 * Double.pi / 180
        for row in table {
            let (atm, speed) = air(mach: row.mach)
            func cm(_ alpha: Double) -> Double {
                let l = model.loads(air: velocity(alpha: alpha, speed: speed, side: side), atmosphere: atm, altitude: 0,
                                    powered: false, centerOfPressureX: { $0 }, planform: (0, 0))
                return l.torque.dot(axis) / (10_000 * CapsuleAerodynamics.apolloReferenceArea
                                             * CapsuleAerodynamics.apolloReferenceDiameter)
            }
            // α' = π - α: a larger α is a smaller α'.
            let slope = (cm(row.angleOfAttack - d) - cm(row.angleOfAttack + d)) / (2 * d)
            XCTAssertLessThan(slope, -0.05, "Cmα (per rad) at Mach \(row.mach)")
            XCTAssertGreaterThan(slope, -0.3, "Cmα (per rad) at Mach \(row.mach)")
        }
    }

    /// DeRose's free-flight trim (TN D-5276, Mach 10-29, x/d 0.270): z/d
    /// 0.046 trims at 151° and L/D 0.435, z/d 0.028 at 162° and 0.255
    /// (±1° and ±0.025 measured; ±1.5° and ±0.02 here); 0.0015 of z/d moves
    /// trim about 1°. Flight-consistent, so the same at every Mach above 10.
    func testDeRoseOffsetCentreOfMass() {
        let capsule = CapsuleAerodynamics.apolloCommandModule()
        let d = 154.0
        func centre(_ z: Double) -> Vec3 { ApolloAxes.construction(xa: 1000 + 0.270 * d, za: z * d) }
        for mach in [10.0, 18, 29] {
            let high = capsule.trim(mach: mach, centerOfMass: centre(0.046))!
            XCTAssertEqual(180 - high.alphaPrime * 180 / .pi, 151, accuracy: 1.5, "z/d 0.046 at Mach \(mach)")
            XCTAssertEqual(high.liftToDrag, 0.435, accuracy: 0.02)
            let low = capsule.trim(mach: mach, centerOfMass: centre(0.028))!
            XCTAssertEqual(180 - low.alphaPrime * 180 / .pi, 162, accuracy: 1.5, "z/d 0.028 at Mach \(mach)")
            XCTAssertEqual(low.liftToDrag, 0.255, accuracy: 0.02)
            let step = capsule.trim(mach: mach, centerOfMass: centre(0.0475))!
            XCTAssertEqual((step.alphaPrime - high.alphaPrime) * 180 / .pi, 1, accuracy: 0.25, "Δz/d 0.0015")
        }
        // The operational calibration is the same to Mach 10 and flies the
        // table's Mach 29.5 row above it.
        let tunnel = CapsuleAerodynamics.apolloCommandModule(calibration: .operational)
        for mach in [2.0, 6, 10] {
            XCTAssertEqual(tunnel.trim(mach: mach, centerOfMass: centre(0.046))!.alphaPrime,
                           capsule.trim(mach: mach, centerOfMass: centre(0.046))!.alphaPrime, accuracy: 1e-12)
        }
        let row29 = tunnel.trim(mach: 29.5, centerOfMass: CapsuleAerodynamics.apollo7TrimCenterOfMass)!
        XCTAssertEqual(180 - row29.alphaPrime * 180 / .pi, 160.37, accuracy: 1e-6)
    }

    /// Apollo 4's flight (TN D-5399, Table II's centres of mass: X 1039.58
    /// and Z 6.57 in at entry, Mach 25.6; X 1039.72, Z 6.45 in at Mach 6):
    /// the resultant trim was about 154.5° and L/D 0.368 at initial entry,
    /// 153° and 0.41 at Mach 6. The model, calibrated on Apollo 7's tunnel
    /// table, holds 154.8°/0.383 at both: within 1° and 0.02 at entry, and
    /// 1.8° and 0.025 high at Mach 6, where the flight's trim drifted lower
    /// than the tunnel tables' does (datasheet §2.4).
    func testApollo4Flight() {
        let capsule = CapsuleAerodynamics.apolloCommandModule()
        let entry = capsule.trim(mach: 25.6, centerOfMass: ApolloAxes.construction(xa: 1039.58, za: 6.57))!
        XCTAssertEqual(180 - entry.alphaPrime * 180 / .pi, 154.5, accuracy: 1)
        XCTAssertEqual(entry.liftToDrag, 0.368, accuracy: 0.02)
        let mach6 = capsule.trim(mach: 6, centerOfMass: ApolloAxes.construction(xa: 1039.72, za: 6.45))!
        XCTAssertEqual(180 - mach6.alphaPrime * 180 / .pi, 153, accuracy: 2)
        XCTAssertEqual(mach6.liftToDrag, 0.41, accuracy: 0.03)
    }

    /// The Newtonian integrator on a bare spherical cap of half-angle θc,
    /// flow along the axis: C_A = C_p,max (1 + cos² θc) / 2 on the cap's
    /// base area (the closed form), with no normal force or moment; and the
    /// Apollo mould line's apex-forward trim, which a real CM has too.
    func testNewtonianLimit() {
        let radius = 4.6939, thetaC = 23.0 * Double.pi / 180
        let cap = (0...200).map { i -> (x: Double, r: Double) in
            let phi = thetaC * Double(i) / 200
            return (radius * (1 - cos(phi)), radius * sin(phi))
        }
        let base = Double.pi * pow(radius * sin(thetaC), 2)
        let n = NewtonianCoefficients(profile: cap, referenceStation: 0, area: base, diameter: 1)
        let c = n.coefficients(0)
        XCTAssertEqual(c.axial, 1.839 * (1 + cos(thetaC) * cos(thetaC)) / 2, accuracy: 1e-4)
        XCTAssertEqual(c.normal, 0, accuracy: 1e-12)
        XCTAssertEqual(c.moment, 0, accuracy: 1e-12)

        // Newtonian theory alone, on the CM's mould line at the table's centre
        // of mass, trims where the hypersonic tunnel does: Table I(a)'s Mach 10
        // row, α' 22.91° and L/D 0.345 (within 1° and 0.02).
        var newtonianOnly = CapsuleAerodynamics.apolloCommandModule()
        newtonianOnly.newtonianBlend = (start: -2, end: -1)
        let hypersonic = newtonianOnly.trim(mach: 10, centerOfMass: CapsuleAerodynamics.apollo7TrimCenterOfMass,
                                            bracket: 1e-6...(Double.pi / 2))!
        XCTAssertEqual(hypersonic.alphaPrime * 180 / .pi, 22.91, accuracy: 1)
        XCTAssertEqual(hypersonic.liftToDrag, 0.345, accuracy: 0.02)

        // Apex forward (α' past 90°) the full model trims stably again.
        let v = testCommandModule()
        let model = v.activeAerodynamics!
        let side = ApolloAxes.direction(xa: 0, ya: -0.11, za: 5.91).normalized, axis = Vec3.unitX.cross(side)
        let (atm, speed) = air(mach: 10)
        func moment(_ alphaPrime: Double) -> Double {
            model.loads(air: velocity(alpha: .pi - alphaPrime, speed: speed, side: side), atmosphere: atm, altitude: 0,
                        powered: false, centerOfPressureX: { $0 }, planform: (0, 0)).torque.dot(axis)
        }
        var crossings: [Double] = []
        for i in 1..<179 {
            let a0 = Double(i) * Double.pi / 180, a1 = a0 + Double.pi / 180
            if moment(a0) > 0 && moment(a1) <= 0 { crossings.append(a0 * 180 / .pi) }
        }
        XCTAssertEqual(crossings.count, 2, "stable trims at α' \(crossings)")
        XCTAssertEqual(crossings.first ?? 0, 22.9, accuracy: 1)
        XCTAssertGreaterThan(crossings.last ?? 0, 120)
    }

    /// The lift side comes from the centre of mass: put it on the other side
    /// of the axis (-Z_A) and the trim, the lift and the moment follow it.
    func testLiftFollowsTheCentreOfMass() {
        for (ya, za) in [(-0.11, 5.91), (0.11, -5.91)] {
            let v = testCommandModule(center: (1040.58, ya, za))
            let model = v.activeAerodynamics!
            let side = ApolloAxes.direction(xa: 0, ya: ya, za: za).normalized
            let row = table[12]   // Mach 10
            let (atm, speed) = air(mach: row.mach)
            let u = velocity(alpha: row.angleOfAttack, speed: speed, side: side)
            let l = model.loads(air: u, atmosphere: atm, altitude: 0, powered: false, centerOfPressureX: { $0 },
                                planform: (0, 0))
            let back = -u.normalized, lift = l.force - back * l.force.dot(back)
            XCTAssertGreaterThan(Vec3(0, lift.y, lift.z).normalized.dot(side), 1 - 1e-9)
            XCTAssertEqual(l.torque.length, 0, accuracy: 1e-6 * l.force.length)
            // On the wrong side the moment turns the capsule towards trim.
            let wrong = velocity(alpha: row.angleOfAttack, speed: speed, side: -side)
            let lw = model.loads(air: wrong, atmosphere: atm, altitude: 0, powered: false, centerOfPressureX: { $0 },
                                 planform: (0, 0))
            XCTAssertGreaterThan(lw.torque.length, 0.01 * l.force.length)
        }
    }
}
