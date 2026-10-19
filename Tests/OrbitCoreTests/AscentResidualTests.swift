import XCTest
@testable import OrbitCore

/// The harness for the ascent residuals against AS-506 as flown
/// (`AS506Postflight`; datasheet §14): the data reduction, which the tests
/// below check for self-consistency, and the model's residuals, which they
/// print without asserting (the WGS-84 pad and the residual closure will
/// move them).
///
/// - Sensed velocity by stage window, as a vector (FER Table 10-1's measure)
///   and as the integral of |a_ng|.
/// - The model's state, thrust direction and attitude error against AS-506's.
/// - Stage injection: AS-506's postflight state put in place of the model's
///   at the model's own T3 and T4, so that the S-II and the S-IVB are each
///   judged from AS-506's state.
final class AscentResidualTests: XCTestCase {
    typealias P = AS506Postflight
    let deg = Double.pi / 180

    // MARK: The data

    // Table B-II as transcribed: every row, 1 s apart from -16 s to 162 s, 2 s
    // apart from 164 s to 708 s, and the 13 event rows between them.
    func testTableB2HasEveryRow() {
        let t = P.trajectory.map(\.time)
        XCTAssertEqual(t.count, 464)
        XCTAssertTrue(zip(t, t.dropFirst()).allSatisfy { $0 < $1 })
        let grid = Set((-16...162).map(Double.init) + stride(from: 164.0, through: 708, by: 2) + [549])
        let events = P.trajectory.filter { $0.event != nil }
        XCTAssertEqual(Set(t.filter { $0 == $0.rounded() }), grid)
        XCTAssertEqual(events.map(\.time), [-16.968, 0.3, 0.6, 66.3, 83.0, 135.2, 161.63, 162.3, 460.62, 548.22,
                                            549.0, 699.33, 709.33])
        XCTAssertEqual(P.row(at: P.Event.sICCutoff.time)?.event, "S-IC OUTBOARD ENGINE CUTOFF (ENGINE SOLENOID)")
        XCTAssertEqual(P.row(at: P.Event.sIVBCutoff.time)?.event, "S-IVB 1ST GUIDANCE CUTOFF")
        // The pad: 6,373.355 km from the Earth's centre at the geocentric
        // latitude 28.447° (datasheet §1.6), against the Fischer ellipsoid's
        // normal, the frame's X.
        let pad = P.trajectory[0].position
        XCTAssertEqual(pad.length, 6_373_355, accuracy: 1)
        XCTAssertEqual(asin(pad.normalized.dot(P.pole)) / deg, 28.4470, accuracy: 1e-4)
    }

    // Row against row: each interval's position change against its end
    // velocities and accelerations (Hermite), and its velocity change against
    // the accelerations (trapezoid). The printed table holds within its
    // rounding (1 m, 0.1 m/s) away from the events and the engine starts,
    // apart from XS at 292 s (printed 6,493.891 km, 10 m off its neighbours).
    // At the S-II and S-IVB starts the thrust rises within an interval; at
    // S-II CECO and insertion the event rows sit 105 m and 65 m off the
    // trajectory, as datasheet §14.4 also found.
    func testTableB2IsKinematicallyConsistent() {
        let transients: [ClosedRange<Double>] = [0.3...1, 135.2...137, 161...166, 460...462, 496...500, 548...556,
                                                699.33...700]
        var worst = (position: 0.0, velocity: 0.0)
        for (a, b) in zip(P.trajectory, P.trajectory.dropFirst()) where a.time >= P.firstMotion {
            let h = b.time - a.time
            let dr = b.position - a.position - (a.velocity + b.velocity) * (h / 2)
                - (a.acceleration - b.acceleration) * (h * h / 12)
            let dv = b.velocity - a.velocity - (a.acceleration + b.acceleration) * (h / 2)
            let quiet = a.event == nil && b.event == nil
                && !transients.contains { $0.contains(a.time) || $0.contains(b.time) }
            let maxR = max(abs(dr.x), abs(dr.y), abs(dr.z)), maxV = max(abs(dv.x), abs(dv.y), abs(dv.z))
            if quiet && a.time != 290 && a.time != 292 {
                worst = (max(worst.position, maxR), max(worst.velocity, maxV))
            }
            switch a.time {
            case 290: XCTAssertEqual(dr.x, 9.7, accuracy: 0.1)
            case 460: XCTAssertEqual(dr.z, -105.0, accuracy: 0.2)
            case 708: XCTAssertEqual(dr.x, -65.2, accuracy: 0.2)
            default: break
            }
        }
        XCTAssertLessThan(worst.position, 2.0)
        XCTAssertLessThan(worst.velocity, 0.45)   // 143-144 s: DDZS 0.4 m/s^2 off its neighbours
    }

