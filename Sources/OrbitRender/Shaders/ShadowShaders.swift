// Shadow maps: the casters' depth-only vertex functions (track R4 owns this module).
let shadowShaderSource = #"""
// ------------------------------------------------------------ shadow ---
// Empty until R4; ShadowPass compiles it.
"""#

extension ShaderModule {
    public static let shadow = ShaderModule(name: "Shadow", source: shadowShaderSource)
}
