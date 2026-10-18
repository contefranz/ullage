import Foundation

extension VesselLibrary {
    /// Apollo 11's Saturn V (AS-506) with its spacecraft, at first motion:
    /// simulation time 0 is range time 0.30 s, and the S-IC tanks already lack
    /// the propellant burned since ignition. Data and sources are in `AS506`.
    ///
    /// Eleven parts, bottom to top: S-IC, S-IC/S-II interstage, S-II, S-II/S-IVB
    /// interstage, S-IVB, S-IVB ullage rockets, IU, SLA, LM, CSM, LES. The
    /// Space key separates the S-IC, the interstage, the LES, the S-II with
    /// the aft interstage, then the ullage rockets' cases; the rest never
    /// separates. The S-IC and S-II separate on their retro motors, which
    /// their separation lights; the S-II and S-IVB ullage motors light at the
    /// IU's command or at the separation below them, whichever comes first.
    /// F-1 and J-2 engines are on/off. The outboard
    /// engines of the S-IC and S-II and the S-IVB J-2 gimbal, each on a
    /// pitch-plane and a yaw-plane actuator; the centre engines are fixed. The
    /// S-IVB APS works once the S-IVB is the active stage: roll during its
    /// burn, three axes in coast.
    ///
    /// The construction frame is the Saturn V station frame in metres (x = STA
    /// x 0.0254 m), whose y and z are the Saturn Y and Z: +z towards Position
    /// I, +y towards Position IV. Engines 1-4 are outboard under fins A-D, on
    /// the diagonals between Positions I-II, II-III, III-IV and IV-I, and
    /// engine 5 is the centre engine.
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
        /// A settled column holding `load` kg, whose full-load centroid is the
        /// middle of `extent` (stations).
        func tank(_ name: String, in p: VesselPart, load m: Double, unusable: Double = 0,
                  extent: (aft: Double, forward: Double), density: Double) -> PropellantTank {
            let centroid = local(p, D.station((extent.aft + extent.forward) / 2))
            return PropellantTank(name: name, capacity: m, unusableMass: unusable,
                                  geometry: .column(fullLoadCentroid: centroid, radius: p.radius, capacity: m,
                                                    density: density))
        }
        /// Five engines on one bipropellant feed, gimballed at `gimbal`: engines
        /// 1-4 at `radius` on the diagonals under fins A-D, with `actuators`;
        /// engine 5 fixed on the axis. Nozzle shapes run from the exit plane
        /// `exit` to the gimbal.
        func cluster(_ p: VesselPart, rating: EngineRating, schedule: PerformanceSchedule? = nil,
                     transients: EngineTransients, gimbal: Double, exit: Double, radius: Double,
                     exitArea: Double, oxidizer: PropellantTank, fuel: PropellantTank, actuators: [GimbalActuator]) {
            let d = radius / 2.squareRoot(), exitRadius = (exitArea / Double.pi).squareRoot()
            for (i, (y, z)) in [(-d, d), (-d, -d), (d, -d), (d, d), (0, 0)].enumerated() {
                let e = Thruster(name: "\(p.name) engine \(i + 1)", position: local(p, gimbal, y, z),
                                 direction: .unitX, rating: rating,
                                 feed: .bipropellant(oxidizer: oxidizer, fuel: fuel), groups: [.main],
                                 throttleRange: 1...1, gimbal: i < 4 ? actuators : [])
                e.schedule = schedule
                e.transients = transients
                p.thrusters.append(e)
                p.shapes.append(frustum(p, exit, gimbal, exitRadius, 0.3 * exitRadius, dark, y: y, z: z))
            }
        }
        /// Solid motors at construction x `x`, at `radius` in the directions
        /// `at` (unit (y, z)), each of `thrust` N for `burn` s on its own
        /// equal share of `propellant` kg: a dud keeps its grain. The grains
        /// share the set's name (one HUD row). The force is along +x
        /// (`forward`) or -x, canted `cant` degrees towards the axis: the
        /// nozzles point outward. `start` delays and ramps the thrust after
        /// ignition.
        func solids(_ name: String, on p: VesselPart, at directions: [(y: Double, z: Double)], x: Double,
                    radius: Double, thrust: Double, burn: Double, propellant: Double, cant: Double, forward: Bool,
                    trigger: SolidTrigger, start: EngineTransients? = nil) {
            let share = propellant / Double(directions.count)
            let rating = EngineRating(name: name, thrustVacuum: thrust, ispVacuum: thrust * burn / (share * standardGravity))
            for (i, d) in directions.enumerated() {
                let at = local(p, x, radius * d.y, radius * d.z)
                let grain = PropellantTank(name: name, capacity: share, geometry: .point(at))
                p.tanks.append(grain)
                let outward = Vec3(0, d.y, d.z).normalized
                let axial = forward ? Vec3.unitX : -Vec3.unitX
                let t = Thruster(name: "\(name) motor \(i + 1)", position: at,
                                 direction: axial * cos(cant * D.degree) - outward * sin(cant * D.degree),
                                 rating: rating, feed: .single(grain), groups: [])
                t.isSolid = true
                t.trigger = trigger
                t.transients = start
                p.thrusters.append(t)
            }
        }
        let positions = [(y: 0.0, z: 1.0), (y: -1.0, z: 0.0), (y: 0.0, z: -1.0), (y: 1.0, z: 0.0)]   // I-IV
        let s = 0.5.squareRoot()
        let diagonals = [(y: -s, z: s), (y: -s, z: -s), (y: s, z: -s), (y: s, z: s)]   // fins A-D

