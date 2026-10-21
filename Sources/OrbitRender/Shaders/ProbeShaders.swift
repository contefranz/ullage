// The environment probe: the cube faces, GGX prefiltering, irradiance and SH9 (track R3 owns this module).
let probeShaderSource = #"""
// ------------------------------------------------------------- probe ---
// Empty until R3; EnvironmentProbePass compiles it.
"""#

extension ShaderModule {
    public static let probe = ShaderModule(name: "Probe", source: probeShaderSource)
}
