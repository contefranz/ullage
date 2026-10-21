import Foundation

// The S-IC, the S-IC/S-II interstage and the F-1 in flight configuration
// (track VG1), from docs/SaturnV-CSM-exterior-datasheet.md §1-§3 and §8.1,
// whose source keys (BCD, M503, ALM, TMX, D5, R1) the grades cite. STA in
// inches; azimuths θ in degrees from Position I towards Position II, fins
// A-D at 45°, 135°, 225° and 315°.

extension ApolloShapeData {
    // MARK: S-IC skin (datasheet §2.1)
    //
    // Bands at BCD's joints from the base heat shield up. The interstage's
    // 23 in ring below the S-IC/S-II separation plane (STA 1541-1564)
    // leaves with the S-IC, so it is drawn on it.

    static let sICHeatShieldTop = 112.00             // STA, BCD (H)
    static let sICHeatShieldThickness = 1.00         // in, 15-7 PH honeycomb; M503 p. 4-3 (H)
    static let sICThrustStructure = 116.00           // STA, its skin's foot; BCD (H)
    static let sICFuelTank = 345.70                  // STA, BCD (H)
    static let sICIntertank = 628.80                 // STA, BCD (H)
    static let sICLOXTank = 885.20                   // STA, BCD (H)
    static let sICForwardSkirt = 1_420.30            // STA, BCD (H)
    /// The LOX tank's forward dome, seen in the forward skirt once the
    /// stages part: from its Y-ring to its vent, half an ellipse (L).
    static let sICLOXDomeBase = 1_404.00             // STA, BCD (H)
    static let sICLOXVent = 1_521.00                 // STA, BCD (H)
    /// Facets per turn of the 33 ft skin: 1.2 mm deep.
    static let sICSkinSegments = 144
    /// What is left of a ramp's section where it meets the skin: a sliver,
    /// capped, rather than a line, which would leave the prism open.
    static let sICRampEnd = 0.02
    /// How far (in) the prisms standing on a skin (scoops, tunnels, vent,
    /// ullage and ordnance fairings) sink their feet below it, along its
    /// arc: deeper than the 144-gon's facets fall inside its circle (0.047
    /// in), so no gap shows under a flank, and shallower than the
    /// interstage's 0.071 in wall, so no foot shows inside it.
    static let sICPrismSink = 0.055

    // MARK: Engine fairings (§2.3: ALM 1.9201)
    //
    // A 15° half-cone over each outboard F-1, on the fin diagonals, its axis
    // parallel to the vehicle's: in section a semicircle facing out, with
    // straight flanks dropping to the skin. Open round the engine at its aft
    // end, it hangs below the heat shield; forward it meets the skin. The
    // ALM sheets' lengths are in calibers of 396 in, taken as printed: with
    // them the cone meets the skin at STA 362.11, the sheet's 362.096.

    static let almCaliber = 396.0                    // in, the reference diameter
    static let sICFairingAft = 48.50                 // STA (H)
    static let sICFairingForward = 362.096           // STA (H)
    static let sICFairingAxis = 0.4596 * almCaliber  // in from the vehicle's axis: 0.5 - 0.0404 cal, 182.0 in (H)
    static let sICFairingAftRadius = 0.2526 * almCaliber // in: 100.0 (H)
    static let sICFairingHalfAngle = 15.0            // deg (H)
    static let sICFairingFlankThickness = 0.5        // in, estimate (L)
    /// Air scoops: ALM 1.9201 draws two on the flank facing the viewer, one
    /// above the other, at about STA 85-92 (M for their existence, L for
    /// the place, scaled off an undimensioned detail). Two on each side of
    /// the fin; their azimuths about the fairing's axis, size and forward
    /// opening are estimates (L).
    static let sICScoopStations = 84.5...92.5        // STA (L)
    static let sICScoopAzimuths = [40.0, 75.0]       // deg either side of the fin (L)
    static let sICScoopWidth = 6.0                   // in (L)
    static let sICScoopHeight = 3.0                  // in (L)

    // MARK: Fins (§2.4: ALM 1.9101)
    //
    // On the fairing's outer generatrix: a 55 in tip chord from STA 81.277
    // to 136.277, the root's leading edge at STA 216.687, 103.0 in of span
    // at the straight trailing edge and a 30° swept leading edge: 75.0 ft².
    // In section a 10° wedge (the ramp) faired into a flat aft 34.7 in,
    // whose faces taper spanwise (2°53′) from 14.4 in thick at the root's
    // trailing edge (15.4 in at the ramp's end) to 4.0 in at the tip.

    static let sICFinTrailingEdge = 81.277           // STA (H)
    static let sICFinTipChord = 55.0                 // in: STA 81.277 to 136.277 (H)
    static let sICFinRootLeadingEdge = 216.687       // STA (H)
    static let sICFinSpan = 0.2601 * almCaliber      // in at the trailing edge: 103.0 (H)
    static let sICFinFlatChord = 0.0877 * almCaliber // in: 34.7 (H)
    static let sICFinRootThickness = 0.0364 * almCaliber // in at the trailing edge: 14.4 (H)
    static let sICFinTipThickness = 0.0101 * almCaliber // in: 4.0 (H)
    /// How far (in) inside the fairing's generatrix the flat section's root
    /// runs: more than the cone falls away under the fin's faces (0.36 in
    /// at the ramp's end), so the root leaves no slit, and no more, since
    /// below the lunate panel the fairing is open round the engine.
    static let sICFinRootSink = 0.5

    // MARK: Retros, hold-downs, tunnels, vents, curtains (§2.5-§2.7)

