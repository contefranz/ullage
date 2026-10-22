import Foundation

/// The tone curves that take exposed scene light (linear Rec. 709, 1 at the
/// sensor's saturation) to display light (linear Rec. 709 in [0, 1], which
/// the sRGB drawable encodes). Track R1: the GPU samples AgX from a 33³ LUT
/// baked here (`ToneLUT`), so the renderer and the tests share this code;
/// PBR Neutral, a hue-preserving min/max operator that a per-channel LUT
/// follows poorly, is evaluated in the post shader, which the GPU tests
/// check against `neutral` here.
public enum ToneCurve: String, Codable, CaseIterable {
    /// AgX: a film-like roll-off in which fire and the Sun go to white.
    case agx
    /// Khronos PBR Neutral: base colours up to 0.8 come out unchanged.
    case neutral

    public func map(_ c: Photometry.RGB) -> Photometry.RGB {
        switch self {
        case .agx: ToneCurves.agx(c)
        case .neutral: ToneCurves.neutral(c)
        }
    }
}

public enum ToneCurves {
    // MARK: AgX

    // Ported from three.js (src/renderers/shaders/ShaderChunk/
    // tonemapping_pars_fragment.glsl.js, commit 7b690028, 2024-08-09; MIT,
    // Copyright © 2010-2026 three.js authors; see THIRD_PARTY_NOTICES.md),
    // which bases its AgX on Filament's (google/filament#7236, Apache-2.0),
    // itself after Troy Sobotka's AgX for Blender, with the sigmoid fitted
    // by iolite-engine. The matrices are written as three.js's GLSL mat3
    // constructors are, column by column.

    /// Linear Rec. 709 to linear Rec. 2020 (columns; ITU-R BT.2407, rounded as three.js has it).
    static let srgbToRec2020: [[Double]] = [[0.6274, 0.0691, 0.0164], [0.3293, 0.9195, 0.0880],
                                            [0.0433, 0.0113, 0.8956]]
    static let rec2020ToSRGB: [[Double]] = [[1.6605, -0.1246, -0.0182], [-0.5876, 1.1329, -0.1006],
                                            [-0.0728, -0.0083, 1.1187]]
    static let agxInset: [[Double]] = [
        [0.856627153315983, 0.137318972929847, 0.11189821299995],
        [0.0951212405381588, 0.761241990602591, 0.0767994186031903],
        [0.0482516061458583, 0.101439036467562, 0.811302368396859],
    ]
    static let agxOutset: [[Double]] = [
        [1.1271005818144368, -0.1413297634984383, -0.14132976349843826],
        [-0.11060664309660323, 1.157823702216272, -0.11060664309660294],
        [-0.016493938717834573, -0.016493938717834257, 1.2519364065950405],
    ]
    /// log₂(2^-10 · 0.18) and log₂(2^6.5 · 0.18): the log encoding's ends.
    static let agxMinEv = -12.47393
    static let agxMaxEv = 4.026069

    /// GLSL's `mat3(c0, c1, c2) * v`.
    static func mul(_ m: [[Double]], _ v: [Double]) -> [Double] {
        (0..<3).map { i in m[0][i] * v[0] + m[1][i] * v[1] + m[2][i] * v[2] }
    }

    /// AgX's sigmoid, a 6th-order polynomial on the log-encoded value.
    static func agxContrast(_ x: Double) -> Double {
        let x2 = x * x, x4 = x2 * x2
        return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232
    }

    /// AgX (three.js's, with no look), exposure 1.
    public static func agx(_ c: Photometry.RGB) -> Photometry.RGB {
        var v = mul(srgbToRec2020, [c.r, c.g, c.b])
        v = mul(agxInset, v)
        v = v.map { x in
            let e = (log2(max(x, 1e-10)) - agxMinEv) / (agxMaxEv - agxMinEv)
            return agxContrast(min(max(e, 0), 1))
        }
        v = mul(agxOutset, v)
        v = v.map { pow(max(0, $0), 2.2) }
        v = mul(rec2020ToSRGB, v).map { min(max($0, 0), 1) }
        return Photometry.RGB(v[0], v[1], v[2])
    }

    // MARK: PBR Neutral

    // Khronos PBR Neutral (KhronosGroup/ToneMapping, PBR_Neutral/README.md),
    // implemented from its specification; the repository is Apache-2.0.

    static let neutralF90 = 0.04
    static let neutralStart = 0.8 - neutralF90
    static let neutralDesaturation = 0.15

