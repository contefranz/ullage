import Foundation

// The SLA and what rides in it: Apollo 8's LTA-B and the LM stand-in
// (track VG3).

extension ApolloShapeData {
    // MARK: SLA (datasheet §12)

    /// The SLA, Xa 502-838 (28 ft, 260 to 154 in), is four fixed lower
    /// panels, the ring, under four upper panels hinged at their aft edges,
    /// numbered by 68-FM-160 as 1 at +Z_A, 2 at -Z_A, 3 at +Y_A and 4 at
    /// -Y_A, each a quarter turn about its axis, so that the four seams lie
    /// on the diagonals (TRN §6.3.6, M). The cone is 234.4 in across at the
    /// hinge line.
    static let slaHinge = 583.2                      // Xa, AOH Figs. 2.9-6, 2.9-10 "HINGE LINE XA = 583.2" (H)
    static let slaPanels: [(ya: Double, za: Double)] = [(0, 1), (0, -1), (1, 0), (-1, 0)]   // 68-FM-160 (H)
    /// The splice plates over the seams' detonating cord (0.060 in
    /// aluminium, TRN §6.2.2, M), a strip each panel carries half of, and
    /// the fixed panels' forward frame along the hinge line: their sizes are
    /// not found, wide enough to read at a CSM close-up (L).
    static let slaSpliceWidth = 4.0                  // in, both halves, estimate (L)
    static let slaSpliceHeight = 0.4                 // in above the skin, estimate (L)
    static let slaHingeFrameHeight = 2.0             // in along the cone, estimate (L)
    static let slaHingeFrameDepth = 0.4              // in above the skin, estimate (L)

    // MARK: LTA-B (datasheet §13)
    //
    // Apollo 8's 19,900 lb test article, as AS08-16-2582..2584 show it
    // (all L): a white drum low in the SLA, a broad flange of segments round
    // its open forward face, a recessed deck crossed by a "#" of paired
    // beams with a round fitting in the middle bay, hung on four V-strut
    // pairs from the fixed panels' rim at the LM support points (±Y_A,
    // ±Z_A, CNR08 p. 66, M).

    static let ltaBBase = 509.0                      // Xa, A8MR Fig. A.5-1, scaled (L)
    static let ltaBFace = 635.0                      // Xa, A8MR Fig. A.5-1 and the photos' 630-655 (L)
    static let ltaBFlangeDiameter = 160.0            // in, from the three photos (L)
    static let ltaBDrumDiameter = 136.0              // in, estimate (L): the flange "broad" in the photos
    static let ltaBFlangeDepth = 4.0                 // in, estimate (L)
    static let ltaBWall = 4.0                        // in, the drum's wall at its face, estimate (L)
    static let ltaBDeckDepth = 10.0                  // in under the face, estimate (L)
    static let ltaBFlangeSegments = 16               // estimate (L)
    static let ltaBBeamWidth = 6.0                   // in, estimate (L)
    static let ltaBBeamDepth = 8.0                   // in, estimate (L)
    static let ltaBHubRadius = 12.0                  // in, estimate (L)
    static let ltaBHubHeight = 6.0                   // in, estimate (L)
    static let ltaBStrutAzimuths = [0.0, 90.0, 180.0, 270.0]   // deg θ_A: the LM support points (M)
    static let ltaBStrutSpread = 20.0                // deg either side at the drum, estimate (L)
    static let ltaBStrutFoot = 600.0                 // Xa, where the struts meet the drum, estimate (L)
    static let ltaBStrutRadius = 2.0                 // in, estimate (L)
    static let ltaBStrutInset = 2.0                  // in inside the SLA's skin at the rim, estimate (L)

    // MARK: LM, crude
    //
    // Inside `AS506`'s stowed envelope (h 85.9-90.9 m, radius 2.1 m, L): an
    // octagonal descent stage, an ascent stage and its docking tunnel, as
    // shares of the envelope's height. Estimates (L).

    static let lmDescentShare = 0.35
    static let lmAscentShare = 0.9
    static let lmAscentRadius = 1.3                  // m, estimate (L)
    static let lmTunnelRadius = 0.42                 // m, estimate (L)
}

extension MaterialKey {
    // The SLA's and LTA-B's finishes (track VG3).
    public static let apolloSLACork: MaterialKey = "apollo.sla.cork"
    public static let apolloSLASeam: MaterialKey = "apollo.sla.seam"
    public static let apolloLTAB: MaterialKey = "apollo.ltab"
}