    /// The TE-M-424 retros: 86 in long and 15.25 in across, in pairs in the
    /// fairings (`AS506`'s motors). There is no port: the exhaust breaks out
    /// through the fairing's skin, where the ports are drawn, the size of
    /// the case (L).
    static let sICRetroLength = 86.0                 // in, M503 p. 4-27 (H)
    static let sICRetroDiameter = 15.25              // in, M503 p. 4-27 (H)
    /// The hold-down post fittings at Positions I-IV, bearing at STA 113.31
    /// on the lower thrust ring (M503 Fig. 8-7, H); their size is an
    /// estimate (L), half of their depth proud of the skin.
    static let sICHoldDown = 113.31                  // STA (H)
    static let sICHoldDownSize = (length: 24.0, width: 20.0, depth: 12.0)   // in (L)
    /// The cable tunnel just off Position I towards fin A and the
    /// pressurization tunnel just off Position III towards fin C (D5 Fig.
    /// 6-5, M), 8° off here, clear of the Position plates at ±3° (L). From a
    /// rounded aft end on the thrust structure (TMX, L) to a ramp ending at
    /// STA 1515 (TMX, L) and 1519 (D5, M); semicircular, 15 in proud (TMX
    /// draws 13-20 in, L).
    static let sICTunnels: [(azimuth: Double, forward: Double)] = [(8, 1_515), (188, 1_519)]
    static let sICTunnelAft = 205.0                  // STA, scaled (L)
    static let sICTunnelRadius = 15.0                // in (L)
    static let sICTunnelRamp = 24.0                  // in (L)
    /// The LOX tank's vent valves exhaust through the forward skirt (M503 p.
    /// 4-1); the outlets' number and form were not found: two fairings, one
    /// per valve, opposite so their thrusts cancel, at Positions II and IV,
    /// open aft (L).
    static let sICLOXVents = [90.0, 270.0]           // deg (L)
    static let sICLOXVentFairing = (bottom: 1_500.0, top: 1_536.0, radius: 6.0)   // STA, in (L)
    /// Each F-1's flexible curtain closes the gap from its interface panel
    /// to the heat shield (NR p. 3-7, M); not dimensioned: a skirt round the
    /// engine's upper block from 4 in below its gimbal to the shield (L).
    /// At its foot it clears the turbopump (74 in from the engine's axis,
    /// within R1's 75.75 in) by 3 in and the inlet block (72 in) by more,
    /// room for the engine's gimballing that near the gimbal plane; at the
    /// shield it stays inside the outboard fairing's cone (83.25 in there).
    static let sICCurtain = (bottom: 96.0, bottomRadius: 77.0, topRadius: 81.0)   // STA, in (L)

    // MARK: F-1 in flight configuration (§8.1: R1 Fig. 2-22 unless noted)
    //
    // Distances along the engine from its gimbal, + aft (in). The tube-wall
    // chamber runs to 10:1 at the turbine exhaust manifold, the extension
    // cooled by the turbine exhaust on to 16:1. As flown the engine is
    // wrapped in its insulation (D5 §4): outside it is the cocoon, not tubes.

    /// 10:1 at the extension's joint, 16:1 at its exit (R1 §1-4; M504 p. 4-4).
    static let f1AreaRatio = 16.0                    // (H)
    static let f1JointAreaRatio = 10.0               // (H)
    static let f1ThroatArea = 961.4                  // in², R1 Fig. 3-13 (H)
    static let f1Exit = 215.50                       // in (H)
    static let f1ExitOuterDiameter = 147.00          // in (H)
    static let f1Joint = 150.00                      // in, the manifold's aft face (H)
    static let f1JointOuterDiameter = 125.00         // in (H)
    static let f1Throat = 65.5                       // in, scaled off TMX1470 Fig. 2: 64-67 (L)
    /// The injector's face; the 30° convergent and a chamber of 1.3 throat
    /// radii as `bell`'s (L).
    static let f1InjectorFace = 30.0                 // in (L)
    /// The manifold: a torus whose section tapers from about 27 in at its
    /// inlet to 14 in (R1's envelope radii, M), drawn at their mean all
    /// round, its outside on the exit's envelope (L). A round 27 in inlet
    /// would not fit between the chamber and that envelope: the real one is
    /// taller than it is wide.
    static let f1ManifoldSection = 20.5              // in (M)
    /// The upper block's envelope: from 14.50 in ahead of the gimbal (the
    /// turbopump inlet block's face; the main block's at 3.50 in) to 62.50
    /// in aft, 51.62 in either side.
    static let f1InletFace = -14.50                  // in (H)
    static let f1BlockFace = -3.50                   // in (H)
    /// The inlet block: an obround, 15.75 in end radii on centres 51.75 in
    /// apart, its centre line 50.00 in out on the turbopump side (H).
    static let f1InletEndRadius = 15.75              // in (H)
    static let f1InletCentres = 51.75                // in (H)
    static let f1TurbopumpAxis = 50.0                // in from the engine's axis (M, from the inlet block)
    /// The Mk-10 turbopump below its inlets, 5 ft long, 4 ft across (R1 Fig. 1-16).
    static let f1TurbopumpDiameter = 48.0            // in (H)
    static let f1TurbopumpLength = 60.0              // in (H)
    /// The heat exchanger in the turbine exhaust duct, 40 in across at the
    /// turbine's outlet and 24 in at the manifold (R1 §1-72, H), from the
    /// turbopump down to the manifold's inlet (L).
    static let f1HeatExchanger = (turbine: 40.0, manifold: 24.0)   // in (H)
    /// The gas generator, 18 × 24 × 28 in (R1 §1-64, H), on the No. 1 side
    /// against the cocoon, 20 in aft of the gimbal at its top (L).
    static let f1GasGenerator = (across: 18.0, along: 24.0, length: 28.0, top: 20.0)   // in (H; top L)
    /// The cocoon: 30 in round the chamber below the upper block (section
    /// A-A, H) and 4 in outside the gas side lower down (L: tubes, bands and
    /// batts; the insulation's thickness as flown was not found), from the
    /// gimbal's boot (L) down into the manifold.
    static let f1CocoonRadius = 30.0                 // in (H)
    static let f1CocoonOffset = 4.0                  // in (L)
    static let f1GimbalBoot = 9.0                    // in (L)
    // The turbopumps' clocking in the cluster was not found: the outboard
    // ones face out into the fairings, the centre one Position I (L).

    // MARK: S-IC/S-II interstage (§3)

