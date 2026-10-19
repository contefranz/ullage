import XCTest
@testable import OrbitCore

/// The Apollo command module against its Mission Report mass rows: Apollo 7
/// (MSC-PA-R-68-15) Table A.5-I rows 19-24 and Apollo 11 (MSC-00171) Table
/// A-I, transcribed by two readers (tools/data/a07_mr_table_a5_1.csv,
/// a11_mr_table_a_1.csv), the ELS items against TN D-7437, and the CM RCS
/// against the AOH's engine map (Fig. 2.5-1).
final class CommandModuleTests: XCTestCase {
    let lb = 0.45359237, inch = 0.0254, slugFt2 = 1.3558179483

    // The CM as built is the "after CM/SM separation" row, in construction
    // axes: weight, CG and the full inertia tensor, the products +∫xy dm in
    // Apollo axes. The expected values are the CSVs' SI columns, so the
    // units, the Y_A, Z_A -> -y, -z flip and the products' signs are
    // checked against the transcription, not against the model's own data.
    func testBuiltAtTheSeparationRow() {
        // mass kg; x m (Saturn station 2756.56 + X_A), y, z m; I_xx, I_yy,
        // I_zz, I_xy, I_xz, I_yz kg m^2 (Apollo axes, +∫xy dm).
        let rows: [(ApolloCM.Mission, Double, Vec3, [Double])] = [
            (.apollo7, 5_608.21606, Vec3(26.43632, -0.00508, 0.1524),
             [7_862.38828, 7_067.87896, 6_433.35616, 56.9443538, -573.510992, 40.6745384]),
            (.apollo11, 5_491.82426, Vec3(26.42616, -0.00508, 0.1524),
             [8_487.42036, 7_416.32418, 6_772.31065, 74.5699872, -546.394633, -63.7234436]),
        ]
        for (mission, mass, apollo, i) in rows {
            let v = VesselLibrary.commandModule(mission)
            XCTAssertEqual(v.mass, mass, accuracy: 1e-5, "\(mission)")
            let cg = v.structuralCenterOfMass
            XCTAssertEqual(cg.x, apollo.x + 2_756.56 * inch, accuracy: 1e-9, "\(mission)")
            XCTAssertEqual(cg.y, -apollo.y, accuracy: 1e-9, "\(mission)")
            XCTAssertEqual(cg.z, -apollo.z, accuracy: 1e-9, "\(mission)")
            // The lift side: Z_A +6 in is -z in the stack's frame.
            XCTAssertLessThan(cg.z, 0)
            let t = v.inertia
            let expected = Mat3(rows: Vec3(i[0], i[3], i[4]), Vec3(i[3], i[1], -i[5]), Vec3(i[4], -i[5], i[2]))
            for r in 0..<3 {
                for c in 0..<3 {
                    XCTAssertEqual(t[r, c], expected[r, c], accuracy: 1e-4, "\(mission) I[\(r),\(c)]")
                }
            }
        }
    }

    // The main pack is what leaves between the main-deploy and landing rows:
    // the main deploy row less the pack gives the landing row on both
    // missions (the pack is the two missions' mean): weight to 0.2 lb, CG to
    // 0.1 in, moments to 0.5 %, products to 6 slug ft^2 (the rows print the
    // CG to 0.1 in). The rows' landing weight is the CM afloat, without its
    // mains (the drop sits at X_A 1088-1091, in the forward compartment).
    func testMainPackClosesTheLandingRows() throws {
        for mission in ApolloCM.Mission.allCases {
            let parts = VesselLibrary.commandModuleParts(mission)
            let pack = try XCTUnwrap(parts.first { $0.name == "Main parachutes" })
            let main = try XCTUnwrap(ApolloCM.row(mission, .mainDeploy))
            let landing = try XCTUnwrap(ApolloCM.row(mission, .landing))
            let pm = pack.mass, pc = pack.offset + pack.centerOfMass
            let m = main.mass - pm
            let c = (main.centerOfMass * main.mass - pc * pm) / m
            let i = main.inertia + .parallelAxis(mass: main.mass, offset: main.centerOfMass - c)
                + (pack.localInertia + .parallelAxis(mass: pm, offset: pc - c)) * -1
            XCTAssertEqual(m / lb, landing.weight, accuracy: 0.2, "\(mission)")
            XCTAssertEqual((c - landing.centerOfMass).length / inch, 0, accuracy: 0.1, "\(mission)")
            let e = landing.inertia
            for k in 0..<3 {
                XCTAssertEqual(i[k, k], e[k, k], accuracy: 0.005 * e[k, k], "\(mission) I[\(k),\(k)]")
            }
            for (r, k) in [(0, 1), (0, 2), (1, 2)] {
                XCTAssertEqual(i[r, k], e[r, k], accuracy: 6 * slugFt2, "\(mission) I[\(r),\(k)]")
            }
        }
    }