    // Sensed velocity by stage, AS-506 (datasheet §14.2): the vector sums
    // 3,303.57, 4,583.74 and 880.79 m/s; the pad phase 169.088 m/s along X_S.
    // The integral of |a_ng| from first motion to the guidance cutoff is
    // §14.2's 9,132.67 m/s on the rows §14 had (PR 12's transcription: every
    // row to 162 s, then mostly 10 s apart), and 9,132.83 m/s on every row,
    // the shorter intervals following the thrust's turn closer: 4,659.38
    // and 885.66 m/s in the S-II and S-IVB windows against §14.3's "at least
    // 4,659.25" and 885.63. §14's sub-windows match too (11.98 m/s for the
    // F-1 decay, 161.63-162.30 s; 12.72 m/s to 164 s; 8.07 m/s^2 at 180-190 s).
    func testSensedVelocityByStage() {
        let sIC = P.sensedVelocity(from: P.firstMotion, to: P.Event.sICCutoff.time)
        let sII = P.sensedVelocity(from: P.Event.sICCutoff.time, to: P.Event.sIICutoff.time)
        let sIVB = P.sensedVelocity(from: P.Event.sIICutoff.time, to: P.Event.sIVBCutoff.time)
        XCTAssertEqual(sIC.vector.length, 3_303.57, accuracy: 0.005)
        XCTAssertEqual(sII.vector.length, 4_583.74, accuracy: 0.005)
        XCTAssertEqual(sIVB.vector.length, 880.79, accuracy: 0.005)
        XCTAssertEqual(sIC.integral, 3_587.79, accuracy: 0.005)
        XCTAssertEqual(sII.integral, 4_659.38, accuracy: 0.005)
        XCTAssertEqual(sIVB.integral, 885.66, accuracy: 0.005)
        XCTAssertEqual(sIC.integral + sII.integral + sIVB.integral, 9_132.83, accuracy: 0.005)
        let section14 = P.trajectory.filter { row in row.time <= 162 + 1e-9
            || Self.section14Rows.contains { abs($0 - row.time) < 1e-6 } }
        let sparse = P.increments(of: section14)
        let integral = { (a: Double, b: Double) in
            sparse.filter { $0.start >= a - 1e-9 && $0.end <= b + 1e-9 }.reduce(0) { $0 + $1.sensed.length }
        }
        XCTAssertEqual(integral(P.firstMotion, 161.63), 3_587.79, accuracy: 0.005)
        XCTAssertEqual(integral(161.63, 548.22), 4_659.25, accuracy: 0.005)
        XCTAssertEqual(integral(548.22, 699.33), 885.63, accuracy: 0.005)
        XCTAssertEqual(integral(P.firstMotion, 699.33), 9_132.67, accuracy: 0.005)
        XCTAssertEqual(P.padSensedVelocity.x, 169.088, accuracy: 0.0005)
        XCTAssertEqual(Vec3(0, P.padSensedVelocity.y, P.padSensedVelocity.z).length, 0, accuracy: 0.1)
        XCTAssertEqual(P.sensedVelocity(from: 161.63, to: 162.3).vector.length, 11.98, accuracy: 0.005)
        XCTAssertEqual(P.sensedVelocity(from: 161.63, to: 164).vector.length, 12.72, accuracy: 0.01)
        XCTAssertEqual(P.sensedVelocity(from: 180, to: 190).integral / 10, 8.07, accuracy: 0.005)
        // The pad's own rows say the same: release to first motion, their
        // velocity change less gravity, within their 0.1 m/s rounding.
        let fm = P.row(at: P.firstMotion)!, grr = P.trajectory[0]
        let rows = P.trajectory.filter { $0.time <= P.firstMotion + 1e-9 }
        var g = Vec3.zero
        for (a, b) in zip(rows, rows.dropFirst()) {
            g += (P.gravity(at: a.position) + P.gravity(at: b.position)) * ((b.time - a.time) / 2)
        }
        XCTAssertEqual((fm.velocity - grr.velocity - g - P.padSensedVelocity).length, 0, accuracy: 0.15)
    }

    // The platform's velocity from guidance reference release, the pad phase
    // plus the PFT's sensed velocity, is FER Table 10-1's postflight value at
    // each cutoff within 0.13 m/s per axis (datasheet §14: 0.05, 0.13, 0.13).
    // So PACSS 12, the platform's frame, has PACSS 13's axes, and the S-IC
    // window is Table 10-1's postflight value less the pad: 3,303.54 m/s.
    func testPlatformVelocityIsFERTable10_1() throws {
        var platform = P.padSensedVelocity, start = P.firstMotion
        for e in [P.Event.sICCutoff, .sIICutoff, .sIVBCutoff] {
            platform += P.sensedVelocity(from: start, to: e.time).vector
            start = e.time
            let fer = try XCTUnwrap(P.platformVelocity[e]).postflight
            XCTAssertEqual(platform.x, fer.x, accuracy: 0.13, "\(e)")
            XCTAssertEqual(platform.y, fer.y, accuracy: 0.13, "\(e)")
            XCTAssertEqual(platform.z, fer.z, accuracy: 0.13, "\(e)")
        }
        let sIC = try XCTUnwrap(P.platformVelocity[.sICCutoff]).postflight - P.padSensedVelocity
        XCTAssertEqual(sIC.length, 3_303.54, accuracy: 0.005)
        // The LVDC's own increments, S-II and S-IVB, within 0.6 m/s of the PFT's.
        let lvdc = { (e: P.Event) in P.platformVelocity[e]!.guidance }
        XCTAssertEqual((lvdc(.sIICutoff) - lvdc(.sICCutoff)).length,
                       P.sensedVelocity(from: 161.63, to: 548.22).vector.length, accuracy: 0.6)
        XCTAssertEqual((lvdc(.sIVBCutoff) - lvdc(.sIICutoff)).length,
                       P.sensedVelocity(from: 548.22, to: 699.33).vector.length, accuracy: 0.6)
    }

