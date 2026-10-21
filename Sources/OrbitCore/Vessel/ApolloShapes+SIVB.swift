import Foundation

// The S-II/S-IVB interstage, the S-IVB, its ullage rockets and the IU
// (track VG2).
//
// Values as in ApolloShapes+SII.swift: the exterior datasheet's (§5-§7),
// with its source keys and grades, and "scaled" ones read for this track
// off MSFC-MAN-503 (M503) Figs. 6-1, 6-14 and 7-4 and TM X-53770 (TMX) Fig.
// 2, all drawn facing Position II (L unless marked).

extension ApolloShapeData {
    // MARK: S-II/S-IVB interstage

    /// Facets round the 260 in S-IVB and IU (0.16 m each), and round the
    /// interstage's cone between them.
    static let upperSegments = 128
    static let interstageSegments = 160

    /// Four S-II retros in the interstage's aft end, between STA 2519 and
    /// 2633: 9 in cases, 104.68 in overall, their axes 3° out from the
    /// centreline, nozzles forward under a jettisonable cap at the fixed
    /// fairing's forward end. On the fin diagonals, where the physics has
    /// them (`AS506`): VD2 found the white fairing on fin A's (503-064, M).
    /// Each motor sits so that its fairing leaves the cone where VD2
    /// measured the fairing's foot, 16 in across (VD2's 5.4°), and the
    /// fairing, cap and all, ends at VD2's measured top: the motor's
    /// forward end just under it (the motor's aft end then at STA 2519.5,
    /// within the interstage), the cap over the nozzle filling the rest.
    /// The axis 14 in over the fairing's flat and the forward end are
    /// estimates within the sourced span. The nozzle's exit is the exhaust
    /// spec's (`ApolloExhaust.sIIRetro`): 8.15 in, 0.9 of the case at which
    /// CEA delivers the motor's 34,810 lbf at its 1,761 psia (P1, L), which
    /// replaced a 7 in placeholder so that drawing and plume share it.
    static let sIIRetroCaseDiameter = 9.0            // in, M503 p. 5-26 (H)
    static let sIIRetroLength = 104.68               // in overall, M503 p. 5-26 (H)
    static let sIIRetroTilt = 3.0                    // deg, M503 p. 5-26 (H)
    static let sIIRetroForwardEnd = 2_624.0          // STA, within 2519-2633 and under VD2's top (M)
    static let sIIRetroFairingFoot = 2_582.7         // STA, VD2 503-064 (M)
    static let sIIRetroFairingTop = 2_626.2          // STA, VD2 503-064 (M)
    static let sIIRetroFairingWidth = 16.0           // in, VD2 503-064 (M)
    static let sIIRetroFairingRise = 14.0            // in, estimate (L)
    static let sIIRetroExitDiameter = ApolloExhaust.sIIRetroExitDiameter   // in, the exhaust spec's (L)
    static let sIIRetroNozzleLength = 5.0            // in, estimate (L)

    // MARK: S-IVB

