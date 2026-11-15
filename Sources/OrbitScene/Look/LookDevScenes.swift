import Foundation
import OrbitCore

/// Track R2's look-dev scenes: `RenderScene`s built directly, with no
/// body, star or plume in view, so that only the vessel pass draws them
/// and their goldens move only when the shading does.
///
/// The light is fixed: the Sun at 1 AU from the upper left, and the Earth
/// as the vessel pass's stand-in sees it from 185 km (a disc of albedo 0.3
/// below, fully lit, sin² σ = (R/r)²), with the night floor. The camera
/// sits at the origin looking along +y, +z up.
public enum LookDevScenes {
    /// 14:00 UTC on 16 July 1969, the look-dev scenes' epoch (only the
    /// clock reads it).
    public static let epoch = Epoch(utcYear: 1969, month: 7, day: 16, hour: 14, minute: 0)
    /// Unit vector to the Sun: from the camera's left, in front, above.
    public static let toSun = Vec3(-0.55, -0.5, 0.67).normalized
    /// sin² of the Earth's angular radius from 185 km.
    public static let earthSinSigma2 = pow(6_371_000.0 / 6_556_000.0, 2)

    /// The material spheres: three rows of five 1 m spheres, 20 m away.
    /// Top: a metal of F0 0.91 (aluminium) at roughness 0.05, 0.25, 0.45,
    /// 0.65 and 0.85; middle: white paint (albedo 0.8) at the same; bottom:
    /// Apollo finishes, the CM's foil, the SM's aluminium, white paint,
    /// zinc-chromate primer and the ablator.
    public static func materialSpheres(width: Int = 640, height: Int = 400) -> RenderScene {
        let roughness = [0.05, 0.25, 0.45, 0.65, 0.85]
        var shapes: [VisualShape] = []
        func sphere(column: Int, row: Int, _ material: MaterialKey, _ colour: (Double, Double, Double)) {
            let centre = Vec3(Double(column - 2) * 2.5, 0, Double(1 - row) * 2.5)
            let profile = (0...48).map { i -> VisualShape.ProfilePoint in
                let t = Double.pi * Double(i) / 48
                return VisualShape.ProfilePoint(-cos(t), sin(t))
            }
            var s = VisualShape.revolution(profile, from: centre, axis: .unitZ, segments: 96, color: colour)
            s.material = material
            shapes.append(s)
        }
        for (i, r) in roughness.enumerated() {
            sphere(column: i, row: 0, MaterialDefaults.lookDev(.metal, roughness: r), (0.913, 0.913, 0.913))
            sphere(column: i, row: 1, MaterialDefaults.lookDev(.dielectric, roughness: r), (0.8, 0.8, 0.8))
        }
        let apollo: [(MaterialKey, (Double, Double, Double))] = [
            (.apolloCMFoil, (0.85, 0.85, 0.87)), (.apolloSMAluminium, (0.72, 0.72, 0.74)),
            (.apolloWhitePaint, (0.8, 0.8, 0.78)), (.apolloInterstagePrimer, (0.77, 0.65, 0.17)),
            (.apolloAblator, (0.3, 0.26, 0.22)),
        ]
        for (i, a) in apollo.enumerated() { sphere(column: i, row: 2, a.0, a.1) }
        let part = VesselPart(name: "Look-dev spheres", dryMass: 1, length: 2, radius: 1, shapes: shapes)
        let vessel = Vessel(name: "Look-dev spheres", parts: [part], reference: SolarSystemStub.earth)
        return scene(vessel, at: Vec3(0, 20, 0), attitude: .identity, fovY: 32, width: width, height: height)
    }

    /// AS-506 dressed for Apollo 11, lying along +x (nose to the right),
    /// Position II towards the camera and Position III towards the Earth,
    /// seen from 4 km through a 1.7° lens: an orthographic view, near enough.
    public static func saturnVSide(width: Int = 640, height: Int = 400) -> RenderScene {
        let stack = VesselLibrary.saturnV()
        for p in stack.parts { p.appearance = .apollo11 }
        VesselLibrary.dressApollo(stack)
        var lo = Double.infinity, hi = -Double.infinity
        for p in stack.parts {
            for s in p.shapes {
                for v in s.mesh().vertices {
                    let x = v.position.x + p.offset.x - stack.structureOrigin.x
                    lo = min(lo, x)
                    hi = max(hi, x)
                }
            }
        }
        let distance = 4_000.0
        let width = Double(width), height = Double(height)
        let fovX = 2 * atan(0.54 * (hi - lo) / distance)
        let fovY = 2 * atan(tan(fovX / 2) * height / width)
        return scene(stack, at: Vec3(-0.5 * (lo + hi), distance, 0), attitude: .identity,
                     fovY: fovY * 180 / Double.pi, width: Int(width), height: Int(height))
    }

    /// `vessel` with its construction origin at `position` (camera-relative)
    /// and `attitude`, seen from the origin along +y.
    static func scene(_ vessel: Vessel, at position: Vec3, attitude: Quat, fovY degrees: Double, width: Int,
                      height: Int) -> RenderScene {
        let viewport = RenderScene.Viewport(width: Double(width), height: Double(height))
        // Rows: right (+x), up (+z), back (-y).
        let camera = RenderScene.Camera(position: .zero, worldToView: Mat3(rows: .unitX, .unitZ, -.unitY),
                                        fovY: degrees * Double.pi / 180, viewport: viewport,
                                        target: .vessel(vessel.id), targetName: vessel.name)
        let illuminance = Photometry.solarIlluminanceAt1AU
        let sun = RenderScene.Sun(position: toSun * Photometry.astronomicalUnit, direction: toSun,
                                  distance: Photometry.astronomicalUnit, illuminance: illuminance,
                                  angularRadius: asin(695_700_000 / Photometry.astronomicalUnit))
        let light = LegacyLight(toSun: toSun, sunlit: 1, sky: 0, earthDirection: -.unitZ, earthLit: 1,
                                earthStrength: 0.3 * earthSinSigma2, earthColor: RenderScene.RGB(0.78, 0.88, 1.0))
        let v = RenderScene.Vessel(id: vessel.id, name: vessel.name, isFocus: true, status: vessel.status,
                                   isLanded: false, referenceBodyID: 399, position: position, attitude: attitude,
                                   structureOrigin: .zero, boundingRadius: vessel.boundingRadius,
                                   geometry: VesselGeometry(of: vessel), thrusters: [:], light: light, glow: .black,
                                   flowDirection: .zero, farPointStyle: nil, heatFlux: 0, heatLoad: 0)
        return RenderScene(clock: RenderScene.Clock(simTime: epoch), camera: camera, sun: sun, vessels: [v])
    }
}

/// A reference body for vessels that are never simulated (the look-dev
/// scenes): the bundled system's Earth, loaded once.
enum SolarSystemStub {
    static let earth: CelestialBody = {
        guard let system = try? SolarSystem.bundled() else { preconditionFailure("the bundled solar system") }
        return system.earth
    }()
}