    // FER Table 10-2's postflight states against the PFT's event rows. The
    // velocities agree within 0.07 m/s per axis at all four events and the positions
    // within 1 m at S-IC OECO and insertion. At S-II OECO and the first
    // S-IVB ECO the table's positions lie 1,432 m behind and 517 m ahead of
    // the rows along the track (the trajectory 0.207 s earlier and 0.066 s
    // later, within 12 m), with the rows' velocities: so the table's flight-
    // path angles there, 0.6075° and 0.0151° (Table 4-2: 0.608° and 0.015°),
    // are 0.012° below and 0.004° above the rows' 0.619° and 0.011°. Each
    // state's radius, speed and flight-path angle match its components (the
    // printed 6,963,309 m apart).
    func testGuidanceComparisonAgainstThePFT() throws {
        let offsets: [(P.Event, Double)] = [(.sICCutoff, 0), (.sIICutoff, -0.207), (.sIVBCutoff, 0.066),
                                            (.insertion, 0)]
        for (e, dt) in offsets {
            let fer = try XCTUnwrap(P.guidanceComparison[e]).postflight
            let row = try XCTUnwrap(P.row(at: e.time))
            let dv = fer.velocity - row.velocity
            XCTAssertLessThan(max(abs(dv.x), abs(dv.y), abs(dv.z)), 0.075, "\(e)")
            let shifted = row.position + row.velocity * dt + (row.acceleration * (dt * dt / 2))
            XCTAssertEqual((fer.position - shifted).length, 0, accuracy: 12.5, "\(e)")
            XCTAssertEqual(flightPathAngle(fer.position, fer.velocity), fer.flightPathAngle, accuracy: 0.0005, "\(e)")
        }
        for e in [P.Event.sICCutoff, .sIICutoff, .sIVBCutoff, .insertion] {
            let c = try XCTUnwrap(P.guidanceComparison[e])
            for (s, isOperationalInsertion) in [(c.guidance, false), (c.postflight, false),
                                                (c.operational, e == .insertion)] {
                XCTAssertEqual(s.position.length, isOperationalInsertion ? s.radius - 400_000 : s.radius,
                               accuracy: 1, "\(e)")
                XCTAssertEqual(s.velocity.length, s.speed, accuracy: 0.01, "\(e)")
            }
        }
        let rowGamma = { (e: P.Event) -> Double in
            let row = P.row(at: e.time)!
            return self.flightPathAngle(row.position, row.velocity)
        }
        XCTAssertEqual(rowGamma(.sIICutoff), 0.6193, accuracy: 0.0005)
        XCTAssertEqual(rowGamma(.sIVBCutoff), 0.0106, accuracy: 0.0005)
    }

    // FER Table 4-2's actual cutoff speeds and angles against the PFT's rows:
    // the speeds within 0.1 m/s, the flight-path angles within 0.002° (S-IC
    // CECO and OECO, S-II CECO; see above for S-II OECO and S-IVB ECO).
    func testCutoffEventsAgainstThePFT() throws {
        for e in [P.Event.sICCenterCutoff, .sICCutoff, .sIICenterCutoff, .sIICutoff, .sIVBCutoff] {
            let fer = try XCTUnwrap(P.cutoffEvents[e]).actual
            let row = try XCTUnwrap(P.row(at: e.time))
            XCTAssertEqual(row.velocity.length, fer.speed, accuracy: 0.1, "\(e)")
            XCTAssertEqual(fer.time, e.time, accuracy: 0.05, "\(e)")
            if [.sICCenterCutoff, .sICCutoff, .sIICenterCutoff].contains(e) {
                XCTAssertEqual(flightPathAngle(row.position, row.velocity), fer.flightPathAngle, accuracy: 0.002,
                               "\(e)")
            }
        }
    }

    // Figure 11-1's measured pitch error against the independent digitisation
    // of datasheet §14 (two dense readings that agreed within 0.03°): its 5 s
    // means average +0.438° over 20-100 s and -0.024° over 105-160 s.
    func testFigure11_1AgainstDatasheetSection14() {
        let means = { (a: Int, b: Int) in stride(from: a, to: b, by: 5).map { P.pitchError(from: $0, to: $0 + 5) } }
        let early = means(20, 100), late = means(105, 160)
        XCTAssertEqual(early.reduce(0, +) / Double(early.count), 0.438, accuracy: 0.03)
        XCTAssertEqual(late.reduce(0, +) / Double(late.count), -0.024, accuracy: 0.03)
        XCTAssertEqual(P.pitchErrorSecondMeans.count, 160)
    }

    // The S-II's thrust in Figure 6-3 against the FER's text (§6.2): 3,082,769
    // N at ESC + 351 s (514.04 s), after the EMR shift at "approximately 335
    // seconds after ESC" (498 s); the mixture ratio steps there too.
    func testFigure6_3AgainstTheFERText() {
        XCTAssertEqual(interpolate(P.sIIThrust.map { ($0.time, $0.thrust) }, at: 514.04), 3.0828, accuracy: 0.006)
        let step = { (s: [(Double, Double)], level: Double) in s.first { $0.1 < level }!.0 }
        XCTAssertEqual(step(P.sIIThrust.map { ($0.time, $0.thrust) }, 3.6), 498, accuracy: 1.5)
        XCTAssertEqual(step(P.sIIMixtureRatio.map { ($0.time, $0.ratio) }, 4.9), 498, accuracy: 1.5)
    }

