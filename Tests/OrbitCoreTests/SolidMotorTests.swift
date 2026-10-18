import XCTest
@testable import OrbitCore

/// Solid motors (retro and ullage rockets): lit once, they burn their grain to
/// the end whatever the controls do, and staging lights the ones it fires.
/// Expected values are worked out from the literals below.
final class SolidMotorTests: XCTestCase {
    let g0 = 9.80665

    /// A solid of `thrust` N for `burn` s on `propellant` kg (Isp_eff =
    /// F t / (m g0)), at part-frame x `x`, thrusting along `direction`; on its
    /// own grain unless `grain` is given (shared by a set).
    func solid(_ name: String, in part: VesselPart, thrust: Double, burn: Double, propellant: Double, x: Double,
               direction: Vec3, trigger: SolidTrigger? = nil, groups: Set<ThrusterGroup> = [],
               grain shared: PropellantTank? = nil) -> Thruster {
        let grain = shared ?? PropellantTank(name: "\(name) grain", capacity: propellant, geometry: .point(Vec3(x, 0, 0)))
        if shared == nil { part.tanks.append(grain) }
        let t = Thruster(name: name, position: Vec3(x, 0, 0), direction: direction,
                         rating: EngineRating(thrustVacuum: thrust, ispVacuum: thrust * burn / (propellant * g0)),
                         feed: .single(grain), groups: groups)
        t.isSolid = true
        t.trigger = trigger
        part.thrusters.append(t)
        return t
    }

    /// `burn` on a 1,000 t block in free space at `warp`, from `ignite` on:
    /// the Δv along the block's axis over 10 s of 1/60 s frames.
    func deltaV(warp: Double, _ setUp: (VesselPart) -> [Thruster], before: (Vessel) -> Void = { _ in },
                after: (Vessel) -> Void = { _ in }) throws -> (dv: Double, motors: [Thruster]) {
        let sim = try Simulation.forTests(perturbations: false)
        let part = VesselPart(name: "Block", dryMass: 1e6, length: 2, radius: 1, staging: .fixed)
        let motors = setUp(part)
        let v = Vessel(name: "Block", parts: [part], reference: VesselLibrary.placeholderBody)
        sim.add(v)
        let x = sim.placeInFreeSpace(v)
        before(v)
        sim.advance(by: 0.5)
        for m in motors { XCTAssertFalse(m.isCommanded, "unlit") }
        for m in motors { XCTAssertTrue(m.ignite()) }
        after(v)
        let start = sim.time, v0 = v.velocity.dot(x)
        sim.warp = warp
        while sim.time - start < 10 { sim.advance(by: 1.0 / 60) }
        for m in motors { XCTAssertFalse(m.isDelivering) }
        return (v.velocity.dot(x) - v0, motors)
    }

    // A lit solid burns its 100 kg grain in 50 kN x 3.92266 s (Isp_eff
    // 200 s) and stops at burnout: the step ends there, so its Δv, Isp g0
    // ln(m0/m1) = 0.1961 m/s on a 1,000 t block, is the same at 1x and
    // 1000x (one 0.02 s step too many would add 1e-3 m/s; the heavy block
    // makes the integrator's mass-at-step-start bias 5e-8 m/s). In the main,
    // retro and translate-forward groups, it is unlit with the throttles and
    // translation commands full on (they set its level, which a solid does
    // not read), and lit, neither disabling it nor zero commands stop it.
    func testSolidBurnsItsGrainOutWhateverTheControls() throws {
        for warp in [1.0, 1000] {
            let run = try deltaV(warp: warp, { part in
                [solid("Motor", in: part, thrust: 50_000, burn: 3.92266, propellant: 100, x: 0, direction: .unitX,
                       groups: [.main, .retro, .translateForward])]
            }, before: { v in
                v.mainThrottle = 1
                v.retroThrottle = 1
                v.translationInput = Vec3(1, 1, 1)
            }, after: { v in
                XCTAssertGreaterThan(v.thrusters[0].level, 0, "the controls drove its level")
                XCTAssertFalse(v.thrusters[0].ignite(), "a solid lights once")
                v.thrusters[0].isEnabled = false
                v.mainThrottle = 0
                v.retroThrottle = 0
                v.translationInput = .zero
            })
            XCTAssertEqual(run.motors[0].tank?.mass, 0)
            XCTAssertEqual(run.dv, 200 * g0 * log(1_000_100 / 1e6), accuracy: 1e-7, "warp \(warp)")
        }
    }

