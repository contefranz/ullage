import Foundation

/// The atmosphere's lookup tables for the renderer (track A2), after
/// Hillaire (2020), "A Scalable and Production Ready Sky and Atmosphere
/// Rendering Technique" (EGSR), built here in Double from an
/// `OpticalAtmosphere` and stored as Float.
///
/// Every table is `width × height` texels of four Floats, RGBA, row-major
/// from v = 0: texel (i, j) starts at index 4 (j·width + i), so it uploads
/// as an rgba32Float 2D texture as it is. RGB are the `Spectrum3` channels
/// (680, 550, 440 nm); A is 1 unless a table says otherwise. Each table
/// maps its parameters to [0, 1] and then to texel centres
/// (`textureCoordinate`), so a linear sampler with clamp-to-edge returns the
/// exact parameter range at the edge texels' centres (Bruneton 2017). The
/// radii are the optics' sphere: the ground at the figure's equatorial
/// radius R (6,378,137 m for WGS 84) and the top 100 km above it.
///
/// - `transmittance` (256×64): the transmittance from radius r along zenith
///   cosine μ to the top, for rays that miss the ground. Bruneton's (r, μ)
///   parameterisation: with H = √(Rtop² − R²), ρ = √(r² − R²), d the
///   distance to the top, d_min = Rtop − r and d_max = ρ + H,
///   x_μ = (d − d_min)/(d_max − d_min) on u and x_r = ρ/H on v.
/// - `multipleScattering` (32×32): Hillaire's Ψ_ms, the isotropic radiance
///   of every order of scattering above the first, per unit scattering
///   coefficient and unit solar irradiance (1/sr): a point at radius r with
///   the Sun at zenith cosine μs scatters σs(r)·Ψ_ms toward any direction.
///   x = μs·0.5 + 0.5 on u, x = √((r − R)/(Rtop − R)) on v: the square
///   root (Hillaire's is linear) puts half the rows below 25 km, where the
///   light changes fastest. The second order L2 scatters the Sun's light
///   first with the Rayleigh and aerosol phase functions (his reference
///   code's `MieRayPhase` option), then isotropically: with the forward
///   aerosol this closes the energy balance within 0.4 %, where isotropic
///   first scattering overshoots by 1-2 % (AtmosphereLUTTests).
/// - `irradiance` (64×16): the sky's irradiance (the diffuse light, single
///   and multiple scattering, without the direct Sun) on a horizontal
///   surface facing up at radius r, per unit solar irradiance; the same
///   axes as `multipleScattering`. The direct part is `sunIrradiance`.
/// - `profile` (1024×1): the medium against altitude h = x·100 km on u:
///   R the air's number density over the ground's, G the aerosol's factor
///   e^(−h/H), B the ozone over its peak, A 0. Times `coefficients`, it
///   gives `OpticalAtmosphere.medium(altitude:)` for a ray march.
///
/// All values are per unit solar irradiance: multiply by the Sun's
/// illuminance above the air (`Photometry`) for physical units.
public struct AtmosphereLUT {
    /// Table sizes, and the quadrature that builds them.
    public struct Resolution: Equatable {
        public var transmittanceWidth = 256
        public var transmittanceHeight = 64
        public var multipleScatteringSize = 32
        public var irradianceWidth = 64
        public var irradianceHeight = 16
        public var profileWidth = 1024
        /// Gauss-Legendre nodes in μ per hemisphere and midpoint azimuths over
        /// [0, π] for the multiple-scattering sphere: 384 directions, where
        /// Hillaire has 64, because the aerosol's forward peak needs 12
        /// azimuths with the Sun low (8 leave Ψ 6 % short).
        public var multipleScatteringZenithNodes = 16
        public var multipleScatteringAzimuths = 12
        public var multipleScatteringSteps = 20
        /// The same for the irradiance's upper hemisphere.
        public var irradianceZenithNodes = 12
        public var irradianceAzimuths = 16
        public var irradianceSteps = 24

