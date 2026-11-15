import Foundation
import OrbitCore

/// The light around a vessel or a site that the vessel pass shades with
/// until the tracks that own each part of it land (R2's documented
/// stand-in for M1.5's `vesselLight` heuristics, in physical units):
///
/// - **Earthshine** (R3's probe replaces it): the reference body as a disc
///   of uniform radiance, its reflectance (albedo × its reflected colour /
///   π, `LegacyLighting`'s) times the irradiance on its ground: the Sun at
///   the disc's mean cosine (`litCosine`, the solid-angle mean of the Sun's
///   cosine over the disc the vessel sees, 0 where it is night), and in
///   air A2's transmitted Sun and its sky (the vessel shader adds those).
///   The diffuse irradiance is that radiance times the sphere's view factor
///   with its horizon (`BRDF.sphereIrradiance`); the specular lobe sees the
///   disc where the reflection meets it. M1.5 used the lit share of the
///   disc instead of its mean cosine, so its ground was as bright under a
///   low Sun as under a high one.
/// - **Sky light** in air (A2's sky irradiance replaces it): M1.5's
///   0.25 √(ρ/ρ₀) times the Sun's share and elevation, as a uniform
///   irradiance in units of E⊙.
/// - **Night floor** (R3's probe replaces it): M1.5's 0.02, now relative to
///   the exposure (R1's rule): a uniform light that shows a surface at
///   0.02 × its albedo of the exposure's white whatever the exposure, so a
///   side away from the Sun and the Earth is never black, and the auto
///   exposure does not lift the night side to day (`floorIlluminance`).
/// - **Glow:** the heat shield's luminance (`RenderScene.Vessel.glow`, R1's
///   grey body), strongest facing the flow.
///
/// M1.5 lit with the same terms in units of the Sun (`LegacyLighting`).
public struct ObjectLighting: Equatable {
    /// Unit vector to the Sun (world) and its visible share (`Eclipse`).
    public var toSun: Vec3
    public var sunlit: Double
    /// Unit vector to the reference body's centre (world); zero for none.
    public var earthDirection: Vec3
    /// sin² of the body's angular radius seen from here (0 for none).
    public var earthSinSigma2: Double
    /// The lit disc's mean radiance without air, cd/m², linear Rec. 709:
    /// `earthReflectance` × R1's Sun (above the air) × `earthLitCosine`.
    public var earthRadiance: RenderScene.RGB
    /// The ground's reflectance, albedo × its colour / π (cd/m² per lux).
    public var earthReflectance: RenderScene.RGB
    /// The Sun's mean cosine over the disc seen (`StandInLighting.litCosine`).
    public var earthLitCosine: Double
    /// Uniform irradiance from the daylit sky, lux.
    public var sky: Double
    /// The night floor: the share of the exposure's white a white surface
    /// shows by it (`StandInLighting.floorIlluminance` makes it lux).
    public var floor: Double
    /// Emitted on heat-shield vertices, cd/m², strongest facing the flow.
    public var glow: RenderScene.RGB
    /// Unit velocity through the air (world); zero in vacuum.
    public var flowDirection: Vec3

    public init(toSun: Vec3, sunlit: Double, earthDirection: Vec3 = .zero, earthSinSigma2: Double = 0,
                earthRadiance: RenderScene.RGB = .black, earthReflectance: RenderScene.RGB = .black,
                earthLitCosine: Double = 0, sky: Double = 0, floor: Double = 0, glow: RenderScene.RGB = .black,
                flowDirection: Vec3 = .zero) {
        self.toSun = toSun
        self.sunlit = sunlit
        self.earthDirection = earthDirection
        self.earthSinSigma2 = earthSinSigma2
        self.earthRadiance = earthRadiance
        self.earthReflectance = earthReflectance
        self.earthLitCosine = earthLitCosine
        self.sky = sky
        self.floor = floor
        self.glow = glow
        self.flowDirection = flowDirection
    }
}

public enum StandInLighting {
    /// M1.5's night floor, relative to the exposure.
    public static let nightFloor = 0.02

    /// The uniform illuminance (lux) of a night floor `floor` at
    /// pre-exposure `preExposure`: a white Lambertian surface then shows
    /// floor × π / P / π × P = floor of the exposure's white.
    public static func floorIlluminance(_ floor: Double, preExposure: Double) -> Double {
        floor * Double.pi / max(preExposure, 1e-30)
    }

