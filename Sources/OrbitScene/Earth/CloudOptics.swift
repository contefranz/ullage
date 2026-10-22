import Foundation

/// Cloud optics in the visible, for the renderer's layers (track C1).
public enum CloudOptics {
    /// Density of liquid water, kg/m³.
    public static let waterDensity = 1000.0
    /// Density of ice, kg/m³.
    public static let iceDensity = 917.0

    /// Extinction coefficient (1/m) of drops or crystals of effective
    /// radius `effectiveRadius` (m) holding `waterContent` (kg/m³) of
    /// condensate of density `density`: β = 3 LWC / (2 ρ r_eff) (Stephens
    /// 1978, J. Atmos. Sci. 35, 2123), the geometric-optics limit, extinction
    /// efficiency 2, which visible light reaches on cloud drops (size
    /// parameter about 100 at 10 µm).
    public static func extinction(waterContent: Double, effectiveRadius: Double,
                                  density: Double = waterDensity) -> Double {
        3 * waterContent / (2 * density * effectiveRadius)
    }

    /// Reflectance of a non-absorbing slab of optical depth `opticalDepth`
    /// whose scattering has asymmetry parameter `asymmetry`, in the two-stream
    /// approximation with backscattered fraction (1 - g) / 2 (Bohren 1987,
    /// Am. J. Phys. 55, 524): R = (1 - g) τ / (2 + (1 - g) τ). The far
    /// regime's slab-BRDF LUT (C2) is checked against it.
    public static func slabReflectance(opticalDepth tau: Double, asymmetry g: Double) -> Double {
        let x = (1 - g) * tau
        return x / (2 + x)
    }

    /// Transmittance (direct and diffuse) of the same slab, 1 - R.
    public static func slabTransmittance(opticalDepth tau: Double, asymmetry g: Double) -> Double {
        1 - slabReflectance(opticalDepth: tau, asymmetry: g)
    }
}

/// One cloud layer of the renderer's layer model: where it lies and what
/// it is made of.
public struct CloudLayer: Equatable {
    public enum Kind: String, Equatable {
        case low, mid, high
    }

    public var kind: Kind
    /// Base and top above the surface, m.
    public var base: Double
    public var top: Double
    /// Fraction of the sky it covers, 0...1.
    public var cover: Double
    /// In-cloud condensate content, kg/m³, of effective radius (m) and
    /// density (kg/m³).
    public var waterContent: Double
    public var effectiveRadius: Double
    public var density: Double
    /// Asymmetry parameter of its scattering in the visible.
    public var asymmetry: Double

    public init(kind: Kind, base: Double, top: Double, cover: Double, waterContent: Double,
                effectiveRadius: Double, density: Double, asymmetry: Double) {
        self.kind = kind
        self.base = base
        self.top = top
        self.cover = cover
        self.waterContent = waterContent
        self.effectiveRadius = effectiveRadius
        self.density = density
        self.asymmetry = asymmetry
    }

    /// In-cloud extinction coefficient, 1/m.
    public var extinction: Double {
        CloudOptics.extinction(waterContent: waterContent, effectiveRadius: effectiveRadius, density: density)
    }

    /// Optical depth through the layer where it is cloudy.
    public var opticalDepth: Double { extinction * (top - base) }
}

/// The layer model (docs/m16/design-earth-moon.md, clouds): heights from
/// ERA5's layer definitions and cloud base, condensate from typical
/// in-cloud values. C2 may tune the values; the structure is the
/// design's. Water paths from data (ERA5's total column cloud liquid and
/// ice water, as extra OSCLOUD1 planes) are left to C2 (docs/m16/plan.md,
/// decision 29); until then these typical values set the optical depth.
public enum CloudLayerModel {
    /// The low layer's base where the sample has none, m.
    public static let defaultLowBase = 1_000.0
    /// The low layer's depth, m (the design's 1-2 km).
    public static let lowDepth = 1_500.0
    /// A cumulonimbus's top, m.
    public static let cumulonimbusTop = 12_000.0
    /// The mid layer's base and top, m (altostratus, altocumulus).
    public static let midBase = 3_000.0, midTop = 6_000.0
    /// The high layer's base and top, m (cirrus, cirrostratus).
    public static let highBase = 8_000.0, highTop = 12_000.0

    /// Cumulus and stratocumulus: 0.4 g/m³ of 10 µm drops (β about
    /// 0.06 /m). Altostratus and altocumulus: 0.05 g/m³ of 8 µm drops.
    /// Cirrus: 0.005 g/m³ of 40 µm ice (β about 2e-4 /m, inside the
    /// design's 1e-4-1e-3).
    public static let lowWater = 4e-4, lowRadius = 10e-6
    public static let midWater = 5e-5, midRadius = 8e-6
    public static let highWater = 5e-6, highRadius = 40e-6
    /// Asymmetry of water drops and of ice crystals in the visible.
    public static let waterAsymmetry = 0.85, iceAsymmetry = 0.75

    /// The sample's three layers, bottom up. The low layer's base is the
    /// sample's cloud base when that is below the mid layer (ERA5's cloud
    /// base is the lowest cloud's, which may be mid or high cloud).
    public static func layers(_ s: CloudSample) -> [CloudLayer] {
        var lowBase = defaultLowBase
        if let b = s.baseHeight, b < midBase { lowBase = max(b, 0) }
        let lowTop = s.convective ? cumulonimbusTop : lowBase + lowDepth
        return [
            CloudLayer(kind: .low, base: lowBase, top: lowTop, cover: s.low, waterContent: lowWater,
                       effectiveRadius: lowRadius, density: CloudOptics.waterDensity, asymmetry: waterAsymmetry),
            CloudLayer(kind: .mid, base: midBase, top: midTop, cover: s.mid, waterContent: midWater,
                       effectiveRadius: midRadius, density: CloudOptics.waterDensity, asymmetry: waterAsymmetry),
            CloudLayer(kind: .high, base: highBase, top: highTop, cover: s.high, waterContent: highWater,
                       effectiveRadius: highRadius, density: CloudOptics.iceDensity, asymmetry: iceAsymmetry),
        ]
    }
}
