import Foundation
import OrbitCore

/// The M1.5 renderer's lighting of a vessel, kept so the scene renders as it
/// did until the physically based tracks replace it (R2's BRDF, R3's
/// earthshine from the probe, A2's sky light). Visual approximations.
public struct LegacyLight {
    /// Unit vector to the Sun (world).
    public var toSun: Vec3
    /// The Sun's visible share (`Eclipse`: Earth and Moon as occulters).
    public var sunlit: Double
    /// The daylit sky's light in air, added to the ambient floor.
    public var sky: Double
    /// Unit vector to the reference body's centre (world); zero for none.
    public var earthDirection: Vec3
    /// The lit share of the body's disc the vessel sees.
    public var earthLit: Double
    /// Earthshine irradiance from the whole disc lit (Sun = 1).
    public var earthStrength: Double
    /// The earthshine's colour.
    public var earthColor: RenderScene.RGB

    public init(toSun: Vec3, sunlit: Double, sky: Double, earthDirection: Vec3, earthLit: Double,
                earthStrength: Double, earthColor: RenderScene.RGB) {
        self.toSun = toSun
        self.sunlit = sunlit
        self.sky = sky
        self.earthDirection = earthDirection
        self.earthLit = earthLit
        self.earthStrength = earthStrength
        self.earthColor = earthColor
    }
}

public enum LegacyLighting {
    /// Ambient light: a floor that keeps an unlit side from going black.
    public static let ambientFloor: Float = 0.02
    /// Skylight at sea level with the Sun well up, falling with the square
    /// root of the air's density and fading out as the Sun sets.
    public static let skylight = 0.25

    /// The Sun's direction and share (`Eclipse`: Earth and Moon as
    /// occulters), the sky's light in air, and the light the reference body
    /// reflects onto the vessel: its albedo over the share of the sky it
    /// fills, (R/r)², times the lit part of the cap the vessel sees (a cap of
    /// half-angle acos(R/r) about the nadir, the terminator crossing it as
    /// the vessel's Sun-centre-vessel angle passes 90°). Visual
    /// approximations, like earthshine's colour.
    public static func light(_ v: Vessel, snapshot snap: SystemSnapshot, system: SolarSystem, sun: Vec3) -> LegacyLight {
        let position = snap.position(v.reference) + v.position
        let toSun = (sun - position).normalized
        let sunlit = Eclipse.sunlitFraction(at: v.position, relativeTo: v.reference, in: system, snapshot: snap)
        var earth = Vec3.zero, lit = 0.0, strength = 0.0, colour = RenderScene.RGB.black
        let body = v.reference, r = v.position.length
        if body !== system.sun, r > 0 {
            let reflect = reflectance(of: body)
            let bodyToSun = (sun - snap.position(body)).normalized
            let phase = acos(max(-1, min(1, bodyToSun.dot(v.position / r))))
            let cap = max(acos(min(1, body.radius / r)), 0.02)
            lit = max(0, min(1, (Double.pi / 2 - phase + cap) / (2 * cap)))
            earth = -v.position / r
            strength = reflect.albedo * min(1, (body.radius / r) * (body.radius / r))
            colour = reflect.color
        }
        // In air, the daylit sky lights the shaded side too.
        var sky = 0.0
        if v.atmosphere.density > 0, r > 0 {
            let elevation = toSun.dot(v.position / r)
            let t = max(0, min(1, (elevation + 0.1) / 0.35))
            sky = skylight * min(1, v.atmosphere.density / 1.225).squareRoot() * t * t * (3 - 2 * t) * sunlit
        }
        return LegacyLight(toSun: toSun, sunlit: sunlit, sky: sky, earthDirection: earth, earthLit: lit,
                           earthStrength: strength, earthColor: colour)
    }

    /// Bond albedo (rounded) and the reflected light's colour.
    public static func reflectance(of body: CelestialBody) -> (albedo: Double, color: RenderScene.RGB) {
        switch body.id {
        case 399: return (0.30, RenderScene.RGB(0.78, 0.88, 1.0))
        case 301: return (0.12, RenderScene.RGB(1.0, 0.97, 0.93))
        case 499: return (0.25, RenderScene.RGB(1.0, 0.72, 0.52))
        default: return (0.25, RenderScene.RGB(1, 1, 1))
        }
    }

    /// The vessel's velocity through the air (world, unit), zero in vacuum.
    public static func flowDirection(_ v: Vessel, snapshot: SystemSnapshot) -> Vec3 {
        guard v.atmosphere.density > 0 else { return .zero }
        let air = v.surfaceVelocity(snapshot: snapshot)
        return air.length > 1 ? air.normalized : .zero
    }

    // MARK: Heat-shield glow

    /// First-order lag of the glow behind the heat flux, s of simulation time
    /// (a visual choice: the ablator's surface follows the heating in seconds).
    public static let thermalLag = 6.0

    /// The ablator's emissivity.
    public static let heatShieldEmissivity = 0.85

    /// The heat shield's glow for a heat flux `q` (W/m²): its luminance,
    /// cd/m² in linear Rec. 709, at the radiative-equilibrium temperature of
    /// an ablator of emissivity 0.85, a grey body (`Photometry.glow`; it
    /// replaces M1.5's Tanner Helland fit). It shows from about 800 K, the
    /// Draper point, as the exposure lets it. `SceneExtractor` lags the flux
    /// (`thermalLag`) in simulation time, so it neither flickers at warp nor
    /// freezes when paused.
    public static func glowLuminance(heatFlux q: Double) -> RenderScene.RGB {
        let c = Photometry.glow(heatFlux: q, emissivity: heatShieldEmissivity).luminance
        return RenderScene.RGB(Float(c.r), Float(c.g), Float(c.b))
    }
}
