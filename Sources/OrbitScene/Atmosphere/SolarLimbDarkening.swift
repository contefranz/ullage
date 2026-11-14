import Foundation
import OrbitCore

/// The Sun's limb darkening by wavelength: Hestroffer and Magnan's (1998,
/// A&A 333:338) one-parameter law I(μ)/I(1) = μ^α, fitted to Pierce and
/// Slaughter (1977) and Neckel and Labs (1994) between 416 and 1,099 nm,
/// with α(λ) = −0.023 + 0.292 / λ (λ in µm). μ is the cosine of the angle
/// between the line of sight and the solar surface's normal: 1 at the
/// disc's centre, 0 at its edge.
///
/// At A1's three wavelengths (`Spectrum3`: 680, 550, 440 nm) α is 0.406,
/// 0.508 and 0.641: the limb is redder than the centre. At 550 nm the
/// centre is 1.254 times the disc's mean, which R1's linear law (u = 0.6,
/// `Photometry.solarLimbDarkening`: 1.25) matches.
public enum SolarLimbDarkening {
    /// The exponent α at `wavelength` (m).
    public static func exponent(wavelength: Double) -> Double {
        -0.023 + 0.292 / (wavelength * 1e6)
    }

    /// α at A1's three wavelengths.
    public static let exponents = OpticalAtmosphere.wavelengths.map(exponent)

    /// I(μ)/I(1) for exponent `alpha`.
    public static func intensity(cosine mu: Double, alpha: Double) -> Double {
        pow(min(max(mu, 0), 1), alpha)
    }

    /// The disc's mean intensity over its centre's, 2/(α + 2): the integral
    /// of μ^α over the disc's area (2 ∫ μ^α μ dμ).
    public static func meanOverCentre(alpha: Double) -> Double {
        2 / (alpha + 2)
    }

    /// The intensity at angular distance `theta` from the centre of a disc
    /// of angular radius `radius`, over the disc's mean, per channel: what
    /// multiplies the mean luminance E⊙/Ω⊙ (and its colour) to give the
    /// disc's luminance there; 0 off the disc.
    public static func relativeLuminance(angle theta: Double, angularRadius radius: Double) -> Spectrum3 {
        guard theta < radius else { return .zero }
        // The sphere seen from far: sin of the angle from the centre over
        // that of the radius is the sine of the angle at the surface.
        let s = sin(theta) / sin(radius)
        let mu = max(0, 1 - s * s).squareRoot()
        return exponents.map { intensity(cosine: mu, alpha: $0) / meanOverCentre(alpha: $0) }
    }
}
