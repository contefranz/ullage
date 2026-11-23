import XCTest
@testable import OrbitCore

/// Apollo 7's deorbit scenario (`VesselLibrary.apollo7BeforeDeorbit`, GET
/// 259:38:00) with its CMC, for the computer's tests: the flight stepped as
/// `Apollo7DeorbitTests` steps it, and the DSKY keys.
struct CMCFlight {
    static let ft = 0.3048, lb = 0.45359237, deg = Double.pi / 180

    let sim: Simulation
    let v: Vessel
    let scs: ApolloSCS
    var cmc: CMCLite { scs.computer }

    init() throws {
        sim = try Simulation.forTests(perturbations: true)
        v = VesselLibrary.apollo7BeforeDeorbit(in: sim)
        scs = try XCTUnwrap(v.flightProgram as? ApolloSCS)
        scs.computer.clockZero = ApolloCSM.apollo7RangeZero
        // One step, so the computer has seen the state.
        fly(to: get + 0.02)
    }

    /// GET of the simulation now, s.
    var get: Double { sim.time - ApolloCSM.apollo7RangeZero }
    /// SPS-8's ignition, 259:39:16.3, as GET and as an epoch.
    static let tigGET = ApolloCSM.apollo7SPS8Ignition.groundElapsedTime
    static var tig: Epoch { ApolloCSM.apollo7RangeZero + tigGET }

    /// Steps of 0.02 s at most, ending on the programs' events, to GET `t`.
    func fly(to t: Double, each: () -> Void = {}) {
        while get < t - 1e-6 {
            for w in sim.vessels { sim.prepareControls(w) }
            sim.step(min(0.02, sim.maxStep(), t - get))
            each()
        }
    }

    /// Steps until `done`, up to GET `limit`.
    func fly(until done: () -> Bool, limit: Double) {
        while !done() && get < limit {
            for w in sim.vessels { sim.prepareControls(w) }
            sim.step(min(0.02, sim.maxStep(), limit - get))
        }
    }

    /// Press the DSKY's keys now; a string of digits and signs keys them.
    func press(_ keys: DSKYKey...) { for k in keys { cmc.press(k, at: sim.time) } }
    func key(_ s: String) {
        for c in s {
            switch c {
            case "+": press(.plus)
            case "-": press(.minus)
            default: press(.digit(Int(String(c))!))
            }
        }
    }

    /// The crew's +X ullage, as the scenario's crew fired it: on or off.
    func ullage(_ on: Bool) {
        v.setPilotInput(rotation: RotationCommand(), translation: on ? Vec3(1, 0, 0) : .zero)
    }

    /// SPS-8 as a load: TIG at the flight's ignition, the Δv along the burn
    /// the flight's states imply (`ApolloCSM.apollo7SPS8DeltaV`), of
    /// `deltaV` m/s, heads down, from DEORBIT's planner.
    func sps8(deltaV: Double) -> ManeuverPlan {
        let d = ApolloCSM.apollo7SPS8DeltaV(system: sim.system).normalized * deltaV
        let atTIG = Kepler.propagate(Kepler.State(position: v.position, velocity: v.velocity), mu: v.reference.gm,
                                     by: Self.tig - sim.time)
        return ManeuverPlan(name: "SPS-8", engine: .sps, ignition: Self.tig, deltaV: d,
                            deltaVLocal: DeorbitPlanner.localVerticalFrame(atTIG) * d, burnTime: 11.9,
                            stateEpoch: sim.time, source: .deorbit)
    }

    /// SPS-8's load sized so that the computer's cutoff signal comes when
    /// the flight's did: the 102.8 m/s along X_A the EMS counter is loaded
    /// with (`apollo7SPS8CounterLoad`, the model's SPS from Z to the flight's
    /// cutoff signal), turned along the thrust, plus what Average-G counts
    /// of the crew's 15 s of four-jet ullage, plus the SPS's tail-off
    /// (its thrust over 0.54 s, falling linearly) at the cutoff's mass.
    func sps8AsFlown() -> ManeuverPlan {
        let sps = v.thrusters.first { $0.name == "SPS" }!
        let d = ApolloCSM.apollo7SPS8DeltaV(system: sim.system).normalized
        let alongX = d.dot(v.attitude.rotate(.unitX))
        let ullage = ApolloCSM.rcsFourJetThrust * ApolloCSM.poundForce / v.mass * 15
        let cutoffMass = v.mass - 790 * Self.lb
        let tailOff = sps.maxThrustVacuum / cutoffMass * ApolloCSM.spsTailoffDelay / 2
        return sps8(deltaV: ApolloCSM.apollo7SPS8CounterLoad / alongX + ullage + tailOff)
    }

    /// Speed, geocentric flight-path angle and geodetic altitude now.
    func state() -> (speed: Double, gamma: Double, altitude: Double) {
        let r = v.position.normalized
        return (v.velocity.length, asin(v.velocity.normalized.dot(r)), v.altitude)
    }

    func logged(_ s: String) -> Bool { sim.events.contains { $0.message.contains(s) } }
}
