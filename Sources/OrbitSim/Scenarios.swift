import Foundation
import OrbitCore

/// Starting situations: test vehicles, and Apollo 11's Saturn V with and
/// without an engine failure.
struct Scenario: Identifiable {
    let id: String
    let name: String
    let summary: String
    /// Zero of the HUD's mission clock (MET), when the mission has one (the
    /// Saturn V's range zero: Apollo 11's GET); nil starts it at liftoff.
    var missionClockZero: Epoch? = nil
    let build: (SolarSystem) -> Simulation

    static let all: [Scenario] = [pad39A, saturnVPad, apollo13, sICEngine1Out, lowEarthOrbit, lunarOrbit]

    /// Launch Complex 39A, Kennedy Space Center, where Apollo 11 stood:
    /// geodetic, on the WGS-84 Earth, with the pad's elevation.
    static let lc39A = VesselLibrary.lc39A

    static let pad39A = Scenario(
        id: "pad39a",
        name: "Pathfinder on LC-39A",
        summary: "Two-stage test rocket on the pad on 16 July 1969, 13:32 UTC. Z for full throttle, space to stage.",
        build: { system in
            let sim = Simulation(system: system, time: Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32))
            let rocket = VesselLibrary.testRocket()
            sim.add(rocket)
            sim.placeLanded(rocket, on: system.earth, latitude: lc39A.latitude, longitude: lc39A.longitude,
                            azimuth: 72, elevation: lc39A.elevation)
            return sim
        })

    /// Apollo 11's Saturn V at first motion (range time 0.30 s), standing as
    /// it did on LC-39A: Position I east (the 90° pad azimuth), its base at
    /// the pad's elevation above the WGS-84 ellipsoid and its axis along the
    /// normal (datasheet §15), with the IU's flight program aboard. It opens
    /// paused with the F-1s at full thrust, so the first step after P is
    /// first motion and the IU's events fall on Apollo 11's UTC times. The
    /// mission clock is Apollo 11's GET, zero at range zero, 13:32:00 UTC.
    static let saturnVPad = Scenario(
        id: "as506-pad",
        name: "Saturn V (AS-506) on LC-39A",
        summary: "Apollo 11 at first motion, 16 July 1969, 13:32:00.3 UTC, paused: P releases the hold-down arms. The IU flies the ascent: tower-clearance yaw, roll and pitch programs, staging, and iterative guidance (IGM) through the S-II and S-IVB burns to a 100 n mi parking orbit. MET is Apollo 11's GET.",
        missionClockZero: VesselLibrary.apollo11RangeZero,
        build: { system in apollo11(system) })

    /// Apollo 13's S-II centre engine out on Apollo 11's stack: AS-508's
    /// engine 5 shut down at T3 + 167.0 s (FER Table 2-2), here range
    /// 328.6 s. The IU senses it, the four outboard J-2s burn about 33 s
    /// longer under the IGM (AS-508's 34.5 s), and the S-IVB still reaches
    /// the parking orbit (datasheet §16).
    static let apollo13 = Scenario(
        id: "as506-apollo13",
        name: "Apollo 13: S-II centre engine out",
        summary: "Apollo 11's Saturn V with Apollo 13's failure: the S-II centre engine (engine 5) shuts down at T3 + 167.0 s, range about 328.6 s, as on AS-508. The IGM flies the four outboard J-2s about 33 s longer (AS-508: 34.5 s) and the S-IVB to the parking orbit. Opens paused at first motion: P releases the hold-down arms.",
        missionClockZero: VesselLibrary.apollo11RangeZero,
        build: { system in
            apollo11(system, failing: SaturnIU.EngineFailure(engine: "S-II engine 5", time: .timeBase(.t3, 167.0)))
        })

    /// An outboard F-1 out at range 60 s (T1 + 59.37 s): the IU senses it,
    /// freezes the pitch program for about 8 s (GE504's chi freeze) and moves
    /// the tilt arrest out; the four F-1s burn longer, and the IGM still
    /// reaches the parking orbit (datasheet §16).
    static let sICEngine1Out = Scenario(
        id: "as506-sic-engine1-out",
        name: "S-IC engine 1 out at 60 s",
        summary: "Apollo 11's Saturn V losing outboard F-1 engine 1 at range 60 s. The IU senses it and freezes the pitch program for about 8 s (GE504's chi freeze), the four F-1s burn on to a later staging, and the IGM still flies the S-II and S-IVB to orbit. Opens paused at first motion: P releases the hold-down arms.",
        missionClockZero: VesselLibrary.apollo11RangeZero,
        build: { system in
            apollo11(system, failing: SaturnIU.EngineFailure(engine: "S-IC engine 1", time: .range(60)))
        })

    /// Apollo 11 at first motion, paused, with the F-1s at full thrust and
    /// an engine failure, if any, scheduled on the IU.
    static func apollo11(_ system: SolarSystem, failing failure: SaturnIU.EngineFailure? = nil) -> Simulation {
        let sim = Simulation(system: system, time: VesselLibrary.apollo11FirstMotion)
        let iu = SaturnIU.as506()
        if let failure { iu.scheduleFailure(of: failure.engine, at: failure.time) }
        let v = VesselLibrary.apollo11OnPad(in: sim, program: iu)
        v.mainThrottle = 1
        sim.paused = true
        return sim
    }

    static let lowEarthOrbit = Scenario(
        id: "leo",
        name: "Capsule in low Earth orbit",
        summary: "185 km circular orbit, 32.5° inclination. Practise attitude control and orbital manoeuvres.",
        build: { system in
            let sim = Simulation(system: system, time: Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 44))
            let capsule = VesselLibrary.capsule()
            sim.add(capsule)
            sim.placeInCircularOrbit(capsule, around: system.earth, altitude: 185_000, inclination: 32.5,
                                     ascendingNode: 0, argumentOfLatitude: 0)
            return sim
        })

    static let lunarOrbit = Scenario(
        id: "llo",
        name: "Capsule in lunar orbit",
        summary: "110 km circular lunar orbit on 20 July 1969.",
        build: { system in
            let sim = Simulation(system: system, time: Epoch(utcYear: 1969, month: 7, day: 20, hour: 17, minute: 0))
            let capsule = VesselLibrary.capsule()
            sim.add(capsule)
            sim.placeInCircularOrbit(capsule, around: system.moon, altitude: 110_000, inclination: 179,
                                     ascendingNode: 0, argumentOfLatitude: 0)
            return sim
        })
}