    static let sICSIISkin = 0.071                    // in, M503 p. 5-1 (H)
    /// The white separation ridges at STA 1564 and 1760, 4 in wide (VD2
    /// 506-040/041, M), 1 in proud (L).
    static let sICSIIRidge = (width: 4.0, height: 1.0)   // in (M; L)
    /// The S-II ullage motors (89 × 12.5 in, M503 p. 5-24, H), each in a
    /// fairing from STA 1563.56 (BCD, H) to a pointed top at STA 1710.68
    /// (M), 24 in wide (VD2's 7° white strips, M) and 22 in proud, room for
    /// the motor at the physics' radius and its canted nozzle (L), centred
    /// 4.0° anticlockwise of each fin line (M). The physics' motors stay at
    /// Positions I-IV (`AS506`, L): the fairings, and the exits drawn at
    /// their feet, are where the photos put them, and each exit is linked
    /// to a motor by name, motor n to fin n's fairing.
    ///
    /// Azimuth. S68-49405 looks at Position I square on (camera at θ 6.6°)
    /// and shows no fairing there, but white strips just anticlockwise of
    /// fins D and A; S68-55424 shows fin B's (VD2's rows 503-050, 051 and
    /// 053, M; docs/data/markings/digitised). A fairing's relief shifts the
    /// edges it shows away from the camera, all but the root of its flank
    /// on the camera's side: 45.4° on A, 321.9° on D and 142.8° on B, which
    /// put a 24 in fairing's centre 3.9°, 3.4° and 4.3° past its fin. That
    /// is the rows' 45.5-52.5° etc. (4.0°); Oikofuge's 16 in (4.6°,
    /// secondary) is within the photos' spread, and M503 Fig. 5-2's Positions
    /// I-IV (the datasheet's §3, M) are a schematic's.
    ///
    /// Top. BCD prints "176.68 / 3.725" (XB, in and m), which disagree.
    /// BCD truncates its metre values (284.00 → 7.213, 112.00 → 2.844,
    /// 207.00 → 5.257), so 3.725 m is XB 146.654-146.693: 146.68, the inch
    /// value with one digit (7 for 4) misprinted, while 176.68 would print
    /// 4.487. The LH2 feed-line fairings on the same azimuths (39.0-52.2° on
    /// fin A, 503-055) start at STA 1722 (BCD, H), which a top at 1740.68
    /// would run 19 in into.
    static let sIIUllageMotorLength = 89.0           // in (H)
    static let sIIUllageMotorDiameter = 12.5         // in (H)
    static let sIIUllageFairingBottom = 1_563.56     // STA, XB -0.44 (H)
    static let sIIUllageFairingTop = 1_710.68        // STA, XB 146.68 (M)
    static let sIIUllageFairingWidth = 24.0          // in (M)
    static let sIIUllageFairingHeight = 22.0         // in (L)
    static let sIIUllageFairingPastFin = 4.0         // deg anticlockwise of fins A-D, VD2 (M)
    /// The exit port's diameter is the exhaust spec's (`ApolloExhaust
    /// .sIIUllage`): 11.27 in, 0.9 of the case at which CEA delivers the
    /// motor's 23,000 lbf at 999 psia (P1, L), which replaced an 8 in
    /// placeholder so that the port and the plume share it.
    static let sIIUllageExitDiameter = ApolloExhaust.sIIUllageExitDiameter   // in (L)
    /// The separation ordnance's two fairings at the first plane (D5 Table
    /// 6-II: θ 55° and 235°, instrumented at STA 1568, H); their size is an
    /// estimate (L).
    static let sICSIIOrdnanceFairings = [55.0, 235.0]   // deg (H)
    static let sICSIIOrdnanceFairing = (full: 1_580.0, top: 1_590.0, radius: 5.0)   // STA, in (L)
}

extension MaterialKey {
    // VG1's finishes (the S-IC, its interstage and the F-1).
    public static let apolloSICHeatShield: MaterialKey = "apollo.sic.heatshield"
    public static let apolloSICCurtain: MaterialKey = "apollo.sic.curtain"
    public static let apolloF1Insulation: MaterialKey = "apollo.f1.insulation"
    public static let apolloF1Extension: MaterialKey = "apollo.f1.extension"
    /// The interstages' inner skin: zinc-chromate primer (the design
    /// report's; VD2's row 503-090, L).
    public static let apolloInterstagePrimer: MaterialKey = "apollo.primer.zinc-chromate"
}

extension ApolloDresser {
    fileprivate static let sICHeatShieldFinish = Finish(colour: (0.5, 0.5, 0.52), material: .apolloSICHeatShield)
    fileprivate static let sICCurtainFinish = Finish(colour: (0.4, 0.38, 0.35), material: .apolloSICCurtain)
    fileprivate static let f1InsulationFinish = Finish(colour: (0.66, 0.64, 0.6), material: .apolloF1Insulation)
    fileprivate static let f1ExtensionFinish = Finish(colour: (0.7, 0.7, 0.7), material: .apolloF1Extension)
    fileprivate static let sICSIIPrimerFinish = Finish(colour: (0.62, 0.64, 0.3), material: .apolloInterstagePrimer)

    func sICShapes() -> [VisualShape]? {
        switch part.name {
        case "S-IC":
            var shapes = sICSkin()
            for fin in [45.0, 135.0, 225.0, 315.0] { shapes += sICFairing(fin) + sICFin(fin) }
            shapes += sICHoldDowns() + sICTunnels() + sICLOXVentFairings()
            // Each engine's parts end with its gas side: the renderer takes a
            // thruster's nozzle exit from the last revolution linked to it.
            for t in part.thrusters where t.groups.contains(.main) { shapes += [sICCurtain(t)] + f1(t) }
            return shapes
        case "S-IC/S-II interstage":
            return sICSIIInterstage()
        default:
            return nil
        }
    }

    /// The S-IC's eight retro ports, its separation plane (STA 1564), its
    /// LOX vents and the LOX tank's frost; the interstage's four S-II
    /// ullage exits and its ring's plane (STA 1760).
    func sICAttachments() -> [VisualAttachment] {
        switch part.name {
        case "S-IC":
            let lox = VisualAttachment(name: "S-IC LOX tank frost", kind: .frostZone,
                                       position: local(Vec3(D.station(S.sICLOXTank), 0, 0)), direction: .unitX,
                                       radius: A.body, length: (S.sICForwardSkirt - S.sICLOXTank) * D.inch)
            return sICRetroPorts()
                + [separationPlane("S-IC/S-II separation plane", at: D.station(D.sICSIISeparationPlane),
                                   radius: A.body, up: true)]
                + sICLOXVentOutlets() + [lox]
        case "S-IC/S-II interstage":
            return sIIUllageExits()
                + [separationPlane("Interstage separation plane", at: D.station(D.sIIAftSkirt),
                                   radius: A.body, up: true)]
        default:
            return []
        }
    }
}

// MARK: - Builders

private typealias A = ApolloDresser
private typealias D = AS506
private typealias S = ApolloShapeData
private typealias P = VisualShape.ProfilePoint
private typealias Q = VisualShape.SectionPoint
private let inch = AS506.inch, degree = Double.pi / 180

/// Construction unit vector at vehicle azimuth `theta` (deg): Position I
/// (+z) at 0, Position II (-y) at 90.
private func sicOutward(_ theta: Double) -> Vec3 { Vec3(0, -sin(theta * degree), cos(theta * degree)) }

/// Vehicle azimuth (deg) of the construction point `c`.
private func sicAzimuth(_ c: Vec3) -> Double { VisualShape.vehicleAzimuth(y: c.y, z: c.z) / degree }

/// The fairing's radius about its own axis (in) at STA `sta`.
private func sicFairingRadius(_ sta: Double) -> Double {
    S.sICFairingAftRadius - (sta - S.sICFairingAft) * tan(S.sICFairingHalfAngle * degree)
}

