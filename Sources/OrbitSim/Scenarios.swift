import Foundation
import OrbitCore

/// Starting situations: test vehicles; Apollo 11's Saturn V with and
/// without an engine failure, from the pad to splashdown; and the Apollo
/// spacecraft in Earth orbit and at entry.
struct Scenario: Identifiable {
    let id: String
    let name: String
    let summary: String
    /// Zero of the HUD's mission clock (MET), when the mission has one (the
    /// Saturn V's range zero: Apollo 11's GET); nil starts it at liftoff.
    var missionClockZero: Epoch? = nil
    /// Where the mission plans to land (geodetic latitude, longitude east,
    /// degrees), for the MAP and ENTRY displays; nil when none is planned.
    var recoveryTarget: (latitude: Double, longitude: Double)? = nil
    let build: (SolarSystem) -> Simulation

    static let all: [Scenario] = [pad39A, saturnVPad, earthOrbitReturn, apollo11ParkingOrbit, apollo13, sICEngine1Out,
                                  apollo7Deorbit, apollo7EntryInterface, lowEarthOrbit, lunarOrbit]

    /// Launch Complex 39A, Kennedy Space Center, where Apollo 11 stood:
    /// geodetic, on the WGS-84 Earth, with the pad's elevation.
    static let lc39A = VesselLibrary.lc39A

    /// Apollo 7's planned landing point, 29.8° N 67.0° W (MSC Internal Note
    /// 68-FM-184 §5.4.3 and Table IX(b), the Apollo 7 entry tests'), also the
    /// target of the AS-506 Earth-orbit return, which has no planned point of
    /// its own. It is the preflight plan's: by the deorbit burn Apollo 7's
    /// target had moved east, near where it came down at 27.64° N 64.15° W,
    /// about 200 n mi away (CM-entry-datasheet §4.5), and the sources give no
    /// coordinates for it.
    static let apollo7Target = (latitude: 29.8, longitude: -67.0)

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

    /// Apollo 11 from the pad back to the ground without leaving Earth
    /// orbit, as if translunar injection were no-go: the same stack and IU
    /// as `saturnVPad`, flown on by the crew. In the parking orbit Space
    /// separates the CSM (the four SLA panels tumble away, the S-IVB, IU and
    /// LM leave under the IU), and the CSM's SCS takes over; then the
    /// retrograde turn on the SM RCS, the DEORBIT MFD's burn on the SPS with
    /// the ΔV counter's cutoff, CM/SM separation (Space twice), and the CM's
    /// entry program and earth landing system to splashdown.
    static let earthOrbitReturn = Scenario(
        id: "as506-earth-orbit-return",
        name: "Apollo 11: pad to splashdown (TLI no-go)",
        summary: "Apollo 11 from the pad, returning from Earth orbit as if TLI were no-go. Paused at first motion: P releases the hold-down arms and the IU flies to the parking orbit. Then Space separates the CSM (the SLA panels, and the S-IVB with the IU and LM, leave); 2 turns it retrograde on the SM RCS; the DEORBIT MFD gives the burn's Δv and TIG, and its SET loads the ΔV counter; Z at TIG lights the SPS and the counter cuts it off; Space twice separates the SM. The CM's entry program holds lift up (9: manual, bank hold, rolling) and the earth landing system brings it down to splashdown.",
        missionClockZero: VesselLibrary.apollo11RangeZero,
        recoveryTarget: apollo7Target,
        build: { system in apollo11(system) })

    /// Apollo 11 at parking-orbit insertion (range 709.33 s), from track C's
    /// builder: the S-IVB with what burn 1 left, the IU turning to the local
    /// horizontal, the LM and the CSM, at AS-506's postflight insertion
    /// state. The rest of the Earth-orbit return from there.
    static let apollo11ParkingOrbit = Scenario(
        id: "as506-parking-orbit",
        name: "Apollo 11 in parking orbit",
        summary: "Apollo 11 at orbit insertion, 16 July 1969, 13:43:49 UTC (GET 00:11:49): the S-IVB, IU, LM and CSM in the 100 n mi parking orbit at AS-506's postflight state, the IU turning to the local horizontal, heads down. Space separates the CSM; from there, as in the Earth-orbit return: 2 retrograde, the DEORBIT MFD's burn with Z and the ΔV counter, Space twice for CM/SM separation, then entry and splashdown.",
        missionClockZero: VesselLibrary.apollo11RangeZero,
        recoveryTarget: apollo7Target,
        build: { system in
            let sim = Simulation(system: system, time: VesselLibrary.apollo11Insertion)
            VesselLibrary.apollo11InParkingOrbit(in: sim)
            return sim
        })