    // AS-506's pitch program fitted in GE504's form (tools/fit_as506_pitch.py)
    // against its reconstructed command, chi_thr less Figure 11-1's error, on
    // 5 s boxcars from the program start to the arrest, but for those over
    // the centre engine cutoff's transient (134-138 s): rms 0.057°, maximum
    // 0.147°; the segments join exactly, the command holds -68.90° at the
    // arrest and never turns faster than the LVDC's 1°/s. Like §14.1's
    // reconstruction it lies further downrange than SA-504's from 40 to 158 s,
    // by 0.8-1.8° (§14.1: 0.6-1.5°), and is no scale of it: 1.12 times
    // SA-504's at 40 s, 1.01 at 158 s. PR 12's own C0 fit (docs/data/as506/
    // e1-reference, which leaves the hold free) is within 0.06° rms of it.
    func testFittedPitchProgramAgainstTheReconstruction() {
        let fit = P.fittedTiltProgram, sa504 = AS506.tiltProgram
        let t1 = AS506.liftoff
        var residuals: [Double] = []
        for k in 16...157 where k + 3 <= 134 || k - 2 >= 138 {
            let a = Double(k - 2) - t1, b = Double(k + 3) - t1
            let samples = (0...500).map { fit.pitch(at: a + (b - a) * Double($0) / 500) / deg }
            let mean = (samples.reduce(0, +) - (samples[0] + samples[500]) / 2) / 500
            residuals.append(mean - P.reconstructedPitchCommand(from: k - 2, to: k + 3))
        }
        let rms = (residuals.map { $0 * $0 }.reduce(0, +) / Double(residuals.count)).squareRoot()
        XCTAssertEqual(residuals.count, 134)
        XCTAssertEqual(rms, 0.057, accuracy: 0.002)
        XCTAssertLessThan(residuals.map(abs).max()!, 0.15)
        for j in AS506.pitchSegmentBoundaries {
            XCTAssertEqual(fit.pitch(at: j - 1e-9) / deg, fit.pitch(at: j) / deg, accuracy: 1e-6)
        }
        XCTAssertEqual(fit.pitch(at: AS506.tiltArrest) / deg, P.heldPitch, accuracy: 1e-9)
        XCTAssertEqual(fit.pitch(at: 200) / deg, P.heldPitch, accuracy: 1e-9)
        let rates = stride(from: 12.6, to: AS506.tiltArrest - 0.01, by: 0.01).map {
            (fit.pitch(at: $0 + 0.01) - fit.pitch(at: $0)) / 0.01 / deg
        }
        XCTAssertLessThan(rates.map(abs).max()!, 0.75)
        let scaled = sa504.coefficients[0][0] / AS506.pitchCoefficients[0][0]   // the IU's 1.025
        for t in stride(from: 40.0, through: 158, by: 2) {
            let sa = sa504.pitch(at: t - t1) / scaled / deg, as506 = fit.pitch(at: t - t1) / deg
            XCTAssertGreaterThan(sa - as506, 0.75, "\(t) s")
            XCTAssertLessThan(sa - as506, 1.8, "\(t) s")
        }
        XCTAssertEqual(fit.pitch(at: 40 - t1) / (sa504.pitch(at: 40 - t1) / scaled), 1.12, accuracy: 0.01)
        XCTAssertEqual(fit.pitch(at: 158 - t1) / (sa504.pitch(at: 158 - t1) / scaled), 1.01, accuracy: 0.01)
    }

    // The fixtures in AS506PostflightData.swift are tools/data's
    // transcriptions: Table B-II cell for cell, the tables, and the figures'
    // samples and second means.
    func testFixturesAreToolsData() throws {
        let b2 = try csv("pft506_table_b2.csv")
        XCTAssertEqual(b2.count, P.trajectory.count)
        for (r, row) in zip(b2, P.trajectory) {
            let km = { (k: String) in Double(r[k]!)! * 1000 }, x = { (k: String) in Double(r[k]!)! }
            XCTAssertEqual(row.time, x("time"))
            XCTAssertEqual(row.position, Vec3(km("xs_km"), km("ys_km"), km("zs_km")))
            XCTAssertEqual(row.velocity, Vec3(x("dxs"), x("dys"), x("dzs")))
            XCTAssertEqual(row.acceleration, Vec3(x("ddxs"), x("ddys"), x("ddzs")))
            XCTAssertEqual(row.event ?? "", r["event"]!)
        }
        let names: [String: P.Event] = ["S-IC CECO": .sICCenterCutoff, "S-IC OECO": .sICCutoff,
                                        "S-II CECO": .sIICenterCutoff, "S-II OECO": .sIICutoff,
                                        "First S-IVB ECO": .sIVBCutoff, "S-IVB 1st guidance cutoff": .sIVBCutoff,
                                        "Parking Orbit Insertion": .insertion]
        for r in try csv("fer506_table_10_1.csv") {
            let e = try XCTUnwrap(P.platformVelocity[names[r["event"]!]!])
            let v = r["source"] == "guidance" ? e.guidance : r["source"] == "postflight" ? e.postflight : e.operational
            XCTAssertEqual(v, Vec3(Double(r["x_ms"]!)!, Double(r["y_ms"]!)!, Double(r["z_ms"]!)!))
            XCTAssertEqual(Double(r["z_fts"]!)! * AS506.foot, v.z, accuracy: 0.006)   // the table's ft/s
        }
        for r in try csv("fer506_table_10_2.csv") {
            let e = try XCTUnwrap(P.guidanceComparison[names[r["event"]!]!])
            let s = r["source"] == "guidance" ? e.guidance : r["source"] == "postflight" ? e.postflight : e.operational
            let x = { (k: String) in Double(r[k]!)! }
            XCTAssertEqual(s.position, Vec3(x("xs_m"), x("ys_m"), x("zs_m")))
            XCTAssertEqual(s.velocity, Vec3(x("dxs"), x("dys"), x("dzs")))
            XCTAssertEqual([s.radius, s.speed, s.flightPathAngle], [x("r_m"), x("vs"), x("gamma_deg")])
            XCTAssertEqual(x("xs_ft") * AS506.foot, s.position.x, accuracy: 0.7)
            XCTAssertEqual(x("dzs_fts") * AS506.foot, s.velocity.z, accuracy: 0.006)
        }
        for r in try csv("fer506_table_4_2.csv") where r["parameter"] == "space-fixed velocity" {
            let e = try XCTUnwrap(P.cutoffEvents[names[r["event"]!]!])
            XCTAssertEqual([e.actual.speed, e.nominal.speed], [Double(r["actual"]!)!, Double(r["nominal"]!)!])
            XCTAssertEqual(e.actual.speed - e.nominal.speed, Double(r["act_minus_nom"]!)!, accuracy: 0.051)
        }
        let samples = { (name: String) in try self.csv(name).map { (Double($0["time"]!)!, Double($0["value"]!)!) } }
        let thrust = try samples("fer506_fig5_3_sic_thrust.csv")
        let figures: [([(Double, Double)], [(Double, Double)])] = [
            (thrust, P.sICThrust.map { ($0.time, $0.thrust) }),
            (try samples("fer506_fig6_3_sii_thrust.csv"), P.sIIThrust.map { ($0.time, $0.thrust) }),
            (try samples("fer506_fig6_3_sii_emr.csv"), P.sIIMixtureRatio.map { ($0.time, $0.ratio) }),
        ]
        for (data, fixture) in figures {
            XCTAssertEqual(data.count, fixture.count)
            for (s, f) in zip(data, fixture) {
                XCTAssertEqual(s.0, f.0, accuracy: 5e-5)
                XCTAssertEqual(s.1, f.1, accuracy: 5e-5)
            }
        }
        let error = try samples("fer506_fig11_1_pitch_error.csv")
        for (k, mean) in zip(1...160, P.pitchErrorSecondMeans) {
            let n = 200
            let v = (0...n).map { interpolate(error, at: Double(k) + Double($0) / Double(n)) }
            XCTAssertEqual((v.reduce(0, +) - (v[0] + v[n]) / 2) / Double(n), mean, accuracy: 1e-4, "\(k) s")
        }
    }

