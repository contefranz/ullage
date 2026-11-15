import Foundation
import OrbitCore

/// What a material or paint evaluation gives the lighting: the Swift mirror
/// of LightingCommon's `SurfaceSample`, the contract between the vessel
/// pass (R2) and the vehicle-look tracks (VM1's paint, VM2's materials).
/// The shader's fields and meanings are the same; see LightingCommon.swift.
public struct SurfaceSample: Equatable {
    /// Linear Rec. 709. A dielectric's diffuse albedo, or a metal's
    /// reflectance at normal incidence (its F0 colour); 0...1.
    public var albedo: RenderScene.RGB
    /// 0 dielectric, 1 conductor; between only where a texel mixes them.
    public var metalness: Float
    /// Perceptual roughness r (α = r²), 0...1; the lighting clamps it at
    /// `BRDF.minimumRoughness` and widens it for specular anti-aliasing.
    public var roughness: Float
    /// A dielectric's reflectance at normal incidence (0.04 for paint and
    /// glass); metals take theirs from `albedo`.
    public var reflectance: Float
    /// Cavity occlusion of the indirect light the material knows about
    /// (relief, crevices), 1 for none; the baked AO multiplies it.
    public var occlusion: Float
    /// Light the surface emits, cd/m² (linear Rec. 709): glow, lit windows.
    public var emission: RenderScene.RGB

    public init(albedo: RenderScene.RGB, metalness: Float = 0, roughness: Float = 0.5, reflectance: Float = 0.04,
                occlusion: Float = 1, emission: RenderScene.RGB = .black) {
        self.albedo = albedo
        self.metalness = metalness
        self.roughness = roughness
        self.reflectance = reflectance
        self.occlusion = occlusion
        self.emission = emission
    }
}

/// Each material key's shading, a stand-in until VM2's `SurfaceMaterial`
/// table gives albedo from measured solar absorptance and metals' F0 from
/// n, k. The colour stays the shape's own (`VisualShape.color`, the
/// dresser's finish), which is a dielectric's albedo or a metal's F0;
/// this table adds the model and the roughness. Every value is an
/// estimate that only has to look right (L).
public enum MaterialDefaults {
    public enum Model: Int, Equatable {
        /// Paint, primer, cork, fibreglass, ablator, concrete.
        case dielectric = 0
        /// Bare or aluminised metal, foil.
        case metal = 1
        /// Window glass: a smooth dielectric.
        case glass = 2
        /// Parachute canvas: a rough dielectric (thin translucency later).
        case fabric = 3
    }

    public struct Entry: Equatable {
        public var model: Model
        /// Perceptual roughness.
        public var roughness: Double
        /// A dielectric's F0.
        public var reflectance: Double

        public init(_ model: Model, roughness: Double, reflectance: Double = 0.04) {
            self.model = model
            self.roughness = roughness
            self.reflectance = reflectance
        }

        public var metalness: Double { model == .metal ? 1 : 0 }
    }

    /// The entry for `key`; a look-dev key's own (`lookDev`); `fallback`
    /// for a key the table does not know.
    public static func entry(for key: MaterialKey) -> Entry {
        if let e = table[key] { return e }
        let p = key.rawValue.split(separator: ".")
        if p.count == 3, p[0] == "lookdev", let r = Double(p[2].replacingOccurrences(of: "_", with: ".")),
           let model = ["dielectric": Model.dielectric, "metal": .metal][String(p[1])] {
            return Entry(model, roughness: r)
        }
        return fallback
    }

    /// A look-dev material: `model` at perceptual roughness `roughness`
    /// ("lookdev.metal.0_30").
    public static func lookDev(_ model: Model, roughness: Double) -> MaterialKey {
        let name = model == .metal ? "metal" : "dielectric"
        return MaterialKey("lookdev.\(name).\(String(format: "%.2f", roughness).replacingOccurrences(of: ".", with: "_"))")
    }

    public static let fallback = Entry(.dielectric, roughness: 0.6)

