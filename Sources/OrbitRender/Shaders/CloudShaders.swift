// Volumetric clouds: noise, the three regimes, the cloud shadow map (track C2 owns this module).
let cloudShaderSource = #"""
// ------------------------------------------------------------- cloud ---
// Empty until C2; CloudPass compiles it.
"""#

extension ShaderModule {
    public static let cloud = ShaderModule(name: "Cloud", source: cloudShaderSource)
}