    // The two earlier readings of PR 12 (docs/data/as506/, from the cloud
    // session behind datasheet §14), as a further, independent check: its
    // Table B-II rows (every row to 162 s, 92 after) agree with these in all
    // 2,349 shared cells but two faded digits that the kinematics settled
    // here (ZS at 88 s and 684 s; it decided a third, DXS at 708 s), and its
    // two dense digitisations of Figure 11-1's error agree with this one
    // within 0.035° on every 5 s mean from 15 to 160 s (0.01° rms).
    func testAgainstPR12Readings() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/data/as506")
        var compared = 0, differ: [String] = []
        for name in ["pft-table-b2/b2-sic-all-rows.txt", "pft-table-b2/b2-oeco-to-insertion-raw.txt"] {
            guard let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) else {
                throw XCTSkip("docs/data/as506/\(name) not found")
            }
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                let f = line.split(separator: " ").compactMap { Double($0) }
                guard f.count >= 10, let row = P.row(at: f[0]) else { continue }
                let mine = [row.position.x / 1000, row.position.y / 1000, row.position.z / 1000,
                            row.velocity.x, row.velocity.y, row.velocity.z,
                            row.acceleration.x, row.acceleration.y, row.acceleration.z]
                for (i, (a, b)) in zip(f[1...9], mine).enumerated() {
                    compared += 1
                    if abs(a - b) > 1e-9 { differ.append("\(f[0]) \(i)") }
                }
            }
        }
        XCTAssertEqual(compared, 2_349)
        XCTAssertEqual(differ, ["88.0 2", "684.0 2"])
        let error = try csv("fer506_fig11_1_pitch_error.csv").map { (Double($0["time"]!)!, Double($0["value"]!)!) }
        for (name, t, v) in [("A/dp_p2.json", "t", "v"), ("B/p2_dp.json", "5", "6")] {
            let data = try Data(contentsOf: root.appendingPathComponent("fer-fig11-1/" + name))
            let points = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
            let trace: [(Double, Double)] = points.compactMap { p in
                if let d = p as? [String: Any], let a = d[t] as? Double, let b = d[v] as? Double { return (a, b) }
                if let l = p as? [Any], let a = l[Int(t)!] as? Double, let b = l[Int(v)!] as? Double { return (a, b) }
                return nil
            }.sorted { $0.0 < $1.0 }
            var worst = 0.0, sum = 0.0, n = 0
            for a in stride(from: 15.0, to: 160, by: 5) {
                let mean = { (s: [(Double, Double)]) -> Double in
                    let x = (0...500).map { self.interpolate(s, at: a + 5 * Double($0) / 500) }
                    return (x.reduce(0, +) - (x[0] + x[500]) / 2) / 500
                }
                let d = mean(error) - mean(trace)
                worst = max(worst, abs(d))
                sum += d * d
                n += 1
            }
            XCTAssertLessThan(worst, 0.035, name)
            XCTAssertLessThan((sum / Double(n)).squareRoot(), 0.012, name)
        }
    }

    // MARK: The model's residuals (printed, not asserted)

    // The default flight against AS-506: states at AS-506's event times,
    // sensed velocity by stage window on the PFT's own interval grid (model
    // minus AS-506), the thrust direction's pitch, and the S-IC attitude
    // error against Figure 11-1. Nothing here is asserted: the WGS-84 pad and
    // the residual closure (datasheet §14.5) will move these numbers.
    func testModelResidualsAgainstThePFT() throws {
        let m = try ModelTrajectory(NominalFlight.shared)
        print("ascent residuals, model - AS-506 (PFT Table B-II), default flight:")
        printStates(m, at: [P.Event.sICCenterCutoff, .sICCutoff, .sIICutoff, .sIVBCutoff].map(\.time))
        printSensedVelocity(m, windows: [("S-IC", P.firstMotion, 161.63), ("S-II", 161.63, 548.22),
                                         ("S-IVB", 548.22, 699.33)])
        // chi_thr, 5 s boxcars [k - 2, k + 3], by window (datasheet §14.1's)
        print("  thrust pitch (5 s boxcars), model - AS-506, deg: window mean (rms)")
        for (a, b) in [(15, 40), (40, 85), (85, 112), (112, 122), (122, 159)] {
            let d = (a...b).map { k in m.thrustPitch(from: k - 2, to: k + 3) - P.thrustPitch(from: k - 2, to: k + 3) }
            print(String(format: "    %3d-%3d s: %+.2f (%.2f)", a, b, mean(d), rms(d)))
        }
        // The attitude error, 10 s means: the model's pitch attitude less its
        // pitch program's command, against Figure 11-1's measured error.
        let f = NominalFlight.shared, iu = f.iu
        let t1 = f.range(try XCTUnwrap(iu.timeBases[.t1]))
        print("  pitch attitude error, 10 s means, model / AS-506 (Figure 11-1), deg:")
        var line = "   "
        for a in stride(from: 20, to: 160, by: 10) {
            let model = f.samples(in: Double(a)...Double(a + 10)).compactMap { s -> Double? in
                guard let st = s.vessels["Apollo 11"], let e = iu.eulerAngles(of: st.attitude) else { return nil }
                return (e.y - iu.plan.tilt.pitch(at: s.range - t1)) / deg
            }
            line += String(format: " %d s %+.2f/%+.2f", a, mean(model), P.pitchError(from: a, to: a + 10))
            if a % 50 == 0 { print(line); line = "   " }
        }
        print(line)
        XCTAssertGreaterThan(m.times.count, 1000)
    }

    // The S-II and the S-IVB, each from AS-506's state: the stack flown
    // again, with AS-506's postflight state (rotated from PACSS 13 into the
    // model's space-fixed frame, carried with gravity alone from the event
    // row to the model's own instant) put in place of the model's at its T3
    // and again at its T4. The S-II is judged at T4 before the second
    // injection, the S-IVB at its cutoff. Asserted: only that the injections
    // put AS-506's state in place; the residuals are printed.
    func testStageInjectionAtT3AndT4() throws {
        let flight = try InjectedFlight.fly(injectAtT3: true, injectAtT4: true)
        for i in flight.injections {
            let row = try XCTUnwrap(P.row(at: i.event))
            XCTAssertEqual(i.range - i.event, 0.03, accuracy: 0.04)   // T3, T4 sensed 1-3 steps after the cutoff
            XCTAssertEqual((i.position - row.position).length, row.velocity.length * (i.range - i.event), accuracy: 2)
            XCTAssertEqual((i.velocity - row.velocity).length, 0, accuracy: 0.5)
        }
        XCTAssertEqual(flight.injections.count, 2)
        let m = try ModelTrajectory(flight)
        print(String(format: "stage injection: AS-506's PFT state at the model's T3 (%.2f s) and T4 (%.2f s):",
                     flight.injections[0].range, flight.injections[1].range))
        let s2 = try XCTUnwrap(flight.beforeT4)
        let pft = P.row(at: 548.22)!, dt = s2.range - 548.22
        let r = pft.position + pft.velocity * dt, v = pft.velocity + P.gravity(at: pft.position) * dt
        print(String(format: "  S-II from T3, at the model's T4: speed %+.2f m/s, flight-path angle %+.3f deg, "
                     + "radius %+.0f m (model - AS-506)", s2.velocity.length - v.length,
                     flightPathAngle(s2.position, s2.velocity) - flightPathAngle(r, v), s2.position.length - r.length))
        printSensedVelocity(m, windows: [("S-II", flight.injections[0].range, flight.injections[1].range - 0.02)],
                            pftWindow: (161.63, 548.22))
        if let c = flight.cutoff {
            // over AS-506's 151.11 s from its S-II cutoff to its guidance cutoff
            let t4 = flight.injections[1].range
            printSensedVelocity(m, windows: [("S-IVB", t4, t4 + 699.33 - 548.22)], pftWindow: (548.22, 699.33))
            print(String(format: "  S-IVB from T4: velocity cutoff at %.2f s, %+.2f s after AS-506's 699.34 s",
                         c, c - 699.34))
        } else {
            print("  S-IVB from T4: no velocity cutoff")
        }
    }

    // AS-506's fitted pitch program flown by the model through the S-IC
    // (printed; datasheet §14.1's run c flew the reconstruction itself).
    func testFittedPitchProgramThroughTheSIC() throws {
        let flight = try InjectedFlight.fly(injectAtT3: false, injectAtT4: false, tilt: P.fittedTiltProgram, until: 162)
        let m = try ModelTrajectory(flight)
        print("AS-506's fitted pitch program, flown through the S-IC, model - AS-506:")
        printStates(m, at: [P.Event.sICCenterCutoff.time, P.Event.sICCutoff.time])
        print("  thrust pitch (5 s boxcars), model - AS-506, deg: window mean (rms)")
        for (a, b) in [(15, 40), (40, 85), (85, 112), (112, 122), (122, 159)] {
            let d = (a...b).map { k in m.thrustPitch(from: k - 2, to: k + 3) - P.thrustPitch(from: k - 2, to: k + 3) }
            print(String(format: "    %3d-%3d s: %+.2f (%.2f)", a, b, mean(d), rms(d)))
        }
        XCTAssertNil(flight.cutoff)
    }

    // MARK: Helpers

    /// The rows after 162 s that datasheet §14's integral of |a_ng| was taken
    /// on: PR 12's transcription's (docs/data/as506/pft-table-b2/).
    static let section14Rows: [Double] = [
        162.3, 164, 166, 168, 170, 172, 180, 190, 200, 210, 220, 230, 240, 250, 260, 270, 280, 290, 300, 310,
        320, 330, 340, 350, 360, 370, 380, 390, 400, 410, 420, 430, 440, 450, 456, 458, 460, 460.62, 462, 464,
        466, 470, 480, 490, 500, 510, 520, 530, 540, 542, 544, 546, 548, 548.22, 549, 550, 552, 554, 556, 558,
        560, 570, 580, 590, 600, 610, 620, 630, 640, 650, 660, 670, 678, 680, 682, 684, 686, 688, 690, 692,
        694, 696, 698, 699.33, 700, 702, 704, 706, 708, 709.33,
    ]

    /// Flight-path angle of a state, deg.
    func flightPathAngle(_ r: Vec3, _ v: Vec3) -> Double { asin(r.dot(v) / (r.length * v.length)) / deg }

    func mean(_ x: [Double]) -> Double { x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count) }
    func rms(_ x: [Double]) -> Double { (x.map { $0 * $0 }.reduce(0, +) / Double(max(x.count, 1))).squareRoot() }

    func interpolate(_ s: [(Double, Double)], at t: Double) -> Double {
        guard let i = s.firstIndex(where: { $0.0 >= t }) else { return s.last!.1 }
        if i == 0 { return s[0].1 }
        let (a, b) = (s[i - 1], s[i])
        return a.1 + (b.1 - a.1) * (t - a.0) / (b.0 - a.0)
    }

    /// The rows of a tools/data CSV (comment lines dropped), by column name.
    func csv(_ name: String) throws -> [[String: String]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/data/\(name)")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("tools/data/\(name) not found")
        }
        let lines = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        let header = lines[0].split(separator: ",").map(String.init)
        return lines.dropFirst().map { line in
            var cells: [String] = [], cell = "", quoted = false
            for ch in line {
                if ch == "\"" {
                    quoted.toggle()
                } else if ch == "," && !quoted {
                    cells.append(cell)
                    cell = ""
                } else {
                    cell.append(ch)
                }
            }
            cells.append(cell)
            return Dictionary(uniqueKeysWithValues: zip(header, cells))
        }
    }

    /// Model - AS-506 at AS-506's event times: speed, flight-path angle, radius.
    func printStates(_ m: ModelTrajectory, at times: [Double]) {
        for t in times {
            guard let row = P.row(at: t), t <= m.times.last! else { continue }
            let (r, v) = m.state(at: t)
            print(String(format: "  %7.2f s: speed %+7.2f m/s, flight-path angle %+.3f deg, radius %+6.0f m", t,
                         v.length - row.velocity.length,
                         flightPathAngle(r, v) - flightPathAngle(row.position, row.velocity),
                         r.length - row.position.length))
        }
    }

    /// Sensed velocity, model - AS-506, on the PFT's interval grid.
    func printSensedVelocity(_ m: ModelTrajectory, windows: [(String, Double, Double)],
                             pftWindow: (Double, Double)? = nil) {
        print("  sensed velocity, vector |sum| and integral of |a_ng|, model / AS-506 (m/s):")
        for (name, a, b) in windows {
            let (pa, pb) = pftWindow ?? (a, b)
            let model = m.sensedVelocity(from: a, to: b), as506 = P.sensedVelocity(from: pa, to: pb)
            print(String(format: "    %@ %.2f-%.2f s: vector %.2f / %.2f (%+.2f), integral %.2f / %.2f (%+.2f)",
                         name, a, b, model.vector.length, as506.vector.length,
                         model.vector.length - as506.vector.length,
                         model.integral, as506.integral, model.integral - as506.integral))
        }
    }
}

