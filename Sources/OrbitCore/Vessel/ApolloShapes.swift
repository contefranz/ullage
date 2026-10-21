import Foundation

/// Shape dimensions of the Saturn V and the Apollo spacecraft that `AS506`
/// does not already carry. They draw the vehicle and feed no physics.
///
/// Confidence as in `AS506`: (H) high, (M) medium, (L) low. "Derived" is
/// arithmetic on published values, "estimate" is a guess that only has to
/// look right, "recalled" was not checked against the source. Inches and Xa
/// (Apollo station, in) as the sources give them; `ApolloAxes` converts.
enum ApolloShapeData {
    // MARK: Engine bells
    //
    // Every bell runs from its exit plane, of radius √(A_e/π), to the
    // injector at the gimbal: a Rao-style bell (a parabola leaving the throat
    // at 1.6 and meeting the exit at 0.4 times the mean slope) over 80 % of a
    // 15° cone's length, at most 80 % of the engine, then a 30° convergent
    // section to a chamber 1.3 times the throat radius. Shape only (L).

    static let bellFraction = 0.8
    static let bellConeHalfAngle = 15.0              // deg
    static let maxDivergentShare = 0.8               // of the exit-to-gimbal length
    static let convergentHalfAngle = 30.0            // deg
    static let chamberToThroat = 1.3                 // radius ratio

    /// F-1: 16:1 at the nozzle extension's exit (10:1 at the extension joint).
    static let f1AreaRatio = 16.0                    // Saturn V News Reference, F-1 fact sheet (recalled, M)
    // J-2: `AS506.j2AreaRatio`, 27.5.

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

    // MARK: Command module outer mould line
    //
    // NASA TM X-1243 (Bertin, 1966) Fig. 1: a spherical heat shield, a
    // toroidal shoulder at the maximum radius, a 33° conical afterbody and a
    // spherical apex. Fig. 1(b) is the 0.045-scale AEDC model: 3.46 in
    // maximum radius, 8.32 in heat-shield radius, 0.35 in shoulder, 0.41 in
    // apex (184.9, 7.78 and 9.1 in full scale). Fig. 1(a) is the 0.02-scale
    // JPL model, 2.55 in long (127.5 in full scale) with a 15.4 in apex.

    static let cmMaxRadius = 77.0                    // in, TM X-1243 symbols: "77 inches for full-scale command module" (H)
    static let cmHeatShieldRadius = 184.8            // in, design-entry (M); TM X-1243 Fig. 1(b) 8.32 in at 0.045 scale = 184.9 (H)
    static let cmShoulderRadius = 7.8                // in, TM X-1243 Fig. 1(b): 0.35 in at 0.045 scale (M)
    static let cmConeHalfAngle = 33.0                // deg, TM X-1243 Fig. 1 (H)
    /// From the heat shield's face to the apex: 10 ft 7 in.
    static let cmHeight = 127.0                      // in, CSM News Reference (M); TM X-1243 Fig. 1(a) 127.5 in
    /// The heat shield's face. TN D-5399 Table II note (b) puts CM station
    /// 1000 at "the tangency line of the CM substructure mold line", and
    /// Apollo 7's CM CG, Xa 1040.8 (Mission Report Table A.5-I rows 19-20),
    /// at TN D-5276's x_cg/d of 0.27-0.28 from the face puts the face at
    /// Xa 998-999: the ablator's thickness below the substructure. (The M1
    /// datasheet's Xa 1010, L, is the SM's top, which the heat shield sinks
    /// into.)
    static let cmFace = 1_000.0                      // Xa, TN D-5399 Table II (M)
    /// The forward heat shield (apex cover) above its base, and the docking
    /// tunnel under it.
    static let apexCoverBase = 88.0                  // in above the face, estimate (L)
    static let tunnelRadius = 16.5                   // in, estimate (L)
    static let tunnelTop = 120.0                     // in above the face, estimate (L)
    /// The boost protective cover's stand-off from the CM's surface.
    static let bpcStandOff = 1.5                     // in, estimate (L)

    // MARK: SLA

