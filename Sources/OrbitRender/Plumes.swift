import Foundation
import simd
import OrbitCore
import OrbitScene

/// Exhaust plumes as additive impostors: for each emitter (a thruster
/// delivering thrust, `RenderScene.Emitter`), a camera-facing cone along the
/// exhaust from its nozzle's exit (or from the thruster's position, with a
/// nominal exit, for jets without a nozzle shape), plus a soft disc over the
/// exit that carries the plume seen end-on. Track P2 owns this file.
///
/// Everything here is a visual approximation that never feeds back into the
/// physics. The look comes from the propellant (`PlumeStyle`); the
/// intensity is the thrust the engine delivers over its vacuum rating (start
/// and shutdown ramps fade it); the plume widens and shortens as the ambient
/// pressure falls. A floor keeps a firing engine visible in
/// vacuum, where a real J-2 or hypergolic plume is nearly invisible (the
/// owner's choice, plan decision 19).
enum Plumes {
    /// The propellant's look (`PlumeStyle`, classified by the scene).
    typealias Style = PlumeStyle

    /// How a style looks at sea level and in vacuum.
    struct Look {
        var color: SIMD3<Float>
        /// Intensity, length in exit radii and the cone's half-angle (deg).
        var seaLevel: (intensity: Double, length: Double, halfAngle: Double)
        var vacuum: (intensity: Double, length: Double, halfAngle: Double)
        /// Strength of the dark core near the exit (0...1).
        var core: Double
    }

    /// The least intensity of a plume at full thrust, whatever the style and the air.
    static let floor = 0.3

    static func look(_ style: Style) -> Look {
        switch style {
        case .kerosene:
            return Look(color: SIMD3(1.0, 0.52, 0.16), seaLevel: (0.75, 24, 3), vacuum: (0.5, 10, 28), core: 0.75)
        case .hydrogen:
            return Look(color: SIMD3(0.55, 0.62, 1.0), seaLevel: (0.5, 14, 3), vacuum: (0.35, 12, 30), core: 0)
        case .solid:
            return Look(color: SIMD3(1.0, 0.82, 0.58), seaLevel: (1.0, 20, 4), vacuum: (0.85, 24, 14), core: 0)
        case .hypergolic:
            return Look(color: SIMD3(1.0, 0.5, 0.4), seaLevel: (0.55, 8, 8), vacuum: (0.4, 8, 32), core: 0)
        }
    }

    /// A plume from `exit` (camera-relative world, m) along the exhaust
    /// direction `axis` (unit, world), for an exit of `radius` (m), at
    /// `fraction` of the vacuum rating, in air at `pressureRatio` of sea
    /// level; `jet` shortens it for attitude jets. Appends its triangles.
    static func append(exit: Vec3, axis: Vec3, radius: Double, style: Style, fraction: Double,
                       pressureRatio: Double, jet: Bool, to out: inout [PlumeVertex]) {
        guard fraction > 0.005, radius > 0 else { return }
        let look = look(style)
        // The plume's shape changes most in the lower atmosphere.
        let k = max(0, min(1, pressureRatio)).squareRoot()
        func mix(_ vac: Double, _ sl: Double) -> Double { vac + (sl - vac) * k }
        let intensity = max(floor, mix(look.vacuum.intensity, look.seaLevel.intensity)) * min(1, fraction)
        var length = mix(look.vacuum.length, look.seaLevel.length) * radius * (0.5 + 0.5 * min(1, fraction))
        if jet { length = max(0.6, length) }      // a puff you can see beside the hull
        let halfAngle = mix(look.vacuum.halfAngle, look.seaLevel.halfAngle) * Double.pi / 180
        let tail = radius + length * tan(halfAngle)
        let exponent = mix(0.55, 1.0)           // vacuum plumes balloon just past the exit

        // Camera at the origin: the strip faces it, turned about the axis.
        let middle = exit + axis * (length / 2)
        let toCamera = (-middle).normalized
        var side = axis.cross(toCamera)
        if side.length < 1e-6 { side = VisualShape.defaultReference(for: axis) }
        side = side.normalized
        let color = SIMD4<Float>(look.color * Float(intensity), 0)
        let core = Float(look.core)

        let segments = 10
        func ring(_ i: Int) -> (left: PlumeVertex, right: PlumeVertex) {
            let t = Double(i) / Double(segments)
            let c = exit + axis * (length * t)
            let w = radius + (tail - radius) * pow(t, exponent)
            return (PlumeVertex(position: SIMD4(c - side * w, 1), color: color, shape: SIMD4(-1, Float(t), core, 0)),
                    PlumeVertex(position: SIMD4(c + side * w, 1), color: color, shape: SIMD4(1, Float(t), core, 0)))
        }
        var previous = ring(0)
        for i in 1...segments {
            let next = ring(i)
            out += [previous.left, previous.right, next.right, previous.left, next.right, next.left]
            previous = next
        }

        // The disc over the exit, facing the camera; brightest end-on.
        let endOn = abs(axis.dot((-exit).normalized))
        let up = toCamera.cross(side).normalized
        let discCentre = exit + axis * (0.1 * length)
        let discRadius = radius * (0.9 + 1.1 * endOn)
        let discColor = SIMD4<Float>(look.color * Float(intensity * (0.15 + 0.85 * endOn)), 0)
        func corner(_ x: Float, _ y: Float) -> PlumeVertex {
            PlumeVertex(position: SIMD4(discCentre + side * (Double(x) * discRadius) + up * (Double(y) * discRadius), 1),
                        color: discColor, shape: SIMD4(x, y, 0, 1))
        }
        out += [corner(-1, -1), corner(1, -1), corner(1, 1), corner(-1, -1), corner(1, 1), corner(-1, 1)]
    }

    /// Colour of a distant vessel's point while its engines fire.
    static func pointColor(_ style: Style) -> SIMD3<Float> { look(style).color }
}

/// A plume impostor's vertex (PlumeShaders).
struct PlumeVertex {
    /// Camera-relative world position, w = 1.
    var position: SIMD4<Float>
    /// rgb: colour times intensity (added), w: unused.
    var color: SIMD4<Float>
    /// x: across the cone (-1...1), y: along it (0 at the exit, 1 at the
    /// tail), z: the dark fuel-rich core's strength, w: 0 for the cone, 1
    /// for the glow disc (x, y then the disc's coordinates).
    var shape: SIMD4<Float>
}
