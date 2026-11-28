import Foundation

/// A turbulent field drawn as octaves of noise, with the inertial range's
/// spectrum (look round 2, LR3; shared with LR4's launch turbulence): the
/// largest octave's cells are the integral-scale eddies, and each finer
/// octave halves the cell.
///
/// - **Amplitudes 2^(−k/3).** In the inertial range a velocity increment
///   over a separation ℓ, and a passive scalar's (the exhaust's share, its
///   temperature's excess), scales as ℓ^(1/3) (Kolmogorov 1941; Obukhov
///   1949 and Corrsin 1951 for the scalar), so the second-order structure
///   function goes as ℓ^(2/3) and the spectrum as k^(−5/3). Octave k, of
///   cell ℓ0 2^(−k), holds the variance between its scale and the next:
///   its amplitude is 2^(−k/3) of the largest's.
/// - **Lifetimes τ0 2^(−2k/3).** An eddy of size ℓ turns over in ℓ/u_ℓ ∝
///   ℓ^(2/3): the small eddies renew faster, by 2^(2/3) an octave.
/// - **The footprint's cut-off.** A pixel averages what is smaller than its
///   footprint away, so an octave is drawn only where its cell spans enough
///   of the pixel's footprint: in full from `cutoffHigh` footprints, faded
///   out to none at `cutoffLow` (P2's plume noise's fade, L). The field
///   then holds the variance the pixel resolves (`resolvedVariance`), not a
///   noise aliased below it; finer octaves appear as the camera closes in.
///
/// Pure Swift and Foundation: the shaders mirror these few lines.
public struct TurbulenceSpectrum: Equatable, Sendable {
    /// The largest octave's cell ℓ0 (m): the integral-scale eddies.
    public var largestCell: Double
    /// Its layers' lifetime τ0 (s): the integral-scale eddies' turnover.
    public var largestLifetime: Double
    /// The most octaves ever drawn (a quality tier's cap).
    public var maximumOctaves: Int

    public init(largestCell: Double, largestLifetime: Double, maximumOctaves: Int = 8) {
        self.largestCell = largestCell
        self.largestLifetime = largestLifetime
        self.maximumOctaves = max(maximumOctaves, 1)
    }

    // MARK: The inertial range

    /// The exponent of an increment's scaling with its separation, ℓ^(1/3)
    /// (Kolmogorov 1941), H.
    public static let incrementExponent = 1.0 / 3
    /// The second-order structure function's, ℓ^(2/3), H.
    public static let structureFunctionExponent = 2.0 / 3
    /// The turnover time's, ℓ^(2/3), H.
    public static let turnoverExponent = 2.0 / 3

    /// Octave k's amplitude over the largest's: 2^(−k/3).
    public static func amplitude(octave k: Int) -> Double {
        pow(2, -incrementExponent * Double(k))
    }

    /// The variance every octave together holds, over the largest's:
    /// Σ 2^(−2k/3) = 1/(1 − 2^(−2/3)), about 2.70.
    public static let totalVariance = 1 / (1 - pow(2, -structureFunctionExponent))

    /// Octave k's cell (m): ℓ0 2^(−k).
    public func cell(octave k: Int) -> Double { largestCell * pow(2, -Double(k)) }

    /// Octave k's lifetime (s): τ0 2^(−2k/3).
    public func lifetime(octave k: Int) -> Double { largestLifetime * pow(2, -Self.turnoverExponent * Double(k)) }

    // MARK: The footprint

    /// An octave is faded out where its cell spans fewer than `cutoffLow`
    /// pixel footprints and drawn in full from `cutoffHigh` (L: P2's fade,
    /// 1.5-4 half-resolution texels).
    public static let cutoffLow = 1.5, cutoffHigh = 4.0

    /// The weight of an octave of cell `cell` where a pixel's footprint is
    /// `footprint` (both m): 0 to 1, smoothly.
    public static func footprintWeight(cell: Double, footprint: Double) -> Double {
        guard footprint > 0 else { return 1 }
        let t = min(max((cell / footprint - cutoffLow) / (cutoffHigh - cutoffLow), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Octave k's weight at a pixel's footprint (m).
    public func weight(octave k: Int, footprint: Double) -> Double {
        k < maximumOctaves ? Self.footprintWeight(cell: cell(octave: k), footprint: footprint) : 0
    }

    /// How many octaves are worth evaluating at a pixel's footprint (m):
    /// those of some weight, at most `maximumOctaves` (none where even the
    /// largest is below the cut-off).
    public func octaves(footprint: Double) -> Int {
        guard footprint > 0 else { return maximumOctaves }
        // The octaves k whose cells span more than cutoffLow footprints:
        // 2^k < ℓ0 / (cutoffLow footprint).
        let n = log2(largestCell / (Self.cutoffLow * footprint)).rounded(.up)
        return n.isFinite ? min(max(Int(n), 0), maximumOctaves) : 0
    }

    /// The share of the turbulence's variance (every octave, without end)
    /// that the octaves drawn at a pixel's footprint hold, their weights
    /// included: 1 at most.
    public func resolvedVariance(footprint: Double) -> Double {
        var v = 0.0
        for k in 0..<octaves(footprint: footprint) {
            let w = weight(octave: k, footprint: footprint), a = Self.amplitude(octave: k)
            v += w * w * a * a
        }
        return v / Self.totalVariance
    }

    /// The field at a pixel's footprint (m), from each octave's own
    /// unit-variance noise `noise(k)` (called only for the octaves drawn):
    /// Σ w_k a_k n_k / √(Σ a_k²), so that with every octave drawn it has
    /// unit variance, and under the cut-off `resolvedVariance` of it.
    public func value(footprint: Double, noise: (Int) -> Double) -> Double {
        var total = 0.0
        for k in 0..<octaves(footprint: footprint) {
            let w = weight(octave: k, footprint: footprint)
            if w > 0 { total += w * Self.amplitude(octave: k) * noise(k) }
        }
        return total / Self.totalVariance.squareRoot()
    }

    /// The second-order structure function ⟨(f(x + r) − f(x))²⟩ of the field
    /// with every octave up to `octaves` drawn, each octave's noise having
    /// the correlation `correlation(r / cell)`: 2 Σ a_k² (1 − ρ(r/ℓ_k)) /
    /// Σ a_k². Over the octaves' span it rises as r^(2/3).
    public func structureFunction(separation r: Double, octaves n: Int,
                                  correlation: (Double) -> Double) -> Double {
        var d = 0.0
        for k in 0..<max(n, 0) {
            let a = Self.amplitude(octave: k)
            d += 2 * a * a * (1 - correlation(r / cell(octave: k)))
        }
        return d / Self.totalVariance
    }
}