    // Two motors on one 100 kg grain (25 kN each, Isp_eff 200 s) empty it
    // together in 3.92266 s: the step ends at the grain's burnout at both
    // motors' flow, so the Δv is the same at 1x and 1000x; with 0.0127 s or,
    // under the 1 ms minimum step, 0.0005 s of grain left, the next step ends
    // there.
    func testASharedGrainEndsTheStepAtBurnout() throws {
        for warp in [1.0, 1000] {
            let run = try deltaV(warp: warp) { part in
                let grain = PropellantTank(name: "Grain", capacity: 100, geometry: .point(.zero))
                part.tanks.append(grain)
                return [-0.5, 0.5].map { x in
                    solid("Motor \(x)", in: part, thrust: 25_000, burn: 3.92266, propellant: 50, x: x,
                          direction: .unitX, grain: grain)
                }
            }
            XCTAssertEqual(run.dv, 200 * g0 * log(1_000_100 / 1e6), accuracy: 1e-7, "warp \(warp)")
        }
        for left in [0.0127, 0.0005] {
            let sim = try Simulation.forTests(perturbations: false)
            let part = VesselPart(name: "Block", dryMass: 1_000, length: 2, radius: 1, staging: .fixed)
            let grain = PropellantTank(name: "Grain", capacity: 100, geometry: .point(.zero))
            part.tanks.append(grain)
            let motors = [-0.5, 0.5].map { x in
                solid("Motor \(x)", in: part, thrust: 25_000, burn: 3.92266, propellant: 50, x: x,
                      direction: .unitX, grain: grain)
            }
            let v = Vessel(name: "Block", parts: [part], reference: VesselLibrary.placeholderBody)
            sim.add(v)
            sim.placeInFreeSpace(v)
            for m in motors { m.ignite() }
            grain.mass = 100 * left / 3.92266
            XCTAssertEqual(sim.maxStep(), left, accuracy: 1e-12, "\(left) s left")
        }
    }

    // A dud (disabled before it is lit), an empty grain and a liquid engine
    // do not light.
    func testDudsAndLiquidEnginesDoNotLight() {
        let part = VesselPart(name: "Block", dryMass: 1_000, length: 2, radius: 1, staging: .fixed)
        let dud = solid("Dud", in: part, thrust: 1_000, burn: 1, propellant: 1, x: 0, direction: .unitX)
        dud.isEnabled = false
        XCTAssertFalse(dud.ignite())
        XCTAssertFalse(dud.isCommanded)
        let empty = solid("Empty", in: part, thrust: 1_000, burn: 1, propellant: 1, x: 0, direction: .unitX)
        empty.tank?.mass = 0
        XCTAssertFalse(empty.ignite())
        let liquid = Toy.stage().thrusters[0]
        XCTAssertFalse(liquid.ignite())
        XCTAssertFalse(liquid.isIgnited)
    }

