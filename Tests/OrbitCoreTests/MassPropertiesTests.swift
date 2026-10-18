import XCTest
@testable import OrbitCore

/// Tank placement, part and vessel mass properties, and keeping the vessel
/// origin at the centre of mass (design tests A6-A10).
final class MassPropertiesTests: XCTestCase {

    // A6: M0 vessels (lumped tanks, no dry CoM or inertia) keep M0's formulas
    // to the bit, at any fill.
    func testM0MassPropertiesAreBitIdentical() {
        for v in [VesselLibrary.testRocket(), VesselLibrary.capsule()] {
            for fill in [1.0, 0.37] {
                for t in v.tanks { t.mass = t.capacity * fill }
                var com = Vec3.zero
                for p in v.parts { com += p.offset * p.mass }
                com = com / v.mass
                var inertia = Mat3.zero
                for p in v.parts {
                    let m = p.mass, r = p.radius, l = p.length, d = p.offset - com
                    let ixx = 0.5 * m * r * r
                    let iyy = m * (3 * r * r + l * l) / 12
                    let parallel = Mat3.identity * (m * d.lengthSquared)
                        + Mat3(columns: d * (-m * d.x), d * (-m * d.y), d * (-m * d.z))
                    inertia = inertia + .diagonal(Vec3(ixx, iyy, iyy)) + parallel
                }
                XCTAssertEqual(v.centerOfMass, com, "\(v.name) at \(fill)")
                XCTAssertEqual(v.inertia, inertia, "\(v.name) at \(fill)")
            }
        }
    }

    // A7: a settled column fills from its aft end. Its liquid adds pitch and
    // yaw inertia as a solid cylinder, but none about its own axis: it does
    // not spin up with the tank in roll (AS-506 FER Table 20-10).
    func testSettledColumnCentroidAndInertia() {
        let geometry = TankGeometry.settledColumn(aftEnd: Vec3(2, 0.5, 0), length: 10, radius: 1)
        for (mass, height) in [(1_000.0, 10.0), (500, 5), (0, 0)] {
            let t = PropellantTank(name: "T", capacity: 1_000, mass: mass, geometry: geometry)
            XCTAssertEqual(t.centroid!.x, 2 + height / 2, accuracy: 1e-12)
            XCTAssertEqual(t.centroid!.y, 0.5, accuracy: 1e-12)
            let i = t.ownInertia
            XCTAssertEqual(i[0, 0], 0)
            XCTAssertEqual(i[1, 1], mass * (3 + height * height) / 12, accuracy: 1e-12)
            XCTAssertEqual(i[2, 2], i[1, 1])
            XCTAssertEqual(i[0, 1], 0)
        }

        // 1000 kg at 10 kg/m^3 in a 2 m radius column is 7.958 m tall.
        let column = TankGeometry.column(fullLoadCentroid: Vec3(5, 0, 0), radius: 2, capacity: 1_000, density: 10)
        let height = 1_000 / (10 * Double.pi * 4)
        let full = PropellantTank(name: "F", capacity: 1_000, geometry: column)
        XCTAssertEqual(full.centroid!.x, 5, accuracy: 1e-12)
        full.mass = 500
        XCTAssertEqual(full.centroid!.x, 5 - height / 4, accuracy: 1e-12)

        let point = PropellantTank(name: "P", capacity: 100, geometry: .point(Vec3(1, 2, 3)))
        XCTAssertEqual(point.centroid, Vec3(1, 2, 3))
        XCTAssertEqual(point.ownInertia, .zero)
        XCTAssertNil(PropellantTank(name: "L", capacity: 100).centroid)
    }

    // A7: feed lines below a column stay full while the tank proper empties,
    // then drain; the tank's mass and draw are unchanged, only where the
    // propellant sits. Lines on the axis add no roll inertia.
    func testFeedLinesEmptyLast() {
        let column = TankGeometry.column(fullLoadCentroid: Vec3(10, 0, 0), radius: 2, capacity: 800, density: 10)
        let t = PropellantTank(name: "T", capacity: 1_000, geometry: column, feedLines: (mass: 200, position: Vec3(1, 0, 0)))
        XCTAssertEqual(t.centroid!.x, (800 * 10 + 200 * 1) / 1_000, accuracy: 1e-12)
        t.mass = 600
        let height = 800 / (10 * Double.pi * 4), proper = 10 - height / 2 + height * 0.5 / 2
        XCTAssertEqual(t.lineMass, 200)
        XCTAssertEqual(t.centroid!.x, (400 * proper + 200 * 1) / 600, accuracy: 1e-12)
        t.mass = 150
        XCTAssertEqual(t.lineMass, 150)
        XCTAssertEqual(t.centroid!.x, 1, accuracy: 1e-12)
        XCTAssertEqual(t.ownInertia[0, 0], 0)
        XCTAssertEqual(t.ownInertia[1, 1], 0, accuracy: 1e-9)
        t.mass = 600
        let c = t.centroid!.x, columnIyy = 400 * (3 * 4 + (height / 2) * (height / 2)) / 12
        XCTAssertEqual(t.ownInertia[0, 0], 0)
        XCTAssertEqual(t.ownInertia[1, 1], columnIyy + 400 * (proper - c) * (proper - c) + 200 * (1 - c) * (1 - c),
                       accuracy: 1e-9)
    }

