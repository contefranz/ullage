import Foundation

// Track C2: the clouds' procedural detail, after Schneider and Vos 2015
// ("The Real-time Volumetric Cloudscapes of Horizon Zero Dawn") in our own
// code: tileable Perlin gradient noise, Worley cellular noise, their
// Perlin-Worley blend, and 2D curl noise. These are the reference the GPU
// generates its volumes from at launch (CloudShaders' `cloud_noise*`
// kernels mirror them line for line, in Float), so that the render tests can
// check the volumes texel by texel and the Linux tests can check the maths:
// tiling, range, Worley against a brute-force search, curl free of
// divergence.
//
// Every function here works in lattice units (one cell per unit) and tiles
// with an integer period, so a volume of N texels over one period repeats
// seamlessly; the renderer anchors the volumes to the body-fixed frame with
// a noise origin computed in Double (`CloudFrame`).

/// The clouds' noise functions and the volumes made of them.
public enum CloudNoise {
    // MARK: Hash

    /// PCG3D (Jarzynski and Olano 2020, "Hash Functions for GPU
    /// Rendering", JCGT 9(3)): three 32-bit lanes from three, wrapping, as
    /// MSL's uint arithmetic.
    public static func pcg3d(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> (UInt32, UInt32, UInt32) {
        var a = x &* 1_664_525 &+ 1_013_904_223
        var b = y &* 1_664_525 &+ 1_013_904_223
        var c = z &* 1_664_525 &+ 1_013_904_223
        a = a &+ b &* c
        b = b &+ c &* a
        c = c &+ a &* b
        a ^= a >> 16
        b ^= b >> 16
        c ^= c >> 16
        a = a &+ b &* c
        b = b &+ c &* a
        c = c &+ a &* b
        return (a, b, c)
    }

    /// The lattice point (i, j, k) wrapped into one period and hashed with a
    /// seed: what makes every function here tile.
    static func cellHash(_ i: Int32, _ j: Int32, _ k: Int32, period: Int32, seed: UInt32) -> (UInt32, UInt32, UInt32) {
        func wrap(_ v: Int32) -> UInt32 {
            let m = v % period
            return UInt32(bitPattern: m < 0 ? m + period : m)
        }
        return pcg3d(wrap(i) &+ seed, wrap(j) &+ seed &* 3, wrap(k) &+ seed &* 7)
    }

    /// A hash lane as a number in [0, 1).
    static func unit(_ h: UInt32) -> Float { Float(h >> 8) * (1 / 16_777_216) }

    // MARK: Perlin

    /// Perlin's twelve edge gradients (Perlin 2002, "Improving Noise").
    static func gradientDot(_ h: UInt32, _ x: Float, _ y: Float, _ z: Float) -> Float {
        switch h % 12 {
        case 0: return x + y
        case 1: return -x + y
        case 2: return x - y
        case 3: return -x - y
        case 4: return x + z
        case 5: return -x + z
        case 6: return x - z
        case 7: return -x - z
        case 8: return y + z
        case 9: return -y + z
        case 10: return y - z
        default: return -y - z
        }
    }

    /// Perlin's quintic fade, 6t⁵ − 15t⁴ + 10t³.
    static func fade(_ t: Float) -> Float { t * t * t * (t * (t * 6 - 15) + 10) }

    static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + t * (b - a) }

    /// Gradient noise at (x, y, z) in cells, tiling every `period` cells;
    /// within about ±1 (0 at every lattice point).
    public static func perlin(_ x: Float, _ y: Float, _ z: Float, period: Int32, seed: UInt32) -> Float {
        let fx = x.rounded(.down), fy = y.rounded(.down), fz = z.rounded(.down)
        let i = Int32(fx), j = Int32(fy), k = Int32(fz)
        let u = x - fx, v = y - fy, w = z - fz
        func corner(_ a: Int32, _ b: Int32, _ c: Int32) -> Float {
            let h = cellHash(i + a, j + b, k + c, period: period, seed: seed).0
            return gradientDot(h, u - Float(a), v - Float(b), w - Float(c))
        }
        let su = fade(u), sv = fade(v), sw = fade(w)
        let x00 = lerp(corner(0, 0, 0), corner(1, 0, 0), su), x10 = lerp(corner(0, 1, 0), corner(1, 1, 0), su)
        let x01 = lerp(corner(0, 0, 1), corner(1, 0, 1), su), x11 = lerp(corner(0, 1, 1), corner(1, 1, 1), su)
        return lerp(lerp(x00, x10, sv), lerp(x01, x11, sv), sw)
    }

