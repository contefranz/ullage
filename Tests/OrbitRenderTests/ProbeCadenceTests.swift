import Foundation
import XCTest
@testable import OrbitCore
import OrbitScene
@testable import OrbitRender

/// R3's face cadence in real scenes, on the CPU: where the faces' staleness
/// is measured (the centre in the nearest body's fixed frame, its height
/// over the figure), what each kind of change does (`EnvironmentProbePass.
/// update`), and which faces a frame draws, paused or not (`FaceSchedule`).
@MainActor
final class ProbeCadenceTests: XCTestCase {
    static let system = try! SolarSystem.bundled()

    static func scene(_ scenario: String, advance: [String] = [], target: String = "focus") throws -> RenderScene {
        var shot = SnapshotSpec.Shot(name: scenario, scenario: scenario, advance: advance,
                                     camera: SnapshotSpec.CameraSpec(target: target, frame: "vessel", yaw: 30, pitch: 10,
                                                                     distance: 60, fov: 40))
        shot.width = 64
        shot.height = 40
        var scene = shot.scene(try shot.prepare(system: system))
        // A running frame, not the extractor's first (a temporal reset).
        scene.clock.temporalReset = false
        return scene
    }

    typealias Pass = EnvironmentProbePass
    static let size = 128

    func state(_ scene: RenderScene, settings: RenderSettings = RenderSettings(), tiles: Int = -1) -> Pass.FaceState {
        Pass.FaceState(scene, center: Pass.center(scene), settings: settings, tiles: tiles)
    }

    /// `scene` a frame later, its target and camera risen `metres` along the
    /// local vertical over the Earth (every camera-relative body moves down).
    static func risen(_ scene: RenderScene, _ metres: Double) -> RenderScene {
        var s = scene
        s.clock.frameIndex += 1
        let earth = s.bodies.firstIndex { $0.id == 399 }!
        let up = (Pass.center(s) - s.bodies[earth].position).normalized
        for i in s.bodies.indices { s.bodies[i].position = s.bodies[i].position - up * metres }
        return s
    }

    /// On the pad: the centre (the stack's) some 30-150 m over the WGS-84
    /// ground, not the 16 km over the polar radius; half a 128² texel there
    /// is a few decimetres of rise a frame. A camera orbiting the stack
    /// moves nothing.
    func testPad() throws {
        let pad = try Self.scene("as506-pad")
        let a = state(pad)
        XCTAssertEqual(a.body, 399)
        XCTAssertGreaterThan(a.height, 30)
        XCTAssertLessThan(a.height, 150, "the geodetic height, not over the polar radius")
        let halfTexel = a.height / Double(Self.size)
        print(String(format: "pad probe: %.0f m over the ground, half a texel %.2f m", a.height, halfTexel))

        var next = pad
        next.clock.frameIndex += 1
        XCTAssertEqual(Pass.update(state(next), after: a, clock: next.clock, size: Self.size), .steady)
        let slow = Self.risen(pad, 0.5 * halfTexel)
        XCTAssertEqual(Pass.update(state(slow), after: a, clock: slow.clock, size: Self.size), .steady)
        let fast = Self.risen(pad, 2 * halfTexel)
        XCTAssertEqual(Pass.update(state(fast), after: a, clock: fast.clock, size: Self.size), .moving)

        // The camera orbits the stack by 40 m: everything camera-relative
        // moves together, the centre over the ground does not.
        var orbit = pad
        orbit.clock.frameIndex += 1
        let shift = Vec3(40, -25, 10)
        orbit.camera.position = orbit.camera.position + shift
        for i in orbit.vessels.indices { orbit.vessels[i].position = orbit.vessels[i].position - shift }
        for i in orbit.bodies.indices { orbit.bodies[i].position = orbit.bodies[i].position - shift }
        let o = state(orbit)
        XCTAssertEqual((o.anchor - a.anchor).length, 0, accuracy: 1e-3)
        XCTAssertEqual(Pass.update(o, after: a, clock: orbit.clock, size: Self.size), .steady)
    }

    /// In LEO: the centre some 185 km up; 100 m a frame (about 1×) is
    /// steady, 2 km (about 15×) moving.
    func testLowEarthOrbit() throws {
        let leo = try Self.scene("as506-parking-orbit")
        let a = state(leo)
        XCTAssertEqual(a.body, 399)
        XCTAssertEqual(a.height, 186_000, accuracy: 6_000)
        let slow = Self.risen(leo, 100)
        XCTAssertEqual(Pass.update(state(slow), after: a, clock: slow.clock, size: Self.size), .steady)
        let fast = Self.risen(leo, 2_000)
        XCTAssertEqual(Pass.update(state(fast), after: a, clock: fast.clock, size: Self.size), .moving)
    }

