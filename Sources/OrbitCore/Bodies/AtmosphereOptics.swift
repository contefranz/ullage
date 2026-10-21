import Foundation

/// A quantity at the atmosphere optics' three wavelengths, 680, 550 and
/// 440 nm: the red, green and blue channels (`OpticalAtmosphere.wavelengths`).
public struct Spectrum3: Equatable, CustomStringConvertible {
    /// 680 nm.
    public var r: Double
    /// 550 nm.
    public var g: Double
    /// 440 nm.
    public var b: Double

    @inlinable public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }
    @inlinable public init(repeating v: Double) {
        r = v; g = v; b = v
    }

    public static let zero = Spectrum3(repeating: 0)
    public static let one = Spectrum3(repeating: 1)

    @inlinable public static func + (a: Spectrum3, c: Spectrum3) -> Spectrum3 { Spectrum3(a.r + c.r, a.g + c.g, a.b + c.b) }
    @inlinable public static func - (a: Spectrum3, c: Spectrum3) -> Spectrum3 { Spectrum3(a.r - c.r, a.g - c.g, a.b - c.b) }
    @inlinable public static func * (a: Spectrum3, c: Spectrum3) -> Spectrum3 { Spectrum3(a.r * c.r, a.g * c.g, a.b * c.b) }
    @inlinable public static func / (a: Spectrum3, c: Spectrum3) -> Spectrum3 { Spectrum3(a.r / c.r, a.g / c.g, a.b / c.b) }
    @inlinable public static func * (a: Spectrum3, s: Double) -> Spectrum3 { Spectrum3(a.r * s, a.g * s, a.b * s) }
    @inlinable public static func * (s: Double, a: Spectrum3) -> Spectrum3 { Spectrum3(a.r * s, a.g * s, a.b * s) }
    @inlinable public static func / (a: Spectrum3, s: Double) -> Spectrum3 { Spectrum3(a.r / s, a.g / s, a.b / s) }
    @inlinable public static func += (a: inout Spectrum3, c: Spectrum3) { a = a + c }
    @inlinable public static func *= (a: inout Spectrum3, c: Spectrum3) { a = a * c }

    /// Each channel through `f`.
    @inlinable public func map(_ f: (Double) -> Double) -> Spectrum3 { Spectrum3(f(r), f(g), f(b)) }
    /// e^(-x) per channel: the transmittance of an optical depth (0 for an infinite one).
    @inlinable public var attenuation: Spectrum3 { Spectrum3(Foundation.exp(-r), Foundation.exp(-g), Foundation.exp(-b)) }
    @inlinable public var max: Double { Swift.max(r, Swift.max(g, b)) }
    @inlinable public var min: Double { Swift.min(r, Swift.min(g, b)) }

    public var description: String { String(format: "(%.6g, %.6g, %.6g)", r, g, b) }
}

/// The Earth's air as light sees it, for the sky, the Sun's colour and the
/// light on vessels (track A1; the renderer's half is A2). Three
/// constituents, each a function of altitude only, over a sphere of the
/// figure's equatorial radius up to `top` (100 km: the 1976 density above
/// it adds under 1e-6 of the optical depth):
///
/// - Rayleigh scattering by the air: Bodhaine et al. (1999) eq. 29's cross
///   section on the core's own number density, `atmosphere.state(altitude:)
///   .density` over M0/N_A (US-1976's M0 = 28.9644 g/mol), so the sky sits
///   on the same US-1976 or launch-day sounding the physics flies. The
///   phase function keeps the air's depolarisation, ρn = 0.0279 (Young 1980).
/// - Aerosol (Mie): an exponential of scale height 1.2 km and vertical
///   optical depth 0.1 at 550 nm, Ångström exponent 1.3, single-scattering
///   albedo 0.9 and Cornette-Shanks phase with g = 0.8 (all `Aerosol`, a
///   scenario parameter).
/// - Ozone absorption: a tent from 10 to 40 km peaking at 25 km, normalised
///   to a 300 DU column, with Serdyuchenko et al. (2014) cross sections at
///   233 K (`Ozone`).
///
/// Refraction is not modelled. Optical depths are integrated numerically
/// along straight rays by Gauss-Legendre quadrature on segments split at the
/// ray's lowest point, where the integrand peaks.
public struct OpticalAtmosphere {
    /// The three wavelengths, m: red, green, blue.
    public static let wavelengths = Spectrum3(680e-9, 550e-9, 440e-9)
    /// Avogadro's number, 1/mol (SI 2019).
    public static let avogadro = 6.02214076e23
    /// The Dobson unit, molecules/m²: 10 µm of the gas at 0 °C and 1 atm.
    public static let dobsonUnit = 2.6867e20
    /// Height of the optical atmosphere's top above the ground, m.
    public static let top = 100_000.0
    /// The air's depolarisation factor ρn (Young 1980, Appl. Opt. 19:3427).
    public static let depolarization = 0.0279

