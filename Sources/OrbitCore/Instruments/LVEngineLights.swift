import Foundation

/// The Saturn's engine status lights on the command module's main display
/// console (LV ENGINES 1-5, yellow, on MDC-1), read from the engines of the
/// vessel's active stage. Each is lit while its engine "is operating below
/// its predetermined level of thrust" (AOH SM2A-03-Block II-(1), p. 3-78):
/// the IU's switching logic reads each engine's thrust-OK pressure switches,
/// which close at 90 % of thrust on an F-1 and 65 % on a J-2 (SA-506 Flight
/// Manual, pp. 2-1 and 3-1). So the lights are lit before ignition, go out as
/// the engines come up to thrust, and light again at a cutoff, an engine
/// failure and staging, until the next stage's engines come up.
///
/// - S-IC and S-II: light n is engine n, 1-4 outboard and 5 the centre,
///   laid out as the engines are (4 1 / 5 / 3 2). The IU's latching relays
///   switch them to the S-II at S-IC/S-II separation (IBM 66-966-0022
///   ¶2-9).
/// - S-IVB, from S-II/S-IVB separation: light 1 is its single J-2; "the
///   remaining 4 lights [are] not operative" (Flight Manual Fig. 6-3).
/// - Without a Saturn stage (the spacecraft alone) there are none (nil),
///   nor on a wreck (`.crashed`): the simulation no longer steps its
///   engines, so they would hold the thrust they had at the impact.
///
/// Not modelled: the momentary blank the logic gives all five at each
/// separation, whose length was not found, and the EDS POWER switch, which
/// the crew turned off after insertion (the lights then go dark) and on
/// again before TLI: here light 1 stays lit in Earth orbit.
public struct LVEngineLights: Equatable {
    /// The stages the lights read.
    public enum Stage: String, Equatable, Sendable {
        case sIC = "S-IC", sII = "S-II", sIVB = "S-IVB"

        /// The fraction of an engine's thrust below which its light is lit:
        /// its thrust-OK pressure switches' level (Flight Manual p. 3-1: 90 %
        /// for the F-1, 65 % for the J-2; the F-1's switches stay closed
        /// from 89 %, IBM ¶2-6).
        public var thrustOK: Double { self == .sIC ? 0.90 : 0.65 }
    }

    /// The stage whose engines they show.
    public let stage: Stage
    /// Lights 1-5 (index 0 is light 1): lit (true) while the engine is
    /// below its thrust-OK level.
    public let lit: [Bool]

    /// The lights of `v`'s active stage, or nil (dark) when that is not a
    /// Saturn stage or `v` is a wreck.
    public init?(vessel v: Vessel) {
        guard v.status != .crashed, let part = v.activeStage, let stage = Stage(rawValue: part.name) else {
            return nil
        }
        let mains = part.thrusters.filter { $0.groups.contains(.main) }
        func lit(_ e: Thruster?) -> Bool { e.map { !Self.isThrustOK($0, stage) } ?? false }
        self.stage = stage
        switch stage {
        case .sIC, .sII:
            self.lit = (1...5).map { n in lit(mains.first { $0.name == "\(part.name) engine \(n)" }) }
        case .sIVB:
            self.lit = [lit(mains.first)] + Array(repeating: false, count: 4)
        }
    }

    /// The engine delivers at least its stage's `thrustOK` fraction of its
    /// thrust at its present setting this step, start and shutdown ramps
    /// included. (The S-II's mixture-ratio shift changes the setting, to
    /// about 80 % of the high setting's thrust, well above 65 %.)
    public static func isThrustOK(_ e: Thruster, _ stage: Stage) -> Bool {
        (e.output?.fraction ?? 0) >= stage.thrustOK
    }
}
