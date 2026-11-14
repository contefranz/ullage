import Foundation
import OrbitCore

/// The atmosphere as one frame sees it, in double precision: the Earth's
/// figure coordinates around the camera, the Sun in them, and the light the
/// air passes to the camera, the values track A2 shares through
/// `AtmosphereUniforms` (docs/look/atmosphere.md):
///
/// - `sunTransmitted`: the Sun's light at the camera through the air, as a
///   unitless colour (A1's transmittance per channel times R1's 5772 K colour
///   at unit luminance, `Photometry.sunColor`) and the illuminance it scales,
///   lux above the air (`RenderScene.Sun.illuminance`). Their product is the
///   Sun's lux per channel: with no air in the way it is
///   `FrameUniforms.sunIlluminance.rgb`; behind the Earth it is 0.
/// - `skyIrradiance`: the sky's light, without the direct Sun, on a
///   horizontal surface facing up at the camera, lux per channel (A1's
///   irradiance table); 0 above the air.
///
/// Figure coordinates are the body axes with z stretched by a/b, where the
/// WGS-84 ellipsoid is the sphere of radius a that A1's optics stand on; the
/// renderer marches in them (`OpticalAtmosphere.sunTransmittance` does too).
public struct AtmosphereFrame {
    /// The planet with an atmosphere: the Earth.
    public static let planetID = 399
    /// The highest cloud top the froxels must reach beyond the horizon, m.
    public static let cloudTop = 12_000.0

    public let planet: RenderScene.Body
    /// The ground (the figure's equatorial radius) and the top, m.
    public let bottomRadius: Double
    public let topRadius: Double
    /// a/b.
    public let stretch: Double
    /// World (ICRF axes) to figure coordinates, for directions: the body
    /// rotation, then z times `stretch` (normalise after).
    public let worldToFigure: Mat3
    /// The camera relative to the planet's centre, figure coordinates, m.
    public let camera: Vec3
    /// |camera|, m.
    public let cameraRadius: Double
    /// Unit vector to the Sun, figure coordinates.
    public let sun: Vec3
    /// The Sun's zenith cosine at the camera (figure coordinates).
    public let cosSunZenith: Double
    /// The camera's zenith (figure coordinates, unit).
    public let up: Vec3
    /// The horizontal unit vector toward the Sun's azimuth at the camera:
    /// the sky-view LUT's φ = 0 (any horizontal one with the Sun at zenith or nadir).
    public let sunAzimuth: Vec3
    /// The Sun's transmittance from the camera, per channel (A1).
    public let sunTransmittance: Spectrum3
    /// The Sun's lux above the air at the camera.
    public let sunIlluminance: Double
    /// The froxels' slices this frame.
    public let froxels: FroxelSlices

    /// The camera's altitude above the optics' sphere, m (within 0.34 % of geodetic).
    public var cameraAltitude: Double { cameraRadius - bottomRadius }
    /// Whether the camera is inside the atmosphere (below its top): the sky
    /// comes from the sky-view LUT; outside, each pixel marches.
    public var isInside: Bool { cameraRadius < topRadius }

    /// The Sun's colour through the air (unitless) and the lux it scales.
    public var sunTransmitted: (color: Photometry.RGB, illuminance: Double) {
        let c = Photometry.sunColor, t = sunTransmittance
        return (Photometry.RGB(c.r * t.r, c.g * t.g, c.b * t.b), sunIlluminance)
    }

    /// The frame's atmosphere, nil when the scene has no Earth.
    public init?(scene: RenderScene, tables: AtmosphereLUT, froxelSlices: Int = 32, froxelExponent: Double = 2) {
        guard let earth = scene.bodies.first(where: { $0.id == Self.planetID }) else { return nil }
        planet = earth
        bottomRadius = tables.bottomRadius
        topRadius = tables.topRadius
        stretch = earth.figure.equatorialRadius / earth.figure.polarRadius
        let toBody = earth.orientation.icrfToBody
        worldToFigure = Mat3(rows: toBody.r0, toBody.r1, toBody.r2 * stretch)
        let body = earth.orientation.toBody(-earth.position)
        camera = Vec3(body.x, body.y, body.z * stretch)
        cameraRadius = camera.length
        sun = (worldToFigure * scene.sun.direction).normalized
        up = camera.normalized
        cosSunZenith = min(max(sun.dot(up), -1), 1)
        let horizontal = sun - up * cosSunZenith
        if horizontal.length > 1e-9 {
            sunAzimuth = horizontal.normalized
        } else {
            let any = abs(up.x) < 0.9 ? Vec3.unitX : Vec3.unitY
            sunAzimuth = (any - up * any.dot(up)).normalized
        }
        sunTransmittance = tables.optics.sunTransmittance(position: body,
                                                         sunDir: earth.orientation.toBody(scene.sun.direction))
        sunIlluminance = scene.sun.illuminance
        froxels = FroxelSlices(count: froxelSlices,
                               far: FroxelSlices.far(cameraAltitude: max(cameraRadius - bottomRadius, 0),
                                                     bottomRadius: bottomRadius),
                               exponent: froxelExponent)
        skyTable = cameraRadius < topRadius
            ? tables.skyIrradiance(radius: max(cameraRadius, bottomRadius), cosSun: cosSunZenith) : .zero
    }

    private let skyTable: Spectrum3

    /// The sky's irradiance on a horizontal surface facing up at the camera,
    /// lux per channel.
    public var skyIrradiance: Photometry.RGB {
        let c = Photometry.sunColor, e = sunIlluminance
        return Photometry.RGB(skyTable.r * c.r * e, skyTable.g * c.g * e, skyTable.b * c.b * e)
    }

    /// The Sun's light per unit solar irradiance (A1's tables) to lux or
    /// cd/m² per channel: E⊙ times R1's colour at unit luminance.
    public var solarScale: Photometry.RGB { Photometry.sunColor.scaled(by: sunIlluminance) }

    /// A world direction in figure coordinates, unit.
    public func figureDirection(_ worldDirection: Vec3) -> Vec3 {
        (worldToFigure * worldDirection).normalized
    }

    /// The sky-view LUT's angles for a world direction: zenith cosine at the
    /// camera and azimuth cosine from the Sun's vertical.
    public func skyViewAngles(_ worldDirection: Vec3) -> (cosZenith: Double, cosAzimuth: Double) {
        let d = figureDirection(worldDirection)
        let mu = min(max(d.dot(up), -1), 1)
        let h = d - up * mu
        let cosAzimuth = h.length > 1e-12 ? min(max(h.normalized.dot(sunAzimuth), -1), 1) : 1
        return (mu, cosAzimuth)
    }
}