    /// The Rayleigh cross section per molecule (m²) of air with 360 ppm CO2
    /// at `wavelength` (m): Bodhaine, Wood, Dutton & Slusser (1999) eq. 29,
    /// σ(550 nm) = 4.5105e-27 cm².
    public static func rayleighCrossSection(wavelength: Double) -> Double {
        let l2 = (wavelength * 1e6) * (wavelength * 1e6)   // µm²
        let numerator: Double = 1.0455996 - 341.29061 / l2 - 0.90230850 * l2
        let denominator: Double = 1 + 0.0027059889 / l2 - 85.968563 * l2
        return numerator / denominator * 1e-32
    }

    /// The aerosol: an exponential layer with a power-law spectrum.
    public struct Aerosol: Equatable {
        /// Vertical optical depth at 550 nm (extinction).
        public var opticalDepth550: Double
        /// Scale height, m.
        public var scaleHeight: Double
        /// Ångström exponent α: τ ∝ λ^-α.
        public var angstromExponent: Double
        /// Single-scattering albedo, the same at every wavelength.
        public var singleScatteringAlbedo: Double
        /// Cornette-Shanks asymmetry parameter g.
        public var asymmetry: Double

        public init(opticalDepth550: Double = 0.1, scaleHeight: Double = 1_200, angstromExponent: Double = 1.3,
                    singleScatteringAlbedo: Double = 0.9, asymmetry: Double = 0.8) {
            self.opticalDepth550 = opticalDepth550
            self.scaleHeight = scaleHeight
            self.angstromExponent = angstromExponent
            self.singleScatteringAlbedo = singleScatteringAlbedo
            self.asymmetry = asymmetry
        }

        /// No aerosol.
        public static let none = Aerosol(opticalDepth550: 0)
    }

    /// The ozone layer: a tent of number density, zero below `peakAltitude
    /// - halfWidth` and above `peakAltitude + halfWidth`.
    public struct Ozone: Equatable {
        /// Column, Dobson units.
        public var column: Double
        /// Altitude of the peak, m.
        public var peakAltitude: Double
        /// Half the tent's base, m: its column is peak density × halfWidth.
        public var halfWidth: Double
        /// Absorption cross sections, m².
        public var crossSection: Spectrum3

        public init(column: Double = 300, peakAltitude: Double = 25_000, halfWidth: Double = 15_000,
                    crossSection: Spectrum3 = Ozone.serdyuchenko233K) {
            self.column = column
            self.peakAltitude = peakAltitude
            self.halfWidth = halfWidth
            self.crossSection = crossSection
        }

        /// Serdyuchenko et al. (2014, Atmos. Meas. Tech. 7:625) at 233 K,
        /// m²: the mean over λ ± 10 nm of their spectrum, from the 10 nm bin
        /// averages Bruneton (2017, BSD-3) tabulates for his atmosphere demo
        /// (670-690 nm: 1.473e-25 and 1.209e-25; 540-560: 3.091e-25 and
        /// 3.5e-25; 430-450: 8.451e-27 and 1.582e-26). The IUP Bremen
        /// archive itself could not be reached when this was written.
        public static let serdyuchenko233K = Spectrum3(1.341e-25, 3.2955e-25, 1.21355e-26)

        /// No ozone.
        public static let none = Ozone(column: 0)

        /// Number density at the peak, 1/m³.
        public var peakDensity: Double { column * OpticalAtmosphere.dobsonUnit / halfWidth }

