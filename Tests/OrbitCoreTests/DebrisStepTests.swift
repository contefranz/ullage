import XCTest
@testable import OrbitCore

/// Passive debris in the air (docs/m16/plan.md, A3): once separated, the
/// SLA panels, the spent stages and the SM have drag only, along the wind,
/// so in the air they take drag-limited steps (`Simulation.passiveAirStep`)
/// instead of controlled flight's 0.02 s, and no longer hold every vessel's
/// step down while they come down. Anything flown, and the focus, keep
/// their steps.
final class DebrisStepTests: XCTestCase {
    static let deg = Double.pi / 180

    /// The Apollo 11 parking orbit after the CSM/LV separation, as
    /// `CSMSeparationTests` flies it: the CSM under its SCS, the S-IVB under
    /// the IU, and the four SLA panels tumbling at 33.5°/s.
    static func separated() throws -> (sim: Simulation, csm: Vessel, sivb: Vessel, panels: [Vessel]) {
        let sim = try Simulation.forTests(perturbations: true)
        let v = VesselLibrary.apollo11InParkingOrbit(in: sim)
        sim.run(seconds: 100)
        let all = sim.stageAll(v)
        return (sim, v, all[0], Array(all.dropFirst()))
    }

    static func down(_ v: Vessel) -> Bool { v.landed != nil || v.status == .crashed }

    /// Great-circle distance (m) between two points of the Earth (rad).
    static func distance(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let c = sin(a.lat) * sin(b.lat) + cos(a.lat) * cos(b.lat) * cos(a.lon - b.lon)
        return acos(min(1, max(-1, c))) * 6_371_000
    }

    /// The four SLA panels, left in the 100 n mi parking orbit at 292 kg on
    /// 239 ft² each, come down about 2.5 h after the separation: through
    /// 116 km (1 Pa) at 7.8 km/s, to the sea at their 11 m/s terminal speed
    /// some 1,000 s later. Flown at the simulation's own steps, as
    /// `Simulation.advance` flies them, with the CSM drifting under its SCS
    /// and the S-IVB under the IU: while any panel is in the air, each takes
    /// 0.5 s steps or longer (at the sea, half the 1.1 s its drag takes to
    /// stop it; 1 s, hypersonic), and so does the simulation.
    func testFourPanelsReenterAtLongSteps() throws {
        let (sim, csm, sivb, panels) = try Self.separated()
        var t = 0.0, steps = 0, airTime = 0.0, airSteps = 0, shortest = Double.infinity
        var entered = [Bool](repeating: false, count: panels.count)
        while panels.contains(where: { !Self.down($0) }) && t < 4 * 3600 {
            for w in sim.vessels { sim.prepareControls(w) }
            let air = panels.indices.filter { !Self.down(panels[$0]) && panels[$0].dynamicPressure > 1 }
            for i in air {
                entered[i] = true
                let p = panels[i]
                XCTAssertTrue(sim.isPassive(p), p.name)
                let own = sim.maxStep(for: p)
                if own < 0.5 {
                    XCTFail(String(format: "%@: %.3f s at %.1f km, %.1f m/s", p.name, own, p.altitude / 1000, p.airspeed))
                }
            }
            let h = sim.maxStep()
            if !air.isEmpty {
                airTime += h
                airSteps += 1
                shortest = min(shortest, h)
            }
            sim.step(h)
            t += h
            steps += 1
        }
        print(String(format: "four panels down %.0f s after the separation, in %d steps; in the air %.0f s in %d steps, "
                     + "the shortest %.3f s", t, steps, airTime, airSteps, shortest))
        XCTAssertEqual(entered, [true, true, true, true])
        for p in panels { XCTAssertTrue(Self.down(p), p.name) }
        XCTAssertGreaterThanOrEqual(shortest, 0.5)
        XCTAssertGreaterThan(airTime, 900)
        // The CSM and the S-IVB fly on, under their programs.
        for v in [csm, sivb] { XCTAssertEqual(v.status, .flying, v.name) }
    }

