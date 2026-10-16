import XCTest
@testable import OrbitCore

/// `VesselLibrary.saturnV()` against published AS-506 references (design tests
/// B1-B4, B7, A13, and A1/A2 on the real stack). Expected values are literals
/// in the published unit with their source; `AS506` only sets up. Checks that
/// are bookkeeping identities, or compare the model with the data it was
/// derived from, say so: they guard the data entry, not the physics.
final class SaturnVDataTests: XCTestCase {
    let lb = 0.45359237, lbf = 4.4482216152605, g0 = 9.80665, inch = 0.0254, ft = 0.3048
    let deg = Double.pi / 180

    func part(_ v: Vessel, _ name: String) -> VesselPart { v.parts.first { $0.name == name }! }
    func pounds(_ parts: [VesselPart]) -> Double { parts.reduce(0) { $0 + $1.mass } / lb }

    // A13: names are unique (the HUD and the IU item address them), tank names
    // fit the HUD column, and every engine draws from its own stage. Engine
    // layout, gimbals and the S-IVB APS against the TVC datasheet (§7).
    func testNamesFeedsAndStagingRules() {
        let v = VesselLibrary.saturnV()
        XCTAssertEqual(v.parts.map(\.name), ["S-IC", "S-IC/S-II interstage", "S-II", "S-II/S-IVB interstage",
                                             "S-IVB", "IU", "SLA", "LM", "CSM", "LES"])
        XCTAssertEqual(v.parts.map(\.staging), [.event(1), .event(2), .event(4), .event(4),
                                                .fixed, .fixed, .fixed, .fixed, .fixed, .event(3)])
        XCTAssertEqual(v.tanks.map(\.name), ["S-IC LOX", "S-IC RP-1", "S-II LOX", "S-II LH2", "S-IVB LOX", "S-IVB LH2",
                                             "APS I N2O4", "APS I MMH", "APS III N2O4", "APS III MMH"])
        for t in v.tanks { XCTAssertLessThanOrEqual(t.name.count, 14, t.name) }
        let names = v.thrusters.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        for p in v.parts {
            for t in p.thrusters {
                for tank in t.feed?.tanks ?? [] {
                    XCTAssertTrue(p.tanks.contains { $0 === tank }, "\(t.name) draws from \(tank.name)")
                }
            }
        }
        let mains = v.thrusters.filter { $0.groups.contains(.main) }
        XCTAssertEqual(mains.map(\.name), (1...5).map { "S-IC engine \($0)" } + (1...5).map { "S-II engine \($0)" }
                       + ["S-IVB engine"])
        for e in mains { XCTAssertEqual(e.throttleRange, 1...1, e.name) }
        // Engine 5 is the centre engine of both clusters.
        for name in ["S-IC engine 5", "S-II engine 5"] {
            let e = v.thrusters.first { $0.name == name }!
            XCTAssertEqual(e.position.y, 0)
            XCTAssertEqual(e.position.z, 0)
        }
        // Engine n under fin n, with +z towards Position I and +y towards IV
        // (Oikofuge after TN D-5399; heroicrelics; CSS): 1 between Positions I
        // and II at (-y, +z), 2 at (-y, -z), 3 at (+y, -z), 4 at (+y, +z).
        for stage in ["S-IC", "S-II"] {
            for (n, signs) in [(1, (-1.0, 1.0)), (2, (-1, -1)), (3, (1, -1)), (4, (1, 1))] {
                let e = v.thrusters.first { $0.name == "\(stage) engine \(n)" }!
                XCTAssertEqual(e.position.y.sign, signs.0.sign, e.name)
                XCTAssertEqual(e.position.z.sign, signs.1.sign, e.name)
                XCTAssertEqual(abs(e.position.y), abs(e.position.z), accuracy: 1e-12, e.name)
            }
        }
        // Gimbals on the outboard engines and the S-IVB J-2, each with a
        // pitch-plane and a yaw-plane actuator; centre engines fixed.
        // Transcriptions: F-1 ±5° and 5°/s (EH 8.13); S-II J-2 ±7° and 8°/s
        // (EH 8.20); S-IVB J-2 ±7° (EH 8.30; Haynes) at the S-II rate, a
        // placeholder.
        for e in mains {
            let gimballed = e.position.y != 0 || e.position.z != 0 || e.name == "S-IVB engine"
            XCTAssertEqual(e.gimbal.map(\.tilt), gimballed ? [.unitZ, -Vec3.unitY] : [], e.name)
            let (range, rate) = e.name.hasPrefix("S-IC") ? (5.0, 5.0) : (7.0, 8.0)
            for a in e.gimbal {
                XCTAssertEqual(a.range.upperBound, range * deg, accuracy: 1e-15, e.name)
                XCTAssertEqual(a.range.lowerBound, -range * deg, accuracy: 1e-15, e.name)
                XCTAssertEqual(a.rateLimit, rate * deg, accuracy: 1e-15, e.name)
                XCTAssertEqual(a.timeConstant, 0, e.name)
                XCTAssertEqual(a.bias, 0, e.name)
            }
        }
        // S-IVB APS: two modules of one pitch, two roll/yaw and one ullage
        // engine (APS-TN; EH 8.30), thrust 147 lbf "operate at" and 72 lbf
        // (APS-TN), responding only while the S-IVB is the active stage.
        let aps = v.thrusters.filter { $0.name.hasPrefix("APS") }
        XCTAssertEqual(aps.map(\.name), ["I", "III"].flatMap { m in
            ["pitch", "roll/yaw +t", "roll/yaw -t", "ullage"].map { "APS \(m) \($0)" } })
        for t in aps {
            XCTAssertTrue(t.activeStageOnly, t.name)
            XCTAssertEqual(t.maxThrustVacuum, (t.name.hasSuffix("ullage") ? 72 : 147) * lbf, accuracy: 1e-9, t.name)
            XCTAssertTrue(t.gimbal.isEmpty, t.name)
        }
        XCTAssertEqual(v.thrusters.filter { $0.activeStageOnly }.count, 8)
        // Roles (datasheet §7.3 table, inferred directions): module I at +z,
        // III at -z. Pure roll fires one tangential engine per module, pure
        // yaw the two that push the same way, pitch a single engine.
        let groups = Dictionary(uniqueKeysWithValues: aps.map { ($0.name, $0.groups) })
        XCTAssertEqual(groups["APS I pitch"], [.pitchDown])
        XCTAssertEqual(groups["APS III pitch"], [.pitchUp])
        XCTAssertEqual(groups["APS I roll/yaw +t"], [.rollRight, .yawRight])
        XCTAssertEqual(groups["APS I roll/yaw -t"], [.rollLeft, .yawLeft])
        XCTAssertEqual(groups["APS III roll/yaw +t"], [.rollRight, .yawLeft])
        XCTAssertEqual(groups["APS III roll/yaw -t"], [.rollLeft, .yawRight])
        XCTAssertEqual(groups["APS I ullage"], [.translateForward])
        XCTAssertEqual(groups["APS III ullage"], [.translateForward])
        for t in aps where !t.name.hasSuffix("ullage") {
            XCTAssertEqual(t.position.z, t.name.hasPrefix("APS I ") ? 3.5 : -3.5, accuracy: 1e-12, t.name)
        }
        // APS loads: FER-507's 405 lb N2O4 and 252 lb MMH at liftoff (AS-507
        // as a proxy), split equally between the modules (transcription). The
        // feed mixture ratio is the load ratio, so both tanks empty together.
        for t in aps { XCTAssertEqual(t.rating.mixtureRatio!, 405.0 / 252, accuracy: 1e-12, t.name) }
        for m in ["I", "III"] {
            XCTAssertEqual(part(v, "S-IVB").tanks.first { $0.name == "APS \(m) N2O4" }!.capacity, 202.5 * lb,
                           accuracy: 1e-9)
            XCTAssertEqual(part(v, "S-IVB").tanks.first { $0.name == "APS \(m) MMH" }!.capacity, 126 * lb,
                           accuracy: 1e-9)
        }
        XCTAssertFalse(v.thrusters.contains { $0.name.contains("stand-in") })
    }