    /// The SLA, Xa 502-838 (28 ft), is a fixed 7 ft ring under four 21 ft
    /// panels, numbered by 68-FM-160 as 1 at +Z_A, 2 at -Z_A, 3 at +Y_A and
    /// 4 at -Y_A, each a quarter turn about its axis. The panels' projected
    /// area, 239 ft² (68-FM-160 §3.2e, H), checks the split.
    static let slaHinge = 586.0                      // Xa, Wikipedia "Apollo (spacecraft)": 7 ft + 21 ft (M)
    static let slaPanels: [(ya: Double, za: Double)] = [(0, 1), (0, -1), (1, 0), (-1, 0)]   // 68-FM-160 (H)

    // MARK: LM, crude
    //
    // Inside `AS506`'s stowed envelope (h 85.9-90.9 m, radius 2.1 m, L): an
    // octagonal descent stage, an ascent stage and its docking tunnel, as
    // shares of the envelope's height. Estimates (L).

    static let lmDescentShare = 0.35
    static let lmAscentShare = 0.9
    static let lmAscentRadius = 1.3                  // m, estimate (L)
    static let lmTunnelRadius = 0.42                 // m, estimate (L)

    // MARK: LES and BPC, crude
    //
    // Down from the tip (`AS506.overallHeight`, Xa ≈ 1484): the Q-ball nose
    // cone, the canard and ballast section, the motors (tower jettison and
    // pitch control motors above the launch escape motor, 26 in across) and
    // the truss tower to the CM.

    static let lesNoseLength = 13.37                 // in, Q-ball nose cone, 13.3 in across; engineering history (L)
    static let lesNoseRadius = 6.65                  // in (L)
    static let lesMotorTop = 1_430.0                 // Xa, estimate (L): the TJM's grain, Xa 1408.5 (`AS506`), below it
    static let lesMotorBottom = 1_207.0              // Xa: the launch escape motor, 15 ft 3 in, recalled (L)
    static let lesMotorRadius = 13.0                 // in, 26 in across, recalled (L); `AS506.lesRadius` ≈ 0.66 m across
    static let lesTowerBaseRadius = 24.0             // in: about 4 ft across at the base, recalled (L)
    static let lesTowerTopRadius = 11.0              // in, estimate (L)
    static let lesTubeRadius = 1.5                   // in, estimate (L)
}

/// The CM's outer mould line (`ApolloShapeData`), as profile points with
/// their outward normals, in inches above the heat shield's face.
enum CMOuterMouldLine {
    typealias S = ApolloShapeData
    static let theta = S.cmConeHalfAngle * Double.pi / 180
    /// The shoulder torus's section centre.
    static let shoulderCentre: (x: Double, r: Double) = {
        let rho = S.cmMaxRadius - S.cmShoulderRadius, d = S.cmHeatShieldRadius - S.cmShoulderRadius
        return (S.cmHeatShieldRadius - (d * d - rho * rho).squareRoot(), rho)
    }()
    /// Normal angles (from -x towards +r) where the heat shield meets the
    /// shoulder and the shoulder meets the cone.
    static let heatShieldEdge = asin(shoulderCentre.r / (S.cmHeatShieldRadius - S.cmShoulderRadius))
    static let coneStart = Double.pi / 2 + theta
    /// The apex sphere that ends the cone at `cmHeight`: derived (L), 18.9 in
    /// against TM X-1243's 15.4 in and 9.1 in models.
    static let apexRadius: Double = {
        let c = shoulderCentre, start = (x: c.x + S.cmShoulderRadius * sin(theta), r: c.r + S.cmShoulderRadius * cos(theta))
        let vertex = start.x + start.r / tan(theta)
        return (vertex - S.cmHeight) / (1 / sin(theta) - 1)
    }()

    struct Point { var x: Double; var r: Double; var nx: Double; var nr: Double }

    /// The heat shield: the spherical cap and the shoulder, from the face to
    /// the cone.
    static var heatShield: [Point] {
        let cap = (0...8).map { i -> Point in
            let a = heatShieldEdge * Double(i) / 8
            return Point(x: S.cmHeatShieldRadius * (1 - cos(a)), r: S.cmHeatShieldRadius * sin(a), nx: -cos(a), nr: sin(a))
        }
        // About 6° steps, through the maximum radius at 90°. The typed
        // parameters keep Swift 6.0's type checker on Linux within its limits.
        let halfPi = Double.pi / 2
        let rising = (1...11).map { (i: Int) -> Double in heatShieldEdge + (halfPi - heatShieldEdge) * Double(i) / 11 }
        let falling = (1...5).map { (i: Int) -> Double in halfPi + (coneStart - halfPi) * Double(i) / 5 }
        let shoulder = (rising + falling).map { a -> Point in
            Point(x: shoulderCentre.x - S.cmShoulderRadius * cos(a), r: shoulderCentre.r + S.cmShoulderRadius * sin(a),
                  nx: -cos(a), nr: sin(a))
        }
        return cap + shoulder
    }