    /// One SLA panel, alone, from the parking orbit to the sea: at the
    /// simulation's own steps, and again with 0.02 s steps from where it
    /// passes 1 Pa (116 km), which every vessel took in the air before. The
    /// two land within 2 km of each other (they land within metres).
    func testAPanelLandsWhereFixedStepsLandIt() throws {
        func fly(fixed: Bool) throws -> (lat: Double, lon: Double, time: Double, steps: Int) {
            let (sim, csm, sivb, panels) = try Self.separated()
            for v in [csm, sivb] + panels.dropFirst() { sim.remove(v) }
            sim.focus = nil
            let p = panels[0]
            var steps = 0
            while !Self.down(p) && sim.time - AS506.rangeZero < 6 * 3600 {
                sim.prepareControls(p)
                let inAir = p.dynamicPressure > 1
                sim.step(fixed && inAir ? 0.02 : sim.maxStep())
                if inAir { steps += 1 }
            }
            XCTAssertTrue(Self.down(p))
            let ll = p.latitudeLongitude(snapshot: sim.snapshot)
            return (ll.lat, ll.lon, sim.time - AS506.rangeZero, steps)
        }
        let relaxed = try fly(fixed: false), fixed = try fly(fixed: true)
        let miss = Self.distance((relaxed.lat, relaxed.lon), (fixed.lat, fixed.lon))
        print(String(format: "a panel lands at %.4f, %.4f in %d steps in the air, %.1f m from where 0.02 s steps "
                     + "(%d) land it; %.2f s apart", relaxed.lat / Self.deg, relaxed.lon / Self.deg, relaxed.steps, miss,
                     fixed.steps, relaxed.time - fixed.time))
        XCTAssertLessThan(miss, 2_000)
        XCTAssertLessThan(relaxed.steps * 20, fixed.steps)
    }

    /// In the air, only debris takes the long steps: the same panel as the
    /// focus, or flown (an autopilot, the pilot's input), takes 0.02 s, as
    /// does a vessel whose air turns it (the CM, its lift and trim moments)
    /// even when nothing flies it. The S-IVB, once neither the IU nor its
    /// attitude hold flies it, has drag along the wind only: it is debris
    /// too.
    func testControlledFlightKeepsItsSteps() throws {
        let (sim, _, sivb, panels) = try Self.separated()
        let p = panels[0]
        sim.place(p, geodeticLatitude: 20, longitude: -150, height: 80_000, inertialSpeed: 7_000, flightPathAngle: -2,
                  azimuth: 90)
        XCTAssertGreaterThan(p.dynamicPressure, 100)
        XCTAssertTrue(sim.isPassive(p))
        XCTAssertGreaterThanOrEqual(sim.maxStep(for: p), 0.5)
        XCTAssertEqual(sim.maxStep(for: p), sim.passiveAirStep(p))

        let focus = sim.focus
        sim.focus = p
        XCTAssertFalse(sim.isPassive(p))
        XCTAssertLessThanOrEqual(sim.maxStep(for: p), 0.02)
        sim.focus = focus
        p.autopilot = .killRotation
        XCTAssertLessThanOrEqual(sim.maxStep(for: p), 0.02)
        p.autopilot = nil
        p.setPilotInput(rotation: RotationCommand(roll: 1), translation: .zero)
        XCTAssertLessThanOrEqual(sim.maxStep(for: p), 0.02)
        p.setPilotInput(rotation: RotationCommand(), translation: .zero)
        XCTAssertGreaterThanOrEqual(sim.maxStep(for: p), 0.5)

        let cm = VesselLibrary.commandModule(.apollo7)
        sim.add(cm)
        sim.place(cm, geodeticLatitude: 20, longitude: -150, height: 80_000, inertialSpeed: 7_000, flightPathAngle: -2,
                  azimuth: 90)
        XCTAssertTrue(sim.isPassive(cm))
        XCTAssertNotNil(cm.activeAerodynamics?.capsule)
        XCTAssertLessThanOrEqual(sim.maxStep(for: cm), 0.02)

        XCTAssertFalse(sim.isPassive(sivb), "the IU flies it")
        sivb.flightProgram = nil
        XCTAssertFalse(sim.isPassive(sivb), "the IU left it on attitude hold")
        sivb.autopilot = nil
        sim.place(sivb, geodeticLatitude: 20, longitude: -150, height: 80_000, inertialSpeed: 7_000, flightPathAngle: -2,
                  azimuth: 90)
        XCTAssertTrue(sivb.activeAerodynamics?.dragAlongWind ?? false)
        XCTAssertTrue(sim.isPassive(sivb))
        XCTAssertGreaterThanOrEqual(sim.maxStep(for: sivb), 0.5)
    }
}
