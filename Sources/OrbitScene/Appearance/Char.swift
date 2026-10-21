import Foundation
import OrbitCore

/// The CM's char after entry, from the heat it took (`Vessel.heatLoad`, the
/// stagnation-point load the core integrates), so it holds at any warp and
/// after a reload.
///
/// `factor` is that load over Apollo 7's: 0 before entry, 1 after an entry
/// like Apollo 7's, more after a lunar return's. The heat shield chars to
/// black, full at Apollo 7's load; the afterbody's Kapton tape burns from
/// silver through gold to brown, more where the flow meets it
/// (`exposure`). Recovered CMs show the heat shield black and the tape burnt
/// to the ablator in white, yellow and brown streaks (S68-56309,
/// S68-56217, csm.csv 103-020); the stages' colours are estimates (L).
public enum Char {
    /// J/m² per BTU/ft².
    public static let btuPerSquareFoot = 11_356.53
    /// Apollo 7's entry heat load: 12,649 BTU/ft² on the operational
    /// trajectory (MSC Internal Note 68-FM-184 §5.4.4), which the model's
    /// Apollo 7 entry flies within 10 % (Apollo7EntryTests), J/m².
    public static let apollo7HeatLoad = 12_649 * btuPerSquareFoot

    /// The char factor of a heat load (J/m²).
    public static func factor(heatLoad: Double) -> Double { max(heatLoad, 0) / apollo7HeatLoad }

    /// The char factor of `vessel`'s entry so far.
    public static func factor(_ vessel: Vessel) -> Double { factor(heatLoad: vessel.heatLoad) }

    /// How far the heat shield has charred, 0 to 1: quickly at first (the
    /// ablator chars early in the pulse), full from Apollo 7's load.
    public static func heatShield(factor f: Double) -> Double {
        let x = 1 - max(0, min(1, f))
        return 1 - x * x * x
    }

    /// How far the afterbody's tape has burnt, 0 to 1, at `exposure` 0 (the
    /// lee) to 1 (facing the flow): 0.4 of the factor on the lee, all of it
    /// facing the flow.
    public static func afterbody(factor f: Double, exposure: Double) -> Double {
        max(0, min(1, f * (0.4 + 0.6 * max(0, min(1, exposure)))))
    }

    /// The flow's incidence on a surface: the square of the sine of the
    /// angle between the surface and the air's velocity relative to the
    /// vehicle (`flow`), as Newtonian pressure and heating go; 0 where the
    /// surface faces away. `normal` points out of the surface.
    public static func exposure(normal: Vec3, flow: Vec3) -> Double {
        let n = normal.length, v = flow.length
        guard n > 0, v > 0 else { return 0 }
        let c = -normal.dot(flow) / (n * v)
        return c > 0 ? c * c : 0
    }

    /// Display colours (linear RGB, L): the stages of the tape's burn, and
    /// the heat shield's char.
    public static let tapeStages: [RenderScene.RGB] = [
        PaintColour.kapton.linear,
        PaintColour.fromSRGB(0xC8, 0xA0, 0x48),   // gold: the polyimide under the burnt coating
        PaintColour.fromSRGB(0x5A, 0x3C, 0x22),   // brown
        PaintColour.fromSRGB(0x2A, 0x22, 0x1C),   // charred
    ]
    public static let charColour = PaintColour.fromSRGB(0x14, 0x12, 0x11)

    /// The tape's colour at burn `b` (0 to 1), through `tapeStages`.
    public static func tapeColour(burn b: Double) -> RenderScene.RGB {
        let x = max(0, min(1, b)) * Double(tapeStages.count - 1)
        let i = min(Int(x), tapeStages.count - 2), t = Float(x - Double(i))
        let p = tapeStages[i], q = tapeStages[i + 1]
        return RenderScene.RGB(p.r + (q.r - p.r) * t, p.g + (q.g - p.g) * t, p.b + (q.b - p.b) * t)
    }
}
