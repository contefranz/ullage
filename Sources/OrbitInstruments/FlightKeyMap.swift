import Foundation

/// What an unshifted key does in flight (docs/m2/design-flight-controls.md
/// §4): the commands the app dispatches, one per key.
public enum FlightCommand: String, CaseIterable, Sendable {
    // The view and the simulation.
    case help, orbitLine, pause, warpUp, warpDown, warpReset
    case cameraTarget, cameraFrame, previousVessel, nextVessel
    case debugView, passTimings, readablePlumes, snapshot
    // The instruments.
    case speedMode, target, hudVisibility
    // The vessel.
    case stage, entryMode, throttleOn, throttleOff, failEngine
    case killRotation, prograde, retrograde, normal, antinormal, radialOut, radialIn, horizonLevel
    case attitudeHold, autopilotOff
    /// Return: the computer's ENTR when digits are keyed, else its PRO when
    /// it waits for the crew.
    case computerKey
    /// G: G&N AUTO, the computer's attitude.
    case gnAuto
}

/// The flight keys as one table: the key of each command and its line of
/// help. The app dispatches the unshifted keys through it; the throttle's
/// = and - and the RCS keys (`RCSKeyControl`) are read as held keys and
/// listed here for the help and the conflict check only.
public enum FlightKeyMap {
    public struct Binding: Sendable {
        public var key: PhysicalKey
        public var command: FlightCommand
        public var help: String
    }

    public static let bindings: [Binding] = [
        Binding(key: .h, command: .help, help: "this help"),
        Binding(key: .m, command: .orbitLine, help: "orbit line"),
        Binding(key: .p, command: .pause, help: "pause"),
        Binding(key: .period, command: .warpUp, help: "time warp up"),
        Binding(key: .comma, command: .warpDown, help: "time warp down"),
        Binding(key: .slash, command: .warpReset, help: "time warp 1x"),
        Binding(key: .c, command: .cameraTarget, help: "camera target"),
        Binding(key: .v, command: .cameraFrame, help: "camera frame"),
        Binding(key: .leftBracket, command: .previousVessel, help: "previous vessel"),
        Binding(key: .rightBracket, command: .nextVessel, help: "next vessel"),
        Binding(key: .f9, command: .debugView, help: "debug view"),
        Binding(key: .f10, command: .passTimings, help: "render pass timings"),
        Binding(key: .b, command: .readablePlumes, help: "readable plumes"),
        Binding(key: .f12, command: .snapshot, help: "snapshot of the next frame"),
        Binding(key: .n, command: .speedMode, help: "navball speed: orbit / surface / target"),
        Binding(key: .y, command: .target, help: "target: nearest vessel, farther ones, none"),
        Binding(key: .f2, command: .hudVisibility, help: "HUD: full / instruments / off"),
        Binding(key: .grave, command: .hudVisibility, help: "HUD: full / instruments / off"),
        Binding(key: .isoSection, command: .hudVisibility, help: "HUD: full / instruments / off"),
        Binding(key: .space, command: .stage, help: "resume the count, stage, or back up the ELS"),
        Binding(key: .digit9, command: .entryMode, help: "entry mode: manual / bank hold / rolling"),
        Binding(key: .z, command: .throttleOn, help: "full throttle (the CSM: SPS on, the EMS cuts off)"),
        Binding(key: .x, command: .throttleOff, help: "cut the throttle (the CSM: ΔV THRUST off)"),
        Binding(key: .f, command: .failEngine, help: "then 1-5: fail that engine of the stage firing"),
        Binding(key: .t, command: .killRotation, help: "kill rotation"),
        Binding(key: .digit1, command: .prograde, help: "prograde"),
        Binding(key: .digit2, command: .retrograde, help: "retrograde"),
        Binding(key: .digit3, command: .normal, help: "normal"),
        Binding(key: .digit4, command: .antinormal, help: "anti-normal"),
        Binding(key: .digit5, command: .radialOut, help: "radial out"),
        Binding(key: .digit6, command: .radialIn, help: "radial in"),
        Binding(key: .digit7, command: .horizonLevel, help: "hold level"),
        Binding(key: .digit8, command: .attitudeHold, help: "hold attitude (the IU's on the Saturn; the SCS's on the CSM)"),
        Binding(key: .digit0, command: .autopilotOff, help: "autopilot off"),
        Binding(key: .returnKey, command: .computerKey, help: "the computer: ENTR with digits keyed, else PRO"),
        Binding(key: .g, command: .gnAuto, help: "G&N AUTO: fly the computer's attitude"),
    ]

    /// Keys read as held, not as commands: the throttle's and the RCS's.
    public static let heldKeys: Set<PhysicalKey> = Set([.equal, .minus]
        + RCSKeyControl.rotationKeys.flatMap { [$0.plus, $0.minus] }
        + RCSKeyControl.translationKeys.flatMap { [$0.plus, $0.minus] })

    private static let byKey = Dictionary(bindings.map { ($0.key, $0.command) }, uniquingKeysWith: { a, _ in a })

    /// The command of an unshifted `key`; nil for none (a held key, or an
    /// unbound one).
    public static func command(for key: PhysicalKey) -> FlightCommand? { byKey[key] }

    /// Keys macOS keeps for itself (F3 Mission Control, F4 Launchpad, F11
    /// Show Desktop), which no flight command may use.
    public static let reserved: Set<PhysicalKey> = [.f3, .f4, .f11]
}