    public static func neutral(_ c: Photometry.RGB) -> Photometry.RGB {
        let x = min(c.r, c.g, c.b)
        let offset = x < 2 * neutralF90 ? x - x * x / (4 * neutralF90) : neutralF90
        var o = Photometry.RGB(c.r - offset, c.g - offset, c.b - offset)
        let peak = max(o.r, o.g, o.b)
        guard peak >= neutralStart else { return o }
        let d = 1 - neutralStart
        let newPeak = 1 - d * d / (peak + d - neutralStart)
        o = o.scaled(by: newPeak / peak)
        let g = 1 - 1 / (neutralDesaturation * (peak - newPeak) + 1)
        return Photometry.RGB(o.r + (newPeak - o.r) * g, o.g + (newPeak - o.g) * g, o.b + (newPeak - o.b) * g)
    }

    /// PBR Neutral's analytic inverse (as the specification's lut-writer has it).
    public static func neutralInverse(_ c: Photometry.RGB) -> Photometry.RGB {
        var o = c
        let peak = max(c.r, c.g, c.b)
        if peak > neutralStart {
            let d = 1 - neutralStart
            let oldPeak = d * d / (1 - peak) - d + neutralStart
            let fInv = neutralDesaturation * (oldPeak - peak) + 1
            let f = 1 / fInv
            o = Photometry.RGB((o.r + (f - 1) * peak) * fInv, (o.g + (f - 1) * peak) * fInv, (o.b + (f - 1) * peak) * fInv)
            o = o.scaled(by: oldPeak / peak)
        }
        let y = min(o.r, o.g, o.b)
        var offset = neutralF90
        if y < neutralF90 {
            let x = (y / 6.25).squareRoot()
            offset = x - 6.25 * x * x
        }
        return Photometry.RGB(o.r + offset, o.g + offset, o.b + offset)
    }
}

/// The tone curve baked into a 3D LUT over log₂ of each input channel,
/// which the post shader samples trilinearly (Binding.toneLUT).
public struct ToneLUT {
    /// Points per axis.
    public static let size = 33
    /// The log₂ input range: 2^-12 to 2^7. Darker channels read as the first
    /// point, brighter ones as the last. AgX is black below about 2^-12.5,
    /// and grey is white above about 2^4; but its inset matrix leaks a bright
    /// channel into the others, so a saturated colour (a heat shield's red
    /// glow) keeps whitening until its channels reach about 2^7.
    public static let minLog2 = -12.0
    public static let maxLog2 = 7.0

    public let curve: ToneCurve
    /// RGBA, red fastest, then green, then blue.
    public let texels: [Float]

    public init(_ curve: ToneCurve) {
        self.curve = curve
        let n = Self.size
        var t = [Float](repeating: 0, count: n * n * n * 4)
        let values = (0..<n).map { Self.input($0) }
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let o = curve.map(Photometry.RGB(values[r], values[g], values[b]))
                    let i = 4 * (r + n * (g + n * b))
                    t[i] = Float(o.r)
                    t[i + 1] = Float(o.g)
                    t[i + 2] = Float(o.b)
                    t[i + 3] = 1
                }
            }
        }
        texels = t
    }

    /// The input value of grid point `i`.
    public static func input(_ i: Int) -> Double {
        pow(2, minLog2 + Double(i) / Double(size - 1) * (maxLog2 - minLog2))
    }

    /// The LUT's output for `c`, interpolated trilinearly as the GPU does it.
    public func sample(_ c: Photometry.RGB) -> Photometry.RGB {
        let n = Self.size
        func coordinate(_ x: Double) -> (Int, Double) {
            let u = (log2(max(x, 1e-30)) - Self.minLog2) / (Self.maxLog2 - Self.minLog2) * Double(n - 1)
            let clamped = min(max(u, 0), Double(n - 1))
            let i = min(Int(clamped), n - 2)
            return (i, clamped - Double(i))
        }
        let (ri, rt) = coordinate(c.r), (gi, gt) = coordinate(c.g), (bi, bt) = coordinate(c.b)
        var out = [0.0, 0.0, 0.0]
        for db in 0...1 {
            for dg in 0...1 {
                for dr in 0...1 {
                    let w = (dr == 1 ? rt : 1 - rt) * (dg == 1 ? gt : 1 - gt) * (db == 1 ? bt : 1 - bt)
                    let i = 4 * ((ri + dr) + n * ((gi + dg) + n * (bi + db)))
                    for k in 0..<3 { out[k] += w * Double(texels[i + k]) }
                }
            }
        }
        return Photometry.RGB(out[0], out[1], out[2])
    }
}
