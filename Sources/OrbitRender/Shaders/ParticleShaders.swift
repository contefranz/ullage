// GPU particles: emit, simulate and compact kernels; streaks, smoke and chunks (track P3 owns this module).
let particleShaderSource = #"""
// ---------------------------------------------------------- particle ---
// Empty until P3; the particle passes compile it.
"""#

extension ShaderModule {
    public static let particle = ShaderModule(name: "Particle", source: particleShaderSource)
}
