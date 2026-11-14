import Foundation

/// Track A2's render settings: the atmosphere's tables, the sky-view LUT,
/// the aerial-perspective froxels and the march from space
/// (docs/look/atmosphere.md). `RenderSettings` holds one; a spec may give
/// only what it changes.
public struct AtmosphereSettings: Codable, Equatable {
    /// Draw the atmosphere: the sky, the aerial perspective, the light it
    /// passes to the ground and to vessels. Off, the Earth is lit by the Sun
    /// above the air, with no sky.
    public var enabled = true
    /// Wait for A1's tables (built on a background queue when the pass is
    /// set up, about 0.2 s in Release) before the first frame that needs
    /// them, so every frame, snapshots included, has its air. Off, frames
    /// drawn before the tables are ready have none.
    public var waitForTables = true
    /// The aerosol's vertical optical depth at 550 nm (A1's
    /// `OpticalAtmosphere.Aerosol`); a change rebuilds the tables.
    public var aerosolOpticalDepth = 0.1
    /// The ground's mean albedo in the multiple scattering (A1's default).
    public var groundAlbedo = 0.1
    /// The sky-view LUT, texels (Hillaire's 192 × 108).
    public var skyViewWidth = 192
    public var skyViewHeight = 108
    /// Steps of each sky-view texel's march.
    public var skyViewSteps = 32
    /// Aerial-perspective froxels across the screen and in depth.
    public var froxelSize = 32
    public var froxelSlices = 32
    /// Slice distribution: slice i ends at far × ((i + 1) / slices)^exponent.
    public var froxelExponent = 2.0
    /// Steps of the march from space per pixel: rays that pass the limb, and
    /// rays that meet the ground.
    public var limbSteps = 24
    public var groundSteps = 10

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, waitForTables, aerosolOpticalDepth, groundAlbedo, skyViewWidth, skyViewHeight, skyViewSteps
        case froxelSize, froxelSlices, froxelExponent, limbSteps, groundSteps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AtmosphereSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        waitForTables = try c.decodeIfPresent(Bool.self, forKey: .waitForTables) ?? d.waitForTables
        aerosolOpticalDepth = try c.decodeIfPresent(Double.self, forKey: .aerosolOpticalDepth) ?? d.aerosolOpticalDepth
        groundAlbedo = try c.decodeIfPresent(Double.self, forKey: .groundAlbedo) ?? d.groundAlbedo
        skyViewWidth = try c.decodeIfPresent(Int.self, forKey: .skyViewWidth) ?? d.skyViewWidth
        skyViewHeight = try c.decodeIfPresent(Int.self, forKey: .skyViewHeight) ?? d.skyViewHeight
        skyViewSteps = try c.decodeIfPresent(Int.self, forKey: .skyViewSteps) ?? d.skyViewSteps
        froxelSize = try c.decodeIfPresent(Int.self, forKey: .froxelSize) ?? d.froxelSize
        froxelSlices = try c.decodeIfPresent(Int.self, forKey: .froxelSlices) ?? d.froxelSlices
        froxelExponent = try c.decodeIfPresent(Double.self, forKey: .froxelExponent) ?? d.froxelExponent
        limbSteps = try c.decodeIfPresent(Int.self, forKey: .limbSteps) ?? d.limbSteps
        groundSteps = try c.decodeIfPresent(Int.self, forKey: .groundSteps) ?? d.groundSteps
    }
}
