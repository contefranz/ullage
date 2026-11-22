import Foundation

/// Track C2's render settings: the volumetric clouds' weather, regimes,
/// march and reprojection. C2 owns this file; `RenderSettings` holds one.
public struct CloudSettings: Codable, Equatable {
    /// Draw the clouds.
    public var enabled = true
    /// Where the weather comes from:
    /// - "auto" or "historic": the mission whose launch is nearest the
    ///   scene's epoch, its ERA5 field when fetched (for its days, fading into
    ///   the procedural weather beyond them), the pad's observed sky at
    ///   launch, and the procedural weather everywhere else;
    /// - "random": the procedural weather alone, everywhere;
    /// - a mission ("apollo7", "apollo8", "apollo11"), as "auto" for it;
    /// - "climatology": the zonal climatology alone (the old fallback);
    /// - "clear".
    public var weather = "auto"
    /// The procedural weather's seed (`ProceduralWeather`). The app draws a
    /// new one at each scenario start; shots and tests keep theirs, so a
    /// recorded seed gives the same sky.
    public var seed = 1
    /// Look-dev: one uniform, homogeneous low layer of this cover and
    /// optical depth everywhere instead of the weather (the cloud slab).
    public var lookDev: LookDevSlab?
    /// Force a regime, for look-dev: "auto", "march" or "far".
    public var regime = "auto"
    /// The march's steps through clear air, and its light march's reach (m;
    /// its samples are CloudLighting's).
    public var steps = 48
    public var lightDistance = 1_500.0
    /// The near field's reach, m.
    public var nearReach = 150_000.0
    /// The detail erosion's strength (0 leaves it out).
    public var detail = 1.0
    /// Temporal reprojection with a checkerboard, one texel in four marched
    /// a frame; off at 10× warp or more and under fast motion anyway.
    public var reprojection = true
    /// The cloud shadow map's side, texels (0: none).
    public var shadowTexels = 256
    /// Scales every layer's extinction.
    public var densityScale = 1.0
    /// Scales the far layer's optical depth, C1's in-cloud one (the march's
    /// extinction averages C1's where there is cloud, so 1 matches it).
    public var farDensity = 1.0
    /// How much the large-scale structure moves partial cover up and down.
    public var coverageModulation = 0.8
    /// The pixel footprint on the layer (m) over which the march hands
    /// over to the far surface layer.
    public var farFootprint = [1_500.0, 6_000.0]
    /// Profiling: stages left out ("weather", "shadow", "march", "resolve").
    public var skip: [String] = []

    /// A uniform slab for the look-dev goldens: its cover, optical depth,
    /// and base and thickness above the ground (m; the far LUT's low layer
    /// is 1,500 m thick).
    public struct LookDevSlab: Codable, Equatable {
        public var cover = 1.0
        public var opticalDepth = 20.0
        public var base = 1_000.0
        public var thickness = 1_500.0

        public init(cover: Double = 1, opticalDepth: Double = 20, base: Double = 1_000, thickness: Double = 1_500) {
            self.cover = cover
            self.opticalDepth = opticalDepth
            self.base = base
            self.thickness = thickness
        }

        private enum CodingKeys: String, CodingKey { case cover, opticalDepth, base, thickness }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cover = try c.decodeIfPresent(Double.self, forKey: .cover) ?? 1
            opticalDepth = try c.decodeIfPresent(Double.self, forKey: .opticalDepth) ?? 20
            base = try c.decodeIfPresent(Double.self, forKey: .base) ?? 1_000
            thickness = try c.decodeIfPresent(Double.self, forKey: .thickness) ?? 1_500
        }
    }

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, weather, seed, lookDev, regime, steps, lightDistance, nearReach, detail, reprojection
        case shadowTexels, densityScale, farDensity, coverageModulation, farFootprint, skip
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CloudSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        weather = try c.decodeIfPresent(String.self, forKey: .weather) ?? d.weather
        seed = try c.decodeIfPresent(Int.self, forKey: .seed) ?? d.seed
        lookDev = try c.decodeIfPresent(LookDevSlab.self, forKey: .lookDev)
        regime = try c.decodeIfPresent(String.self, forKey: .regime) ?? d.regime
        steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? d.steps
        lightDistance = try c.decodeIfPresent(Double.self, forKey: .lightDistance) ?? d.lightDistance
        nearReach = try c.decodeIfPresent(Double.self, forKey: .nearReach) ?? d.nearReach
        detail = try c.decodeIfPresent(Double.self, forKey: .detail) ?? d.detail
        reprojection = try c.decodeIfPresent(Bool.self, forKey: .reprojection) ?? d.reprojection
        shadowTexels = try c.decodeIfPresent(Int.self, forKey: .shadowTexels) ?? d.shadowTexels
        densityScale = try c.decodeIfPresent(Double.self, forKey: .densityScale) ?? d.densityScale
        farDensity = try c.decodeIfPresent(Double.self, forKey: .farDensity) ?? d.farDensity
        coverageModulation = try c.decodeIfPresent(Double.self, forKey: .coverageModulation) ?? d.coverageModulation
        farFootprint = try c.decodeIfPresent([Double].self, forKey: .farFootprint) ?? d.farFootprint
        skip = try c.decodeIfPresent([String].self, forKey: .skip) ?? []
    }
}
