import XCTest
@testable import OrbitCore

/// Staging rules and construction coordinates through burns and separations
/// (design tests A11, A12), on `Toy.stack`.
final class StagingTests: XCTestCase {
    /// Construction station of each `Toy.stack` part's offset (its mid-station).
    let stations: [String: Double] = ["Booster": 10, "Interstage": 21, "Core": 32, "Adapter": 43,
                                      "Upper": 54, "Payload": 66, "Tower": 71]

    // A12: Space separates the lowest pending event group; `.fixed` parts stay.
    func testEventGroupsSeparateInOrder() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.stack()
        sim.add(v)
        sim.placeInCircularOrbit(v, around: sim.system.earth, altitude: 400_000)
        let m = v.mass, p = v.velocity * m
        var separated: [[String]] = []
        var ahead: [Double] = []
        while let spent = sim.stage(v) {
            separated.append(spent.parts.map(\.name))
            XCTAssertEqual(spent.name, "Toy stack – \(spent.parts[0].name)")
            ahead.append(v.attitude.inverseRotate(spent.position - v.position).x)
            // Debris does not split again.
            XCTAssertNil(sim.stage(spent))
        }
        XCTAssertEqual(separated, [["Booster"], ["Interstage"], ["Tower"], ["Core", "Adapter"]])
        XCTAssertEqual(v.parts.map(\.name), ["Upper", "Payload"])
        XCTAssertNil(v.jettisonBottomPart())
        XCTAssertEqual(sim.vessels.count, 5)
        XCTAssertEqual(sim.vessels.reduce(0) { $0 + $1.mass }, m, accuracy: 1e-6)
        let p1 = sim.vessels.reduce(Vec3.zero) { $0 + $1.velocity * $1.mass }
        XCTAssertEqual((p1 - p).length, 0, accuracy: 1e-3)
        // The tower leaves forward (CoM to CoM); everything else falls behind.
        guard ahead.count == 4 else { return XCTFail("expected 4 separations") }
        XCTAssertGreaterThan(ahead[2], 0)
        for i in [0, 1, 3] { XCTAssertLessThan(ahead[i], 0) }
    }

    // A12: with no event pending, Space falls back to the lowest
    // `.bottomOfStack` part, skipping `.fixed` ones.
    func testFallbackSeparatesBottomOfStackPartsOnly() {
        let v = Vessel(name: "Mixed",
                       parts: [Toy.block("Stage 1", from: 0, to: 10, mass: 10_000, staging: .bottomOfStack),
                               Toy.block("Stage 2", from: 10, to: 16, mass: 5_000, staging: .bottomOfStack),
                               Toy.block("Payload", from: 16, to: 20, mass: 3_000, staging: .fixed),
                               Toy.block("Fairing", from: 20, to: 23, radius: 1, mass: 500, staging: .bottomOfStack),
                               Toy.block("Tower", from: 23, to: 27, radius: 0.5, mass: 1_000, staging: .event(1))],
                       reference: VesselLibrary.placeholderBody)
        var order: [String] = []
        while let spent = v.jettisonNextStage() { order.append(spent.parts.map(\.name).joined(separator: "+")) }
        XCTAssertEqual(order, ["Tower", "Stage 1", "Stage 2", "Fairing"])
        XCTAssertEqual(v.parts.map(\.name), ["Payload"])

        // An M0 stack (all `.bottomOfStack`) stages exactly as before.
        let m0 = VesselLibrary.testRocket()
        order = []
        while let spent = m0.jettisonNextStage() { order.append(spent.parts.map(\.name).joined(separator: "+")) }
        XCTAssertEqual(order, ["Stage 1", "Stage 2"])
        XCTAssertEqual(m0.parts.map(\.name), ["Capsule"])
    }

    // A11: construction coordinates (`offset - structureOrigin`) do not change
    // through burns and separations, and a separation moves no part.
    func testConstructionOffsetsSurviveBurnsAndSeparations() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.stack()
        sim.add(v)
        sim.placeInFreeSpace(v)
        func check(_ label: String) {
            for w in sim.vessels {
                XCTAssertLessThan(w.centerOfMass.length, 1e-9, label)
                for p in w.parts {
                    let construction = p.offset - w.structureOrigin
                    XCTAssertLessThan((construction - Vec3(stations[p.name]!, 0, 0)).length, 1e-9, "\(label): \(p.name)")
                }
            }
        }
        /// Separate the next event and check that every part stays where it was.
        func stage(_ label: String) {
            let before = sim.vessels.flatMap { w in w.parts.map { ($0.name, w.inertialPosition(ofStructuralPoint: Vec3(stations[$0.name]!, 0, 0))) } }
            XCTAssertNotNil(sim.stage(v), label)
            let after = Dictionary(uniqueKeysWithValues: sim.vessels.flatMap { w in
                w.parts.map { ($0.name, w.inertialPosition(ofStructuralPoint: Vec3(stations[$0.name]!, 0, 0))) }
            })
            for (name, position) in before {
                XCTAssertLessThan((after[name]! - position).length, 1e-6, "\(label): \(name)")
            }
            check(label)
        }

        check("built")
        v.mainThrottle = 1
        sim.run(seconds: 20)
        check("booster burn")
        stage("booster")
        sim.run(seconds: 10)
        check("core burn with interstage")
        stage("interstage")
        stage("tower")
        sim.run(seconds: 10)
        check("core burn")
        stage("core and adapter")
        sim.run(seconds: 10)
        check("upper burn")
        XCTAssertEqual(sim.vessels.count, 5)
    }

    /// A program the tests hand from vessel to vessel by its host part.
    final class Hosted: FlightProgram {
        let host: String
        init(_ host: String) { self.host = host }
        func update(_ vessel: Vessel, in sim: Simulation) {}
        func timeToNextEvent(at now: Epoch) -> Double? { nil }
        var status: String { host }
        var hostPart: String? { host }
    }

    // One event, several vessels: parts in separation groups leave on their
    // own, first, each on its `separationVelocity` (relative to what it
    // leaves, shared by momentum) and tumbling at its `separationRate`; the
    // ungrouped rest leaves as the main vessel, returned first. Momentum is
    // conserved and each leaves with the velocity it was given.
    func testSeparationGroupsLeaveOnTheirOwn() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let core = Toy.block("Core", from: 0, to: 10, mass: 10_000, staging: .event(1))
        core.separationSpeed = 0
        let left = Toy.block("Left", from: 10, to: 12, mass: 200, staging: .event(1))
        let right = Toy.block("Right", from: 10, to: 12, mass: 200, staging: .event(1))
        let top = Toy.block("Top", from: 12, to: 16, mass: 3_000, staging: .fixed)
        left.separationGroup = "Left"
        left.separationVelocity = Vec3(0, -2, 0)
        left.separationRate = Vec3(0, 0, 0.5)
        right.separationGroup = "Right"
        right.separationVelocity = Vec3(0, 2, 0)
        let v = Vessel(name: "Toy", parts: [core, left, right, top], reference: VesselLibrary.placeholderBody)
        sim.add(v)
        sim.placeInFreeSpace(v)
        let p0 = v.velocity * v.mass
        let all = sim.stageAll(v)
        XCTAssertEqual(all.map(\.name), ["Toy – Core", "Toy – Left", "Toy – Right"])
        XCTAssertEqual(v.parts.map(\.name), ["Top"])
        let p1 = ([v] + all).reduce(Vec3.zero) { $0 + $1.velocity * $1.mass }
        XCTAssertLessThan((p1 - p0).length, 1e-9)
        // Each 2 m/s is relative to what its part leaves: Left from the
        // 13,400 kg stack, Right from the 13,200 kg it left.
        let l = all[1], r = all[2], rest = 13_000.0
        let vl = -2 * (rest + 200) / (rest + 400), vr = 2 * 200 / (rest + 400) + 2 * rest / (rest + 200)
        XCTAssertEqual(l.attitude.inverseRotate(l.velocity - r.velocity).y, vl - vr, accuracy: 1e-9)
        XCTAssertEqual(l.angularVelocity.z, 0.5, accuracy: 1e-12)
        XCTAssertEqual(r.angularVelocity.length, 0, accuracy: 1e-12)
        XCTAssertEqual(all[0].velocity, v.velocity)   // no springs
    }

    // The crew keeps the vessel: should an event carry the crewed part, the
    // parts without it leave, and the vessel keeps its identity and its
    // crew's frame; the triggers act by the event as ever.
    func testCrewKeepsTheVessel() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let booster = Toy.block("Booster", from: 0, to: 10, mass: 10_000, staging: .fixed)
        let capsule = Toy.block("Capsule", from: 10, to: 13, mass: 3_000, staging: .event(1))
        capsule.isCrewed = true
        capsule.crewFrame = ApolloAxes.rotation
        let v = Vessel(name: "Crew", parts: [booster, capsule], reference: VesselLibrary.placeholderBody)
        v.controlFrame = ApolloAxes.rotation
        sim.add(v)
        sim.placeInFreeSpace(v)
        let id = v.id
        let spent = try XCTUnwrap(sim.stage(v))
        XCTAssertEqual(spent.parts.map(\.name), ["Booster"])
        XCTAssertEqual(spent.name, "Crew – Booster")
        XCTAssertTrue(v.id == id && sim.focus === v)
        XCTAssertEqual(v.parts.map(\.name), ["Capsule"])
        XCTAssertEqual(v.controlFrame, ApolloAxes.rotation)
        XCTAssertEqual(spent.controlFrame, .identity)
    }

    // The flight program, and every control it flies with, goes with its host
    // part; the vessel left behind starts afresh and takes the standby
    // program its parts carry. A program whose host stays stays.
    func testProgramMigratesWithItsHostPart() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.stack()
        sim.add(v)
        sim.placeInFreeSpace(v)
        let program = Hosted("Core"), standby = Hosted("Payload")
        v.parts.first { $0.name == "Payload" }?.standbyProgram = standby
        v.flightProgram = program
        v.autopilot = .attitudeHold
        v.attitudeCommand = AttitudeCommand(attitude: v.attitude)
        v.phasePlane = AS506.apsLaw
        v.tvcGains = TVCGains(naturalFrequency: 0.3)
        v.mainThrottle = 1
        v.translationInput = Vec3(1, 0, 0)
        for _ in 0..<3 { sim.stage(v) }   // booster, interstage, tower: the core stays
        XCTAssertTrue(v.flightProgram === program)
        let core = try XCTUnwrap(sim.stage(v))
        XCTAssertEqual(core.parts.map(\.name), ["Core", "Adapter"])
        XCTAssertTrue(core.flightProgram === program)
        XCTAssertEqual(core.autopilot, .attitudeHold)
        XCTAssertNotNil(core.attitudeCommand)
        XCTAssertEqual(core.phasePlane, AS506.apsLaw)
        XCTAssertEqual(core.tvcGains, TVCGains(naturalFrequency: 0.3))
        XCTAssertEqual(core.mainThrottle, 1)
        XCTAssertEqual(core.translationInput, Vec3(1, 0, 0))
        XCTAssertTrue(v.flightProgram === standby)
        XCTAssertNil(v.autopilot)
        XCTAssertNil(v.attitudeCommand)
        XCTAssertNil(v.phasePlane)
        XCTAssertEqual(v.tvcGains, TVCGains())
        XCTAssertEqual(v.mainThrottle, 0)
        XCTAssertEqual(v.translationInput, .zero)
    }

    // A part centred until an event (`centeredUntilEvent`) counts on the
    // axis, without products of inertia, until that event separates; then
    // its own distribution, and the vessels re-centre on it.
    func testCentredUntilAnEvent() {
        let low = Toy.block("Low", from: 0, to: 10, mass: 10_000, staging: .event(1))
        let off = Toy.block("Off", from: 10, to: 14, mass: 2_000, staging: .fixed)
        off.dryCenterOfMass = Vec3(0, 0.3, -0.2)
        off.dryInertia = Mat3(rows: Vec3(500, 20, 30), Vec3(20, 900, 40), Vec3(30, 40, 900))
        off.centeredUntilEvent = 1
        let v = Vessel(name: "Off", parts: [low, off], reference: VesselLibrary.placeholderBody)
        XCTAssertEqual(off.centerOfMass, Vec3(0, 0, 0))
        XCTAssertEqual(off.localInertia[0, 1], 0)
        XCTAssertEqual(v.structuralCenterOfMass.y, 0)
        v.jettison(event: 1)
        XCTAssertNil(off.centeredUntilEvent)
        XCTAssertEqual(off.centerOfMass, Vec3(0, 0.3, -0.2))
        XCTAssertEqual(off.localInertia[0, 1], 20, accuracy: 1e-9)
        XCTAssertEqual(v.centerOfMass.length, 0, accuracy: 1e-12)
        XCTAssertEqual(v.structuralCenterOfMass.y, 0.3, accuracy: 1e-12)
    }
}