    /// The afterbody: the cone and the apex sphere, from the shoulder to the
    /// apex.
    static var afterbody: [Point] {
        let centre = S.cmHeight - apexRadius
        return [heatShield[heatShield.count - 1]] + (0...6).map { i -> Point in
            let a = coneStart + (Double.pi - coneStart) * Double(i) / 6
            return Point(x: centre - apexRadius * cos(a), r: apexRadius * sin(a), nx: -cos(a), nr: sin(a))
        }
    }

    /// Radius of the afterbody cone at `x` (in above the face), and where
    /// the cone has radius `r`.
    static func coneRadius(at x: Double) -> Double {
        let start = heatShield[heatShield.count - 1]
        return start.r - (x - start.x) * tan(theta)
    }
    static func coneStation(atRadius r: Double) -> Double {
        let start = heatShield[heatShield.count - 1]
        return start.x + (start.r - r) / tan(theta)
    }
}

extension VesselLibrary {
    /// Give the parts of a Saturn V or Apollo vessel their shapes, by part
    /// name, in the Saturn V construction frame (any vessel built there, or
    /// separated from one, keeps it). Names follow the M1.5 contract, so the
    /// stack's single "CSM" and "SLA" parts and the split "SM", "CM", "SLA
    /// ring", "SLA panel 1"-"4", "Apex cover" and parachute parts are all
    /// dressed. Main engines get open bells linked to their thrusters, the SPS
    /// its bell when the part has an "SPS" thruster. A part whose name is not
    /// known keeps its shapes; every other part's shapes are replaced.
    public static func dressApollo(_ vessel: Vessel) {
        let names = Set(vessel.parts.map(\.name))
        for p in vessel.parts {
            let dresser = ApolloDresser(part: p, construction: p.offset - vessel.structureOrigin,
                                        apexCovered: names.contains("Apex cover"))
            if let shapes = dresser.shapes() { p.shapes = shapes }
        }
    }

    /// `dressApollo` for `saturnV()`'s stack.
    public static func dressSaturnV(_ stack: Vessel) { dressApollo(stack) }
}

/// One part's shapes, built in construction coordinates (m) and moved into
/// the part frame.
private struct ApolloDresser {
    typealias D = AS506
    typealias S = ApolloShapeData
    typealias P = VisualShape.ProfilePoint
    typealias Colour = (Double, Double, Double)

    let part: VesselPart
    /// Construction coordinates of the part's reference point.
    let construction: Vec3
    /// The CM's apex is a part of its own: draw the CM's forward deck and tunnel.
    let apexCovered: Bool

    static let white: Colour = (0.9, 0.9, 0.88), dark: Colour = (0.25, 0.25, 0.27), grey: Colour = (0.72, 0.72, 0.74)
    static let aluminium: Colour = (0.78, 0.79, 0.8), silver: Colour = (0.82, 0.82, 0.84)
    static let ablator: Colour = (0.45, 0.38, 0.3), nozzleExtension: Colour = (0.6, 0.6, 0.62)
    static let gold: Colour = (0.78, 0.62, 0.25), canvas: Colour = (0.85, 0.8, 0.7)

    static let body = D.bodyDiameter / 2 * D.inch, upper = D.sIVBDiameter / 2 * D.inch
    static let csmRadius = D.csmDiameter / 2 * D.inch
    static let lesTip = D.station(D.baseStation) + D.overallHeight * D.foot

    /// Construction x (m) of Apollo station `xa` (in).
    func xa(_ xa: Double) -> Double { D.apolloStation(xa) }
    /// Construction x (m) of a point `x` inches above the CM's heat-shield face.
    func cm(_ x: Double) -> Double { xa(S.cmFace + x) }
    /// Part-frame point of construction coordinates `c`.
    func local(_ c: Vec3) -> Vec3 { c - construction }

