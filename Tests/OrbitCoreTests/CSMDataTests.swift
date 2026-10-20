import XCTest
@testable import OrbitCore

/// The CSM's propulsion against its sources (`ApolloCSM`, track C): the SPS
/// as MSC IN 68-FM-184 Table I(b) rates it and the Apollo Operations
/// Handbook (AOH, SM2A-03-BLOCK II-(1)) §2.4 lays it out, and the SM RCS
/// quads as AOH §2.5 and Fig. 2.5-1 number them. Expected values are
/// literals in the published unit with their source.
final class CSMDataTests: XCTestCase {
    let lb = 0.45359237, lbf = 4.4482216152605, g0 = 9.80665, deg = Double.pi / 180

    func sm(_ v: Vessel) -> VesselPart { v.parts.first { $0.name == "SM" }! }
    func thruster(_ v: Vessel, _ name: String) -> Thruster { v.thrusters.first { $0.name == name }! }

    // 68-FM-184 Table I(b): 21,080 lbf at 312.34 s, 67.49 lb/s; the
    // build-up and tail-off delta Ts as the ramps' lengths;
    // oxidizer/fuel 1.6 (AOH p. 2.4-1); the nozzle's 98.4 in exit (AOH p.
    // 2.4-43). The tanks: Apollo 11's four lumped per propellant at AOH p.
    // 2.4-42's capacities (oxidizer 11,284.69 + 13,923.72, fuel 7,058.36 +
    // 8,708.10 lb) with the lines' 124 and 79 lb, loaded as its Mission
    // Report §8.11 says (25,091 and 15,712 lb); Apollo 7's in its sumps,
    // with its §5.21 loads (6,026.7 and 3,710.6 lb). The SPS is the SM's
    // main engine, on/off, and draws from the SM's own tanks.
    func testSPSRatingAndTanks() {
        let v = VesselLibrary.apolloCSM(.apollo11)
        let sps = thruster(v, "SPS")
        XCTAssertEqual(sps.rating.thrustVacuum / lbf, 21_080, accuracy: 1e-6)
        XCTAssertEqual(sps.rating.ispVacuum, 312.34, accuracy: 1e-9)
        XCTAssertEqual(sps.rating.massFlow / lb, 67.49, accuracy: 0.005)
        XCTAssertEqual(sps.rating.mixtureRatio, 1.6)
        XCTAssertEqual(sps.rating.impliedExitArea, Double.pi * pow(98.4 / 2 * 0.0254, 2), accuracy: 1e-9)
        XCTAssertEqual(sps.groups, [.main])
        XCTAssertEqual(sps.throttleRange, 1...1)
        let tr = try! XCTUnwrap(sps.transients)
        XCTAssertEqual(tr.startDelay, 0)
        XCTAssertEqual(tr.startRise, 0.015, accuracy: 1e-12)
        XCTAssertEqual(tr.shutdown, 0.54, accuracy: 1e-12)
        XCTAssertTrue(v.activeStage === sm(v))
        let tanks = sm(v).tanks
        XCTAssertEqual(tanks.filter { $0.name.hasPrefix("SPS") }.map(\.name), ["SPS oxidizer", "SPS fuel"])
        let ox = tanks.first { $0.name == "SPS oxidizer" }!, fuel = tanks.first { $0.name == "SPS fuel" }!
        XCTAssertEqual(ox.capacity / lb, 11_284.69 + 13_923.72 + 124, accuracy: 1e-6)
        XCTAssertEqual(fuel.capacity / lb, 7_058.36 + 8_708.10 + 79, accuracy: 1e-6)
        XCTAssertEqual(ox.mass / lb, 25_091, accuracy: 1e-6)
        XCTAssertEqual(fuel.mass / lb, 15_712, accuracy: 1e-6)
        XCTAssertEqual(ox.lineMass / lb, 124, accuracy: 1e-9)
        if case .bipropellant(let o, let f)? = sps.feed {
            XCTAssertTrue(o === ox && f === fuel)
        } else { XCTFail("the SPS has a bipropellant feed") }

        let a7 = VesselLibrary.apolloCSM(.apollo7)
        let ox7 = sm(a7).tanks.first { $0.name == "SPS oxidizer" }!, fuel7 = sm(a7).tanks.first { $0.name == "SPS fuel" }!
        XCTAssertEqual(ox7.capacity / lb, 13_923.72 + 123.7, accuracy: 1e-6)
        XCTAssertEqual(fuel7.capacity / lb, 8_708.10 + 78.6, accuracy: 1e-6)
        XCTAssertEqual(ox7.mass / lb, 6_026.7, accuracy: 1e-6)
        XCTAssertEqual(fuel7.mass / lb, 3_710.6, accuracy: 1e-6)
        // The oxidizer is on the +Y_A side (-y), the fuel on the -Y_A side.
        XCTAssertLessThan(ox7.centroid!.y, -0.9)
        XCTAssertGreaterThan(fuel7.centroid!.y, 0.9)
    }

