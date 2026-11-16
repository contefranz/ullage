import Foundation

/// Track R3's render settings: the environment probe and image-based lighting, the night floor. R3 owns this file and fills
/// it; `RenderSettings` holds one.
public struct ProbeSettings: Codable, Equatable {
    /// The probe and its image-based lighting; off, the vessels light with
    /// R2's stand-in (`StandInLighting`) and the SH9 are zero.
    public var enabled = true
    /// The radiance cube's side, texels: 128 at Medium and High, 64 at Low
    /// (design-renderer-core, "Quality tiers").
    public var faceSize = 128
    /// The specular cube's mip levels, roughness k/(count − 1) at mip k
    /// (`EnvironmentProbe.roughness`): 6 from 128² go down to 4², 22° a texel.
    public var specularMips = 6
    /// GGX samples per texel of the first prefiltered mip, doubling at each
    /// mip after it up to eight times (filtered importance sampling: each
    /// reads the source mip its pdf covers).
    public var prefilterSamples = 32
    /// The night floor: the share of the exposure's white a white surface
    /// shows by it alone (StandInLighting's 0.02), merged as a soft maximum
    /// (`EnvironmentProbe.floored`). 0 turns it off.
    public var nightFloor = 0.02
    /// A scale on the probe's light (LightingUniforms.ambient.w), 1 for the
    /// physical value.
    public var intensity = 1.0
    /// Draw C2's far cloud layers into the probe (where the clouds are on).
    public var clouds = true
    /// Draw the pad (LC-39A, within 2 km) into the probe, so the stack sees
    /// its concrete and steel.
    public var sites = true
    /// What the probe sees: the scene, or an analytic look-dev environment.
    public var environment = ProbeEnvironment.scene
    /// The furnace's radiance, cd/m² (`environment` = furnace).
    public var furnaceRadiance = 1_000.0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, faceSize, specularMips, prefilterSamples, nightFloor, intensity, clouds, sites, environment
        case furnaceRadiance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProbeSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        faceSize = try c.decodeIfPresent(Int.self, forKey: .faceSize) ?? d.faceSize
        specularMips = try c.decodeIfPresent(Int.self, forKey: .specularMips) ?? d.specularMips
        prefilterSamples = try c.decodeIfPresent(Int.self, forKey: .prefilterSamples) ?? d.prefilterSamples
        nightFloor = try c.decodeIfPresent(Double.self, forKey: .nightFloor) ?? d.nightFloor
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? d.intensity
        clouds = try c.decodeIfPresent(Bool.self, forKey: .clouds) ?? d.clouds
        sites = try c.decodeIfPresent(Bool.self, forKey: .sites) ?? d.sites
        environment = try c.decodeIfPresent(ProbeEnvironment.self, forKey: .environment) ?? d.environment
        furnaceRadiance = try c.decodeIfPresent(Double.self, forKey: .furnaceRadiance) ?? d.furnaceRadiance
    }

    /// The face size the renderer uses: a power of two in 16...512.
    public var resolvedFaceSize: Int {
        var n = 16
        while n < min(max(faceSize, 16), 512) { n *= 2 }
        return n
    }

    /// The specular mips the renderer uses: at least 2, and none below 4².
    public var resolvedSpecularMips: Int {
        let most = Int(log2(Double(resolvedFaceSize))) - 1
        return min(max(specularMips, 2), most)
    }
}

/// What the environment probe draws.
public enum ProbeEnvironment: String, Codable, CaseIterable {
    /// The scene: the planets, A2's sky, C2's far clouds.
    case scene
    /// A uniform radiance (`ProbeSettings.furnaceRadiance`): the white furnace.
    case furnace
    /// R2's look-dev Earth below at 185 km, point by point under the scene's
    /// Sun (`EnvironmentProbe.LookDevEnvironment.earthBelow`).
    case earthBelow
    /// The same Earth lit evenly at the sub-solar point's radiance: Howell's
    /// uniform disc (`EnvironmentProbe.LookDevEnvironment.earthUniform`).
    case earthUniform
}
