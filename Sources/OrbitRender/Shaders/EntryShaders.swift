// Entry: the plasma sheath's shock-layer shell and wake (track P6 owns this module).
let entryShaderSource = #"""
// ------------------------------------------------------------- entry ---
// Empty until P6; EntryPass compiles it.
"""#

extension ShaderModule {
    public static let entry = ShaderModule(name: "Entry", source: entryShaderSource)
}