    // The drogues weigh TN D-7437's 2 x 37.4 lb, within Apollo 7's 81 lb drop
    // from drogue deploy to main deploy (the rest is propellant and
    // ablator). The apex cover leaves before the drogue-deploy rows: both
    // missions' drops to them exceed it, and with the cover taken out at its
    // station the rest of each drop sits on the aft heat shield and the RCS
    // tanks: aft of X_A 1035, and not aft of the ablator's outer face (X_A
    // 1000 less up to 2.7 in of ablator, TN D-5399; the rows' 0.1 in CG
    // rounding moves it by about 3 in).
    func testDroguesAndApexCoverInTheRowDrops() throws {
        let parts = VesselLibrary.commandModuleParts(.apollo7)
        let drogues = try XCTUnwrap(parts.first { $0.name == "Drogue parachutes" })
        let cover = try XCTUnwrap(parts.first { $0.name == "Apex cover" })
        XCTAssertEqual(drogues.mass / lb, 74.8, accuracy: 1e-9)
        let a7 = ApolloCM.apollo7Rows, a11 = ApolloCM.apollo11Rows
        let drop = try XCTUnwrap(a7[.drogueDeploy]).weight - XCTUnwrap(a7[.mainDeploy]).weight
        XCTAssertEqual(drop - drogues.mass / lb, 3, accuracy: 4)
        let coverWeight = cover.mass / lb
        let coverX = (cover.offset + cover.centerOfMass).x / inch - 2_756.56
        for (before, after) in [(try XCTUnwrap(a7[.mach10]), try XCTUnwrap(a7[.drogueDeploy])),
                                (try XCTUnwrap(a11[.entryInterface]), try XCTUnwrap(a11[.drogueDeploy]))] {
            let w = before.weight - after.weight
            XCTAssertGreaterThan(w, coverWeight)
            let restX = (before.weight * before.xa - after.weight * after.xa - coverWeight * coverX) / (w - coverWeight)
            XCTAssertLessThan(restX, 1_035)
            XCTAssertGreaterThan(restX, 990)
        }
    }

    // Space separates the apex cover (30), the drogues (31) and the mains
    // (32), in that order, each as debris; the CM stays, and then nothing
    // separates. The cover leaves forward at its 3 m/s.
    func testELSPartsSeparateInOrder() throws {
        let v = VesselLibrary.commandModule(.apollo7)
        XCTAssertEqual(v.parts.map(\.name), ["CM", "Apex cover", "Drogue parachutes", "Main parachutes"])
        let total = v.mass
        let cover = try XCTUnwrap(v.jettisonNextStage())
        XCTAssertEqual(cover.name, "Apollo 7 – Apex cover")
        let dv = v.attitude.inverseRotate(cover.velocity - v.velocity)
        XCTAssertEqual(dv.length, 3, accuracy: 1e-9)
        XCTAssertGreaterThan(dv.x, 2.9)
        XCTAssertEqual(try XCTUnwrap(v.jettisonNextStage()).name, "Apollo 7 – Drogue parachutes")
        XCTAssertEqual(try XCTUnwrap(v.jettisonNextStage()).name, "Apollo 7 – Main parachutes")
        XCTAssertEqual(v.parts.map(\.name), ["CM"])
        XCTAssertNil(v.jettisonNextStage())
        XCTAssertEqual((total - v.mass) / lb, 260 + 74.8 + 446, accuracy: 1e-6)
    }

