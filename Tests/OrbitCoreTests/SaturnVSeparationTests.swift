import XCTest
@testable import OrbitCore

/// Apollo 11's staging on its solid motors (datasheet §12), read from the
/// shared recorded flight (`NominalFlight`). AS-506's separations were
/// "similar to those observed on previous flights" (FER §12): the measured
/// dynamics are AS-501's (MPR-SAT-FE-68-1, "FER-501" §12), a proxy with
/// different stage masses and eight S-II ullage motors, so the tolerances
/// are wide. Other references: AS-506's FER ("FER", Tables 2-2, 20-9) and
/// postflight trajectory (Boeing D5-15560-6, "PFT"), whose Tables 6-I and
/// 6-II simulate the spent stages.
final class SaturnVSeparationTests: XCTestCase {
    let flight = NominalFlight.shared
    let stack = "Apollo 11"

    /// Relative axial travel (m) and speed (m/s) of construction station
    /// `sta` (in) between the stack and `spent`, along the stack's axis, at
    /// each recorded sample from `t0` on (seconds after `t0`).
    func separation(from t0: Double, spent: String, station sta: Double, for span: Double = 2)
        -> [(t: Double, travel: Double, speed: Double, spent: NominalFlight.State, stack: NominalFlight.State)] {
        let p = Vec3(AS506.station(sta), 0, 0)
        return flight.samples(in: t0...(t0 + span)).compactMap { s in
            guard let a = s.vessels[stack], let b = s.vessels[spent] else { return nil }
            let x = a.attitude.rotate(.unitX)
            return (s.range - t0, (a.inertialPosition(ofStructuralPoint: p) - b.inertialPosition(ofStructuralPoint: p)).dot(x),
                    (a.velocity - b.velocity).dot(x), b, a)
        }
    }

    /// The first time `value` reaches `level`, linearly between samples.
    func time<T>(_ samples: [T], _ value: (T) -> Double, _ t: (T) -> Double, reaches level: Double) -> Double? {
        for (a, b) in zip(samples, samples.dropFirst()) where value(a) < level && value(b) >= level {
            return t(a) + (t(b) - t(a)) * (level - value(a)) / (value(b) - value(a))
        }
        return nil
    }

    // S-IC/S-II: the separation command (T3 + 0.7 s, FER Table 2-2) fires the
    // eight retros, which decelerate the spent S-IC while the S-II ullage
    // motors push the stack. On AS-501 the S-II's J-2 bells, 0.41 m below the
    // separation plane, cleared it 0.37 s after the signal, and the stages
    // had moved 1.55 m apart at +0.57 s, parting at about 8 m/s (FER-501
    // §12.2.3, Figures 12-3 and 12-4, M). The travel is measured at STA 1564
    // (any station gives the same for stages that hardly rotate). A constant
    // parting acceleration through those two points is 18.3 m/s^2 from an
    // effective start 0.158 s after the signal; the model's, reduced the
    // same way, is its retros' and ullage motors' 19 m/s^2, from AS-501's
    // effective start within 0.05 s: the retros' thrust builds up as in
    // FER-501 Figure 12-1. The stack's rates stay small.
    func testSICRetrosSeparateTheStages() throws {
        let t0 = try XCTUnwrap(flight.time(of: "S-IC/S-II separation"))
        XCTAssertEqual(t0, 162.3, accuracy: 0.1)
        let s = separation(from: t0, spent: "\(stack) – S-IC", station: 1564)
        /// Constant acceleration and effective start through two (time, travel) points.
        func fit(_ p1: (t: Double, d: Double), _ p2: (t: Double, d: Double)) -> (a: Double, start: Double) {
            let rootA = ((2 * p2.d).squareRoot() - (2 * p1.d).squareRoot()) / (p2.t - p1.t)
            return (rootA * rootA, p2.t - (2 * p2.d).squareRoot() / rootA)
        }
        let as501 = fit((0.37, 0.41), (0.57, 1.55))
        XCTAssertEqual(as501.a, 18.3, accuracy: 0.05)
        XCTAssertEqual(as501.start, 0.158, accuracy: 0.001)
        let model = fit((try XCTUnwrap(time(s, { $0.travel }, { $0.t }, reaches: 0.41)), 0.41),
                        (try XCTUnwrap(time(s, { $0.travel }, { $0.t }, reaches: 1.55)), 1.55))
        XCTAssertEqual(model.a, as501.a, accuracy: 1.5)
        XCTAssertEqual(model.start, as501.start, accuracy: 0.05)
        let at155 = try XCTUnwrap(s.first { $0.travel >= 1.55 })
        XCTAssertEqual(at155.speed, 8, accuracy: 1.5)
        for x in s { XCTAssertLessThan(x.stack.angularVelocity.length, 0.2 * AS506.degree) }
    }

