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

    /// One engine on large tanks, stepped by hand like `Vessel.consumePropellant`.
    func engine(_ transients: EngineTransients? = nil, unusable: Double = 0) -> (Thruster, PropellantTank, PropellantTank) {
        let ox = PropellantTank(name: "Ox", capacity: 100_000, unusableMass: unusable)
        let fuel = PropellantTank(name: "Fuel", capacity: 100_000)
        let e = Thruster(name: "E", position: .zero, direction: .unitX, rating: Toy.engine,
                         feed: .bipropellant(oxidizer: ox, fuel: fuel), groups: [.main])
        e.transients = transients
        e.level = 1
        return (e, ox, fuel)
    }

    func step(_ e: Thruster, _ n: Int, impulse: inout Double) {
        for _ in 0..<n {
            impulse += e.thrust(ambientPressure: 0, seaLevelPressure: 0) * 0.02
            if e.massFlow > 0 { e.draw(dt: 0.02) }
            e.advanceTransients(dt: 0.02)
        }
    }

    // A6: a performance schedule scales thrust and flow along the burn clock
    // and moves the mixture ratio, on the same nozzle (the pressure loss stays
    // p A_e). It holds beyond its last knot, and the clock restarts when the
    // engine is lit again.
    func testPerformanceScheduleFollowsTheBurnClock() {
        let (e, ox, fuel) = engine()
        e.schedule = PerformanceSchedule([.init(time: 0, thrustFactor: 1, flowFactor: 1, mixtureRatio: 2.5),
                                          .init(time: 10, thrustFactor: 1.1, flowFactor: 1.05, mixtureRatio: 3.0)])
        var impulse = 0.0
        step(e, 250, impulse: &impulse)   // 5 s
        XCTAssertEqual(e.burnTime, 5, accuracy: 1e-9)
        XCTAssertEqual(e.maxThrustVacuum, 1.05e6, accuracy: 1e-3)
        XCTAssertEqual(e.currentRating.massFlow, Toy.engine.massFlow * 1.025, accuracy: 1e-9)
        XCTAssertEqual(e.currentRating.mixtureRatio ?? 0, 2.75, accuracy: 1e-12)
        XCTAssertEqual(e.currentRating.impliedExitArea, 0.8, accuracy: 1e-9)
        XCTAssertEqual(e.thrust(ambientPressure: 101_325, seaLevelPressure: 101_325), 1.05e6 - 101_325 * 0.8,
                       accuracy: 1e-3)
        // Propellant and impulse so far: the integrals of the schedule
        // (each 0.02 s step at its start value, so within half a step's change).
        var oxExpected = 0.0, fuelExpected = 0.0
        for k in 0..<50_000 {
            let t = (Double(k) + 0.5) * 1e-4, mdot = Toy.engine.massFlow * (1 + 0.005 * t), r = 2.5 + 0.05 * t
            oxExpected += mdot * r / (1 + r) * 1e-4
            fuelExpected += mdot / (1 + r) * 1e-4
        }
        XCTAssertEqual(100_000 - ox.mass, oxExpected, accuracy: oxExpected * 2e-4)
        XCTAssertEqual(100_000 - fuel.mass, fuelExpected, accuracy: fuelExpected * 2e-4)
        XCTAssertEqual(impulse, 1e6 * (5 + 0.01 * 12.5), accuracy: 1e6 * 5 * 2e-4)
        step(e, 500, impulse: &impulse)   // 15 s
        XCTAssertEqual(e.maxThrustVacuum, 1.1e6, accuracy: 1e-3)
        e.level = 0
        e.advanceTransients(dt: 0.02)
        XCTAssertEqual(e.burnTime, 0)
        e.level = 1
        XCTAssertEqual(e.maxThrustVacuum, 1e6, accuracy: 1e-6)
        XCTAssertEqual(e.currentRating.mixtureRatio ?? 0, 2.5, accuracy: 1e-12)
    }

    // A7: a start ramp. The engine is commanded (it counts as lit for the
    // controls) but gives nothing for the delay, then rises linearly; sampled
    // at each step's middle, the start impulse and propellant are exactly
    // half the rise at full thrust.
    func testStartRampDelaysThenRaisesThrust() {
        let (e, ox, fuel) = engine(EngineTransients(startDelay: 0.5, startRise: 1.0))
        var impulse = 0.0
        step(e, 24, impulse: &impulse)    // the next step, 0.48-0.50 s, is the last of the delay
        XCTAssertTrue(e.isCommanded)
        XCTAssertFalse(e.isDelivering)
        step(e, 1, impulse: &impulse)
        XCTAssertEqual(impulse, 0)
        XCTAssertTrue(e.isDelivering)
        step(e, 125, impulse: &impulse)   // to 3 s
        XCTAssertEqual(impulse, 1e6 * (3 - 0.5 - 0.5), accuracy: 1e-3)
        XCTAssertEqual(200_000 - ox.mass - fuel.mass, Toy.engine.massFlow * 2, accuracy: 1e-6)
        XCTAssertEqual(e.thrust(ambientPressure: 0, seaLevelPressure: 0), 1e6)
    }

    // A8, a relight during the decay: a cut engine runs its shutdown ramp to
    // the end before it can start again (0.3 s of full thrust here, however
    // soon it is commanded), then starts with its full start ramp.
    func testRelightWaitsForTheShutdownRamp() {
        let (e, _, _) = engine(EngineTransients(startDelay: 0.2, startRise: 0.4, shutdown: 0.6))
        var impulse = 0.0
        step(e, 50, impulse: &impulse)
        e.level = 0
        impulse = 0
        step(e, 5, impulse: &impulse)
        e.level = 1
        XCTAssertFalse(e.isCommanded)
        XCTAssertTrue(e.isDelivering)
        step(e, 25, impulse: &impulse)
        XCTAssertEqual(impulse, 1e6 * 0.3, accuracy: 1e-3)
        XCTAssertFalse(e.isDelivering)
        XCTAssertTrue(e.isCommanded)
        impulse = 0
        step(e, 30, impulse: &impulse)
        XCTAssertEqual(impulse, 1e6 * 0.2, accuracy: 1e-3)
        XCTAssertEqual(e.burnTime, 0.6, accuracy: 1e-9)
    }

    // A8: a shutdown ramp. Cut off (here disabled, as the IU cuts an engine)
    // or run dry, the engine falls linearly from full to zero over the ramp:
    // half the ramp of full-thrust impulse, drawing the tail-off propellant
    // from below the unusable mass. It is no longer commanded, so the IU
    // senses the cutoff at once.
    func testShutdownRampAfterCutoffAndDepletion() {
        let (e, ox, fuel) = engine(EngineTransients(shutdown: 0.6), unusable: 300)
        var impulse = 0.0
        step(e, 50, impulse: &impulse)
        let (ox1, fuel1) = (ox.mass, fuel.mass)
        e.isEnabled = false
        impulse = 0
        XCTAssertFalse(e.isCommanded)
        XCTAssertTrue(e.isDelivering)
        step(e, 50, impulse: &impulse)
        XCTAssertEqual(impulse, 1e6 * 0.3, accuracy: 1e-3)
        XCTAssertEqual(ox1 + fuel1 - ox.mass - fuel.mass, Toy.engine.massFlow * 0.3, accuracy: 1e-6)
        XCTAssertFalse(e.isDelivering)

        // Run dry: the depleting step runs to its end, then the ramp draws
        // below the oxidizer's unusable 300 kg (never below zero).
        let (d, dOx, _) = engine(EngineTransients(shutdown: 0.6), unusable: 300)
        dOx.mass = 300 + Toy.engine.massFlow * 2.5 / 3.5 * 1.01   // 1.01 s of oxidizer
        var dImpulse = 0.0
        step(d, 51, impulse: &dImpulse)   // the 51st step runs dry
        XCTAssertFalse(d.hasPropellant)
        XCTAssertEqual(dOx.mass, 300)
        dImpulse = 0
        step(d, 50, impulse: &dImpulse)
        XCTAssertEqual(dImpulse, 1e6 * 0.3, accuracy: 1e-3)
        XCTAssertEqual(300 - dOx.mass, Toy.engine.massFlow * 2.5 / 3.5 * 0.3, accuracy: 1e-6)
    }

    // A9: the HUD's Δv follows a schedule: a free-space burn to depletion
    // with flow rising 10 % and thrust 12 % achieves it.
    func testMainDeltaVFollowsTheSchedule() throws {
        let stage = Toy.stage()
        for e in stage.thrusters {
            e.position = Vec3(-10, 0, 0)
            e.schedule = PerformanceSchedule([.init(time: 0, thrustFactor: 1, flowFactor: 1),
                                              .init(time: 60, thrustFactor: 1.12, flowFactor: 1.1)])
        }
        let v = Vessel(name: "Toy", parts: [stage], reference: VesselLibrary.placeholderBody)
        let expected = v.mainDeltaV
        let sim = try Simulation.forTests(perturbations: false)
        sim.add(v)
        let x = sim.placeInFreeSpace(v)
        v.mainThrottle = 1
        for _ in 0..<10_000 where stage.thrusters[0].hasPropellant { sim.tick() }
        XCTAssertEqual(v.velocity.dot(x), expected, accuracy: expected * 1e-3)
    }

    // A10: a rating ramp (`.rating(part:_:ramp:)`, for the S-II's EMR
    // shift): thrust, flow and mixture ratio move linearly from one setting
    // to the next in equal cells of at most 0.02 s, each at its middle's
    // value, and the IU ends steps on the cells' ends. Over the ramp the
    // impulse is then the linear ramp's, (F0 + F1)/2 times its length, the
    // propellant (ṁ0 + ṁ1)/2 times it, and its split the same, however the
    // steps fall: fixed 0.02 s and 0.007 s steps and the app's frames at 1×,
    // 10× and 1,000×.
    // The bound is the epoch's resolution (1.2e-7 s in 1969: 1e-6 of the
    // impulse) and the simulation's 1 ms minimum step: a step that starts
    // less than 1 ms before a cell's end (after a frame's end, or the
    // epoch's rounding) is stretched to 1 ms past it, and runs that part at
    // the earlier cell's value, at most a cell's change for 1 ms. Steps that
    // ignore the cells' ends (0.013 s, not bounded by the IU) err by over
    // 1e-4. Two toy engines go from `Toy.engine` (1 MN) to `Toy.lowRating`
    // (0.8 MN) over 0.73 s (37 cells), lit at 0.5 s and shifted at 1.0 s.
    func testRatingRampImpulseIsIndependentOfStepAndWarp() throws {
        let plan = SaturnIU.Plan(
            liftoffDelay: 0, referenceToLiftoff: 0, flightAzimuth: 0, towerYaw: (0, 0, 0),
            programStart: (1e9, 1e9), tilt: TiltProgram(boundaries: [], coefficients: [[0, 0, 0, 0, 0]], arrest: 0),
            commandRateLimit: 0.02, coastRateLimit: Vec3(0.01, 0.01, 0.01), cant: (0, 0),
            sequence: [SaturnIU.Event(.t1, 0.5, "ignition", .mainThrottle(1)),
                       SaturnIU.Event(.t1, 1.0, "shift", .rating(part: "Stage", Toy.lowRating, ramp: 0.73))],
            // Engine 2 as the "centre engine": the IU never cuts it, so no T2.
            stages: ("Stage", "-", "-"), centreEngine: "Stage engine 2", guidance: nil)
        let ramp = 0.73, cells = Thruster.rampCells(ramp)
        XCTAssertEqual(cells, 37)
        /// The impulse (N s), oxidizer and fuel (kg) over the ramp, its steps
        /// and those stretched to the 1 ms minimum, flown in fixed steps of
        /// `step` s or in frames of `frame` s at `warp`; `bounded`: steps end
        /// where the IU asks.
        func fly(step: Double = 0.02, frame: Double? = nil, warp: Double = 1, bounded: Bool = true)
            throws -> (impulse: Double, ox: Double, fuel: Double, steps: Int, stretched: Int) {
            let sim = try Simulation.forTests(perturbations: false)
            let v = Toy.rocket()
            sim.add(v)
            sim.placeInFreeSpace(v)
            let iu = SaturnIU(plan: plan)
            v.flightProgram = iu
            let mains = v.thrusters.filter { $0.groups.contains(.main) }, tanks = v.parts[0].tanks
            let start = sim.time
            var shift: (at: Epoch, ox: Double, fuel: Double)?, drawn: (ox: Double, fuel: Double)?
            var impulse = 0.0, steps = 0, stretched = 0
            while sim.time - start < 2 {
                var remaining = frame.map { $0 * warp } ?? step
                while remaining > 1e-9 {
                    for w in sim.vessels { sim.prepareControls(w) }
                    if shift == nil, iu.log.contains(where: { $0.event == "shift" }) {
                        shift = (sim.time, tanks[0].mass, tanks[1].mass)
                    }
                    let most = sim.maxStep()
                    let h = min(remaining, frame == nil ? step : .infinity, bounded ? most : .infinity)
                    if let s = shift, sim.time - s.at < ramp - 1e-6 {
                        impulse += mains.reduce(0) { $0 + $1.thrust(ambientPressure: 0, seaLevelPressure: 0) } * h
                        steps += 1
                        if most == 1e-3 && h == most { stretched += 1 }
                    } else if let s = shift, drawn == nil {
                        drawn = (s.ox - tanks[0].mass, s.fuel - tanks[1].mass)
                    }
                    sim.step(h)
                    remaining -= h
                }
            }
            let d = try XCTUnwrap(drawn)
            return (impulse, d.ox, d.fuel, steps, stretched)
        }
        let impulse = (2e6 + 1.6e6) / 2 * ramp
        let flows = (Toy.engine.massFlow, Toy.lowRating.massFlow), flow = (flows.0 + flows.1) * ramp
        // A cell's change for 1 ms.
        let cellImpulse = (2e6 - 1.6e6) / Double(cells) * 1e-3, cellFlow = 2 * (flows.0 - flows.1) / Double(cells) * 1e-3
        let reference = try fly()
        var runs = [("0.02 s", reference), ("0.007 s", try fly(step: 0.007)), ("1x", try fly(frame: 1.0 / 60)),
                    ("10x", try fly(frame: 1.0 / 60, warp: 10)), ("1000x", try fly(frame: 1.0 / 60, warp: 1000))]
        // The split from a run no step of which was stretched.
        let exact = try XCTUnwrap(runs.first { $0.1.stretched == 0 }).1
        for (name, run) in runs {
            let n = Double(run.stretched)
            XCTAssertEqual(run.impulse, impulse, accuracy: impulse * 1e-6 + n * cellImpulse, name)
            XCTAssertEqual(run.ox + run.fuel, flow, accuracy: flow * 1e-6 + n * cellFlow, name)
            XCTAssertEqual(run.ox, exact.ox, accuracy: exact.ox * 1e-6 + n * cellFlow, name)
            XCTAssertEqual(run.fuel, exact.fuel, accuracy: exact.fuel * 1e-6 + n * cellFlow, name)
        }
        runs.removeFirst()
        XCTAssertTrue(runs.allSatisfy { $0.1.steps != reference.steps })
        let unbounded = try fly(step: 0.013, bounded: false)
        XCTAssertGreaterThan(abs(unbounded.impulse - impulse), impulse * 1e-4)
    }
}

