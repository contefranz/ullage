import Foundation

// The service module, its SPS and SM RCS (track VG3).

extension ApolloShapeData {
    // MARK: SPS

    /// SPS (AJ10-137): the nozzle extension's exit, inside diameter. With the
    /// stations below, the bell from the gimbal to the exit is 118 in of the
    /// engine's 159.944 in (AOH 2.4-43, H).
    static let spsExitDiameter = 98.4                // in, AOH Vol. 1 2.4-43 (H; track D's aoh_block2_sps_rcs.csv)
    static let spsAreaRatio = 62.5                   // AOH Vol. 1 2.4-43 (H)
    static let spsGimbal = 833.0                     // Xa, datasheet §4 (L)
    /// The SM is 295 in long with its nozzle (datasheet §1.5, press kit,
    /// recalled): Xa 1010 - 295.
    static let spsExit = 715.0                       // Xa, datasheet §4 (L)

    // MARK: Service module

    /// The SM's cylinder runs from its aft bulkhead (`AS506.slaTop`, Xa 838)
    /// to the CM interface (`AS506.smTop`, Xa 1010), at the CSM's 154 in
    /// (`AS506.csmDiameter`).
    /// SM RCS quads: four packages 90° apart, each 7°15′ off its axis,
    /// counter-clockwise looking forward: A at -Z_A, B at +Y_A, C at +Z_A,
    /// D at -Y_A.
    static let rcsQuadStation = 959.0                // Xa, datasheet §4 (L)
    static let rcsQuadOffset = 7.25                  // deg, AOH Vol. 1 Fig. 2.4-3 (H; track D)
    static let rcsQuads: [(name: String, ya: Double, za: Double)] = [("A", 0, -1), ("B", 1, 0), ("C", 0, 1),
                                                                     ("D", -1, 0)]
    static let rcsExitDiameter = 5.6                 // in, R-4D nozzle exit, AOH Vol. 1 2.5-24 (H)
    static let rcsCant = 10.0                        // deg away from the panel, AOH Vol. 1 §2.5 (H)
    static let rcsNozzleLength = 6.0                 // in showing of the 13.4 in engine (AOH 2.5-24, H), estimate (L)
    static let rcsHousingHalfWidth = 12.0            // in, estimate (L)
    static let rcsHousingHeight = 6.0                // in above the skin, estimate (L)
    static let rcsJetSpacing = 8.0                   // in from the package centre, estimate (L)
}

extension ApolloDresser {
    func smShapes() -> [VisualShape]? {
        switch part.name {
        case "CSM":
            return serviceModule() + commandModule()
        case "SM":
            return serviceModule()
        default:
            return nil
        }
    }

    func smAttachments() -> [VisualAttachment] { [] }

    func serviceModule() -> [VisualShape] {
        let r = ApolloDresser.csmRadius, inch = D.inch
        var sps = finished(.revolution(ApolloDresser.bell(exitRadius: S.spsExitDiameter / 2 * inch,
                                                          areaRatio: S.spsAreaRatio,
                                                          length: (S.spsGimbal - S.spsExit) * inch),
                                       from: local(Vec3(xa(S.spsExit), 0, 0)),
                                       color: ApolloDresser.nozzleExtension.colour),
                           ApolloDresser.nozzleExtension, vehicleFrame: false)
        sps.capBase = false
        sps.twoSided = true
        if part.thrusters.contains(where: { $0.name == "SPS" }) { sps.thruster = "SPS" }
        return [frustum(xa(D.slaTop), xa(D.smTop), r, r, ApolloDresser.aluminium), sps] + rcsQuads()
    }

    /// The four SM RCS packages; their jets from the part's "SM RCS"
    /// thrusters when it has them (linked), else from the AOH's layout.
    func rcsQuads() -> [VisualShape] {
        typealias A = ApolloDresser
        let inch = D.inch, skin = A.csmRadius, deg = Double.pi / 180
        let jets = part.thrusters.filter { $0.name.hasPrefix("SM RCS") }
        let exitRadius = S.rcsExitDiameter / 2 * inch, nozzleLength = S.rcsNozzleLength * inch
        /// A jet's nozzle, its exit `exhaust` (unit) away from the throat `throat` (construction).
        func nozzle(throat: Vec3, exhaust: Vec3, thruster: String? = nil) -> VisualShape {
            var s = finished(VisualShape.revolution([P(0, exitRadius), P(nozzleLength, 0.35 * exitRadius)],
                                                    from: local(throat + exhaust * nozzleLength), axis: -exhaust,
                                                    segments: 12, color: A.dark.colour), A.dark, vehicleFrame: false)
            s.capBase = false
            s.twoSided = true
            s.thruster = thruster
            return s
        }
        var shapes: [VisualShape] = []
        for quad in S.rcsQuads {
            let angle = atan2(quad.za, quad.ya) - S.rcsQuadOffset * deg
            let out = ApolloAxes.direction(xa: 0, ya: cos(angle), za: sin(angle))
            let along = out.cross(.unitX)   // tangential, perpendicular to x and `out`
            let centre = Vec3(xa(S.rcsQuadStation), 0, 0) + out * skin
            var housing = revolution([P(0, S.rcsHousingHalfWidth * inch), P(S.rcsHousingHeight * inch,
                                                                             S.rcsHousingHalfWidth * inch)],
                                     at: centre - out * (0.5 * S.rcsHousingHeight * inch), axis: out,
                                     reference: Vec3.unitX, segments: 4,
                                     sweep: Double.pi / 4...(Double.pi / 4 + 2 * Double.pi), A.white)
            housing.faceted = true
            shapes.append(housing)
            guard jets.isEmpty else { continue }
            let throatAt = centre + out * (0.5 * S.rcsHousingHeight * inch), cant = S.rcsCant * deg
            for d in [Vec3.unitX, -Vec3.unitX, along, -along] {
                let exhaust = (d * cos(cant) + out * sin(cant)).normalized
                shapes.append(nozzle(throat: throatAt + d * (S.rcsJetSpacing * inch), exhaust: exhaust))
            }
        }
        for t in jets {
            shapes.append(nozzle(throat: t.position + construction, exhaust: -t.direction, thruster: t.name))
        }
        return shapes
    }
}