    /// `octaves` of Perlin noise at (x, y, z) in units of one base period,
    /// the base `basePeriod` cells across and each octave twice the last's
    /// frequency at half its amplitude, mapped to [0, 1].
    public static func perlinFBM(_ x: Float, _ y: Float, _ z: Float, basePeriod: Int32, octaves: Int,
                                 seed: UInt32) -> Float {
        var sum: Float = 0, amplitude: Float = 1, total: Float = 0
        var period = basePeriod
        for o in 0..<octaves {
            let s = Float(period)
            sum += amplitude * perlin(x * s, y * s, z * s, period: period, seed: seed &+ UInt32(o))
            total += amplitude
            amplitude *= 0.5
            period *= 2
        }
        return min(max(0.5 + 0.5 * sum / total, 0), 1)
    }

    // MARK: Worley

    /// Distance to the nearest feature point (one per cell, `cells` cells
    /// across one unit, tiling every unit), as 1 − F1 clamped to [0, 1]: 1
    /// at a feature point, falling to 0 a cell away (Worley 1996).
    public static func worley(_ x: Float, _ y: Float, _ z: Float, cells: Int32, seed: UInt32) -> Float {
        let n = Float(cells)
        let px = x * n, py = y * n, pz = z * n
        let fx = px.rounded(.down), fy = py.rounded(.down), fz = pz.rounded(.down)
        let i = Int32(fx), j = Int32(fy), k = Int32(fz)
        var best: Float = 9
        for c in -1...1 {
            for b in -1...1 {
                for a in -1...1 {
                    let h = cellHash(i + Int32(a), j + Int32(b), k + Int32(c), period: cells, seed: seed)
                    let dx = fx + Float(a) + unit(h.0) - px
                    let dy = fy + Float(b) + unit(h.1) - py
                    let dz = fz + Float(c) + unit(h.2) - pz
                    best = min(best, dx * dx + dy * dy + dz * dz)
                }
            }
        }
        return min(max(1 - best.squareRoot(), 0), 1)
    }

    /// Three octaves of Worley noise (`cells`, twice and four times as many),
    /// weighted 0.625, 0.25 and 0.125 (Schneider and Vos 2015).
    public static func worleyFBM(_ x: Float, _ y: Float, _ z: Float, cells: Int32, seed: UInt32) -> Float {
        0.625 * worley(x, y, z, cells: cells, seed: seed)
            + 0.25 * worley(x, y, z, cells: cells * 2, seed: seed &+ 1)
            + 0.125 * worley(x, y, z, cells: cells * 4, seed: seed &+ 2)
    }

    /// Perlin noise dilated by Worley cells, remap(p, −w, 1, 0, 1): billows
    /// at the cells' centres (where w is 1 it is (p + 1)/2) and Perlin's
    /// wisps between them (where w is 0 it is p). In [0, 1].
    public static func perlinWorley(perlin p: Float, worley w: Float) -> Float {
        min(max((p + w) / (1 + w), 0), 1)
    }

    // MARK: The volumes

    /// The shape volume's side in texels, and the cells of its octaves.
    public static let shapeSize = 128
    /// The detail volume's side.
    public static let detailSize = 32
    /// The curl map's side.
    public static let curlSize = 128

