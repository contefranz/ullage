// The vessels' materials and analytic relief, to a surface sample: a header
// of the vessel module (track VM2 owns this file).
let vesselMaterialShaderSource = #"""
// ------------------------------------------------------ vessel material ---
// Empty until VM2.
"""#

extension ShaderHeader {
    public static let vesselMaterial = ShaderHeader(name: "VesselMaterial", source: vesselMaterialShaderSource)
}
