import Foundation

/// Track R4's render settings: the Sun's shadow maps and their filtering
/// (`ShadowFitting`, ShadowPass and ShadowCommon). R4 owns this file;
/// `RenderSettings` holds one. Every member may be left out of a spec.
public struct ShadowSettings: Codable, Equatable {
    /// Draw the shadow maps; off, every receiver is lit.
    public var enabled = true
    /// Texels per side of each map: 4096 at Medium and High, 2048 at Low.
    public var mapSize = 4096
    /// Maps per frame, at most 4 (`LightingUniforms.maxShadowMaps`): the
    /// detail map, the camera target's cluster, then other clusters and
    /// sites by their size on screen. Low and Medium draw 2.
    public var maxMaps = 4
    /// Draw the detail map about the camera target, finer than its
    /// cluster's (`ShadowFitting.detailRadius`).
    public var detailMap = true
    /// Taps of the PCSS blocker search and of its filter, each (16 at
    /// Medium, 32 at High). 9 or fewer is a fixed 3×3 PCF with no blocker
    /// search (Low).
    public var filterSamples = 16
    /// Vessels whose bounding spheres come closer than this (m) share a map.
    public var clusterLink = 300.0
    /// A cluster or a site gets a map only when it is more than this many
    /// pixels across on screen.
    public var minimumPixels = 64.0
    /// Against acne: the receiver moves off its surface along its normal
    /// by this many texels, times the sine of the Sun's incidence.
    public var normalOffset = 1.5
    /// Against acne: a depth bias of this many texels per unit tangent of
    /// the Sun's incidence (at most 8), on top of one texel.
    public var slopeBias = 1.0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, mapSize, maxMaps, detailMap, filterSamples, clusterLink, minimumPixels, normalOffset, slopeBias
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShadowSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        mapSize = try c.decodeIfPresent(Int.self, forKey: .mapSize) ?? d.mapSize
        maxMaps = try c.decodeIfPresent(Int.self, forKey: .maxMaps) ?? d.maxMaps
        detailMap = try c.decodeIfPresent(Bool.self, forKey: .detailMap) ?? d.detailMap
        filterSamples = try c.decodeIfPresent(Int.self, forKey: .filterSamples) ?? d.filterSamples
        clusterLink = try c.decodeIfPresent(Double.self, forKey: .clusterLink) ?? d.clusterLink
        minimumPixels = try c.decodeIfPresent(Double.self, forKey: .minimumPixels) ?? d.minimumPixels
        normalOffset = try c.decodeIfPresent(Double.self, forKey: .normalOffset) ?? d.normalOffset
        slopeBias = try c.decodeIfPresent(Double.self, forKey: .slopeBias) ?? d.slopeBias
    }
}