    /// A frustum along +x from construction x `bottom` to `top`, off the axis
    /// by (`y`, `z`); `open` leaves both ends open and draws both faces.
    func frustum(_ bottom: Double, _ top: Double, _ r0: Double, _ r1: Double, _ colour: Colour,
                 y: Double = 0, z: Double = 0, open: Bool = false) -> VisualShape {
        var s = VisualShape.frustum(from: local(Vec3(bottom, y, z)), length: top - bottom, baseRadius: r0,
                                    topRadius: r1, color: colour)
        if open { s.capBase = false; s.capTop = false; s.twoSided = true }
        return s
    }

    /// A surface of revolution along `axis` from the construction point `at`.
    func revolution(_ profile: [P], at: Vec3, axis: Vec3 = .unitX, reference: Vec3? = nil, segments: Int = 48,
                    sweep: ClosedRange<Double> = 0...(2 * Double.pi), _ colour: Colour) -> VisualShape {
        .revolution(profile, from: local(at), axis: axis, reference: reference, segments: segments, sweep: sweep,
                    color: colour)
    }

    /// An open, two-sided bell from its exit plane (x = 0) to the injector at
    /// `length` (m), with exit radius `exitRadius` (m).
    static func bell(exitRadius re: Double, areaRatio: Double, length: Double) -> [P] {
        let deg = Double.pi / 180
        let rt = re / areaRatio.squareRoot(), rc = S.chamberToThroat * rt, spread = re - rt
        let divergent = min(S.bellFraction * spread / tan(S.bellConeHalfAngle * deg), S.maxDivergentShare * length)
        let convergent = min((rc - rt) / tan(S.convergentHalfAngle * deg), (length - divergent) / 2)
        let contour = (0...10).map { i -> P in
            let t = 1 - Double(i) / 10   // 1 at the exit, 0 at the throat
            return P(divergent * (1 - t), rt + spread * (1.6 * t - 0.6 * t * t))
        }
        return contour + [P(divergent + convergent, rc, crease: true), P(length, rc, crease: true)]
    }

    /// A bell for each main-group thruster, from construction x `exit` to its
    /// gimbal, linked to the thruster.
    func bells(exit: Double, exitArea: Double, areaRatio: Double, _ colour: Colour) -> [VisualShape] {
        part.thrusters.filter { $0.groups.contains(.main) }.map { t in
            let gimbal = t.position.x + construction.x
            var s = VisualShape.revolution(ApolloDresser.bell(exitRadius: (exitArea / Double.pi).squareRoot(),
                                                              areaRatio: areaRatio, length: gimbal - exit),
                                           from: Vec3(exit - construction.x, t.position.y, t.position.z),
                                           color: colour)
            s.capBase = false
            s.twoSided = true
            s.thruster = t.name
            return s
        }
    }

    func shapes() -> [VisualShape]? {
        typealias A = ApolloDresser
        let name = part.name
        switch name {
        case "S-IC":
            return [frustum(D.station(D.f1GimbalStation), D.station(D.sICTop), A.body, A.body, A.white)]
                + bells(exit: D.station(D.baseStation), exitArea: D.f1ExitArea, areaRatio: S.f1AreaRatio, A.dark)
        case "S-IC/S-II interstage":
            return [frustum(D.station(D.sICTop), D.station(D.sIIAftSkirt), A.body, A.body, A.white, open: true)]
        case "S-II":
            // The thrust structure hangs below the aft skirt to the gimbal plane.
            return [frustum(D.station(D.sIIAftSkirt), D.station(D.sIITop), A.body, A.body, A.white),
                    frustum(D.station(D.sIIJ2GimbalStation), D.station(D.sIIAftSkirt), 0.6 * A.body, A.body, A.grey)]
                + bells(exit: D.station(D.sIIJ2ExitStation), exitArea: D.j2ExitArea, areaRatio: D.j2AreaRatio, A.dark)
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
        case "SLA":
            return slaRing() + (1...4).map(slaPanel)
        case "SLA ring":
            return slaRing()
        case "LM":
            return lm()
        case "CSM":
            return serviceModule() + commandModule()
        case "SM":
            return serviceModule()
        case "CM":
            return commandModule()
        case "Apex cover":
            return [apexCover()]
        case "Drogue parachutes":
            // Two mortars beside the tunnel.
            return [90.0, 270.0].map { stowed(at: $0, radius: 4.5, height: 12, A.grey) }
        case "Main parachutes":
            // Three packs round the tunnel.
            return [30.0, 150.0, 210.0].map { stowed(at: $0, radius: 5, height: 10, A.canvas) }
        case "LES":
            return les()
        default:
            if name.hasPrefix("SLA panel "), let n = Int(name.dropFirst("SLA panel ".count)), (1...4).contains(n) {
                return [slaPanel(n)]
            }
            return nil
        }
    }