    // Staging event 1 lights the booster's retro (it leaves, and burns on as
    // the spent vessel's) and the core's ullage motor (event 1, it stays), and
    // gives no spring speed when the booster's `separationSpeed` is 0. Each
    // burns its grain into its own vessel only: the spent booster loses
    // 250 g0 ln(m0/m1) along -x, the stack gains 230 g0 ln(m0/m1) along +x
    // (within 1e-4: the integrator applies each step's thrust to the mass
    // at its start). The rule lights nothing else: not a retro on a part
    // that stays, nor an ullage motor of another event, nor one on a part
    // that leaves with its event. A disabled retro stays a dud.
    func testStagingLightsRetrosAndUllageMotors() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = Toy.stack()
        let booster = v.parts[0], interstage = v.parts[1], core = v.parts[2], upper = v.parts[4]
        booster.separationSpeed = 0
        let retro = solid("Retro", in: booster, thrust: 400_000, burn: 0.6, propellant: 400 * 0.6 / (250 * g0) * 1_000,
                          x: 8, direction: -Vec3.unitX, trigger: .ownSeparation)
        let ullage = solid("Ullage", in: core, thrust: 20_000, burn: 4, propellant: 20 * 4 / (230 * g0) * 1_000,
                           x: -9, direction: .unitX, trigger: .event(1))
        let interstageRetro = solid("Interstage retro", in: interstage, thrust: 1_000, burn: 1, propellant: 1, x: 0,
                                    direction: -Vec3.unitX, trigger: .ownSeparation)
        let leavingUllage = solid("Leaving ullage", in: interstage, thrust: 1_000, burn: 1, propellant: 1, x: 0,
                                  direction: .unitX, trigger: .event(2))
        let upperUllage = solid("Upper ullage", in: upper, thrust: 1_000, burn: 1, propellant: 1, x: -9,
                                direction: .unitX, trigger: .event(4))
        let dud = solid("Dud retro", in: interstage, thrust: 1_000, burn: 1, propellant: 1, x: 0,
                        direction: -Vec3.unitX, trigger: .ownSeparation)
        dud.isEnabled = false
        sim.add(v)
        let x = sim.placeInFreeSpace(v)
        // Every pre-separation mass, with the grains aboard.
        let boosterMass = booster.mass
        let stackMass = v.mass - boosterMass

        let spent = try XCTUnwrap(sim.stage(v, event: 1))
        XCTAssertTrue(retro.isIgnited && retro.isCommanded)
        XCTAssertTrue(ullage.isIgnited && ullage.isCommanded)
        XCTAssertFalse(interstageRetro.isIgnited, "a retro on a part that stays")
        XCTAssertFalse(leavingUllage.isIgnited, "an ullage motor of another event")
        XCTAssertFalse(upperUllage.isIgnited, "an ullage motor of another event")
        XCTAssertEqual(spent.velocity.dot(x), v.velocity.dot(x), accuracy: 1e-9, "no spring kick")
        let spentV0 = spent.velocity.dot(x), stackV0 = v.velocity.dot(x)
        for _ in 0..<300 { sim.tick() }   // 6 s
        XCTAssertEqual(retro.tank?.mass, 0)
        XCTAssertEqual(ullage.tank?.mass, 0)
        let retroGrain = 400 * 0.6 / (250 * g0) * 1_000, ullageGrain = 20 * 4 / (230 * g0) * 1_000
        let retroDV = 250 * g0 * log(boosterMass / (boosterMass - retroGrain))
        let ullageDV = 230 * g0 * log(stackMass / (stackMass - ullageGrain))
        XCTAssertEqual(spent.velocity.dot(x) - spentV0, -retroDV, accuracy: 1e-4 * retroDV)
        XCTAssertEqual(v.velocity.dot(x) - stackV0, ullageDV, accuracy: 1e-4 * ullageDV)

        XCTAssertNotNil(sim.stage(v, event: 2))
        XCTAssertTrue(interstageRetro.isIgnited, "its own part's separation")
        XCTAssertFalse(leavingUllage.isIgnited, "an ullage motor on a part that leaves with its event")
        XCTAssertFalse(upperUllage.isIgnited, "an ullage motor of another event")
        XCTAssertFalse(dud.isIgnited, "a dud")
    }
}
