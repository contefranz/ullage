import Foundation

/// Shape dimensions of the Saturn V and the Apollo spacecraft that `AS506`
/// does not already carry. They draw the vehicle and feed no physics.
///
/// Confidence as in `AS506`: (H) high, (M) medium, (L) low. "Derived" is
/// arithmetic on published values, "estimate" is a guess that only has to
/// look right, "recalled" was not checked against the source. Inches and Xa
/// (Apollo station, in) as the sources give them; `ApolloAxes` converts.
///
/// Each element's dimensions are in an extension in its own file, with the
/// shapes they draw: ApolloShapes+SIC.swift (S-IC, S-IC/S-II interstage),
/// +SII.swift (S-II), +SIVB.swift (S-II/S-IVB interstage, S-IVB, its
/// ullage rockets, IU), +SLA.swift (SLA, LM), +SM.swift (SM, SPS, SM RCS),
/// +CM.swift (CM, apex cover, parachutes) and +LES.swift (LES and BPC).
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

    // The F-1's area ratio is in +SIC.swift, the SPS's in +SM.swift.
    // J-2: `AS506.j2AreaRatio`, 27.5.
}

extension VesselLibrary {
    /// Give the parts of a Saturn V or Apollo vessel their shapes and
    /// attachments, by part name and `appearance` (Apollo 11's when nil),
    /// in the Saturn V construction frame (any vessel built there, or
    /// separated from one, keeps it). Names follow the M1.5 contract, so the
    /// stack's single "CSM" and "SLA" parts and the split "SM", "CM", "SLA
    /// ring", "SLA panel 1"-"4", "Apex cover" and parachute parts are all
    /// dressed. Main engines get open bells linked to their thrusters, the SPS
    /// its bell when the part has an "SPS" thruster. A part whose name is not
    /// known keeps its shapes and attachments; every other part's are
    /// replaced.
    public static func dressApollo(_ vessel: Vessel) {
        let names = Set(vessel.parts.map(\.name))
        for p in vessel.parts {
            let dresser = ApolloDresser(part: p, construction: p.offset - vessel.structureOrigin,
                                        apexCovered: names.contains("Apex cover"), variant: p.appearance ?? .apollo11)
            if let dress = dresser.dress() {
                p.shapes = dress.shapes
                p.attachments = dress.attachments
            }
        }
    }

    /// `dressApollo` for `saturnV()`'s stack.
    public static func dressSaturnV(_ stack: Vessel) { dressApollo(stack) }
}

extension MaterialKey {
    // The Apollo dresser's materials, one per finish (`ApolloDresser`).
    public static let apolloWhitePaint: MaterialKey = "apollo.paint.white"
    public static let apolloEngineBell: MaterialKey = "apollo.engine.bell"
    public static let apolloGreyMetal: MaterialKey = "apollo.metal.grey"
    public static let apolloSMAluminium: MaterialKey = "apollo.sm.aluminium"
    public static let apolloCMFoil: MaterialKey = "apollo.cm.foil"
    public static let apolloAblator: MaterialKey = "apollo.cm.ablator"
    public static let apolloSPSNozzle: MaterialKey = "apollo.sps.nozzle"
    public static let apolloLMFoil: MaterialKey = "apollo.lm.foil"
    public static let apolloCanvas: MaterialKey = "apollo.fabric.canvas"
}

/// One part's shapes and attachments, built in construction coordinates
/// (m) and moved into the part frame. The elements' files each answer for
/// the part names they know (`sICShapes()`, with `sICAttachments()` for
/// those parts, and so on); shapes about the vehicle's axis measure their
/// surface in its frame.
struct ApolloDresser {
    typealias D = AS506
    typealias S = ApolloShapeData
    typealias P = VisualShape.ProfilePoint

    /// A surface's colour (linear RGB, the renderer's fallback) and material.
    struct Finish {
        var colour: (Double, Double, Double)
        var material: MaterialKey
    }

    let part: VesselPart
    /// Construction coordinates of the part's reference point.
    let construction: Vec3
    /// The CM's apex is a part of its own: draw the CM's forward deck and tunnel.
    let apexCovered: Bool
    /// The vehicle the part belongs to.
    let variant: ApolloVariant

    static let white = Finish(colour: (0.9, 0.9, 0.88), material: .apolloWhitePaint)
    static let dark = Finish(colour: (0.25, 0.25, 0.27), material: .apolloEngineBell)
    static let grey = Finish(colour: (0.72, 0.72, 0.74), material: .apolloGreyMetal)
    static let aluminium = Finish(colour: (0.78, 0.79, 0.8), material: .apolloSMAluminium)
    static let silver = Finish(colour: (0.82, 0.82, 0.84), material: .apolloCMFoil)
    static let ablator = Finish(colour: (0.45, 0.38, 0.3), material: .apolloAblator)
    static let nozzleExtension = Finish(colour: (0.6, 0.6, 0.62), material: .apolloSPSNozzle)
    static let gold = Finish(colour: (0.78, 0.62, 0.25), material: .apolloLMFoil)
    static let canvas = Finish(colour: (0.85, 0.8, 0.7), material: .apolloCanvas)

