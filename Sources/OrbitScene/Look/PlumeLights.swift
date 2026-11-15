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

    /// The light of cluster `c`, nil when it gives none.
    public static func light(_ c: PlumeCluster) -> PlumeLight? {
        var r = 0.0, g = 0.0, b = 0.0
        var profile: [(x: Double, i: Double)] = []
        for m in c.members where glows(m.family) {
            let reach = m.length
            guard reach > 0 else { continue }
            let dx = reach / Double(samples)
            let across = PlumeLook.perpendicular(m.axis)
            for j in 0..<samples {
                let x = (Double(j) + 0.5) * dx
                let e = m.extent(atX: x)
                let seen = PlumeLook.march([m], from: m.exit + m.axis * x - across * e, direction: across,
                                           range: 0...(2 * e), steps: steps)
                let width = 1.6 * min(m.radius(atX: x), e)
                let k = width * dx
                r += seen.radiance.r * k
                g += seen.radiance.g * k
                b += seen.radiance.b * k
                let xc = (m.exit + m.axis * x - c.origin).dot(c.axis)
                profile.append((xc, seen.radiance.luminance * k))
            }
        }
        let total = 0.2126 * r + 0.7152 * g + 0.0722 * b
        guard total > 0, total.isFinite else { return nil }
        // The segment: from the exits to nine-tenths of the light.
        profile.sort { $0.x < $1.x }
        var sum = 0.0, end = profile.last?.x ?? 0
        for p in profile {
            sum += p.i
            if sum >= 0.9 * total {
                end = p.x
                break
            }
        }
        let length = max(end, c.members.map(\.exitDiameter).max() ?? 1)
        let radius = max(c.radius(atX: 0.5 * length) / PlumeClusters.margin, c.members.map(\.exitRadius).max() ?? 0)
        return PlumeLight(centre: c.origin + c.axis * (0.5 * length), axis: c.axis, length: length, radius: radius,
                          intensity: RenderScene.RGB(Float(r), Float(g), Float(b)),
                          range: (total / cutoffIlluminance).squareRoot(), luminousIntensity: total)
    }
}