        /// Number density at altitude `h` (m), 1/m³.
        @inlinable public func density(altitude h: Double) -> Double {
            peakDensity * Swift.max(0, 1 - abs(h - peakAltitude) / halfWidth)
        }
    }

    /// The scattering and absorption coefficients at one altitude, 1/m.
    public struct Medium: Equatable {
        public var rayleighScattering: Spectrum3
        public var aerosolScattering: Spectrum3
        public var aerosolExtinction: Spectrum3
        public var ozoneAbsorption: Spectrum3

        public var scattering: Spectrum3 { rayleighScattering + aerosolScattering }
        public var extinction: Spectrum3 { rayleighScattering + aerosolExtinction + ozoneAbsorption }
    }

    /// The figure whose equatorial radius is the ground of the optics.
    public let figure: Ellipsoid
    public let aerosol: Aerosol
    public let ozone: Ozone
    /// Rayleigh cross sections at the three wavelengths, m².
    public let rayleighCrossSection: Spectrum3
    /// Aerosol extinction at the ground, 1/m.
    public let aerosolExtinctionAtGround: Spectrum3
    /// The air's number density (1/m³) every `profileStep` metres from the
    /// ground to the top, from the atmosphere it was built on.
    let airDensityProfile: [Double]
    static let profileStep = 50.0

    /// Optics over `atmosphere` (US-1976 by default, or a launch day's
    /// sounding), on the `figure`'s equatorial sphere.
    public init(atmosphere: Atmosphere = USStandardAtmosphere1976(), figure: Ellipsoid = .wgs84,
                aerosol: Aerosol = Aerosol(), ozone: Ozone = Ozone()) {
        self.figure = figure
        self.aerosol = aerosol
        self.ozone = ozone
        let w = Self.wavelengths
        rayleighCrossSection = w.map(Self.rayleighCrossSection)
        let k = aerosol.opticalDepth550 / aerosol.scaleHeight
        let alpha = aerosol.angstromExponent
        aerosolExtinctionAtGround = w.map { k * pow($0 / 550e-9, -alpha) }
        let perKilogram = Self.avogadro / USStandardAtmosphere1976.molarMass
        let count = Int((Self.top / Self.profileStep).rounded()) + 1
        airDensityProfile = (0..<count).map { i in
            atmosphere.state(altitude: Double(i) * Self.profileStep).density * perKilogram
        }
    }

    /// The ground's radius, m: the figure's equatorial radius.
    public var bottomRadius: Double { figure.equatorialRadius }
    /// The optical top's radius, m.
    public var topRadius: Double { figure.equatorialRadius + Self.top }

    // MARK: The medium

    /// The air's number density at altitude `h` (m), 1/m³: linear between
    /// the profile's 50 m nodes, the ground's below it and 0 above the top.
    public func airNumberDensity(altitude h: Double) -> Double {
        airDensity(h)
    }

    func airDensity(_ h: Double) -> Double {
        let x = h / Self.profileStep
        if x <= 0 { return airDensityProfile[0] }
        let i = Int(x)
        if i >= airDensityProfile.count - 1 { return h > Self.top ? 0 : airDensityProfile[airDensityProfile.count - 1] }
        let f = x - Double(i)
        return airDensityProfile[i] + (airDensityProfile[i + 1] - airDensityProfile[i]) * f
    }

    /// Scattering and absorption at altitude `h` (m); nothing above the top.
    public func medium(altitude h: Double) -> Medium {
        guard h <= Self.top else { return Medium(rayleighScattering: .zero, aerosolScattering: .zero,
                                                 aerosolExtinction: .zero, ozoneAbsorption: .zero) }
        let air = airDensity(h)
        let aerosolFactor = exp(-Swift.max(h, 0) / aerosol.scaleHeight)
        let ext = aerosolExtinctionAtGround * aerosolFactor
        return Medium(rayleighScattering: rayleighCrossSection * air,
                      aerosolScattering: ext * aerosol.singleScatteringAlbedo,
                      aerosolExtinction: ext,
                      ozoneAbsorption: ozone.crossSection * ozone.density(altitude: h))
    }