/// The model's trajectory in PACSS 13 terms: the "Apollo 11" stack's
/// recorded states rotated into the IU's space-fixed frame, interpolated
/// (velocity linearly, position by Hermite), with the simulator's own gravity
/// rotated likewise, so that its sensed velocity can be taken on the PFT's
/// interval grid.
struct ModelTrajectory {
    let times: [Double]
    let positions: [Vec3], velocities: [Vec3]
    let gravity: (Double, Vec3) -> Vec3

    init(times: [Double], positions: [Vec3], velocities: [Vec3], sim: Simulation, start: Epoch, frame: Quat) {
        self.times = times
        self.positions = positions.map { frame.conjugate.rotate($0) }
        self.velocities = velocities.map { frame.conjugate.rotate($0) }
        let earth = sim.system.earth
        gravity = { t, r in
            let s = sim.system.snapshot(at: start + (t - AS506.firstMotion))
            return frame.conjugate.rotate(sim.system.acceleration(relativeTo: earth, at: frame.rotate(r), snapshot: s))
        }
    }

    init(_ f: NominalFlight) throws {
        let s = f.samples.compactMap { x in x.vessels["Apollo 11"].map { (x.range, $0) } }
        self.init(times: s.map(\.0), positions: s.map(\.1.position), velocities: s.map(\.1.velocity),
                  sim: f.sim, start: AS506.rangeZero + AS506.firstMotion, frame: try XCTUnwrap(f.iu.spaceFixed))
    }