    // B3: the vehicle at first motion is the ground-ignition stack less the
    // propellant used before release, row by row.
    func testFirstMotionMassesMatchGroundIgnitionWeights() {
        let v = VesselLibrary.saturnV()
        // Bookkeeping identities: SP-4029 Ground Ignition Weights rows, plus the
        // 85,745 lb ignition-to-release consumption (Mission Operations Report
        // M-932-69-11, Table 3, predicted) taken from the S-IC tanks.
        XCTAssertEqual(v.mass / lb + 85_745, 6_477_875, accuracy: 1e-6)
        XCTAssertEqual(pounds([part(v, "S-IC")]) + 85_745, 5_023_648, accuracy: 1e-6)
        XCTAssertEqual(pounds([part(v, "S-IC/S-II interstage")]), 11_477, accuracy: 1e-6)
        XCTAssertEqual(pounds([part(v, "S-II")]), 1_058_140, accuracy: 1e-6)
        XCTAssertEqual(pounds([part(v, "S-II/S-IVB interstage")]), 8_076, accuracy: 1e-6)
        XCTAssertEqual(pounds([part(v, "S-IVB")]), 262_613, accuracy: 1e-6)
        XCTAssertEqual(pounds([part(v, "IU")]), 4_275, accuracy: 1e-6)
        XCTAssertEqual(pounds(["SLA", "LM", "CSM", "LES"].map { part(v, $0) }), 109_646, accuracy: 1e-6)
        // The pre-release consumption leaves the S-IC tanks in the stage's
        // consumption ratio (SP-4029 Propellant Usage: 3,266,014 / 1,394,126 lb).
        let lox = v.tanks[0].mass / lb, rp1 = v.tanks[1].mass / lb
        XCTAssertEqual((3_305_786 - lox) / (1_424_889 - rp1), 3_266_014 / 1_394_126.0, accuracy: 1e-4)

        // Independent: everything above the S-IC against the pre-flight S-II
        // ignition mass, 659,432.6 kg (AS-506 Technical Information Summary, as
        // converted by the M1 datasheet). The model does not vent the S-II and
        // S-IVB before S-II ignition (est. 0.5-1.5 t), but a prediction's loads
        // can differ from the ground ignition loads either way, so the sign of
        // the difference is not checked.
        let above = v.parts.dropFirst().reduce(0) { $0 + $1.mass }
        XCTAssertEqual(above, 659_432.6, accuracy: 659_432.6 * 1e-3)
    }