    /// The S-IVB's two APS modules on the aft skirt at Positions I and III.
    func apsModules() -> [VisualShape] {
        let x = D.height(D.apsModuleHeight)
        return [1.0, -1.0].map { side in
            frustum(x - 0.9, x + 0.9, 0.35, 0.35, ApolloDresser.grey, z: side * (ApolloDresser.upper + 0.15))
        }
    }

    // MARK: SLA

    /// The SLA's radius at Apollo station `station`, from the IU's top
    /// (Xa 502) to the SM's aft bulkhead.
    func slaRadius(_ station: Double) -> Double {
        let base = D.iuTop - D.apolloStationOffset, r0 = ApolloDresser.upper, r1 = ApolloDresser.csmRadius
        return r0 + (r1 - r0) * (station - base) / (D.slaTop - base)
    }

    func slaRing() -> [VisualShape] {
        [frustum(D.station(D.iuTop), xa(S.slaHinge), slaRadius(D.iuTop - D.apolloStationOffset),
                 slaRadius(S.slaHinge), ApolloDresser.white, open: true)]
    }

    /// Panel `n` (1-4): a quarter turn of the SLA's cone about its axis.
    func slaPanel(_ n: Int) -> VisualShape {
        let axis = S.slaPanels[n - 1], centre = ApolloAxes.direction(xa: 0, ya: axis.ya, za: axis.za)
        var s = revolution([P(0, slaRadius(S.slaHinge)), P(xa(D.slaTop) - xa(S.slaHinge), slaRadius(D.slaTop))],
                           at: Vec3(xa(S.slaHinge), 0, 0), reference: centre, segments: 48,
                           sweep: -Double.pi / 4...Double.pi / 4, ApolloDresser.white)
        s.capBase = false
        s.capTop = false
        s.twoSided = true
        return s
    }

    // MARK: LM

    func lm() -> [VisualShape] {
        let bottom = D.height(D.lmBottomHeight), top = D.height(D.lmTopHeight), h = top - bottom
        let descentTop = bottom + S.lmDescentShare * h, ascentTop = bottom + S.lmAscentShare * h
        var descent = revolution([P(0, D.lmRadius), P(descentTop - bottom, D.lmRadius)], at: Vec3(bottom, 0, 0),
                                 segments: 8, sweep: Double.pi / 8...(Double.pi / 8 + 2 * Double.pi), ApolloDresser.gold)
        descent.faceted = true
        return [descent,
                frustum(descentTop, ascentTop, S.lmAscentRadius, 0.85 * S.lmAscentRadius, ApolloDresser.grey),
                frustum(ascentTop, top, S.lmTunnelRadius, S.lmTunnelRadius, ApolloDresser.grey)]
    }

    // MARK: Service module

