import Foundation

// The S-II/S-IVB interstage, the S-IVB, its ullage rockets and the IU
// (track VG2).

extension ApolloDresser {
    func sIVBShapes() -> [VisualShape]? {
        typealias A = ApolloDresser
        switch part.name {
        case "S-II/S-IVB interstage":
            return [frustum(D.station(D.sIITop), D.station(D.sIVBAftSkirt), A.body, A.upper, A.white, open: true)]
        case "S-IVB":
            return [frustum(D.station(D.sIVBAftSkirt), D.station(D.sIVBTop), A.upper, A.upper, A.white),
                    frustum(D.station(D.sIVBJ2GimbalStation), D.station(D.sIVBAftSkirt), 0.12 * A.upper,
                            0.7 * A.upper, A.grey)]
                + bells(exit: D.station(D.sIVBJ2ExitStation), exitArea: D.j2ExitArea, areaRatio: D.j2AreaRatio, A.dark)
                + apsModules()
        case "S-IVB ullage rockets":
            // A fairing round each motor, on its side of the aft skirt.
            return part.thrusters.flatMap { t -> [VisualShape] in
                let x = t.position.x + construction.x
                return [frustum(x - 0.75, x + 0.4, 0.2, 0.2, A.white, y: t.position.y, z: t.position.z),
                        frustum(x + 0.4, x + 0.75, 0.2, 0.05, A.white, y: t.position.y, z: t.position.z)]
            }
        case "IU":
            return [frustum(D.station(D.sIVBTop), D.station(D.iuTop), A.upper, A.upper, A.grey, open: true)]
        default:
            return nil
        }
    }

    /// The S-II retros and the S-II/S-IVB plane (STA 2746.5) on the
    /// interstage that leaves with the S-II; the S-IVB's ullage motors.
    func sIVBAttachments() -> [VisualAttachment] {
        switch part.name {
        case "S-II/S-IVB interstage":
            return solidMotorPorts("retro", .retroPort)
                + [separationPlane("S-II/S-IVB separation plane", at: D.station(D.sIVBAftSkirt),
                                   radius: ApolloDresser.upper, up: true)]
        case "S-IVB ullage rockets":
            return solidMotorPorts("ullage", .ullageExit)
        default:
            return []
        }
    }

    /// The S-IVB's two APS modules on the aft skirt at Positions I and III.
    func apsModules() -> [VisualShape] {
        let x = D.height(D.apsModuleHeight)
        return [1.0, -1.0].map { side in
            frustum(x - 0.9, x + 0.9, 0.35, 0.35, ApolloDresser.grey, z: side * (ApolloDresser.upper + 0.15))
        }
    }
}