        /// Pitch-plane and yaw-plane actuators, parallel to the vehicle Y and Z
        /// axes. With the gimbal aft of the CoM a positive angle gives a positive
        /// pitch or yaw torque, the sign of the Saturn's δp and δy.
        func actuators(range: Double, rate: Double) -> [GimbalActuator] {
            [GimbalActuator(tilt: .unitZ, limit: range * D.degree, rateLimit: rate * D.degree),
             GimbalActuator(tilt: -Vec3.unitY, limit: range * D.degree, rateLimit: rate * D.degree)]
        }

        let body = D.bodyDiameter / 2 * D.inch, upper = D.sIVBDiameter / 2 * D.inch
        let csmRadius = D.csmDiameter / 2 * D.inch

        // S-IC at first motion: engines below the thrust structure, RP-1
        // below LOX. Its dry mass is the FER stage less its tanks and retro
        // grains, with the small interstage ring that leaves with it. The
        // retros, not springs, separate it.
        let sIC = part("S-IC", D.station(D.baseStation), D.station(D.sICTop), radius: body,
                       dryMass: D.sICAtFirstMotion - D.sICLOXAtFirstMotion - D.sICRP1AtFirstMotion
                           - D.sICRetroPropellant + D.sICSIIInterstageSmall,
                       dryCenterOfMass: D.station(D.sICDryCoMStation),
                       dragCoefficient: D.bodyDragCoefficient, staging: .event(1))
        sIC.separationSpeed = 0
        let sICLOX = tank("S-IC LOX", in: sIC, load: D.sICLOXAtFirstMotion, unusable: D.sICLOXAtCutoff,
                          extent: D.sICLOXExtent, density: D.loxDensity)
        let sICRP1 = tank("S-IC RP-1", in: sIC, load: D.sICRP1AtFirstMotion, extent: D.sICRP1Extent,
                          density: D.rp1Density)
        sIC.tanks = [sICLOX, sICRP1]
        sIC.shapes = [frustum(sIC, D.station(D.f1GimbalStation), D.station(D.sICTop), body, body, white)]
        cluster(sIC, rating: D.f1, schedule: D.f1Schedule, transients: D.f1Transients,
                gimbal: D.station(D.f1GimbalStation), exit: D.station(D.baseStation),
                radius: D.f1OutboardRadius * D.inch, exitArea: D.f1ExitArea, oxidizer: sICLOX, fuel: sICRP1,
                actuators: actuators(range: D.f1GimbalRange, rate: D.f1GimbalRate))
        // Eight retros, a pair in each fairing, side by side about its fin.
        let pair = D.sICRetroPairOffset * D.degree
        let retroDirections = diagonals.flatMap { d -> [(y: Double, z: Double)] in
            let a = atan2(d.y, d.z)
            return [(y: sin(a - pair), z: cos(a - pair)), (y: sin(a + pair), z: cos(a + pair))]
        }
        solids("S-IC retro", on: sIC, at: retroDirections, x: D.station(D.sICRetroStation), radius: D.sICRetroRadius,
               thrust: D.sICRetroThrust, burn: D.sICRetroBurnTime, propellant: D.sICRetroPropellant,
               cant: D.sICRetroCant, forward: false, trigger: .ownSeparation, start: D.sICRetroStart)

