// Post: the NaN guard, histogram and exposure, bloom, tone mapping and dither (track R1 owns this module).
let postShaderSource = #"""
// -------------------------------------------------------------- post ---
// Empty until R1; PostPass compiles it.
"""#

extension ShaderModule {
    public static let post = ShaderModule(name: "Post", source: postShaderSource)
}
