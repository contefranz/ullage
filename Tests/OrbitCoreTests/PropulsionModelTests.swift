import XCTest
@testable import OrbitCore

/// Propellant feeds, engine ratings and main-engine controls on toy vehicles
/// (design tests A1-A5). Expected values are worked out from `Toy`'s literals.
final class PropulsionModelTests: XCTestCase {
    let g0 = 9.80665

    // A1: shared bipropellant feed, oxidizer runs out first.
    func testBipropellantDrawKeepsMixtureRatioAndStopsAtUnusableMass() {
        let stage = Toy.stage()
        let v = Vessel(name: "Toy", parts: [stage], reference: VesselLibrary.placeholderBody)
        let ox = stage.tanks[0], fuel = stage.tanks[1]
        for e in stage.thrusters { e.level = 1 }

        XCTAssertTrue(v.consumePropellant(dt: 0.02))
        XCTAssertEqual((30_000 - ox.mass) / (13_000 - fuel.mass), 2.5, accuracy: 1e-9)

        // 2 x 1 MN at 300 s draw 2e6 / (300 g0) kg/s, 2.5/3.5 of it oxidizer.
        // Usable oxidizer 29 700 kg needs 11 880 kg of the 12 800 kg usable fuel.
        let oxFlow = 2e6 / (300 * g0) * 2.5 / 3.5
        var t = 0.02
        while t < 300 && v.consumePropellant(dt: 0.02) { t += 0.02 }   // about 61 s
        XCTAssertEqual(ox.mass, 300)
        XCTAssertEqual(fuel.mass, 13_000 - 29_700 / 2.5, accuracy: 1e-6)
        XCTAssertEqual(t, 29_700 / oxFlow, accuracy: 0.02)
        for e in stage.thrusters {
            XCTAssertFalse(e.hasPropellant)
            XCTAssertEqual(e.thrust(ambientPressure: 0, seaLevelPressure: 0), 0)
            XCTAssertEqual(e.massFlow, 0)
        }
        XCTAssertEqual(v.mainDeltaV, 0)
    }

    // A1, the other way round: a fuel-short load ends on fuel.
    func testBipropellantDrawStopsOnFuelWhenFuelRunsOutFirst() {
        let stage = Toy.stage()
        let v = Vessel(name: "Toy", parts: [stage], reference: VesselLibrary.placeholderBody)
        let ox = stage.tanks[0], fuel = stage.tanks[1]
        fuel.mass = 10_000   // usable 9 800 kg burns 24 500 kg of oxidizer
        for e in stage.thrusters { e.level = 1 }
        var t = 0.0
        while t < 300 && v.consumePropellant(dt: 0.02) { t += 0.02 }   // about 50 s
        XCTAssertEqual(fuel.mass, 200)
        XCTAssertEqual(ox.mass, 30_000 - 9_800 * 2.5, accuracy: 1e-6)
    }

    // A depleting draw leaves the limiting tank exactly at its unusable mass,
    // so the engine stops instead of firing another full-thrust step on a
    // rounding residue (here 4e-16 kg if the scaled draw were subtracted).
    func testDepletingDrawEndsExactlyAtUnusableMass() {
        let ox = PropellantTank(name: "Ox", capacity: 1_000, mass: 3.5)
        let fuel = PropellantTank(name: "Fuel", capacity: 1_000)
        let e = Thruster(name: "E", position: .zero, direction: .unitX, rating: Toy.engine,
                         feed: .bipropellant(oxidizer: ox, fuel: fuel), groups: [.main])
        e.level = 1
        e.draw(dt: 0.02)   // wants 4.86 kg of oxidizer
        XCTAssertEqual(ox.mass, 0)
        XCTAssertFalse(e.hasPropellant)
        XCTAssertEqual(fuel.mass, 1_000 - 3.5 / 2.5, accuracy: 1e-12)
    }

    func testSingleFeedStopsAtUnusableMass() {
        let tank = PropellantTank(name: "T", capacity: 1_000, unusableMass: 40)
        let t = Thruster(name: "T", position: .zero, direction: .unitX, maxThrustVacuum: 1e5, ispVacuum: 250,
                         tank: tank, groups: [.main])
        XCTAssertTrue(t.tank === tank)
        XCTAssertNil(Toy.stage().thrusters[0].tank)   // bipropellant engines have no single tank
        t.level = 1
        for _ in 0..<100 where t.massFlow > 0 { t.draw(dt: 1) }   // 40.8 kg/s: 24 draws
        XCTAssertEqual(tank.mass, 40)
        XCTAssertEqual(tank.usableMass, 0)
        XCTAssertFalse(t.hasPropellant)
        XCTAssertEqual(t.thrust(ambientPressure: 0, seaLevelPressure: 0), 0)
    }