        // The large interstage, with the four S-II ullage motors: lit by the
        // IU's ullage command, or at the S-IC's separation if not yet lit.
        let interstage = part("S-IC/S-II interstage", D.station(D.sICTop), D.station(D.sIIAftSkirt), radius: body,
                              dryMass: D.sICSIIInterstageLarge, dragCoefficient: D.bodyDragCoefficient,
                              staging: .event(2))
        interstage.shapes = [frustum(interstage, D.station(D.sICTop), D.station(D.sIIAftSkirt), body, body, white)]
        solids("S-II ullage", on: interstage, at: positions, x: D.station(D.sIIUllageMotorStation),
               radius: D.sIIUllageMotorRadius,
               thrust: D.sIIUllageMotorThrust * D.poundForce, burn: D.sIIUllageMotorBurnTime,
               propellant: D.sIIUllageMotorPropellant, cant: D.sIIUllageMotorCant, forward: true,
               trigger: .event(1))

        // S-II: LOX aft, LH2 forward over a common bulkhead. Its J-2s hang
        // into the interstage below.
        let sII = part("S-II", D.station(D.sIIAftSkirt), D.station(D.sIITop), radius: body,
                       dryMass: (D.sIIDry + D.sIIOther) * lb, dryCenterOfMass: D.station(D.sIIDryCoMStation),
                       dragCoefficient: D.bodyDragCoefficient, staging: .event(4))
        let sIILOX = tank("S-II LOX", in: sII, load: D.sIILOXLoad * lb, unusable: D.sIILOXAtCutoff,
                          extent: D.sIILOXExtent, density: D.loxDensity)
        let sIILH2 = tank("S-II LH2", in: sII, load: D.sIILH2Load * lb, extent: D.sIILH2Extent,
                          density: D.lh2Density)
        sII.tanks = [sIILOX, sIILH2]
        sII.shapes = [frustum(sII, D.station(D.sIIAftSkirt), D.station(D.sIITop), body, body, white)]
        // The J-2s start at PU null; the IU steps them to high and low EMR.
        cluster(sII, rating: D.sIIJ2Start, transients: D.sIIJ2Transients,
                gimbal: D.station(D.sIIJ2GimbalStation), exit: D.station(D.sIIJ2ExitStation),
                radius: D.sIIOutboardCircle / 2 * D.foot, exitArea: D.j2ExitArea, oxidizer: sIILOX, fuel: sIILH2,
                actuators: actuators(range: D.sIIJ2GimbalRange, rate: D.sIIJ2GimbalRate))

        // The aft interstage leaves with the S-II, with the S-IVB's aft frame
        // and detonation package; its four retros, not springs, separate them.
        let aftInterstage = part("S-II/S-IVB interstage", D.station(D.sIITop), D.station(D.sIVBAftSkirt),
                                 radius: body, dryMass: D.sIISIVBInterstageDry + D.sIVBAftFrame,
                                 dryCenterOfMass: D.station(D.sIISIVBInterstageCoMStation),
                                 dragCoefficient: D.bodyDragCoefficient, staging: .event(4))
        aftInterstage.shapes = [frustum(aftInterstage, D.station(D.sIITop), D.station(D.sIVBAftSkirt), body, upper,
                                        white)]
        sII.separationSpeed = 0
        aftInterstage.separationSpeed = 0
        solids("S-II retro", on: aftInterstage, at: diagonals, x: D.station(D.sIIRetroStation), radius: body,
               thrust: D.sIIRetroThrust * D.poundForce, burn: D.sIIRetroBurnTime, propellant: D.sIIRetroPropellant,
               cant: D.sIIRetroCant, forward: false, trigger: .ownSeparation, start: D.sIIRetroStart)