// Prisms standing on a skin. Their sections' origin is `sICPrismSink`
// under the skin's tangent point (place them there: `sicSunk`), their base
// that far under the skin all along its arc. A station that scales a
// section across by s scales it by s² in height (`sicOnSkin`), so the base
// follows the arc as it narrows; a ramp (`sicRamp`) does the same. Between
// two stations whose s differ by Δ the base's feet sink a further Δ²/4 of
// the arc's drop across the section: the steps here keep that under 0.006
// in (Δ ≤ 0.2 on the tunnels' 0.57 in drop, 0.24 on the ullage fairings').

/// How far (in) a skin of radius `skin` (in) falls below its tangent plane
/// `b` in across.
private func sicDrop(_ b: Double, skin: Double) -> Double { skin - (skin * skin - b * b).squareRoot() }

/// The base of a section `2w` in wide on a skin of radius `skin` (in): from
/// b = w round to -w along the arc, the feet creased (metres out).
private func sicBase(_ w: Double, skin: Double) -> [Q] {
    let n = max(2, Int(w.rounded(.up)))   // 2 in apart at most: the chords sag 0.003 in
    return (0...n).map { k in
        let b = w - 2 * w * Double(k) / Double(n)
        return Q(-sicDrop(b, skin: skin) * inch, b * inch, crease: k == 0 || k == n)
    }
}

/// A half-round section on a skin of radius `skin` (inches in, metres
/// out): `width` across (b), standing `height` proud of the tangent point
/// (a), its flanks dropping to the base.
private func sicHalfRound(width: Double, height: Double, skin: Double, steps: Int = 8) -> [Q] {
    let w = width / 2, sink = S.sICPrismSink
    var q = [Q(sink * inch, -w * inch, crease: true)]
    for k in 1..<steps {
        let phi = Double.pi * (Double(k) / Double(steps) - 0.5)
        q.append(Q((sink + height * cos(phi)) * inch, w * sin(phi) * inch))
    }
    return q + [Q(sink * inch, w * inch, crease: true)] + sicBase(w, skin: skin)
}

/// A U section on a skin of radius `skin` (inches in, metres out):
/// straight flanks `width` apart rising from the base, closed by a
/// semicircle `height` proud of the tangent point.
private func sicUSection(width: Double, height: Double, skin: Double, steps: Int = 10) -> [Q] {
    let w = width / 2, centre = S.sICPrismSink + height - w
    var q = [Q(centre * inch, -w * inch)]
    for k in 1..<steps {
        let phi = Double.pi * (Double(k) / Double(steps) - 0.5)
        q.append(Q((centre + w * cos(phi)) * inch, w * sin(phi) * inch))
    }
    return q + [Q(centre * inch, w * inch)] + sicBase(w, skin: skin)
}

/// A prism station `x` m along on a skin, its section scaled by `s` across
/// and s² in height (`PrismStation`'s width is along the reference, out of
/// the skin): its feet then stay on the arc, as the arc's drop goes as the
/// square of the distance across.
private func sicOnSkin(_ x: Double, _ s: Double) -> VisualShape.PrismStation { .init(x, width: s * s, height: s) }

/// The stations of a ramp from its full section at `from` (m along, not
/// included) to the sliver `sICRampEnd` at `to`: its height falls
/// linearly, its width as the root of it (`sicOnSkin`), in six equal steps
/// of the width.
private func sicRamp(from: Double, to: Double) -> [VisualShape.PrismStation] {
    let end = S.sICRampEnd.squareRoot()
    return (1...6).map { k in
        let s = 1 - (1 - end) * Double(k) / 6
        return sicOnSkin(from + (to - from) * (1 - s * s) / (1 - S.sICRampEnd), s)
    }
}

/// The origin of a section on a skin whose tangent point is `surface`
/// (construction, m) and whose outward normal there is `normal` (unit):
/// `sICPrismSink` under it.
private func sicSunk(_ surface: Vec3, _ normal: Vec3) -> Vec3 { surface - normal * (S.sICPrismSink * inch) }

/// `v` turned `angle` (rad) about the vehicle's axis, towards larger
/// azimuth.
private func sicTurned(_ v: Vec3, _ angle: Double) -> Vec3 {
    let c = cos(angle), s = sin(angle)
    return Vec3(v.x, v.y * c - v.z * s, v.z * c + v.y * s)
}

extension ApolloDresser {
    /// `s` in `finish`, its surface in the vehicle's frame: the off-axis
    /// shapes on the skin that paint is laid out over.
    fileprivate func sICPainted(_ s: VisualShape, _ finish: Finish) -> VisualShape {
        var s = finished(s, finish)
        s.surfaceFrame = .vehicle(partOrigin: construction)
        return s
    }

    /// A band of the skin about the vehicle's axis from STA `bottom` to
    /// `top`, its ends open.
    fileprivate func sICBand(_ bottom: Double, _ top: Double) -> VisualShape {
        var s = revolution([P(D.station(bottom), A.body), P(D.station(top), A.body)], at: .zero,
                           segments: S.sICSkinSegments, A.white)
        s.capBase = false
        s.capTop = false
        return s
    }

    // MARK: S-IC skin

    /// The heat shield across the base, the bands up to the forward skirt
    /// (open, the LOX tank's dome inside) and the interstage's ring.
    fileprivate func sICSkin() -> [VisualShape] {
        let r = A.body, face = S.sICHeatShieldTop - S.sICHeatShieldThickness
        // The shield's aft face, and its edge up to the thrust structure.
        var shield = revolution([P(D.station(face), 0), P(D.station(face), r, crease: true),
                                 P(D.station(S.sICThrustStructure), r)], at: .zero, segments: S.sICSkinSegments,
                                A.sICHeatShieldFinish)
        shield.capTop = false
        var skirt = sICBand(S.sICForwardSkirt, D.sICTop)
        skirt.twoSided = true
        let rise = S.sICLOXVent - S.sICLOXDomeBase
        let dome: [P] = (0...8).map { i in
            let a = Double(i) / 8 * Double.pi / 2
            return P(D.station(S.sICLOXDomeBase + rise * sin(a)), i == 8 ? 0 : r * cos(a))
        }
        var loxDome = revolution(dome, at: .zero, segments: S.sICSkinSegments, A.grey)
        loxDome.capBase = false
        return [shield, sICBand(S.sICThrustStructure, S.sICFuelTank), sICBand(S.sICFuelTank, S.sICIntertank),
                sICBand(S.sICIntertank, S.sICLOXTank), sICBand(S.sICLOXTank, S.sICForwardSkirt), skirt, loxDome]
            + sICSIIWall(D.sICTop, D.sICSIISeparationPlane, ridgeBelow: false, ridgeAbove: true)
    }

    // MARK: Engine fairings

