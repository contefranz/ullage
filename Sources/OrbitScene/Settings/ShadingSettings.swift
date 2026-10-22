import Foundation

/// Track R2's render settings: physically based shading of vessels and
/// sites, specular anti-aliasing, plume lights. R2 owns this file;
/// `RenderSettings` holds one. Every member may be left out of a spec.
public struct ShadingSettings: Codable, Equatable {
    /// Widen roughness by the normal's change over the pixel (Tokuyoshi
    /// and Kaplanyan's NDF filtering), so highlights do not sparkle.
    public var specularAntiAliasing = true
    /// Restore the energy single scattering loses at high roughness
    /// (Fdez-Agüera's and Kulla and Conty's compensation).
    public var multipleScattering = true
    /// Light the specular lobe from the Sun's disc, not a point.
    public var sunDiscAreaLight = true
    /// Thin tubes (the LES truss, risers) never draw thinner than this
    /// radius on screen (px); their coverage fades instead (Persson's
    /// phone-wire anti-aliasing). 0 turns it off.
    public var wireMinimumRadius = 0.7
    /// Light vessels and the pad with the plumes, at most this many lights.
    public var plumeLights = 8
    /// Bake each vessel's ambient occlusion before drawing it instead of in
    /// the background (snapshots that must not depend on timing).
    public var waitForAmbientOcclusion = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case specularAntiAliasing, multipleScattering, sunDiscAreaLight, wireMinimumRadius, plumeLights
        case waitForAmbientOcclusion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShadingSettings()
        specularAntiAliasing = try c.decodeIfPresent(Bool.self, forKey: .specularAntiAliasing) ?? d.specularAntiAliasing
        multipleScattering = try c.decodeIfPresent(Bool.self, forKey: .multipleScattering) ?? d.multipleScattering
        sunDiscAreaLight = try c.decodeIfPresent(Bool.self, forKey: .sunDiscAreaLight) ?? d.sunDiscAreaLight
        wireMinimumRadius = try c.decodeIfPresent(Double.self, forKey: .wireMinimumRadius) ?? d.wireMinimumRadius
        plumeLights = try c.decodeIfPresent(Int.self, forKey: .plumeLights) ?? d.plumeLights
        waitForAmbientOcclusion = try c.decodeIfPresent(Bool.self, forKey: .waitForAmbientOcclusion)
            ?? d.waitForAmbientOcclusion
    }
}
