import Foundation
import OrbitCore

/// The flight harness's trigger language made real: commands that advance a
/// scenario headless, at full speed, through the same OrbitCore entry points
/// the app's keys use (`Simulation.advance`, `stage`, the ELS backup, the
/// throttle, the autopilot, warp). Deterministic: no wall-clock step budget.
///
/// - `met:<s>`: run until the mission clock (the scenario's zero, else its
///   start) reads s seconds.
/// - `wait:<s>`: run s seconds of simulation time.
/// - `ev:<text>`: run until an event the simulation logs, or the IU logs,
///   contains `text` (case-insensitive), e.g. `ev:S-IC OECO`, `ev:mains deployed`.
/// - `liftoff`: run until the focus vessel leaves the ground.
/// - `t<n>`: run until the IU starts time base n (`t3`).
/// - `stage`: Space: the next staging event, or the ELS backup's next step
///   once the CM's entry program is awake.
/// - `throttle:<0...1>`, `warp:<x>`, `autopilot:<mode|off>` (a mode's name,
///   `prograde` ... `attitudeHold`, or its HUD text), `fail:<engine name>`.
/// - `focus:<name prefix>`: the vessel the commands and the camera act on.
public struct ScenarioScript: Equatable {
    public enum Command: Equatable {
        case met(Double)
        case wait(Double)
        case event(String)
        case liftoff
        case timeBase(Int)
        case stage
        case throttle(Double)
        case warp(Double)
        case autopilot(AttitudeAutopilot?)
        case fail(String)
        case focus(String)
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case unknownCommand(String)
        case badValue(String)
        case notReached(String, after: Double)
        case noVessel(String)

        public var description: String {
            switch self {
            case .unknownCommand(let c): "unknown script command \"\(c)\""
            case .badValue(let c): "bad value in script command \"\(c)\""
            case let .notReached(c, after): "\"\(c)\" not reached after \(Int(after)) s of simulation"
            case .noVessel(let name): "no vessel \"\(name)\""
            }
        }
    }

    public let commands: [Command]
    /// Longest a waiting command runs before it fails, simulation s (two days).
    public var limit = 172_800.0

    public init(_ lines: [String]) throws {
        commands = try lines.map(Self.parse)
    }

    public static func parse(_ line: String) throws -> Command {
        let text = line.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, !first.isEmpty else { throw Failure.unknownCommand(text) }
        let word = first.lowercased(), arg = parts.count > 1 ? parts[1] : ""
        func number() throws -> Double {
            guard let x = Double(arg), x.isFinite else { throw Failure.badValue(text) }
            return x
        }
        switch word {
        case "met": return .met(try number())
        case "wait": return .wait(try number())
        case "ev": guard !arg.isEmpty else { throw Failure.badValue(text) }; return .event(arg)
        case "liftoff": return .liftoff
        case "stage": return .stage
        case "throttle":
            let x = try number()
            guard (0...1).contains(x) else { throw Failure.badValue(text) }
            return .throttle(x)
        case "warp":
            let x = try number()
            guard x > 0 else { throw Failure.badValue(text) }
            return .warp(x)
        case "autopilot":
            if arg.lowercased() == "off" { return .autopilot(nil) }
            let mode = AttitudeAutopilot.allCases.first {
                "\($0)".lowercased() == arg.lowercased() || $0.rawValue.lowercased() == arg.lowercased()
            }
            guard let mode else { throw Failure.badValue(text) }
            return .autopilot(mode)
        case "fail": guard !arg.isEmpty else { throw Failure.badValue(text) }; return .fail(arg)
        case "focus": guard !arg.isEmpty else { throw Failure.badValue(text) }; return .focus(arg)
        default:
            if word.count == 2, word.hasPrefix("t"), let n = Int(word.dropFirst()), (1...5).contains(n) {
                return .timeBase(n)
            }
            throw Failure.unknownCommand(text)
        }
    }