    /// The fairing on fin diagonal `theta`: the half-cone, its two flanks,
    /// the heat shield's lunate panel inside it and its scoops.
    fileprivate func sICFairing(_ theta: Double) -> [VisualShape] {
        let d = sicOutward(theta)
        let length = S.sICFairingForward - S.sICFairingAft
        let base = Vec3(D.station(S.sICFairingAft), 0, 0) + d * (S.sICFairingAxis * inch)
        // In short pieces: a triangle's span of vehicle azimuth stays under
        // a facet's.
        let profile: [P] = (0...24).map { k in
            let sta = S.sICFairingAft + length * Double(k) / 24
            return P((sta - S.sICFairingAft) * inch, sicFairingRadius(sta) * inch)
        }
        var cone = revolution(profile, at: base, reference: d, segments: 64,
                              sweep: -Double.pi / 2...(Double.pi / 2), A.white)
        cone.capBase = false
        cone.capTop = false
        cone.twoSided = true
        cone.surfaceFrame = .vehicle(partOrigin: construction)
        return [cone, sICFairingFlank(theta, side: 1), sICFairingFlank(theta, side: -1), sICLunateShield(theta)]
            + sICScoops(theta)
    }

    /// The flat flank on `side` (+1 towards larger θ) of the fairing on
    /// diagonal `theta`, in its plane from the half-cone's edge in to the
    /// skin's radius, which the edge crosses at STA 130.6.
    fileprivate func sICFairingFlank(_ theta: Double, side: Double) -> VisualShape {
        let d = sicOutward(theta), t = Vec3.unitX.cross(d)
        let half = S.sICFairingHalfAngle * degree
        let skin = D.bodyDiameter / 2, axis = S.sICFairingAxis, aft = S.sICFairingAft
        let meet = (skin * skin - axis * axis).squareRoot()
        let end = aft + (S.sICFairingAftRadius - meet) / tan(half)
        /// The flank's depth (in, inwards negative) at STA `sta`.
        func depth(_ sta: Double) -> Double {
            let rc = sicFairingRadius(sta)
            return (skin * skin - rc * rc).squareRoot() - axis
        }
        /// Distance (in) along the edge from the aft end to STA `sta`.
        func along(_ sta: Double) -> Double { (sta - aft) / cos(half) }
        var outline = [Q(0, 0, crease: true), Q(along(end) * inch, 0, crease: true)]
        for k in 1...8 {
            let sta = end - (end - aft) * Double(k) / 8
            outline.append(Q(along(sta) * inch, depth(sta) * inch, crease: k == 8))
        }
        let edge = (Vec3.unitX - t * (side * tan(half))).normalized
        let origin = Vec3(D.station(aft), 0, 0) + d * (axis * inch) + t * (side * S.sICFairingAftRadius * inch)
        return sICPainted(.plate(outline, at: local(origin), axis: edge, reference: d,
                                thickness: S.sICFairingFlankThickness * inch, color: A.white.colour), A.white)
    }

    /// The heat shield's lunate panel in the fairing on diagonal `theta`:
    /// between the skin's circle and the fairing's section, at the shield's
    /// level (D5 Table 2-I's pressure ports reach 260 in out).
    fileprivate func sICLunateShield(_ theta: Double) -> VisualShape {
        let d = sicOutward(theta), t = Vec3.unitX.cross(d)
        let mid = S.sICHeatShieldTop - S.sICHeatShieldThickness / 2
        let rc = sicFairingRadius(mid), axis = S.sICFairingAxis, skin = D.bodyDiameter / 2
        let edge = asin(rc / skin)
        var outline: [Q] = []
        for k in 0...16 {
            let phi = Double.pi * (Double(k) / 16 - 0.5)
            outline.append(Q((axis + rc * cos(phi)) * inch, rc * sin(phi) * inch, crease: k == 0 || k == 16))
        }
        for k in 0...16 {
            let psi = edge * (1 - Double(k) / 8)
            outline.append(Q(skin * cos(psi) * inch, skin * sin(psi) * inch, crease: k == 0 || k == 16))
        }
        return sICPainted(.plate(outline, at: local(Vec3(D.station(mid), 0, 0)), axis: d, reference: t,
                                thickness: S.sICHeatShieldThickness * inch, color: A.sICHeatShieldFinish.colour),
                         A.sICHeatShieldFinish)
    }

    /// The fairing's air scoops, two either side of its fin, ramping up
    /// from the cone and open forward.
    fileprivate func sICScoops(_ theta: Double) -> [VisualShape] {
        let d = sicOutward(theta), t = Vec3.unitX.cross(d), half = S.sICFairingHalfAngle * degree
        let aft = S.sICScoopStations.lowerBound
        let length = (S.sICScoopStations.upperBound - aft) / cos(half) * inch
        // Across the generatrix the cone curves with radius r / cos(half),
        // r its radius at the scoop's full section.
        let curve = sicFairingRadius(S.sICScoopStations.upperBound) / cos(half)
        let section = sicHalfRound(width: S.sICScoopWidth, height: S.sICScoopHeight, skin: curve)
        let azimuths = S.sICScoopAzimuths.flatMap { [$0, -$0] }
        return azimuths.map { alpha -> VisualShape in
            let n = d * cos(alpha * degree) + t * sin(alpha * degree)
            let edge = (Vec3.unitX - n * tan(half)).normalized, normal = (n + Vec3.unitX * tan(half)).normalized
            let foot = Vec3(D.station(aft), 0, 0) + d * (S.sICFairingAxis * inch) + n * (sicFairingRadius(aft) * inch)
            return sICPainted(.prism(section, from: local(sicSunk(foot, normal)), axis: edge, reference: normal,
                                    stations: sicRamp(from: length, to: 0).reversed() + [.init(length)],
                                    color: A.white.colour), A.white)
        }
    }

    // MARK: Fins