        public init() {}

        /// The sizes A2 uploads.
        public static let standard = Resolution()
    }

    /// One table: `width × height` RGBA Float texels, row-major from v = 0.
    public struct Table: Equatable {
        public let width: Int
        public let height: Int
        public internal(set) var texels: [Float]

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            texels = [Float](repeating: 1, count: 4 * width * height)
        }

        /// Texel (i, j)'s RGB.
        public subscript(i: Int, j: Int) -> Spectrum3 {
            let k = 4 * (j * width + i)
            return Spectrum3(Double(texels[k]), Double(texels[k + 1]), Double(texels[k + 2]))
        }

        /// The RGB at (u, v) as a GPU's linear sampler with clamp-to-edge
        /// returns it: bilinear between texel centres, constant beyond them.
        public func sample(u: Double, v: Double) -> Spectrum3 {
            // NaN reads the first texel rather than trapping.
            let x = Swift.min(Swift.max((u * Double(width) - 0.5).nanToZero, 0), Double(width - 1))
            let y = Swift.min(Swift.max((v * Double(height) - 0.5).nanToZero, 0), Double(height - 1))
            let i0 = Swift.min(Int(x), width - 1), j0 = Swift.min(Int(y), height - 1)
            let i1 = Swift.min(i0 + 1, width - 1), j1 = Swift.min(j0 + 1, height - 1)
            let fx = x - Double(i0), fy = y - Double(j0)
            let bottom = self[i0, j0] * (1 - fx) + self[i1, j0] * fx
            let top = self[i0, j1] * (1 - fx) + self[i1, j1] * fx
            return bottom * (1 - fy) + top * fy
        }

