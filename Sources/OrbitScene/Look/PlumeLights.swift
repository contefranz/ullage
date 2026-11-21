import Foundation
import OrbitCore

/// A plume as a light on the vehicle and the pad: a line light along the
/// exhaust's axis (LightingCommon's `LocalLight`).
public struct PlumeLight: Equatable {
    /// Camera-relative centre of the luminous segment, m.
    public var centre: Vec3
    /// Unit exhaust direction (world).
    public var axis: Vec3
    /// The segment's length and the column's radius, m.
    public var length: Double
    public var radius: Double
    /// Luminous intensity seen broadside, cd, as linear Rec. 709 whose
    /// luminance (0.2126, 0.7152, 0.0722) is the intensity.
    public var intensity: RenderScene.RGB
    /// Beyond this distance its illuminance is negligible (m).
    public var range: Double
    /// Broadside intensity, cd.
    public var luminousIntensity: Double
}

/// The plume lights (track P2; R2's vessel pass shades them): one line
/// light per plume cluster (`PlumeClusters`), carrying the light the
/// plume's own look gives off (`PlumeLook`), so the lights and the drawn
/// plumes agree. The five F-1s light the S-IC's base, the pad and the deck
/// as one column.
///
/// - Each member's broadside intensity is its light seen side-on through
///   its axis (the reference march, `PlumeLook.march`) times the jet's
///   width, summed along it: a luminance times a projected area.
/// - The segment runs from the exits to where nine-tenths of that light
///   is reached, about the axis, as wide as the proxy there.
/// - Only the glowing families give one: kerosene's soot and the solids'
///   alumina; a J-2's, the SPS's or an RCS jet's light is negligible.
/// - The brightest at the camera are kept, `maximum` at most.
public enum PlumeLights {
    public static let maximum = 8
    /// Lights dimmer than this at their range are cut, lux.
    public static let cutoffIlluminance = 1.0
    /// Samples along a member, and steps across it.
    static let samples = 12, steps = 24

    /// The scene's brightest plume lights at the camera, from its emitters.
    public static func lights(_ scene: RenderScene, settings: PlumeSettings = PlumeSettings(),
                              maximum: Int = PlumeLights.maximum) -> [PlumeLight] {
        guard maximum > 0 else { return [] }
        let members = scene.emitters.compactMap { PlumeLook.member($0, settings: settings) }
        return lights(PlumeClusters.clusters(members), maximum: maximum)
    }

    /// The brightest lights of `clusters` at the camera.
    public static func lights(_ clusters: [PlumeCluster], maximum: Int = PlumeLights.maximum) -> [PlumeLight] {
        guard maximum > 0 else { return [] }
        let all = clusters.compactMap(light)
        func weight(_ l: PlumeLight) -> Double {
            l.luminousIntensity / max(l.centre.lengthSquared, l.length * l.length)
        }
        return Array(all.sorted { weight($0) > weight($1) }.prefix(maximum))
    }

    /// The light of one emitter alone, nil when it gives none.
    public static func light(_ e: RenderScene.Emitter, settings: PlumeSettings = PlumeSettings()) -> PlumeLight? {
        guard let m = PlumeLook.member(e, settings: settings) else { return nil }
        return light(PlumeClusters.cluster([m]))
    }

    /// Whether a family's plume lights its surroundings.
    public static func glows(_ f: PlumeFamily) -> Bool { f == .kerosene || f == .solid }

    /// One member's light along its own axis: its broadside light (the
    /// luminance seen side-on through the axis times the jet's width, cd
    /// per m) in `samples` bins of `step` m from its exit; nil for a family
    /// that does not glow. It depends on the member's look alone, not on
    /// where it is, so the renderer keeps it across frames.
    public struct Profile: Equatable {
        public var step: Double
        public var bins: [RenderScene.RGB]
    }

