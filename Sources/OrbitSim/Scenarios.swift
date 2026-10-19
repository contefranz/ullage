import Foundation
import OrbitCore

/// Starting situations. Real Apollo/Shuttle scenarios arrive with M1+.
struct Scenario: Identifiable {
    let id: String
    let name: String
    let summary: String
    let build: (SolarSystem) -> Simulation

    static let all: [Scenario] = [pad39A, saturnVPad, lowEarthOrbit, lunarOrbit]

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
    /// first motion and the IU's events fall on Apollo 11's UTC times.
    static let saturnVPad = Scenario(
        id: "as506-pad",
        name: "Saturn V (AS-506) on LC-39A",
        summary: "Apollo 11 at first motion, 16 July 1969, 13:32:00.3 UTC, paused: P releases the hold-down arms. The IU flies the ascent: tower-clearance yaw, roll and pitch programs, staging, and iterative guidance (IGM) through the S-II and S-IVB burns to a 100 n mi parking orbit.",
        build: { system in
            let sim = Simulation(system: system, time: VesselLibrary.apollo11FirstMotion)
            let v = VesselLibrary.apollo11OnPad(in: sim)
            v.mainThrottle = 1
            sim.paused = true
            return sim
        })

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
