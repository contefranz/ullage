import Foundation

/// The frost on the Saturn V's cryogenic tanks, on the pad and through the
/// S-IC's burn, from AS-506's FER Table 20-1 (read from the page images,
/// document page 20-2, H; docs/AS506-datasheet.md §17): the S-IC carried
/// 635 kg at first motion and 340 kg at CECO, the S-II 204 kg and the S-IVB
/// 90 kg, both gone by CECO. The model's masses book them the same way
/// (`AS506.sIIFrostAndPurge`, `sIVBFrost`, the S-IC's first-motion mass).
///
/// Each stage's frost lies on its zones (`zones`): bands of skin over its
/// cryogenic tanks, each with a weight. Its areal density at a station is
/// the stage's frost mass over the zones' weighted area, times the weight
/// there, so it integrates over the skin to the table's mass at any time.
/// `coverage`, the overlay's strength, is that density over the S-IC LOX
/// tank's at first motion (`fullCoverageDensity`), the heaviest frost on
/// the vehicle: so the overlay is one scale for every stage, and a stage
/// whose frost is spread thinner (the S-IVB's) reads lighter. AS-503's
/// frost was not tabled here: Apollo 8 uses AS-506's (L).
public enum Frost {
    public enum Stage: String, CaseIterable {
        case sIC = "S-IC", sII = "S-II", sIVB = "S-IVB"
    }

    /// Range time (s) of first motion (hold-down release) and of the S-IC's
    /// centre-engine cutoff on AS-506 (SP-4029 Apollo 11 Timeline, H; as
    /// `AS506.firstMotion` and `AS506.sICCenterCutoff`).
    public static let firstMotion = 0.30
    public static let centreCutoff = 135.20

    /// Frost aboard at first motion and at CECO, kg (FER Table 20-1, H).
    public static func tableMass(_ stage: Stage) -> (firstMotion: Double, cutoff: Double) {
        switch stage {
        case .sIC: return (635, 340)
        case .sII: return (204, 0)
        case .sIVB: return (90, 0)
        }
    }

    /// Frost aboard `stage` at range time `time` (s): the first-motion mass
    /// on the pad, shed linearly to CECO (as the S-IC's thrust level was
    /// fitted, datasheet §17.3 item 3), the CECO mass after it. The S-IC's
    /// remaining 340 kg leave with it at separation.
    public static func mass(_ stage: Stage, time: Double) -> Double {
        let m = tableMass(stage)
        let t = max(0, min(1, (time - firstMotion) / (centreCutoff - firstMotion)))
        return m.firstMotion + (m.cutoff - m.firstMotion) * t
    }

    /// The rate frost leaves `stage` at range time `time`, kg/s (positive).
    public static func shedRate(_ stage: Stage, time: Double) -> Double {
        guard time > firstMotion, time < centreCutoff else { return 0 }
        let m = tableMass(stage)
        return (m.firstMotion - m.cutoff) / (centreCutoff - firstMotion)
    }

    /// A band of skin that holds frost: STA `stations` (in) at `radius`
    /// (in), weighted `weight`, the weight ramping from 0 over `rampLow`
    /// inches above its foot and over `rampHigh` below its top.
    public struct Zone: Equatable {
        public var stage: Stage
        public var name: String
        public var stations: ClosedRange<Double>
        public var radius: Double
        public var weight: Double
        public var rampLow: Double
        public var rampHigh: Double
        public var grade: MarkingGrade

        /// The weight at STA `station`, 0 off the band.
        public func weight(at station: Double) -> Double {
            guard stations.contains(station) else { return 0 }
            var w = weight
            if rampLow > 0 { w *= min(1, (station - stations.lowerBound) / rampLow) }
            if rampHigh > 0 { w *= min(1, (stations.upperBound - station) / rampHigh) }
            return w
        }

        /// ∫ weight dA over the band, m².
        public var weightedArea: Double {
            let inch = 0.0254
            let length = stations.upperBound - stations.lowerBound - (rampLow + rampHigh) / 2
            return 2 * Double.pi * radius * inch * weight * length * inch
        }
    }

