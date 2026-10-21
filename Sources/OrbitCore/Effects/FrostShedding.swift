import Foundation

/// The pad frost on AS-506's cryogenic stages and its shedding through the
/// S-IC burn, for the frost overlay and the ice particles: FER Table 20-1's
/// frost masses at first motion and at CECO (H), shed as a burst at first
/// motion and an exponential decay after it, whose shape is assumed (L) and
/// whose integral to CECO is the table's exactly. Times are seconds from
/// first motion (simulation time in the Apollo 11 scenario). Visual only:
/// the vehicle model carries the frost as dry mass on the S-IC to its
/// separation (AS506Data `sIIFrostAndPurge`, `sIVBFrost`).
public enum FrostShedding {
    /// A stage's frosted band (its LOX and LH2 tank walls and lines).
    public enum Band: String, CaseIterable {
        case sIC = "S-IC", sII = "S-II", sIVB = "S-IVB"
    }

    /// Frost at first motion and at CECO, kg (FER Table 20-1, read from the
    /// page images, H): the S-IC's 635 and 340; the S-II's 204 and the
    /// S-IVB's 90, all of it gone by CECO.
    public static func initialMass(_ band: Band) -> Double {
        switch band {
        case .sIC: return 635
        case .sII: return 204
        case .sIVB: return 90
        }
    }

    public static func massAtCutoff(_ band: Band) -> Double {
        band == .sIC ? 340 : 0
    }

    /// From first motion to AS-506's CECO, 135.20 s range time, s.
    public static let cutoffTime = AS506.sICCenterCutoff - AS506.firstMotion
    /// The share of each band's shedding to CECO that goes at first motion
    /// (the ignition and release shake it off), and the decay time of the
    /// rest (L: tuned by eye to the launch films).
    public static let burstShare = 0.2
    public static let decayTime = 30.0
    /// The shed mass's split (L): 80 % fine flakes 1-5 mm across, which drag
    /// slows and the air sublimates, and 20 % slabs 2-30 cm, which tumble.
    public static let flakeShare = 0.8
    public static let flakeDiameters = 0.001...0.005
    public static let slabSizes = 0.02...0.30
    /// Above about 40 km the shed ice that survives glints in the sun: the
    /// "fireflies".
    public static let fireflyAltitude = 40_000.0

    /// The share of a band's shedding to CECO done by `t`: the burst at t ≥
    /// 0, then the decay, normalised to reach 1 at CECO and held after.
    public static func shedShare(at t: Double) -> Double {
        guard t >= 0 else { return 0 }
        guard t < cutoffTime else { return 1 }
        let norm = -expm1(-cutoffTime / decayTime)
        return burstShare + (1 - burstShare) * -expm1(-t / decayTime) / norm
    }

    /// Frost on `band` at `t`, kg.
    public static func remainingMass(_ band: Band, at t: Double) -> Double {
        let m0 = initialMass(band)
        return m0 - (m0 - massAtCutoff(band)) * shedShare(at: t)
    }

    /// Frost on `band` at `t` over its frost at first motion: the overlay's
    /// strength.
    public static func remainingFraction(_ band: Band, at t: Double) -> Double {
        remainingMass(band, at: t) / initialMass(band)
    }

    /// Mass shed from `band` between `t0` and `t1` (t0 ≤ t1), kg: the burst
    /// with it when the interval holds first motion, so an emitter
    /// integrating frame intervals sheds the table's mass at any warp.
    public static func shedMass(_ band: Band, from t0: Double, to t1: Double) -> Double {
        remainingMass(band, at: t0) - remainingMass(band, at: t1)
    }

    /// The decay's shedding rate at `t` (the burst left out), kg/s.
    public static func shedRate(_ band: Band, at t: Double) -> Double {
        guard t > 0 && t < cutoffTime else { return 0 }
        let norm = -expm1(-cutoffTime / decayTime)
        let shed = initialMass(band) - massAtCutoff(band)
        return shed * (1 - burstShare) * exp(-t / decayTime) / (decayTime * norm)
    }
}
