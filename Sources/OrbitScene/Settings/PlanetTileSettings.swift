import Foundation

/// Track E1's render settings: the planet tile cache (docs/m16/planet-tile-cache.md).
/// `RenderSettings` holds one; a spec may give only what it changes.
public struct PlanetTileSettings: Codable, Equatable {
    /// Stream the Earth's tiles from Application Support/OrbitSim/Tiles
    /// when they are there. Off (or without the files), the Earth keeps its
    /// fallback look: earth.jpg if present, else the plain ocean.
    public var enabled = true
    /// GPU memory for all the Earth's atlases, MB, split between the layers
    /// by `PlanetTileLayerKind.memoryShare`.
    public var atlasMemoryMB = 256
    /// The largest a texel may appear on screen, px (the quadtree's pixel error).
    public var pixelError = 1.0
    /// The share of a layer's atlas the quadtree's selection may fill; the
    /// rest holds ancestors, prefetched tiles and the eviction reserve.
    public var selectionShare = 0.5
    /// Tiles uploaded per layer per frame, at most.
    public var uploadsPerFrame = 12
    /// Tiles loading or decoding per layer at once, at most.
    public var maxPendingLoads = 24
    /// How far ahead along the predicted track to prefetch, real seconds
    /// (simulation seconds are these times the warp); empty: no prefetch.
    public var prefetchSeconds = [0.5, 1.0, 2.0]
    /// Prefetch views are selected every this many frames.
    public var prefetchInterval = 4
    /// The indirection texture's deepest level at most (512² entries per
    /// face at 9); a layer's texture stops at the deepest level it stores
    /// everywhere, and deeper tiles (an inset's) go through its hash table.
    public var maxTextureLevel = 9
    /// Load every wanted tile before drawing (snapshots), instead of
    /// streaming them in over the next frames.
    public var synchronous = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, atlasMemoryMB, pixelError, selectionShare, uploadsPerFrame, maxPendingLoads, prefetchSeconds
        case prefetchInterval, maxTextureLevel, synchronous
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PlanetTileSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        atlasMemoryMB = try c.decodeIfPresent(Int.self, forKey: .atlasMemoryMB) ?? d.atlasMemoryMB
        pixelError = try c.decodeIfPresent(Double.self, forKey: .pixelError) ?? d.pixelError
        selectionShare = try c.decodeIfPresent(Double.self, forKey: .selectionShare) ?? d.selectionShare
        uploadsPerFrame = try c.decodeIfPresent(Int.self, forKey: .uploadsPerFrame) ?? d.uploadsPerFrame
        maxPendingLoads = try c.decodeIfPresent(Int.self, forKey: .maxPendingLoads) ?? d.maxPendingLoads
        prefetchSeconds = try c.decodeIfPresent([Double].self, forKey: .prefetchSeconds) ?? d.prefetchSeconds
        prefetchInterval = try c.decodeIfPresent(Int.self, forKey: .prefetchInterval) ?? d.prefetchInterval
        maxTextureLevel = try c.decodeIfPresent(Int.self, forKey: .maxTextureLevel) ?? d.maxTextureLevel
        synchronous = try c.decodeIfPresent(Bool.self, forKey: .synchronous) ?? d.synchronous
    }
}

/// The Earth's tile layers (M1.6 design §3-4), each one OSTILES1 file in
/// Application Support/OrbitSim/Tiles (plus insets for the albedo).
public enum PlanetTileLayerKind: String, CaseIterable, Codable {
    /// BMNG 2004 monthly colour, 500 m, `earth-bmng-2004-MM.ostiles`, with
    /// the Cape inset `earth-cape-landsat.ostiles` over it.
    case albedo
    /// Natural Earth water with the 1960s Aral Sea and Lake Chad, about 1 km,
    /// `earth-water.ostiles`.
    case water
    /// ETOPO 2022 relief normals, about 1 km, `earth-relief.ostiles`.
    case relief

    /// Its share of `PlanetTileSettings.atlasMemoryMB`.
    public var memoryShare: Double {
        switch self {
        case .albedo: return 0.6
        case .water: return 0.1
        case .relief: return 0.3
        }
    }

    /// Whether the atlas holds sRGB colour (decoded to linear by the sampler).
    public var isColor: Bool { self == .albedo }
}

/// The tile files' names and the month a scenario's date takes.
public enum EarthTileFiles {
    /// BMNG's month file, e.g. `earth-bmng-2004-12.ostiles`.
    public static func albedo(month: Int) -> String { "earth-bmng-2004-\(month < 10 ? "0" : "")\(month).ostiles" }
    public static let capeInset = "earth-cape-landsat.ostiles"
    public static let water = "earth-water.ostiles"
    public static let relief = "earth-relief.ostiles"

    /// Of the months available, the nearest to `month` round the year (a
    /// tie goes to the earlier). E2's EarthLayers may choose otherwise.
    public static func nearestMonth(to month: Int, available: [Int]) -> Int? {
        available.min { a, b in
            func d(_ m: Int) -> Int { let x = abs(m - month) % 12; return min(x, 12 - x) }
            return d(a) != d(b) ? d(a) < d(b) : a < b
        }
    }
}