    // MSFC-MAN-506 §4: seven retros (one out) separate the S-IC by at least
    // 6 ft (1.83 m) within a second. A retro that fails to light is a dud,
    // and keeps its grain (1,027 / 8 kg).
    func testSevenSICRetrosStillSeparateInASecond() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo11OnPad(in: sim)
        v.mainThrottle = 1
        func range() -> Double { sim.time - AS506.rangeZero }
        v.thrusters.first { $0.name == "S-IC retro motor 1" }!.isEnabled = false
        while range() < 161 { sim.tick() }
        let iu = v.flightProgram as! SaturnIU
        while range() < 170 && !iu.log.contains(where: { $0.event == "S-IC/S-II separation" }) { sim.tick() }
        _ = try XCTUnwrap(iu.log.first { $0.event == "S-IC/S-II separation" })
        let t0 = range()
        let spent = try XCTUnwrap(sim.vessels.first { $0.name == "\(stack) – S-IC" })
        XCTAssertEqual(spent.thrusters.filter { $0.name.hasPrefix("S-IC retro") && $0.isIgnited }.count, 7)
        let p = Vec3(AS506.station(1564), 0, 0)
        while range() < t0 + 1 - 1e-9 { sim.tick() }
        let travel = (v.inertialPosition(ofStructuralPoint: p) - spent.inertialPosition(ofStructuralPoint: p))
            .dot(v.attitude.rotate(.unitX))
        XCTAssertGreaterThanOrEqual(travel, 1.83)
        let grains = spent.tanks.filter { $0.name == "S-IC retro" }.map(\.mass)
        XCTAssertEqual(grains.reduce(0, +), AS506.sICRetroPropellant / 8, accuracy: 1e-9)
    }

    // The tower jettison (T3 + 36.2 s = 197.9 s, FER Table 2-2): the
    // frangible nuts and the tower-jettison motor fire together, with no
    // spring (AOH 2.9.4.8.4). The motor burns its 205.2 lb (93.08 kg) grain
    // for 36,734 lbf s (TN D-6295), a sensed Δv of Isp g0 ln(m0/m1) = 40.9
    // m/s on the LES's 4,042 kg (FER Table 20-9). Its thrust, leaning 3.784°
    // towards Position III (-z) and crossing the axis ahead of the LES's
    // CG, throws the tower to that side and pitches its nose over that way;
    // a separate planar integration of the same data (datasheet §12.3, L)
    // has it 8.3 m/s to the side and turning at 41°/s at burnout. The
    // manoeuvre "ensured a minimum miss distance of 150 feet" (TN D-7083,
    // H): when the stack's nose, the CM apex, passes the tower, the tower
    // is at least 45.7 m to the side.
    func testTowerJettisonMotorThrowsTheTowerClear() throws {
        let t0 = try XCTUnwrap(flight.time(of: "launch escape tower jettison"))
        XCTAssertEqual(t0, 197.9, accuracy: 0.1)
        let les = "\(stack) – LES"
        let window = flight.samples(in: t0...(t0 + 15))
        let s = window.filter { $0.vessels[les] != nil }
        let first = try XCTUnwrap(s.first?.vessels[les])
        XCTAssertEqual(first.mass, 4_042, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(first.tanks["Tower jettison"]), 205.2 * AS506.pound, accuracy: 1e-9)

        // Each sample's thrust acceleration holds over the step that ends there.
        var sensed = 0.0
        for (a, b) in zip(window, window.dropFirst()) where b.range <= t0 + 2 {
            sensed += (b.vessels[les]?.thrustAcceleration ?? 0) * (b.range - a.range)
        }
        let grain = 205.2 * AS506.pound
        let isp = 36_734 * AS506.poundForce / grain
        XCTAssertEqual(sensed, isp * log(4_042 / (4_042 - grain)), accuracy: 0.02)
        let burnout = flight.sample(at: t0 + 1.3)
        let spent = try XCTUnwrap(burnout.vessels[les])
        XCTAssertEqual(try XCTUnwrap(spent.tanks["Tower jettison"]), 0)
        let stackState = try XCTUnwrap(burnout.vessels[stack])
        let lateral = stackState.attitude.inverseRotate(spent.velocity - stackState.velocity)
        XCTAssertEqual(lateral.z, -8.3, accuracy: 0.5)
        XCTAssertEqual(lateral.y, 0, accuracy: 0.1)
        XCTAssertEqual(spent.angularVelocity.y / AS506.degree, 41, accuracy: 3, "nose towards -z")

        let nose = Vec3(AS506.apolloStation(AS506.cmApex), 0, 0)
        let passing = try XCTUnwrap(s.first { x in
            guard let a = x.vessels[stack], let l = x.vessels[les] else { return false }
            return a.attitude.inverseRotate(l.position - a.inertialPosition(ofStructuralPoint: nose)).x < 0
        })
        let a = try XCTUnwrap(passing.vessels[stack]), l = try XCTUnwrap(passing.vessels[les])
        let offset = a.attitude.inverseRotate(l.position - a.inertialPosition(ofStructuralPoint: nose))
        XCTAssertLessThan(offset.z, -45.7, "150 ft to the -z side")
    }

    // S-II/S-IVB: the separation command (T4 + 0.8 s) fires the four S-II
    // retros on the aft interstage. On AS-501 the S-IVB's J-2 had cleared
    // the separation plane, 5.51 m (217 in) of relative travel, 1.044 s
    // after the command, the stages parting at about 11 m/s with the S-II
    // decelerating at 11-13.5 m/s^2, and the S-IVB's rates within 0.2°/s
    // up to the J-2's start (FER-501 §12.4.3, Figures 12-12 and 12-15, M).
    // No spring parts them before the retros light.
    func testSIIRetrosSeparateTheStages() throws {
        let t0 = try XCTUnwrap(flight.time(of: "S-II/S-IVB separation"))
        XCTAssertEqual(t0, 549.0, accuracy: 0.1)
        let s = separation(from: t0, spent: "\(stack) – S-II", station: AS506.sIVBAftSkirt, for: 552.2 - t0)
        let first = try XCTUnwrap(s.first { $0.t > 0 })
        XCTAssertEqual(first.speed, 0, accuracy: 0.05, "no separation spring")
        let clear = try XCTUnwrap(time(s, { $0.travel }, { $0.t }, reaches: 5.51))
        XCTAssertEqual(clear, 1.044, accuracy: 0.15)
        let atClear = try XCTUnwrap(s.first { $0.t >= clear })
        XCTAssertEqual(atClear.speed, 11, accuracy: 2)
        let decelerating = s.filter { (0.2...1.2).contains($0.t) }.map { $0.spent.thrustAcceleration }
        XCTAssertFalse(decelerating.isEmpty)
        for a in decelerating { XCTAssertEqual(a, 12.25, accuracy: 1.25) }
        for x in s where x.t + t0 < 552.2 {
            XCTAssertLessThan(x.stack.angularVelocity.length, 0.2 * AS506.degree)
        }
    }

    // The S-IVB ullage motors: lit at 548.9 s (T4 + 0.7) and burning alone
    // until the J-2's start (STDV open, 552.2 s), they push the S-IVB stack
    // at 2 x 3,390 lbf x cos 35° (their nozzle cant; M) over its 166,634 kg
    // (FER Table 20-9, first ESC): 0.148 m/s^2. AS-506 had 10 kg of their 53 kg left at STDV open and
    // 1 kg at mainstage (554.7 s); their 61 kg of cases left at 561.0 s
    // (FER Tables 2-2 and 20-9).
    func testSIVBUllageMotorsBurnAndAreJettisoned() throws {
        XCTAssertEqual(try XCTUnwrap(flight.time(of: "S-IVB ullage motor ignition")), 548.9, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(flight.time(of: "S-IVB ullage case jettison")), 561.0, accuracy: 0.1)
        let expected = 2 * 3_390 * AS506.poundForce * cos(35 * AS506.degree) / 166_634
        for s in flight.samples(in: 549.3...552.1) {
            XCTAssertEqual(try XCTUnwrap(s.vessels[stack]).thrustAcceleration, expected, accuracy: 0.005)
        }
        XCTAssertEqual(try XCTUnwrap(flight.sample(at: 552.2).vessels[stack]?.tanks["S-IVB ullage"]), 10, accuracy: 3)
        XCTAssertEqual(try XCTUnwrap(flight.sample(at: 554.7).vessels[stack]?.tanks["S-IVB ullage"]), 0, accuracy: 1)
        let before = try XCTUnwrap(flight.sample(at: 560.9).vessels[stack]).mass
        let after = flight.sample(at: 561.1)
        XCTAssertEqual(try XCTUnwrap(after.vessels["\(stack) – S-IVB ullage rockets"]).mass, 61, accuracy: 1e-9)
        XCTAssertNil(after.vessels[stack]?.tanks["S-IVB ullage"])
        XCTAssertLessThan(try XCTUnwrap(after.vessels[stack]).mass, before - 61)
    }

    // The spent stages climb on as predicted: the S-IC to 115.0 km at
    // 269.1 s and the S-II to 188.8 km at 587.0 s (PFT Tables 6-I and 6-II,
    // altitudes over the Fischer-1960 ellipsoid; M as simulations). The
    // model's apexes are converted to the same ellipsoid
    // (`Ellipsoid.fischer1960`, on WGS 84's centre and axis; datasheet §15).
    // The S-IC peaks 1.2 km higher, at 116.2 km at 270.1 s; the S-II, which
    // leaves 0.07° steeper than AS-506's (0.68° against 0.61°), at 189.8 km
    // at 589.2 s (datasheet §17).
    func testSpentStagesClimbAsPredicted() throws {
        let pole = flight.sim.snapshot.orientation(flight.sim.system.earth).pole
        /// Height over Fischer 1960 of an ICRF position.
        func fischer(_ r: Vec3) -> Double {
            let z = r.dot(pole)
            return Ellipsoid.fischer1960.geodetic(Vec3((r - pole * z).length, 0, z)).height
        }
        func apex(_ name: String) throws -> (range: Double, height: Double) {
            var best: (range: Double, height: Double)?
            for s in flight.samples {
                guard let v = s.vessels[name] else { continue }
                let h = fischer(v.position)
                if h > best?.height ?? -.infinity { best = (s.range, h) }
            }
            return try XCTUnwrap(best)
        }

        let sIC = try apex("\(stack) – S-IC")
        XCTAssertEqual(sIC.range, 269.1, accuracy: 3)
        XCTAssertEqual(sIC.height, 115_000, accuracy: 1_500)
        let sII = try apex("\(stack) – S-II")
        XCTAssertEqual(sII.range, 587.0, accuracy: 5)
        XCTAssertEqual(sII.height, 188_800, accuracy: 1_500)
    }
}