    /// Where frost forms (stations: the VD1 datasheet's exterior bands, H),
    /// the bands design-vehicle-look.md names ("the S-IC LOX tank and lines,
    /// the S-II aft/LOX band, a light S-IVB band"):
    /// - S-IC: the LOX tank's exposed wall, STA 885.2-1420.3, bare
    ///   aluminium wetted by LOX inside (M503 p. 4-1; frost hides the flags
    ///   there in AS-506's launch-day photos, as506.csv 506-112), weight 1
    ///   (M); the intertank below it, STA 628.8-885.2, round the LOX tank's
    ///   aft dome (STA 772), frost-covered on AS-502 (as502.csv 502-011),
    ///   weight 0.5 (L);
    /// - S-II: its aft band over the LOX tank, from the aft skirt's foot
    ///   (STA 1760) to the top of the LOX ellipsoid (STA 1980; the
    ///   ellipsoid 1716-1980, AS506-datasheet.md §13, L), round the tank's
    ///   equator where the aft skirt meets the LH2 wall (STA 1890), not the
    ///   LH2 wall above it under its helium-purged foam (L: where the
    ///   204 kg lay is not sourced);
    /// - S-IVB: the tank's exposed wall, STA 2832-3100.56, insulated inside
    ///   (L). Its 90 kg over 135 m² come to about 0.67 kg/m², just over
    ///   half the S-IC LOX tank's 1.21: the light band.
    public static let zones: [Zone] = [
        Zone(stage: .sIC, name: "intertank", stations: 628.8...885.2, radius: 198, weight: 0.5,
             rampLow: 12, rampHigh: 0, grade: .low),
        Zone(stage: .sIC, name: "LOX tank", stations: 885.2...1420.3, radius: 198, weight: 1,
             rampLow: 0, rampHigh: 12, grade: .medium),
        Zone(stage: .sII, name: "aft LOX band", stations: 1760...1980, radius: 198, weight: 1,
             rampLow: 12, rampHigh: 12, grade: .low),
        Zone(stage: .sIVB, name: "tank", stations: 2832...3100.56, radius: 130, weight: 1,
             rampLow: 12, rampHigh: 12, grade: .low),
    ]

    /// The weighted area of `stage`'s zones, m².
    public static func weightedArea(_ stage: Stage) -> Double {
        zones.filter { $0.stage == stage }.reduce(0) { $0 + $1.weightedArea }
    }

    static let areas: [Stage: Double] = Dictionary(uniqueKeysWithValues: Stage.allCases.map { ($0, weightedArea($0)) })

    /// The zone at STA `station`, if any (the bands do not overlap but at
    /// their shared ends).
    public static func zone(at station: Double) -> Zone? {
        zones.last { $0.stations.contains(station) && $0.weight(at: station) > 0 } ?? zones.first { $0.stations.contains(station) }
    }

    /// Frost on the skin at STA `station` at range time `time`, kg/m².
    public static func arealDensity(station: Double, time: Double) -> Double {
        guard let z = zone(at: station), let area = areas[z.stage], area > 0 else { return 0 }
        return mass(z.stage, time: time) * z.weight(at: station) / area
    }

    /// The areal density (kg/m²) the overlay shows at full strength: the
    /// S-IC LOX tank's at first motion, about 1.21 kg/m², the heaviest
    /// frost on the vehicle.
    public static let fullCoverageDensity: Double = tableMass(.sIC).firstMotion / weightedArea(.sIC)

    /// The overlay's strength at STA `station` at range time `time`, 0 to
    /// 1: the frost's areal density there over `fullCoverageDensity`. On a
    /// band it falls as the stage's frost is shed (the share of its
    /// first-motion mass still aboard), and it is lighter where a stage's
    /// frost lies thinner: 1 on the S-IC LOX tank on the pad, 0.5 on the
    /// intertank, about 0.55 on the S-IVB.
    public static func coverage(station: Double, time: Double) -> Double {
        min(1, arealDensity(station: station, time: time) / fullCoverageDensity)
    }
}
