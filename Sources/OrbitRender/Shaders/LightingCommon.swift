// Shared lighting for the modules that shade surfaces: the BRDF, image-based
// lighting, the Sun's disc as an area light, specular anti-aliasing and the
// local lights. A header: every module that lights a surface includes it (track R2 owns this file).
let lightingCommonSource = #"""
// ------------------------------------------------------------- lighting ---
// Empty until R2: the vessel module lights with its own legacy terms.
"""#

extension ShaderHeader {
    public static let lightingCommon = ShaderHeader(name: "LightingCommon", source: lightingCommonSource)
}
