import Foundation
import Metal
import OrbitCore
import OrbitScene

// Track C2: the clouds' textures that do not change from frame to frame.
// The noise volumes are generated on the GPU at the first frame by
// CloudShaders' `cloud_noise_*` kernels, which mirror OrbitScene's
// CloudNoise; the far regime's slab LUT is CloudSlabLUT's bake; the air's
// transmittance and sky irradiance are A1's tables as A2 shares them
// (CloudAir).

/// The noise volumes, made once on the GPU.
@MainActor
final class CloudNoiseVolumes {
    /// 128³ RGBA: Perlin-Worley and three Worley fBm octaves, mipmapped.
    let shape: MTLTexture
    /// 32³ RGBA: three Worley fBm octaves, mipmapped.
    let detail: MTLTexture
    /// 128² RG in [−1, 1]: curl.
    let curl: MTLTexture
    private(set) var generated = false

    init?(device: MTLDevice) {
        func volume(_ n: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor()
            d.textureType = .type3D
            d.pixelFormat = .rgba8Unorm
            d.width = n
            d.height = n
            d.depth = n
            d.mipmapLevelCount = Int(log2(Double(n))) + 1
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Snorm, width: CloudNoise.curlSize,
                                                         height: CloudNoise.curlSize, mipmapped: false)
        c.usage = [.shaderRead, .shaderWrite]
        c.storageMode = .private
        guard let shape = volume(CloudNoise.shapeSize), let detail = volume(CloudNoise.detailSize),
              let curl = device.makeTexture(descriptor: c) else { return nil }
        shape.label = "Cloud shape noise"
        detail.label = "Cloud detail noise"
        curl.label = "Cloud curl noise"
        self.shape = shape
        self.detail = detail
        self.curl = curl
    }

    /// Generates the volumes and their mips on `cb`, once.
    func generate(on cb: MTLCommandBuffer, pipelines: (shape: MTLComputePipelineState, detail: MTLComputePipelineState,
                                                        curl: MTLComputePipelineState)) {
        guard !generated, let enc = cb.makeComputeCommandEncoder() else { return }
        enc.label = "Cloud noise"
        func dispatch3(_ p: MTLComputePipelineState, _ t: MTLTexture) {
            enc.setComputePipelineState(p)
            enc.setTexture(t, index: 0)
            enc.dispatchThreads(MTLSize(width: t.width, height: t.height, depth: t.depth),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
        }
        dispatch3(pipelines.shape, shape)
        dispatch3(pipelines.detail, detail)
        enc.setComputePipelineState(pipelines.curl)
        enc.setTexture(curl, index: 0)
        enc.dispatchThreads(MTLSize(width: curl.width, height: curl.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        if let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: shape)
            blit.generateMipmaps(for: detail)
            blit.endEncoding()
        }
        generated = true
    }
}

/// The far LUT, as a texture.
@MainActor
final class CloudTables {
    /// CloudSlabLUT: x the view cosine, y the Sun's, z optical depth by layer
    /// and side (from above, from below).
    let slab: MTLTexture

    /// The bake, once per process (CPU, a fraction of a second in Release).
    static let slabLUT = CloudSlabLUT.standard()

    init?(device: MTLDevice) {
        let lut = Self.slabLUT
        let n = CloudSlabLUT.cosines, depth = CloudSlabLUT.depths * lut.slabs.count * 2
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba32Float
        d.width = n
        d.height = n
        d.depth = depth
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let slab = device.makeTexture(descriptor: d) else { return nil }
        lut.texels.withUnsafeBytes { b in
            slab.replace(region: MTLRegionMake3D(0, 0, 0, n, n, depth), mipmapLevel: 0, slice: 0,
                         withBytes: b.baseAddress!, bytesPerRow: 16 * n, bytesPerImage: 16 * n * n)
        }
        slab.label = "Cloud slab LUT"
        self.slab = slab
    }
}

/// A1's transmittance (256×64) and sky irradiance (64×16) as A2 shares
/// them: its LUT pass's textures when it ran this frame (P0, before the
/// clouds), else its tables (`AtmosphereTables`, the same settings' key)
/// uploaded here once, so the clouds draw with the atmosphere off too.
@MainActor
final class CloudAir {
    struct Tables {
        let transmittance: MTLTexture
        let irradiance: MTLTexture
        /// The top of the air above the ground, m.
        let top: Double
    }

    private let device: MTLDevice
    private var own: (key: AtmosphereTables.Key, transmittance: MTLTexture, irradiance: MTLTexture)?

    init(device: MTLDevice) { self.device = device }

    /// Starts A2's build of the tables for `settings`.
    func request(_ settings: AtmosphereSettings) { AtmosphereTables.shared.request(AtmosphereTables.Key(settings)) }

    /// The tables for this frame; nil while they are being built and the
    /// settings do not wait for them.
    func tables(_ f: FrameContext) -> Tables? {
        let settings = f.settings.atmosphere
        let key = AtmosphereTables.Key(settings)
        guard let lut = AtmosphereTables.shared.tables(key, wait: settings.waitForTables) else { return nil }
        let top = lut.topRadius - lut.bottomRadius
        if let t = f.textures[.atmosphereLUTs], let i = f.textures[.atmosphereIrradiance] {
            return Tables(transmittance: t, irradiance: i, top: top)
        }
        if own?.key != key {
            guard let t = Self.upload(lut.transmittance, "Cloud air transmittance (A1)", device: device),
                  let i = Self.upload(lut.irradiance, "Cloud sky irradiance (A1)", device: device) else { return nil }
            own = (key, t, i)
        }
        guard let own else { return nil }
        return Tables(transmittance: own.transmittance, irradiance: own.irradiance, top: top)
    }

    private static func upload(_ t: AtmosphereLUT.Table, _ label: String, device: MTLDevice) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: t.width,
                                                          height: t.height, mipmapped: false)
        td.usage = .shaderRead
        td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        t.texels.withUnsafeBytes { b in
            tex.replace(region: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0,
                        withBytes: b.baseAddress!, bytesPerRow: 16 * t.width)
        }
        tex.label = label
        return tex
    }
}
