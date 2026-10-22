import Foundation

/// Track R6's render settings: the effect slots' resolution, the
/// upsample, and the test emitters that look-dev shots and F9 draw through
/// the slots. R6 owns this file; `RenderSettings` holds one.
public struct TransparencySettings: Codable, Equatable {
    /// The effect targets' resolution (R7's tiers choose it).
    public var resolution = EffectResolution.half
    /// The upsample's depth tolerance, relative in linear depth: bilinear
    /// where the four texels are within it of the pixel, nearest-depth
    /// beyond (`EffectSlots.upsampleWeights`).
    public var upsampleTolerance = 0.1
    /// Shapes drawn through the slots, to prove and inspect them: none
    /// unless a shot or a test asks.
    public var testEmitters: [EffectTestEmitter] = []
    /// Look-dev: the opaque scene is wiped to black at infinity before the
    /// test emitters' column, so a shot shows nothing but R6's own drawing.
    public var testBackdrop = false

    public init() {}

    private enum CodingKeys: String, CodingKey { case resolution, upsampleTolerance, testEmitters, testBackdrop }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try c.decodeIfPresent(EffectResolution.self, forKey: .resolution) ?? .half
        upsampleTolerance = try c.decodeIfPresent(Double.self, forKey: .upsampleTolerance) ?? 0.1
        testEmitters = try c.decodeIfPresent([EffectTestEmitter].self, forKey: .testEmitters) ?? []
        testBackdrop = try c.decodeIfPresent(Bool.self, forKey: .testBackdrop) ?? false
    }
}

/// The effect targets' resolution against the frame's.
public enum EffectResolution: String, Codable, CaseIterable {
    case half, full

    /// Frame pixels per target texel, along each axis.
    public var scale: Int { self == .half ? 2 : 1 }
}

/// A test shape drawn through the effect slots exactly as the effect tracks
/// will draw theirs. Placed in the camera target's frame
/// (`EffectTargetFrame`): metres east, north and up of the target.
public struct EffectTestEmitter: Codable, Equatable {
    public enum Kind: String, Codable, CaseIterable {
        /// A lit homogeneous box, a cloud deck's stand-in (C2): the clouds
        /// layer, its front where its opacity reaches 2 %.
        case slab
        /// A ray-marched emissive cone, a plume's stand-in (P2): the volumes
        /// layer, drawn as the back faces of its proxy.
        case cone
        /// Soft lit billboards, smoke's stand-in (P3): weighted-blended OIT,
        /// depth-tested at half resolution with a soft fade.
        case sprites
        /// Additive streaks at full resolution after the composite: sparks
        /// (P3).
        case sparks
        /// An opaque grey column drawn in P1: something for the slots to
        /// pass behind and in front of.
        case column
    }

    public var kind: Kind
    /// Its centre (slab, sprites, sparks), apex (cone) or base (column):
    /// m east, north and up of the camera's target.
    public var position = [0.0, 0.0, 0.0]
    /// Its size, m: the slab's half-width (it is 0.2 of that thick), the
    /// cone's length (its base radius is 0.25 of it), the radius of the
    /// sprites' and sparks' cloud, the column's height (its radius is 0.04
    /// of it).
    public var size = 50.0
    /// The cone's axis, apex to base, and the sparks' flight: east, north,
    /// up. Down by default.
    public var axis = [0.0, 0.0, -1.0]
    /// How many sprites or sparks.
    public var count = 12

    public init(_ kind: Kind, position: [Double] = [0, 0, 0], size: Double = 50, axis: [Double] = [0, 0, -1],
                count: Int = 12) {
        self.kind = kind
        self.position = position
        self.size = size
        self.axis = axis
        self.count = count
    }

    private enum CodingKeys: String, CodingKey { case kind, position, size, axis, count }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        position = try c.decodeIfPresent([Double].self, forKey: .position) ?? [0, 0, 0]
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 50
        axis = try c.decodeIfPresent([Double].self, forKey: .axis) ?? [0, 0, -1]
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 12
    }
}
