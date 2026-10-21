import Foundation

/// Track R5's render settings: the baked per-vertex ambient occlusion
/// (`AmbientOcclusion`, `AmbientOcclusionBaker`). R5 owns this file;
/// `RenderSettings` holds one. Every member may be left out of a spec.
public struct AmbientOcclusionSettings: Codable, Equatable {
    /// Bake and apply AO; off, every vertex is drawn unoccluded.
    public var enabled = true
    /// Cosine-weighted rays cast from each vertex (and from each vertex's
    /// back for a two-sided shape).
    public var raysPerVertex = 32
    /// Occluders farther than this (m) do not count: AO is contact shadow
    /// from the vessel's own nearby structure, not its gross shape.
    public var maxDistance = 3.0
    /// Facets are subdivided until no edge is longer than this (m), so that
    /// long panels carry enough vertices to show it.
    public var maxEdge = 0.5
    /// A finished bake fades in over this long (s, the renderer's clock).
    public var fadeDuration = 0.5
    /// The rays' pattern is rotated per vertex from this seed: one seed,
    /// one result, whatever the thread count.
    public var seed: UInt64 = 1

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, raysPerVertex, maxDistance, maxEdge, fadeDuration, seed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AmbientOcclusionSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        raysPerVertex = try c.decodeIfPresent(Int.self, forKey: .raysPerVertex) ?? d.raysPerVertex
        maxDistance = try c.decodeIfPresent(Double.self, forKey: .maxDistance) ?? d.maxDistance
        maxEdge = try c.decodeIfPresent(Double.self, forKey: .maxEdge) ?? d.maxEdge
        fadeDuration = try c.decodeIfPresent(Double.self, forKey: .fadeDuration) ?? d.fadeDuration
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? d.seed
    }
}