    /// The fin on diagonal `theta`: its flat aft section and its ramp, each
    /// a prism along the span to the tip, scaled with the chord and the
    /// faces' taper. The ramp starts inside the fairing, where the root's
    /// leading edge meets the generatrix, closed in above the lunate panel.
    /// The flat section, over the fairing's open aft end, starts on the
    /// generatrix: its root, `sICFinRootSink` inside it, runs aft and out
    /// along it from the ramp's end, where the section is a sliver.
    fileprivate func sICFin(_ theta: Double) -> [VisualShape] {
        let d = sicOutward(theta)
        let trailing = S.sICFinTrailingEdge, ramp = trailing + S.sICFinFlatChord
        let tipLeading = trailing + S.sICFinTipChord
        let rootTrailing = S.sICFairingAxis + sicFairingRadius(trailing)            // 273.2 in
        let tip = rootTrailing + S.sICFinSpan                                     // 376.2 in
        let root = S.sICFairingAxis + sicFairingRadius(S.sICFinRootLeadingEdge)     // 236.9 in
        /// Half the thickness (in) at `r` in from the vehicle's axis.
        func half(_ r: Double) -> Double {
            let h0 = S.sICFinRootThickness / 2, h1 = S.sICFinTipThickness / 2
            return h1 + (h0 - h1) * (tip - r) / (tip - rootTrailing)
        }
        /// The flat section's root (in from the vehicle's axis) at STA `sta`.
        func sunk(_ sta: Double) -> Double { S.sICFairingAxis + sicFairingRadius(sta) - S.sICFinRootSink }
        func foot(_ sta: Double, _ r: Double) -> Vec3 { local(Vec3(D.station(sta), 0, 0) + d * (r * inch)) }

        // The flat section aft of the ramp's end (a < 0), its full chord
        // from the trailing edge's root out.
        let chord = S.sICFinFlatChord, sliver = S.sICRampEnd
        let r0 = sunk(ramp - sliver * chord), r1 = sunk(trailing)
        let hf = half(r1)
        let flat = [Q(-chord * inch, -hf * inch), Q(0, -hf * inch), Q(0, hf * inch),
                    Q(-chord * inch, hf * inch)].map { Q($0.a, $0.b, crease: true) }
        let flatStations: [VisualShape.PrismStation] = [
            .init(0, width: sliver, height: half(r0) / hf), .init((r1 - r0) * inch),
            .init((tip - r0) * inch, height: half(tip) / hf),
        ]
        let flatSection = VisualShape.prism(flat, from: foot(ramp, r0), axis: d, reference: .unitX,
                                            stations: flatStations, color: A.white.colour)

        let h = half(root), thin = half(tip) / h, span = (tip - root) * inch
        let rampChord = S.sICFinRootLeadingEdge - ramp
        let wedge = [Q(0, -h * inch, crease: true), Q(rampChord * inch, 0, crease: true), Q(0, h * inch, crease: true)]
        let rampSection = VisualShape.prism(wedge, from: foot(ramp, root), axis: d, reference: .unitX,
                                            stations: [.init(0), .init(span, width: (tipLeading - ramp) / rampChord,
                                                                       height: thin)], color: A.white.colour)
        return [sICPainted(flatSection, A.white), sICPainted(rampSection, A.white)]
    }

    // MARK: Hold-downs, tunnels, vents

    /// The four hold-down post fittings at Positions I-IV.
    fileprivate func sICHoldDowns() -> [VisualShape] {
        let size = S.sICHoldDownSize
        return [0.0, 90, 180, 270].map { theta in
            let d = sicOutward(theta)
            let base = Vec3(D.station(S.sICHoldDown), 0, 0) + d * (D.bodyDiameter / 2 * inch)
            return sICPainted(.box(from: local(base), length: size.length * inch, width: size.width * inch,
                                  height: size.depth * inch, axis: .unitX, reference: Vec3.unitX.cross(d),
                                  color: A.grey.colour), A.grey)
        }
    }

    /// The two tunnels, each from its rounded aft end to its forward ramp.
    fileprivate func sICTunnels() -> [VisualShape] {
        let r = S.sICTunnelRadius, skin = D.bodyDiameter / 2
        let section = sicHalfRound(width: 2 * r, height: r, skin: skin)
        return S.sICTunnels.map { tunnel in
            let d = sicOutward(tunnel.azimuth), length = tunnel.forward - S.sICTunnelAft
            // Round in plan at the aft end, as a parabola in elevation.
            var stations: [VisualShape.PrismStation] = (0...8).map { k in
                let a = Double(k) / 8 * Double.pi / 2
                return sicOnSkin(r * (1 - cos(a)) * inch, sin(a))
            }
            let rampFoot = (length - S.sICTunnelRamp) * inch
            stations += [.init(rampFoot)] + sicRamp(from: rampFoot, to: length * inch)
            let base = Vec3(D.station(S.sICTunnelAft), 0, 0) + d * (skin * inch)
            return sICPainted(.prism(section, from: local(sicSunk(base, d)), axis: .unitX, reference: d,
                                    stations: stations, color: A.white.colour), A.white)
        }
    }

    /// The LOX vents' fairings on the forward skirt, open aft, ramped forward.
    fileprivate func sICLOXVentFairings() -> [VisualShape] {
        let v = S.sICLOXVentFairing, skin = D.bodyDiameter / 2
        let section = sicHalfRound(width: 2 * v.radius, height: v.radius, skin: skin)
        return S.sICLOXVents.map { theta in
            let d = sicOutward(theta)
            let base = Vec3(D.station(v.bottom), 0, 0) + d * (skin * inch)
            let full = (v.top - v.bottom - 2 * v.radius) * inch
            return sICPainted(.prism(section, from: local(sicSunk(base, d)), axis: .unitX, reference: d,
                                    stations: [.init(0), .init(full)] + sicRamp(from: full, to: (v.top - v.bottom) * inch),
                                    color: A.white.colour), A.white)
        }
    }

    /// The vents' outlets, at the fairings' open feet, blowing aft and out.
    fileprivate func sICLOXVentOutlets() -> [VisualAttachment] {
        let v = S.sICLOXVentFairing
        return S.sICLOXVents.map { theta in
            let d = sicOutward(theta)
            let at = Vec3(D.station(v.bottom), 0, 0) + d * ((D.bodyDiameter / 2 + v.radius / 2) * inch)
            return VisualAttachment(name: theta < 180 ? "S-IC LOX vent II" : "S-IC LOX vent IV", kind: .vent,
                                    position: local(at), direction: d * 0.25 - Vec3.unitX,
                                    radius: v.radius / 2 * inch)
        }
    }

    /// The retros' ports where each motor's exhaust line leaves its
    /// fairing's skin, ahead of the motor (its thrust point, the grain).
    fileprivate func sICRetroPorts() -> [VisualAttachment] {
        part.thrusters.filter { $0.isSolid && $0.name.contains("retro") }.map { t in
            let start = t.position + construction, exhaust = -t.direction
            let fin = ((sicAzimuth(start) - 45) / 90).rounded() * 90 + 45
            let axis = sicOutward(fin) * (S.sICFairingAxis * inch)
            /// How far (m) the point `l` m down the exhaust lies outside the skin.
            func outside(_ l: Double) -> Double {
                let p = start + exhaust * l
                let dy = p.y - axis.y, dz = p.z - axis.z
                return (dy * dy + dz * dz).squareRoot() - sicFairingRadius(p.x / inch) * inch
            }
            var inside = 0.0, out = 2 * S.sICRetroLength * inch
            for _ in 0..<60 {
                let l = (inside + out) / 2
                if outside(l) < 0 { inside = l } else { out = l }
            }
            return VisualAttachment(name: t.name, kind: .retroPort, position: local(start + exhaust * out),
                                    direction: exhaust, radius: S.sICRetroDiameter / 2 * inch, thruster: t.name)
        }
    }

