import XCTest
@testable import OrbitCore

/// The CSM's separations: from the S-IVB (event 6) with the SLA panels, and
/// CM/SM (event 7) with the SM jettison controller, against 68-FM-184,
/// 68-FM-160 and MSC-03466, and the staging rules they need: the crew
/// keeps the vessel, the IU's program and laws leave with the IU.
final class CSMSeparationTests: XCTestCase {
    /// A program on the IU that only lets the pilot stage.
    final class IUStandIn: FlightProgram {
        func update(_ vessel: Vessel, in sim: Simulation) {}
        func timeToNextEvent(at now: Epoch) -> Double? { nil }
        var status: String { "IU stand-in" }
        var hostPart: String? { "IU" }
    }

    let ft = 0.3048, deg = Double.pi / 180

    func part(_ v: Vessel, _ name: String) -> VesselPart? { v.parts.first { $0.name == name } }

    // Space through the whole stack in orbit: S-IC, interstage, LES, S-II,
    // the S-IVB's ullage cases, then CSM/S-IVB separation, which makes five
    // vessels (the S-IVB, IU, SLA ring and LM as "Apollo 11 – S-IVB", the
    // main one, and each SLA panel on its own), and CM/SM separation, which
    // the CSM's SCS (on standby in the CM, in charge once the IU has gone)
    // takes only on a second press within 2 s. The crewed vessel keeps its
    // identity, name and focus throughout; mass and momentum are conserved.
    func testSpaceSequenceOneToSeven() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.saturnV()
        let iu = IUStandIn()
        v.flightProgram = iu
        sim.add(v)
        sim.placeInCircularOrbit(v, around: sim.system.earth, altitude: 400_000)
        let id = v.id, m = v.mass, momentum = v.velocity * m
        var clock = 0.0
        sim.clock = { clock }
        var separated: [[String]] = []
        for _ in 1...6 { if let spent = sim.stage(v) { separated.append(spent.parts.map(\.name)) } }
        XCTAssertEqual(sim.vessels.count, 1 + 5 + 5)
        XCTAssertEqual(sim.vessels.reduce(0) { $0 + $1.mass }, m, accuracy: 1e-6)
        let after = sim.vessels.reduce(Vec3.zero) { $0 + $1.velocity * $1.mass }
        XCTAssertLessThan((after - momentum).length, momentum.length * 1e-12)
        sim.tick()                       // the SCS, in charge now, takes the simulation's clock
        XCTAssertNil(sim.stage(v))       // the first press for event 7 arms the guard
        XCTAssertEqual(separated, [["S-IC"], ["S-IC/S-II interstage"], ["LES"], ["S-II", "S-II/S-IVB interstage"],
                                   ["S-IVB ullage rockets"], ["S-IVB", "IU", "SLA ring", "LM"]])
        XCTAssertEqual(sim.vessels.map(\.name).suffix(5), ["Apollo 11 – S-IVB", "Apollo 11 – SLA panel 1",
                                                           "Apollo 11 – SLA panel 2", "Apollo 11 – SLA panel 3",
                                                           "Apollo 11 – SLA panel 4"])
        // The IU's program left with the S-IVB; the SCS took over and
        // refused the first press for event 7.
        XCTAssertTrue(sim.vessels.first { $0.name == "Apollo 11 – S-IVB" }?.flightProgram === iu)
        let scs = try XCTUnwrap(v.flightProgram as? ApolloSCS)
        XCTAssertTrue(v.parts.first { $0.name == "CM" }?.standbyProgram === scs)
        XCTAssertEqual(v.nextStagingEvent, 7)
        clock = 3
        XCTAssertNil(sim.stage(v))
        clock = 6.5                      // too late: 3.5 s after the first
        XCTAssertNil(sim.stage(v))
        clock = 7.9
        let sm = try XCTUnwrap(sim.stage(v))
        XCTAssertEqual(sm.parts.map(\.name), ["SM"])
        XCTAssertEqual(sm.name, "Apollo 11 – SM")
        XCTAssertEqual(v.parts.map(\.name), ["CM", "Apex cover", "Drogue parachutes", "Main parachutes"])
        XCTAssertTrue(v.id == id && v.name == "Apollo 11" && sim.focus === v)
        XCTAssertEqual(v.controlFrame, ApolloAxes.rotation)
        XCTAssertTrue(v.flightProgram === scs)
        XCTAssertEqual(sim.vessels.count, 1 + 5 + 5 + 1)
        // Debris does not split again, nor the panels.
        for w in sim.vessels where w !== v { XCTAssertTrue(w.jettisonNextStageAll().isEmpty, w.name) }
    }

    // The parking-orbit scenario (`apollo11InParkingOrbit`): at insertion,
    // range 709.33 s, on AS-506's postflight state (PFT Table B-II) turned
    // to ICRF through the frame the IU fixes when it lifts off (within
    // 1e-6 rad of the one a flight's IU fixes at T1); its osculating orbit
    // over the PFT's 6,378,165 m sphere, 186.0 x 183.3 km, against AS-506's
    // 186.0 x 185.2 km (the osculating perigee of a near-circular orbit
    // swings by kilometres with J2 and with 1 m/s); the stack's mass the
    // FER's at the end of burn 1's thrust decay (Table 20-5, 135,102 kg)
    // within 0.2 %, with the CSM's own mass distribution centred until it
    // separates; the IU at T5 + 9.8 s, its APS ullage on, as AS-506's.
    func testApollo11ParkingOrbitScenario() throws {
        let pad = try Simulation.forTests(perturbations: true)
        let stack = VesselLibrary.apollo11OnPad(in: pad)
        stack.mainThrottle = 1
        let liftoff = try XCTUnwrap(stack.flightProgram as? SaturnIU)
        while liftoff.spaceFixed == nil { pad.tick() }
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo11InParkingOrbit(in: sim)
        let frame = try XCTUnwrap((v.flightProgram as? SaturnIU)?.spaceFixed)
        XCTAssertLessThan(rotationVector(frame.conjugate * liftoff.spaceFixed!).length, 1e-6)
        XCTAssertEqual(sim.time - AS506.rangeZero, 709.33, accuracy: 1e-6)
        XCTAssertEqual(v.parts.map(\.name), SaturnVDataTests.parkingOrbitStack)
        let e = v.elements(snapshot: sim.snapshot)
        let sphere = 6_378_165.0
        print(String(format: "parking orbit: %.2f x %.2f km, %.1f kg", (e.apoapsisRadius - sphere) / 1000,
                     (e.periapsisRadius - sphere) / 1000, v.mass))
        XCTAssertEqual((e.apoapsisRadius - sphere) / 1000, 186.0, accuracy: 0.5)
        XCTAssertEqual((e.periapsisRadius - sphere) / 1000, 185.2, accuracy: 2.5)
        XCTAssertEqual(v.mass, 135_102, accuracy: 0.002 * 135_102)
        let iu = try XCTUnwrap(v.flightProgram as? SaturnIU)
        XCTAssertEqual(try XCTUnwrap(iu.timeBases[.t5]) - AS506.rangeZero, 699.57, accuracy: 1e-6)
        sim.tick()
        XCTAssertEqual(v.translationInput.x, 1)       // the APS ullage, to T5 + 87 s
        XCTAssertTrue(iu.status.hasPrefix("T5+"), iu.status)
        XCTAssertTrue(v.parts.first { $0.name == "SM" }?.centeredUntilEvent == 6)
    }

    // Apollo 11 in its parking orbit (`apollo11InParkingOrbit`), the IU
    // flying: the IU refuses the CSM's separation while the S-IVB burns,
    // and allows it once it is out. The separation leaves the IU's program
    // and every law it flies with on "Apollo 11 – S-IVB" (attitude hold,
    // its command, the APS law), which goes on holding the local horizontal
    // as the IU commands; the crewed vessel keeps its identity, takes the
    // CM's SCS (no autopilot, the CSM's phase-plane law, the crew's frame)
    // and backs away on its +X jets for 3 s: 4 x 99.8 lbf x 3 s on 28,806
    // kg, 0.185 m/s, while the S-IVB, with no springs, gains nothing.
    func testCSMSeparationHandsTheIUToTheSIVB() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.apollo11InParkingOrbit(in: sim)
        let iu = try XCTUnwrap(v.flightProgram as? SaturnIU)
        XCTAssertEqual(iu.hostPart, "IU")
        sim.run(seconds: 100)           // past the turn to the local horizontal and the ullage's end
        XCTAssertTrue(iu.status.contains("local horizontal, parking orbit"), iu.status)
        let j2 = try XCTUnwrap(v.thrusters.first { $0.name == "S-IVB engine" })
        v.mainThrottle = 1
        sim.run(seconds: 5)
        XCTAssertTrue(j2.isDelivering)
        XCTAssertNil(sim.stage(v))
        XCTAssertTrue(sim.events.last?.message.contains("inhibited") ?? false)
        v.mainThrottle = 0
        sim.run(seconds: 2)
        let id = v.id, before = v.velocity
        let command = v.attitudeCommand
        let all = sim.stageAll(v)
        XCTAssertEqual(all.count, 5)
        let sivb = try XCTUnwrap(all.first)
        XCTAssertEqual(sivb.name, "Apollo 11 – S-IVB")
        XCTAssertTrue(sivb.flightProgram === iu)
        XCTAssertEqual(sivb.autopilot, .attitudeHold)
        XCTAssertEqual(sivb.attitudeCommand, command)
        XCTAssertEqual(sivb.phasePlane, AS506.apsLaw)
        XCTAssertEqual(sivb.controlFrame, .identity)
        XCTAssertTrue(v.id == id && sim.focus === v)
        XCTAssertTrue(v.flightProgram is ApolloSCS)
        XCTAssertNil(v.autopilot)
        XCTAssertNil(v.attitudeCommand)
        XCTAssertEqual(v.mainThrottle, 0)
        XCTAssertEqual(v.translationInput, .zero)
        XCTAssertEqual(v.controlFrame, ApolloAxes.rotation)
        XCTAssertEqual(v.activeStage?.name, "SM")
        sim.run(seconds: 4)
        XCTAssertEqual(v.phasePlane, ApolloCSM.phasePlaneLaw(deadband: 0.5))
        XCTAssertEqual(v.translationInput, .zero)
        let x = v.attitude.rotate(.unitX)
        let gained = (v.velocity - before).dot(x) - (sivb.velocity - before).dot(x)
        XCTAssertEqual(gained, 4 * 99.8 * 4.4482216152605 * 3 / 28_806, accuracy: 0.002)
        // The S-IVB holds the IU's attitude command.
        sim.run(seconds: 60)
        let error = rotationVector(sivb.attitude.conjugate * (sivb.attitudeCommand?.attitude ?? .identity)).length
        XCTAssertLessThan(error, 2 * deg)
        XCTAssertGreaterThan(v.attitude.inverseRotate(v.position - sivb.position).x, 10)
    }

    // 68-FM-184 §5.1.4: Apollo 7 separated from its S-IVB on its four +X
    // jets for 2.6 s, 1.0 ft/s (399.2 lbf x 2.6 s on its 32,458 lb). The
    // model's CSM-101 at its launch loads, 32,208 lb, by hand (U).
    func testApollo7SeparationImpulse() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.apolloCSM(.apollo7)
        sim.add(v)
        let x = sim.placeInFreeSpace(v)
        XCTAssertEqual(v.mass / 0.45359237, 32_207.9, accuracy: 0.1)
        v.setPilotInput(rotation: RotationCommand(), translation: Vec3(1, 0, 0))
        sim.run(seconds: 2.6)
        v.setPilotInput(rotation: RotationCommand(), translation: .zero)
        sim.run(seconds: 0.2)
        XCTAssertEqual(v.velocity.dot(x) / ft, 1.0, accuracy: 0.05)
    }

    // 68-FM-160: each panel leaves at 8 ft/s or more, 110° ± 20° from the
    // S-IVB's +X, turning at 33.5°/s or more, and none comes back: over 60 s
    // each panel's centre moves away from the axis of the S-IVB stack and of
    // the CSM, clear of them (their radius and the panel's half length)
    // from 3 s on.
    func testSLAPanelsJettison() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.apollo11InParkingOrbit(in: sim)
        sim.run(seconds: 100)
        let momentum = v.velocity * v.mass, w0 = v.angularVelocity
        let all = sim.stageAll(v)
        let sivb = all[0], panels = Array(all.dropFirst())
        XCTAssertEqual(panels.map(\.name), (1...4).map { "Apollo 11 – SLA panel \($0)" })
        // Velocities relative to the S-IVB's motion where the panel is: the
        // stack turns at the orbital rate.
        let spin = sivb.attitude.rotate(sivb.angularVelocity)
        for p in panels {
            let rel = p.attitude.inverseRotate(p.velocity - sivb.velocity - spin.cross(p.position - sivb.position))
            // 8 ft/s from the stack it left; the later panels' recoil takes
            // up to 0.01 ft/s of it relative to the S-IVB.
            XCTAssertEqual(rel.length / ft, 8, accuracy: 0.02, p.name)
            XCTAssertEqual(acos(rel.x / rel.length) / deg, 110, accuracy: 20, p.name)
            XCTAssertGreaterThanOrEqual((p.angularVelocity - w0).length / deg, 33.5 - 1e-9, p.name)
        }
        // Momentum is conserved, but for the CSM's CG taking its place 4 cm
        // off the axis (the stack carried it centred): at the orbital rate,
        // 5e-5 m/s of the stack's motion.
        let after = ([v] + all).reduce(Vec3.zero) { $0 + $1.velocity * $1.mass }
        XCTAssertLessThan((after - momentum).length, 1e-4 * (v.mass + all.reduce(0) { $0 + $1.mass }))
        var last = panels.map { _ in 0.0 }
        for step in 1...3_000 {
            sim.tick()
            for (i, p) in panels.enumerated() {
                for (other, radius) in [(sivb, 3.3), (v, 2.0)] {
                    let rel = other.attitude.inverseRotate(p.position - other.position)
                    let r = (rel.y * rel.y + rel.z * rel.z).squareRoot()
                    if other === sivb {
                        XCTAssertGreaterThan(r, last[i] - 1e-6, "\(p.name) away from the axis at \(step)")
                        last[i] = r
                    }
                    if step >= 150 { XCTAssertGreaterThan(r, radius + 3.2, "\(p.name) clear of \(other.name) at \(step)") }
                }
            }
        }
    }

    // Time warp with the SLA panels tumbling in the parking orbit: each
    // panel is passive (no program, not the focus, out of the air), so its
    // 33.5°/s holds its steps to 1 rad of turn, 1.7 s, instead of 0.05 rad,
    // 0.085 s; the simulation's step, the smallest of every vessel's, stays
    // at 1 s or more over 98 % of ten minutes of coast with the S-IVB under
    // the IU (its APS pulses end shorter steps) and the CSM drifting.
    func testWarpStepsWithThePanelsTumbling() throws {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo11InParkingOrbit(in: sim)
        sim.run(seconds: 100)
        let panels = Array(sim.stageAll(v).dropFirst())
        sim.run(seconds: 4)              // the CSM's +X ullage
        var long = 0.0, total = 0.0, shortest = Double.infinity
        while total < 600 {
            for w in sim.vessels { sim.prepareControls(w) }
            for p in panels {
                XCTAssertTrue(sim.isPassive(p), p.name)
                XCTAssertGreaterThanOrEqual(sim.maxStep(for: p), 1, p.name)
            }
            let h = sim.maxStep()
            sim.step(h)
            total += h
            if h >= 1 { long += h }
            shortest = min(shortest, h)
        }
        print(String(format: "warp with the panels: %.1f %% of the time in steps of 1 s or more, shortest %.3f s",
                     100 * long / total, shortest))
        XCTAssertGreaterThan(long / total, 0.98)
        for p in panels { XCTAssertEqual(p.status, .flying) }
    }

    // CM/SM separation (MSC-03466): the SM leaves on its four -X jets, fired
    // from the separation until their quads run dry, and spins on its four
    // +roll jets from 2.0 to 7.5 s. The -X jets' Δv is the rocket equation's
    // on what they burn (the roll jets push no net force), and the SM moves
    // away along -X. The CM's RCS is armed: it has authority on every axis.
    func testSMJettison() throws {
        let sim = try Simulation.forTests(perturbations: false)
        let v = VesselLibrary.apolloCSM(.apollo11)
        sim.add(v)
        let x = sim.placeInFreeSpace(v)
        ApolloCSM.setLoads(v, spsOxidizer: 3_106, spsFuel: 1_958, rcs: 780)   // Apollo 11 at separation (§8.11)
        let sm = try XCTUnwrap(sim.stage(v, event: 7))
        XCTAssertEqual(sm.name, "Apollo 11 – SM")
        let cmRates = v.rcsAuthority()
        XCTAssertGreaterThan(min(cmRates.x, cmRates.y, cmRates.z), 0)
        XCTAssertTrue(v.thrusters.allSatisfy { $0.isEnabled })
        let back = sm.thrusters.filter { $0.groups.contains(.translateBack) }
        let roll = sm.thrusters.filter { $0.sequence?.start == 2 }
        XCTAssertEqual(back.count, 4)
        XCTAssertEqual(roll.count, 4)
        let m0 = sm.mass
        var rollOn: [(start: Double, end: Double)] = [], t = 0.0, sensed = 0.0
        // Steps of 0.02 s at most that end where the roll window opens and
        // closes and where the quads run dry (the SM flies passively).
        while back.contains(where: { $0.hasPropellant }) && t < 2_000 {
            for w in sim.vessels { sim.prepareControls(w) }
            let h = min(0.02, sim.maxStep())
            let rolling = roll.allSatisfy { $0.isDelivering }
            for j in back where j.hasPropellant { XCTAssertTrue(j.isDelivering, j.name) }
            sim.step(h)
            sensed += sm.thrustAcceleration * h
            if rolling { rollOn.append((t, t + h)) }
            t += h
        }
        XCTAssertEqual(try XCTUnwrap(rollOn.first).start, 2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(rollOn.last).end, 7.5, accuracy: 1e-9)
        XCTAssertEqual(rollOn.count, Int((5.5 / 0.02).rounded()))
        // The rocket equation on the -X jets' share of the flow: alone to
        // 2 s, with the roll jets' as much again to 7.5 s, alone after.
        let flow = back.reduce(0) { $0 + $1.rating.massFlow }, c = 276.0 * standardGravity
        let ma = m0 - flow * 2, mb = ma - 2 * flow * 5.5
        let dv = c * (log(m0 / ma) + 0.5 * log(ma / mb) + log(mb / sm.mass))
        XCTAssertEqual(sensed, dv, accuracy: 1e-5 * dv)
        XCTAssertGreaterThan(dv, 100)
        XCTAssertLessThan(v.attitude.inverseRotate(sm.position - v.position).x, 0)
        XCTAssertGreaterThan(abs(sm.angularVelocity.x), 0.01)
    }
}
