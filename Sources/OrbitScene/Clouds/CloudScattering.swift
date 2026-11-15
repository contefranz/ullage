import Foundation

// Track C2: how light scatters in the clouds the renderer marches. The phase
// functions, the multiple-scattering octaves, and the lighting of one sample
// of the march, which CloudShaders' `cloud_inScattering` mirrors line for
// line. The far regime's slab-BRDF LUT (CloudSlab.swift) is this same
// lighting marched through a flat, homogeneous slab, so the three regimes
// agree by construction.

/// Phase functions, in 1/sr, of the cosine of the scattering angle: the
/// cosine between the view ray (outward from the eye) and the direction to
/// the Sun, as A1's atmosphere has it, so 1 is looking straight at the Sun
/// through the cloud (forward scattering).
public enum CloudPhase {
    /// Henyey and Greenstein 1941: (1 − g²) / (4π (1 + g² − 2g cos θ)^{3/2}).
    public static func henyeyGreenstein(_ cosTheta: Double, g: Double) -> Double {
        let d = 1 + g * g - 2 * g * cosTheta
        return (1 - g * g) / (4 * .pi * d * d.squareRoot())
    }

    /// Draine 2003 (ApJ 598, 1017, eq. 4): Henyey-Greenstein times
    /// (1 + α cos² θ), normalised.
    public static func draine(_ cosTheta: Double, g: Double, alpha: Double) -> Double {
        henyeyGreenstein(cosTheta, g: g) * (1 + alpha * cosTheta * cosTheta) / (1 + alpha * (1 + 2 * g * g) / 3)
    }

    /// The mean cosine of Draine's function.
    public static func draineAsymmetry(g: Double, alpha: Double) -> Double {
        g * (1 + alpha * (3 + 2 * g * g) / 5) / (1 + alpha * (1 + 2 * g * g) / 3)
    }

    /// Jendersie and d'Eon 2023 ("An Approximate Mie Scattering Function
    /// for Fog and Cloud Rendering", SIGGRAPH Talks): water droplets of
    /// diameter d (µm, 5-50) scatter as a blend of Henyey-Greenstein (the
    /// diffraction peak) and Draine (the body and the backscatter), with
    /// their fits for the parameters.
    public struct ApproximateMie: Equatable {
        public var gHG: Double
        public var gDraine: Double
        public var alpha: Double
        public var weightDraine: Double

        public init(diameter d: Double) {
            gHG = exp(-0.0990567 / (d - 1.67154))
            gDraine = exp(-2.20679 / (d + 3.91029) - 0.428934)
            alpha = exp(3.62489 - 8.29288 / (d + 5.52825))
            weightDraine = exp(-0.599085 / (d - 0.641583) - 0.665888)
        }

        public func phase(_ cosTheta: Double) -> Double {
            (1 - weightDraine) * henyeyGreenstein(cosTheta, g: gHG)
                + weightDraine * draine(cosTheta, g: gDraine, alpha: alpha)
        }

        /// The mean cosine of the blend.
        public var asymmetry: Double {
            (1 - weightDraine) * gHG + weightDraine * draineAsymmetry(g: gDraine, alpha: alpha)
        }
    }
}

/// The lighting of one sample of the cloud march, per unit irradiance (the
/// shader multiplies by the Sun's and the sky's), in 1/sr per unit
/// extinction:
/// - the Sun's light scattered once, with the approximate Mie phase,
///   through the optical depth the light march finds towards the Sun;
/// - the light scattered many times, as the diffuse streams of the
///   two-stream slab C1 checks the clouds against (Bohren 1987; C1's
///   `CloudOptics.slabReflectance`), of the column the sample sits in: its
///   optical depth from the local extinction times the layer's thickness,
///   the sample's depth in it from its height in the layer or from the
///   light march, whichever is less (a sunlit side is near the Sun's side
///   of the cloud however low it is);
/// - the sky's light, entering the same column diffusely from above.
///
/// The design's octaves of multiple scattering (Wrenninge, Kulla and
/// Lundqvist 2013) were tried first and dropped: their light comes out of
/// the top optical depth or so of the cloud only, so with Hillaire's
/// a = b = c = 0.5 and three octaves a deck of τ = 90 came out darker than
/// one of τ = 3 (plane albedo 0.09 against 0.18, the Sun 60° from the
/// zenith), where the two-stream slab has 0.87 against 0.18.
public struct CloudLighting: Equatable {
    /// The droplets' diameter, µm, for the phase of single scattering
    /// (approximate Mie): 20 µm is the layer model's 10 µm effective radius.
    public var dropletDiameter = 20.0
    /// The asymmetry the diffuse streams scatter with: C1's water droplets'
    /// (CloudLayerModel.waterAsymmetry), whose two-stream slab is the check.
    public var asymmetry = CloudLayerModel.waterAsymmetry
    /// The light march: `lightSamples` samples over `lightDistance` (m)
    /// towards the Sun, the segments growing quadratically from the sample.
    public var lightSamples = 4
    public var lightDistance = 1_500.0
    /// The least cosine of the Sun's zenith the diffuse streams are fed
    /// with: a cloud lit by a low Sun takes it on its sides as well as its
    /// top.
    public var minimumSunCosine = 0.08