    /// The skin: the aft skirt, the tank's wall and the forward skirt, at
    /// the stage's 260 in.
    static let sIVBAftSkirtTop = 2_832.0             // STA (S-IVB 286.15), BCD (H)
    static let sIVBForwardSkirtBottom = 3_100.56     // STA (S-IVB 554.70), BCD (H)
    /// The propellant tank's hemispherical domes, R 130 in, drawn 1 in
    /// inside the skin: the LOX tank's aft dome hangs below the aft skirt to
    /// STA 2702, the LH2 tank's forward dome stands inside the IU to
    /// 3230.56 (`docs/AS506-datasheet.md` §13, M).
    static let sIVBDomeHeight = 130.0                // in, TN D-3968 (M)
    static let sIVBAftDomeBottom = 2_702.0           // STA (M)
    static let sIVBForwardDomeTop = 3_230.56         // STA (M)
    /// The thrust structure, an inverted cone 5.2 ft tall from the engine
    /// mount to the aft dome, whose large end meets the dome 40 in from the
    /// axis (derived, M); the mount's radius is today's estimate (L). Eight
    /// ambient helium spheres round it (M503 p. 6-1, H), their size and
    /// places estimates (L).
    static let sIVBThrustStructureHeight = 62.4      // in, M503 Fig. 6-1 (H)
    static let sIVBEngineMountRadius = 15.6          // in, estimate (L)
    static let sIVBHeliumSpheres = (count: 8, diameter: 20.0)   // M503 p. 6-1 (H); in, estimate (L)
    /// The APS modules at Positions I and III (M503 p. 6-20, H): long
    /// fairings with a rounded nose, the three attitude engines low down and
    /// the ullage engine at the foot (M503 Fig. 6-14, H as form). Scaled off
    /// TMX Fig. 2's silhouette: from the aft skirt's foot to about STA 2828
    /// at 24 in deep, then a nose to the skin by about 2862. The width is an
    /// estimate from Fig. 6-14. The attitude engines' nozzles are at the
    /// physics' station (`AS506.apsModuleHeight`, L), their lengths an
    /// estimate; their exits are the exhaust specs' (`ApolloExhaust
    /// .apsAttitude`, `.apsUllage`: 6.43 in for the 147 lbf engines, 2.21
    /// in for the 72 lbf ullage engine, each the exit its thrust needs at
    /// 100 psia, P1, L), which replaced a 5 in placeholder for all four so
    /// that drawing and plume share them.
    static let sIVBAPSModuleBottom = 2_748.0         // STA, scaled (L)
    static let sIVBAPSModuleShoulder = 2_828.0       // STA, scaled (L)
    static let sIVBAPSModuleTop = 2_862.0            // STA, scaled (L)
    static let sIVBAPSModuleDepth = 24.0             // in off the skin, scaled (L)
    static let sIVBAPSModuleWidth = 40.0             // in, estimate (L)
    static let sIVBAPSNozzle = (exitDiameter: ApolloExhaust.apsAttitudeExitDiameter, length: 6.0)   // in (L)
    static let sIVBAPSUllageNozzle = (exitDiameter: ApolloExhaust.apsUllageExitDiameter, length: 6.0)   // in (L)
    /// The two TX-280 ullage motors' fairings, diametrically opposite on
    /// the aft skirt, 15-20° off the fin B and D diagonals towards Positions
    /// II and IV (D5 Fig. 5-7, M; TMX Fig. 2 draws one at about 117°), where
    /// the physics has the motors on the diagonals (`AS506`, L). Their size
    /// is scaled off TMX Fig. 2; each motor's nozzle stands out of its
    /// fairing's foot at the motor's radius, canted out as the physics has
    /// it (`AS506.sIVBUllageMotorCant`, M), and carries the motor's plume.
    /// Its exit is the exhaust spec's (`ApolloExhaust.sIVBUllage`): 6.22
    /// in, 0.9 of the inferred 7 in case at which CEA delivers the motor's
    /// 3,390 lbf at 980 psia (P1, L), which replaced a 5 in placeholder so
    /// that drawing and plume share it; its length is an estimate.
    static let sIVBUllageFairingOffset = 17.5        // deg from the fin line towards the Position (M)
    static let sIVBUllageFairingBottom = 2_748.0     // STA, scaled (L)
    static let sIVBUllageFairingTop = 2_808.0        // STA, scaled (L)
    static let sIVBUllageFairingTaper = 38.0         // in, scaled (L)
    static let sIVBUllageFairingWidth = 18.0         // in, scaled (L)
    static let sIVBUllageFairingDepth = 10.5         // in, estimate (L)
    static let sIVBUllageNozzle = (exitDiameter: ApolloExhaust.sIVBUllageExitDiameter, length: 5.0)   // in (L)
    /// Two tunnels, fairings over the wiring and pressurisation lines (M503
    /// p. 6-1, H as form): a long systems tunnel and a short helium tunnel
    /// on the face between the APS modules, on the side towards Position II
    /// where the umbilicals are. Extents, azimuths and width scaled off TMX
    /// Fig. 2, semicircular, the ends tapering (L).
    static let sIVBSystemsTunnel = (from: 2_783.0, to: 3_152.0, azimuth: 100.0)   // STA, deg, scaled (L)
    static let sIVBHeliumTunnel = (from: 2_984.0, to: 3_094.0, azimuth: 74.0)     // STA, deg, scaled (L)
    static let sIVBTunnelWidth = 18.0                // in, scaled (L)
    static let sIVBTunnelTaper = 9.0                 // in, estimate (L)
    /// Two telemetry antennas, folded-sleeve dipoles on the forward skirt,
    /// 180° apart: at θ 79° and 259° as the datasheet reads M503 p. 6-30
    /// (M), their centreline at BCD's station (H), as rods of an estimated
    /// size (L).
    static let sIVBTelemetryAntennaStation = 3_193.56          // STA, BCD (H)
    static let sIVBTelemetryAntennaAzimuths = [79.0, 259.0]    // deg (M)
    static let sIVBTelemetryAntenna = (diameter: 1.5, length: 12.0)   // in, estimate (L)