    public static let table: [MaterialKey: Entry] = [
        // Paints and coatings.
        .apolloWhitePaint: Entry(.dielectric, roughness: 0.55),
        .apolloInterstagePrimer: Entry(.dielectric, roughness: 0.7),
        .apolloSMRCSHousing: Entry(.dielectric, roughness: 0.55),
        .apolloSMRadiator: Entry(.dielectric, roughness: 0.45),
        .apolloSMScimitar: Entry(.dielectric, roughness: 0.55),
        .apolloHighGainAntenna: Entry(.dielectric, roughness: 0.6),
        .apolloLESCanard: Entry(.dielectric, roughness: 0.6),
        .apolloLESSkirt: Entry(.dielectric, roughness: 0.6),
        .apolloLESTower: Entry(.dielectric, roughness: 0.5),
        .apolloLTAB: Entry(.dielectric, roughness: 0.7),
        // Non-metallic structure and insulation.
        .apolloBPC: Entry(.dielectric, roughness: 0.65),
        .apolloBPCSoft: Entry(.dielectric, roughness: 0.85),
        .apolloAblator: Entry(.dielectric, roughness: 0.9),
        .apolloCMRCSPort: Entry(.dielectric, roughness: 0.8),
        .apolloSLACork: Entry(.dielectric, roughness: 0.85),
        .apolloSLASeam: Entry(.dielectric, roughness: 0.7),
        .apolloSICHeatShield: Entry(.dielectric, roughness: 0.85),
        .apolloSIIHeatShield: Entry(.dielectric, roughness: 0.85),
        .apolloSICCurtain: Entry(.fabric, roughness: 0.9),
        .apolloCanvas: Entry(.fabric, roughness: 0.95),
        .apolloCMWindow: Entry(.glass, roughness: 0.05),
        // Metals and foils.
        .apolloCMFoil: Entry(.metal, roughness: 0.18),
        .apolloLMFoil: Entry(.metal, roughness: 0.25),
        .apolloSMAluminium: Entry(.metal, roughness: 0.35),
        .apolloGreyMetal: Entry(.metal, roughness: 0.45),
        .apolloCMWindowFrame: Entry(.metal, roughness: 0.4),
        .apolloDockingProbe: Entry(.metal, roughness: 0.3),
        .apolloDockingRing: Entry(.metal, roughness: 0.35),
        .apolloQBall: Entry(.metal, roughness: 0.35),
        .apolloEngineBell: Entry(.metal, roughness: 0.55),
        .apolloF1Extension: Entry(.metal, roughness: 0.6),
        .apolloF1Insulation: Entry(.metal, roughness: 0.65),
        .apolloSPSColumbium: Entry(.metal, roughness: 0.6),
        .apolloSPSNozzle: Entry(.metal, roughness: 0.4),
        // The pad.
        .lc39aLattice: Entry(.dielectric, roughness: 0.75),
        .lc39aSteel: Entry(.dielectric, roughness: 0.7),
        .lc39aConcrete: Entry(.dielectric, roughness: 0.9),
        .lc39aRefractory: Entry(.dielectric, roughness: 0.9),
    ]

    /// The surface a shape shows where no paint covers it: its colour as
    /// albedo (or F0) with its key's model and roughness.
    public static func sample(_ shape: VisualShape) -> SurfaceSample {
        let e = entry(for: shape.material)
        let c = shape.color
        return SurfaceSample(albedo: RenderScene.RGB(Float(c.0), Float(c.1), Float(c.2)), metalness: Float(e.metalness),
                             roughness: Float(e.roughness), reflectance: Float(e.reflectance))
    }
}

/// VM1's paint colours as the renderer's stand-in until VM1's GPU paint
/// evaluator lands: each vertex's paint from the Swift evaluator
/// (`Markings`, regions only: the lettering and flags wait for the decal
/// atlas), as vertex v2's paint id, 1 + the colour's index here (0 is no
/// paint: the shape's material shows).
public enum PaintStandIn {
    /// The colours a paint id names, in id order from 1.
    public static let colours = PaintColour.allCases

    /// The id for `colour`.
    public static func id(_ colour: PaintColour) -> UInt8 {
        UInt8(1 + (colours.firstIndex(of: colour) ?? 0))
    }

    /// The colour of id `id`, nil for 0.
    public static func colour(_ id: UInt8) -> PaintColour? {
        id >= 1 && Int(id) <= colours.count ? colours[Int(id) - 1] : nil
    }

    /// How a paint colour shades: `PaintColour.linear` as albedo, and the
    /// finish (aluminium and Kapton are metals; L).
    public static func sample(_ colour: PaintColour) -> SurfaceSample {
        let metal = colour == .aluminium || colour == .kapton
        let roughness: Float
        switch colour {
        case .aluminium: roughness = 0.35
        case .kapton: roughness = 0.18
        case .frost: roughness = 0.8
        case .black: roughness = 0.5
        default: roughness = 0.55
        }
        return SurfaceSample(albedo: colour.linear, metalness: metal ? 1 : 0, roughness: roughness)
    }

    /// The paint id of each vertex of `mesh`, a shape of the part named
    /// `part` at `partOffset` in the construction frame, on `variant`: the
    /// outer face's region paint (decals left out).
    public static func ids(part: String, shape: VisualShape, mesh: VisualShape.Mesh, partOffset: Vec3,
                           variant: ApolloVariant) -> [UInt8] {
        guard let element = PaintElement.of(part: part, shape: shape, partOffset: partOffset, variant: variant) else {
            return [UInt8](repeating: 0, count: mesh.vertices.count)
        }
        let scheme = regionSchemes[variant] ?? regionScheme(variant)
        return mesh.vertices.map { v in
            scheme.sample(element, at: PaintCoordinates(v, of: shape, partOffset: partOffset)).map { id($0.colour) } ?? 0
        }
    }

    static func regionScheme(_ variant: ApolloVariant) -> PaintScheme {
        let s = Markings.scheme(for: variant)
        return PaintScheme(vehicles: s.vehicles, regions: s.regions, decals: [], probes: [])
    }

    static let regionSchemes: [ApolloVariant: PaintScheme] = {
        var out: [ApolloVariant: PaintScheme] = [:]
        for v in [ApolloVariant.apollo7, .apollo8, .apollo11] { out[v] = regionScheme(v) }
        return out
    }()
}