    // Twelve SE-8 jets of 93 lbf in two systems, named "CM RCS 1A"-"6A" and
    // "1B"-"6B" after the AOH's engines 11-16 and 21-26. Each one's torque,
    // in Apollo axes, has the sign its AOH label gives (1 +roll, 2 -roll,
    // 3 +pitch, 4 -pitch, 5 +yaw, 6 -yaw), and its body group follows: Y_A
    // and Z_A are -y and -z, so Apollo +pitch is the body's pitch down. Not
    // `activeStageOnly`, and armed by CM/SM separation (event 7) in a stack.
    func testCMRCSFollowsTheAOHEngineMap() throws {
        let parts = VesselLibrary.commandModuleParts(.apollo7)
        let cm = try XCTUnwrap(parts.first { $0.name == "CM" })
        XCTAssertEqual(cm.thrusters.map(\.name),
                       ["1A", "2A", "3A", "4A", "5A", "6A", "1B", "2B", "3B", "4B", "5B", "6B"].map { "CM RCS \($0)" })
        for t in cm.thrusters {
            XCTAssertFalse(t.activeStageOnly, t.name)
            XCTAssertFalse(t.isEnabled, t.name)
            XCTAssertEqual(t.trigger, .event(7), t.name)
            XCTAssertEqual(t.maxThrustVacuum, 93 * 4.4482216152605, accuracy: 1e-9)
            XCTAssertTrue(t.groups.isDisjoint(with: [.main, .retro, .hover, .translateForward, .translateBack,
                                                     .translateLeft, .translateRight, .translateUp, .translateDown]))
        }
        XCTAssertNil(parts.first { $0.thrusters.contains { $0.groups.contains(.main) } })

        let v = VesselLibrary.commandModule(.apollo7)
        let expected: [Character: (axis: Int, sign: Double, group: ThrusterGroup)] = [
            "1": (0, 1, .rollRight), "2": (0, -1, .rollLeft), "3": (1, 1, .pitchDown),
            "4": (1, -1, .pitchUp), "5": (2, 1, .yawLeft), "6": (2, -1, .yawRight),
        ]
        let com = v.centerOfMass
        for part in v.parts {
            for t in part.thrusters {
                XCTAssertTrue(t.isEnabled, t.name)
                let e = try XCTUnwrap(expected[t.name.dropLast().last!], t.name)
                let body = (t.position + part.offset - com).cross(t.direction)
                let apollo = [body.x, -body.y, -body.z]
                XCTAssertEqual(apollo[e.axis].sign == .minus ? -1.0 : 1.0, e.sign, t.name)
                for k in 0..<3 where k != e.axis { XCTAssertLessThan(abs(apollo[k]), abs(apollo[e.axis]), t.name) }
                XCTAssertEqual(t.groups, [e.group], t.name)
            }
        }
        // Loads: Apollo 7 §5.21 (263.9 lb), Apollo 11 §8.11 (245.9 lb).
        XCTAssertEqual(v.tanks.reduce(0) { $0 + $1.mass } / lb, 263.9, accuracy: 1e-9)
        let a11 = VesselLibrary.commandModule(.apollo11)
        XCTAssertEqual(a11.tanks.reduce(0) { $0 + $1.mass } / lb, 245.9, accuracy: 1e-9)

        // With no part carrying `.main` the jets still respond: a pilot's
        // +pitch (crew axes) fires both systems' +pitch engines and no other.
        XCTAssertNil(v.activeStage)
        let authority = v.rcsAuthority()
        XCTAssertGreaterThan(min(authority.x, authority.y, authority.z), 500)
        v.setPilotInput(rotation: RotationCommand(pitch: 1), translation: .zero)
        v.applyControls(rotation: v.rotationInput)
        let firing = v.thrusters.filter { $0.level > 0 }.map(\.name)
        XCTAssertEqual(firing, ["CM RCS 3A", "CM RCS 3B"])
    }
}
