import Foundation

// Track C2: the far regime's slab-BRDF LUT. From far away a cloud layer is
// a surface: what it reflects towards the eye is the volumetric march's
// lighting (CloudLighting) marched through a flat, homogeneous slab of the
// layer's optical depth, with the same light march, diffuse streams and sky
// light, so the far regime matches the orbit and near regimes by
// construction (docs/m16/design-earth-moon.md, clouds (3)). Only the single
// scattering depends on the scattering angle, through its phase, so the
// LUT keeps it without the phase, over (τ, μ0, μ): three dimensions, the
// phase evaluated by the shader at the pixel's angle. It is checked against
// the two-stream slab reflectance C1 pinned (CloudOptics.slabReflectance)
// and against the march's closed form.

/// A flat cloud slab lit from above and seen from above.
public struct CloudSlab: Equatable {
    /// Its thickness, m (the light march's reach is in metres, so a slab of
    /// a given optical depth depends on it).
    public var thickness: Double
    public var lighting: CloudLighting

    public init(thickness: Double, lighting: CloudLighting = CloudLighting()) {
        self.thickness = thickness
        self.lighting = lighting
    }

    /// What the march returns through the slab for one view, per unit
    /// irradiance: the Sun's light scattered once without its phase
    /// (multiply by the phase at the pixel's angle, the Sun's irradiance and
    /// the air's transmittance); scattered many times (times the Sun's
    /// irradiance and the air's transmittance); the sky's (times the sky's
    /// irradiance); and the slab's transmittance along the view.
    public struct Response: Equatable {
        public var single: Double
        public var sunDiffuse: Double
        public var sky: Double
        public var transmittance: Double
    }

    /// The light march's estimate of the optical depth towards the Sun from
    /// `depth` m below the slab's top, extinction `sigma`: its midpoint
    /// samples that are still in the slab, as the shader's light march sees a
    /// homogeneous layer.
    public func sunOpticalDepth(depth: Double, sigma: Double, mu0: Double) -> Double {
        let ends = lighting.lightSegmentEnds, d = lighting.lightDistance
        var tau = 0.0
        for k in 0..<lighting.lightSamples {
            let s = d * 0.5 * (ends[k] + ends[k + 1])
            if s * mu0 < depth { tau += sigma * d * (ends[k + 1] - ends[k]) }
        }
        return tau
    }

    /// Whether the light march's last sample from `depth` m below the top
    /// is out of the slab.
    public func lightEscapes(depth: Double, mu0: Double) -> Bool {
        let ends = lighting.lightSegmentEnds, k = lighting.lightSamples
        return lighting.lightDistance * 0.5 * (ends[k - 1] + ends[k]) * mu0 >= depth
    }

    /// The march through a slab of optical depth `tau`, Sun at cosine `mu0`
    /// from the zenith, the eye at cosine `mu` from the zenith above it (or,
    /// `fromBelow`, from the nadir below it, looking up), in `steps` equal
    /// steps of depth from the eye's side, each integrated as the shader
    /// does: the step's light times (1 − e^{−σΔ}) (Hillaire 2016), then the
    /// transmittance.
    public func march(opticalDepth tau: Double, mu0: Double, mu: Double, fromBelow: Bool = false,
                      steps: Int = 96) -> Response {
        let sigma = tau / thickness, mu = max(mu, 1e-4), mu0 = max(mu0, 1e-4)
        let dz = thickness / Double(steps), dl = dz / mu
        let stepOpacity = 1 - exp(-sigma * dl)
        // The light's upward cosine towards the eye.
        let muUp = fromBelow ? -mu : mu
        var r = Response(single: 0, sunDiffuse: 0, sky: 0, transmittance: 1)
        for m in 0..<steps {
            let fromEye = (Double(m) + 0.5) * dz
            let depth = fromBelow ? thickness - fromEye : fromEye, h = 1 - depth / thickness
            let tauSun = sunOpticalDepth(depth: depth, sigma: sigma, mu0: mu0)
            let t = lighting.columnDepth(column: tau, heightFraction: h, sunOpticalDepth: tauSun, sunCosine: mu0,
                                         escaped: lightEscapes(depth: depth, mu0: mu0))
            let w = r.transmittance * stepOpacity
            r.single += w * exp(-tauSun)
            r.sunDiffuse += w * lighting.sunDiffuse(depth: t, column: tau, sunCosine: mu0, muUp: muUp)
            r.sky += w * lighting.skyDiffuse(column: tau, heightFraction: h, muUp: muUp)
            r.transmittance *= exp(-sigma * dl)
        }
        return r
    }

    /// The Sun's light reflected towards the eye per unit solar irradiance
    /// (1/sr), at scattering-angle cosine `cosTheta`, without sky light.
    public func reflectance(opticalDepth tau: Double, mu0: Double, mu: Double, cosTheta: Double,
                            steps: Int = 96) -> Double {
        let r = march(opticalDepth: tau, mu0: mu0, mu: mu, steps: steps)
        return r.single * lighting.mie.phase(cosTheta) + r.sunDiffuse
    }

    /// The single scattering's closed form with an exact path to the Sun:
    /// p μ0/(μ + μ0) (1 − e^{−τ(1/μ0 + 1/μ)}), the limit the march's first
    /// term converges to as its steps shrink and its light march reaches
    /// the slab's top.
    public func singleScatteringClosedForm(opticalDepth tau: Double, mu0: Double, mu: Double) -> Double {
        let k = 1 / mu0 + 1 / mu
        return (1 - exp(-tau * k)) / (mu * k)
    }