    /// What changes do: another nearest body, a target, a warp or a
    /// skipped frame redraw every face; the extractor's reset for the body
    /// turning alone (same target, same warp) only moves.
    func testChanges() throws {
        let leo = try Self.scene("as506-parking-orbit")
        let a = state(leo)
        var next = leo
        next.clock.frameIndex += 1

        // The Moon brought within 1,000 km of the centre: the nearest body.
        var moon = next
        let m = try XCTUnwrap(moon.bodies.firstIndex { $0.id == 301 })
        moon.bodies[m].position = Pass.center(moon) + Vec3(0, 0, 1_000_000 + moon.bodies[m].radius)
        let b = state(moon)
        XCTAssertEqual(b.body, 301)
        XCTAssertEqual(Pass.update(b, after: a, clock: moon.clock, size: Self.size), .full)

        var turn = next
        turn.clock.temporalReset = true
        XCTAssertEqual(Pass.update(state(turn), after: a, clock: turn.clock, size: Self.size), .moving,
                       "a reset for the turn alone")
        var warp = turn
        warp.clock.warp = 100
        XCTAssertEqual(Pass.update(state(warp), after: a, clock: warp.clock, size: Self.size), .full, "a new warp")
        var target = turn
        target.camera.target = .body(399)
        XCTAssertEqual(Pass.update(state(target), after: a, clock: target.clock, size: Self.size), .full,
                       "a new target (the probe at the camera)")
        var skipped = leo
        skipped.clock.frameIndex += 2
        XCTAssertEqual(Pass.update(state(skipped), after: a, clock: skipped.clock, size: Self.size), .full)
        var settings = RenderSettings()
        settings.cloud.enabled = false
        XCTAssertEqual(Pass.update(state(next, settings: settings), after: a, clock: next.clock, size: Self.size), .full)
    }

    /// The Earth turning under the stack on the pad is not motion: the
    /// centre's anchor in the body's frame stays, while the Sun turns in it.
    /// A turn of a frame at 1000× (0.07°) stays steady; one of 1.5° (the
    /// extractor's 1e4× and up) moves through the Sun alone.
    func testEarthTurningUnderThePad() throws {
        let pad = try Self.scene("as506-pad")
        let a = state(pad)
        func turned(_ degrees: Double) -> RenderScene {
            var s = pad
            s.clock.frameIndex += 1
            let e = s.bodies.firstIndex { $0.id == 399 }!
            let body = s.bodies[e]
            // The world turned about the pole by the angle: the body's axes
            // with it, its centre about the stack, which is fixed on it.
            let w = Quat(axis: body.orientation.pole, angle: degrees * Double.pi / 180).matrix
            let center = Pass.center(s)
            s.bodies[e].orientation = BodyOrientation(icrfToBody: body.orientation.icrfToBody * w.transposed,
                                                      angularVelocity: body.orientation.angularVelocity)
            s.bodies[e].position = center - w * (center - body.position)
            return s
        }
        let slow = state(turned(0.07))
        XCTAssertEqual((slow.anchor - a.anchor).length, 0, accuracy: 1e-3, "the stack stays on the turning ground")
        XCTAssertEqual(slow.height, a.height, accuracy: 1e-3)
        XCTAssertEqual(Pass.update(slow, after: a, clock: turned(0.07).clock, size: Self.size), .steady)
        let fast = state(turned(1.5))
        XCTAssertEqual((fast.anchor - a.anchor).length, 0, accuracy: 1e-3)
        XCTAssertGreaterThan(acos(min(fast.toSun.dot(a.toSun), 1)), 1.3 * Double.pi / 180, "the Sun turned in its frame (1.5° × sin 69° off the pole)")
        XCTAssertEqual(Pass.update(fast, after: a, clock: turned(1.5).clock, size: Self.size), .moving)
    }