    // AOH pp. 2.4-14, 2.4-15 and 2.4-44: ±4.5° in pitch and yaw about the
    // thrusting nulls, which lean the thrust 2° towards +Z_A and 1° towards
    // +Y_A for the offset centre of mass, at 0.12 rad/s. In construction
    // axes +Z_A is -z and +Y_A is -y; the gimbal starts at its nulls.
    func testSPSGimbalAboutItsThrustingNulls() {
        let sps = thruster(VesselLibrary.apolloCSM(.apollo11), "SPS")
        XCTAssertEqual(sps.gimbal.count, 2)
        let pitch = sps.gimbal[0], yaw = sps.gimbal[1]
        XCTAssertEqual(pitch.tilt, Vec3(0, 0, -1))
        XCTAssertEqual(yaw.tilt, Vec3(0, -1, 0))
        for (a, null) in [(pitch, 2.0), (yaw, 1.0)] {
            XCTAssertEqual(a.bias / deg, null, accuracy: 1e-12)
            XCTAssertEqual(a.angle, a.bias)
            XCTAssertEqual(a.range.lowerBound / deg, null - 4.5, accuracy: 1e-12)
            XCTAssertEqual(a.range.upperBound / deg, null + 4.5, accuracy: 1e-12)
            XCTAssertEqual(a.travel / deg, 4.5, accuracy: 1e-12)
            XCTAssertEqual(a.rateLimit, 0.12)
        }
        let d = sps.thrustDirection
        XCTAssertLessThan(d.z, 0)
        XCTAssertLessThan(d.y, 0)
        XCTAssertEqual(atan(-d.z / d.x) / deg, 2, accuracy: 1e-9)
        XCTAssertEqual(atan(-d.y / d.x) / deg, 1, accuracy: 1e-9)
    }

