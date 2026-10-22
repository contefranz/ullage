import Foundation
import Metal

extension ImageFiles {
    /// A Portable Float Map of linear light given as RGBA floats, rows top
    /// first (RGB, little-endian, rows bottom first, scale -1). Track R1:
    /// a snapshot's light before the tone map, in cd/m².
    public static func writePFM(light: [Float], width: Int, height: Int, to url: URL) throws {
        var data = Data("PF\n\(width) \(height)\n-1.0\n".utf8)
        var floats = [Float](repeating: 0, count: 3 * width * height)
        for y in 0..<height {
            let row = height - 1 - y
            for x in 0..<width {
                let i = 4 * (row * width + x), o = 3 * (y * width + x)
                floats[o] = light[i]
                floats[o + 1] = light[i + 1]
                floats[o + 2] = light[i + 2]
            }
        }
        floats.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }
}

extension SceneRenderer {
    /// R1's post pass, when the renderer has it.
    public var post: PostPass? { graph.passes.first { $0 is PostPass } as? PostPass }
}