    // MARK: IU

    /// The IU's doors and antennas. Their azimuths are scaled off M503 Fig.
    /// 7-4 sheet 1 (M: a schematic drawn facing Position II, which puts them
    /// where the datasheet's §7 says), their stations and sizes scaled off
    /// it or estimated (L). On the access-door segment, between Positions I
    /// and II near II: the umbilical door and the equipment and personnel
    /// access door, raised 1/2 in. The antennas, as boxes: VHF telemetry
    /// near II and IV; CCS PCM omni transmit, C-band and CCS omni receive in
    /// two groups 180° apart, past II towards III and past IV towards I; the
    /// UHF telemetry and CCS/PCM directional antennas at Position I.
    static let iuDoors: [(azimuth: Double, wide: Double, tall: Double)] = [
        (60, 20, 24),                                // umbilical door
        (74, 32, 33),                                // access door
    ]
    static let iuDoorProud = 0.5                     // in, estimate (L)
    static let iuAntennas: [(azimuth: Double, station: Double, tall: Double, wide: Double, proud: Double)] = [
        (96, 3_240.56, 18, 6, 3), (276, 3_240.56, 18, 6, 3),   // VHF telemetry
        (111, 3_240.56, 12, 6, 3), (291, 3_240.56, 12, 6, 3),  // CCS PCM omni transmit
        (128, 3_232.0, 10, 10, 4), (308, 3_232.0, 10, 10, 4),  // C-band
        (128, 3_250.0, 9, 4, 3), (308, 3_250.0, 9, 4, 3),      // CCS omni receive
        (0, 3_250.0, 12, 6, 3),                                // UHF telemetry
        (0, 3_232.0, 12, 10, 4),                               // CCS/PCM directional
    ]
}

extension ApolloDresser {
    func sIVBShapes() -> [VisualShape]? {
        switch part.name {
        case "S-II/S-IVB interstage":
            return sIISIVBInterstage()
        case "S-IVB":
            return sIVBStructure() + apsModules() + j2Engines(exit: D.station(D.sIVBJ2ExitStation))
        case "S-IVB ullage rockets":
            return sIVBUllageRockets().shapes
        case "IU":
            return instrumentUnit()
        default:
            return nil
        }
    }

    /// The S-II retros' ports and the S-II/S-IVB plane (STA 2746.5) on the
    /// interstage that leaves with the S-II; the S-IVB's ullage motors'
    /// exits. The ports are at the nozzles' exits.
    func sIVBAttachments() -> [VisualAttachment] {
        switch part.name {
        case "S-II/S-IVB interstage":
            return sIIRetros().ports
                + [separationPlane("S-II/S-IVB separation plane", at: D.station(D.sIVBAftSkirt),
                                   radius: ApolloDresser.upper, up: true)]
        case "S-IVB ullage rockets":
            return sIVBUllageRockets().ports
        default:
            return []
        }
    }

    // MARK: S-II/S-IVB interstage

    /// The cone, open, with the retros' fairings.
    func sIISIVBInterstage() -> [VisualShape] {
        typealias A = ApolloDresser
        var cone = revolution([P(D.station(D.sIITop), A.body), P(D.station(D.sIVBAftSkirt), A.upper)], at: .zero,
                              segments: S.interstageSegments, A.white)
        upperStageOpen(&cone)
        return [cone] + sIIRetros().shapes
    }

