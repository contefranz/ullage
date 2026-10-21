import Foundation

/// Which Apollo vehicle a part belongs to: its launch vehicle, its CSM and
/// what rode in the SLA, so that the dresser (`VesselLibrary.dressApollo`)
/// can draw what differed between flights. It rides on the part
/// (`VesselPart.appearance`), so it stays with the part through every
/// separation: a re-dress after a split keeps CSM-103 as CSM-103. Only the
/// look reads it; the physics never does.
///
/// Apollo 8's payload part keeps the contract name "LM", and the dresser
/// draws LTA-B from the variant, so the IU's program and the separations
/// keep working by name. AS-501 and AS-502 (Apollo 4 and 6) are here for
/// the markings tables only: their Block I CSMs are not built.
public struct ApolloVariant: Hashable {
    /// The Saturn V.
    public enum LaunchVehicle: String, CaseIterable {
        case as501 = "AS-501", as502 = "AS-502", as503 = "AS-503", as506 = "AS-506"
    }

    /// The Block II CSM.
    public enum CSM: String, CaseIterable {
        case csm101 = "CSM-101", csm103 = "CSM-103", csm107 = "CSM-107"
    }

    /// What rode in the SLA.
    public enum Payload: Hashable {
        /// Nothing: Apollo 7's SLA flew empty.
        case empty
        /// Lunar Test Article B, Apollo 8's ballast in place of a LM.
        case ltaB
        /// LM-`n` (Apollo 11's LM-5).
        case lm(Int)
    }

    /// nil: not a Saturn V (Apollo 7's Saturn IB, which is not built).
    public var launchVehicle: LaunchVehicle?
    public var csm: CSM
    public var payload: Payload

    public init(launchVehicle: LaunchVehicle?, csm: CSM, payload: Payload) {
        self.launchVehicle = launchVehicle
        self.csm = csm
        self.payload = payload
    }

    /// Apollo 7: CSM-101, launched by a Saturn IB, its SLA empty.
    public static let apollo7 = ApolloVariant(launchVehicle: nil, csm: .csm101, payload: .empty)
    /// Apollo 8: AS-503, CSM-103 and LTA-B.
    public static let apollo8 = ApolloVariant(launchVehicle: .as503, csm: .csm103, payload: .ltaB)
    /// Apollo 11: AS-506, CSM-107 and LM-5.
    public static let apollo11 = ApolloVariant(launchVehicle: .as506, csm: .csm107, payload: .lm(5))

    /// The vehicle a mission's spacecraft builders stand for.
    public init(_ mission: ApolloCM.Mission) {
        switch mission {
        case .apollo7: self = .apollo7
        case .apollo11: self = .apollo11
        }
    }
}