extension ApolloDresser {
    static let slaCork = Finish(colour: (0.9, 0.9, 0.88), material: .apolloSLACork)
    static let slaSeam = Finish(colour: (0.84, 0.84, 0.82), material: .apolloSLASeam)
    static let ltaB = Finish(colour: (0.86, 0.86, 0.85), material: .apolloLTAB)

    func slaShapes() -> [VisualShape]? {
        let name = part.name
        switch name {
        case "SLA":
            return slaRing() + (1...4).flatMap(slaPanel)
        case "SLA ring":
            return slaRing()
        case "LM":
            // Apollo 8's payload keeps the contract name.
            switch variant.payload {
            case .ltaB: return ltaB()
            case .lm: return lm()
            case .empty: return []
            }
        default:
            if name.hasPrefix("SLA panel "), let n = Int(name.dropFirst("SLA panel ".count)), (1...4).contains(n) {
                return slaPanel(n)
            }
            return nil
        }
    }

    func slaAttachments() -> [VisualAttachment] { [] }

    /// The SLA's radius (m) at Apollo station `station`, from the IU's top
    /// (Xa 502) to the SM's aft bulkhead.
    func slaRadius(_ station: Double) -> Double {
        let base = D.iuTop - D.apolloStationOffset, r0 = ApolloDresser.upper, r1 = ApolloDresser.csmRadius
        return r0 + (r1 - r0) * (station - base) / (D.slaTop - base)
    }

    /// The fixed lower panels, open, and their forward frame along the hinge
    /// line.
    func slaRing() -> [VisualShape] {
        let base = D.iuTop - D.apolloStationOffset, inch = D.inch
        var ring = revolution([P(0, slaRadius(base)), P(xa(S.slaHinge) - xa(base), slaRadius(S.slaHinge))],
                              at: Vec3(xa(base), 0, 0), segments: 96, ApolloDresser.slaCork)
        ring.capBase = false
        ring.capTop = false
        ring.twoSided = true
        // The frame stands proud of the skin below the hinge line, its lips
        // sunk into the skin.
        let x0 = S.slaHinge - S.slaHingeFrameHeight, h = S.slaHingeFrameDepth * inch, sink = 0.05 * inch
        let length = xa(S.slaHinge) - xa(x0)
        var frame = revolution([P(0, slaRadius(x0) - sink, crease: true), P(0, slaRadius(x0) + h, crease: true),
                                P(length, slaRadius(S.slaHinge) + h, crease: true),
                                P(length, slaRadius(S.slaHinge) - sink, crease: true)],
                               at: Vec3(xa(x0), 0, 0), segments: 96, ApolloDresser.slaSeam)
        frame.capBase = false
        frame.capTop = false
        return [ring, frame]
    }

    /// Panel `n` (1-4): a quarter turn of the SLA's cone about its axis
    /// (first), and the halves of the splice plates along its two seams.
    func slaPanel(_ n: Int) -> [VisualShape] {
        typealias F = SpacecraftFrame
        let axis = S.slaPanels[n - 1], centre = ApolloAxes.direction(xa: 0, ya: axis.ya, za: axis.za)
        var panel = revolution([P(0, slaRadius(S.slaHinge)), P(xa(D.slaTop) - xa(S.slaHinge), slaRadius(D.slaTop))],
                               at: Vec3(xa(S.slaHinge), 0, 0), reference: centre, segments: 96,
                               sweep: -Double.pi / 4...Double.pi / 4, ApolloDresser.slaCork)
        panel.capBase = false
        panel.capTop = false
        panel.twoSided = true

        // The seams, a quarter turn either side of the panel's centre: each
        // half strip runs up the cone's generator, flat on it, into the panel.
        let inch = D.inch, theta = F.vehicleAzimuth(of: centre)
        let h = S.slaSpliceHeight * inch, sink = 0.05 * inch
        // The plate's own axis just outside the seam, clear of its outline.
        let gap = 0.1 * inch, half = S.slaSpliceWidth / 2 * inch
        let outline = [(0.0, gap), (1.0, gap), (1.0, gap + half), (0.0, gap + half)]
        let strips = [-1.0, 1.0].map { side -> VisualShape in
            let seam = theta + side * Double.pi / 4
            let bottom = Vec3(xa(S.slaHinge), 0, 0) + F.radial(seam) * slaRadius(S.slaHinge)
            let top = Vec3(xa(D.slaTop), 0, 0) + F.radial(seam) * slaRadius(D.slaTop)
            let along = (top - bottom).normalized, length = (top - bottom).length
            let inward = F.tangent(seam) * -side
            let normal = along.cross(inward).dot(F.radial(seam)) > 0 ? along.cross(inward) : inward.cross(along)
            let section = outline.map { VisualShape.SectionPoint($0.0 * length, $0.1, crease: true) }
            let origin = bottom + normal.normalized * (h / 2 - sink) - inward * gap
            return finished(.plate(section, at: local(origin), axis: along, reference: inward, thickness: h,
                                   color: ApolloDresser.slaSeam.colour), ApolloDresser.slaSeam)
        }
        return [panel] + strips
    }