    /// Extinction at altitude `h` (m), 1/m.
    public func extinction(altitude h: Double) -> Spectrum3 {
        guard h <= Self.top else { return .zero }
        let aerosolFactor = exp(-Swift.max(h, 0) / aerosol.scaleHeight)
        let rayleigh = rayleighCrossSection * airDensity(h)
        return rayleigh + aerosolExtinctionAtGround * aerosolFactor + ozone.crossSection * ozone.density(altitude: h)
    }

    // MARK: Phase functions

    /// The Rayleigh phase function (1/sr) for scattering angle θ, with the
    /// air's depolarisation (Chandrasekhar 1950): 3/(16π(1+2γ)) ×
    /// ((1+3γ) + (1-γ)cos²θ), γ = ρn/(2-ρn). `cosTheta` is the cosine
    /// between the view ray and the direction to the Sun.
    public static func rayleighPhase(cosTheta: Double) -> Double {
        let gamma = depolarization / (2 - depolarization)
        let k = 3 / (16 * Double.pi * (1 + 2 * gamma))
        return k * ((1 + 3 * gamma) + (1 - gamma) * cosTheta * cosTheta)
    }

    /// The Cornette-Shanks (1992) phase function (1/sr): 3/(8π) (1-g²)(1+cos²θ)
    /// / ((2+g²)(1+g²-2g cosθ)^1.5), forward-peaked for g > 0 toward the Sun.
    public static func cornetteShanksPhase(cosTheta: Double, g: Double) -> Double {
        let g2 = g * g
        let k = 3 / (8 * Double.pi) * (1 - g2) / (2 + g2)
        let d = 1 + g2 - 2 * g * cosTheta
        return k * (1 + cosTheta * cosTheta) / (d * d.squareRoot())
    }

    /// The aerosol's phase function (1/sr).
    public func aerosolPhase(cosTheta: Double) -> Double {
        Self.cornetteShanksPhase(cosTheta: cosTheta, g: aerosol.asymmetry)
    }

    // MARK: Rays on the sphere

    /// Altitude (m) at distance `s` along a ray from radius `r` with zenith cosine `mu`.
    @inlinable public func altitude(radius r: Double, cosZenith mu: Double, distance s: Double) -> Double {
        (r * r + s * (s + 2 * r * mu)).squareRoot() - bottomRadius
    }

    /// Whether a ray from radius `r` (at or above the ground) with zenith
    /// cosine `mu` meets the ground.
    public func rayMeetsGround(radius r: Double, cosZenith mu: Double) -> Bool {
        let rb = bottomRadius
        return mu < 0 && r * r * (mu * mu - 1) + rb * rb >= 0
    }

    /// Distance (m) along the ray to the ground, if it meets it.
    public func distanceToGround(radius r: Double, cosZenith mu: Double) -> Double? {
        let rb = bottomRadius
        let disc: Double = r * r * (mu * mu - 1) + rb * rb
        guard mu < 0, disc >= 0 else { return nil }
        return Swift.max(0, -r * mu - disc.squareRoot())
    }

    /// Distance (m) along the ray to where it leaves through the top, or nil
    /// if it never meets the top sphere.
    public func distanceToTop(radius r: Double, cosZenith mu: Double) -> Double? {
        let rt = topRadius
        let disc: Double = r * r * (mu * mu - 1) + rt * rt
        guard disc >= 0 else { return nil }
        let far = -r * mu + disc.squareRoot()
        return far >= 0 ? far : nil
    }

    /// Where the ray from radius `r` with zenith cosine `mu` is inside the
    /// atmosphere, as distances along it, up to the ground if it meets it;
    /// nil if it never enters.
    public func atmosphereSegment(radius r: Double, cosZenith mu: Double) -> (enter: Double, exit: Double)? {
        let rt = topRadius
        let disc: Double = r * r * (mu * mu - 1) + rt * rt
        guard disc >= 0 else { return nil }
        let root = disc.squareRoot()
        let far = -r * mu + root
        guard far > 0 else { return nil }
        let enter = Swift.max(0, -r * mu - root)
        let exit = distanceToGround(radius: r, cosZenith: mu) ?? far
        return exit > enter ? (enter, exit) : nil
    }