    // Two settings of one fixed nozzle lose p A_e of thrust at any pressure.
    func testFixedNozzleRatingsShareThePressureLoss() {
        XCTAssertEqual(Toy.engine.ispSeaLevel, 300 * (1 - 101_325 * 0.8 / 1e6), accuracy: 1e-12)
        let tank = PropellantTank(name: "T", capacity: 1_000)
        for rating in [Toy.engine, Toy.lowRating] {
            XCTAssertEqual(rating.impliedExitArea, 0.8, accuracy: 1e-12)
            let t = Thruster(name: "T", position: .zero, direction: .unitX, rating: rating, feed: .single(tank),
                             groups: [.main])
            t.level = 1
            for p in [0, 50_000, 101_325.0] {
                XCTAssertEqual(t.thrust(ambientPressure: p, seaLevelPressure: 101_325), rating.thrustVacuum - p * 0.8,
                               accuracy: 1e-6)
            }
        }
    }

    // A2: assigning a rating (like the J-2 mixture-ratio shift) changes thrust,
    // flow and propellant split together.
    func testAssigningRatingChangesThrustFlowAndSplitTogether() {
        let stage = Toy.stage()
        let ox = stage.tanks[0], fuel = stage.tanks[1]
        let e = stage.thrusters[0]
        e.level = 1
        e.rating = Toy.lowRating
        let flow = 0.8e6 / (305 * g0)
        XCTAssertEqual(e.maxThrustVacuum, 0.8e6)
        XCTAssertEqual(e.ispVacuum, 305)
        XCTAssertEqual(e.thrust(ambientPressure: 0, seaLevelPressure: 101_325), 0.8e6, accuracy: 1e-6)
        XCTAssertEqual(e.thrust(ambientPressure: 101_325, seaLevelPressure: 101_325), 0.8e6 - 101_325 * 0.8,
                       accuracy: 1e-6)
        XCTAssertEqual(e.massFlow, flow, accuracy: 1e-9)
        e.draw(dt: 1)
        XCTAssertEqual(30_000 - ox.mass, flow * 2 / 3, accuracy: 1e-9)
        XCTAssertEqual(13_000 - fuel.mass, flow / 3, accuracy: 1e-9)
    }

    // A3: on/off engines run at full level for any positive command; the
    // default 0...1 range is M0's `min(1, throttle)`.
    func testThrottleRangeClampsCommands() {
        let toy = Toy.rocket()
        let mains = toy.thrusters.filter { $0.groups.contains(.main) }
        XCTAssertEqual(mains.count, 2)
        for (command, expected) in [(0.0, 0.0), (0.01, 1.0), (0.3, 1.0), (1.0, 1.0), (1.5, 1.0)] {
            toy.mainThrottle = command
            toy.applyControls(rotation: RotationCommand())
            for e in mains { XCTAssertEqual(e.level, expected, "throttle \(command)") }
        }

        let m0 = VesselLibrary.testRocket()
        let s1 = m0.thrusters.first { $0.name == "S1 engine" }!
        XCTAssertEqual(s1.throttleRange, 0...1)
        for command in [0.0, 0.01, 0.3, 1.0, 1.5] {
            m0.mainThrottle = command
            m0.applyControls(rotation: RotationCommand())
            XCTAssertEqual(s1.level, min(1, command))
        }

        // A deep-throttling range: positive commands are clamped into it, zero stays off.
        s1.throttleRange = 0.1...0.6
        for (command, expected) in [(0.0, 0.0), (0.05, 0.1), (0.3, 0.3), (0.9, 0.6)] {
            m0.mainThrottle = command
            m0.applyControls(rotation: RotationCommand())
            XCTAssertEqual(s1.level, expected, "throttle \(command)")
        }

        // Attitude commands are clamped the same way.
        let pitchUp = m0.thrusters.filter { $0.groups.contains(.pitchUp) }
        let onOff = pitchUp[0]
        onOff.throttleRange = 1...1
        m0.applyControls(rotation: RotationCommand(pitch: 0.2))
        XCTAssertEqual(onOff.level, 1)
        for t in pitchUp.dropFirst() { XCTAssertEqual(t.level, 0.2) }
    }