    // MARK: F-1

    /// The curtain round engine `t`'s upper block up to the heat shield,
    /// fixed to the structure (not gimballed).
    fileprivate func sICCurtain(_ t: Thruster) -> VisualShape {
        let c = S.sICCurtain, g = t.position + construction
        let bottom = D.station(c.bottom), top = D.station(S.sICHeatShieldTop - S.sICHeatShieldThickness)
        var s = finished(.frustum(from: local(Vec3(bottom, g.y, g.z)), length: top - bottom,
                                  baseRadius: c.bottomRadius * inch, topRadius: c.topRadius * inch,
                                  color: A.sICCurtainFinish.colour), A.sICCurtainFinish, vehicleFrame: false)
        s.capBase = false
        s.capTop = false
        s.twoSided = true
        return s
    }

    /// The F-1 on main thruster `t` in flight configuration, every part
    /// linked to it: the cocoon over the dome and chamber, the turbopump,
    /// its inlet block, the gas generator, the heat exchanger down to the
    /// manifold, the manifold, the extension's outside and lip, and last the
    /// gas side from the exit to the injector.
    fileprivate func f1(_ t: Thruster) -> [VisualShape] {
        let gimbal = t.position + construction, aft = -Vec3.unitX
        let yz = Vec3(0, gimbal.y, gimbal.z)
        let pump = yz.length > 1e-6 ? yz.normalized : Vec3.unitZ   // the turbopump's side (L)
        let right = Vec3.unitX.cross(pump)                         // the No. 2 side, seen from the exit
        /// Construction point `x` in aft of the gimbal, `out` towards the
        /// turbopump, `across` towards the No. 2 side.
        func at(_ x: Double, _ out: Double = 0, _ across: Double = 0) -> Vec3 {
            gimbal + aft * (x * inch) + pump * (out * inch) + right * (across * inch)
        }
        func linked(_ s: VisualShape, _ finish: Finish, open: Bool = false) -> VisualShape {
            var s = finished(s, finish, vehicleFrame: false)
            s.thruster = t.name
            if open {
                s.capBase = false
                s.capTop = false
            }
            return s
        }
        let insulation = A.f1InsulationFinish
        func aboutEngine(_ profile: [P], segments: Int) -> VisualShape {
            .revolution(profile.map { P($0.x * inch, $0.r * inch, crease: $0.crease) }, from: local(gimbal),
                        axis: aft, reference: pump, segments: segments, color: insulation.colour)
        }

        // The gas side: r = r_t + b u + c u² from the throat (u = 0) through
        // 10:1 at the joint to 16:1 at the exit.
        let rt = (S.f1ThroatArea / Double.pi).squareRoot()
        let rj = rt * S.f1JointAreaRatio.squareRoot(), re = rt * S.f1AreaRatio.squareRoot()
        let uj = S.f1Joint - S.f1Throat, ue = S.f1Exit - S.f1Throat
        let c = ((re - rt) / ue - (rj - rt) / uj) / (ue - uj)
        let b = (rj - rt) / uj - c * uj
        func gas(_ x: Double) -> Double {
            let u = x - S.f1Throat
            return rt + b * u + c * u * u
        }
        let rc = S.chamberToThroat * rt
        let convergent = S.f1Throat - (rc - rt) / tan(S.convergentHalfAngle * degree)
        let gasSide = [P(S.f1Exit, re)] + stride(from: 200.0, through: 70, by: -10).map { P($0, gas($0)) }
            + [P(S.f1Throat, rt, crease: true), P(convergent, rc, crease: true), P(S.f1InjectorFace, rc, crease: true),
               P(S.f1InjectorFace, 0)]

        let cocoon = [P(-2, 0), P(0, S.f1GimbalBoot), P(6, S.f1GimbalBoot, crease: true),
                      P(18, S.f1CocoonRadius, crease: true)]
            + stride(from: 70.0, through: 140, by: 10).map { P($0, max(S.f1CocoonRadius, gas($0) + S.f1CocoonOffset)) }
        let lip = S.f1ExitOuterDiameter / 2, joint = S.f1JointOuterDiameter / 2
        let outside = [P(S.f1Joint - 4, joint), P(S.f1Joint, joint, crease: true), P(S.f1Exit, lip, crease: true),
                       P(S.f1Exit, re, crease: true)]

        // The manifold, its outside on the exit's envelope and its aft face
        // on the joint.
        let minor = S.f1ManifoldSection / 2
        let manifold = VisualShape.torus(centre: local(at(S.f1Joint - minor)), axis: aft, reference: pump,
                                         majorRadius: (lip - minor) * inch, minorRadius: minor * inch, segments: 48,
                                         minorSegments: 12, color: insulation.colour)

        // The turbopump below its inlet block, the heat exchanger from its
        // turbine down to the manifold's inlet, the gas generator.
        let pumpFoot = S.f1BlockFace + S.f1TurbopumpLength
        let turbopump = VisualShape.frustum(from: local(at(pumpFoot, S.f1TurbopumpAxis)),
                                            length: S.f1TurbopumpLength * inch,
                                            baseRadius: S.f1TurbopumpDiameter / 2 * inch,
                                            topRadius: S.f1TurbopumpDiameter / 2 * inch, color: insulation.colour)
        let r = S.f1InletEndRadius, gap = S.f1InletCentres / 2, o = S.f1TurbopumpAxis
        let ends: [Q] = (0...16).map { k in
            let psi = Double.pi * Double(k) / 16
            return Q((o + r * cos(psi)) * inch, (gap + r * sin(psi)) * inch)
        } + (0...16).map { k in
            let psi = Double.pi * (1 + Double(k) / 16)
            return Q((o + r * cos(psi)) * inch, (r * sin(psi) - gap) * inch)
        }
        let inletBlock = VisualShape.prism(ends, from: local(at(S.f1BlockFace)),
                                           length: (S.f1BlockFace - S.f1InletFace) * inch, axis: .unitX,
                                           reference: pump, color: insulation.colour)
        // The exchanger leaves the turbopump's foot (from 4 in up inside
        // it) and lands on the manifold's crown, its foot 0.5 in in and its
        // outside on the envelope.
        let exchangerTop = at(pumpFoot - 4, S.f1TurbopumpAxis)
        let exchangerFoot = at(S.f1Joint - 2 * minor + 0.5, lip - S.f1HeatExchanger.manifold / 2)
        let exchanger = VisualShape.frustum(from: local(exchangerTop), length: (exchangerFoot - exchangerTop).length,
                                            baseRadius: S.f1HeatExchanger.turbine / 2 * inch,
                                            topRadius: S.f1HeatExchanger.manifold / 2 * inch,
                                            axis: exchangerFoot - exchangerTop, color: insulation.colour)
        let gg = S.f1GasGenerator
        let generator = VisualShape.box(from: local(at(gg.top + gg.length, 0, 1 - S.f1CocoonRadius - gg.across / 2)),
                                        length: gg.length * inch, width: gg.across * inch, height: gg.along * inch,
                                        axis: .unitX, reference: right, color: insulation.colour)

        var nozzle = aboutEngine(gasSide, segments: 64)
        nozzle.capBase = false
        return [linked(aboutEngine(cocoon, segments: 48), insulation, open: true), linked(turbopump, insulation),
                linked(inletBlock, insulation), linked(generator, insulation), linked(exchanger, insulation),
                linked(manifold, insulation),
                linked(aboutEngine(outside, segments: 64), A.f1ExtensionFinish, open: true),
                linked(nozzle, A.dark)]
    }

