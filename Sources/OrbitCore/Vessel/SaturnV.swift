import Foundation

extension VesselLibrary {
    /// Apollo 11's Saturn V (AS-506) with its spacecraft, at first motion:
    /// simulation time 0 is range time 0.30 s, and the S-IC tanks already lack
    /// the propellant burned since ignition. Data and sources are in `AS506`.
    ///
    /// Ten parts, bottom to top: S-IC, S-IC/S-II interstage, S-II, S-II/S-IVB
    /// interstage, S-IVB, IU, SLA, LM, CSM, LES. The Space key separates the
    /// S-IC, the interstage, the LES, then the S-II with the aft interstage;
    /// the rest never separates. F-1 and J-2 engines are on/off, and each stage
    /// carries interim TVC stand-ins for attitude control.
    ///
    /// The construction frame is the Saturn V station frame in metres (x = STA
    /// x 0.0254 m). Engines 1-4 are outboard, on the diagonals between the ±y
    /// and ±z axes, and engine 5 is the centre engine; how 1-4 map to Saturn
    /// positions I-IV is not established, so the layout is only symmetric.
    public static func saturnV(name: String = "Apollo 11") -> Vessel {
        typealias D = AS506
        let lb = D.pound
        let white = (0.9, 0.9, 0.88), dark = (0.25, 0.25, 0.27), grey = (0.72, 0.72, 0.74)

        /// A part spanning construction x `bottom...top` (m), placed at its
        /// middle. Its dry CoM is at `dryCenterOfMass` (construction x) if
        /// given, otherwise at the middle.
        func part(_ name: String, _ bottom: Double, _ top: Double, radius: Double, dryMass: Double,
                  dryCenterOfMass: Double? = nil, dragCoefficient: Double = 0.5, staging: StagingRule) -> VesselPart {
            let mid = (bottom + top) / 2
            return VesselPart(name: name, dryMass: dryMass, offset: Vec3(mid, 0, 0), length: top - bottom,
                              radius: radius, dragCoefficient: dragCoefficient,
                              dryCenterOfMass: Vec3((dryCenterOfMass ?? mid) - mid, 0, 0), staging: staging)
        }
        /// Part-frame point of construction coordinates (x, y, z).
        func local(_ p: VesselPart, _ x: Double, _ y: Double = 0, _ z: Double = 0) -> Vec3 {
            Vec3(x - p.offset.x, y, z)
        }
        func frustum(_ p: VesselPart, _ bottom: Double, _ top: Double, _ r0: Double, _ r1: Double,
                     _ color: (Double, Double, Double), y: Double = 0, z: Double = 0) -> VisualShape {
            .frustum(from: local(p, bottom, y, z), length: top - bottom, baseRadius: r0, topRadius: r1, color: color)
        }
        /// A settled column holding `load` lb, whose full-load centroid is the
        /// middle of `extent` (m above the base).
        func tank(_ name: String, in p: VesselPart, load: Double, unusable: Double = 0,
                  extent: (aft: Double, forward: Double), density: Double) -> PropellantTank {
            let m = load * lb
            let centroid = local(p, D.height((extent.aft + extent.forward) / 2))
            return PropellantTank(name: name, capacity: m, unusableMass: unusable * lb,
                                  geometry: .column(fullLoadCentroid: centroid, radius: p.radius, capacity: m,
                                                    density: density))
        }
        /// Five engines on one bipropellant feed, gimballed at `gimbal`: engines
        /// 1-4 at `radius` on the diagonals, engine 5 on the axis. Nozzle shapes
        /// run from the exit plane `exit` to the gimbal.
        func cluster(_ p: VesselPart, rating: EngineRating, gimbal: Double, exit: Double, radius: Double,
                     exitArea: Double, oxidizer: PropellantTank, fuel: PropellantTank) {
            let d = radius / 2.squareRoot(), exitRadius = (exitArea / Double.pi).squareRoot()
            for (i, (y, z)) in [(d, -d), (-d, -d), (-d, d), (d, d), (0, 0)].enumerated() {
                p.thrusters.append(Thruster(name: "\(p.name) engine \(i + 1)", position: local(p, gimbal, y, z),
                                            direction: .unitX, rating: rating,
                                            feed: .bipropellant(oxidizer: oxidizer, fuel: fuel), groups: [.main],
                                            throttleRange: 1...1))
                p.shapes.append(frustum(p, exit, gimbal, exitRadius, 0.3 * exitRadius, dark, y: y, z: z))
            }
        }
        /// Stand-in couples at ±0.45 of the part length about its middle.
        func standIns(_ p: VesselPart, thrust: Double, tank: PropellantTank) {
            addTVCStandIns(to: p, prefix: p.name, foreX: 0.45 * p.length, aftX: -0.45 * p.length, radius: p.radius,
                           thrust: thrust, tank: tank)
        }

        let body = D.bodyDiameter / 2 * D.inch, upper = D.sIVBDiameter / 2 * D.inch
        let csmRadius = D.csmDiameter / 2 * D.inch

        // S-IC: engines below the thrust structure, RP-1 below LOX.
        let sIC = part("S-IC", D.station(D.baseStation), D.station(D.sICTop), radius: body,
                       dryMass: (D.sICDry + D.sICOther) * lb, dryCenterOfMass: D.height(D.sICDryCoMHeight),
                       dragCoefficient: D.bodyDragCoefficient, staging: .event(1))
        let sICLOX = tank("S-IC LOX", in: sIC, load: D.sICLOXAtFirstMotion, unusable: D.sICLOXAtCutoff,
                          extent: D.sICLOXExtent, density: D.loxDensity)
        let sICRP1 = tank("S-IC RP-1", in: sIC, load: D.sICRP1AtFirstMotion, extent: D.sICRP1Extent,
                          density: D.rp1Density)
        sIC.tanks = [sICLOX, sICRP1]
        sIC.shapes = [frustum(sIC, D.station(D.f1GimbalStation), D.station(D.sICTop), body, body, white)]
        cluster(sIC, rating: D.f1, gimbal: D.station(D.f1GimbalStation), exit: D.station(D.baseStation),
                radius: D.f1OutboardRadius * D.inch, exitArea: D.f1ExitArea, oxidizer: sICLOX, fuel: sICRP1)
        standIns(sIC, thrust: D.sICStandInThrust, tank: sICRP1)

        let interstage = part("S-IC/S-II interstage", D.station(D.sICTop), D.station(D.sIIAftSkirt), radius: body,
                              dryMass: D.sICSIIInterstage * lb, dragCoefficient: D.bodyDragCoefficient,
                              staging: .event(2))
        interstage.shapes = [frustum(interstage, D.station(D.sICTop), D.station(D.sIIAftSkirt), body, body, white)]

        // S-II: LOX aft, LH2 forward over a common bulkhead. Its J-2s hang
        // into the interstage below.
        let sII = part("S-II", D.station(D.sIIAftSkirt), D.station(D.sIITop), radius: body,
                       dryMass: (D.sIIDry + D.sIIOther) * lb, dragCoefficient: D.bodyDragCoefficient,
                       staging: .event(4))
        let sIILOX = tank("S-II LOX", in: sII, load: D.sIILOXLoad, unusable: D.sIILOXUnusable,
                          extent: D.sIILOXExtent, density: D.loxDensity)
        let sIILH2 = tank("S-II LH2", in: sII, load: D.sIILH2Load, extent: D.sIILH2Extent, density: D.lh2Density)
        sII.tanks = [sIILOX, sIILH2]
        sII.shapes = [frustum(sII, D.station(D.sIIAftSkirt), D.station(D.sIITop), body, body, white)]
        cluster(sII, rating: D.sIIJ2, gimbal: D.height(D.sIIJ2GimbalHeight), exit: D.height(D.sIIJ2ExitHeight),
                radius: D.sIIOutboardCircle / 2 * D.foot, exitArea: D.j2ExitArea, oxidizer: sIILOX, fuel: sIILH2)
        standIns(sII, thrust: D.sIIStandInThrust, tank: sIILH2)

        let aftInterstage = part("S-II/S-IVB interstage", D.station(D.sIITop), D.station(D.sIVBAftSkirt),
                                 radius: body, dryMass: D.sIISIVBInterstage * lb,
                                 dragCoefficient: D.bodyDragCoefficient, staging: .event(4))
        aftInterstage.shapes = [frustum(aftInterstage, D.station(D.sIITop), D.station(D.sIVBAftSkirt), body, upper,
                                        white)]

        // S-IVB: one J-2, inside the aft interstage until the S-II leaves.
        let sIVB = part("S-IVB", D.station(D.sIVBAftSkirt), D.station(D.sIVBTop), radius: upper,
                        dryMass: (D.sIVBDry + D.sIVBOther) * lb, staging: .fixed)
        let sIVBLOX = tank("S-IVB LOX", in: sIVB, load: D.sIVBLOXLoad, unusable: D.sIVBLOXUnusable,
                           extent: D.sIVBLOXExtent, density: D.loxDensity)
        let sIVBLH2 = tank("S-IVB LH2", in: sIVB, load: D.sIVBLH2Load, unusable: D.sIVBLH2Unusable,
                           extent: D.sIVBLH2Extent, density: D.lh2Density)
        sIVB.tanks = [sIVBLOX, sIVBLH2]
        let j2ExitRadius = (D.j2ExitArea / Double.pi).squareRoot()
        sIVB.thrusters.append(Thruster(name: "S-IVB engine", position: local(sIVB, D.height(D.sIVBJ2GimbalHeight)),
                                       direction: .unitX, rating: D.sIVBJ2Burn1,
                                       feed: .bipropellant(oxidizer: sIVBLOX, fuel: sIVBLH2), groups: [.main],
                                       throttleRange: 1...1))
        sIVB.shapes = [frustum(sIVB, D.station(D.sIVBAftSkirt), D.station(D.sIVBTop), upper, upper, white),
                       frustum(sIVB, D.height(D.sIVBJ2ExitHeight), D.height(D.sIVBJ2GimbalHeight), j2ExitRadius,
                               0.3 * j2ExitRadius, dark)]
        standIns(sIVB, thrust: D.sIVBStandInThrust, tank: sIVBLH2)

        let iu = part("IU", D.station(D.sIVBTop), D.station(D.iuTop), radius: upper, dryMass: D.iu * lb,
                      staging: .fixed)
        iu.shapes = [frustum(iu, D.station(D.sIVBTop), D.station(D.iuTop), upper, upper, grey)]

        let sla = part("SLA", D.station(D.iuTop), D.apolloStation(D.slaTop), radius: upper, dryMass: D.sla * lb,
                       staging: .fixed)
        sla.shapes = [frustum(sla, D.station(D.iuTop), D.apolloStation(D.slaTop), upper, csmRadius, white)]

        // Inside the SLA, so it has no shapes.
        let lm = part("LM", D.height(D.lmBottomHeight), D.height(D.lmTopHeight), radius: D.lmRadius,
                      dryMass: D.lm * lb, staging: .fixed)

        // CSM as one part (M2 splits it). No CSM CG was found: the SM and CM
        // each sit at their own mid-station.
        let smMid = D.apolloStation((D.slaTop + D.smTop) / 2), cmMid = D.apolloStation((D.smTop + D.cmApex) / 2)
        let csm = part("CSM", D.apolloStation(D.slaTop), D.apolloStation(D.cmApex), radius: csmRadius,
                       dryMass: (D.sm + D.cm) * lb,
                       dryCenterOfMass: (D.sm * smMid + D.cm * cmMid) / (D.sm + D.cm), staging: .fixed)
        csm.shapes = [frustum(csm, D.apolloStation(D.slaTop), D.apolloStation(D.smTop), csmRadius, csmRadius,
                              (0.7, 0.72, 0.75)),
                      frustum(csm, D.apolloStation(D.smTop), D.apolloStation(D.cmApex), csmRadius,
                              D.cmApexDiameter / 2, (0.8, 0.8, 0.8))]

        // LES with the boost protective cover; tower, motor and nose are crude.
        let lesTop = D.station(D.baseStation) + D.overallHeight * D.foot
        let lesBottom = lesTop - D.lesLength * D.foot
        let les = part("LES", lesBottom, lesTop, radius: D.lesRadius, dryMass: D.les * lb, staging: .event(3))
        les.shapes = [frustum(les, lesBottom, lesBottom + 3.5, 0.66, 0.33, grey),
                      frustum(les, lesBottom + 3.5, lesTop - 1, 0.33, 0.33, white),
                      frustum(les, lesTop - 1, lesTop, 0.33, 0.05, white)]

        return Vessel(name: name, parts: [sIC, interstage, sII, aftInterstage, sIVB, iu, sla, lm, csm, les],
                      reference: placeholderBody)
    }