    /// Each S-II retro's fixed fairing with its nozzle cap: a prism along
    /// the motor's axis, tilted 3° out, from inside the cone to VD2's top
    /// just past the nozzle, a half-round over the motor on straight sides
    /// down to a flat below the cone. Its port is the nozzle's exit at the
    /// motor's forward end, the exhaust leaving against the motor's thrust;
    /// the nozzle, inside the fairing under the cap, is linked to the motor
    /// so that its plume starts there (`VesselGeometry`), not at the
    /// physics' thrust point. The fairings stand on the motors' diagonals,
    /// or on fins A-D without motors.
    func sIIRetros() -> (shapes: [VisualShape], ports: [VisualAttachment]) {
        typealias A = ApolloDresser
        let inch = D.inch, tilt = S.sIIRetroTilt * D.degree
        let motors = part.thrusters.filter { $0.isSolid && $0.name.contains("retro") }
        let outs: [Vec3] = motors.isEmpty
            ? [45.0, 135.0, 225.0, 315.0].map { theta in let d = skinDirection(theta); return Vec3(0, d.y, d.z) }
            : motors.map { t in let c = t.position + construction; return Vec3(0, c.y, c.z).normalized }
        let aft = D.station(D.sIITop)
        let slope = (A.body - A.upper) / (D.station(D.sIVBAftSkirt) - aft)
        let half = S.sIIRetroFairingWidth / 2 * inch, rise = S.sIIRetroFairingRise * inch
        let foot = D.station(S.sIIRetroFairingFoot), forward = D.station(S.sIIRetroForwardEnd)
        let start = foot - 12 * inch
        /// The motor's axis's distance from the vehicle's at construction x:
        /// the fairing's crown meets the cone at the foot.
        func axisRadius(_ x: Double) -> Double {
            let crown = A.body - (foot - aft) * slope
            return crown - half + (x - foot) * tan(tilt)
        }

        var section: [VisualShape.SectionPoint] = [.init(0, -half, crease: true), .init(0, half, crease: true)]
        for k in 0...8 {
            let a = Double.pi * Double(k) / 8
            section.append(.init(rise + half * sin(a), half * cos(a)))
        }
        // The flat's forward corners, the fairing's forward end, at VD2's
        // top: the flat stands `rise * sin(tilt)` forward of the axis.
        let exit = (forward - start) / cos(tilt)
        let cap = (D.station(S.sIIRetroFairingTop) - forward - rise * sin(tilt)) / cos(tilt)
        let stations: [VisualShape.PrismStation] = [
            .init(0), .init(exit - 4 * inch), .init(exit, width: 0.92, height: 0.92),
            .init(exit + 0.5 * cap, width: 0.75, height: 0.75), .init(exit + cap, width: 0.45, height: 0.45),
        ]

        var shapes: [VisualShape] = [], ports: [VisualAttachment] = []
        for (k, out) in outs.enumerated() {
            let along = Vec3.unitX * cos(tilt) + out * sin(tilt)
            let up = out * cos(tilt) - Vec3.unitX * sin(tilt)
            let flat = Vec3(start, 0, 0) + out * axisRadius(start) - up * rise
            var fairing = finished(.prism(section, from: local(flat), axis: along, reference: up, stations: stations,
                                          color: A.white.colour), A.white)
            fairing.surfaceFrame = .vehicle(partOrigin: construction)
            shapes.append(fairing)
            guard k < motors.count else { continue }
            let nozzle = Vec3(forward, 0, 0) + out * axisRadius(forward)
            var cone = upperStageNozzle(exit: nozzle, thrust: motors[k].direction,
                                        exitRadius: S.sIIRetroExitDiameter / 2 * inch,
                                        length: S.sIIRetroNozzleLength * inch)
            cone.thruster = motors[k].name
            shapes.append(cone)
            ports.append(VisualAttachment(name: motors[k].name, kind: .retroPort, position: local(nozzle),
                                          direction: -motors[k].direction,
                                          radius: S.sIIRetroExitDiameter / 2 * inch, thruster: motors[k].name))
        }
        return (shapes, ports)
    }

    // MARK: S-IVB

