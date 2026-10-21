import Foundation

// The SLA and what rides in it (track VG3).

extension ApolloShapeData {
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
}

extension ApolloDresser {
    func slaShapes() -> [VisualShape]? {
        let name = part.name
        switch name {
        case "SLA":
            return slaRing() + (1...4).map(slaPanel)
        case "SLA ring":
            return slaRing()
        case "LM":
            return lm()
        default:
            if name.hasPrefix("SLA panel "), let n = Int(name.dropFirst("SLA panel ".count)), (1...4).contains(n) {
                return [slaPanel(n)]
            }
            return nil
        }
    }

    func slaAttachments() -> [VisualAttachment] { [] }

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
}