    // MARK: S-IC/S-II interstage

    /// The interstage above the separation plane: its walls, the S-II
    /// ullage motors' fairings and the ordnance fairings.
    fileprivate func sICSIIInterstage() -> [VisualShape] {
        sICSIIWall(D.sICSIISeparationPlane, D.sIIAftSkirt, ridgeBelow: true, ridgeAbove: true)
            + sIIUllageFairings() + S.sICSIIOrdnanceFairings.map(sICSIIOrdnanceFairing)
    }

    /// The interstage's skin from STA `bottom` to `top`: white outside, the
    /// primer inside, with half of a separation ridge at either end if asked.
    fileprivate func sICSIIWall(_ bottom: Double, _ top: Double, ridgeBelow: Bool,
                                ridgeAbove: Bool) -> [VisualShape] {
        let r = D.bodyDiameter / 2, inner = r - S.sICSIISkin
        let wall = [P(top, r), P(top, inner, crease: true), P(bottom, inner, crease: true), P(bottom, r)]
        var primer = revolution(wall.map { P(D.station($0.x), $0.r * inch, crease: $0.crease) }, at: .zero,
                                segments: S.sICSkinSegments, A.sICSIIPrimerFinish)
        primer.capBase = false
        primer.capTop = false
        var shapes = [sICBand(bottom, top), primer]
        let w = S.sICSIIRidge.width / 2, proud = (r + S.sICSIIRidge.height) * inch
        for (on, from, to) in [(ridgeBelow, bottom, bottom + w), (ridgeAbove, top - w, top)] where on {
            var ridge = revolution([P(D.station(from), r * inch), P(D.station(from), proud, crease: true),
                                    P(D.station(to), proud, crease: true), P(D.station(to), r * inch)],
                                   at: .zero, segments: S.sICSkinSegments, A.white)
            ridge.capBase = false
            ridge.capTop = false
            shapes.append(ridge)
        }
        return shapes
    }

    /// The S-II ullage motors' fairings' azimuths (deg), `sIIUllageFairingPastFin`
    /// anticlockwise of fins A-D, in the order of the motors they stand for
    /// (`sIIUllageExits`).
    static var sIIUllageFairingAzimuths: [Double] {
        [45.0, 135.0, 225.0, 315.0].map { $0 + S.sIIUllageFairingPastFin }
    }

    /// The S-II ullage motors' fairings on the interstage: four, and on
    /// AS-501 eight (D5 §6.2.2), the other four half-way between (L). Each
    /// is full round its motor from STA 1563.56 to 1 in above the motor's
    /// top, the motor 89 in up from the separation plane at the physics'
    /// radius, then tapers to a point at its top: by 1 - f² across and its
    /// square in height, f from 0 to 1, so it fairs into the skin.
    func sIIUllageFairings() -> [VisualShape] {
        var azimuths = A.sIIUllageFairingAzimuths
        if variant.launchVehicle == .as501 { azimuths += azimuths.map { $0 + 45 } }
        let bottom = S.sIIUllageFairingBottom, skin = D.bodyDiameter / 2
        let full = D.sICSIISeparationPlane + S.sIIUllageMotorLength + 1 - bottom
        let taper = S.sIIUllageFairingTop - bottom - full
        var stations: [VisualShape.PrismStation] = [.init(0), .init(full * inch)]
        for k in 1...8 {
            let f = Double(k) / 8
            stations.append(sicOnSkin((full + taper * f) * inch, 1 - f * f))
        }
        let section = sicUSection(width: S.sIIUllageFairingWidth, height: S.sIIUllageFairingHeight, skin: skin)
        return azimuths.map { theta in
            let d = sicOutward(theta), base = Vec3(D.station(bottom), 0, 0) + d * (skin * inch)
            return sICPainted(.prism(section, from: local(sicSunk(base, d)), axis: .unitX, reference: d,
                                    stations: stations, color: A.white.colour), A.white)
        }
    }

    /// An ordnance fairing on azimuth `theta`, above the separation plane.
    fileprivate func sICSIIOrdnanceFairing(_ theta: Double) -> VisualShape {
        let f = S.sICSIIOrdnanceFairing, bottom = D.sICSIISeparationPlane, skin = D.bodyDiameter / 2
        let section = sicHalfRound(width: 2 * f.radius, height: f.radius, skin: skin)
        let d = sicOutward(theta), base = Vec3(D.station(bottom), 0, 0) + d * (skin * inch)
        let full = (f.full - bottom) * inch
        return sICPainted(.prism(section, from: local(sicSunk(base, d)), axis: .unitX, reference: d,
                                stations: [.init(0), .init(full)] + sicRamp(from: full, to: (f.top - bottom) * inch),
                                color: A.white.colour), A.white)
    }

    /// The ullage exits, one per S-II ullage motor of the part, motor n on
    /// fin n's fairing: each motor's thrust point and exhaust turned about
    /// the vehicle's axis to its fairing, the exit where that exhaust line
    /// crosses the fairing's foot (STA 1563.56). The motors themselves stay
    /// where the physics has them.
    func sIIUllageExits() -> [VisualAttachment] {
        let motors = part.thrusters.filter { $0.isSolid && $0.name.contains("ullage") }
        return zip(motors, A.sIIUllageFairingAzimuths).map { t, theta in
            let thrust = t.position + construction
            let turn = (theta - sicAzimuth(thrust)) * degree
            let start = sicTurned(thrust, turn), exhaust = sicTurned(-t.direction, turn)
            let l = (start.x - D.station(S.sIIUllageFairingBottom)) / -exhaust.x
            return VisualAttachment(name: t.name, kind: .ullageExit, position: local(start + exhaust * l),
                                    direction: exhaust, radius: S.sIIUllageExitDiameter / 2 * inch,
                                    thruster: t.name)
        }
    }
}