    static let body = D.bodyDiameter / 2 * D.inch, upper = D.sIVBDiameter / 2 * D.inch
    static let csmRadius = D.csmDiameter / 2 * D.inch
    static let lesTip = D.station(D.baseStation) + D.overallHeight * D.foot

    /// The part's shapes and attachments, from the first element that
    /// knows its name; nil when none does.
    func dress() -> (shapes: [VisualShape], attachments: [VisualAttachment])? {
        typealias Element = (shapes: () -> [VisualShape]?, attachments: () -> [VisualAttachment])
        let elements: [Element] = [(sICShapes, sICAttachments), (sIIShapes, sIIAttachments),
                                   (sIVBShapes, sIVBAttachments), (slaShapes, slaAttachments),
                                   (smShapes, smAttachments), (cmShapes, cmAttachments), (lesShapes, lesAttachments)]
        for element in elements {
            if let shapes = element.shapes() { return (shapes, element.attachments()) }
        }
        return nil
    }

    /// Construction x (m) of Apollo station `xa` (in).
    func xa(_ xa: Double) -> Double { D.apolloStation(xa) }
    /// Construction x (m) of a point `x` inches above the CM's heat-shield face.
    func cm(_ x: Double) -> Double { xa(S.cmFace + x) }
    /// Part-frame point of construction coordinates `c`.
    func local(_ c: Vec3) -> Vec3 { c - construction }

    /// `s` in `finish`, its surface in the vehicle's frame when it turns
    /// about the vehicle's axis and `vehicleFrame` allows (engines and
    /// nozzles keep their own).
    func finished(_ s: VisualShape, _ finish: Finish, vehicleFrame: Bool = true) -> VisualShape {
        var s = s
        s.color = finish.colour
        s.material = finish.material
        let c = s.origin + construction
        if vehicleFrame && abs(s.axis.x) > 1 - 1e-12 && (c.y * c.y + c.z * c.z).squareRoot() < 1e-9 {
            s.surfaceFrame = .vehicle(partOrigin: construction)
        }
        return s
    }

    /// A frustum along +x from construction x `bottom` to `top`, off the axis
    /// by (`y`, `z`); `open` leaves both ends open and draws both faces.
    func frustum(_ bottom: Double, _ top: Double, _ r0: Double, _ r1: Double, _ finish: Finish,
                 y: Double = 0, z: Double = 0, open: Bool = false) -> VisualShape {
        var s = finished(VisualShape.frustum(from: local(Vec3(bottom, y, z)), length: top - bottom, baseRadius: r0,
                                             topRadius: r1, color: finish.colour), finish)
        if open { s.capBase = false; s.capTop = false; s.twoSided = true }
        return s
    }

    /// A surface of revolution along `axis` from the construction point `at`.
    func revolution(_ profile: [P], at: Vec3, axis: Vec3 = .unitX, reference: Vec3? = nil, segments: Int = 48,
                    sweep: ClosedRange<Double> = 0...(2 * Double.pi), _ finish: Finish) -> VisualShape {
        finished(.revolution(profile, from: local(at), axis: axis, reference: reference, segments: segments,
                             sweep: sweep, color: finish.colour), finish)
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
    func bells(exit: Double, exitArea: Double, areaRatio: Double, _ finish: Finish) -> [VisualShape] {
        part.thrusters.filter { $0.groups.contains(.main) }.map { t in
            let gimbal = t.position.x + construction.x
            var s = finished(VisualShape.revolution(ApolloDresser.bell(exitRadius: (exitArea / Double.pi).squareRoot(),
                                                                       areaRatio: areaRatio, length: gimbal - exit),
                                                    from: Vec3(exit - construction.x, t.position.y, t.position.z),
                                                    color: finish.colour), finish, vehicleFrame: false)
            s.capBase = false
            s.twoSided = true
            s.thruster = t.name
            return s
        }
    }

    // MARK: Attachments

    /// The ports of the part's solid motors whose names hold `motor`
    /// ("retro", "ullage"), as `kind`, the exhaust leaving against the
    /// thrust. Each sits at its motor's thrust point (the thruster's
    /// position, at its grain), not yet at the nozzle exit downstream of
    /// it: the motors' lengths and exit radii (0 here) wait for VD1.
    func solidMotorPorts(_ motor: String, _ kind: VisualAttachment.Kind) -> [VisualAttachment] {
        part.thrusters.filter { $0.isSolid && $0.name.contains(motor) }.map { t in
            VisualAttachment(name: t.name, kind: kind, position: t.position, direction: -t.direction, radius: 0,
                             thruster: t.name)
        }
    }

    /// The separation plane at construction x `x`, of radius `radius`, its
    /// normal along +x or -x (`up`) away from the part.
    func separationPlane(_ name: String, at x: Double, radius: Double, up: Bool) -> VisualAttachment {
        VisualAttachment(name: name, kind: .separationPlane, position: local(Vec3(x, 0, 0)),
                         direction: up ? .unitX : -Vec3.unitX, radius: radius)
    }
}