    /// The light around vessel `v` of `scene`.
    public static func vessel(_ v: RenderScene.Vessel, in scene: RenderScene) -> ObjectLighting {
        let e = scene.sun.illuminance, light = v.light
        var out = ObjectLighting(toSun: light.toSun, sunlit: light.sunlit,
                                 sky: e * light.sky, floor: nightFloor, glow: v.glow,
                                 flowDirection: v.flowDirection)
        if light.earthStrength > 0 {
            // earthStrength is the body's albedo × min(1, (R/r)²).
            let albedo = groundReflectance(bodyID: v.referenceBodyID).albedo
            let s2 = min(1, light.earthStrength / albedo)
            out.earthDirection = light.earthDirection
            out.earthSinSigma2 = s2
            out.earthReflectance = scaled(light.earthColor, albedo / Double.pi)
            out.earthLitCosine = litCosine(toBody: light.earthDirection, sinSigma2: s2, toSun: light.toSun)
            out.earthRadiance = ground(out.earthReflectance, sun: e, cosine: out.earthLitCosine)
        }
        return out
    }

    /// The solid-angle mean of max(cos ψ, 0) over the disc of a sphere seen
    /// from a point outside it, ψ the angle between the ground's normal and
    /// the Sun: the share of the Sun's irradiance its ground gets on
    /// average, as the vessel sees it. `toBody`: unit vector to the
    /// sphere's centre; `sinSigma2`: sin² of its angular radius, (R/r)²
    /// (1 on the ground, where the disc is the flat ground below and the
    /// mean is the Sun's elevation's sine); `toSun`: unit vector to the Sun.
    /// From afar it is the Lambert disc's: 2/3 at full phase, 2/(3π) at
    /// quarter phase. A midpoint rule over equal solid angles (16 rings, 32
    /// azimuths).
    public static func litCosine(toBody: Vec3, sinSigma2: Double, toSun: Vec3) -> Double {
        let s2 = max(0, min(1, sinSigma2))
        guard s2 > 0, toBody.length > 0 else { return 0 }
        let d = toBody.normalized
        // The vessel at distance r = 1/sin σ from the centre (R = 1), at -d.
        let r = 1 / s2.squareRoot(), cosSigma = (1 - s2).squareRoot()
        let e1 = VisualShape.defaultReference(for: d), e2 = d.cross(e1)
        let rings = 16, azimuths = 32
        var sum = 0.0
        for i in 0..<rings {
            let cosAlpha = cosSigma + (1 - cosSigma) * (Double(i) + 0.5) / Double(rings)
            let sinAlpha = max(0, 1 - cosAlpha * cosAlpha).squareRoot()
            // Distance to the near side along the ray (0 on the ground).
            let t = r * cosAlpha - max(0, 1 - r * r * sinAlpha * sinAlpha).squareRoot()
            for k in 0..<azimuths {
                let phi = 2 * Double.pi * (Double(k) + 0.5) / Double(azimuths)
                let omega = d * cosAlpha + (e1 * cos(phi) + e2 * sin(phi)) * sinAlpha
                let normal = (d * -r + omega * t).normalized
                sum += max(normal.dot(toSun), 0)
            }
        }
        return sum / Double(rings * azimuths)
    }

    /// The ground's radiance without air: reflectance × R1's Sun (`sun` lux
    /// in its 5772 K colour, as the frame's `sunIlluminance`) × the mean
    /// cosine.
    static func ground(_ reflectance: RenderScene.RGB, sun lux: Double, cosine: Double) -> RenderScene.RGB {
        let c = Photometry.sunColor.scaled(by: lux * cosine)
        return RenderScene.RGB(reflectance.r * Float(c.r), reflectance.g * Float(c.g), reflectance.b * Float(c.b))
    }

    /// The light around site `s` of `scene` (the pad), as M1.5's
    /// heuristics light a vessel standing there: the Sun's share from its
    /// elevation over the geodetic horizon, the ground below filling the
    /// lower half of the sky, lit at the Sun's elevation's sine, and the
    /// sea-level sky.
    public static func site(_ s: RenderScene.Site, in scene: RenderScene) -> ObjectLighting {
        let e = scene.sun.illuminance
        let up = s.orientation.c2.normalized, toSun = scene.sun.direction
        let elevation = asin(max(-1, min(1, up.dot(toSun))))
        let rho = max(scene.sun.angularRadius, 1e-6)
        let sunlit = max(0, min(1, (elevation + rho) / (2 * rho)))
        let reflect = groundReflectance(bodyID: s.bodyID)
        let reflectance = scaled(reflect.color, reflect.albedo / Double.pi)
        let cosine = litCosine(toBody: -up, sinSigma2: 1, toSun: toSun)
        let t = max(0, min(1, (sin(elevation) + 0.1) / 0.35))
        let sky = LegacyLighting.skylight * t * t * (3 - 2 * t) * sunlit
        return ObjectLighting(toSun: toSun, sunlit: sunlit, earthDirection: -up, earthSinSigma2: 1,
                              earthRadiance: ground(reflectance, sun: e, cosine: cosine),
                              earthReflectance: reflectance, earthLitCosine: cosine, sky: e * sky, floor: nightFloor)
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