    /// The same seen from below, the eye at cosine `mu` from the nadir:
    /// (e^{−τ/μ0} − e^{−τ/μ}) / (μ (1/μ − 1/μ0)), whose limit where μ = μ0
    /// is τ e^{−τ/μ}/μ.
    public func singleScatteringClosedFormFromBelow(opticalDepth tau: Double, mu0: Double, mu: Double) -> Double {
        let k = 1 / mu - 1 / mu0
        if abs(k) < 1e-9 { return tau * exp(-tau / mu) / mu }
        return (exp(-tau / mu0) - exp(-tau / mu)) / (mu * k)
    }

    /// The plane albedo for the Sun at `mu0`, ∫ L μ dω / μ0 over the upward
    /// hemisphere by a midpoint rule in μ and azimuth: the reflected flux
    /// over the incident.
    public func planeAlbedo(opticalDepth tau: Double, mu0: Double, muSteps: Int = 24, azimuths: Int = 48) -> Double {
        let sin0 = (1 - mu0 * mu0).squareRoot(), mie = lighting.mie
        var flux = 0.0
        for m in 0..<muSteps {
            let mu = (Double(m) + 0.5) / Double(muSteps), sinV = (1 - mu * mu).squareRoot()
            let r = march(opticalDepth: tau, mu0: mu0, mu: mu, steps: 64)
            var phase = 0.0
            for p in 0..<azimuths {
                let phi = 2 * Double.pi * (Double(p) + 0.5) / Double(azimuths)
                // The view ray (eye to slab, downward) against the direction
                // to the Sun (upward).
                phase += mie.phase(-(sinV * sin0 * cos(phi)) - mu * mu0)
            }
            let l = r.single * phase / Double(azimuths) + r.sunDiffuse
            flux += l * mu * (1 / Double(muSteps)) * 2 * .pi
        }
        return flux / mu0
    }
}

/// The far regime's LUT: `CloudSlab.march` over a grid of optical depth,
/// Sun and view cosines, one block of optical depths per layer, as the
/// shader's two 3D textures want it (CloudShaders' `cloud_slabLUT`).
public struct CloudSlabLUT: Equatable {
    /// Optical depths, log-spaced from `minDepth` to `maxDepth`.
    public static let depths = 24
    public static let minDepth = 0.05, maxDepth = 256.0
    /// Sun and view cosines, from `minCosine` to 1.
    public static let cosines = 16
    public static let minCosine = 0.02

    /// The layers, bottom up: low and mid (their thicknesses; the cirrus is a
    /// 2D layer of the high one).
    public let slabs: [CloudSlab]
    /// RGBA per texel: the march's single scattering (without phase), the
    /// Sun's diffuse light, the sky's, and the transmittance along the view.
    /// x the view cosine, y the Sun's, z the optical depth within a block;
    /// the blocks stacked in z as layer 0 from above, layer 0 from below,
    /// layer 1 from above, layer 1 from below (`block(layer:fromBelow:)`).
    public let texels: [Float]

    /// The block of a layer and a side, in z.
    public static func block(layer: Int, fromBelow: Bool) -> Int { 2 * layer + (fromBelow ? 1 : 0) }

    public init(slabs: [CloudSlab]) {
        self.slabs = slabs
        let n = Self.cosines, d = Self.depths
        var texels = [Float](repeating: 0, count: 4 * n * n * d * 2 * slabs.count)
        for (l, slab) in slabs.enumerated() {
            for below in [false, true] {
                let b = Self.block(layer: l, fromBelow: below)
                for k in 0..<d {
                    let tau = Self.depth(k)
                    for j in 0..<n {
                        for i in 0..<n {
                            let r = slab.march(opticalDepth: tau, mu0: Self.cosine(j), mu: Self.cosine(i), fromBelow: below)
                            let at = 4 * (((b * d + k) * n + j) * n + i)
                            texels[at] = Float(r.single)
                            texels[at + 1] = Float(r.sunDiffuse)
                            texels[at + 2] = Float(r.sky)
                            texels[at + 3] = Float(r.transmittance)
                        }
                    }
                }
            }
        }
        self.texels = texels
    }

    /// The renderer's LUT: the layer model's low and mid layers.
    public static func standard(lighting: CloudLighting = CloudLighting()) -> CloudSlabLUT {
        CloudSlabLUT(slabs: [CloudSlab(thickness: CloudLayerModel.lowDepth, lighting: lighting),
                             CloudSlab(thickness: CloudLayerModel.midTop - CloudLayerModel.midBase, lighting: lighting)])
    }

    /// Grid point k's optical depth.
    public static func depth(_ k: Int) -> Double {
        minDepth * pow(maxDepth / minDepth, Double(k) / Double(depths - 1))
    }

    /// Grid point j's cosine.
    public static func cosine(_ j: Int) -> Double {
        minCosine + (1 - minCosine) * Double(j) / Double(cosines - 1)
    }

    /// The fractional grid coordinate of an optical depth (clamped to the
    /// grid), as the shader computes it.
    public static func depthCoordinate(_ tau: Double) -> Double {
        let x = log(max(tau, minDepth) / minDepth) / log(maxDepth / minDepth) * Double(depths - 1)
        return min(max(x, 0), Double(depths - 1))
    }

    public static func cosineCoordinate(_ mu: Double) -> Double {
        min(max((mu - minCosine) / (1 - minCosine) * Double(cosines - 1), 0), Double(cosines - 1))
    }
}