    init(_ f: InjectedFlight) throws {
        self.init(times: f.times, positions: f.positions, velocities: f.velocities, sim: f.sim, start: f.start,
                  frame: try XCTUnwrap(f.iu.spaceFixed))
    }

    func state(at t: Double) -> (position: Vec3, velocity: Vec3) {
        var lo = 0, hi = times.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if times[mid] <= t { lo = mid } else { hi = mid }
        }
        let h = times[hi] - times[lo], u = h > 0 ? (t - times[lo]) / h : 0
        let v = velocities[lo] * (1 - u) + velocities[hi] * u
        let h00 = 2 * u * u * u - 3 * u * u + 1, h10 = u * u * u - 2 * u * u + u
        let h01 = -2 * u * u * u + 3 * u * u, h11 = u * u * u - u * u
        let r = positions[lo] * h00 + velocities[lo] * (h10 * h) + positions[hi] * h01 + velocities[hi] * (h11 * h)
        return (r, v)
    }

    /// Sensed velocity on the PFT's interval grid within [a, b]: vector sum
    /// and integral of |a_ng| (Simpson's rule for the gravity).
    func sensedVelocity(from a: Double, to b: Double) -> (vector: Vec3, integral: Double) {
        var grid = AS506Postflight.trajectory.map(\.time).filter { $0 > a + 1e-9 && $0 < b - 1e-9 }
        grid = [a] + grid + [b]
        var v = Vec3.zero, s = 0.0
        for (t0, t1) in zip(grid, grid.dropFirst()) {
            let d = increment(t0, t1)
            v += d
            s += d.length
        }
        return (v, s)
    }

    func increment(_ t0: Double, _ t1: Double) -> Vec3 {
        let a = state(at: t0), b = state(at: t1), m = state(at: (t0 + t1) / 2)
        let g = gravity(t0, a.position) + gravity((t0 + t1) / 2, m.position) * 4 + gravity(t1, b.position)
        return b.velocity - a.velocity - g * ((t1 - t0) / 6)
    }

    /// Pitch of the model's sensed velocity over whole range seconds, deg.
    func thrustPitch(from a: Int, to b: Int) -> Double {
        AS506Postflight.pitch(of: sensedVelocity(from: Double(a), to: Double(b)).vector)
    }
}