    // MARK: LTA-B

    /// LTA-B: the drum and flange with its recessed deck, the "#" of beams
    /// and the round fitting on the deck, and the four V-strut pairs to the
    /// fixed panels' rim.
    func ltaB() -> [VisualShape] {
        typealias A = ApolloDresser
        typealias F = SpacecraftFrame
        let inch = D.inch, rd = S.ltaBDrumDiameter / 2, rf = S.ltaBFlangeDiameter / 2
        let height = S.ltaBFace - S.ltaBBase, flange = height - S.ltaBFlangeDepth
        let deck = height - S.ltaBDeckDepth, inner = rd - S.ltaBWall
        let drumProfile = [P(0, 0), P(0, rd, crease: true), P(height, rd, crease: true), P(height, inner, crease: true),
                           P(deck, inner, crease: true), P(deck, 0)]
        let drum = revolution(drumProfile.map { P($0.x * inch, $0.r * inch, crease: $0.crease) },
                              at: Vec3(xa(S.ltaBBase), 0, 0), segments: 64, A.ltaB)
        // The flange, its segments as facets; its inner face inside the drum.
        let lip = 0.05
        let flangeProfile = [P(flange, rd - 0.5), P(flange, rf), P(height + lip, rf), P(height + lip, rd - 0.5)]
        var ring = revolution(flangeProfile.map { P(($0.x - flange) * inch, $0.r * inch, crease: true) },
                              at: Vec3(xa(S.ltaBBase + flange), 0, 0), segments: S.ltaBFlangeSegments, A.ltaB)
        ring.faceted = true
        ring.capBase = false
        ring.capTop = false

        // The beams: two each way, a third of the deck's width apart.
        var shapes = [drum, ring]
        let offset = inner / 3, span = 2 * (inner * inner - offset * offset).squareRoot()
        let mid = S.ltaBFace - S.ltaBDeckDepth + S.ltaBBeamDepth / 2
        for (a, b) in [(Vec3.unitY, Vec3.unitZ), (Vec3.unitZ, Vec3.unitY)] {
            for sign in [1.0, -1.0] {
                let start = Vec3(xa(mid), 0, 0) + b * (sign * offset * inch) - a * (span / 2 * inch)
                shapes.append(finished(.box(from: local(start), length: span * inch, width: S.ltaBBeamDepth * inch,
                                            height: S.ltaBBeamWidth * inch, axis: a, reference: .unitX,
                                            color: A.ltaB.colour), A.ltaB))
            }
        }
        let deckX = S.ltaBFace - S.ltaBDeckDepth
        shapes.append(revolution([P(0, 0), P(0, S.ltaBHubRadius * inch, crease: true),
                                  P(S.ltaBHubHeight * inch, S.ltaBHubRadius * inch, crease: true),
                                  P(S.ltaBHubHeight * inch, 0)],
                                 at: Vec3(xa(deckX - 0.5), 0, 0), segments: 32, A.ltaB))

        // The struts: from each support point inside the rim to the drum's
        // wall either side of it.
        let rim = slaRadius(S.slaHinge) - S.ltaBStrutInset * inch
        for azimuth in S.ltaBStrutAzimuths {
            let theta = F.theta(apollo: azimuth)
            let top = Vec3(xa(S.slaHinge), 0, 0) + F.radial(theta) * rim
            for side in [-1.0, 1.0] {
                let foot = Vec3(xa(S.ltaBStrutFoot), 0, 0)
                    + F.radial(theta + side * S.ltaBStrutSpread * F.degree) * (rd * inch)
                shapes.append(scTube(foot, top, radius: S.ltaBStrutRadius * inch, A.ltaB))
            }
        }
        return shapes
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
}

extension SpacecraftFrame {
    /// The vehicle azimuth (rad) of the construction direction `d`.
    static func vehicleAzimuth(of d: Vec3) -> Double { VisualShape.vehicleAzimuth(y: d.y, z: d.z) }
}
