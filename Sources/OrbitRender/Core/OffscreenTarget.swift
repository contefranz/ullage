import Foundation
import Metal
import OrbitScene

/// A texture to render a scene into without a window, and its pixels.
@MainActor
public final class OffscreenTarget {
    public let texture: MTLTexture

    /// `width` × `height` pixels in `format` (the drawable's by default),
    /// readable from the CPU.
    public init?(device: MTLDevice, width: Int, height: Int, format: MTLPixelFormat = .bgra8Unorm_srgb) {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                         mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        texture = t
    }

    public var width: Int { texture.width }
    public var height: Int { texture.height }

    /// The pixels, rows top first, 4 bytes each in the texture's order
    /// (B, G, R, A for the drawable's format). Call once the GPU is done.
    public func bytes() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { p in
            texture.getBytes(p.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
        }
        return out
    }
}

extension SceneRenderer {
    /// Renders `scene` into `target` and waits for the GPU.
    @discardableResult
    public func renderAndWait(_ scene: RenderScene, into target: OffscreenTarget) -> MTLCommandBuffer? {
        guard let cb = render(scene, to: target.texture) else { return nil }
        cb.waitUntilCompleted()
        return cb
    }
}
