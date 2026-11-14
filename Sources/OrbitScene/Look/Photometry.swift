import Foundation

/// Photometric units for the HDR renderer: the scene is linear light in
/// luminance (cd/m²) and illuminance (lux), in linear Rec. 709 primaries
/// (track R1; docs/look/units-and-exposure.md records each value and its
/// grade).
///
/// Colours of thermal sources (the Sun, stars, the heat shield's glow) come
/// from Planck's law integrated against the CIE 1931 2° colour-matching
/// functions, in the multi-lobe Gaussian fits of Wyman, Sloan and Shirley
/// (2013, JCGT 2(2)), so no licensed CIE table is needed.
public enum Photometry {
    // MARK: Constants

    /// The astronomical unit, m (IAU 2012).
    public static let astronomicalUnit = 149_597_870_700.0
    /// The Sun's illuminance at 1 AU above the atmosphere, lux: the luminous
    /// solar constant of Darula, Kittler and Gueymard (2005, Solar Energy
    /// 79(5):559-565) for the CIE V(λ) photopic curve, 133.334 klx (134.108
    /// klx with the 1988 V_M(λ)). Earlier values span 127.5-133.8 klx.
    public static let solarIlluminanceAt1AU = 133_334.0
    /// The Sun's nominal radius, m (IAU 2015 Resolution B3).
    public static let solarRadius = 695_700_000.0
    /// The Sun's nominal effective temperature, K (IAU 2015 Resolution B3).
    public static let solarTemperature = 5_772.0
    /// Linear limb darkening of the Sun's disc in the visible, L(μ) = L₀(1 - u(1 - μ))
    /// (Allen's Astrophysical Quantities, u ≈ 0.56-0.62 between 500 and 600 nm).
    public static let solarLimbDarkening = 0.6
    /// The maximum luminous efficacy of radiation, lm/W (SI, 540 THz).
    public static let luminousEfficacy = 683.0
    /// Planck's radiation constants for spectral radiance: c₁L = 2hc²
    /// (W m² / sr) and c₂ = hc/k (m K), from the 2019 SI exact h, c and k.
    public static let c1L = 2 * 6.626_070_15e-34 * 299_792_458.0 * 299_792_458.0
    public static let c2 = 6.626_070_15e-34 * 299_792_458.0 / 1.380_649e-23

    // MARK: The Sun

    /// The Sun's illuminance at `distance` (m) from it, lux.
    public static func solarIlluminance(distance: Double) -> Double {
        let au = distance / astronomicalUnit
        return solarIlluminanceAt1AU / max(au * au, 1e-12)
    }

    /// The Sun's angular radius seen from `distance` (m), rad: 0.2665° at 1 AU.
    public static func solarAngularRadius(distance: Double) -> Double {
        asin(min(1, solarRadius / max(distance, solarRadius)))
    }

    /// The solid angle of a disc of angular radius `alpha`, sr.
    public static func discSolidAngle(angularRadius alpha: Double) -> Double {
        2 * Double.pi * (1 - cos(alpha))
    }

    /// The Sun's mean luminance over its disc, cd/m²: its illuminance over
    /// the disc's solid angle, the same at any distance (1.96e9 cd/m²).
    public static var solarLuminance: Double {
        let alpha = solarAngularRadius(distance: astronomicalUnit)
        return solarIlluminanceAt1AU / discSolidAngle(angularRadius: alpha)
    }

    /// The luminance at the centre of the disc over the disc's mean, for the
    /// linear limb darkening (the mean of 1 - u(1 - μ) over the disc is 1 - u/3).
    public static var solarCentreOverMean: Double { 1 / (1 - solarLimbDarkening / 3) }

    /// The Sun's colour, linear Rec. 709 with a luminance of 1: a 5772 K
    /// blackbody, about (1.11, 0.976, 0.912).
    public static let sunColor = blackbody(solarTemperature).color

    // MARK: Colour matching

    /// The CIE 1931 2° colour-matching functions x̄, ȳ, z̄ at `nm`, from the
    /// multi-lobe fits of Wyman, Sloan and Shirley (2013).
    public static func colorMatching(_ nm: Double) -> (x: Double, y: Double, z: Double) {
        func g(_ mu: Double, _ s1: Double, _ s2: Double) -> Double {
            let t = (nm - mu) / (nm < mu ? s1 : s2)
            return exp(-0.5 * t * t)
        }
        let x = 1.056 * g(599.8, 37.9, 31.0) + 0.362 * g(442.0, 16.0, 26.7) - 0.065 * g(501.1, 20.4, 26.2)
        let y = 0.821 * g(568.8, 46.9, 40.5) + 0.286 * g(530.9, 16.3, 31.1)
        let z = 1.217 * g(437.0, 11.8, 36.0) + 0.681 * g(459.0, 26.0, 13.8)
        return (x, y, z)
    }

    /// Planck's spectral radiance of a full radiator at `kelvin`, W/(m² sr m)
    /// at a wavelength of `metres` (with radiation constant `c2`).
    public static func planck(wavelength metres: Double, kelvin: Double, c2: Double = Photometry.c2) -> Double {
        let e = c2 / (metres * kelvin)
        return c1L / pow(metres, 5) / (e > 700 ? .infinity : expm1(e))
    }