    // MARK: Optical depth

    /// Altitudes (m) where rays are cut for the quadrature: three aerosol
    /// scale heights, and the ozone tent's base, peak and top, where the
    /// profile has corners.
    var cutAltitudes: [Double] {
        [3 * aerosol.scaleHeight,
         ozone.peakAltitude - ozone.halfWidth, ozone.peakAltitude, ozone.peakAltitude + ozone.halfWidth]
    }

    /// [s0, s1] along the ray from radius `r` with zenith cosine `mu`, cut
    /// at its lowest point and where it crosses a cut altitude, so the
    /// medium is smooth on each piece and spans a few scale heights. Each piece is (anchor, end): the
    /// anchor is its lower end, the one toward the lowest point.
    public func smoothPieces(radius r: Double, cosZenith mu: Double, from s0: Double,
                             to s1: Double) -> [(anchor: Double, end: Double)] {
        guard s1 > s0 else { return [] }
        let lowest = Swift.min(Swift.max(-r * mu, s0), s1)
        var cuts = [s0, lowest, s1]
        let b = r * mu
        for a in cutAltitudes {
            let ra = bottomRadius + a
            let disc: Double = b * b - r * r + ra * ra
            guard disc > 0 else { continue }
            let root = disc.squareRoot()
            for s in [-b - root, -b + root] where s > s0 && s < s1 { cuts.append(s) }
        }
        cuts.sort()
        var pieces: [(anchor: Double, end: Double)] = []
        for i in 0..<(cuts.count - 1) where cuts[i + 1] > cuts[i] {
            let a = cuts[i], z = cuts[i + 1]
            pieces.append(z <= lowest ? (z, a) : (a, z))
        }
        return pieces
    }

    /// ∫ f(altitude) ds from `s0` to `s1` along the ray from radius `r` with
    /// zenith cosine `mu`, by `nodes`-point Gauss-Legendre on each of its
    /// `smoothPieces`, with s quadratic in the quadrature variable so the
    /// nodes crowd toward each piece's lower end.
    public func integrate(radius r: Double, cosZenith mu: Double, from s0: Double, to s1: Double,
                          nodes: Int = 16, _ f: (Double) -> Spectrum3) -> Spectrum3 {
        let rule = GaussLegendre.rule(nodes)
        var sum = Spectrum3.zero
        for piece in smoothPieces(radius: r, cosZenith: mu, from: s0, to: s1) {
            let length = piece.end - piece.anchor
            for (t, w) in rule {
                let s = piece.anchor + length * t * t
                sum += f(altitude(radius: r, cosZenith: mu, distance: s)) * (w * 2 * t * abs(length))
            }
        }
        return sum
    }

    /// Optical depth along the ray from radius `r` with zenith cosine `mu`
    /// between distances `s0` and `s1` (m).
    public func opticalDepth(radius r: Double, cosZenith mu: Double, from s0: Double, to s1: Double,
                             nodes: Int = 16) -> Spectrum3 {
        integrate(radius: r, cosZenith: mu, from: s0, to: s1, nodes: nodes) { extinction(altitude: $0) }
    }

    /// Optical depth from altitude `h` (m) along zenith cosine `mu` to the
    /// top; infinite where the ray meets the ground.
    public func opticalDepth(altitude h: Double, cosZenith mu: Double) -> Spectrum3 {
        let r = bottomRadius + Swift.max(h, 0)
        if rayMeetsGround(radius: r, cosZenith: mu) { return Spectrum3(repeating: .infinity) }
        guard let segment = atmosphereSegment(radius: r, cosZenith: mu) else { return .zero }
        return opticalDepth(radius: r, cosZenith: mu, from: segment.enter, to: segment.exit)
    }

    /// Transmittance from altitude `h` (m) along zenith cosine `mu` to space;
    /// 0 where the ray meets the ground.
    public func transmittance(altitude h: Double, cosZenith mu: Double) -> Spectrum3 {
        opticalDepth(altitude: h, cosZenith: mu).attenuation
    }