        mutating func set(_ i: Int, _ j: Int, _ value: Spectrum3, alpha: Float = 1) {
            let k = 4 * (j * width + i)
            texels[k] = Float(value.r)
            texels[k + 1] = Float(value.g)
            texels[k + 2] = Float(value.b)
            texels[k + 3] = alpha
        }
    }

    /// The medium's coefficients that scale `profile` (1/m), for the shader's
    /// uniforms; the scale heights and layer are for analytic fallbacks.
    public struct Coefficients: Equatable {
        public var rayleighScatteringAtGround: Spectrum3
        /// The air's column over its density at the ground, m.
        public var rayleighScaleHeight: Double
        public var aerosolScatteringAtGround: Spectrum3
        public var aerosolExtinctionAtGround: Spectrum3
        public var aerosolScaleHeight: Double
        public var aerosolAsymmetry: Double
        public var ozoneAbsorptionAtPeak: Spectrum3
        public var ozonePeakAltitude: Double
        public var ozoneHalfWidth: Double
    }

    public let optics: OpticalAtmosphere
    /// The ground's Lambertian albedo, lit by the Sun through the air, in
    /// the multiple scattering.
    public let groundAlbedo: Spectrum3
    /// The Sun's angular radius (rad), which softens its setting behind the
    /// planet in the scattering integrals: 1 AU's.
    public let sunAngularRadius: Double
    public let resolution: Resolution
    public private(set) var transmittance: Table
    public private(set) var multipleScattering: Table
    public private(set) var irradiance: Table
    public private(set) var profile: Table
    public let coefficients: Coefficients

    /// Builds every table for `optics`, rows in parallel: about 0.6 s in
    /// Release on four cloud cores at the standard resolution.
    public init(optics: OpticalAtmosphere = OpticalAtmosphere(), groundAlbedo: Spectrum3 = Spectrum3(repeating: 0.1),
                sunAngularRadius: Double = Eclipse.solarRadius / 149_597_870_700,
                resolution: Resolution = .standard) {
        self.optics = optics
        self.groundAlbedo = groundAlbedo
        self.sunAngularRadius = sunAngularRadius
        self.resolution = resolution
        let ground = optics.medium(altitude: 0)
        let peak = optics.medium(altitude: optics.ozone.peakAltitude).ozoneAbsorption
        let air0 = optics.airNumberDensity(altitude: 0)
        coefficients = Coefficients(
            rayleighScatteringAtGround: ground.rayleighScattering,
            rayleighScaleHeight: optics.airColumn(altitude: 0, cosZenith: 1) / air0,
            aerosolScatteringAtGround: ground.aerosolScattering,
            aerosolExtinctionAtGround: ground.aerosolExtinction,
            aerosolScaleHeight: optics.aerosol.scaleHeight,
            aerosolAsymmetry: optics.aerosol.asymmetry,
            ozoneAbsorptionAtPeak: peak,
            ozonePeakAltitude: optics.ozone.peakAltitude,
            ozoneHalfWidth: optics.ozone.halfWidth)
        transmittance = Table(width: resolution.transmittanceWidth, height: resolution.transmittanceHeight)
        multipleScattering = Table(width: resolution.multipleScatteringSize, height: resolution.multipleScatteringSize)
        irradiance = Table(width: resolution.irradianceWidth, height: resolution.irradianceHeight)
        profile = Table(width: resolution.profileWidth, height: 1)
        buildProfile()
        transmittance = Self.fill(transmittance) { i, j in transmittanceTexel(i, j) }
        multipleScattering = Self.fill(multipleScattering) { i, j in multipleScatteringTexel(i, j) }
        irradiance = Self.fill(irradiance) { i, j in irradianceTexel(i, j) }
    }

    public var bottomRadius: Double { optics.bottomRadius }
    public var topRadius: Double { optics.topRadius }

    // MARK: Parameterisation

    /// [0, 1] to the texture coordinate of a table `size` texels wide: 0 and
    /// 1 land on the centres of the first and last texels.
    public static func textureCoordinate(unit x: Double, size: Int) -> Double {
        0.5 / Double(size) + x * (1 - 1 / Double(size))
    }

    /// The inverse of `textureCoordinate`.
    public static func unit(textureCoordinate u: Double, size: Int) -> Double {
        (u - 0.5 / Double(size)) / (1 - 1 / Double(size))
    }

    /// The transmittance table's (u, v) for radius `r` and zenith cosine `mu`.
    public func transmittanceUV(radius r: Double, cosZenith mu: Double) -> (u: Double, v: Double) {
        let rb = bottomRadius, rt = topRadius
        let h = (rt * rt - rb * rb).squareRoot()
        let rr = Swift.min(Swift.max(r, rb), rt)
        let rho = Swift.max(0, rr * rr - rb * rb).squareRoot()
        let disc: Double = rr * rr * (mu * mu - 1) + rt * rt
        let d = Swift.max(0, -rr * mu + Swift.max(0, disc).squareRoot())
        let dMin = rt - rr, dMax = rho + h
        let xMu = dMax > dMin ? (d - dMin) / (dMax - dMin) : 0
        return (Self.textureCoordinate(unit: xMu, size: transmittance.width),
                Self.textureCoordinate(unit: rho / h, size: transmittance.height))
    }

    /// The radius and zenith cosine at the transmittance table's (u, v).
    public func transmittanceRadiusAndCosine(u: Double, v: Double) -> (radius: Double, cosZenith: Double) {
        let rb = bottomRadius, rt = topRadius
        let xMu = Self.unit(textureCoordinate: u, size: transmittance.width)
        let xR = Self.unit(textureCoordinate: v, size: transmittance.height)
        let h = (rt * rt - rb * rb).squareRoot()
        let rho = h * xR
        let r = (rho * rho + rb * rb).squareRoot()
        let dMin = rt - r, dMax = rho + h
        let d = dMin + xMu * (dMax - dMin)
        guard d > 0 else { return (r, 1) }
        let mu: Double = (h * h - rho * rho - d * d) / (2 * r * d)
        return (r, Swift.min(Swift.max(mu, -1), 1))
    }

    /// (u, v) on a table `width × height` over (μs, r), as the
    /// multiple-scattering and irradiance tables use.
    public func sunTableUV(radius r: Double, cosSun muS: Double, width: Int, height: Int) -> (u: Double, v: Double) {
        let xMu = Swift.min(Swift.max(muS * 0.5 + 0.5, 0), 1)
        let xR = Swift.min(Swift.max((r - bottomRadius) / (topRadius - bottomRadius), 0), 1).squareRoot()
        return (Self.textureCoordinate(unit: xMu, size: width), Self.textureCoordinate(unit: xR, size: height))
    }

    /// The radius and Sun zenith cosine at (u, v) on such a table.
    public func sunTableRadiusAndCosine(u: Double, v: Double, width: Int, height: Int) -> (radius: Double, cosSun: Double) {
        let xMu = Self.unit(textureCoordinate: u, size: width)
        let xR = Self.unit(textureCoordinate: v, size: height)
        return (bottomRadius + xR * xR * (topRadius - bottomRadius), 2 * xMu - 1)
    }

    // MARK: Lookups (the CPU's mirror of the GPU's)

    /// Transmittance from radius `r` along `mu` to the top, from the table;
    /// rays into the ground read the horizon's.
    public func transmittanceToTop(radius r: Double, cosZenith mu: Double) -> Spectrum3 {
        let uv = transmittanceUV(radius: r, cosZenith: mu)
        return transmittance.sample(u: uv.u, v: uv.v)
    }

    /// The Sun's transmittance at radius `r` with the Sun at zenith cosine
    /// `muS`, times the share of its disc above the planet's horizon
    /// (Bruneton's smoothstep over the disc).
    public func transmittanceToSun(radius r: Double, cosSun muS: Double) -> Spectrum3 {
        let sinH = Swift.min(bottomRadius / r, 1)
        let cosH = -Swift.max(0, 1 - sinH * sinH).squareRoot()
        let edge = sinH * sunAngularRadius
        let visible = Self.smoothstep(-edge, edge, muS - cosH)
        guard visible > 0 else { return .zero }
        return transmittanceToTop(radius: r, cosZenith: muS) * visible
    }

    /// Ψ_ms at radius `r` with the Sun at zenith cosine `muS` (1/sr).
    public func multipleScattering(radius r: Double, cosSun muS: Double) -> Spectrum3 {
        let t = multipleScattering
        let uv = sunTableUV(radius: r, cosSun: muS, width: t.width, height: t.height)
        return t.sample(u: uv.u, v: uv.v)
    }

    /// The sky's irradiance on a horizontal surface facing up at radius `r`,
    /// per unit solar irradiance.
    public func skyIrradiance(radius r: Double, cosSun muS: Double) -> Spectrum3 {
        let t = irradiance
        let uv = sunTableUV(radius: r, cosSun: muS, width: t.width, height: t.height)
        return t.sample(u: uv.u, v: uv.v)
    }

    /// The direct Sun's irradiance on the same surface, per unit solar irradiance.
    public func sunIrradiance(radius r: Double, cosSun muS: Double) -> Spectrum3 {
        transmittanceToSun(radius: r, cosSun: muS) * Swift.max(muS, 0)
    }

    // MARK: The sky

    /// What a ray march returns, per unit solar irradiance.
    public struct March {
        /// In-scattered radiance (1/sr), and the ground's if the ray meets it.
        public var radiance = Spectrum3.zero
        /// Hillaire's L_f: ∫ T σs dt, the light a unit isotropic source
        /// along the ray would send back to its origin, × 4π.
        public var transfer = Spectrum3.zero
        /// Transmittance along the ray to its end.
        public var transmittance = Spectrum3.one
    }

    /// The radiance reaching radius `r` along the view ray of zenith cosine
    /// `mu` (looking outward along it), with the Sun at zenith cosine `muS`
    /// and cosine `nu` between the view ray and the Sun: single scattering
    /// with the Rayleigh and aerosol phase functions plus σs·Ψ_ms, and the
    /// ground's Lambertian light where the ray meets it. This is the sky A2
    /// draws, marched in `steps` steps.
    public func skyRadiance(radius r: Double, cosZenith mu: Double, cosSun muS: Double, cosView nu: Double,
                            steps: Int = 40, groundAlbedo: Spectrum3? = nil) -> Spectrum3 {
        march(radius: r, cosZenith: mu, cosSun: muS, cosView: nu, steps: steps, isotropic: false,
              withMultipleScattering: true, groundAlbedo: groundAlbedo ?? self.groundAlbedo,
              sun: transmittanceToSun).radiance
    }

    /// The march behind every table: `steps` steps (about; each smooth piece
    /// of the ray gets at least two) crowded toward the ray's lowest point,
    /// the medium constant within a step and its attenuation integrated
    /// exactly (Hillaire 2015). `isotropic` scatters the Sun's light with
    /// 1/4π instead of the phase functions; `sun` gives the transmittance to
    /// the Sun at a radius and Sun zenith cosine.
    public func march(radius r: Double, cosZenith mu: Double, cosSun muS: Double, cosView nu: Double,
                      steps: Int, isotropic: Bool, withMultipleScattering: Bool, groundAlbedo: Spectrum3,
                      sun: (Double, Double) -> Spectrum3) -> March {
        var result = March()
        let ground = optics.distanceToGround(radius: r, cosZenith: mu)
        // A ray from the ground into it has no air to cross, only the ground's light.
        let segment = optics.atmosphereSegment(radius: r, cosZenith: mu) ?? (0, 0)
        guard segment.exit > segment.enter || ground != nil else { return result }
        let rayleighPhase = OpticalAtmosphere.rayleighPhase(cosTheta: nu)
        let aerosolPhase = optics.aerosolPhase(cosTheta: nu)
        let isotropicPhase = 1 / (4 * Double.pi)
        if segment.exit > segment.enter {
            // Steps per piece: its length times the air's density at its lower end.
            var weights = 0.0
            let pieces = optics.smoothPieces(radius: r, cosZenith: mu, from: segment.enter, to: segment.exit)
            for (anchor, end) in pieces {
                weights += abs(end - anchor) * Self.airWeight(optics, r, mu, anchor)
            }
            var a = segment.enter
            for (anchor, end) in pieces {
                let share = Double(steps) * abs(end - anchor) * Self.airWeight(optics, r, mu, anchor)
                let n = Swift.max(2, Int((share / Swift.max(weights, 1e-300)).rounded()))
                let length = end - anchor
                for k in 1...n {
                    // Quadratic from the anchor, walked in the ray's direction.
                    let x = length >= 0 ? Double(k) / Double(n) : 1 - Double(k) / Double(n)
                    let b = anchor + length * x * x
                    let dt = b - a, s = 0.5 * (a + b)
                    a = b
                    let rs = (r * r + s * (s + 2 * r * mu)).squareRoot()
                    let m = optics.medium(altitude: rs - bottomRadius)
                    let muSs = Swift.min(Swift.max((r * muS + s * nu) / rs, -1), 1)
                    let scattering = m.scattering
                    let phased: Spectrum3 = isotropic
                        ? scattering * isotropicPhase
                        : m.rayleighScattering * rayleighPhase + m.aerosolScattering * aerosolPhase
                    var source = sun(rs, muSs) * phased
                    if withMultipleScattering {
                        source += multipleScattering(radius: rs, cosSun: muSs) * scattering
                    }
                    let ext = m.extinction
                    let stepT = (ext * dt).attenuation
                    let integral = Spectrum3(Self.stepIntegral(ext.r, stepT.r, dt),
                                             Self.stepIntegral(ext.g, stepT.g, dt),
                                             Self.stepIntegral(ext.b, stepT.b, dt))
                    result.radiance += result.transmittance * source * integral
                    result.transfer += result.transmittance * scattering * integral
                    result.transmittance *= stepT
                }
            }
        }
        if let d = ground {
            let muG = Swift.min(Swift.max((r * muS + d * nu) / bottomRadius, -1), 1)
            let lit = sun(bottomRadius, muG) * (Swift.max(muG, 0) / Double.pi)
            result.radiance += result.transmittance * lit * groundAlbedo
        }
        return result
    }

    /// ∫ e^(−σt) dt over a step of length `dt` with transmittance `t`.
    static func stepIntegral(_ sigma: Double, _ t: Double, _ dt: Double) -> Double {
        sigma * dt > 1e-6 ? (1 - t) / sigma : dt * (1 - 0.5 * sigma * dt)
    }

    /// The air's density at distance `s` along the ray relative to the
    /// ground's, roughly: e^(−h/8 km).
    static func airWeight(_ optics: OpticalAtmosphere, _ r: Double, _ mu: Double, _ s: Double) -> Double {
        exp(-Swift.max(optics.altitude(radius: r, cosZenith: mu, distance: s), 0) / 8_000)
    }

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        guard e1 > e0 else { return x >= e1 ? 1 : 0 }
        let t = Swift.min(Swift.max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: Building

    /// Fills every texel of `table` with `texel(i, j)`, rows in parallel.
    static func fill(_ table: Table, _ texel: (Int, Int) -> Spectrum3) -> Table {
        var out = table
        let width = table.width
        out.texels.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: table.height) { j in
                for i in 0..<width {
                    let value = texel(i, j), k = 4 * (j * width + i)
                    base[k] = Float(value.r)
                    base[k + 1] = Float(value.g)
                    base[k + 2] = Float(value.b)
                    base[k + 3] = 1
                }
            }
        }
        return out
    }

    mutating func buildProfile() {
        let n = profile.width
        let air0 = optics.airNumberDensity(altitude: 0)
        let ozonePeak = optics.ozone.peakDensity
        for i in 0..<n {
            let h = OpticalAtmosphere.top * Double(i) / Double(n - 1)
            let air = optics.airNumberDensity(altitude: h) / air0
            let aerosol = exp(-h / optics.aerosol.scaleHeight)
            let ozone = ozonePeak > 0 ? optics.ozone.density(altitude: h) / ozonePeak : 0
            profile.set(i, 0, Spectrum3(air, aerosol, ozone), alpha: 0)
        }
    }

    func transmittanceTexel(_ i: Int, _ j: Int) -> Spectrum3 {
        let u = (Double(i) + 0.5) / Double(transmittance.width)
        let v = (Double(j) + 0.5) / Double(transmittance.height)
        let (r, mu) = transmittanceRadiusAndCosine(u: u, v: v)
        let disc: Double = r * r * (mu * mu - 1) + topRadius * topRadius
        let d = Swift.max(0, -r * mu + Swift.max(0, disc).squareRoot())
        return optics.opticalDepth(radius: r, cosZenith: mu, from: 0, to: d).attenuation
    }

    /// Hillaire's eqs. 5-10 at one texel: Ψ_ms = L2/(1 − f_ms).
    func multipleScatteringTexel(_ i: Int, _ j: Int) -> Spectrum3 {
        let size = multipleScattering.width
        let (r, muS) = sunTableRadiusAndCosine(u: (Double(i) + 0.5) / Double(size),
                                               v: (Double(j) + 0.5) / Double(size), width: size, height: size)
        let (secondOrder, transfer) = multipleScatteringIntegrals(radius: r, cosSun: muS)
        return secondOrder / (Spectrum3.one - transfer)
    }

    /// L2 and f_ms (Hillaire's eqs. 5 and 7) at radius `r` with the Sun at
    /// zenith cosine `muS`, from the transmittance table: over the sphere of
    /// directions, the singly scattered light arriving (true phase
    /// functions, the ground's bounce included) and the transfer ∫ T σs dt,
    /// each scattered on isotropically. `zenithNodes` Gauss-Legendre nodes
    /// per hemisphere in μ, `azimuths` midpoints over [0, π].
    public func multipleScatteringIntegrals(radius r: Double, cosSun muS: Double,
                                            zenithNodes: Int? = nil, azimuths: Int? = nil,
                                            steps: Int? = nil) -> (secondOrder: Spectrum3, transfer: Spectrum3) {
        let rule = GaussLegendre.rule(zenithNodes ?? resolution.multipleScatteringZenithNodes)
        let k = azimuths ?? resolution.multipleScatteringAzimuths
        let n = steps ?? resolution.multipleScatteringSteps
        let sinS = Swift.max(0, 1 - muS * muS).squareRoot()
        let isotropic = 1 / (4 * Double.pi)
        var secondOrder = Spectrum3.zero, transfer = Spectrum3.zero
        for (t, w) in rule {
            for mu in [t, -t] {
                let sinV = Swift.max(0, 1 - mu * mu).squareRoot()
                for a in 0..<k {
                    let phi = Double.pi * (Double(a) + 0.5) / Double(k)
                    let nu = mu * muS + sinV * sinS * cos(phi)
                    let m = march(radius: r, cosZenith: mu, cosSun: muS, cosView: nu, steps: n, isotropic: false,
                                  withMultipleScattering: false, groundAlbedo: groundAlbedo,
                                  sun: transmittanceToSun)
                    // dω = dμ dφ, the azimuths over [0, π] counted twice.
                    let solidAngle = w * 2 * Double.pi / Double(k)
                    secondOrder += m.radiance * (solidAngle * isotropic)
                    transfer += m.transfer * (solidAngle * isotropic)
                }
            }
        }
        return (secondOrder, transfer)
    }

    func irradianceTexel(_ i: Int, _ j: Int) -> Spectrum3 {
        let t = irradiance
        let (r, muS) = sunTableRadiusAndCosine(u: (Double(i) + 0.5) / Double(t.width),
                                               v: (Double(j) + 0.5) / Double(t.height), width: t.width, height: t.height)
        return skyIrradianceIntegral(radius: r, cosSun: muS)
    }

    /// The sky's irradiance on a horizontal surface facing up, integrated
    /// over its hemisphere: ∫ L cosθ dω with `zenithNodes` Gauss-Legendre
    /// nodes in cosθ and `azimuths` midpoints over [0, π].
    public func skyIrradianceIntegral(radius r: Double, cosSun muS: Double, zenithNodes: Int? = nil,
                                      azimuths: Int? = nil, steps: Int? = nil) -> Spectrum3 {
        let rule = GaussLegendre.rule(zenithNodes ?? resolution.irradianceZenithNodes)
        let k = azimuths ?? resolution.irradianceAzimuths
        let n = steps ?? resolution.irradianceSteps
        let sinS = Swift.max(0, 1 - muS * muS).squareRoot()
        var e = Spectrum3.zero
        for (mu, w) in rule {
            let sinV = Swift.max(0, 1 - mu * mu).squareRoot()
            for a in 0..<k {
                let phi = Double.pi * (Double(a) + 0.5) / Double(k)
                let nu = mu * muS + sinV * sinS * cos(phi)
                let l = skyRadiance(radius: r, cosZenith: mu, cosSun: muS, cosView: nu, steps: n)
                e += l * (mu * w * 2 * Double.pi / Double(k))
            }
        }
        return e
    }
}

private extension Double {
    var nanToZero: Double { isNaN ? 0 : self }
}
