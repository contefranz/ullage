import Foundation
import OrbitCore

/// The light around a vessel or a site that the vessel pass shades with
/// until the tracks that own each part of it land (R2's documented
/// stand-in for M1.5's `vesselLight` heuristics, in physical units):
///
/// - **Earthshine** (R3's probe replaces it): the reference body as a disc
///   of uniform radiance, albedo × E⊙ × the lit share of the disc the
///   vessel sees / π, in its reflected colour (`LegacyLighting`'s albedo,
///   lit share and colour). The diffuse irradiance is that radiance times
///   the sphere's view factor with its horizon (`BRDF.sphereIrradiance`),
///   which is M1.5's albedo (R/r)² cos θ wherever the whole disc is above
///   the surface's horizon; the specular lobe sees the disc where the
///   reflection meets it.
/// - **Sky light** in air (A2's sky irradiance replaces it): M1.5's
///   0.25 √(ρ/ρ₀) times the Sun's share and elevation, as a uniform
///   irradiance in units of E⊙.
/// - **Night floor** (R3's floor relative to the exposure replaces it):
///   M1.5's 0.02 E⊙, uniform, so a side away from the Sun and the Earth is
///   never black.
/// - **Glow:** the heat shield's (`LegacyLighting.glowColor`, 1 for white
///   paint in sunlight) times E⊙ at 1 AU / π, in cd/m², until R1's
///   blackbody glow.
///
/// M1.5 lit with the same terms in units of the Sun (`LegacyLighting`);
/// with the stand-in exposure (`preExposure`, EV 15) the vehicle reads as
/// it did, until R1's exposure takes over.
public struct ObjectLighting: Equatable {
    /// Unit vector to the Sun (world) and its visible share (`Eclipse`).
    public var toSun: Vec3
    public var sunlit: Double
    /// Unit vector to the reference body's centre (world); zero for none.
    public var earthDirection: Vec3
    /// sin² of the body's angular radius seen from here (0 for none).
    public var earthSinSigma2: Double
    /// The lit disc's mean radiance, cd/m², linear Rec. 709.
    public var earthRadiance: RenderScene.RGB
    /// Uniform irradiance from the daylit sky, lux.
    public var sky: Double
    /// Uniform irradiance of the night floor, lux.
    public var floor: Double
    /// Emitted on heat-shield vertices, cd/m², strongest facing the flow.
    public var glow: RenderScene.RGB
    /// Unit velocity through the air (world); zero in vacuum.
    public var flowDirection: Vec3

    public init(toSun: Vec3, sunlit: Double, earthDirection: Vec3 = .zero, earthSinSigma2: Double = 0,
                earthRadiance: RenderScene.RGB = .black, sky: Double = 0, floor: Double = 0, glow: RenderScene.RGB = .black,
                flowDirection: Vec3 = .zero) {
        self.toSun = toSun
        self.sunlit = sunlit
        self.earthDirection = earthDirection
        self.earthSinSigma2 = earthSinSigma2
        self.earthRadiance = earthRadiance
        self.sky = sky
        self.floor = floor
        self.glow = glow
        self.flowDirection = flowDirection
    }
}

public enum StandInLighting {
    /// The exposure the vessel pass uses until R1's (FrameUniforms.exposure
    /// still (1, 0, 1, 0)): EV100 15, "sunny 16", so sunlit white paint
    /// (albedo 0.8) reads about 0.84.
    public static let exposureEV100 = 15.0
    /// 1 / (1.2 · 2^EV100) (Lagarde and de Rousiers 2014, eq. 12).
    public static var preExposure: Double { 1 / (1.2 * pow(2, exposureEV100)) }

    /// The heat-shield glow's scale: `LegacyLighting.glowColor` 1 is as
    /// bright as a white Lambertian surface in sunlight at 1 AU, E⊙/π.
    public static var glowScale: Double { Photometry.solarIlluminanceAt1AU / Double.pi }

    /// The light around vessel `v` of `scene`.
    public static func vessel(_ v: RenderScene.Vessel, in scene: RenderScene) -> ObjectLighting {
        let e = scene.sun.illuminance, light = v.light
        var out = ObjectLighting(toSun: light.toSun, sunlit: light.sunlit,
                                 sky: e * light.sky, floor: e * Double(LegacyLighting.ambientFloor),
                                 glow: scaled(v.glow, glowScale),
                                 flowDirection: v.flowDirection)
        if light.earthStrength > 0 {
            // earthStrength is the body's albedo × min(1, (R/r)²).
            let albedo = groundReflectance(bodyID: v.referenceBodyID).albedo
            let s2 = min(1, light.earthStrength / albedo)
            out.earthDirection = light.earthDirection
            out.earthSinSigma2 = s2
            out.earthRadiance = scaled(light.earthColor, e * albedo * light.earthLit / Double.pi)
        }
        return out
    }

    /// The light around site `s` of `scene` (the pad), as M1.5's
    /// heuristics light a vessel standing there: the Sun's share from its
    /// elevation over the geodetic horizon, the ground below as the
    /// reference body's lit disc filling the lower half of the sky, and
    /// the sea-level sky.
    public static func site(_ s: RenderScene.Site, in scene: RenderScene) -> ObjectLighting {
        let e = scene.sun.illuminance
        let up = s.orientation.c2.normalized, toSun = scene.sun.direction
        let elevation = asin(max(-1, min(1, up.dot(toSun))))
        let rho = max(scene.sun.angularRadius, 1e-6)
        let sunlit = max(0, min(1, (elevation + rho) / (2 * rho)))
        let reflect = groundReflectance(bodyID: s.bodyID)
        // M1.5's lit share at the surface: the cap shrinks to 0.02 rad.
        let lit = max(0, min(1, (elevation + 0.02) / 0.04))
        let t = max(0, min(1, (sin(elevation) + 0.1) / 0.35))
        let sky = LegacyLighting.skylight * t * t * (3 - 2 * t) * sunlit
        return ObjectLighting(toSun: toSun, sunlit: sunlit, earthDirection: -up, earthSinSigma2: 1,
                              earthRadiance: scaled(reflect.color, e * reflect.albedo * lit / Double.pi),
                              sky: e * sky, floor: e * Double(LegacyLighting.ambientFloor))
    }

    /// `LegacyLighting.reflectance` by NAIF id.
    static func groundReflectance(bodyID: Int) -> (albedo: Double, color: RenderScene.RGB) {
        switch bodyID {
        case 399: return (0.30, RenderScene.RGB(0.78, 0.88, 1.0))
        case 301: return (0.12, RenderScene.RGB(1.0, 0.97, 0.93))
        case 499: return (0.25, RenderScene.RGB(1.0, 0.72, 0.52))
        default: return (0.25, RenderScene.RGB(1, 1, 1))
        }
    }

    static func scaled(_ c: RenderScene.RGB, _ k: Double) -> RenderScene.RGB {
        RenderScene.RGB(c.r * Float(k), c.g * Float(k), c.b * Float(k))
    }
}
