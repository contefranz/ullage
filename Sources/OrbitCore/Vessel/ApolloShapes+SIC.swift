import Foundation

// The S-IC and the S-IC/S-II interstage (track VG1).

extension ApolloShapeData {
    // MARK: S-IC

    /// F-1: 16:1 at the nozzle extension's exit (10:1 at the extension joint).
    static let f1AreaRatio = 16.0                    // Saturn V News Reference, F-1 fact sheet (recalled, M)
}

extension ApolloDresser {
    func sICShapes() -> [VisualShape]? {
        typealias A = ApolloDresser
        switch part.name {
        case "S-IC":
            return [frustum(D.station(D.f1GimbalStation), D.station(D.sICTop), A.body, A.body, A.white)]
                + bells(exit: D.station(D.baseStation), exitArea: D.f1ExitArea, areaRatio: S.f1AreaRatio, A.dark)
        case "S-IC/S-II interstage":
            return [frustum(D.station(D.sICTop), D.station(D.sIIAftSkirt), A.body, A.body, A.white, open: true)]
        default:
            return nil
        }
    }

    /// The S-IC's eight retro ports and its separation plane (STA 1564);
    /// the interstage's four S-II ullage motors and its ring's plane (STA
    /// 1760).
    func sICAttachments() -> [VisualAttachment] {
        switch part.name {
        case "S-IC":
            return solidMotorPorts("retro", .retroPort)
                + [separationPlane("S-IC/S-II separation plane", at: D.station(D.sICSIISeparationPlane),
                                   radius: ApolloDresser.body, up: true)]
        case "S-IC/S-II interstage":
            return solidMotorPorts("ullage", .ullageExit)
                + [separationPlane("Interstage separation plane", at: D.station(D.sIIAftSkirt),
                                   radius: ApolloDresser.body, up: true)]
        default:
            return []
        }
    }
}
