import Foundation

extension VesselLibrary {
    /// Give the parts of `saturnV()`'s stack their shapes, by part name:
    /// cylinders and cones for the stages, interstages, IU, SLA, CSM and LES,
    /// and a cone for each main engine's nozzle, from its exit plane to its
    /// gimbal. The LM is inside the SLA and the S-IVB ullage rockets are
    /// small, so they have none. Each part's shapes replace any it had.
    public static func dressSaturnV(_ stack: Vessel) {
        typealias D = AS506
        let white = (0.9, 0.9, 0.88), dark = (0.25, 0.25, 0.27), grey = (0.72, 0.72, 0.74)
        let body = D.bodyDiameter / 2 * D.inch, upper = D.sIVBDiameter / 2 * D.inch
        let csmRadius = D.csmDiameter / 2 * D.inch
        let lesTop = D.station(D.baseStation) + D.overallHeight * D.foot
        let lesBottom = lesTop - D.lesLength * D.foot

        for p in stack.parts {
            // The part's reference point in construction coordinates.
            let mid = (p.offset - stack.structureOrigin).x
            /// A frustum from construction x `bottom` to `top` (m), off the
            /// axis by (`y`, `z`).
            func frustum(_ bottom: Double, _ top: Double, _ r0: Double, _ r1: Double,
                         _ color: (Double, Double, Double), y: Double = 0, z: Double = 0) -> VisualShape {
                .frustum(from: Vec3(bottom - mid, y, z), length: top - bottom, baseRadius: r0, topRadius: r1,
                         color: color)
            }
            /// A cone per main engine, from the exit plane `exit` to the
            /// gimbal (construction x), whose exit has area `exitArea`.
            func nozzles(exit: Double, gimbal: Double, exitArea: Double) -> [VisualShape] {
                let exitRadius = (exitArea / Double.pi).squareRoot()
                return p.thrusters.filter { $0.groups.contains(.main) }.map {
                    frustum(exit, gimbal, exitRadius, 0.3 * exitRadius, dark, y: $0.position.y, z: $0.position.z)
                }
            }
            switch p.name {
            case "S-IC":
                p.shapes = [frustum(D.station(D.f1GimbalStation), D.station(D.sICTop), body, body, white)]
                    + nozzles(exit: D.station(D.baseStation), gimbal: D.station(D.f1GimbalStation),
                              exitArea: D.f1ExitArea)
            case "S-IC/S-II interstage":
                p.shapes = [frustum(D.station(D.sICTop), D.station(D.sIIAftSkirt), body, body, white)]
            case "S-II":
                p.shapes = [frustum(D.station(D.sIIAftSkirt), D.station(D.sIITop), body, body, white)]
                    + nozzles(exit: D.station(D.sIIJ2ExitStation), gimbal: D.station(D.sIIJ2GimbalStation),
                              exitArea: D.j2ExitArea)
            case "S-II/S-IVB interstage":
                p.shapes = [frustum(D.station(D.sIITop), D.station(D.sIVBAftSkirt), body, upper, white)]
            case "S-IVB":
                p.shapes = [frustum(D.station(D.sIVBAftSkirt), D.station(D.sIVBTop), upper, upper, white)]
                    + nozzles(exit: D.station(D.sIVBJ2ExitStation), gimbal: D.station(D.sIVBJ2GimbalStation),
                              exitArea: D.j2ExitArea)
            case "IU":
                p.shapes = [frustum(D.station(D.sIVBTop), D.station(D.iuTop), upper, upper, grey)]
            case "SLA":
                p.shapes = [frustum(D.station(D.iuTop), D.apolloStation(D.slaTop), upper, csmRadius, white)]
            case "CSM":
                p.shapes = [frustum(D.apolloStation(D.slaTop), D.apolloStation(D.smTop), csmRadius, csmRadius,
                                    (0.7, 0.72, 0.75)),
                            frustum(D.apolloStation(D.smTop), D.apolloStation(D.cmApex), csmRadius,
                                    D.cmApexDiameter / 2, (0.8, 0.8, 0.8))]
            case "LES":
                // Tower, motor and nose are crude.
                p.shapes = [frustum(lesBottom, lesBottom + 3.5, 0.66, 0.33, grey),
                            frustum(lesBottom + 3.5, lesTop - 1, 0.33, 0.33, white),
                            frustum(lesTop - 1, lesTop, 0.33, 0.05, white)]
            default:
                break
            }
        }
    }
}
