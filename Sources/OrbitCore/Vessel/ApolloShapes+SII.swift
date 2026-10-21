import Foundation

// The S-II (track VG2).

extension ApolloDresser {
    func sIIShapes() -> [VisualShape]? {
        typealias A = ApolloDresser
        switch part.name {
        case "S-II":
            // The thrust structure hangs below the aft skirt to the gimbal plane.
            return [frustum(D.station(D.sIIAftSkirt), D.station(D.sIITop), A.body, A.body, A.white),
                    frustum(D.station(D.sIIJ2GimbalStation), D.station(D.sIIAftSkirt), 0.6 * A.body, A.body, A.grey)]
                + bells(exit: D.station(D.sIIJ2ExitStation), exitArea: D.j2ExitArea, areaRatio: D.j2AreaRatio, A.dark)
        default:
            return nil
        }
    }

    func sIIAttachments() -> [VisualAttachment] { [] }
}