    func serviceModule() -> [VisualShape] {
        let r = ApolloDresser.csmRadius, inch = D.inch
        var sps = revolution(ApolloDresser.bell(exitRadius: S.spsExitDiameter / 2 * inch, areaRatio: S.spsAreaRatio,
                                                length: (S.spsGimbal - S.spsExit) * inch),
                             at: Vec3(xa(S.spsExit), 0, 0), ApolloDresser.nozzleExtension)
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
            var s = VisualShape.revolution([P(0, exitRadius), P(nozzleLength, 0.35 * exitRadius)],
                                           from: local(throat + exhaust * nozzleLength), axis: -exhaust,
                                           segments: 12, color: A.dark)
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

    // MARK: Command module

    /// The heat shield (emissive) and the afterbody; without the apex when
    /// the apex cover is a part of its own, showing the forward deck and the
    /// docking tunnel.
    func commandModule() -> [VisualShape] {
        typealias A = ApolloDresser
        typealias M = CMOuterMouldLine
        let face = Vec3(cm(0), 0, 0), inch = D.inch
        var heatShield = revolution(M.heatShield.map { P($0.x * inch, $0.r * inch) }, at: face, A.ablator)
        heatShield.capTop = false
        heatShield.emissive = .heatShield
        var afterbody: VisualShape
        if apexCovered {
            let base = S.apexCoverBase, r = M.coneRadius(at: base)
            afterbody = revolution([P(M.afterbody[0].x, M.afterbody[0].r), P(base, r, crease: true),
                                    P(base, S.tunnelRadius, crease: true), P(S.tunnelTop, S.tunnelRadius, crease: true),
                                    P(S.tunnelTop, 0)].map { P($0.x * inch, $0.r * inch, crease: $0.crease) },
                                   at: face, A.silver)
        } else {
            afterbody = revolution(M.afterbody.map { P($0.x * inch, $0.r * inch) }, at: face, A.silver)
        }
        afterbody.capBase = false
        return [heatShield, afterbody]
    }

    /// The forward heat shield: the OML above `apexCoverBase`, open below.
    func apexCover() -> VisualShape {
        typealias M = CMOuterMouldLine
        let base = S.apexCoverBase, inch = D.inch
        let profile = [P(base * inch, M.coneRadius(at: base) * inch)]
            + M.afterbody.filter { $0.x > base }.map { P($0.x * inch, $0.r * inch) }
        var s = revolution(profile, at: Vec3(cm(0), 0, 0), ApolloDresser.silver)
        s.capBase = false
        s.twoSided = true
        return s
    }

    /// A stowed parachute item in the forward compartment, at `azimuth`
    /// (deg from +Y_A towards +Z_A).
    func stowed(at azimuth: Double, radius: Double, height: Double, _ colour: Colour) -> VisualShape {
        let a = azimuth * Double.pi / 180, inch = D.inch
        let d = ApolloAxes.direction(xa: 0, ya: cos(a), za: sin(a)) * ((S.tunnelRadius + radius + 1) * inch)
        return frustum(cm(S.apexCoverBase), cm(S.apexCoverBase + height), radius * inch, radius * inch, colour,
                       y: d.y, z: d.z)
    }

    // MARK: LES

    /// The BPC over the CM's afterbody, the truss tower, the motors, the
    /// canards and the nose.
    func les() -> [VisualShape] {
        typealias A = ApolloDresser
        typealias M = CMOuterMouldLine
        let inch = D.inch, off = S.bpcStandOff
        // From the shoulder's widest point up, pushed out along the normals.
        let shell = (M.heatShield.filter { $0.nx >= -1e-9 } + M.afterbody.dropFirst())
            .map { P(($0.x + off * $0.nx) * inch, ($0.r + off * $0.nr) * inch) }
        var bpc = revolution(shell, at: Vec3(cm(0), 0, 0), A.white)
        bpc.capBase = false
        bpc.twoSided = true

        let motorBottom = xa(S.lesMotorBottom), motorTop = xa(S.lesMotorTop), noseBase = A.lesTip - S.lesNoseLength * inch
        let motorR = S.lesMotorRadius * inch, noseR = S.lesNoseRadius * inch
        // Legs from the CM's surface at the base radius to the motor's skirt, on the diagonals.
        let baseX = M.coneStation(atRadius: S.lesTowerBaseRadius)
        let legs = (0..<4).map { i -> VisualShape in
            let a = (Double(i) + 0.5) * Double.pi / 2
            let d = Vec3(0, cos(a), sin(a))
            let from = Vec3(cm(baseX), 0, 0) + d * (S.lesTowerBaseRadius * inch)
            let to = Vec3(motorBottom, 0, 0) + d * (S.lesTowerTopRadius * inch)
            return VisualShape.frustum(from: local(from), length: (to - from).length, baseRadius: S.lesTubeRadius * inch,
                                       topRadius: S.lesTubeRadius * inch, axis: to - from, color: A.grey)
        }
        return [bpc] + legs + [
            frustum(motorBottom, motorTop, motorR, motorR, A.white),
            frustum(motorTop, noseBase, motorR, noseR, A.white),
            frustum(noseBase, A.lesTip, noseR, 0.15 * noseR, A.grey),
        ]
    }
}
