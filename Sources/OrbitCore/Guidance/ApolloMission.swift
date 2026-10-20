import Foundation

/// The Apollo spacecraft's flight programs wired for a mission: the CSM's
/// stabilization and control system (`ApolloSCS`, track C) flies the CSM
/// and, once the SM has gone, hands the command module to its entry program
/// (`CMEntryProgram`), which flies it to splashdown.
public enum ApolloMission {
    /// The SCS a CSM carries (`VesselLibrary.apolloCSM`, and on standby on
    /// the Saturn V), with the CM's entry program as its successor, holding
    /// `entryMode` (lift up unless told otherwise).
    public static func spacecraftControl(separationUllage: Double = 0,
                                         entryMode: CMEntryProgram.Mode = .bankHold(0)) -> ApolloSCS {
        let scs = ApolloSCS(separationUllage: separationUllage)
        scs.successor = CMEntryProgram(mode: entryMode)
        return scs
    }

    /// The CM's entry program flying `v`: its own program, or the one its
    /// SCS hosts; nil when it carries none.
    public static func entryProgram(of v: Vessel) -> CMEntryProgram? {
        if let p = v.flightProgram as? CMEntryProgram { return p }
        return (v.flightProgram as? ApolloSCS)?.successor as? CMEntryProgram
    }

    /// The earth landing system bringing `v` down: its own program, or the
    /// one its entry program runs.
    public static func landingSystem(of v: Vessel) -> EarthLandingSystem? {
        (v.flightProgram as? EarthLandingSystem) ?? entryProgram(of: v)?.els
    }
}