    // B7: stack geometry. None of it is independent: the stations were derived
    // from these published lengths or chosen to fit them, so the checks guard
    // the data entry.
    func testStackDimensions() {
        let v = VesselLibrary.saturnV()
        func span(_ names: [String]) -> Double {
            let ps = names.map { part(v, $0) }
            let top = ps.map { $0.offset.x + $0.length / 2 }.max()!
            let bottom = ps.map { $0.offset.x - $0.length / 2 }.min()!
            return top - bottom
        }
        // Identities by construction: the LES tip is placed 363 ft (Apollo 11
        // press kit) above the base, the base is the 138 ft S-IC (Saturn V News
        // Reference) below STA 1541, and the 396 in diameter is 33 ft.
        XCTAssertEqual(span(v.parts.map(\.name)), 363 * ft, accuracy: 1e-9)
        XCTAssertEqual(span(["S-IC"]), 138 * ft, accuracy: 1e-9)
        XCTAssertEqual(2 * v.parts.map(\.radius).max()!, 33 * ft, accuracy: 1e-9)
        // Consistent with the stations the datasheet chose: each upper stage's
        // length includes the interstage below it, a convention picked to fit
        // these News Reference lengths (the 281 ft is recalled; the model is
        // 1 in over).
        XCTAssertEqual(span(["S-IC/S-II interstage", "S-II"]), 81.5 * ft, accuracy: 0.3)
        XCTAssertEqual(span(["S-II/S-IVB interstage", "S-IVB"]), (58 * 12 + 7) * inch, accuracy: 0.3)
        XCTAssertEqual(span(["S-IC", "S-IC/S-II interstage", "S-II", "S-II/S-IVB interstage", "S-IVB", "IU"]),
                       281 * ft, accuracy: 0.3)
    }