    /// The air column (molecules/m²) from altitude `h` along `mu` to the top;
    /// infinite where the ray meets the ground.
    public func airColumn(altitude h: Double, cosZenith mu: Double) -> Double {
        let r = bottomRadius + Swift.max(h, 0)
        if rayMeetsGround(radius: r, cosZenith: mu) { return .infinity }
        guard let segment = atmosphereSegment(radius: r, cosZenith: mu) else { return 0 }
        return integrate(radius: r, cosZenith: mu, from: segment.enter, to: segment.exit) { a in
            Spectrum3(repeating: a <= Self.top ? airDensity(a) : 0)
        }.r
    }

    /// The relative optical air mass from altitude `h` at zenith cosine `mu`:
    /// the slant air column over the vertical one, without refraction.
    public func relativeAirMass(altitude h: Double, cosZenith mu: Double) -> Double {
        airColumn(altitude: h, cosZenith: mu) / airColumn(altitude: h, cosZenith: 1)
    }

    // MARK: The Sun's light at a point

    /// The Sun's transmittance at `position` (m from the planet's centre)
    /// toward the unit vector `sunDir`: 1 above the air with a clear line,
    /// reddened and dimmed through it, 0 where the planet's figure blocks
    /// the Sun's centre. Multiply by `Eclipse`'s sunlit fraction for the
    /// disc's partial occultation.
    ///
    /// Both vectors are in any frame whose `pole` is the planet's rotation
    /// axis (body-fixed: the default; ICRF: the body orientation's `pole`).
    /// The ray is traced in figure coordinates, the axis stretched by a/b so
    /// the ellipsoid becomes the sphere the optics stand on, as the renderer
    /// marches: the ground is exact and altitudes are within 0.34 % of
    /// geodetic. A point below the ground is lifted onto it.
    public func sunTransmittance(position: Vec3, sunDir: Vec3, pole: Vec3 = .unitZ) -> Spectrum3 {
        let stretch = figure.equatorialRadius / figure.polarRadius - 1
        let p = position + pole * (position.dot(pole) * stretch)
        let d = (sunDir + pole * (sunDir.dot(pole) * stretch)).normalized
        let distance = p.length
        guard distance > 0 else { return .zero }
        let r = Swift.max(distance, bottomRadius)
        let mu = p.dot(d) / distance
        if rayMeetsGround(radius: r, cosZenith: mu) { return .zero }
        guard let segment = atmosphereSegment(radius: r, cosZenith: mu) else { return .one }
        return opticalDepth(radius: r, cosZenith: mu, from: segment.enter, to: segment.exit).attenuation
    }
}

/// Gauss-Legendre rules on [0, 1], built once per order.
enum GaussLegendre {
    private static let common: [Int: [(t: Double, w: Double)]] = [8: make(8), 16: make(16), 32: make(32), 64: make(64)]

    /// The `n`-point rule (n ≥ 2): nodes in (0, 1) and weights summing to 1.
    static func rule(_ n: Int) -> [(t: Double, w: Double)] {
        common[n] ?? make(n)
    }

    private static func make(_ n: Int) -> [(t: Double, w: Double)] {
        precondition(n >= 2)
        var out: [(t: Double, w: Double)] = []
        for i in 1...n {
            var x = cos(Double.pi * (Double(i) - 0.25) / (Double(n) + 0.5))
            var derivative = 1.0
            for _ in 0..<100 {
                let (p, dp) = legendre(n, x)
                derivative = dp
                let dx = p / dp
                x -= dx
                if abs(dx) < 1e-16 { break }
            }
            derivative = legendre(n, x).dp
            let w = 2 / ((1 - x * x) * derivative * derivative)
            out.append(((1 - x) / 2, w / 2))
        }
        return out.sorted { $0.t < $1.t }
    }

    /// P_n(x) and its derivative.
    private static func legendre(_ n: Int, _ x: Double) -> (p: Double, dp: Double) {
        var p0 = 1.0, p1 = x
        for k in 2...n {
            let a = Double(2 * k - 1) * x * p1
            let p2 = (a - Double(k - 1) * p0) / Double(k)
            p0 = p1
            p1 = p2
        }
        return (p1, Double(n) * (x * p1 - p0) / (x * x - 1))
    }
}
