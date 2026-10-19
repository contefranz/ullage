import XCTest
@testable import OrbitCore

/// `VesselLibrary.saturnV()` against published AS-506 references (design tests
/// B1-B4, B7, A13, and A1/A2 on the real stack), mostly AS-506's Flight
/// Evaluation Report, MPR-SAT-FE-69-9 (FER). Expected values are literals in
/// the published unit with their source; `AS506` only sets up. Checks that
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
                                             "S-IVB", "S-IVB ullage rockets", "IU", "SLA", "LM", "CSM", "LES"])
        XCTAssertEqual(v.parts.map(\.staging), [.event(1), .event(2), .event(4), .event(4),
                                                .fixed, .event(5), .fixed, .fixed, .fixed, .fixed, .event(3)])
        // Each solid motor has its own grain, named after its set.
        func times(_ name: String, _ n: Int) -> [String] { Array(repeating: name, count: n) }
        var expected: [String] = ["S-IC LOX", "S-IC RP-1"]
        expected += times("S-IC retro", 8)
        expected += times("S-II ullage", 4)
        expected += ["S-II LOX", "S-II LH2"]
        expected += times("S-II retro", 4)
        expected += ["S-IVB LOX", "S-IVB LH2", "APS I N2O4", "APS I MMH", "APS III N2O4", "APS III MMH"]
        expected += times("S-IVB ullage", 2)
        expected += ["Tower jettison"]
        XCTAssertEqual(v.tanks.map(\.name), expected)
        // The solids: retros fire with their own stage's separation, ullage
        // motors with the separation below them; no controls reach them, and
        // each set's forces add to a pure axial thrust (no side force, no
        // torque about the vehicle axis or the CoM's line).
        for (set, count, trigger, forward) in [("S-IC retro", 8, SolidTrigger.ownSeparation, false),
                                               ("S-II ullage", 4, .event(1), true),
                                               ("S-II retro", 4, .ownSeparation, false),
                                               ("S-IVB ullage", 2, .event(4), true)] {
            let motors = v.thrusters.filter { $0.name.hasPrefix(set + " motor") }
            XCTAssertEqual(motors.count, count, set)
            var force = Vec3.zero, torque = Vec3.zero
            for m in motors {
                XCTAssertEqual(motors.filter { $0.tank === m.tank }.count, 1, "\(m.name) has its own grain")
                XCTAssertTrue(m.isSolid, m.name)
                XCTAssertEqual(m.trigger, trigger, m.name)
                XCTAssertTrue(m.groups.isEmpty, m.name)
                XCTAssertEqual(m.direction.x > 0, forward, m.name)
                force += m.direction
                torque += m.position.cross(m.direction)
            }
            XCTAssertEqual(force.y, 0, accuracy: 1e-12, set)
            XCTAssertEqual(force.z, 0, accuracy: 1e-12, set)
            XCTAssertEqual(torque.length, 0, accuracy: 1e-9 * Double(count), set)
        }
        // Motors, not springs, separate the S-IC, the S-II with the aft
        // interstage, and the LES; the interstage and the ullage cases keep
        // the 1 m/s placeholder.
        for p in v.parts {
            XCTAssertEqual(p.separationSpeed, ["S-IC", "S-II", "S-II/S-IVB interstage", "LES"].contains(p.name) ? 0 : 1,
                           p.name)
        }
        // The tower-jettison motor: lit by the LES's separation, its thrust
        // 3.784° off the axis towards Position III (-z), crossing the axis
        // (TN D-6295, AOH 2.9.5.7.4; MSFC-MAN-506 Fig 7-15) 98.8 in ahead of
        // the whole LES's CG (Xa 1395.9 and 1297.1), about which the LES's
        // inertia is the Mission Reports' (datasheet §12).
        let lesPart = try! XCTUnwrap(v.parts.first { $0.name == "LES" })
        let tjm = try! XCTUnwrap(lesPart.thrusters.first { $0.name == "Tower jettison motor" })
        XCTAssertEqual(tjm.position.x - lesPart.centerOfMass.x, 98.8 * AS506.inch, accuracy: 1e-9)
        XCTAssertEqual(lesPart.localInertia.r0.x, 1_100, accuracy: 1e-6)
        XCTAssertEqual(lesPart.localInertia.r1.y, 37_500, accuracy: 1e-6)
        XCTAssertEqual(lesPart.localInertia.r2.z, 37_500, accuracy: 1e-6)
        XCTAssertTrue(tjm.isSolid)
        XCTAssertEqual(tjm.trigger, .ownSeparation)
        XCTAssertEqual(acos(tjm.direction.x) / AS506.degree, 3.784, accuracy: 1e-9)
        XCTAssertLessThan(tjm.direction.z, 0)
        XCTAssertEqual(tjm.direction.y, 0)
        XCTAssertEqual(tjm.position.y, 0)
        XCTAssertEqual(tjm.position.z, 0)
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
        // APS loads: AS-506's 203 lb N2O4 and 126 lb MMH in each module (FER
        // Table 7-5, transcription). The feed mixture ratio is the load ratio,
        // so both tanks empty together.
        for t in aps { XCTAssertEqual(t.rating.mixtureRatio!, 203.0 / 126, accuracy: 1e-12, t.name) }
        for m in ["I", "III"] {
            XCTAssertEqual(part(v, "S-IVB").tanks.first { $0.name == "APS \(m) N2O4" }!.capacity, 203 * lb,
                           accuracy: 1e-9)
            XCTAssertEqual(part(v, "S-IVB").tanks.first { $0.name == "APS \(m) MMH" }!.capacity, 126 * lb,
                           accuracy: 1e-9)
        }
        XCTAssertFalse(v.thrusters.contains { $0.name.contains("stand-in") })
    }

    // B3: the vehicle at first motion (holddown release, 0.30 s).
    func testFirstMotionMassesMatchTheFER() {
        let v = VesselLibrary.saturnV()
        // Independent: the model's S-IC is the FER's but its upper stages are
        // SP-4029's ground ignition weights; together they make the FER's
        // vehicle at first motion, 2,899,008 kg (Table 20-1), to the
        // kilogram, and with the 39,307 kg burned in thrust buildup (Table
        // 20-9) the ground ignition mass, 6,477,875 lb (SP-4029).
        XCTAssertEqual(v.mass, 2_899_008, accuracy: 1)
        XCTAssertEqual((v.mass + 39_307) / lb, 6_477_875, accuracy: 3)
        // Bookkeeping identities: the S-IC at holddown release (FER Table
        // 20-1) with the small interstage ring that leaves with it (Table
        // 20-9) and the upper stages' frost and purge gas (S-II 204 + 54 kg,
        // S-IVB 90 kg, Table 20-1), its LOX (liquid, Table 5-2, and the GOX
        // already in its ullage, Table 20-1) and RP-1 (Table 5-2).
        XCTAssertEqual(part(v, "S-IC").mass, 2_239_381 + 614 + 258 + 90, accuracy: 1e-6)
        XCTAssertEqual(v.tanks[0].mass, 1_468_594 + 235, accuracy: 1e-6)
        XCTAssertEqual(v.tanks[1].mass, 637_830, accuracy: 1e-6)
        XCTAssertEqual(pounds([part(v, "S-II")]) + 258 / lb, 1_058_140, accuracy: 1e-6)
        // The S-IVB's aft frame and detonation package (23 kg) are booked with
        // the aft interstage, which they leave with, and its ullage motors
        // (53 kg of grain, 61 kg of cases) on a part of their own.
        XCTAssertEqual(pounds(["S-IVB", "S-IVB ullage rockets"].map { part(v, $0) }) + (AS506.sIVBAftFrame + 90) / lb,
                       262_613, accuracy: 1e-6)
        XCTAssertEqual(pounds([part(v, "IU")]), 4_275, accuracy: 1e-6)
        // Independent, FER items against SP-4029 rows: the S-IC/S-II
        // interstage, 11,477 lb, is the ring, the large interstage and its
        // ullage motors' propellant (614 + 3,982 + 610 kg, Table 20-9); the
        // spacecraft, 109,646 lb, is the LES, CSM, LM and SLA (4,042 + 28,806
        // + 15,095 + 1,166 + 626 kg, Tables 20-7 and 20-9).
        XCTAssertEqual(pounds([part(v, "S-IC/S-II interstage")]) + 614 / lb, 11_477, accuracy: 1)
        // The aft interstage, 8,076 lb, is its structure and the S-II retros'
        // propellant (3,180 + 484 kg, Table 20-9): 1.7 lb more.
        XCTAssertEqual(pounds([part(v, "S-II/S-IVB interstage")]) - AS506.sIVBAftFrame / lb, 8_076, accuracy: 2)
        XCTAssertEqual(pounds(["SLA", "LM", "CSM", "LES"].map { part(v, $0) }), 109_646, accuracy: 1)
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
        // Each upper stage's length includes the interstage below it, as
        // MSFC-MAN-504 Figs 5-1 and 6-1 draw them (the S-II's 81-1/2 ft from
        // STA 1541 to 2519; the S-IVB's 59.0 ft with its 19 ft aft
        // interstage), against these News Reference lengths (the 281 ft is
        // recalled; the model is 1 in over).
        XCTAssertEqual(span(["S-IC/S-II interstage", "S-II"]), 81.5 * ft, accuracy: 0.3)
        XCTAssertEqual(span(["S-II/S-IVB interstage", "S-IVB"]), (58 * 12 + 7) * inch, accuracy: 0.3)
        XCTAssertEqual(span(["S-IC", "S-IC/S-II interstage", "S-II", "S-II/S-IVB interstage", "S-IVB", "IU"]),
                       281 * ft, accuracy: 0.3)
    }

    // B7: the J-2s and the interfaces around them at their published
    // stations. Independent (H): the S-II gimbal plane at S-II station 100,
    // STA 1664, and the S-IVB's at S-IVB station 100, STA 2645.85 (D5-15481-1
    // Fig. 3-1; Boeing's 1967 configuration diagram, NASA image 9253429, with
    // S-II station = STA - 1564 and S-IVB station = STA - 2545.85); the
    // S-IC/S-II interstage from the S-IC's forward skirt top, STA 1541
    // (MSFC-MAN-504 Fig 5-1), to the second separation plane, 1760; the
    // S-II's top, 2519; the S-II/S-IVB plane, 2746.5 (both planes also
    // MSFC-MAN-506 Fig 5-19). The nozzle exits, from FER-501 §12.2.3 and
    // §12.4.3 (16 in below the first plane; 217 in of travel to clear the
    // third), agree with the 116 ± 3 in from gimbal to exit measured on the
    // to-scale drawing in the News Reference's J-2 fact sheet, and lie inside
    // the interstages. REF504's S-II centre-of-pressure origin is that
    // gimbal plane.
    func testJ2GimbalsAtThePublishedStations() {
        let v = VesselLibrary.saturnV()
        func station(_ p: VesselPart, _ x: Double) -> Double { (p.offset.x + x - v.structureOrigin.x) / inch }
        func ends(_ name: String) -> [Double] {
            let p = part(v, name)
            return [station(p, -p.length / 2), station(p, p.length / 2)]
        }
        for (name, expected) in [("S-IC/S-II interstage", [1541, 1760]), ("S-II", [1760, 2519]),
                                 ("S-II/S-IVB interstage", [2519, 2746.5])] {
            for (a, b) in zip(ends(name), expected) { XCTAssertEqual(a, b, accuracy: 1e-6, name) }
        }
        for (stage, gimbal, exit) in [("S-II", 1664.0, 1548.0), ("S-IVB", 2645.85, 2529.5)] {
            let p = part(v, stage)
            let engines = p.thrusters.filter { $0.groups.contains(.main) }
            XCTAssertEqual(engines.count, stage == "S-II" ? 5 : 1)
            XCTAssertEqual(gimbal - exit, 116, accuracy: 3, stage)
            XCTAssertGreaterThan(exit, stage == "S-II" ? 1541 : 2519, stage)
            for e in engines {
                XCTAssertEqual(station(p, e.position.x), gimbal, accuracy: 1e-6, e.name)
                let bells = p.shapes.filter { s in
                    guard case .frustum(let r0, _) = s.kind else { return false }
                    return r0 < p.radius && s.origin.y == e.position.y && s.origin.z == e.position.z
                }
                XCTAssertEqual(bells.count, 1, e.name)
                for b in bells {
                    XCTAssertEqual(station(p, b.origin.x), exit, accuracy: 1e-6, e.name)
                    XCTAssertEqual(station(p, b.origin.x + b.length), gimbal, accuracy: 1e-6, e.name)
                }
            }
        }
        XCTAssertEqual(AS506.aerodynamics[1].referenceStation / inch, 1664, accuracy: 1e-9)
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

        // F-1 as flown (FER §5), per engine at first motion: a fifth of the
        // stage's vacuum thrust, 39.4549 MN (FER Figure 5-3's site thrust at
        // AS-506's pressure, M; `testF1ThrustFollowsFigure5_3`) at the level
        // of AS-506's measured acceleration (fitted, 0.22 % above the figure;
        // `AscentResidualTests`), and of its site flow, 13,165 kg/s (Figure
        // 5-3, M), with the fitted 0.062 % cut of the five-engine phase; the
        // mixture ratio, 2.2835, with its fitted 0.016 % one; a 10.10 m^2 exit
        // (derived from the figure).
        let f1 = AS506.f1
        XCTAssertEqual(AS506.sICThrustScale, 1.0022)
        XCTAssertEqual(f1.thrustVacuum, 39_454_900.0 / 5 * 1.0022, accuracy: 1e-6)
        XCTAssertEqual(f1.massFlow, 13_165.0 / 5 * 0.999385, accuracy: 1e-9)
        XCTAssertEqual(f1.impliedExitArea, 10.10, accuracy: 1e-9)
        let flight = run(f1, at: p0)
        XCTAssertEqual(flight.ox / flight.fuel, 2.2835 * 0.999840, accuracy: 1e-9)
        // Independent: Betts' rated vacuum Isp, 304.1 s, within 0.8 % over the
        // burn (thrust over flow; 306.5 s at first motion, where Figure 5-3's
        // thrust is 0.6 % above its flow times its own Isp) and within 0.3 %
        // on the burn's impulse over its propellant (304.7 s); the sea-level
        // Isp at first motion within 3 s of Betts' 265.4 s; the nozzle, (F_vac
        // - F_sl) / p0 = 9.93 m^2, within 2 %.
        var impulse = 0.0, propellant = 0.0
        for t in stride(from: 0.0, to: AS506.sICOutboardCutoff - AS506.firstMotion, by: 0.01) {
            let k = AS506.f1Schedule.values(at: t)
            XCTAssertEqual(k.thrust / k.flow * f1.ispVacuum, 304.1, accuracy: 304.1 * 8e-3, "\(t) s")
            impulse += k.thrust * f1.thrustVacuum
            propellant += k.flow * f1.massFlow
        }
        XCTAssertEqual(f1.ispVacuum, 306.5, accuracy: 0.05)
        XCTAssertEqual(impulse / propellant / g0, 304.1, accuracy: 304.1 * 3e-3)
        XCTAssertEqual(f1.ispSeaLevel, 265.4, accuracy: 3)
        XCTAssertEqual(f1.impliedExitArea, (1_748_200 - 1_522_000) * lbf / p0, accuracy: 9.93 * 0.02)
        // The schedule against the stage's site thrust in Figure 5-3 (M) as
        // the datasheet first read it (§9.2): about 34.35 MN at liftoff
        // (100.6 kPa ambient), 40.05 MN just before CECO and 32.07 MN at 160 s
        // (a few hundred Pa or less: vacuum thrust).
        func stage(_ engines: Double, at range: Double, pressure p: Double) -> Double {
            let factor = AS506.f1Schedule.values(at: range - AS506.firstMotion).thrust
            return engines * (f1.thrustVacuum * factor - p * f1.impliedExitArea)
        }
        XCTAssertEqual(stage(5, at: 0.30, pressure: 100_600), 34.35e6, accuracy: 34.35e6 * 0.01)
        XCTAssertEqual(stage(5, at: 135.20, pressure: 0), 40.05e6, accuracy: 40.05e6 * 3e-3)
        XCTAssertEqual(stage(4, at: 160, pressure: 0), 32.07e6, accuracy: 32.07e6 * 5e-3)

        // J-2 settings as flown, per engine: transcription checks. Every
        // setting shares the geometric exit, pi/4 (14.7 in throat, NASA
        // SP-8120)^2 x area ratio 27.5. The S-II's flows carry the fitted
        // 0.329 % cut that closes its budget.
        let j2Exit = Double.pi / 4 * (14.7 * inch) * (14.7 * inch) * 27.5
        let settings: [(EngineRating, thrust: Double, flow: Double, ratio: Double)] = [
            (AS506.sIIJ2Start, 878_288, 878_288 / 4_195 * 0.996709, 5.0),          // FER §6.2; MSFC-MAN-506 EMR
            (AS506.sIIJ2, 1_028_303, 1_028_303 / 4_164.9 * 0.996709, 5.5006),      // FER Table 6-1; EMR fitted
            (AS506.sIIJ2LowEMR, 772_750, 772_750 / 4_190 * 0.996709, 4.34),         // FER Figure 6-3, §6.5
            (AS506.sIVBJ2Burn1, 903_000, 215.37, 4.85),                            // FER Figure 7-2, Tables 20-9, 20-5
        ]
        for (rating, thrust, flow, ratio) in settings {
            let vacuum = run(rating, at: 0)
            XCTAssertEqual(vacuum.thrust, thrust, accuracy: thrust * 1e-12, rating.name)
            XCTAssertEqual(vacuum.ox + vacuum.fuel, flow, accuracy: 1e-9, rating.name)
            XCTAssertEqual(vacuum.ox / vacuum.fuel, ratio, accuracy: 1e-9, rating.name)
            XCTAssertEqual(rating.impliedExitArea, j2Exit, accuracy: j2Exit * 1e-9, rating.name)
            XCTAssertEqual(run(rating, at: p0).thrust, thrust - p0 * j2Exit, accuracy: 1e-6, rating.name)
        }
        // Independent: the S-II's high-EMR setting against the J-2's rating,
        // 230,000 lbf and 425 s at EMR 5.5 (NTRS 20100032986;
        // enginehistory.org), and against the FER's own flow at ESC + 61 s,
        // 246.9 kg/s (Table 6-1), which the budget's 0.33 % cut takes 0.8
        // kg/s below (so the Isp 1.1 s above); the S-IVB's against FER Table 7-1's
        // standardised 202,603 lbf (also This Day in Aviation; Braeunig) and
        // 4,204 N s/kg, the engine's own flow: the model's flow is Table
        // 20-9's mainstage consumption, venting included, so its Isp is 0.3 %
        // lower.
        XCTAssertEqual(AS506.sIIJ2.thrustVacuum, 230_000 * lbf, accuracy: 230_000 * lbf * 0.01)
        XCTAssertEqual(AS506.sIIJ2.ispVacuum, 425, accuracy: 1.5)
        XCTAssertEqual(AS506.sIIJ2.massFlow, 246.9, accuracy: 246.9 * 4e-3)
        XCTAssertEqual(AS506.sIVBJ2Burn1.thrustVacuum, 202_603 * lbf, accuracy: 202_603 * lbf * 3e-3)
        XCTAssertEqual(AS506.sIVBJ2Burn1.ispVacuum * g0, 4_204, accuracy: 4_204 * 5e-3)
    }

    // The F-1's thrust against FER Figure 5-3's stage thrust (reconstructed,
    // digitised: M), along AS-506's own path: at its altitude over the
    // Fischer ellipsoid (PFT Table B-II, Hermite between rows; 59.7 m at
    // first motion) and the launch day's pressure there, the schedule's
    // stage thrust, n (F_vac k(t) - p A_e), follows the figure's 0.5 s
    // samples, five engines to 134 s within 0.04 % rms and 0.18 % at most,
    // four from 137 to 160.5 s within 0.05 % and 0.13 % (the centre engine's
    // decay between, and the figure's hook before OECO, are not the
    // schedule's), and its impulse over each span within 0.01 %. A
    // data-entry check: the schedule's knots are fitted to these samples.
    func testF1ThrustFollowsFigure5_3() {
        typealias P = AS506Postflight
        let atmosphere = AS506.launchDayAtmosphere(), f1 = AS506.f1, rows = P.trajectory
        func altitude(_ t: Double) -> Double {
            let i = rows.firstIndex { $0.time >= t }!
            var r = rows[i].position
            if rows[i].time > t {
                let a = rows[i - 1], b = rows[i], h = b.time - a.time, u = (t - a.time) / h
                r = a.position * (2 * u * u * u - 3 * u * u + 1) + a.velocity * ((u * u * u - 2 * u * u + u) * h)
                    + b.position * (3 * u * u - 2 * u * u * u) + b.velocity * ((u * u * u - u * u) * h)
            }
            let z = r.dot(P.pole)
            return Ellipsoid.fischer1960.geodetic(Vec3((r - P.pole * z).length, 0, z)).height
        }
        XCTAssertEqual(altitude(AS506.firstMotion), 59.7, accuracy: 0.1)   // PFT Table B-III: 59 m
        for (span, engines, rmsLimit, maxLimit) in [(0.5...134.0, 5.0, 4e-4, 1.85e-3),
                                                    (137.0...160.5, 4.0, 5.1e-4, 1.35e-3)] {
            var residuals: [Double] = [], model = 0.0, figure = 0.0
            for s in P.sICThrust where span.contains(s.time) {
                let p = atmosphere.state(altitude: altitude(s.time)).pressure
                let k = AS506.f1Schedule.values(at: s.time - AS506.firstMotion).thrust
                let thrust = engines * (f1.thrustVacuum / AS506.sICThrustScale * k - p * f1.impliedExitArea)
                residuals.append(thrust / (s.thrust * 1e6) - 1)
                model += thrust
                figure += s.thrust * 1e6
            }
            let rms = (residuals.map { $0 * $0 }.reduce(0, +) / Double(residuals.count)).squareRoot()
            XCTAssertLessThan(rms, rmsLimit, "\(engines) engines")
            XCTAssertLessThan(residuals.map(abs).max()!, maxLimit, "\(engines) engines")
            XCTAssertEqual(model / figure, 1, accuracy: 1e-4, "\(engines) engines")
        }
        // At first motion: the pad's 101.2 kPa (the sounding at 59.7 m).
        let p = atmosphere.state(altitude: altitude(AS506.firstMotion)).pressure
        XCTAssertEqual(p, 101_220, accuracy: 50)
        XCTAssertEqual(5 * (f1.thrustVacuum / AS506.sICThrustScale - p * f1.impliedExitArea), 34.34e6,
                       accuracy: 0.01e6)
        // At OECO, past the figure's hook: AS-506's sensed acceleration then,
        // 38.61 m/s^2 (FER Table 4-1; the PFT's row: 38.61), over the FER's
        // 827,292 kg (Table 20-1), the thrust at the scaled level.
        let oeco = AS506.f1Schedule.values(at: AS506.sICOutboardCutoff - AS506.firstMotion).thrust
        XCTAssertEqual(4 * f1.thrustVacuum * oeco, 38.61 * 827_292, accuracy: 1)
    }

    // B2, transients: the impulse each start and shutdown ramp delivers, run
    // through the engines, against the FER's (H): F-1 centre engine from
    // its cutoff signal to zero thrust 2,659,605 N s, outboard engines from
    // OECO to separation 10,612,096 N s (§5.4); S-II start, 582 kg burned
    // from STDV open to mainstage (Table 20-9), and OECO cutoff 581,916 N s
    // to 5 % thrust (§6.4); S-IVB start, 857,243 N s from STDV open to STDV
    // + 2.5 s (§7.2), and cutoff 188,302 N s (§7.4).
    func testTransientImpulsesMatchTheFER() {
        let v = VesselLibrary.saturnV()
        func engines(_ part: String) -> [Thruster] {
            v.parts.first { $0.name == part }!.thrusters.filter { $0.groups.contains(.main) }
        }
        /// Vacuum impulse of `es` over `steps` 0.02 s steps.
        func impulse(_ es: [Thruster], steps: Int) -> Double {
            var j = 0.0
            for _ in 0..<steps {
                j += es.reduce(0) { $0 + $1.thrust(ambientPressure: 0, seaLevelPressure: 101_325) } * 0.02
                v.consumePropellant(dt: 0.02)
            }
            return j
        }
        let sIC = engines("S-IC")
        for e in sIC { e.level = 1 }
        var t = AS506.firstMotion
        while t < AS506.sICCenterCutoff - 1e-9 { v.consumePropellant(dt: 0.02); t += 0.02 }
        sIC[4].isEnabled = false
        XCTAssertEqual(impulse([sIC[4]], steps: 40), 2_659_605, accuracy: 2_659_605 * 0.01)
        while sIC[0].hasPropellant { v.consumePropellant(dt: 0.02) }
        XCTAssertEqual(impulse(Array(sIC.prefix(4)), steps: 40), 10_612_096, accuracy: 10_612_096 * 0.01)
        XCTAssertFalse(sIC.contains { $0.isDelivering })

        v.jettisonNextStage()
        let sII = engines("S-II"), tanks = v.tanks.filter { $0.name.hasPrefix("S-II L") }
        let loaded = tanks.reduce(0) { $0 + $1.mass }
        for e in sII { e.level = 1 }
        _ = impulse(sII, steps: 110)   // to 166.2 s
        XCTAssertEqual(loaded - tanks.reduce(0) { $0 + $1.mass }, 582, accuracy: 582 * 0.01)
        sII[4].isEnabled = false
        for e in sII { e.rating = AS506.sIIJ2LowEMR }
        _ = impulse(sII, steps: 50)
        for e in sII { e.level = 0 }
        XCTAssertEqual(impulse(sII, steps: 40), 581_916, accuracy: 581_916 * 0.01)

        for _ in 0..<3 { v.jettisonNextStage() }
        let j2 = engines("S-IVB")
        j2[0].level = 1
        XCTAssertEqual(impulse(j2, steps: 125), 857_243, accuracy: 857_243 * 0.01)
        _ = impulse(j2, steps: 50)
        j2[0].level = 0
        XCTAssertEqual(impulse(j2, steps: 40), 188_302, accuracy: 188_302 * 0.01)
        XCTAssertFalse(j2[0].isDelivering)
    }

    // A1 on the S-IC: with the centre engine cut at 135.20 s, the shared feed
    // runs out of LOX first, at exactly its unusable mass; then the outboard
    // engines' thrust decay burns below it, and they stop delivering.
    func testSICDrawStopsOnLOXDepletion() {
        let v = VesselLibrary.saturnV()
        let lox = v.tanks[0], rp1 = v.tanks[1]
        let mains = v.parts[0].thrusters.filter { $0.groups.contains(.main) }
        for e in mains { e.level = 1 }
        var t = AS506.firstMotion
        while t < AS506.sICCenterCutoff - 1e-9 { v.consumePropellant(dt: 0.02); t += 0.02 }
        // Consistency (the five-engine scales were fitted to them): at CECO
        // the tanks hold FER Table 5-2's reconstructed 216,633 kg of LOX and
        // 99,059 kg of RP-1, with Table 20-1's 2,809 kg of GOX. Bookkeeping:
        // the vehicle is 661 kg above Table 20-1's 1,110,189 kg, the frost and
        // purge gas AS-506 had shed by then (S-IC 295 + 16 kg, S-II 204 + 54
        // kg, S-IVB 90 kg), which the model's S-IC carries to its separation.
        XCTAssertEqual(lox.mass, 216_633 + 2_809, accuracy: 1)
        XCTAssertEqual(rp1.mass, 99_059, accuracy: 1)
        XCTAssertEqual(v.mass - 1_110_189, 661, accuracy: 3)
        mains[4].isEnabled = false
        while mains[0].hasPropellant && t < 200 { v.consumePropellant(dt: 0.02); t += 0.02 }
        XCTAssertEqual(lox.mass, lox.unusableMass)
        XCTAssertGreaterThan(rp1.usableMass, 0)
        XCTAssertEqual(v.mainDeltaV, 0)
        // Consistency (the flow and mixture-ratio scales were fitted to
        // them): LOX depletion at 161.63 s (FER Table 2-2), when the LOX tank
        // held 18,041 kg of liquid (Table 5-2) and 3,611 kg of GOX (Table
        // 20-1), and the RP-1 tank 13,954 kg (Table 5-2).
        XCTAssertEqual(t, 161.63, accuracy: 0.03)
        XCTAssertEqual(lox.mass, 18_041 + 3_611, accuracy: 1e-6)
        XCTAssertEqual(rp1.mass, 13_954, accuracy: 13_954 * 1e-3)
        // Independent: the outboard engines' thrust decay to separation
        // burned 3,634 kg (FER Table 20-9); the model's comes from their
        // cutoff impulse (FER §5.4).
        let left = lox.mass + rp1.mass
        for _ in 0..<34 { v.consumePropellant(dt: 0.02) }   // to 162.31 s
        XCTAssertFalse(mains.contains { $0.isDelivering })
        XCTAssertEqual(left - lox.mass - rp1.mass, 3_634, accuracy: 3_634 * 0.05)
    }

    // A2 on the S-II: a J-2 starts on its start setting, delivering nothing
    // for 1.09 s and full thrust from 2.2 s; assigning a rating mid-burn
    // changes thrust, flow and the drawn split together, and does not
    // restart it.
    func testSIIMixtureRatioShift() {
        let v = VesselLibrary.saturnV()
        let e = v.thrusters.first { $0.name == "S-II engine 1" }!
        let lox = v.tanks.first { $0.name == "S-II LOX" }!, lh2 = v.tanks.first { $0.name == "S-II LH2" }!
        func vacuumThrust() -> Double { e.thrust(ambientPressure: 0, seaLevelPressure: 101_325) }
        e.level = 1
        for _ in 0..<53 { v.consumePropellant(dt: 0.02) }   // the step from 1.06 s
        XCTAssertEqual(vacuumThrust(), 0)
        for _ in 0..<2 { v.consumePropellant(dt: 0.02) }    // from 1.10 s
        XCTAssertGreaterThan(vacuumThrust(), 0)
        for _ in 0..<55 { v.consumePropellant(dt: 0.02) }   // from 2.20 s
        XCTAssertEqual(vacuumThrust(), 878_288, accuracy: 1e-6)
        e.rating = AS506.sIIJ2
        XCTAssertEqual(vacuumThrust(), 1_028_303, accuracy: 1e-6)
        e.rating = AS506.sIIJ2LowEMR
        XCTAssertEqual(vacuumThrust(), 772_750, accuracy: 1e-6)
        XCTAssertEqual(e.massFlow, AS506.sIIJ2LowEMR.massFlow)
        let lox0 = lox.mass, lh20 = lh2.mass
        v.consumePropellant(dt: 1)
        XCTAssertEqual((lox0 - lox.mass) / (lh20 - lh2.mass), 4.34, accuracy: 1e-9)
        XCTAssertEqual(lox0 - lox.mass + lh20 - lh2.mass, e.massFlow, accuracy: 1e-9)
        XCTAssertEqual(e.burnTime, 3.2, accuracy: 1e-9)
    }

    // The S-II's low EMR against FER Figure 6-3's stage thrust
    // (reconstructed, digitised: M) and §6.3's text (H). The rating at the
    // PU valve step, carried by its decline (thrust and flow together, so
    // the Isp stays the rating's), is a line through the figure's samples
    // from 499.5 to 538 s within 0.1 % rms and 0.25 % at most, 0.10 % below
    // §6.3's 3,082,769 N at ESC + 351 s and 0.02 % below its 3,059,402 N at
    // ESC + 381 s (ESC 163.04 s); it holds after OECO. The figure's last 8 s,
    // traced 0.5 % below the line where its solid curve meets the dashed
    // prediction, are not the line's. The ramp from high EMR puts its middle
    // on AS-506's effective step, 498.8 s (the postflight trajectory,
    // datasheet §14.2), 1.2 s after the valve step; the figure's own step,
    // impulse for impulse, falls at 496.8 s, and its low EMR, 4.29-4.31, is
    // within 0.05 of §6.5's 4.34 average.
    func testSIILowEMRFollowsFigure6_3() {
        typealias P = AS506Postflight
        let low = AS506.sIIJ2LowEMR, decline = AS506.sIILowMixtureRatioDecline
        func stage(at t: Double) -> (thrust: Double, flow: Double) {
            let k = decline.values(at: t - AS506.sIIMixtureRatioShift)
            return (4 * low.thrustVacuum * k.thrust, 4 * low.massFlow * k.flow)
        }
        let samples = P.sIIThrust.filter { $0.time >= 499.5 && $0.time <= 538 }
        let residuals = samples.map { stage(at: $0.time).thrust / ($0.thrust * 1e6) - 1 }
        XCTAssertEqual(residuals.count, 78)
        XCTAssertLessThan((residuals.map { $0 * $0 }.reduce(0, +) / Double(residuals.count)).squareRoot(), 1e-3)
        XCTAssertLessThan(residuals.map(abs).max()!, 2.5e-3)
        XCTAssertEqual(stage(at: 163.04 + 351).thrust, 3_082_769, accuracy: 3_082_769 * 1.5e-3)
        XCTAssertEqual(stage(at: 163.04 + 381).thrust, 3_059_402, accuracy: 3_059_402 * 5e-4)
        let tail = P.sIIThrust.filter { $0.time > 540 }
        XCTAssertLessThan(tail.map { $0.thrust * 1e6 / stage(at: $0.time).thrust - 1 }.reduce(0, +) / Double(tail.count),
                          -3e-3)
        for t in stride(from: 497.6, through: 560, by: 2.5) {
            let s = stage(at: t)
            XCTAssertEqual(s.thrust / s.flow, low.thrustVacuum / low.massFlow, accuracy: 1e-9, "\(t) s")
        }
        XCTAssertEqual(stage(at: 560).thrust, stage(at: AS506.sIIOutboardCutoff).thrust, accuracy: 1e-6)
        XCTAssertEqual(AS506.sIIMixtureRatioShift + AS506.sIIMixtureRatioRamp / 2, 498.8, accuracy: 1e-9)
        // The figure's step: the high-EMR mean (486-493 s) and the low line,
        // the impulse between them from 490 to 505 s on the samples.
        let high = P.sIIThrust.filter { $0.time <= 493 }.map(\.thrust)
        let hi = high.reduce(0, +) / Double(high.count)
        let span = P.sIIThrust.filter { $0.time >= 490 && $0.time <= 505 }
        var excess = 0.0
        for (a, b) in zip(span, span.dropFirst()) {
            excess += ((a.thrust + b.thrust) / 2 * 1e6 - stage(at: (a.time + b.time) / 2).thrust) * (b.time - a.time)
        }
        let lo = stage(at: 490).thrust
        XCTAssertEqual(490 + excess / (hi * 1e6 - lo), 496.8, accuracy: 0.15)
        let emr = P.sIIMixtureRatio.filter { $0.time >= 500 }.map(\.ratio)
        XCTAssertEqual(emr.reduce(0, +) / Double(emr.count), AS506.sIILowMixtureRatio, accuracy: 0.05)
    }

    // B4: AS-506's sequence driven through the propellant model alone (no
    // trajectory), first motion to the end of the S-IVB's first thrust
    // decay, at the FER's event times (Table 2-2; the S-II ullage and EMR
    // events from T3, 161.66 s, Table 2-1): the vehicle against the FER's
    // event masses (Tables 20-1, 20-3, 20-5, 20-9), and its thrust
    // acceleration against the stage maxima of Table 4-1 (total inertial
    // acceleration; drag is negligible there) or Figure 4-3 (M).
    func testEventTimelineThroughThePropellantModel() {
        let v = VesselLibrary.saturnV()
        var t = AS506.firstMotion, acceleration = 0.0
        let t3 = AS506.timeBase3
        func engine(_ name: String) -> Thruster { v.thrusters.first { $0.name == name }! }
        func tank(_ name: String) -> PropellantTank { v.tanks.first { $0.name == name }! }
        /// Propellant left in a set of solid motors (a grain each).
        func grains(_ name: String) -> Double { v.tanks.filter { $0.name == name }.reduce(0) { $0 + $1.mass } }
        func mains() -> [Thruster] { v.activeStage!.thrusters.filter { $0.groups.contains(.main) } }
        func set(_ engines: [Thruster], _ level: Double) { for e in engines { e.level = level } }
        /// Range time `end`, or until a lit main engine runs dry (returns true).
        func burn(to end: Double) -> Bool {
            while t < end - 1e-9 {
                let h = min(0.02, end - t)
                acceleration = v.thrusters.reduce(0) { $0 + $1.thrust(ambientPressure: 0, seaLevelPressure: 101_325) }
                    / v.mass
                v.consumePropellant(dt: h)
                t += h
                if mains().contains(where: { $0.isEnabled && $0.level > 0 && !$0.hasPropellant }) { return true }
            }
            return false
        }
        // The S-IC's propellant is the FER's, and the S-IC carries the 661 kg
        // of frost and purge gas AS-506 had shed by CECO (Table 20-1) to its
        // separation, so 0.1 % there. After it the stack is the FER's within
        // 50 kg (the model has 3-34 kg; the upper stages' boil-off before
        // ignition and the S-IVB's fuel lead are not modelled).
        func mass(_ kg: Double, _ label: String, within tolerance: Double = 50) {
            XCTAssertEqual(v.mass, kg, accuracy: tolerance, label)
        }

        // S-IC: centre engine cut at 135.20 s, outboard engines to LOX depletion.
        set(mains(), 1)
        XCTAssertFalse(burn(to: AS506.sICCenterCutoff))
        mass(1_110_189, "S-IC CECO", within: 1_110)
        engine("S-IC engine 5").isEnabled = false
        XCTAssertTrue(burn(to: 170))
        // Consistency (the F-1's flow scales were fitted to it): 161.63 s.
        XCTAssertEqual(t, 161.63, accuracy: 0.03)
        mass(827_292, "S-IC OECO", within: 827)
        XCTAssertEqual(acceleration, 38.61, accuracy: 38.61 * 3e-3)   // 3.94 g

        // Thrust decay; the S-II ullage motors from T3 + 0.5 s; separation.
        set(mains(), 0)
        XCTAssertFalse(burn(to: t3 + AS506.sIIUllageIgnitionTime))
        for m in v.thrusters where m.name.hasPrefix("S-II ullage") { XCTAssertTrue(m.ignite()) }
        XCTAssertFalse(burn(to: AS506.sICSeparation))
        mass(823_625, "S-IC/S-II separation", within: 824)
        XCTAssertEqual(v.jettisonNextStage()?.parts.map(\.name), ["S-IC"])

        // S-II: engine start (solenoids) at 164.0 s, mainstage at 166.2 s,
        // the ullage motors out (309 kg left at engine start, Table 20-9);
        // high EMR at T3 + 6.9 s, interstage and LES jettison, CECO, low EMR
        // at the PU valve step, and LOX depletion.
        XCTAssertFalse(burn(to: AS506.sIIIgnition))
        mass(658_363, "S-II engine start")
        XCTAssertEqual(grains("S-II ullage"), 309, accuracy: 5)
        set(mains(), 1)
        XCTAssertFalse(burn(to: t3 + AS506.sIIUllageEndTime))
        XCTAssertEqual(grains("S-II ullage"), 0, accuracy: 1e-9)
        XCTAssertFalse(burn(to: 166.2))
        mass(657_459, "S-II mainstage")
        XCTAssertFalse(burn(to: t3 + AS506.sIIHighMixtureRatioTime))
        for e in mains() { e.rating = AS506.sIIJ2 }
        XCTAssertFalse(burn(to: AS506.interstageJettison))
        XCTAssertEqual(v.jettisonNextStage()?.parts.map(\.name), ["S-IC/S-II interstage"])
        XCTAssertFalse(burn(to: AS506.lesJettison))
        XCTAssertEqual(v.jettisonNextStage()?.parts.map(\.name), ["LES"])
        XCTAssertFalse(burn(to: AS506.sIICenterCutoff))
        XCTAssertEqual(acceleration, 17.84, accuracy: 17.84 * 3e-3)   // 1.82 g
        engine("S-II engine 5").isEnabled = false
        XCTAssertFalse(burn(to: AS506.sIIMixtureRatioShift))
        // The low EMR as the IU sets it: along the ramp, then Figure 6-3's decline.
        for e in mains() {
            e.setRating(AS506.sIIJ2LowEMR, ramp: AS506.sIIMixtureRatioRamp)
            e.schedule = AS506.sIILowMixtureRatioDecline.delayed(by: e.burnTime)
        }
        XCTAssertTrue(burn(to: 560))
        // Consistency (the S-II's flow scale and high EMR were fitted to
        // them): LOX depletion at 548.22 s (Table 2-2) with 3,353 kg of LH2
        // aboard, liquid and the GH2 made in flight (Table 20-3).
        XCTAssertEqual(t, 548.22, accuracy: 0.1)
        XCTAssertEqual(tank("S-II LOX").mass, tank("S-II LOX").unusableMass)
        XCTAssertEqual(tank("S-II LH2").mass, 3_353, accuracy: 3_353 * 1e-3)
        mass(213_888, "S-II OECO")
        XCTAssertEqual(acceleration, 14.3, accuracy: 14.3 * 0.01)   // Figure 4-3

        // Thrust decay; the S-IVB ullage motors from 548.9 s, separation at
        // 549.0 s; S-IVB burn 1 from 552.20 s (STDV open) to the guidance
        // cutoff at 699.34 s, with the ullage cases jettisoned at 561.0 s, and
        // its decay. AS-506's ullage motors had 10 kg left at STDV open and
        // 1 kg at mainstage (Table 20-9).
        set(mains(), 0)
        XCTAssertFalse(burn(to: 548.9))
        for m in v.thrusters where m.name.hasPrefix("S-IVB ullage") { XCTAssertTrue(m.ignite()) }
        XCTAssertFalse(burn(to: AS506.sIISeparation))
        mass(213_757, "S-II/S-IVB separation")
        XCTAssertEqual(v.jettisonNextStage()?.parts.map(\.name), ["S-II", "S-II/S-IVB interstage"])
        XCTAssertFalse(burn(to: AS506.sIVBIgnition))
        mass(166_571, "S-IVB ignition")
        XCTAssertEqual(grains("S-IVB ullage"), 10, accuracy: 3)
        set(mains(), 1)
        XCTAssertFalse(burn(to: 554.70))
        mass(166_396, "S-IVB mainstage")
        XCTAssertEqual(grains("S-IVB ullage"), 0, accuracy: 1)
        XCTAssertFalse(burn(to: 561.0))
        XCTAssertEqual(v.jettisonNextStage()?.mass ?? 0, AS506.sIVBUllageMotorCases, accuracy: 1e-9)
        XCTAssertFalse(burn(to: 699.34))
        mass(135_182, "S-IVB cutoff")
        // Figure 4-3 (M) rather than Table 4-1's 6.73 m/s^2, which is more
        // than the S-IVB's thrust (FER Figure 7-2) over the tabulated mass.
        XCTAssertEqual(acceleration, 6.69, accuracy: 6.69 * 5e-3)
        set(mains(), 0)
        XCTAssertFalse(burn(to: 699.54))
        mass(135_102, "S-IVB end of thrust decay")
        XCTAssertEqual(v.parts.map(\.name), ["S-IVB", "IU", "SLA", "LM", "CSM"])
    }
}