    /// The skin, open at both ends, with the domes seen through them, the
    /// thrust structure (open at the dome, closed by the engine mount) with
    /// its helium spheres, the tunnels and the forward skirt's antennas. The
    /// skin comes first.
    func sIVBStructure() -> [VisualShape] {
        typealias A = ApolloDresser
        let inch = D.inch, r = A.upper
        var skin = revolution([P(D.station(D.sIVBAftSkirt), r), P(D.station(S.sIVBAftSkirtTop), r),
                               P(D.station(S.sIVBForwardSkirtBottom), r), P(D.station(D.sIVBTop), r)],
                              at: .zero, segments: S.upperSegments, A.white)
        upperStageOpen(&skin)

        let dome = r - inch, height = S.sIVBDomeHeight * inch
        let equator = D.station(S.sIVBAftDomeBottom) + height
        let aftDome = revolution(upperStageDome(equator: equator, radius: dome, height: -height), at: .zero,
                                 segments: 96, A.grey)
        let forwardDome = revolution(upperStageDome(equator: D.station(S.sIVBForwardDomeTop) - height,
                                                    radius: dome, height: height),
                                     at: .zero, segments: 96, A.grey)

        let mount = D.station(D.sIVBJ2GimbalStation), large = mount + S.sIVBThrustStructureHeight * inch
        let u = (equator - large) / height, mountRadius = S.sIVBEngineMountRadius * inch
        let largeRadius = dome * (1 - u * u).squareRoot()
        var thrust = revolution([P(mount, mountRadius), P(large, largeRadius)], at: .zero, segments: 64, A.grey)
        upperStageOpen(&thrust)
        thrust.capBase = true   // the engine mount
        let sphere = S.sIVBHeliumSpheres.diameter / 2 * inch
        let ring = (mountRadius + largeRadius) / 2 + sphere + inch
        let spheres = (0..<S.sIVBHeliumSpheres.count).map { k -> VisualShape in
            let d = skinDirection(22.5 + 45 * Double(k))
            let centre = Vec3((mount + large) / 2, d.y * ring, d.z * ring)
            return finished(VisualShape(kind: .sphere(radius: sphere), origin: local(centre), axis: .unitX,
                                        length: 2 * sphere, color: A.grey.colour), A.grey)
        }

        let tunnels = [S.sIVBSystemsTunnel, S.sIVBHeliumTunnel].map { t in
            upperStageFairing(skinDirection(t.azimuth), skin: r, from: D.station(t.from), to: D.station(t.to),
                              width: S.sIVBTunnelWidth * inch, depth: S.sIVBTunnelWidth / 2 * inch,
                              taperBottom: S.sIVBTunnelTaper * inch, taperTop: S.sIVBTunnelTaper * inch, A.white)
        }
        let antennas = S.sIVBTelemetryAntennaAzimuths.map { theta -> VisualShape in
            let d = skinDirection(theta), radial = Vec3(0, d.y, d.z), rod = S.sIVBTelemetryAntenna
            let foot = Vec3(D.station(S.sIVBTelemetryAntennaStation), 0, 0) + radial * (r - 0.5 * inch)
            var s = finished(.frustum(from: local(foot), length: (rod.length + 0.5) * inch,
                                      baseRadius: rod.diameter / 2 * inch, topRadius: rod.diameter / 2 * inch,
                                      axis: radial, color: A.grey.colour), A.grey)
            s.surfaceFrame = .vehicle(partOrigin: construction)
            return s
        }
        return [skin, aftDome, forwardDome, thrust] + spheres + tunnels + antennas
    }

    /// The S-IVB's two APS modules on the aft skirt at Positions I and III,
    /// each a faired body with its nozzles: the pitch engine's in its face
    /// (it fires inwards), the two roll and yaw engines' in its sides, the
    /// ullage engine's in its foot (it fires forward), none linked to the
    /// thrusters (`VesselGeometry` takes a cone narrowing to a thruster as
    /// its nozzle).
    func apsModules() -> [VisualShape] {
        typealias A = ApolloDresser
        let inch = D.inch, r = A.upper
        let bottom = D.station(S.sIVBAPSModuleBottom), top = D.station(S.sIVBAPSModuleTop)
        let width = S.sIVBAPSModuleWidth * inch, depth = S.sIVBAPSModuleDepth * inch
        let engines = Vec3(D.height(D.apsModuleHeight), 0, 0)
        var shapes: [VisualShape] = []
        for side in [1.0, -1.0] {
            let out = Vec3(0, 0, side), across = Vec3.unitX.cross(out), mid = r + depth / 2
            shapes.append(upperStageFairing((y: 0, z: side), skin: r, from: bottom, to: top, width: width,
                                            depth: depth, taperTop: top - D.station(S.sIVBAPSModuleShoulder),
                                            roundTop: true, face: { t in pow(1 - pow(abs(t), 3), 1.0 / 3) },
                                            A.white))
            let attitude = S.sIVBAPSNozzle, ullage = S.sIVBAPSUllageNozzle
            let jets: [(exit: Vec3, thrust: Vec3, nozzle: (exitDiameter: Double, length: Double))] = [
                (engines + out * (r + depth + 0.5 * inch), -out, attitude),
                (engines + out * mid - across * (width / 2 + 0.5 * inch), across, attitude),
                (engines + out * mid + across * (width / 2 + 0.5 * inch), -across, attitude),
                (Vec3(bottom - 0.5 * inch, 0, 0) + out * mid, .unitX, ullage),
            ]
            for jet in jets {
                let nozzle = jet.nozzle
                shapes.append(upperStageNozzle(exit: jet.exit, thrust: jet.thrust,
                                               exitRadius: nozzle.exitDiameter / 2 * inch,
                                               length: nozzle.length * inch))
            }
        }
        return shapes
    }

