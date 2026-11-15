import Foundation
import Metal
import OrbitScene

/// The volume noise (P3): a tileable 128³ RG8 field of gradient noise
/// (`VolumeNoiseField`), made on the GPU at load with a fixed seed, so it is
/// procedural, MIT by construction and the same on every run. Smoke erodes
/// its puffs with it on the turbulence clock; P2's plumes may sample it too.
@MainActor
public final class VolumeNoise {
    public let texture: MTLTexture
    /// A trilinear sampler repeating on every axis.
    public let sampler: MTLSamplerState
    /// Whether the texels are written (the first frame's command buffer does it).
    public private(set) var isReady = false
    private let pipeline: MTLComputePipelineState

    public init(device: MTLDevice, library: MTLLibrary) throws {
        let n = VolumeNoiseField.size
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rg8Unorm
        d.width = n
        d.height = n
        d.depth = n
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let texture = device.makeTexture(descriptor: d) else { throw SceneRenderer.Failure.noResources }
        texture.label = "Volume noise"
        self.texture = texture
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.sAddressMode = .repeat
        s.tAddressMode = .repeat
        s.rAddressMode = .repeat
        guard let sampler = device.makeSamplerState(descriptor: s),
              let fn = library.makeFunction(name: "particle_noise") else {
            throw ShaderLibrary.Failure.missingFunction("particle_noise")
        }
        self.sampler = sampler
        pipeline = try device.makeComputePipelineState(function: fn)
    }

    /// Writes the texels on `enc`, once.
    public func encodeIfNeeded(_ enc: MTLComputeCommandEncoder) {
        guard !isReady else { return }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(texture, index: 0)
        let n = VolumeNoiseField.size
        enc.dispatchThreads(MTLSize(width: n, height: n, depth: n), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
        isReady = true
    }
}
