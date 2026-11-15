import Foundation

/// Mip chains for the maps the renderer generates (VM2's Kapton crinkle,
/// F-1 batts, cork and ablator; the decal atlas), built in Swift so the
/// tests and the GPU see the same levels (track R2; the vehicle-look
/// tracks build their maps' mips here).
///
/// - Colour and scalar maps: each level the 2×2 box mean of the one above,
///   in linear values (convert sRGB first). Odd sizes round down; the last
///   row or column joins its neighbour's box.
/// - Normal and roughness maps: a level's normal is the mean of the unit
///   normals of its whole footprint at level 0, renormalised, and its
///   roughness carries what that averaging loses (Toksvig 2005). The mean
///   normal's length |n̄| falls below 1 as the normals spread: with the
///   Gaussian spread Toksvig assumes, their slope variance is
///   (1 - |n̄|) / |n̄|, and the lobe's (α²/2 per axis, Beckmann's and, near
///   its peak, GGX's) adds to it: α'² = mean(α²) + 2 (1 - |n̄|) / |n̄|,
///   clamped at 1. Without it a bumpy foil's distant mips would turn into
///   a mirror and sparkle.
public enum MipBuilder {
    /// A map: `channels` floats per texel, rows top first.
    public struct Image: Equatable {
        public var width: Int
        public var height: Int
        public var channels: Int
        public var pixels: [Float]

        public init(width: Int, height: Int, channels: Int, pixels: [Float]) {
            precondition(pixels.count == width * height * channels, "MipBuilder.Image: \(pixels.count) floats")
            self.width = width
            self.height = height
            self.channels = channels
            self.pixels = pixels
        }

        public subscript(x: Int, y: Int, c: Int) -> Float { pixels[(y * width + x) * channels + c] }
    }

    /// One level of a normal and roughness chain.
    public struct NormalLevel: Equatable {
        public var width: Int
        public var height: Int
        /// Unit normals, three floats per texel (tangent space or world, as given).
        public var normals: [Float]
        /// Perceptual roughness (α = r²), widened by the normals' spread.
        public var roughness: [Float]
        /// The mean normal's length before renormalising, 1 at level 0.
        public var meanLength: [Float]
    }

    /// The number of levels down to 1×1 for `width` × `height`.
    public static func levelCount(width: Int, height: Int) -> Int {
        var n = 1, w = width, h = height
        while w > 1 || h > 1 {
            w = max(1, w / 2)
            h = max(1, h / 2)
            n += 1
        }
        return n
    }

    /// The footprint at the level above of texel `i` of a level `size`
    /// wide, whose level above is `above` wide: 2i and 2i + 1, and the
    /// last texel also takes the odd one left over.
    static func footprint(_ i: Int, size: Int, above: Int) -> Range<Int> {
        let start = min(2 * i, above - 1)
        let end = i == size - 1 ? above : min(2 * i + 2, above)
        return start..<max(end, start + 1)
    }

    /// `image` and its box-filtered levels down to 1×1.
    public static func mips(_ image: Image) -> [Image] {
        var levels = [image]
        while let last = levels.last, last.width > 1 || last.height > 1 {
            let w = max(1, last.width / 2), h = max(1, last.height / 2), c = last.channels
            var out = [Float](repeating: 0, count: w * h * c)
            for y in 0..<h {
                let rows = footprint(y, size: h, above: last.height)
                for x in 0..<w {
                    let cols = footprint(x, size: w, above: last.width)
                    let count = Float(rows.count * cols.count)
                    for k in 0..<c {
                        var sum: Float = 0
                        for yy in rows { for xx in cols { sum += last[xx, yy, k] } }
                        out[(y * w + x) * c + k] = sum / count
                    }
                }
            }
            levels.append(Image(width: w, height: h, channels: c, pixels: out))
        }
        return levels
    }

    /// The normal and roughness chain of a level-0 map of unit `normals`
    /// (three floats per texel) and perceptual `roughness`, down to 1×1,
    /// Toksvig-widened. Each level averages its whole level-0 footprint
    /// (the sums are carried down, not the renormalised normals).
    public static func normalRoughnessMips(width: Int, height: Int, normals: [Float],
                                           roughness: [Float]) -> [NormalLevel] {
        precondition(normals.count == 3 * width * height && roughness.count == width * height,
                     "MipBuilder: \(width)×\(height) needs \(3 * width * height) normal and \(width * height) roughness floats")
        // Per texel: the sums of the unit normals and of α², and the count.
        var sums = Image(width: width, height: height, channels: 5, pixels: (0..<(width * height)).flatMap { i -> [Float] in
            let r = roughness[i]
            return [normals[3 * i], normals[3 * i + 1], normals[3 * i + 2], r * r * r * r, 1]
        })
        var levels: [NormalLevel] = []
        while true {
            levels.append(level(from: sums))
            guard sums.width > 1 || sums.height > 1 else { break }
            let w = max(1, sums.width / 2), h = max(1, sums.height / 2)
            var out = [Float](repeating: 0, count: w * h * 5)
            for y in 0..<h {
                let rows = footprint(y, size: h, above: sums.height)
                for x in 0..<w {
                    let cols = footprint(x, size: w, above: sums.width)
                    for k in 0..<5 {
                        var s: Float = 0
                        for yy in rows { for xx in cols { s += sums[xx, yy, k] } }
                        out[(y * w + x) * 5 + k] = s
                    }
                }
            }
            sums = Image(width: w, height: h, channels: 5, pixels: out)
        }
        return levels
    }

    /// A level from its footprints' sums.
    static func level(from sums: Image) -> NormalLevel {
        let count = sums.width * sums.height
        var normals = [Float](repeating: 0, count: 3 * count), rough = [Float](repeating: 0, count: count)
        var lengths = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let n = Float(sums.pixels[5 * i + 4])
            let x = sums.pixels[5 * i] / n, y = sums.pixels[5 * i + 1] / n, z = sums.pixels[5 * i + 2] / n
            let length = (x * x + y * y + z * z).squareRoot()
            let alpha2 = sums.pixels[5 * i + 3] / n
            let widened = min(alpha2 + toksvigVariance(meanLength: length), 1)
            rough[i] = widened.squareRoot().squareRoot()
            lengths[i] = min(length, 1)
            let inv: Float = length > 1e-6 ? 1 / length : 0
            normals[3 * i] = length > 1e-6 ? x * inv : 0
            normals[3 * i + 1] = length > 1e-6 ? y * inv : 0
            normals[3 * i + 2] = length > 1e-6 ? z * inv : 1
        }
        return NormalLevel(width: sums.width, height: sums.height, normals: normals, roughness: rough,
                           meanLength: lengths)
    }

    /// The α² a mean normal of length `meanLength` adds: twice Toksvig's
    /// slope variance (1 - |n̄|) / |n̄| (1 when the normals cancel out).
    public static func toksvigVariance(meanLength l: Float) -> Float {
        guard l > 1e-6 else { return 1 }
        return min(2 * max(0, 1 - min(l, 1)) / l, 1)
    }
}
