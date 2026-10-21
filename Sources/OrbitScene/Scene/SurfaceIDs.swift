import Foundation

/// The material, paint-set and decal-set ids a vertex carries in vertex
/// v2's `normal.w` (ShaderCommon's `VertexV2`), 0-255 each, packed as the
/// integer material + 256 paint + 65,536 decal, which a Float holds exactly
/// (below 2^24) and no denormal flush can touch.
public struct SurfaceIDs: Equatable {
    public var material: UInt8
    public var paint: UInt8
    public var decal: UInt8

    public init(material: UInt8 = 0, paint: UInt8 = 0, decal: UInt8 = 0) {
        self.material = material
        self.paint = paint
        self.decal = decal
    }

    public var packed: Float { Float(UInt32(material) | UInt32(paint) << 8 | UInt32(decal) << 16) }

    public init(packed: Float) {
        let v = UInt32(max(0, min(16_777_215, packed.rounded())))
        self.init(material: UInt8(v & 255), paint: UInt8(v >> 8 & 255), decal: UInt8(v >> 16 & 255))
    }
}