    // A3 in the simulation: on/off engines lift off at full thrust from a 30 % command.
    func testOnOffEnginesLiftOffAtFullThrustFromPartialThrottle() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = Toy.rocket()
        sim.add(v)
        sim.placeLanded(v, on: sim.system.earth, latitude: 28.6083, longitude: -80.6041)
        let m0 = v.mass
        let p = sim.system.earth.atmosphere!.state(altitude: v.altitude).pressure
        v.mainThrottle = 0.3
        sim.tick()
        XCTAssertEqual(v.status, .flying)
        XCTAssertTrue(sim.events.contains { $0.message.contains("liftoff") })
        // Two fixed nozzles at full level: F = 2 (F_vac - p A_e).
        XCTAssertEqual(v.thrustAcceleration, 2 * (1e6 - p * 0.8) / m0, accuracy: 1e-9)
    }

    // A4: a disabled engine gives no thrust or flow, drops out of `mainDeltaV`
    // and `rotationAuthority`, and does not hand the throttle to the next stage.
    func testDisabledEngineIsShutDownButStaysInActiveStage() {
        let lower = Toy.stage("Lower", offset: Vec3(10, 0, 0))
        lower.addRCS(foreX: 8, aftX: -8, radius: 2, thrust: 2_000, isp: 280, tank: lower.tanks[1])
        let upper = Toy.stage("Upper", offset: Vec3(30, 0, 0))
        let v = Vessel(name: "Toy", parts: [lower, upper], reference: VesselLibrary.placeholderBody)
        let e1 = lower.thrusters[0], e2 = lower.thrusters[1]
        e2.rating = Toy.lowRating

        e1.isEnabled = false
        v.mainThrottle = 1
        v.applyControls(rotation: RotationCommand())
        XCTAssertEqual(e1.thrust(ambientPressure: 0, seaLevelPressure: 0), 0)
        XCTAssertEqual(e1.massFlow, 0)
        XCTAssertEqual(e2.thrust(ambientPressure: 0, seaLevelPressure: 0), 0.8e6)
        e1.draw(dt: 1)
        XCTAssertEqual(lower.tanks[0].mass, 30_000)

        // Engine 2 alone (MR 2.0) runs out of fuel first: 12 800 kg of fuel
        // takes 25 600 kg of oxidizer, out of 102 t.
        let single = 305 * g0 * log(102_000 / (102_000 - 12_800 * 3))
        XCTAssertEqual(v.mainDeltaV, single, accuracy: single * 1e-12)

        let authority = v.rotationAuthority()
        XCTAssertGreaterThan(authority.y, 0)
        for t in v.thrusters where t.groups.contains(.pitchUp) { t.isEnabled = false }
        let reduced = v.rotationAuthority()
        XCTAssertEqual(reduced.y, 0)
        XCTAssertEqual(reduced.x, authority.x)
        XCTAssertEqual(reduced.z, authority.z)

        e2.isEnabled = false
        XCTAssertEqual(v.mainDeltaV, 0)
        XCTAssertTrue(v.activeStage === lower)
        v.applyControls(rotation: RotationCommand())
        for t in upper.thrusters { XCTAssertEqual(t.level, 0) }
        XCTAssertEqual(v.thrustForceAndTorque(ambientPressure: 0, seaLevelPressure: 0).force, .zero)
    }

    // A5: two different engines on one feed burn together until the first
    // tank is down to its unusable mass; the effective Isp is ΣF / Σṁ.
    func testMainDeltaVOfSharedBipropellantFeed() throws {
        let stage = Toy.stage()
        for e in stage.thrusters { e.position = Vec3(-10, 0, 0) }   // on the axis: no torque
        stage.thrusters[1].rating = Toy.lowRating
        let v = Vessel(name: "Toy", parts: [stage], reference: VesselLibrary.placeholderBody)

        // 1 MN at 300 s with MR 2.5, plus 0.8 MN at 305 s with MR 2.0. Fuel runs
        // out after 68.7 s, before the oxidizer would (70.5 s).
        let flowA = 1e6 / (300 * g0), flowB = 0.8e6 / (305 * g0)
        let oxRate = flowA * 2.5 / 3.5 + flowB * 2 / 3
        let fuelRate = flowA / 3.5 + flowB / 3
        let burnTime = min(29_700 / oxRate, 12_800 / fuelRate)
        XCTAssertEqual(burnTime, 12_800 / fuelRate)
        let expected = 1.8e6 / (flowA + flowB) * log(51_000 / (51_000 - (flowA + flowB) * burnTime))
        XCTAssertEqual(v.mainDeltaV, expected, accuracy: expected * 1e-9)

        // A free-space burn to depletion achieves it, give or take the last
        // step, which runs at full thrust.
        let sim = try Simulation.forTests(perturbations: false)
        sim.add(v)
        let x = sim.placeInFreeSpace(v)
        v.mainThrottle = 1
        for _ in 0..<10_000 where stage.thrusters[0].hasPropellant { sim.tick() }   // about 3,440 steps
        XCTAssertEqual(stage.tanks[1].mass, 200)
        XCTAssertEqual(v.velocity.dot(x), expected, accuracy: 0.02 * 1.8e6 / v.mass)
    }
}
