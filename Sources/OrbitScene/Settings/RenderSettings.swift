import Foundation

/// Everything the renderer can be told, one sub-struct per track, each
/// defined in that track's own file so the tracks never edit this one. A
/// snapshot spec carries a `RenderSettings`; the app keeps one per session.
/// A track adding members to its struct decodes them with
/// `decodeIfPresent`, so that specs may leave them out.
public struct RenderSettings: Codable, Equatable {
    /// R1, HDR and post.
    public var post = PostSettings()
    /// R2, shading.
    public var shading = ShadingSettings()
    /// R3, the environment probe.
    public var probe = ProbeSettings()
    /// R4, shadows.
    public var shadow = ShadowSettings()
    /// R5, baked AO.
    public var ambientOcclusion = AmbientOcclusionSettings()
    /// R6, the effect slots.
    public var transparency = TransparencySettings()
    /// R7, tiers and pacing.
    public var quality = QualitySettings()
    /// A2, the atmosphere.
    public var atmosphere = AtmosphereSettings()
    /// E1, the tile cache.
    public var planetTile = PlanetTileSettings()
    /// E2, the Earth's surface.
    public var earthSurface = EarthSurfaceSettings()
    /// C2, clouds.
    public var cloud = CloudSettings()
    /// P2, plumes.
    public var plume = PlumeSettings()
    /// P3, particles.
    public var particle = ParticleSettings()
    /// P4, launch effects.
    public var launchEffect = LaunchEffectSettings()
    /// P5, staging effects.
    public var stagingEffect = StagingEffectSettings()
    /// P6, entry effects.
    public var entryEffect = EntryEffectSettings()
    /// VM1, markings.
    public var marking = MarkingSettings()
    /// VM2, materials.
    public var material = MaterialSettings()
    /// LC, the pad.
    public var site = SiteSettings()
    /// The render foundation's debug views and timings (F9, F10).
    public var debug = DebugSettings()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case post, shading, probe, shadow, ambientOcclusion, transparency, quality, atmosphere, planetTile
        case earthSurface, cloud, plume, particle, launchEffect, stagingEffect, entryEffect, marking, material, site
        case debug
    }

    /// Any member may be left out (a snapshot spec gives only what it changes).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        post = try c.decodeIfPresent(PostSettings.self, forKey: .post) ?? PostSettings()
        shading = try c.decodeIfPresent(ShadingSettings.self, forKey: .shading) ?? ShadingSettings()
        probe = try c.decodeIfPresent(ProbeSettings.self, forKey: .probe) ?? ProbeSettings()
        shadow = try c.decodeIfPresent(ShadowSettings.self, forKey: .shadow) ?? ShadowSettings()
        ambientOcclusion = try c.decodeIfPresent(AmbientOcclusionSettings.self, forKey: .ambientOcclusion) ?? AmbientOcclusionSettings()
        transparency = try c.decodeIfPresent(TransparencySettings.self, forKey: .transparency) ?? TransparencySettings()
        quality = try c.decodeIfPresent(QualitySettings.self, forKey: .quality) ?? QualitySettings()
        atmosphere = try c.decodeIfPresent(AtmosphereSettings.self, forKey: .atmosphere) ?? AtmosphereSettings()
        planetTile = try c.decodeIfPresent(PlanetTileSettings.self, forKey: .planetTile) ?? PlanetTileSettings()
        earthSurface = try c.decodeIfPresent(EarthSurfaceSettings.self, forKey: .earthSurface) ?? EarthSurfaceSettings()
        cloud = try c.decodeIfPresent(CloudSettings.self, forKey: .cloud) ?? CloudSettings()
        plume = try c.decodeIfPresent(PlumeSettings.self, forKey: .plume) ?? PlumeSettings()
        particle = try c.decodeIfPresent(ParticleSettings.self, forKey: .particle) ?? ParticleSettings()
        launchEffect = try c.decodeIfPresent(LaunchEffectSettings.self, forKey: .launchEffect) ?? LaunchEffectSettings()
        stagingEffect = try c.decodeIfPresent(StagingEffectSettings.self, forKey: .stagingEffect) ?? StagingEffectSettings()
        entryEffect = try c.decodeIfPresent(EntryEffectSettings.self, forKey: .entryEffect) ?? EntryEffectSettings()
        marking = try c.decodeIfPresent(MarkingSettings.self, forKey: .marking) ?? MarkingSettings()
        material = try c.decodeIfPresent(MaterialSettings.self, forKey: .material) ?? MaterialSettings()
        site = try c.decodeIfPresent(SiteSettings.self, forKey: .site) ?? SiteSettings()
        debug = try c.decodeIfPresent(DebugSettings.self, forKey: .debug) ?? DebugSettings()
    }
}

/// Debug views (F9 cycles them) and the per-pass GPU timings (F10).
public struct DebugSettings: Codable, Equatable {
    public var view = DebugView.none
    public var showPassTimings = false

    public init() {}

    private enum CodingKeys: String, CodingKey { case view, showPassTimings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        view = try c.decodeIfPresent(DebugView.self, forKey: .view) ?? .none
        showPassTimings = try c.decodeIfPresent(Bool.self, forKey: .showPassTimings) ?? false
    }
}

/// What the screen shows instead of the image (F9 cycles them), and what
/// `orbitsnap` writes as AOVs beside it.
public enum DebugView: String, Codable, CaseIterable {
    case none
    /// Distance from the camera on a log scale, 0.25 m (white) to 10^9 m
    /// (dark blue); the sky black.
    case depth
    /// Surface normals reconstructed from depth, world axes as colour.
    case normals
    /// The image's luminance in false colour, one band per stop.
    case luminance
    /// The Sun's visible share from the shadow maps on every surface, tinted
    /// by the map that served it (R4's `ShadowDebugPass`).
    case sunShadow
}