    // AOH p. 2.5-2 (Fig. 2.5-1): each quad's 1 is the clockwise +roll jet
    // and 2 the counterclockwise -roll; 3 and 4 are +pitch and -pitch on
    // quads A and C, +yaw and -yaw on B and D (rotations about +X_A, +Y_A
    // and +Z_A). In construction axes +pitch about Y_A is pitch down about
    // y, +yaw about Z_A is yaw left. The quads sit 90° apart, 7°15′ off the
    // ±Y_A/±Z_A axes (A at -Z_A towards -Y_A, B at +Y_A towards -Z_A, C at
    // +Z_A towards +Y_A, D at -Y_A towards +Z_A; AOH p. 2.5-1 and Fig.
    // 2.4-3). Every jet is in exactly one rotation group and one
    // translation group, and is `activeStageOnly`.
    func testSMRCSQuadsFollowTheAOH() {
        let v = VesselLibrary.apolloCSM(.apollo11)
        let jets = sm(v).thrusters.filter { $0.name.hasPrefix("SM RCS") }
        XCTAssertEqual(jets.count, 16)
        let rotation: Set<ThrusterGroup> = [.rollLeft, .rollRight, .pitchUp, .pitchDown, .yawLeft, .yawRight]
        let translation: Set<ThrusterGroup> = [.translateForward, .translateBack, .translateLeft, .translateRight,
                                               .translateUp, .translateDown]
        for t in jets {
            XCTAssertEqual(t.groups.intersection(rotation).count, 1, t.name)
            XCTAssertEqual(t.groups.intersection(translation).count, 1, t.name)
            XCTAssertEqual(t.groups.count, 2, t.name)
            XCTAssertTrue(t.activeStageOnly, t.name)
            XCTAssertEqual(t.rating.thrustVacuum / lbf, 99.8, accuracy: 1e-9)
        }
        let expected: [String: ThrusterGroup] = [
            "A1": .rollRight, "A2": .rollLeft, "A3": .pitchDown, "A4": .pitchUp,
            "B1": .rollRight, "B2": .rollLeft, "B3": .yawLeft, "B4": .yawRight,
            "C1": .rollRight, "C2": .rollLeft, "C3": .pitchDown, "C4": .pitchUp,
            "D1": .rollRight, "D2": .rollLeft, "D3": .yawLeft, "D4": .yawRight,
        ]
        for (name, group) in expected {
            XCTAssertTrue(thruster(v, "SM RCS \(name)").groups.contains(group), name)
        }
        // Where the quads are, in Apollo axes: angle from +Y_A towards +Z_A.
        for (quad, angle) in [("A", 262.75), ("B", 352.75), ("C", 82.75), ("D", 172.75)] {
            let p = thruster(v, "SM RCS \(quad)1").position + sm(v).offset - v.structureOrigin
            XCTAssertEqual(atan2(-p.z, -p.y) / deg, angle > 180 ? angle - 360 : angle, accuracy: 1e-9, quad)
            XCTAssertEqual(p.x / 0.0254 - AS506.apolloStationOffset, 959, accuracy: 1e-9)
        }
        // Each rotation group's jets push no net force and turn the CSM
        // about their own axis (the quads' 7°15′ offset leaves the other
        // axis 13 % of it); each translation group's push no net torque
        // about the axis at the quads' station.
        let station = thruster(v, "SM RCS A1").position
        for g in rotation {
            let set = jets.filter { $0.groups.contains(g) }
            XCTAssertEqual(set.count, g == .rollLeft || g == .rollRight ? 4 : 2, "\(g)")
            let force = set.reduce(Vec3.zero) { $0 + $1.direction }
            XCTAssertLessThan(force.length, 1e-12, "\(g)")
            let torque = set.reduce(Vec3.zero) { $0 + ($1.position - Vec3(station.x, 0, 0)).cross($1.direction) }
            let axis: Vec3 = [.rollLeft, .rollRight].contains(g) ? .unitX : [.pitchUp, .pitchDown].contains(g) ? .unitY : .unitZ
            let sign: Double = [.rollRight, .pitchUp, .yawRight].contains(g) ? 1 : -1
            let along = torque.dot(axis) * sign, across = (torque - axis * torque.dot(axis)).length
            XCTAssertGreaterThan(along, 0, "\(g)")
            XCTAssertEqual(across / along, [.rollLeft, .rollRight].contains(g) ? 0 : tan(7.25 * deg), accuracy: 1e-9, "\(g)")
        }
        for g in translation {
            let set = jets.filter { $0.groups.contains(g) }
            let torque = set.reduce(Vec3.zero) { $0 + ($1.position - Vec3(station.x, 0, 0)).cross($1.direction) }
            XCTAssertLessThan(torque.length, 1e-9, "\(g)")
        }
    }

    // 68-FM-184 Table I(b): four jets along +X give 399.2 lbf at 276.0 s,
    // 1.45 lb/s; oxidizer/fuel 2 (AOH §2.5). Each quad has its own tanks,
    // loaded as the Mission Reports say: Apollo 11 110 lb of fuel and 225
    // lb of oxidizer per quad (§8.11), Apollo 7 443.3 and 898.4 lb in all
    // (§5.21).
    func testFourJetsAlongXGive399LbfAt276s() {
        let v = VesselLibrary.apolloCSM(.apollo11)
        let forward = v.thrusters.filter { $0.groups.contains(.translateForward) }
        XCTAssertEqual(forward.map(\.name).sorted(), ["SM RCS A4", "SM RCS B4", "SM RCS C3", "SM RCS D3"])
        XCTAssertEqual(forward.reduce(0) { $0 + $1.rating.thrustVacuum * $1.direction.x } / lbf, 399.2, accuracy: 1e-9)
        XCTAssertEqual(forward.reduce(0) { $0 + $1.rating.massFlow } / lb, 1.45, accuracy: 0.005)
        for t in forward { XCTAssertEqual(t.rating.ispVacuum, 276.0) }
        XCTAssertEqual(forward[0].rating.mixtureRatio, 2.0)
        let rcs = sm(v).tanks.filter { $0.name.hasPrefix("SM RCS") }
        XCTAssertEqual(rcs.count, 8)
        XCTAssertEqual(rcs.filter { $0.name == "SM RCS fuel" }.map { $0.mass / lb }, [110, 110, 110, 110])
        XCTAssertEqual(rcs.filter { $0.name == "SM RCS ox" }.map { $0.mass / lb }, [225, 225, 225, 225])
        let a7 = sm(VesselLibrary.apolloCSM(.apollo7)).tanks.filter { $0.name.hasPrefix("SM RCS") }
        XCTAssertEqual(a7.filter { $0.name == "SM RCS fuel" }.reduce(0) { $0 + $1.mass } / lb, 443.3, accuracy: 1e-9)
        XCTAssertEqual(a7.filter { $0.name == "SM RCS ox" }.reduce(0) { $0 + $1.mass } / lb, 898.4, accuracy: 1e-9)
        // Each jet draws from its own quad's tanks.
        for t in v.thrusters where t.name.hasPrefix("SM RCS") {
            for tank in t.feed?.tanks ?? [] { XCTAssertTrue(sm(v).tanks.contains { $0 === tank }) }
        }
    }