        // S-IVB: one J-2, inside the aft interstage until the S-II leaves. The
        // APS propellant, booked in `sIVBOther`, moves to the APS tanks; the
        // ullage motors (grains and cases) and the aft frame move to their
        // own parts.
        let sIVB = part("S-IVB", D.station(D.sIVBAftSkirt), D.station(D.sIVBTop), radius: upper,
                        dryMass: (D.sIVBDry + D.sIVBOther - 2 * (D.apsOxidizerLoad + D.apsFuelLoad)) * lb
                            - D.sIVBUllageMotorPropellant - D.sIVBUllageMotorCases - D.sIVBAftFrame,
                        dryCenterOfMass: D.station(D.sIVBDryCoMStation), staging: .fixed)
        let sIVBLOX = tank("S-IVB LOX", in: sIVB, load: D.sIVBLOXLoad * lb, unusable: D.sIVBLOXUnusable * lb,
                           extent: D.sIVBLOXExtent, density: D.loxDensity)
        let sIVBLH2 = tank("S-IVB LH2", in: sIVB, load: D.sIVBLH2Load * lb, unusable: D.sIVBLH2Unusable * lb,
                           extent: D.sIVBLH2Extent, density: D.lh2Density)
        sIVB.tanks = [sIVBLOX, sIVBLH2]
        let j2ExitRadius = (D.j2ExitArea / Double.pi).squareRoot()
        let j2 = Thruster(name: "S-IVB engine", position: local(sIVB, D.station(D.sIVBJ2GimbalStation)),
                          direction: .unitX, rating: D.sIVBJ2Burn1,
                          feed: .bipropellant(oxidizer: sIVBLOX, fuel: sIVBLH2), groups: [.main],
                          throttleRange: 1...1,
                          gimbal: actuators(range: D.sIVBJ2GimbalRange, rate: D.sIVBJ2GimbalRate))
        j2.transients = D.sIVBJ2Transients
        sIVB.thrusters.append(j2)
        sIVB.shapes = [frustum(sIVB, D.station(D.sIVBAftSkirt), D.station(D.sIVBTop), upper, upper, white),
                       frustum(sIVB, D.station(D.sIVBJ2ExitStation), D.station(D.sIVBJ2GimbalStation), j2ExitRadius,
                               0.3 * j2ExitRadius, dark)]
        // APS groups follow the sign of each engine's torque about a point on
        // the axis 8 m ahead of the modules, near the CoM of the S-IVB stack
        // (h 80.9 at ignition, 82.0 at insertion).
        for (module, side) in [("I", 1.0), ("III", -1.0)] {
            addAPSModule(to: sIVB, name: "APS \(module)",
                         at: local(sIVB, D.height(D.apsModuleHeight), 0, side * D.apsModuleRadius),
                         controlPoint: local(sIVB, D.height(D.apsModuleHeight) + 8))
        }

        // The S-IVB ullage motors' cases and fairings on the aft skirt, a part
        // of their own so the IU can jettison them; lit by the IU 0.1 s
        // before the S-II separates, or by that separation.
        let ullageHeight = D.height(D.sIVBUllageMotorHeight)
        let ullageRockets = part("S-IVB ullage rockets", ullageHeight - 0.75, ullageHeight + 0.75, radius: upper,
                                 dryMass: D.sIVBUllageMotorCases, staging: .event(5))
        solids("S-IVB ullage", on: ullageRockets, at: [diagonals[1], diagonals[3]], x: ullageHeight,
               radius: D.sIVBUllageMotorRadius,
               thrust: D.sIVBUllageMotorThrust * D.poundForce, burn: D.sIVBUllageMotorBurnTime,
               propellant: D.sIVBUllageMotorPropellant, cant: D.sIVBUllageMotorCant, forward: true,
               trigger: .event(4))