    /// Interim attitude control for a stage until the TVC item replaces it:
    /// pitch, yaw and roll couples (no net force, no translation groups) of
    /// `thrust` each, at `foreX` / `aftX` and `radius` in the part frame. They
    /// draw from `tank` at a negligible rate (`AS506.standInIsp`). Names are
    /// "<prefix> TVC stand-in <place>".
    static func addTVCStandIns(to part: VesselPart, prefix: String, foreX: Double, aftX: Double, radius r: Double,
                               thrust: Double, tank: PropellantTank) {
        let rating = EngineRating(name: "TVC stand-in", thrustVacuum: thrust, ispVacuum: AS506.standInIsp)
        func add(_ place: String, _ position: Vec3, _ direction: Vec3, _ group: ThrusterGroup) {
            part.thrusters.append(Thruster(name: "\(prefix) TVC stand-in \(place)", position: position,
                                           direction: direction, rating: rating, feed: .single(tank),
                                           groups: [group]))
        }
        // Body axes as in `VesselPart.addRCS`: pitch up turns the nose towards -z.
        add("fwd -z", Vec3(foreX, 0, r), Vec3(0, 0, -1), .pitchUp)
        add("aft +z", Vec3(aftX, 0, -r), Vec3(0, 0, 1), .pitchUp)
        add("fwd +z", Vec3(foreX, 0, -r), Vec3(0, 0, 1), .pitchDown)
        add("aft -z", Vec3(aftX, 0, r), Vec3(0, 0, -1), .pitchDown)
        add("fwd +y", Vec3(foreX, -r, 0), Vec3(0, 1, 0), .yawRight)
        add("aft -y", Vec3(aftX, r, 0), Vec3(0, -1, 0), .yawRight)
        add("fwd -y", Vec3(foreX, r, 0), Vec3(0, -1, 0), .yawLeft)
        add("aft +y", Vec3(aftX, -r, 0), Vec3(0, 1, 0), .yawLeft)
        add("roll R1", Vec3(foreX, 0, -r), Vec3(0, 1, 0), .rollRight)
        add("roll R2", Vec3(foreX, 0, r), Vec3(0, -1, 0), .rollRight)
        add("roll L1", Vec3(foreX, 0, -r), Vec3(0, -1, 0), .rollLeft)
        add("roll L2", Vec3(foreX, 0, r), Vec3(0, 1, 0), .rollLeft)
    }
}
