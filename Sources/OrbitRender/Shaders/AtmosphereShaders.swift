// The atmosphere: transmittance, multiple-scattering and sky-view LUTs,
// aerial-perspective froxels, the limb from space, and the P2 composite (track A2 owns this module).
let atmosphereShaderSource = #"""
// -------------------------------------------------------- atmosphere ---
// Empty until A2; AtmospherePass compiles it.
"""#

extension ShaderModule {
    public static let atmosphere = ShaderModule(name: "Atmosphere", source: atmosphereShaderSource)
}