    /// CIE XYZ of a full radiator at `kelvin`: Y is its luminance, cd/m²
    /// (683 lm/W times radiance weighted by ȳ, 360-830 nm in 1 nm steps).
    /// `c2` may be set to an older radiation constant, as in the definition
    /// of illuminant A (1.435e-2 m K).
    public static func blackbodyXYZ(_ kelvin: Double, c2: Double = Photometry.c2) -> (x: Double, y: Double, z: Double) {
        var x = 0.0, y = 0.0, z = 0.0
        for nm in 360...830 {
            let b = planck(wavelength: Double(nm) * 1e-9, kelvin: kelvin, c2: c2)
            let m = colorMatching(Double(nm))
            x += b * m.x
            y += b * m.y
            z += b * m.z
        }
        let k = luminousEfficacy * 1e-9
        return (x * k, y * k, z * k)
    }

    /// A full radiator: its luminance (cd/m²), chromaticity, and colour in
    /// linear Rec. 709 with a luminance of 1 (out-of-gamut reds clipped to
    /// the gamut, keeping the luminance).
    public struct Blackbody {
        public var luminance: Double
        public var chromaticity: (x: Double, y: Double)
        public var color: RGB
    }

    public static func blackbody(_ kelvin: Double) -> Blackbody {
        guard kelvin > 1 else { return Blackbody(luminance: 0, chromaticity: (0, 0), color: RGB(1, 1, 1)) }
        let xyz = blackbodyXYZ(kelvin)
        let sum = xyz.x + xyz.y + xyz.z
        let chroma = sum > 0 ? (xyz.x / sum, xyz.y / sum) : (0, 0)
        let rgb = rec709(xyz).inGamut, y = rgb.luminance
        return Blackbody(luminance: xyz.y, chromaticity: chroma, color: y > 0 ? rgb.scaled(by: 1 / y) : RGB(1, 0, 0))
    }

    // MARK: Colour spaces

    /// Linear RGB, Double precision (OrbitScene's colours before they reach
    /// the GPU).
    public struct RGB: Equatable {
        public var r: Double, g: Double, b: Double

        public init(_ r: Double, _ g: Double, _ b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        /// The Rec. 709 luminance.
        public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

        public func scaled(by k: Double) -> RGB { RGB(r * k, g * k, b * k) }

        /// Negative components clipped, then scaled back to the same luminance.
        public var inGamut: RGB {
            let c = RGB(max(r, 0), max(g, 0), max(b, 0))
            let y = c.luminance
            return y > 0 ? c.scaled(by: luminance / y) : c
        }
    }

    /// CIE XYZ to linear Rec. 709 (sRGB primaries, D65 white; IEC 61966-2-1).
    public static func rec709(_ xyz: (x: Double, y: Double, z: Double)) -> RGB {
        RGB(3.240_454_2 * xyz.x - 1.537_138_5 * xyz.y - 0.498_531_4 * xyz.z,
            -0.969_266_0 * xyz.x + 1.876_010_8 * xyz.y + 0.041_556_0 * xyz.z,
            0.055_643_4 * xyz.x - 0.204_025_9 * xyz.y + 1.057_225_2 * xyz.z)
    }

    // MARK: Stars

    /// The illuminance of a star of visual magnitude 0, lux: E = E₀ 10^(-0.4 V)
    /// (Allen's Astrophysical Quantities, 2.54 µlx, i.e. V = -13.99 - 2.5 log₁₀ E).
    public static let magnitudeZeroIlluminance = 2.54e-6

    /// The illuminance at the observer from a star of V magnitude `v`, lux.
    public static func illuminance(visualMagnitude v: Double) -> Double {
        magnitudeZeroIlluminance * pow(10, -0.4 * v)
    }

    /// A star's effective temperature from its B-V colour index, K
    /// (Ballesteros 2012, EPL 97, 34008: a blackbody fit to main-sequence stars).
    public static func starTemperature(colorIndex bv: Double) -> Double {
        let b = min(max(bv, -0.4), 2.0)
        return 4_600 * (1 / (0.92 * b + 1.7) + 1 / (0.92 * b + 0.62))
    }

    // MARK: Glow

    /// Stefan-Boltzmann's constant, W/(m² K⁴).
    public static let stefanBoltzmann = 5.670_374_419e-8

    /// A surface glowing at radiative equilibrium under a heat flux `q`
    /// (W/m²) with emissivity `emissivity`: its temperature (K) and its
    /// luminance in linear Rec. 709 (cd/m²), the emissivity times a full
    /// radiator's (a grey body).
    public static func glow(heatFlux q: Double, emissivity: Double) -> (temperature: Double, luminance: RGB) {
        let t = pow(max(q, 0) / (emissivity * stefanBoltzmann), 0.25)
        guard t > 500 else { return (t, RGB(0, 0, 0)) }
        let bb = blackbody(t)
        return (t, bb.color.scaled(by: bb.luminance * emissivity))
    }
}
