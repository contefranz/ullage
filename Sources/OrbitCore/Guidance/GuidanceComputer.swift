import Foundation

/// A key of the onboard computer's keyboard, the DSKY's as M2's CMC-lite
/// takes it (docs/m2/design-flight-controls.md §3 and §4): the CMC page's
/// buttons press these, and the flight key Return presses `returnKey`.
public enum DSKYKey: Hashable, Sendable {
    /// A digit 0-9, keyed into the buffer.
    case digit(Int)
    /// The sign of the value being keyed.
    case plus, minus
    /// PRG (V37): change program; the digits keyed next name it, and
    /// Return enters them.
    case program
    /// DSP: the program step's next display.
    case display
    /// V82: the orbit's apsides and the time to them.
    case orbitParameters
    /// KEY REL: hand the display back to the program.
    case keyRelease
    /// PRO: proceed.
    case proceed
    /// ENTR: enter the keyed digits.
    case enter
    /// CLR: clear the keyed digits.
    case clear
    /// RSET: put out the PROG and OPR ERR lamps.
    case reset
    /// NXT: the program that flies the load (P40 on the SPS, P41 on the RCS).
    case next
    /// Return: ENTR when digits are keyed, PRO otherwise.
    case returnKey
}

/// What the computer's display shows: the program, verb and noun, the three
/// registers with their labels, the lamps, and in English what it waits
/// for. A value type, so the CMC page draws it and M3's AGC adapter can
/// deliver it from the AGC's display words.
public struct DSKYDisplay: Equatable, Sendable {
    /// One register: what it holds and its value as the display reads it
    /// (in Apollo units, signed, with its unit).
    public struct Register: Equatable, Sendable {
        public var label: String
        public var value: String
        public var unit: String
        public init(_ label: String, _ value: String, _ unit: String = "") {
            self.label = label
            self.value = value
            self.unit = unit
        }
    }

    /// The caution lamps the computer lights.
    public struct Lamps: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// UPLINK ACTY: a load came up from the ground.
        public static let uplinkActivity = Lamps(rawValue: 1 << 0)
        /// PROG: the program cannot do what it was asked (`reason` says why).
        public static let programAlarm = Lamps(rawValue: 1 << 1)
        /// OPR ERR: a key the computer could not take (`reason` says why).
        public static let operatorError = Lamps(rawValue: 1 << 2)
        /// KEY REL: the program wants the display back.
        public static let keyRelease = Lamps(rawValue: 1 << 3)
    }

    /// The major mode (P00, P30...); nil while it is blank.
    public var program: Int?
    public var verb: Int?
    public var noun: Int?
    /// The verb and noun flash: the computer waits for the crew.
    public var flashing: Bool
    /// The program's name ("EXTERNAL DV").
    public var title: String
    /// R1-R3, top to bottom; an empty label leaves a register blank.
    public var registers: [Register]
    public var lamps: Lamps
    /// What the computer asks or does now, in English ("ENABLE ENGINE
    /// IGNITION?").
    public var prompt: String
    /// Why PROG or OPR ERR is lit; nil with neither.
    public var reason: String?
    /// The digits keyed so far, with their sign ("+0040"); empty when none.
    public var keyBuffer: String

    public init(program: Int? = nil, verb: Int? = nil, noun: Int? = nil, flashing: Bool = false, title: String = "",
                registers: [Register] = [], lamps: Lamps = [], prompt: String = "", reason: String? = nil,
                keyBuffer: String = "") {
        self.program = program
        self.verb = verb
        self.noun = noun
        self.flashing = flashing
        self.title = title
        self.registers = registers
        self.lamps = lamps
        self.prompt = prompt
        self.reason = reason
        self.keyBuffer = keyBuffer
    }

    /// The display of a computer that is off or not running: all blank.
    public static let blank = DSKYDisplay()
}

/// The computer's answer to a load from the ground (`GuidanceComputer.uplink`).
public enum UplinkResult: Equatable, Sendable {
    case accepted
    /// Refused, with the reason for the pilot ("NOT IN P00").
    case refused(String)
}

/// An onboard computer flown through a DSKY: M2's CMC-lite, which ApolloSCS
/// hosts, and later M3's AGC adapter and M2.5's LGC-lite behind the same
/// seam. Its host runs `update` at the start of each control step, before
/// the attitude laws, and ends steps on `timeToNextEvent`; the displays read
/// `display` and `load`; the keys press `press`; the ground's SET calls
/// `uplink`; the warp governor reads `warpEvents`.
public protocol GuidanceComputer: AnyObject {
    /// What the display shows now.
    var display: DSKYDisplay { get }
    /// The burn loaded (P30's), which the navball's marker and the HUD show;
    /// nil when none.
    var load: ManeuverPlan? { get }
    /// A key pressed on the DSKY at `now`.
    func press(_ key: DSKYKey, at now: Epoch)
    /// A load from the ground at `now`; it lands in the program that takes
    /// it, or is refused.
    func uplink(_ plan: ManeuverPlan, at now: Epoch) -> UplinkResult
    /// One control step of `vessel` at `sim.time`.
    func update(_ vessel: Vessel, in sim: Simulation)
    /// `vessel`'s state for the displays where no host steps the computer
    /// (on a stack, in standby): nothing is flown.
    func observe(_ vessel: Vessel, in sim: Simulation)
    /// Seconds from `now` to the computer's next timed action, so that the
    /// host's step ends there; nil when none is scheduled.
    func timeToNextEvent(at now: Epoch) -> Double?
    /// The warp stops and caps the computer asks for from `now` on
    /// (`WarpEvent`).
    func warpEvents(after now: Epoch) -> [WarpEvent]
}

/// A flight program that carries an onboard computer (the CSM's SCS, which
/// hosts CMC-lite).
public protocol GuidanceComputerHost: AnyObject {
    var guidanceComputer: GuidanceComputer { get }
}

extension Vessel {
    /// The onboard computer aboard: its flight program's, or on a stack the
    /// one a part carries on standby (the CM's, under the Saturn's IU), where
    /// the programs that need no stepping still run; nil when none.
    public var guidanceComputer: GuidanceComputer? {
        if let host = flightProgram as? GuidanceComputerHost { return host.guidanceComputer }
        return parts.lazy.compactMap { ($0.standbyProgram as? GuidanceComputerHost)?.guidanceComputer }.first
    }
}