    /// Apollo 7 (CSM-101) before its deorbit burn, SPS-8, at GET 259:38:00
    /// (track C's builder): in the burn's attitude, held, the EMS ΔV counter
    /// loaded. The crew's steps are the Mission Report's (Table 2-I); it
    /// opens paused so that the pilot can read them.
    static let apollo7Deorbit = Scenario(
        id: "apollo7-deorbit",
        name: "Apollo 7: deorbit and entry",
        summary: "Apollo 7 (CSM-101) on 22 October 1968 at GET 259:38:00, before its deorbit burn (SPS-8): in the burn's attitude, held, with the EMS ΔV counter loaded. Paused: P starts. As the crew flew it: U (+X ullage) for 15 s from 259:39:01; Z at 259:39:16 lights the SPS and the counter cuts it off; Space twice at 259:43:34 separates the SM. The CM's entry program holds lift up (9: manual, bank hold, rolling); entry interface near 259:53:27, splashdown near 27.64° N 64.15° W.",
        missionClockZero: VesselLibrary.apollo7RangeZero,
        recoveryTarget: apollo7Target,
        build: { system in
            let sim = Simulation(system: system, time: VesselLibrary.apollo7RangeZero)
            VesselLibrary.apollo7BeforeDeorbit(in: sim)
            sim.paused = true
            return sim
        })

    /// Apollo 7's planned entry interface, MSC Internal Note 68-FM-184
    /// Table IX(b) (H; the longitude's sign M; tools/data/
    /// 68fm184_table8i_9_deorbit_entry.csv): 400,000 ft over 31.03° N,
    /// 98.83° W, 25,850.3 ft/s inertial at -1.759° and azimuth 83.64°, the
    /// angles in the geocentric horizontal; at 10:19:53:50 GET, the plan's
    /// 10:19:40:04 cutoff (§5.4.2) and 826 s coast. `EntryTests` and
    /// `Apollo7EntryTests` start there too.
    static let apollo7Interface = (groundElapsedTime: 934_804.0 + 826, latitude: 31.03, longitude: -98.83,
                                   height: 121_920.0, speed: 25_850.3 * 0.3048, flightPathAngle: -1.759,
                                   azimuth: 83.64)

    /// Apollo 7's command module at its planned entry interface
    /// (`apollo7Interface`), after CM/SM separation: E2's CM at the Mission
    /// Report's mass row, its entry program awake at the first step and
    /// holding the 55° bank 68-FM-184 §5.4.4 targets the landing point on
    /// (to the left, as Apollo 7's backup bank was), the CM turned to that
    /// trim attitude. The app's aerodynamics are the flight-consistent ones.
    static let apollo7EntryInterface = Scenario(
        id: "apollo7-cm-ei",
        name: "Apollo 7 CM at entry interface",
        summary: "Apollo 7's command module at its planned entry interface (68-FM-184 Table IX(b)): 400,000 ft over 31.03° N 98.83° W at 25,850 ft/s and -1.76°, GET 259:53:50. The entry program holds a 55° left bank, the bank 68-FM-184 targets 29.8° N 67.0° W on; 9 cycles manual (Q/E roll the lift about the air), bank hold (the bank flown) and rolling. The ELS fires on its baroswitches, Space being its backup below 40,000 ft, down to splashdown.",
        missionClockZero: VesselLibrary.apollo7RangeZero,
        recoveryTarget: apollo7Target,
        build: { system in
            let ei = apollo7Interface, bank = -55 * Double.pi / 180
            let sim = Simulation(system: system, time: VesselLibrary.apollo7RangeZero + ei.groundElapsedTime)
            let cm = VesselLibrary.commandModule(.apollo7)
            VesselLibrary.dressApollo(cm)
            sim.add(cm)
            sim.place(cm, geodeticLatitude: ei.latitude, longitude: ei.longitude, height: ei.height,
                      inertialSpeed: ei.speed, flightPathAngle: ei.flightPathAngle, azimuth: ei.azimuth)
            cm.flightProgram = CMEntryProgram(mode: .bankHold(bank))
            if let capsule = cm.activeAerodynamics?.capsule,
               let trim = CMEntryProgram.trimAttitude(of: cm, capsule: capsule, bank: bank, in: sim) {
                cm.attitude = trim
            }
            return sim
        })

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