    /// The two TX-280s' fairings and nozzles, `sIVBUllageFairingOffset`
    /// off the motors' fin diagonals (fins B and D without motors) towards
    /// Positions II and IV, and their exits, the exhaust aft and out. Each
    /// nozzle is linked to its motor, so that the motor's plume starts at
    /// the nozzle's exit, the port (`VesselGeometry`), not at the physics'
    /// thrust point on the fin line, 17.5° round on bare skin; the plume's
    /// axis stays the physics' exhaust, 10° off the nozzle's.
    func sIVBUllageRockets() -> (shapes: [VisualShape], ports: [VisualAttachment]) {
        typealias A = ApolloDresser
        let inch = D.inch, r = A.upper, cant = D.sIVBUllageMotorCant * D.degree, nozzle = S.sIVBUllageNozzle
        let motors = part.thrusters.filter { $0.isSolid && $0.name.contains("ullage") }
        let fins: [Double] = motors.isEmpty ? [135, 315] : motors.map { t in
            let c = t.position + construction
            return VisualShape.vehicleAzimuth(y: c.y, z: c.z) * 180 / Double.pi
        }
        let bottom = D.station(S.sIVBUllageFairingBottom), top = D.station(S.sIVBUllageFairingTop)
        var shapes: [VisualShape] = [], ports: [VisualAttachment] = []
        for (k, fin) in fins.enumerated() {
            let d = skinDirection(fin - S.sIVBUllageFairingOffset), out = Vec3(0, d.y, d.z)
            shapes.append(upperStageFairing(d, skin: r, from: bottom, to: top, width: S.sIVBUllageFairingWidth * inch,
                                            depth: S.sIVBUllageFairingDepth * inch,
                                            taperTop: S.sIVBUllageFairingTaper * inch, A.white))
            let thrust = Vec3.unitX * cos(cant) - out * sin(cant)
            let exit = Vec3(bottom, 0, 0) + out * D.sIVBUllageMotorRadius - thrust * (nozzle.length * inch)
            var cone = upperStageNozzle(exit: exit, thrust: thrust, exitRadius: nozzle.exitDiameter / 2 * inch,
                                        length: nozzle.length * inch)
            guard k < motors.count else {
                shapes.append(cone)
                continue
            }
            cone.thruster = motors[k].name
            shapes.append(cone)
            ports.append(VisualAttachment(name: motors[k].name, kind: .ullageExit, position: local(exit),
                                          direction: -thrust, radius: nozzle.exitDiameter / 2 * inch,
                                          thruster: motors[k].name))
        }
        return (shapes, ports)
    }

    /// A small engine's nozzle from its exit (construction), a cone up
    /// `length` (m) along the thrust from `exitRadius` (m) to a third of
    /// it, open at the exit.
    func upperStageNozzle(exit: Vec3, thrust: Vec3, exitRadius: Double, length: Double) -> VisualShape {
        var s = finished(.frustum(from: local(exit), length: length, baseRadius: exitRadius,
                                  topRadius: exitRadius / 3, axis: thrust, color: ApolloDresser.dark.colour),
                         ApolloDresser.dark, vehicleFrame: false)
        s.capBase = false
        s.twoSided = true
        return s
    }

    // MARK: IU

    /// The IU's ring, open, with its doors and antennas.
    func instrumentUnit() -> [VisualShape] {
        typealias A = ApolloDresser
        let inch = D.inch, r = A.upper
        let bottom = D.station(D.sIVBTop), top = D.station(D.iuTop), mid = (bottom + top) / 2
        var ring = revolution([P(bottom, r), P(top, r)], at: .zero, segments: S.upperSegments, A.white)
        upperStageOpen(&ring)
        let doors = S.iuDoors.map { door in
            upperStageFairing(skinDirection(door.azimuth), skin: r, from: mid - door.tall / 2 * inch,
                              to: mid + door.tall / 2 * inch, width: door.wide * inch, depth: S.iuDoorProud * inch,
                              face: { _ in 1 }, A.white)
        }
        let antennas = S.iuAntennas.map { a in
            upperStageBox(skinDirection(a.azimuth), skin: r, at: D.station(a.station), tall: a.tall * inch,
                          wide: a.wide * inch, proud: a.proud * inch, A.grey)
        }
        return [ring] + doors + antennas
    }
}
