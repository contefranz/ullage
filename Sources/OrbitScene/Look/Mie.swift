import Foundation

/// Light scattered by a homogeneous sphere (Mie): the efficiencies and the
/// asymmetry parameter, as Bohren and Huffman's BHMIE (Absorption and
/// Scattering of Light by Small Particles, 1983, Appendix A) computes them.
/// For the plumes' condensates: the ice an expanding exhaust freezes into.
public enum Mie {
    /// A complex number, for the series.
    struct C {
        var re: Double, im: Double
        init(_ re: Double, _ im: Double = 0) {
            self.re = re
            self.im = im
        }
        static func + (a: C, b: C) -> C { C(a.re + b.re, a.im + b.im) }
        static func - (a: C, b: C) -> C { C(a.re - b.re, a.im - b.im) }
        static func * (a: C, b: C) -> C { C(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re) }
        static func * (a: C, k: Double) -> C { C(a.re * k, a.im * k) }
        static func / (a: C, b: C) -> C {
            let d = b.re * b.re + b.im * b.im
            return C((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d)
        }
        var conj: C { C(re, -im) }
        var abs2: Double { re * re + im * im }
    }

    /// Extinction and scattering efficiencies (over the geometric cross
    /// section) and g, for size parameter `x` = 2πr/λ and relative
    /// refractive index `n` + i`k`.
    public static func efficiencies(sizeParameter x: Double, index n: Double, absorption k: Double = 0)
        -> (extinction: Double, scattering: Double, asymmetry: Double) {
        let m = C(n, k), y = m * x
        let stop = x + 4 * pow(x, 1.0 / 3) + 2
        let nStop = Int(stop.rounded())
        let nMax = Int(max(stop, (y.abs2).squareRoot()).rounded()) + 15
        // The logarithmic derivative D_n(mx), downwards.
        var d = [C](repeating: C(0), count: nMax + 1)
        for n in stride(from: nMax, to: 1, by: -1) {
            let en = C(Double(n)) / y
            d[n - 1] = en - C(1) / (d[n] + en)
        }
        var psi0 = cos(x), psi1 = sin(x), chi0 = -sin(x), chi1 = cos(x)
        var xi1 = C(psi1, -chi1)
        var qsca = 0.0, qext = 0.0, g = 0.0
        var an1 = C(0), bn1 = C(0)
        for n in 1...max(nStop, 1) {
            let dn = Double(n)
            let psi = (2 * dn - 1) * psi1 / x - psi0
            let chi = (2 * dn - 1) * chi1 / x - chi0
            let xi = C(psi, -chi)
            let a1 = d[n] / m + C(dn / x), b1 = m * d[n] + C(dn / x)
            let an = (a1 * psi - C(psi1)) / (a1 * xi - xi1)
            let bn = (b1 * psi - C(psi1)) / (b1 * xi - xi1)
            qsca += (2 * dn + 1) * (an.abs2 + bn.abs2)
            qext += (2 * dn + 1) * (an.re + bn.re)
            g += (2 * dn + 1) / (dn * (dn + 1)) * (an * bn.conj).re
            if n > 1 {
                g += (dn - 1) * (dn + 1) / dn * (an1 * an.conj + bn1 * bn.conj).re
            }
            psi0 = psi1
            psi1 = psi
            chi0 = chi1
            chi1 = chi
            xi1 = C(psi1, -chi1)
            an1 = an
            bn1 = bn
        }
        let asymmetry = 2 * g / qsca
        return (2 / (x * x) * qext, 2 / (x * x) * qsca, asymmetry)
    }
}
