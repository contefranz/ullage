import Foundation
import OrbitCore

/// Who flies a vessel's attitude, for the displays (the HUD's HOLD row, the
/// CMC page's ATT line).
public enum AttitudeOwner {
    /// The program whose command the hold flies: "IU" for the Saturn's,
    /// "G&N" while the SCS flies the computer's attitude, "SCS" for the
    /// CSM's own hold, "CM" for the CM's entry program (or the SCS once the
    /// SM has gone); nil without a program.
    public static func program(_ v: Vessel) -> String? {
        switch v.flightProgram {
        case nil: return nil
        case is SaturnIU: return "IU"
        case is CMEntryProgram, is EarthLandingSystem: return "CM"
        case let scs as ApolloSCS:
            if !v.parts.contains(where: { $0.name == "SM" }) { return "CM" }
            return scs.gnAuto ? "G&N" : "SCS"
        default: return "PGM"
        }
    }

    /// One line for the attitude: "G&N AUTO", "IU HOLD", "SCS HOLD", "CM
    /// ENTRY", "SCS PROGRADE", "FREE".
    public static func describe(_ v: Vessel) -> String {
        let program = Self.program(v)
        if program == "G&N" { return "G&N AUTO" }
        guard let mode = v.autopilot else { return "FREE" }
        let who = program ?? "PILOT"
        switch mode {
        case .attitudeHold: return "\(who) HOLD"
        case .entry: return "CM ENTRY"
        default: return "\(who) " + mode.rawValue.uppercased()
        }
    }
}
