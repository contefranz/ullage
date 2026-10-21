import XCTest
@testable import OrbitCore

/// The vehicle frame's azimuth v, which paint and markings are laid out in:
/// from Position I towards Position II about +x, so Position I at 0, II at
/// π/2, III at π and IV at 3π/2. In construction axes +z is Position I and
/// +y Position IV, so +Z_A, Position III, is -z (MSFC-MAN-506 Fig. 7-15);
/// the fins A-D, and engines 1-4 under them, lie on the diagonals, A between
/// Positions I and II (FER-501 Table 12-2, NASA CR-61390 Fig. 4.1-2;
/// datasheet §12). The S-IVB's APS modules are at Positions I and III.
final class PositionConventionTests: XCTestCase {
    let pi = Double.pi

    func wrapped(_ a: Double) -> Double { remainder(a, 2 * pi) }

    /// Vehicle azimuth of the construction point `c`.
    func azimuth(_ c: Vec3) -> Double { VisualShape.vehicleAzimuth(y: c.y, z: c.z) }

    func testPositionsAndApolloAxes() {
        XCTAssertEqual(azimuth(.unitZ), 0)                                   // I
        XCTAssertEqual(azimuth(-Vec3.unitY), pi / 2, accuracy: 1e-15)        // II
        XCTAssertEqual(abs(azimuth(-Vec3.unitZ)), pi, accuracy: 1e-15)       // III
        XCTAssertEqual(wrapped(azimuth(.unitY) - 3 * pi / 2), 0, accuracy: 1e-15)   // IV
        // +Z_A is Position III, +Y_A Position II.
        XCTAssertEqual(abs(azimuth(ApolloAxes.direction(xa: 0, ya: 0, za: 1))), pi, accuracy: 1e-15)
        XCTAssertEqual(azimuth(ApolloAxes.direction(xa: 0, ya: 1, za: 0)), pi / 2, accuracy: 1e-15)
    }

    // On the Saturn V as built and dressed: the APS modules at Positions I
    // and III, their pitch engines firing inwards there; the S-IVB's skin
    // carries v = 0 towards module I, π towards module III, and π/2 at
    // Position II; engines n under fins A-D at (2n - 1)π/4; the S-II ullage
    // motors at Positions I-IV in order, motor n's exit on its fairing 4°
    // anticlockwise of fin n (SICExteriorTests); SLA panel 1 at +Z_A (III), 2 at
    // -Z_A (I), 3 at +Y_A (II), 4 at -Y_A (IV), each a quarter turn about
    // its Position.
    func testSaturnVAgainstTheAPSModules() throws {
        let stack = VesselLibrary.saturnV()
        func construction(_ p: VesselPart, _ x: Vec3) -> Vec3 { x + p.offset - stack.structureOrigin }
        let sIVB = try XCTUnwrap(stack.parts.first { $0.name == "S-IVB" })
        for (module, expected) in [("I", 0.0), ("III", pi)] {
            let pitch = try XCTUnwrap(sIVB.thrusters.first { $0.name == "APS \(module) pitch" })
            XCTAssertEqual(wrapped(azimuth(construction(sIVB, pitch.position)) - expected), 0, accuracy: 1e-12, module)
            XCTAssertEqual(wrapped(azimuth(-pitch.direction) - expected), 0, accuracy: 1e-12, module)
        }
        // The two module fairings, on the skin at I and III.
        let modules = sIVB.shapes.filter { $0.material == .apolloWhitePaint && $0.origin.y == 0 && $0.origin.z != 0 }
        XCTAssertEqual(modules.map { wrapped(azimuth(construction(sIVB, $0.origin))) }.map { abs($0) }.sorted(),
                       [0, pi])

        // The skin's own v, vertex by vertex.
        let skin = try XCTUnwrap(sIVB.shapes.first)
        guard case .vehicle = skin.surfaceFrame else { return XCTFail("the S-IVB's skin is in the vehicle frame") }
        let vertices = skin.mesh().vertices.filter { $0.surface.r > 1 }
        for (direction, expected) in [(Vec3.unitZ, 0.0), (-Vec3.unitZ, pi), (-Vec3.unitY, pi / 2),
                                      (Vec3.unitY, 3 * pi / 2)] {
            let nearest = try XCTUnwrap(vertices.max { a, b in
                Vec3(0, a.position.y, a.position.z).normalized.dot(direction)
                    < Vec3(0, b.position.y, b.position.z).normalized.dot(direction)
            })
            XCTAssertEqual(wrapped(nearest.surface.v - expected), 0, accuracy: 1e-12)
        }

        for stage in ["S-IC", "S-II"] {
            let part = try XCTUnwrap(stack.parts.first { $0.name == stage })
            for n in 1...4 {
                let e = try XCTUnwrap(part.thrusters.first { $0.name == "\(stage) engine \(n)" })
                let expected = Double(2 * n - 1) * pi / 4
                XCTAssertEqual(wrapped(azimuth(construction(part, e.position)) - expected), 0, accuracy: 1e-12, e.name)
            }
        }

        let interstage = try XCTUnwrap(stack.parts.first { $0.name == "S-IC/S-II interstage" })
        let motors = interstage.thrusters.filter(\.isSolid)
        XCTAssertEqual(motors.count, 4)
        for (n, motor) in motors.enumerated() {
            XCTAssertEqual(wrapped(azimuth(construction(interstage, motor.position)) - Double(n) * pi / 2), 0,
                           accuracy: 1e-12, motor.name)
        }
        let ullage = interstage.attachments.filter { $0.kind == .ullageExit }
        XCTAssertEqual(ullage.count, 4)
        for (n, port) in ullage.enumerated() {
            XCTAssertEqual(port.thruster, "S-II ullage motor \(n + 1)")
            let fairing = Double(2 * n + 1) * pi / 4 + 4 * pi / 180
            XCTAssertEqual(wrapped(azimuth(construction(interstage, port.position)) - fairing), 0,
                           accuracy: 1e-12, port.name)
        }

        for (n, expected) in [(1, pi), (2, 0), (3, pi / 2), (4, 3 * pi / 2)] {
            let panel = try XCTUnwrap(stack.parts.first { $0.name == "SLA panel \(n)" }?.shapes.first)
            let v = panel.mesh().vertices.map(\.surface.v)
            XCTAssertEqual(wrapped((v.min()! + v.max()!) / 2 - expected), 0, accuracy: 1e-12, "panel \(n)")
            XCTAssertEqual(v.max()! - v.min()!, pi / 2, accuracy: 1e-12, "panel \(n)")
        }
    }
}