    /// Runs the commands on `sim`. `missionClockZero` is the scenario's (nil:
    /// the mission clock starts where the script does). `observe` is called
    /// after each stretch of stepping (at most 1 s of simulation time, or
    /// `warp` s), so a caller can follow the flight, e.g. to warm the scene
    /// extractor's thermal lag.
    public func run(on sim: Simulation, missionClockZero: Epoch?, observe: (Simulation) -> Void = { _ in }) throws {
        let zero = missionClockZero ?? sim.time
        // Every stretch runs whole: no wall-clock budget, no cap on the
        // steps one advance may take (0.02 s powered steps at a high warp).
        sim.stepBudget = nil
        sim.maxRealInterval = .infinity
        sim.maxSubsteps = .max
        for (index, command) in commands.enumerated() {
            let label = "command \(index + 1)"
            switch command {
            case .met(let s):
                let remaining = s - (sim.time - zero)
                if remaining > 0 { Self.advance(sim, remaining, observe: observe) }
            case .wait(let s):
                Self.advance(sim, s, observe: observe)
            case .event(let text):
                let needle = text.lowercased()
                let simEvents = sim.events.count
                // What each IU had logged when the command began; an IU seen
                // later (none is created in flight) starts from nothing.
                var logged: [ObjectIdentifier: Int] = [:]
                for iu in Self.ius(in: sim) { logged[ObjectIdentifier(iu)] = iu.log.count }
                try runUntil(sim, "\(label), ev:\(text)", observe: observe) { sim in
                    if sim.events.dropFirst(min(simEvents, sim.events.count)).contains(where: {
                        $0.message.lowercased().contains(needle)
                    }) { return true }
                    return Self.ius(in: sim).contains { iu in
                        iu.log.dropFirst(logged[ObjectIdentifier(iu)] ?? 0).contains { $0.event.lowercased().contains(needle) }
                    }
                }
            case .liftoff:
                try runUntil(sim, "\(label), liftoff", observe: observe) { $0.focus?.landed == nil }
            case .timeBase(let n):
                guard let base = SaturnIU.TimeBase(rawValue: n) else { throw Failure.badValue("t\(n)") }
                try runUntil(sim, "\(label), t\(n)", observe: observe) { sim in
                    sim.vessels.contains { ($0.flightProgram as? SaturnIU)?.timeBases[base] != nil }
                }
            case .stage:
                guard let v = sim.focus else { throw Failure.noVessel("focus") }
                if let entry = ApolloMission.entryProgram(of: v), entry.phase != .dormant {
                    _ = entry.advanceELS(v, in: sim)
                } else {
                    sim.stage(v)
                }
            case .throttle(let x):
                sim.focus?.mainThrottle = x
            case .warp(let x):
                sim.warp = x
            case .autopilot(let mode):
                sim.focus?.autopilot = mode
            case .fail(let engine):
                guard let v = sim.vessels.first(where: { $0.thrusters.contains { $0.name == engine } }) else {
                    throw Failure.noVessel(engine)
                }
                if let iu = v.flightProgram as? SaturnIU {
                    iu.scheduleFailure(of: engine, at: .epoch(sim.time))
                } else if let e = v.thrusters.first(where: { $0.name == engine }), !e.isFailed {
                    e.fail()
                    sim.log("\(v.name): \(engine) failed")
                }
            case .focus(let name):
                guard let v = Self.vessel(named: name, in: sim) else { throw Failure.noVessel(name) }
                sim.focus = v
            }
        }
    }

    /// The vessel whose name starts with `name` (case-insensitive), the
    /// first in the simulation's order.
    public static func vessel(named name: String, in sim: Simulation) -> Vessel? {
        sim.vessels.first { $0.name.lowercased().hasPrefix(name.lowercased()) }
    }

    /// The Saturn IUs aboard the simulation's vessels.
    static func ius(in sim: Simulation) -> [SaturnIU] {
        sim.vessels.compactMap { $0.flightProgram as? SaturnIU }
    }

    /// Runs until the simulation is `seconds` on, at its warp, in stretches
    /// of at most max(1, warp) s, counting the time it actually covered.
    static func advance(_ sim: Simulation, _ seconds: Double, observe: (Simulation) -> Void) {
        sim.paused = false
        let end = sim.time + seconds
        while end - sim.time > 1e-6 {
            let before = sim.time
            sim.advance(by: min(end - sim.time, max(1, sim.warp)) / sim.warp)
            observe(sim)
            if sim.time - before <= 0 { break }     // the epoch can resolve no finer
        }
    }

    /// Runs in steps of 0.1 s of simulation time (times the warp) until
    /// `done`, at most `limit` s of simulation time.
    func runUntil(_ sim: Simulation, _ what: String, observe: (Simulation) -> Void,
                  _ done: (Simulation) -> Bool) throws {
        sim.paused = false
        let start = sim.time
        var observed = sim.time
        while !done(sim) {
            guard sim.time - start < limit else { throw Failure.notReached(what, after: sim.time - start) }
            let before = sim.time
            // 0.1 s of simulation time, times the warp above 1: as `advance`
            // does, never less than the epoch can resolve at a tiny warp.
            sim.advance(by: 0.1 * max(1, sim.warp) / sim.warp)
            if sim.time - before <= 0 { throw Failure.notReached(what, after: sim.time - start) }
            if sim.time - observed >= max(1, sim.warp) {
                observe(sim)
                observed = sim.time
            }
        }
        observe(sim)
    }
}
