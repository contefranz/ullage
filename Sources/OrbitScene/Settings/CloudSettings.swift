import Foundation

/// Track C2's render settings: the volumetric clouds' weather, regimes,
/// march and reprojection. C2 owns this file; `RenderSettings` holds one.
public struct CloudSettings: Codable, Equatable {
    /// Draw the clouds.
    public var enabled = true
    /// Where the weather comes from: "auto" (the mission whose launch is
    /// nearest the scene's epoch: its ERA5 field if fetched, else the
    /// climatology, with the pad's observed sky at launch), "climatology",
    /// "clear", or a mission ("apollo7", "apollo8", "apollo11").
    public var weather = "auto"
    /// Look-dev: one uniform, homogeneous low layer of this cover and
    /// optical depth everywhere instead of the weather (the cloud slab).
    public var lookDev: LookDevSlab?
    /// Force a regime, for look-dev: "auto", "march" or "far".
    public var regime = "auto"
    /// The march's steps and its light march's samples and reach (m).
    public var steps = 96
    public var lightSamples = 6
    public var lightDistance = 1_500.0
    /// The near field's reach, m.
    public var nearReach = 150_000.0
    /// The detail erosion's strength (0 leaves it out).
    public var detail = 1.0
    /// Temporal reprojection with a checkerboard, one texel in four marched
    /// a frame; off at 10× warp or more and under fast motion anyway.
    public var reprojection = true
    /// The cloud shadow map's side, texels (0: none).
    public var shadowTexels = 512
    /// Scales every layer's extinction.
    public var densityScale = 1.0
    /// The far layer's in-cloud optical depth over the layer model's: the
    /// march's clouds are not uniformly dense (their edges, their profile),
    /// so the surface layer that matches them is thinner.
    public var farDensity = 0.45
    /// How much the large-scale structure moves partial cover up and down.
    public var coverageModulation = 0.8
    /// The pixel footprint on the layer (m) over which the march hands
    /// over to the far surface layer.
    public var farFootprint = [1_500.0, 6_000.0]

    /// A uniform slab for the look-dev goldens.
    public struct LookDevSlab: Codable, Equatable {
        public var cover = 1.0
        public var opticalDepth = 20.0

        public init(cover: Double = 1, opticalDepth: Double = 20) {
            self.cover = cover
            self.opticalDepth = opticalDepth
        }
    }

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, weather, lookDev, regime, steps, lightSamples, lightDistance, nearReach, detail, reprojection
        case shadowTexels, densityScale, farDensity, coverageModulation, farFootprint
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CloudSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        weather = try c.decodeIfPresent(String.self, forKey: .weather) ?? d.weather
        lookDev = try c.decodeIfPresent(LookDevSlab.self, forKey: .lookDev)
        regime = try c.decodeIfPresent(String.self, forKey: .regime) ?? d.regime
        steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? d.steps
        lightSamples = try c.decodeIfPresent(Int.self, forKey: .lightSamples) ?? d.lightSamples
        lightDistance = try c.decodeIfPresent(Double.self, forKey: .lightDistance) ?? d.lightDistance
        nearReach = try c.decodeIfPresent(Double.self, forKey: .nearReach) ?? d.nearReach
        detail = try c.decodeIfPresent(Double.self, forKey: .detail) ?? d.detail
        reprojection = try c.decodeIfPresent(Bool.self, forKey: .reprojection) ?? d.reprojection
        shadowTexels = try c.decodeIfPresent(Int.self, forKey: .shadowTexels) ?? d.shadowTexels
        densityScale = try c.decodeIfPresent(Double.self, forKey: .densityScale) ?? d.densityScale
        farDensity = try c.decodeIfPresent(Double.self, forKey: .farDensity) ?? d.farDensity
        coverageModulation = try c.decodeIfPresent(Double.self, forKey: .coverageModulation) ?? d.coverageModulation
        farFootprint = try c.decodeIfPresent([Double].self, forKey: .farFootprint) ?? d.farFootprint
    }
}