    // B1, B2: engine ratings.
    func testEngineRatings() {
        let p0 = 101_325.0
        /// Thrust at pressure `p` and the propellant one engine draws in 1 s.
        func run(_ rating: EngineRating, at p: Double) -> (thrust: Double, ox: Double, fuel: Double) {
            let ox = PropellantTank(name: "Ox", capacity: 1e5), fuel = PropellantTank(name: "Fuel", capacity: 1e5)
            let e = Thruster(name: "E", position: .zero, direction: .unitX, rating: rating,
                             feed: .bipropellant(oxidizer: ox, fuel: fuel), groups: [.main])
            e.level = 1
            let thrust = e.thrust(ambientPressure: p, seaLevelPressure: p0)
            e.draw(dt: 1)
            return (thrust, 1e5 - ox.mass, 1e5 - fuel.mass)
        }

        // F-1 as rated (Betts, NTRS 20140011656): 1,522,000 lbf and 265.4 s at
        // sea level, 304.1 s in vacuum, 5,737 lb/s at mixture ratio 2.27. The
        // sea-level thrust is an identity: the rated exit area is (F_vac - F_sl) / p0.
        let rated = run(AS506.f1Rated, at: p0)
        XCTAssertEqual(rated.thrust, 1_522_000 * lbf, accuracy: 1e-6)
        XCTAssertEqual(AS506.f1Rated.ispSeaLevel, 265.4, accuracy: 1)
        XCTAssertEqual(AS506.f1Rated.ispVacuum, 304.1, accuracy: 1)
        XCTAssertEqual(rated.ox + rated.fuel, 5_737 * lb, accuracy: 5_737 * lb * 1e-2)
        XCTAssertEqual(rated.ox / rated.fuel, 2.27, accuracy: 1e-9)

        // F-1 flight-matched: its 9.96 m^2 effective exit keeps the rated
        // sea-level Isp, and matches the rated nozzle, (F_vac - F_sl) / p0 from
        // Betts' pair, to 1 %. Five of them against the published liftoff
        // thrust, 7,648,000 lbf (This Day in Aviation, Braeunig; basis unknown):
        // a constant flow fitted to the whole burn is about 1.7 % high at
        // liftoff, so allow 2.5 %.
        XCTAssertEqual(AS506.f1.ispSeaLevel, 265.4, accuracy: 0.1)
        XCTAssertEqual(AS506.f1.ispVacuum, 304.1, accuracy: 0.1)
        XCTAssertEqual(AS506.f1.impliedExitArea, (1_748_200 - 1_522_000) * lbf / p0, accuracy: 9.93 * 1e-2)
        let flight = run(AS506.f1, at: p0)
        XCTAssertEqual(5 * flight.thrust, 7_648_000 * lbf, accuracy: 7_648_000 * lbf * 0.025)
        XCTAssertEqual(flight.ox / flight.fuel, 2.3427, accuracy: 1e-9)

        // J-2 settings: transcription checks of the published values, and the
        // derived low-EMR setting (thrust linear in EMR between the other two,
        // Isp +4 s per unit of EMR decrease). Every setting shares the geometric
        // exit, pi/4 (14.7 in throat, NASA SP-8120)^2 x area ratio 27.5.
        let j2Exit = Double.pi / 4 * (14.7 * inch) * (14.7 * inch) * 27.5
        let settings: [(EngineRating, thrust: Double, isp: Double, ratio: Double)] = [
            (AS506.sIIJ2, 230_000, 425, 5.5),          // NTRS 20100032986; enginehistory.org
            (AS506.sIVBJ2Burn1, 202_603, 427, 5.0),    // This Day in Aviation; Braeunig
            (AS506.sIIJ2LowEMR, 186_164.8, 428.2, 4.7), // derived; EMR from the AS-501 summary
        ]
        for (rating, thrust, isp, ratio) in settings {
            let vacuum = run(rating, at: 0)
            XCTAssertEqual(vacuum.thrust, thrust * lbf, accuracy: thrust * lbf * 1e-6, rating.name)
            XCTAssertEqual(rating.ispVacuum, isp, accuracy: 1e-9, rating.name)
            XCTAssertEqual(vacuum.ox + vacuum.fuel, thrust * lbf / (isp * g0), accuracy: 1e-9, rating.name)
            XCTAssertEqual(vacuum.ox / vacuum.fuel, ratio, accuracy: 1e-9, rating.name)
            XCTAssertEqual(rating.impliedExitArea, j2Exit, accuracy: j2Exit * 1e-9, rating.name)
            XCTAssertEqual(run(rating, at: p0).thrust, thrust * lbf - p0 * j2Exit, accuracy: 1e-6, rating.name)
        }
    }

