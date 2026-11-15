import Foundation

/// The volume noise's texels (P3's VolumeNoise, 128³ RG8): tileable
/// gradient noise in three octaves of 16, 8 and 4 texels a cell, two
/// decorrelated channels, from a fixed seed, so it is procedural and the
/// same everywhere. ParticleShaders' particle_noiseValue computes the same
/// in Float; the self-test compares texels.
public enum VolumeNoiseField {
    public static let size = 128

    static let gradients: [(Double, Double, Double)] = [
        (1, 1, 0), (-1, 1, 0), (1, -1, 0), (-1, -1, 0), (1, 0, 1), (-1, 0, 1), (1, 0, -1), (-1, 0, -1),
        (0, 1, 1), (0, -1, 1), (0, 1, -1), (0, -1, -1),
    ]

    /// Perlin's improved gradient noise at `p` (cells), periodic over
    /// `period` cells.
    static func gradientNoise(_ p: (Double, Double, Double), period: Int, seed: UInt32) -> Double {
        let i = (Int(p.0.rounded(.down)), Int(p.1.rounded(.down)), Int(p.2.rounded(.down)))
        let f = (p.0 - Double(i.0), p.1 - Double(i.1), p.2 - Double(i.2))
        func fade(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }
        let u = (fade(f.0), fade(f.1), fade(f.2))
        var v = [Double](repeating: 0, count: 8)
        for k in 0..<8 {
            let o = (k & 1, (k >> 1) & 1, (k >> 2) & 1)
            func wrap(_ x: Int) -> Int { ((x % period) + period) % period }
            let c = (wrap(i.0 + o.0), wrap(i.1 + o.1), wrap(i.2 + o.2))
            let h = ParticleRandom.pcg(UInt32(c.0 + period * (c.1 + period * c.2)) ^ seed)
            let g = gradients[Int(h % 12)]
            v[k] = g.0 * (f.0 - Double(o.0)) + g.1 * (f.1 - Double(o.1)) + g.2 * (f.2 - Double(o.2))
        }
        func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        let x00 = mix(v[0], v[1], u.0), x10 = mix(v[2], v[3], u.0), x01 = mix(v[4], v[5], u.0), x11 = mix(v[6], v[7], u.0)
        return mix(mix(x00, x10, u.1), mix(x01, x11, u.1), u.2)
    }

    /// Texel (x, y, z)'s channel 0 or 1, in 0...1.
    public static func value(_ x: Int, _ y: Int, _ z: Int, channel: Int) -> Double {
        let p = (Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5)
        let seed = 0x2545_F491 &+ UInt32(channel) &* 0x9E37_79B9
        func at(_ cell: Double) -> (Double, Double, Double) { (p.0 / cell, p.1 / cell, p.2 / cell) }
        let n = 0.6 * gradientNoise(at(16), period: 8, seed: seed) + 0.3 * gradientNoise(at(8), period: 16, seed: seed &+ 1)
            + 0.1 * gradientNoise(at(4), period: 32, seed: seed &+ 2)
        return min(max(0.5 + 0.8 * n, 0), 1)
    }
}