/// Apollo 11 flown from the pad, with AS-506's postflight state optionally put
/// in place of the model's at the model's own T3 and T4, and optionally with
/// another pitch program; the stack's state recorded after every step.
final class InjectedFlight {
    struct Injection {
        /// The PFT event row's range time and the model's instant (s).
        let event: Double, range: Double
        /// AS-506's state put in place, PACSS 13 (m, m/s).
        let position: Vec3, velocity: Vec3
    }

    let sim: Simulation
    let stack: Vessel
    let iu: SaturnIU
    let start: Epoch
    private(set) var times: [Double] = [], positions: [Vec3] = [], velocities: [Vec3] = []
    private(set) var injections: [Injection] = []
    /// The stack at the model's T4, before any injection there (PACSS 13).
    private(set) var beforeT4: (range: Double, position: Vec3, velocity: Vec3)?
    /// Range time of the IGM's velocity cutoff.
    private(set) var cutoff: Double?

    private init(tilt: TiltProgram?) throws {
        sim = try Simulation.forTests(perturbations: true)
        stack = VesselLibrary.apollo11OnPad(in: sim, program: .as506(tilt: tilt))
        stack.mainThrottle = 1
        iu = stack.flightProgram as! SaturnIU
        start = sim.time
    }

    func range() -> Double { sim.time - start + AS506.firstMotion }

    static func fly(injectAtT3: Bool, injectAtT4: Bool, tilt: TiltProgram? = nil, until end: Double = 710)
        throws -> InjectedFlight {
        let f = try InjectedFlight(tilt: tilt)
        f.record()
        while f.range() < end && f.cutoff == nil {
            let before = f.range()
            for v in f.sim.vessels { f.sim.prepareControls(v) }
            f.sim.step(min(0.02, f.sim.maxStep()))
            if f.cutoff == nil && f.iu.log.last?.event == "S-IVB velocity cutoff (IGM)" { f.cutoff = before }
            if injectAtT3 && f.injections.isEmpty && f.iu.timeBases[.t3] != nil {
                f.inject(AS506Postflight.Event.sICCutoff.time)
            }
            if f.beforeT4 == nil && f.iu.timeBases[.t4] != nil, let frame = f.iu.spaceFixed {
                f.beforeT4 = (f.range(), frame.conjugate.rotate(f.stack.position),
                              frame.conjugate.rotate(f.stack.velocity))
                if injectAtT4 { f.inject(AS506Postflight.Event.sIICutoff.time) }
            }
            f.record()
        }
        return f
    }

    private func record() {
        times.append(range())
        positions.append(stack.position)
        velocities.append(stack.velocity)
    }

    /// AS-506's state at the event row, carried with the PFT's gravity alone
    /// to now, in place of the stack's.
    private func inject(_ event: Double) {
        guard let row = AS506Postflight.row(at: event), let frame = iu.spaceFixed else { return }
        let dt = range() - event
        let g = AS506Postflight.gravity(at: row.position)
        let r = row.position + row.velocity * dt + g * (dt * dt / 2), v = row.velocity + g * dt
        stack.position = frame.rotate(r)
        stack.velocity = frame.rotate(v)
        injections.append(Injection(event: event, range: range(), position: r, velocity: v))
    }
}