    static let shapePerlinPeriod: Int32 = 4, shapePerlinOctaves = 5
    static let shapeWorleyCells: [Int32] = [4, 8, 16]
    static let detailWorleyCells: [Int32] = [4, 8, 16]
    static let curlPeriod: Int32 = 4, curlOctaves = 4
    static let shapeSeed: UInt32 = 0x0C2, detailSeed: UInt32 = 0x1C2, curlSeed: UInt32 = 0x2C2

    /// Texel (x, y, z) of the 128³ shape volume, RGBA: r Perlin-Worley (a
    /// 5-octave Perlin fBm from 4 cells dilated by the 4-cell Worley fBm),
    /// g, b and a the Worley fBm from 4, 8 and 16 cells. Texel centres sit
    /// at (i + 0.5)/N of the period.
    public static func shapeTexel(_ x: Int, _ y: Int, _ z: Int) -> (Float, Float, Float, Float) {
        let s = 1 / Float(shapeSize)
        let u = (Float(x) + 0.5) * s, v = (Float(y) + 0.5) * s, w = (Float(z) + 0.5) * s
        let p = perlinFBM(u, v, w, basePeriod: shapePerlinPeriod, octaves: shapePerlinOctaves, seed: shapeSeed)
        let w0 = worleyFBM(u, v, w, cells: shapeWorleyCells[0], seed: shapeSeed &+ 16)
        let w1 = worleyFBM(u, v, w, cells: shapeWorleyCells[1], seed: shapeSeed &+ 32)
        let w2 = worleyFBM(u, v, w, cells: shapeWorleyCells[2], seed: shapeSeed &+ 48)
        return (perlinWorley(perlin: p, worley: w0), w0, w1, w2)
    }

    /// Texel (x, y, z) of the 32³ detail volume, RGB: the Worley fBm from 4,
    /// 8 and 16 cells.
    public static func detailTexel(_ x: Int, _ y: Int, _ z: Int) -> (Float, Float, Float) {
        let s = 1 / Float(detailSize)
        let u = (Float(x) + 0.5) * s, v = (Float(y) + 0.5) * s, w = (Float(z) + 0.5) * s
        return (worleyFBM(u, v, w, cells: detailWorleyCells[0], seed: detailSeed),
                worleyFBM(u, v, w, cells: detailWorleyCells[1], seed: detailSeed &+ 16),
                worleyFBM(u, v, w, cells: detailWorleyCells[2], seed: detailSeed &+ 32))
    }

    /// The stream function of the curl map: a 4-octave Perlin fBm in the
    /// plane, tiling every unit, centred on 0.
    public static func streamFunction(_ u: Float, _ v: Float) -> Float {
        perlinFBM(u, v, 0, basePeriod: curlPeriod, octaves: curlOctaves, seed: curlSeed) - 0.5
    }

    /// The curl map's scale: its components are the stream function's
    /// gradient times this, so that they lie within ±1.
    static let curlScale: Float = 0.08

    /// Texel (x, y) of the 128² curl map, RG in [−1, 1]: the curl of the
    /// stream function ψ, (∂ψ/∂v, −∂ψ/∂u), by central differences of half a
    /// texel, which is free of divergence.
    public static func curlTexel(_ x: Int, _ y: Int) -> (Float, Float) {
        let s = 1 / Float(curlSize), h = 0.5 * s
        let u = (Float(x) + 0.5) * s, v = (Float(y) + 0.5) * s
        let dv = (streamFunction(u, v + h) - streamFunction(u, v - h)) / (2 * h)
        let du = (streamFunction(u + h, v) - streamFunction(u - h, v)) / (2 * h)
        return (min(max(dv * curlScale, -1), 1), min(max(-du * curlScale, -1), 1))
    }

    /// A unit value as the GPU's unorm8 texel stores it.
    public static func unorm8(_ v: Float) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
    /// A signed value in [−1, 1] as the GPU's snorm8 texel stores it.
    public static func snorm8(_ v: Float) -> Int8 { Int8((min(max(v, -1), 1) * 127).rounded()) }
}
