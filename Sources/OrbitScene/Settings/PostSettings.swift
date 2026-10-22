import Foundation

/// Track R1's render settings: exposure (auto, manual and the Hasselblad
/// photo mode), the tone curve, bloom, the Sun's glare and the dither.
/// `RenderSettings` holds one; a spec may give only what it changes.
public struct PostSettings: Codable, Equatable {
    public var exposure = ExposureSettings()
    public var toneCurve = ToneCurve.agx
    /// The share of the image's light the bloom spreads (2-4 %), 0 for none.
    public var bloom = 0.03
    /// The veiling glare around the Sun, scaled by how much of its disc is
    /// in view (the Earth's limb and the vehicles cover it).
    public var sunGlare = true
    /// Blue-noise dither of ±1 step before the 8-bit output.
    public var dither = true

    public init() {}

    private enum CodingKeys: String, CodingKey { case exposure, toneCurve, bloom, sunGlare, dither }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(ExposureSettings.self, forKey: .exposure) ?? ExposureSettings()
        toneCurve = try c.decodeIfPresent(ToneCurve.self, forKey: .toneCurve) ?? .agx
        bloom = try c.decodeIfPresent(Double.self, forKey: .bloom) ?? 0.03
        sunGlare = try c.decodeIfPresent(Bool.self, forKey: .sunGlare) ?? true
        dither = try c.decodeIfPresent(Bool.self, forKey: .dither) ?? true
    }
}

/// How the camera is exposed.
public struct ExposureSettings: Codable, Equatable {
    public enum Mode: String, Codable, CaseIterable {
        /// From the image's histogram, adapting in wall-clock time.
        case auto
        /// A fixed EV100 (`ev100`).
        case manual
        /// The Hasselblad's settings: `aperture`, `shutter` and the film's `iso`.
        case photo
    }

    public var mode = Mode.auto
    /// Manual mode's EV100; 15 is "sunny 16".
    public var ev100 = 15.0
    /// Auto mode's bias, EV: positive brightens the image.
    public var compensation = AutoExposureDefaults.compensation
    /// The photo mode: the Apollo 8 Earthrise frame's f/11 and 1/250 s on
    /// Ektachrome rated ISO 64 (EV100 15.5).
    public var aperture = 11.0
    public var shutter = 1.0 / 250
    public var iso = 64.0

    public init(mode: Mode = .auto) {
        self.mode = mode
    }

    /// The EV100 this sets when it is not automatic, nil when it is.
    public var fixedEV100: Double? {
        switch mode {
        case .auto: nil
        case .manual: ev100
        case .photo: Exposure.ev100(aperture: aperture, shutter: shutter, iso: iso)
        }
    }

    private enum CodingKeys: String, CodingKey { case mode, ev100, compensation, aperture, shutter, iso }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .auto
        ev100 = try c.decodeIfPresent(Double.self, forKey: .ev100) ?? 15
        compensation = try c.decodeIfPresent(Double.self, forKey: .compensation) ?? AutoExposureDefaults.compensation
        aperture = try c.decodeIfPresent(Double.self, forKey: .aperture) ?? 11
        shutter = try c.decodeIfPresent(Double.self, forKey: .shutter) ?? 1.0 / 250
        iso = try c.decodeIfPresent(Double.self, forKey: .iso) ?? 64
    }
}

public enum AutoExposureDefaults {
    /// The auto exposure's default bias, EV. The histogram's 50th-95th
    /// percentile band is the brighter half of what is lit, which a meter
    /// would put at 12.5 % of saturation; this lifts it.
    public static let compensation = 1.0
}