    /// `m`'s profile (`Profile`), nil when it gives no light.
    public static func profile(_ m: PlumeMember) -> Profile? {
        guard glows(m.family), m.length > 0 else { return nil }
        let dx = m.length / Double(samples)
        let across = PlumeLook.perpendicular(m.axis)
        var bins: [RenderScene.RGB] = []
        for j in 0..<samples {
            let x = (Double(j) + 0.5) * dx
            let e = m.extent(atX: x)
            let seen = PlumeLook.march([m], from: m.exit + m.axis * x - across * e, direction: across,
                                       range: 0...(2 * e), steps: steps, around: (e, 0.5 * m.denseRadius(atX: x)))
            let k = 1.6 * min(m.radius(atX: x), e) * dx
            bins.append(RenderScene.RGB(Float(seen.radiance.r * k), Float(seen.radiance.g * k),
                                        Float(seen.radiance.b * k)))
        }
        return Profile(step: dx, bins: bins)
    }

    /// The light of cluster `c`, nil when it gives none.
    public static func light(_ c: PlumeCluster) -> PlumeLight? {
        light(c, profiles: c.members.map(profile))
    }

    /// The light of cluster `c` from its members' profiles (in the order of
    /// its members), nil when it gives none. The segment runs from the
    /// exits to where nine-tenths of the light is reached, found within
    /// the bin that crosses it, so that it moves smoothly.
    public static func light(_ c: PlumeCluster, profiles: [Profile?]) -> PlumeLight? {
        var r = 0.0, g = 0.0, b = 0.0
        var bins: [(x: Double, width: Double, i: Double)] = []
        for (m, profile) in zip(c.members, profiles) {
            guard let profile else { continue }
            for (j, bin) in profile.bins.enumerated() {
                r += Double(bin.r)
                g += Double(bin.g)
                b += Double(bin.b)
                let x = (Double(j) + 0.5) * profile.step
                let xc = (m.exit + m.axis * x - c.origin).dot(c.axis)
                bins.append((xc, profile.step, 0.2126 * Double(bin.r) + 0.7152 * Double(bin.g)
                             + 0.0722 * Double(bin.b)))
            }
        }
        let total = 0.2126 * r + 0.7152 * g + 0.0722 * b
        guard total > 0, total.isFinite, let width = bins.map(\.width).min(), width > 0 else { return nil }
        // The members' bins summed on one grid along the axis (each spread
        // over the cells it covers), so that members side by side cross
        // together, then the 90 % found within its cell.
        let lo = bins.map { $0.x - 0.5 * $0.width }.min() ?? 0
        let hi = bins.map { $0.x + 0.5 * $0.width }.max() ?? 0
        let cells = max(1, Int(((hi - lo) / width).rounded(.up)))
        var grid = [Double](repeating: 0, count: cells)
        for p in bins where p.i > 0 {
            let a = p.x - 0.5 * p.width - lo, b = a + p.width
            for k in max(0, Int(a / width))...min(cells - 1, Int(b / width)) {
                let overlap = min(b, Double(k + 1) * width) - max(a, Double(k) * width)
                if overlap > 0 { grid[k] += p.i * overlap / p.width }
            }
        }
        var sum = 0.0, end = hi
        for (k, i) in grid.enumerated() where i > 0 {
            if sum + i >= 0.9 * total {
                end = lo + (Double(k) + min(max((0.9 * total - sum) / i, 0), 1)) * width
                break
            }
            sum += i
        }
        let length = max(end, c.members.map(\.exitDiameter).max() ?? 1)
        let radius = max(c.radius(atX: 0.5 * length) / PlumeClusters.margin, c.members.map(\.exitRadius).max() ?? 0)
        return PlumeLight(centre: c.origin + c.axis * (0.5 * length), axis: c.axis, length: length, radius: radius,
                          intensity: RenderScene.RGB(Float(r), Float(g), Float(b)),
                          range: (total / cutoffIlluminance).squareRoot(), luminousIntensity: total)
    }
}