    // A1 on the S-IC: the shared feed runs out of LOX first, at exactly its
    // unusable mass, after usable LOX / LOX flow.
    func testSICDrawStopsOnLOXDepletion() {
        let v = VesselLibrary.saturnV()
        let lox = v.tanks[0], rp1 = v.tanks[1]
        let lox0 = lox.mass, rp10 = rp1.mass
        let mains = v.parts[0].thrusters.filter { $0.groups.contains(.main) }
        for e in mains { e.level = 1 }
        let oxFlow = mains.reduce(0) { $0 + $1.massFlow } * 2.3427 / 3.3427
        var t = 0.0
        while t < 400 && v.consumePropellant(dt: 0.02) { t += 0.02 }   // about 156 s
        XCTAssertEqual(lox.mass, lox.unusableMass)
        XCTAssertEqual(rp1.mass, rp10 - (lox0 - lox.unusableMass) / 2.3427, accuracy: 1)
        XCTAssertEqual(t, (lox0 - lox.unusableMass) / oxFlow, accuracy: 0.02)
        XCTAssertEqual(v.mainDeltaV, 0)
        // Consistency (the mixture ratio is the published consumption ratio):
        // LOX at OECO 39,772 lb and RP-1 30,763 lb (SP-4029 Propellant Usage).
        XCTAssertEqual(lox.mass / lb, 39_772, accuracy: 1e-6)
        XCTAssertEqual(rp1.mass / lb, 30_763, accuracy: 30_763 * 1e-3)
    }

    // A2 on the S-II: assigning the low-EMR rating changes thrust, flow and the
    // drawn split together.
    func testSIIMixtureRatioShift() {
        let v = VesselLibrary.saturnV()
        let e = v.thrusters.first { $0.name == "S-II engine 1" }!
        let lox = v.tanks[2], lh2 = v.tanks[3]
        e.level = 1
        XCTAssertEqual(e.thrust(ambientPressure: 0, seaLevelPressure: 101_325), 230_000 * lbf, accuracy: 1e-6)
        e.rating = AS506.sIIJ2LowEMR
        XCTAssertEqual(e.thrust(ambientPressure: 0, seaLevelPressure: 101_325), AS506.sIIJ2LowEMR.thrustVacuum)
        XCTAssertEqual(e.massFlow, AS506.sIIJ2LowEMR.massFlow)
        let lox0 = lox.mass, lh20 = lh2.mass
        e.draw(dt: 1)
        XCTAssertEqual((lox0 - lox.mass) / (lh20 - lh2.mass), 4.7, accuracy: 1e-9)
        XCTAssertEqual(lox0 - lox.mass + lh20 - lh2.mass, e.massFlow, accuracy: 1e-9)
    }

