import XCTest
@testable import OrbitCore

/// The Apollo spacecraft axes in the Saturn V construction frame: X_A = +x,
/// Y_A = -y, Z_A = -z (datasheet §12, MSFC-MAN-506 Fig. 7-15, H).
final class ApolloAxesTests: XCTestCase {
    // The tower-jettison motor's resultant "is in the pitch plane in the +Z
    // direction" (AOH §2.9.5.7.4, H): leaning towards +Z_A, it comes out
    // towards -z (Position III), the lean the Saturn V's LES is built with,
    // and its thrust line crosses the axis at Xa 1395.9.
    func testTowerJettisonLeanTowardsPlusZA() throws {
        let tilt = AS506.towerJettisonTilt * AS506.degree
        let lean = ApolloAxes.direction(xa: cos(tilt), ya: 0, za: sin(tilt))
        XCTAssertLessThan(lean.z, 0)
        XCTAssertEqual(lean.y, 0)
        let stack = VesselLibrary.saturnV()
        let les = try XCTUnwrap(stack.parts.first { $0.name == "LES" })
        let tjm = try XCTUnwrap(les.thrusters.first { $0.name == "Tower jettison motor" })
        XCTAssertEqual((lean - tjm.direction).length, 0, accuracy: 1e-15)
        let crossing = ApolloAxes.construction(xa: AS506.towerJettisonThrustPoint)
        XCTAssertEqual((crossing - (tjm.position + les.offset - stack.structureOrigin)).length, 0, accuracy: 1e-9)
    }

    func testAxesAndUnits() {
        for (apollo, construction) in [(Vec3.unitX, Vec3.unitX), (.unitY, -Vec3.unitY), (.unitZ, -Vec3.unitZ)] {
            XCTAssertEqual(ApolloAxes.direction(xa: apollo.x, ya: apollo.y, za: apollo.z), construction)
            XCTAssertEqual(ApolloAxes.rotation.rotate(apollo), construction)
        }
        // Stations and offsets in inches; Xa 0 is Saturn station 2,756.56.
        let p = ApolloAxes.construction(xa: 1_000, ya: 10, za: -20)
        XCTAssertEqual(p.x, 3_756.56 * 0.0254, accuracy: 1e-12)
        XCTAssertEqual(p.y, -0.254, accuracy: 1e-15)
        XCTAssertEqual(p.z, 0.508, accuracy: 1e-15)
    }

    // Pilot commands go through `controlFrame`: the identity passes them to
    // the body axes, and the crew axes flip pitch and yaw and the y and z
    // translations.
    func testPilotInputThroughTheControlFrame() {
        let v = VesselLibrary.capsule()
        let rotation = RotationCommand(roll: 1, pitch: 1, yaw: -1), translation = Vec3(1, 1, -1)
        v.setPilotInput(rotation: rotation, translation: translation)
        XCTAssertEqual(v.rotationInput, rotation)
        XCTAssertEqual(v.translationInput, translation)
        v.controlFrame = ApolloAxes.rotation
        v.setPilotInput(rotation: rotation, translation: translation)
        XCTAssertEqual(v.rotationInput, RotationCommand(roll: 1, pitch: -1, yaw: 1))
        XCTAssertEqual(v.translationInput, Vec3(1, -1, 1))
    }
}