    // The SM jettison controller (MSC-03466 p. 1): the four -X jets from
    // the SM's separation to propellant depletion, the four roll jets from
    // 2 s for 5.5 s. They are staged by the SM's own separation.
    func testJettisonControllerSequences() {
        let v = VesselLibrary.apolloCSM(.apollo11)
        let back = v.thrusters.filter { $0.groups.contains(.translateBack) }
        XCTAssertEqual(back.map(\.name).sorted(), ["SM RCS A3", "SM RCS B3", "SM RCS C4", "SM RCS D4"])
        for t in back {
            XCTAssertEqual(t.trigger, .ownSeparation)
            XCTAssertEqual(t.sequence, FiringSequence(start: 0, duration: nil))
        }
        let roll = v.thrusters.filter { t in t.sequence != nil && !back.contains { $0 === t } }
        XCTAssertEqual(roll.map(\.name).sorted(), ["SM RCS A1", "SM RCS B1", "SM RCS C1", "SM RCS D1"])
        for t in roll {
            XCTAssertEqual(t.trigger, .ownSeparation)
            XCTAssertEqual(t.sequence, FiringSequence(start: 2, duration: 5.5))
        }
        XCTAssertEqual(v.thrusters.filter { $0.sequence != nil }.count, 8)
    }

    // The CM RCS (track E2's) is disabled until event 7, CM/SM separation,
    // arms it; the SM's own separation (event 7) is the SM's.
    func testCMRCSIsDisabledUntilEvent7() {
        let v = VesselLibrary.apolloCSM(.apollo11)
        let cm = v.thrusters.filter { $0.name.hasPrefix("CM RCS") }
        XCTAssertEqual(cm.count, 12)
        for t in cm {
            XCTAssertFalse(t.isEnabled, t.name)
            XCTAssertEqual(t.trigger, .event(7))
            XCTAssertFalse(t.activeStageOnly)
        }
        XCTAssertEqual(sm(v).staging, .event(7))
        XCTAssertEqual(v.parts.first { $0.name == "CM" }?.staging, .fixed)
        XCTAssertTrue(v.parts.first { $0.name == "CM" }!.isCrewed)
        let spent = v.jettison(event: 7)
        XCTAssertEqual(spent?.parts.map(\.name), ["SM"])
        for t in cm { XCTAssertTrue(t.isEnabled, t.name) }
    }

    // On the Saturn stack the S-IVB is the active stage, so every SM RCS jet
    // stays silent whatever the controls command, while the S-IVB's APS,
    // the active stage's, flies them; the SPS is not the active stage's
    // main engine, so the main throttle never reaches it.
    func testSMRCSIsSilentOnTheSaturnStack() {
        let v = VesselLibrary.saturnV()
        for n in 1...5 { v.jettison(event: n) }
        XCTAssertEqual(v.activeStage?.name, "S-IVB")
        v.mainThrottle = 1
        v.translationInput = Vec3(1, 1, 1)
        v.applyControls(rotation: RotationCommand(roll: 1, pitch: 1, yaw: 1))
        for t in v.thrusters where t.name.hasPrefix("SM RCS") || t.name == "SPS" {
            XCTAssertEqual(t.level, 0, t.name)
            XCTAssertFalse(t.isCommanded, t.name)
        }
        XCTAssertTrue(v.thrusters.contains { $0.name.hasPrefix("APS") && $0.level > 0 })
        XCTAssertEqual(v.thrusters.first { $0.name == "S-IVB engine" }?.level, 1)
    }
}
