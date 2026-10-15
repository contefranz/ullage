import Foundation
import OrbitCore

/// Starting situations. Real Apollo/Shuttle scenarios arrive with M1+.
struct Scenario: Identifiable {
    let id: String
    let name: String
    let summary: String
    let build: (SolarSystem) -> Simulation

    static let all: [Scenario] = [pad39A, saturnVPad, lowEarthOrbit, lunarOrbit]

    /// Launch Complex 39A, Kennedy Space Center (pad centre).
    static let lc39A = (latitude: 28.60822, longitude: -80.60411)

    static let pad39A = Scenario(
        id: "pad39a",
        name: "Pathfinder on LC-39A",
        summary: "Two-stage test rocket on the pad on 16 July 1969, 13:32 UTC. Z for full throttle, space to stage.",
        build: { system in
            let sim = Simulation(system: system, time: Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32))
            let rocket = VesselLibrary.testRocket()
            sim.add(rocket)
            sim.placeLanded(rocket, on: system.earth, latitude: lc39A.latitude, longitude: lc39A.longitude,
                            azimuth: 72)
            return sim
        })

    /// Apollo 11's Saturn V at first motion (range time 0.30 s). The pad
    /// azimuth is 72° until the IU roll program exists. TODO (IU item): move
    /// the pad to the geocentric latitude in `AS506.padLatitude`, which the
    /// datasheet's orbit targets assume; on the map it sits 18 km south.
    static let saturnVPad = Scenario(
        id: "as506-pad",
        name: "Saturn V (AS-506) on LC-39A",
        summary: "Apollo 11 launch vehicle at first motion, 16 July 1969, 13:32:00.3 UTC. Z ignites (F-1 and J-2 do not throttle); space for the next staging event.",
        build: { system in
            let sim = Simulation(system: system, time: Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32,
                                                             second: 0.3))
            let stack = VesselLibrary.saturnV()
            sim.add(stack)
            sim.placeLanded(stack, on: system.earth, latitude: lc39A.latitude, longitude: lc39A.longitude,
                            azimuth: 72)
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
