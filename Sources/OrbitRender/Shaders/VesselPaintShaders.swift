// The vessels' paint regions, decals, frost and char: a header of the vessel
// module (track VM1 owns this file).
let vesselPaintShaderSource = #"""
// --------------------------------------------------------- vessel paint ---
// Empty until VM1.
"""#

extension ShaderHeader {
    public static let vesselPaint = ShaderHeader(name: "VesselPaint", source: vesselPaintShaderSource)
}