    // B4: the published event timeline driven through the propellant model
    // alone (no trajectory), from first motion to S-IVB cutoff. Mass at each
    // event and the sensed (thrust) accelerations against SP-4029.
    func testEventTimelineThroughThePropellantModel() {
        let v = VesselLibrary.saturnV()
        var t = AS506.firstMotion, deltaV = 0.0, acceleration = 0.0
        func mains() -> [Thruster] { v.activeStage!.thrusters.filter { $0.groups.contains(.main) && $0.isEnabled } }
        func engine(_ name: String) -> Thruster { v.thrusters.first { $0.name == name }! }
        func tank(_ name: String) -> PropellantTank { v.tanks.first { $0.name == name }! }
        /// Range time `end`, or until the active stage's engines run dry (returns true).
        func burn(to end: Double) -> Bool {
            while t < end - 1e-9 {
                let h = min(0.02, end - t)
                acceleration = mains().reduce(0) { $0 + $1.thrust(ambientPressure: 0, seaLevelPressure: 101_325) }
                    / v.mass
                deltaV += acceleration * h
                v.consumePropellant(dt: h)
                t += h
                if mains().contains(where: { !$0.hasPropellant }) { return true }
            }
            return false
        }
        func ignite() { for e in mains() { e.level = 1 } }

        // S-IC: centre engine cut at 135.20 s, outboard engines run to LOX depletion.
        ignite()
        XCTAssertFalse(burn(to: AS506.sICCenterCutoff))
        engine("S-IC engine 5").isEnabled = false
        XCTAssertTrue(burn(to: 170))
        // Consistency: the F-1 flow was derived from this cutoff time and the
        // published consumption (SP-4029 Apollo 11 Summary 161.63 s; mass at
        // OECO 1,817,735 lb = ground ignition less consumed, SP-4029).
        XCTAssertEqual(t, 161.63, accuracy: 0.05)
        XCTAssertEqual(v.mass / lb, 1_817_735, accuracy: 1_817_735 * 5e-3)
        // Independent: 3.94 g at OECO (SP-4029 Ascent Phase, total inertial acceleration).
        XCTAssertEqual(acceleration / g0, 3.94, accuracy: 0.05)

        // S-II: ignition at 164.00 s, interstage at 192.3 s, LES at 197.9 s.
        XCTAssertEqual(v.jettisonNextStage()?.parts.map(\.name), ["S-IC"])
        t = AS506.sIIIgnition
        ignite()
        XCTAssertFalse(burn(to: AS506.interstageJettison))
        XCTAssertEqual(v.jettisonNextStage()?.parts.map(\.name), ["S-IC/S-II interstage"])
        XCTAssertFalse(burn(to: AS506.lesJettison))
        XCTAssertEqual(v.jettisonNextStage()?.parts.map(\.name), ["LES"])
        XCTAssertFalse(burn(to: AS506.sIICenterCutoff))
        // Consistency (the J-2's 230,000 lbf was selected among published
        // ratings to reproduce it): 1.82 g just before S-II CECO (SP-4029 Ascent Phase).
        XCTAssertEqual(acceleration / g0, 1.82, accuracy: 0.03)
        engine("S-II engine 5").isEnabled = false
        deltaV = 0
        XCTAssertFalse(burn(to: AS506.sIIMixtureRatioShift))
        for e in mains() { e.rating = AS506.sIIJ2LowEMR }
        XCTAssertTrue(burn(to: 560))
        // Consistency: the EMR shift time and low EMR were chosen so that LOX
        // depletes at the published S-II OECO, 548.22 s (SP-4029 Apollo 11 Summary).
        XCTAssertEqual(t, 548.22, accuracy: 0.3)
        XCTAssertEqual(tank("S-II LOX").mass, tank("S-II LOX").unusableMass)
        XCTAssertGreaterThan(tank("S-II LH2").usableMass, 0)
        // Independent but loose: CECO to OECO thrust Δv against the observed
        // 1,208.6 m/s plus gravity (10.7) and estimated steering (≈ 30) losses
        // (SP-4029 Ascent Phase; the M1 datasheet's budget).
        XCTAssertEqual(deltaV, 1_250, accuracy: 40)

        // S-IVB burn 1: separation at 549.0 s, ignition at 552.20 s, guidance
        // cutoff at 699.33 s.
        XCTAssertEqual(v.jettisonNextStage()?.parts.map(\.name), ["S-II", "S-II/S-IVB interstage"])
        t = AS506.sIVBIgnition
        ignite()
        XCTAssertFalse(burn(to: AS506.sIVBCutoff))
        // Independent: 0.69 g at cutoff (SP-4029 Ascent Phase, a single read),
        // and the insertion mass, 299,099 lb (Flight Evaluation Report
        // MPR-SAT-FE-69-9, read by OCR; low confidence, so 1 %).
        XCTAssertEqual(acceleration / g0, 0.69, accuracy: 0.02)
        XCTAssertEqual(v.mass / lb, 299_099, accuracy: 299_099 * 1e-2)
        XCTAssertEqual(v.parts.map(\.name), ["S-IVB", "IU", "SLA", "LM", "CSM"])
    }
}