    public init() {}

    /// The phase of single scattering.
    public var mie: CloudPhase.ApproximateMie { CloudPhase.ApproximateMie(diameter: dropletDiameter) }

    /// The two-stream backscattered fraction, (1 − g)/2.
    public var backscatter: Double { (1 - asymmetry) / 2 }

    /// The two-stream slab's downward and upward fluxes at optical depth
    /// `t` from the top of a column of optical depth `tau`, per unit flux
    /// entering its top: 1 − bt/(1 + bτ) and b(τ − t)/(1 + bτ). The upward
    /// flux at the top is the slab's reflectance, bτ/(1 + bτ).
    public func streams(depth t: Double, column tau: Double) -> (down: Double, up: Double) {
        let b = backscatter, t = min(max(t, 0), tau)
        return (1 - b * t / (1 + b * tau), b * (tau - t) / (1 + b * tau))
    }

    /// The radiance of the diffuse streams going in a direction whose
    /// upward cosine is `muUp` (the light's travel: towards an eye above,
    /// positive), per unit flux entering the top: each stream isotropic over
    /// its hemisphere, F/π, blended by the direction.
    static func streamRadiance(down: Double, up: Double, muUp: Double) -> Double {
        let w = 0.5 * (1 + min(max(muUp, -1), 1))
        return (w * up + (1 - w) * down) / .pi
    }

    /// The sample's depth in its column, optical depth from the column's
    /// top: from its height fraction h in the layer, or, when the light
    /// march came out of the cloud (`escaped`: its last sample in clear
    /// air), from its optical depth towards the Sun made vertical, the
    /// lesser. A light march that never left the cloud says only that the
    /// Sun's side is far: then the height decides.
    public func columnDepth(column tau: Double, heightFraction h: Double, sunOpticalDepth: Double,
                            sunCosine mu0: Double, escaped: Bool = true) -> Double {
        let byHeight = tau * (1 - min(max(h, 0), 1))
        return escaped ? min(byHeight, sunOpticalDepth * max(mu0, minimumSunCosine)) : byHeight
    }

    /// The Sun's light scattered many times towards the eye, per unit solar
    /// irradiance: the diffuse streams of the column fed by the Sun's flux
    /// on the horizontal, less the direct beam the single scattering has.
    public func sunDiffuse(depth t: Double, column tau: Double, sunCosine mu0: Double, muUp: Double) -> Double {
        let flux = max(mu0, minimumSunCosine), s = streams(depth: t, column: tau)
        let diffuseDown = max(s.down - exp(-t / flux), 0)
        return flux * Self.streamRadiance(down: diffuseDown, up: s.up, muUp: muUp)
    }

    /// The sky's light scattered towards the eye, per unit sky irradiance
    /// (on the horizontal): the streams of the column fed diffusely from
    /// above, at the sample's vertical depth.
    public func skyDiffuse(column tau: Double, heightFraction h: Double, muUp: Double) -> Double {
        let s = streams(depth: tau * (1 - min(max(h, 0), 1)), column: tau)
        return Self.streamRadiance(down: s.down, up: s.up, muUp: muUp)
    }

    /// The light march's segment ends, as fractions of `lightDistance`:
    /// (k / K)², k = 0...K. Its samples sit at the segments' midpoints.
    public var lightSegmentEnds: [Double] {
        (0...lightSamples).map { k in pow(Double(k) / Double(lightSamples), 2) }
    }
}