        let iu = part("IU", D.station(D.sIVBTop), D.station(D.iuTop), radius: upper, dryMass: D.iu * lb,
                      dryCenterOfMass: D.station(D.iuCoMStation), staging: .fixed)
        iu.shapes = [frustum(iu, D.station(D.sIVBTop), D.station(D.iuTop), upper, upper, grey)]

        let sla = part("SLA", D.station(D.iuTop), D.apolloStation(D.slaTop), radius: upper, dryMass: D.sla,
                       staging: .fixed)
        sla.shapes = [frustum(sla, D.station(D.iuTop), D.apolloStation(D.slaTop), upper, csmRadius, white)]

        // Inside the SLA, so it has no shapes.
        let lm = part("LM", D.height(D.lmBottomHeight), D.height(D.lmTopHeight), radius: D.lmRadius,
                      dryMass: D.lm, staging: .fixed)

        // CSM as one part (M2 splits it). No CSM CG was found: the SM and CM
        // each sit at their own mid-station.
        let smMid = D.apolloStation((D.slaTop + D.smTop) / 2), cmMid = D.apolloStation((D.smTop + D.cmApex) / 2)
        let cm = D.cm * lb
        let csm = part("CSM", D.apolloStation(D.slaTop), D.apolloStation(D.cmApex), radius: csmRadius,
                       dryMass: D.csm,
                       dryCenterOfMass: ((D.csm - cm) * smMid + cm * cmMid) / D.csm, staging: .fixed)
        csm.shapes = [frustum(csm, D.apolloStation(D.slaTop), D.apolloStation(D.smTop), csmRadius, csmRadius,
                              (0.7, 0.72, 0.75)),
                      frustum(csm, D.apolloStation(D.smTop), D.apolloStation(D.cmApex), csmRadius,
                              D.cmApexDiameter / 2, (0.8, 0.8, 0.8))]

        // LES with the boost protective cover; tower, motor and nose are crude.
        // Its tower-jettison motor, not a spring, throws it clear: the thrust
        // leans towards Position III (-z) and crosses the axis ahead of the
        // CG, pitching the tower over.
        let lesTop = D.station(D.baseStation) + D.overallHeight * D.foot
        let lesBottom = lesTop - D.lesLength * D.foot
        // The CG and inertia are the whole LES's: its dry part's are what is
        // left without the grain, which sits ahead of the CG.
        let grain = D.towerJettisonPropellant, lesDry = D.les - grain
        let grainLead = (D.towerJettisonGrainPoint - D.lesCenterOfMass) * D.inch
        let dryLag = grain * grainLead / lesDry
        let lesDryPitch = D.lesInertia.pitch - lesDry * dryLag * dryLag - grain * grainLead * grainLead
        let les = part("LES", lesBottom, lesTop, radius: D.lesRadius, dryMass: lesDry,
                       dryCenterOfMass: D.apolloStation(D.lesCenterOfMass) - dryLag, staging: .event(3))
        les.dryInertia = .diagonal(Vec3(D.lesInertia.roll, lesDryPitch, lesDryPitch))
        les.separationSpeed = 0
        let tjmGrain = PropellantTank(name: "Tower jettison", capacity: grain,
                                      geometry: .point(local(les, D.apolloStation(D.towerJettisonGrainPoint))))
        les.tanks = [tjmGrain]
        let tjmThrust = D.towerJettisonThrust * D.poundForce, tilt = D.towerJettisonTilt * D.degree
        let tjm = Thruster(name: "Tower jettison motor",
                           position: local(les, D.apolloStation(D.towerJettisonThrustPoint)),
                           direction: Vec3(cos(tilt), 0, -sin(tilt)),
                           rating: EngineRating(name: "Tower jettison", thrustVacuum: tjmThrust,
                                                ispVacuum: tjmThrust * D.towerJettisonBurnTime
                                                    / (D.towerJettisonPropellant * standardGravity)),
                           feed: .single(tjmGrain), groups: [])
        tjm.isSolid = true
        tjm.trigger = .ownSeparation
        tjm.transients = D.towerJettisonStart
        les.thrusters = [tjm]
        les.shapes = [frustum(les, lesBottom, lesBottom + 3.5, 0.66, 0.33, grey),
                      frustum(les, lesBottom + 3.5, lesTop - 1, 0.33, 0.33, white),
                      frustum(les, lesTop - 1, lesTop, 0.33, 0.05, white)]