    // A7: a part combines its dry body (with lumped tanks) and its placed tanks.
    func testPartCombinesDryBodyAndPlacedTanks() {
        let part = VesselPart(name: "P", dryMass: 1_000, length: 10, radius: 1,
                              tanks: [PropellantTank(name: "Lumped", capacity: 400),
                                      PropellantTank(name: "Point", capacity: 600, geometry: .point(Vec3(-4, 0, 0)))],
                              dryCenterOfMass: Vec3(1, 0, 0), dryInertia: .diagonal(Vec3(100, 200, 300)))
        // Body: 1400 kg at x = 1; point: 600 kg at x = -4; CoM at -0.5.
        XCTAssertEqual(part.centerOfMass.x, -0.5, accuracy: 1e-12)
        // Body inertia: dry inertia plus 400 kg as a solid cylinder (r 1, l 10),
        // then both elements moved to the CoM (1.5 m and 3.5 m away).
        let cylinder: Double = 400 * (3 + 100) / 12
        let transverse: Double = cylinder + 1_400 * 1.5 * 1.5 + 600 * 3.5 * 3.5
        let expected = Mat3.diagonal(Vec3(100 + 0.5 * 400, 200 + transverse, 300 + transverse))
        for r in 0..<3 {
            for c in 0..<3 { XCTAssertEqual(part.localInertia[r, c], expected[r, c], accuracy: 1e-9) }
        }
        // With no dry inertia the body is a solid bounding cylinder of all its mass.
        part.dryInertia = nil
        XCTAssertEqual(part.localInertia[0, 0], 0.5 * 1_400, accuracy: 1e-9)
        let bounding: Double = 1_400 * (3 + 100) / 12
        XCTAssertEqual(part.localInertia[1, 1], bounding + 1_400 * 1.5 * 1.5 + 600 * 3.5 * 3.5, accuracy: 1e-9)
    }

    // A8: the simulation keeps the origin at the CoM after every burning step,
    // while the CoM moves through the structure.
    func testOriginStaysAtCenterOfMassDuringBurn() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.rocket()
        sim.add(v)
        sim.placeInFreeSpace(v)
        let station0 = v.structuralCenterOfMass.x
        v.mainThrottle = 1
        var worst = 0.0, steps = 0
        while v.thrusters.contains(where: { $0.hasPropellant }) && steps < 10_000 {   // about 3,060
            sim.tick()
            steps += 1
            worst = max(worst, v.centerOfMass.length)
        }
        XCTAssertFalse(v.thrusters.contains { $0.hasPropellant })
        XCTAssertLessThan(worst, 1e-9)
        XCTAssertLessThan(v.structuralCenterOfMass.x - station0, -2)
    }

    // A8 on the pad: a burn below the vessel's weight keeps its base on the
    // ground while the origin follows the CoM.
    func testLandedSubWeightBurnKeepsBaseOnPad() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = Toy.rocket(throttleRange: 0...1)
        sim.add(v)
        sim.placeLanded(v, on: sim.system.earth, latitude: 28.6083, longitude: -80.6041)
        let clearance = v.altitude - v.baseHeight
        let station0 = v.structuralCenterOfMass.x
        v.mainThrottle = 0.25   // 2 x 0.25 x 0.92 MN at sea level, under the 0.52 MN weight
        var worst = 0.0
        sim.run(seconds: 20) { worst = max(worst, v.centerOfMass.length) }
        XCTAssertEqual(v.status, .landed)
        XCTAssertLessThan(worst, 1e-9)
        XCTAssertEqual(v.altitude - v.baseHeight, clearance, accuracy: 1e-6)
        XCTAssertGreaterThan(abs(v.structuralCenterOfMass.x - station0), 0.05)
    }

    // A9: the structure follows F/m wherever the propellant sits. Two rockets
    // that differ only in tank placement (columns or lumped) keep their
    // construction origins together in a free-space burn.
    func testStructurePathDoesNotDependOnTankPlacement() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let a = Toy.rocket(columns: true), b = Toy.rocket(columns: false)
        sim.add(a)
        sim.add(b)
        sim.placeInFreeSpace(a)
        sim.placeInFreeSpace(b)
        b.position += a.inertialPosition(ofStructuralPoint: .zero) - b.inertialPosition(ofStructuralPoint: .zero)
        let stations0 = (a.structuralCenterOfMass.x, b.structuralCenterOfMass.x)
        a.mainThrottle = 1
        b.mainThrottle = 1
        sim.run(seconds: 50)
        let gap = a.inertialPosition(ofStructuralPoint: .zero) - b.inertialPosition(ofStructuralPoint: .zero)
        XCTAssertLessThan(gap.length, 1e-4)
        // The two CoMs moved differently through the structure, and far.
        let moved = (a.structuralCenterOfMass.x - stations0.0, b.structuralCenterOfMass.x - stations0.1)
        XCTAssertGreaterThan(abs(moved.0 - moved.1), 1)
    }

    // A10: after a burn has moved the CoM through the structure, a tumbling
    // vessel's true CoM still coasts like a point mass.
    func testTumbleAfterBurnKeepsCenterOfMassOnItsPath() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.rocket(), twin = VesselLibrary.capsule()
        sim.add(v)
        sim.add(twin)
        sim.placeInFreeSpace(v)
        sim.placeInFreeSpace(twin)
        v.mainThrottle = 1
        sim.run(seconds: 30)
        v.mainThrottle = 0
        twin.position = v.position
        twin.velocity = v.velocity
        v.angularVelocity = Vec3(0, 0.05, 0)
        sim.run(seconds: 60)
        let trueCoM = v.position + v.attitude.rotate(v.centerOfMass)
        XCTAssertLessThan((trueCoM - twin.position).length, 1e-6)
    }
}