    /// Each full-update guard alone: a new target with the same centre
    /// source; the same target with the centre moved to the camera (past
    /// 50 km); the sky switched from the camera's LUT to the centre's march
    /// (past 2 km). And in a scene: the target 60 km from the camera.
    func testCentreGuards() throws {
        let leo = try Self.scene("as506-parking-orbit")
        let a = state(leo)
        XCTAssertTrue(a.onTarget)
        XCTAssertFalse(a.skyFromCentre)
        var next = leo
        next.clock.frameIndex += 1
        var b = state(next)
        XCTAssertEqual(Pass.update(b, after: a, clock: next.clock, size: Self.size), .steady)
        b.target = .body(399)
        XCTAssertEqual(Pass.update(b, after: a, clock: next.clock, size: Self.size), .full, "the target alone")
        b = state(next)
        b.onTarget = false
        XCTAssertEqual(Pass.update(b, after: a, clock: next.clock, size: Self.size), .full, "the centre's source alone")
        b = state(next)
        b.skyFromCentre = true
        XCTAssertEqual(Pass.update(b, after: a, clock: next.clock, size: Self.size), .full, "the sky's source alone")

        // The camera 60 km from its target, the same target: the probe moves
        // to the camera.
        var far = next
        let d = Vec3(60_000, 0, 0)
        far.camera.position = far.camera.position + d
        for i in far.vessels.indices { far.vessels[i].position = far.vessels[i].position - d }
        for i in far.bodies.indices { far.bodies[i].position = far.bodies[i].position - d }
        let c = state(far)
        XCTAssertEqual(c.target, a.target)
        XCTAssertFalse(c.onTarget)
        XCTAssertEqual(Pass.update(c, after: a, clock: far.clock, size: Self.size), .full)
        // 10 km from it: the probe stays on the target, its sky marched.
        var mid = next
        let m = Vec3(10_000, 0, 0)
        mid.camera.position = mid.camera.position + m
        for i in mid.vessels.indices { mid.vessels[i].position = mid.vessels[i].position - m }
        for i in mid.bodies.indices { mid.bodies[i].position = mid.bodies[i].position - m }
        let e = state(mid)
        XCTAssertTrue(e.onTarget)
        XCTAssertTrue(e.skyFromCentre)
        XCTAssertEqual((e.anchor - a.anchor).length, 0, accuracy: 1e-3, "the camera moved, not the centre")
        XCTAssertEqual(Pass.update(e, after: a, clock: mid.clock, size: Self.size), .full)
    }

    /// The schedule: two a frame in turn, each face once in three frames;
    /// three while moving; six on a full update. Paused: the turn finishes,
    /// then nothing, until motion, a full update or tiles streaming in.
    func testSchedule() {
        var s = Pass.FaceSchedule()
        let turn = (0..<3).map { _ in s.next(.steady, paused: false, steady: 2, tilesChanged: false) }
        XCTAssertEqual(turn.flatMap { $0 }.sorted(), Array(0..<6))
        XCTAssertEqual(s.next(.moving, paused: false, steady: 2, tilesChanged: false).count, 3)
        XCTAssertEqual(s.next(.full, paused: false, steady: 2, tilesChanged: false).count, 6)

        let paused = (0..<3).map { _ in s.next(.steady, paused: true, steady: 2, tilesChanged: false) }
        XCTAssertEqual(paused.flatMap { $0 }.sorted(), Array(0..<6))
        XCTAssertEqual(s.next(.steady, paused: true, steady: 2, tilesChanged: false), [])
        XCTAssertEqual(s.next(.moving, paused: true, steady: 2, tilesChanged: false).count, 3, "motion while paused")
        let after = (0..<2).map { _ in s.next(.steady, paused: true, steady: 2, tilesChanged: false) }
        XCTAssertEqual(after.map(\.count), [2, 2], "the turn again after the motion")
        XCTAssertEqual(s.next(.steady, paused: true, steady: 2, tilesChanged: false), [])
        XCTAssertEqual(s.next(.steady, paused: true, steady: 2, tilesChanged: true).count, 2, "tiles streamed in")
        _ = (0..<2).map { _ in s.next(.steady, paused: true, steady: 2, tilesChanged: false) }
        XCTAssertEqual(s.next(.steady, paused: true, steady: 2, tilesChanged: false), [])
        XCTAssertEqual(s.next(.full, paused: true, steady: 2, tilesChanged: false).count, 6, "a full update while paused")
        XCTAssertEqual(s.next(.steady, paused: true, steady: 2, tilesChanged: false), [])
        XCTAssertEqual(s.next(.steady, paused: false, steady: 6, tilesChanged: false).count, 6, "six on request")
    }
}
