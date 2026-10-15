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
}