        let stack = Vessel(name: name, parts: [sIC, interstage, sII, aftInterstage, sIVB, ullageRockets, iu, sla, lm,
                                               csm, les],
                           reference: placeholderBody)
        // The IU's APS switching logic flies the APS in every mode but kill rotation.
        stack.phasePlane = D.apsLaw
        stack.aerodynamics = D.aerodynamics
        return stack
    }

    /// One S-IVB APS module at `p` (part frame, off the axis): a pitch engine
    /// firing radially inwards, two tangential roll/yaw engines and an ullage
    /// engine along +x, all fed from the module's own N2O4 and MMH point tanks
    /// (appended to the part). The attitude engines' groups follow the sign of
    /// their torque about `controlPoint`. Every APS engine is
    /// `activeStageOnly`: the APS was inactive during S-IC and S-II flight, so
    /// it responds from S-II separation, when the S-IVB becomes the active
    /// stage. Until the J-2 lights it flies all three axes, pitch engines
    /// included, where datasheet §7.3 lists roll only (and that roll from
    /// separation is itself assumed, L); then roll only during the burn. Low
    /// confidence: the IU item may gate it on its own discrete.
    static func addAPSModule(to part: VesselPart, name: String, at p: Vec3, controlPoint c: Vec3) {
        typealias D = AS506
        let lb = D.pound, lbf = D.poundForce
        let ox = PropellantTank(name: "\(name) N2O4", capacity: D.apsOxidizerLoad * lb, geometry: .point(p))
        let fuel = PropellantTank(name: "\(name) MMH", capacity: D.apsFuelLoad * lb, geometry: .point(p))
        part.tanks += [ox, fuel]
        let n = Vec3(0, p.y, p.z).normalized, tangent = Vec3.unitX.cross(n)
        let attitude = EngineRating(name: "APS attitude", thrustVacuum: D.apsAttitudeThrust * lbf,
                                    ispVacuum: D.apsAttitudeIsp, mixtureRatio: D.apsMixtureRatio)
        let ullage = EngineRating(name: "APS ullage", thrustVacuum: D.apsUllageThrust * lbf,
                                  ispVacuum: D.apsUllageIsp, mixtureRatio: D.apsMixtureRatio)
        func add(_ label: String, _ direction: Vec3, _ rating: EngineRating, _ groups: Set<ThrusterGroup>? = nil) {
            let torque = (p - c).cross(direction), tiny = 1e-6 * torque.length
            var derived: Set<ThrusterGroup> = []
            if torque.x > tiny { derived.insert(.rollRight) } else if torque.x < -tiny { derived.insert(.rollLeft) }
            if torque.y > tiny { derived.insert(.pitchUp) } else if torque.y < -tiny { derived.insert(.pitchDown) }
            if torque.z > tiny { derived.insert(.yawRight) } else if torque.z < -tiny { derived.insert(.yawLeft) }
            let t = Thruster(name: "\(name) \(label)", position: p, direction: direction, rating: rating,
                             feed: .bipropellant(oxidizer: ox, fuel: fuel), groups: groups ?? derived)
            t.activeStageOnly = true
            part.thrusters.append(t)
        }
        add("pitch", -n, attitude)
        add("roll/yaw +t", tangent, attitude)
        add("roll/yaw -t", -tangent, attitude)
        // The U key for now; the restart ullage burns come with M2.
        add("ullage", .unitX, ullage, [.translateForward])
    }
}
