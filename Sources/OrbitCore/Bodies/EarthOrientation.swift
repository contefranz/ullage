// The Earth's orientation in the ICRF: IAU 2006 precession with the frame
// bias, IAU 2000B nutation, the Earth rotation angle and IAU 2006 sidereal
// time.
//
// Transcribed from ERFA, the Essential Routines for Fundamental Astronomy
// (https://github.com/liberfa/erfa, master at commit 1a8044c, its routines
// revised 2021 May 11): pfw06, obl06, fw2m, pmat06, pnm06a (with nut00b in
// place of nut06a), nut00b, ee00 and eect00 with the IERS 2003 fundamental
// arguments (fal03, falp03, faf03, fad03, faom03, fave03, fae03, fapa03),
// era00 and gmst06. The two series were extracted by script from nut00b.c
// (sha256 a5246d525e987eb5...) and eect00.c (sha256 771d6e118a12b8fd...),
// not retyped; EarthOrientationTests checks every routine against ERFA's own
// test values (t_erfa_c.c). ERFA is derived, with permission, from the IAU's
// SOFA library; this code is neither SOFA nor ERFA. ERFA's licence asks that
// its notice be kept with code derived from it:
//
//   Copyright (C) 2013-2021, NumFOCUS Foundation.
//   All rights reserved.
//
//   Redistribution and use in source and binary forms, with or without
//   modification, are permitted provided that the following conditions are
//   met:
//
//   1 Redistributions of source code must retain the above copyright
//     notice, this list of conditions and the following disclaimer.
//
//   2 Redistributions in binary form must reproduce the above copyright
//     notice, this list of conditions and the following disclaimer in the
//     documentation and/or other materials provided with the distribution.
//
//   3 Neither the name of the Standards Of Fundamental Astronomy Board, the
//     International Astronomical Union nor the names of its contributors
//     may be used to endorse or promote products derived from this software
//     without specific prior written permission.
//
//   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
//   IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
//   TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
//   PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
//   HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
//   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
//   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
//   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
//   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
//   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Foundation

/// The Earth's orientation in the ICRF, without polar motion.
///
/// The celestial-to-terrestrial rotation is the classical, equinox-based one
/// of the IERS Conventions (2010, §5.6): R = R3(GAST) · NPB. NPB is the frame
/// bias and IAU 2006 precession, through the Fukushima-Williams angles, with
/// the IAU 2000B nutation (77 luni-solar terms and a fixed offset for the
/// planetary ones; within 1 mas of IAU 2000A from 1995 to 2050). GAST, the
/// Greenwich apparent sidereal time, is the IAU 2006 GMST (the Earth rotation
/// angle plus the accumulated precession in right ascension) plus the
/// equation of the equinoxes. The terrestrial frame is the CIP's: polar
/// motion, the pole's wander in the crust by a few tenths of an arcsecond
/// (8.5 m at the surface on 16 July 1969), is not modelled.
///
/// Dates are two-part Julian dates, as ERFA takes them: the date is the sum,
/// and a large and a small part keep the precision one Double would lose. TT
/// drives precession and nutation, UT1 the Earth's rotation. Angles in radians.
public enum EarthOrientation {
    /// Arcseconds to radians.
    static let das2r = 4.848136811095359935899141e-6
    /// Arcseconds in a full circle.
    static let turnas = 1_296_000.0
    static let twoPi = 6.283185307179586476925287
    static let j2000 = 2451545.0
    static let daysPerCentury = 36525.0

    /// The Earth's rotation rate in inertial space (rad/s): the Earth rotation
    /// angle's, 2π × 1.00273781191135448 per UT1 day, about the CIP.
    public static let rotationRate = 7.292115146706979e-5

    /// Julian centuries since J2000 of a two-part date.
    static func centuries(_ date: (Double, Double)) -> Double { ((date.0 - j2000) + date.1) / daysPerCentury }

    /// An angle reduced to [0, 2π).
    static func normalized(_ a: Double) -> Double {
        let w = a.truncatingRemainder(dividingBy: twoPi)
        return w < 0 ? w + twoPi : w
    }

    // MARK: Precession (IAU 2006)

    /// Mean obliquity of the ecliptic, IAU 2006 (ERFA obl06).
    public static func meanObliquity(tt: (Double, Double)) -> Double {
        let t = centuries(tt)
        return (84381.406 + (-46.836769 + (-0.0001831 + (0.00200340 + (-0.000000576 + (-0.0000000434) * t)
            * t) * t) * t) * t) * das2r
    }

    /// The Fukushima-Williams angles of the frame bias and IAU 2006
    /// precession (ERFA pfw06): γ̄, φ̄, ψ̄ and the mean obliquity ε_A.
    public static func precessionAngles(tt: (Double, Double)) -> (gamma: Double, phi: Double, psi: Double,
                                                                 epsilon: Double) {
        let t = centuries(tt)
        let gamma = (-0.052928 + (10.556378 + (0.4932044 + (-0.00031238 + (-0.000002788 + (0.0000000260) * t)
            * t) * t) * t) * t) * das2r
        let phi = (84381.412819 + (-46.811016 + (0.0511268 + (0.00053289 + (-0.000000440 + (-0.0000000176) * t)
            * t) * t) * t) * t) * das2r
        let psi = (-0.041775 + (5038.481484 + (1.5584175 + (-0.00018522 + (-0.000026452 + (-0.0000000148) * t)
            * t) * t) * t) * t) * das2r
        return (gamma, phi, psi, meanObliquity(tt: tt))
    }

    /// The rotation matrix of four Fukushima-Williams angles (ERFA fw2m):
    /// R1(-ε) · R3(-ψ) · R1(φ) · R3(γ), passive rotations.
    public static func fukushimaWilliamsMatrix(gamma: Double, phi: Double, psi: Double, epsilon: Double) -> Mat3 {
        Mat3.frameX(-epsilon) * (Mat3.frameZ(-psi) * (Mat3.frameX(phi) * Mat3.frameZ(gamma)))
    }

    /// Frame bias and precession, ICRF -> mean equator and equinox of date
    /// (ERFA pmat06).
    public static func biasPrecessionMatrix(tt: (Double, Double)) -> Mat3 {
        let a = precessionAngles(tt: tt)
        return fukushimaWilliamsMatrix(gamma: a.gamma, phi: a.phi, psi: a.psi, epsilon: a.epsilon)
    }

    // MARK: Nutation (IAU 2000B)

    /// Nutation in longitude and obliquity, IAU 2000B (ERFA nut00b).
    public static func nutation(tt: (Double, Double)) -> (dpsi: Double, deps: Double) {
        let t = centuries(tt)
        // Delaunay arguments, Simon et al. (1994), linear as 2000B takes them.
        let el = (485868.249036 + (1717915923.2178) * t).truncatingRemainder(dividingBy: turnas) * das2r
        let elp = (1287104.79305 + (129596581.0481) * t).truncatingRemainder(dividingBy: turnas) * das2r
        let f = (335779.526232 + (1739527262.8478) * t).truncatingRemainder(dividingBy: turnas) * das2r
        let d = (1072260.70369 + (1602961601.2090) * t).truncatingRemainder(dividingBy: turnas) * das2r
        let om = (450160.398036 + (-6962890.5431) * t).truncatingRemainder(dividingBy: turnas) * das2r
        var dp = 0.0, de = 0.0
        // Smallest terms first, as ERFA sums them.
        for n in nutationTerms.reversed() {
            let arg = (n.l * el + n.lp * elp + n.f * f + n.d * d + n.om * om).truncatingRemainder(dividingBy: twoPi)
            let s = sin(arg), c = cos(arg)
            dp += (n.ps + n.pst * t) * s + n.pc * c
            de += (n.ec + n.ect * t) * c + n.es * s
        }
        // 0.1 µas to radians; fixed offsets in lieu of the planetary terms.
        let u2r = das2r / 1e7
        return (dp * u2r + -0.135 * (das2r / 1e3), de * u2r + 0.388 * (das2r / 1e3))
    }

    /// Frame bias, precession and nutation, ICRF -> true equator and equinox
    /// of date (ERFA pnm06a, with the IAU 2000B nutation).
    public static func biasPrecessionNutationMatrix(tt: (Double, Double)) -> Mat3 {
        PrecessionNutation(tt: tt).matrix
    }

    // MARK: Sidereal time

    /// The Earth rotation angle (ERFA era00), from UT1.
    public static func earthRotationAngle(ut1: (Double, Double)) -> Double {
        let (d1, d2) = ut1.0 < ut1.1 ? (ut1.0, ut1.1) : (ut1.1, ut1.0)
        let t = d1 + (d2 - j2000)
        let f = d1.truncatingRemainder(dividingBy: 1) + d2.truncatingRemainder(dividingBy: 1)
        return normalized(twoPi * (f + 0.7790572732640 + 0.00273781191135448 * t))
    }

    /// Greenwich mean sidereal time, IAU 2006 (ERFA gmst06): the Earth
    /// rotation angle plus the precession in right ascension.
    public static func gmst(ut1: (Double, Double), tt: (Double, Double)) -> Double {
        let t = centuries(tt)
        return normalized(earthRotationAngle(ut1: ut1)
            + (0.014506 + (4612.156534 + (1.3915817 + (-0.00000044 + (-0.000029956 + (-0.0000000368) * t)
                * t) * t) * t) * t) * das2r)
    }

    /// The equation of the equinoxes' complementary terms, IAU 2000 (ERFA
    /// eect00).
    public static func equationOfEquinoxesComplementaryTerms(tt: (Double, Double)) -> Double {
        let t = centuries(tt)
        // IERS 2003 fundamental arguments: l, l', F, D, Ω, L_Ve, L_E, p_A.
        let fa = [
            (485868.249036 + t * (1717915923.2178 + t * (31.8792 + t * (0.051635 + t * (-0.00024470)))))
                .truncatingRemainder(dividingBy: turnas) * das2r,
            (1287104.793048 + t * (129596581.0481 + t * (-0.5532 + t * (0.000136 + t * (-0.00001149)))))
                .truncatingRemainder(dividingBy: turnas) * das2r,
            (335779.526232 + t * (1739527262.8478 + t * (-12.7512 + t * (-0.001037 + t * (0.00000417)))))
                .truncatingRemainder(dividingBy: turnas) * das2r,
            (1072260.703692 + t * (1602961601.2090 + t * (-6.3706 + t * (0.006593 + t * (-0.00003169)))))
                .truncatingRemainder(dividingBy: turnas) * das2r,
            (450160.398036 + t * (-6962890.5431 + t * (7.4722 + t * (0.007702 + t * (-0.00005939)))))
                .truncatingRemainder(dividingBy: turnas) * das2r,
            (3.176146697 + 1021.3285546211 * t).truncatingRemainder(dividingBy: twoPi),
            (1.753470314 + 628.3075849991 * t).truncatingRemainder(dividingBy: twoPi),
            (0.024381750 + 0.00000538691 * t) * t,
        ]
        var s0 = 0.0
        for e in equinoxTerms.reversed() {
            var a = 0.0
            for j in 0..<8 { a += e.n[j] * fa[j] }
            s0 += e.s * sin(a) + e.c * cos(a)
        }
        // The one term of order t: -0.87 µas sin Ω.
        let s1 = -0.87e-6 * sin(fa[4]) + 0.00e-6 * cos(fa[4])
        return (s0 + s1 * t) * das2r
    }

    /// The equation of the equinoxes, IAU 2000 with the 2000B nutation and the
    /// IAU 2006 obliquity (ERFA ee00): Δψ cos ε_A plus the complementary terms.
    public static func equationOfEquinoxes(tt: (Double, Double)) -> Double {
        PrecessionNutation(tt: tt).equationOfEquinoxes
    }

    /// Greenwich apparent sidereal time: GMST (IAU 2006) plus the equation of
    /// the equinoxes.
    public static func gast(ut1: (Double, Double), tt: (Double, Double)) -> Double {
        normalized(gmst(ut1: ut1, tt: tt) + equationOfEquinoxes(tt: tt))
    }

    /// ICRF -> terrestrial (no polar motion): R3(GAST) · NPB (ERFA c2teqx
    /// with the identity for the polar motion matrix).
    public static func celestialToTerrestrial(ut1: (Double, Double), tt: (Double, Double)) -> Mat3 {
        PrecessionNutation(tt: tt).celestialToTerrestrial(ut1: ut1, tt: tt)
    }

    // MARK: The slowly varying part

    /// Bias, precession and nutation at a TT date: the matrix NPB and the
    /// equation of the equinoxes. They change by milliarcseconds an hour, so
    /// the simulation evaluates them every `PrecessionNutation.Cache.interval`
    /// and interpolates.
    struct PrecessionNutation {
        var matrix: Mat3
        var equationOfEquinoxes: Double

        init(matrix: Mat3, equationOfEquinoxes: Double) {
            self.matrix = matrix; self.equationOfEquinoxes = equationOfEquinoxes
        }

        init(tt: (Double, Double)) {
            let a = precessionAngles(tt: tt), n = nutation(tt: tt)
            matrix = fukushimaWilliamsMatrix(gamma: a.gamma, phi: a.phi, psi: a.psi + n.dpsi,
                                             epsilon: a.epsilon + n.deps)
            equationOfEquinoxes = n.dpsi * cos(a.epsilon) + equationOfEquinoxesComplementaryTerms(tt: tt)
        }

        /// R3(GAST) · NPB.
        func celestialToTerrestrial(ut1: (Double, Double), tt: (Double, Double)) -> Mat3 {
            Mat3.frameZ(normalized(gmst(ut1: ut1, tt: tt) + equationOfEquinoxes)) * matrix
        }

        /// NPB and the equation of the equinoxes evaluated every `interval` s
        /// of TT from J2000 and interpolated linearly, element by element,
        /// between: within 1 µas of the series (the 13.7-day nutation
        /// curves the most), and orthogonal to 1e-17. It keeps the last
        /// interval it evaluated.
        final class Cache {
            static let interval = 600.0
            private var node = Double.nan
            private var lower = PrecessionNutation(matrix: .identity, equationOfEquinoxes: 0)
            private var upper = PrecessionNutation(matrix: .identity, equationOfEquinoxes: 0)

            /// The terms at `tt` seconds of TT past J2000.
            func terms(ttSecondsPastJ2000 s: Double) -> PrecessionNutation {
                let k = (s / Self.interval).rounded(.down)
                if k != node {
                    node = k
                    lower = PrecessionNutation(tt: (j2000, k * Self.interval / 86400))
                    upper = PrecessionNutation(tt: (j2000, (k + 1) * Self.interval / 86400))
                }
                let f = (s - k * Self.interval) / Self.interval
                let a = lower.matrix, b = upper.matrix
                return PrecessionNutation(
                    matrix: Mat3(rows: a.r0 + (b.r0 - a.r0) * f, a.r1 + (b.r1 - a.r1) * f, a.r2 + (b.r2 - a.r2) * f),
                    equationOfEquinoxes: lower.equationOfEquinoxes
                        + (upper.equationOfEquinoxes - lower.equationOfEquinoxes) * f)
            }
        }
    }

    // MARK: Series

    /// A term of the IAU 2000B luni-solar nutation: multipliers of l, l', F, D
    /// and Ω, then, in 0.1 µas, the longitude's sin, t·sin and cos
    /// coefficients and the obliquity's cos, t·cos and sin ones.
    struct NutationTerm {
        let l, lp, f, d, om: Double
        let ps, pst, pc, ec, ect, es: Double
    }

    private static func N(_ l: Double, _ lp: Double, _ f: Double, _ d: Double, _ om: Double,
                          _ ps: Double, _ pst: Double, _ pc: Double,
                          _ ec: Double, _ ect: Double, _ es: Double) -> NutationTerm {
        NutationTerm(l: l, lp: lp, f: f, d: d, om: om, ps: ps, pst: pst, pc: pc, ec: ec, ect: ect, es: es)
    }

    /// ERFA nut00b.c's table, in its order.
    static let nutationTerms: [NutationTerm] = [
        // 1-10
        N( 0,  0,  0,  0,  1, -172064161, -174666, 33386, 92052331, 9086, 15377),
        N( 0,  0,  2, -2,  2, -13170906, -1675, -13696, 5730336, -3015, -4587),
        N( 0,  0,  2,  0,  2, -2276413, -234, 2796, 978459, -485, 1374),
        N( 0,  0,  0,  0,  2, 2074554, 207, -698, -897492, 470, -291),
        N( 0,  1,  0,  0,  0, 1475877, -3633, 11817, 73871, -184, -1924),
        N( 0,  1,  2, -2,  2, -516821, 1226, -524, 224386, -677, -174),
        N( 1,  0,  0,  0,  0, 711159, 73, -872, -6750, 0, 358),
        N( 0,  0,  2,  0,  1, -387298, -367, 380, 200728, 18, 318),
        N( 1,  0,  2,  0,  2, -301461, -36, 816, 129025, -63, 367),
        N( 0, -1,  2, -2,  2, 215829, -494, 111, -95929, 299, 132),
        // 11-20
        N( 0,  0,  2, -2,  1, 128227, 137, 181, -68982, -9, 39),
        N(-1,  0,  2,  0,  2, 123457, 11, 19, -53311, 32, -4),
        N(-1,  0,  0,  2,  0, 156994, 10, -168, -1235, 0, 82),
        N( 1,  0,  0,  0,  1, 63110, 63, 27, -33228, 0, -9),
        N(-1,  0,  0,  0,  1, -57976, -63, -189, 31429, 0, -75),
        N(-1,  0,  2,  2,  2, -59641, -11, 149, 25543, -11, 66),
        N( 1,  0,  2,  0,  1, -51613, -42, 129, 26366, 0, 78),
        N(-2,  0,  2,  0,  1, 45893, 50, 31, -24236, -10, 20),
        N( 0,  0,  0,  2,  0, 63384, 11, -150, -1220, 0, 29),
        N( 0,  0,  2,  2,  2, -38571, -1, 158, 16452, -11, 68),
        // 21-30
        N( 0, -2,  2, -2,  2, 32481, 0, 0, -13870, 0, 0),
        N(-2,  0,  0,  2,  0, -47722, 0, -18, 477, 0, -25),
        N( 2,  0,  2,  0,  2, -31046, -1, 131, 13238, -11, 59),
        N( 1,  0,  2, -2,  2, 28593, 0, -1, -12338, 10, -3),
        N(-1,  0,  2,  0,  1, 20441, 21, 10, -10758, 0, -3),
        N( 2,  0,  0,  0,  0, 29243, 0, -74, -609, 0, 13),
        N( 0,  0,  2,  0,  0, 25887, 0, -66, -550, 0, 11),
        N( 0,  1,  0,  0,  1, -14053, -25, 79, 8551, -2, -45),
        N(-1,  0,  0,  2,  1, 15164, 10, 11, -8001, 0, -1),
        N( 0,  2,  2, -2,  2, -15794, 72, -16, 6850, -42, -5),
        // 31-40
        N( 0,  0, -2,  2,  0, 21783, 0, 13, -167, 0, 13),
        N( 1,  0,  0, -2,  1, -12873, -10, -37, 6953, 0, -14),
        N( 0, -1,  0,  0,  1, -12654, 11, 63, 6415, 0, 26),
        N(-1,  0,  2,  2,  1, -10204, 0, 25, 5222, 0, 15),
        N( 0,  2,  0,  0,  0, 16707, -85, -10, 168, -1, 10),
        N( 1,  0,  2,  2,  2, -7691, 0, 44, 3268, 0, 19),
        N(-2,  0,  2,  0,  0, -11024, 0, -14, 104, 0, 2),
        N( 0,  1,  2,  0,  2, 7566, -21, -11, -3250, 0, -5),
        N( 0,  0,  2,  2,  1, -6637, -11, 25, 3353, 0, 14),
        N( 0, -1,  2,  0,  2, -7141, 21, 8, 3070, 0, 4),
        // 41-50
        N( 0,  0,  0,  2,  1, -6302, -11, 2, 3272, 0, 4),
        N( 1,  0,  2, -2,  1, 5800, 10, 2, -3045, 0, -1),
        N( 2,  0,  2, -2,  2, 6443, 0, -7, -2768, 0, -4),
        N(-2,  0,  0,  2,  1, -5774, -11, -15, 3041, 0, -5),
        N( 2,  0,  2,  0,  1, -5350, 0, 21, 2695, 0, 12),
        N( 0, -1,  2, -2,  1, -4752, -11, -3, 2719, 0, -3),
        N( 0,  0,  0, -2,  1, -4940, -11, -21, 2720, 0, -9),
        N(-1, -1,  0,  2,  0, 7350, 0, -8, -51, 0, 4),
        N( 2,  0,  0, -2,  1, 4065, 0, 6, -2206, 0, 1),
        N( 1,  0,  0,  2,  0, 6579, 0, -24, -199, 0, 2),
        // 51-60
        N( 0,  1,  2, -2,  1, 3579, 0, 5, -1900, 0, 1),
        N( 1, -1,  0,  0,  0, 4725, 0, -6, -41, 0, 3),
        N(-2,  0,  2,  0,  2, -3075, 0, -2, 1313, 0, -1),
        N( 3,  0,  2,  0,  2, -2904, 0, 15, 1233, 0, 7),
        N( 0, -1,  0,  2,  0, 4348, 0, -10, -81, 0, 2),
        N( 1, -1,  2,  0,  2, -2878, 0, 8, 1232, 0, 4),
        N( 0,  0,  0,  1,  0, -4230, 0, 5, -20, 0, -2),
        N(-1, -1,  2,  2,  2, -2819, 0, 7, 1207, 0, 3),
        N(-1,  0,  2,  0,  0, -4056, 0, 5, 40, 0, -2),
        N( 0, -1,  2,  2,  2, -2647, 0, 11, 1129, 0, 5),
        // 61-70
        N(-2,  0,  0,  0,  1, -2294, 0, -10, 1266, 0, -4),
        N( 1,  1,  2,  0,  2, 2481, 0, -7, -1062, 0, -3),
        N( 2,  0,  0,  0,  1, 2179, 0, -2, -1129, 0, -2),
        N(-1,  1,  0,  1,  0, 3276, 0, 1, -9, 0, 0),
        N( 1,  1,  0,  0,  0, -3389, 0, 5, 35, 0, -2),
        N( 1,  0,  2,  0,  0, 3339, 0, -13, -107, 0, 1),
        N(-1,  0,  2, -2,  1, -1987, 0, -6, 1073, 0, -2),
        N( 1,  0,  0,  0,  2, -1981, 0, 0, 854, 0, 0),
        N(-1,  0,  0,  1,  0, 4026, 0, -353, -553, 0, -139),
        N( 0,  0,  2,  1,  2, 1660, 0, -5, -710, 0, -2),
        // 71-77
        N(-1,  0,  2,  4,  2, -1521, 0, 9, 647, 0, 4),
        N(-1,  1,  0,  1,  1, 1314, 0, 0, -700, 0, 0),
        N( 0, -2,  2, -2,  1, -1283, 0, 0, 672, 0, 0),
        N( 1,  0,  2,  2,  1, -1331, 0, 8, 663, 0, 4),
        N(-2,  0,  2,  2,  2, 1383, 0, -2, -594, 0, -2),
        N(-1,  0,  0,  0,  2, 1405, 0, 4, -610, 0, 2),
        N( 1,  1,  2, -2,  2, 1290, 0, 0, -556, 0, 0),
    ]

    /// A term of order t⁰ of the equation of the equinoxes' complementary
    /// terms: multipliers of l, l', F, D, Ω, L_Ve, L_E and p_A, and the sine
    /// and cosine coefficients in arcseconds.
    struct EquinoxTerm {
        let n: [Double]
        let s, c: Double
    }

    private static func E(_ l: Double, _ lp: Double, _ f: Double, _ d: Double, _ om: Double,
                          _ lve: Double, _ le: Double, _ pa: Double, _ s: Double, _ c: Double) -> EquinoxTerm {
        EquinoxTerm(n: [l, lp, f, d, om, lve, le, pa], s: s, c: c)
    }

    /// ERFA eect00.c's e0 table, in its order.
    static let equinoxTerms: [EquinoxTerm] = [
        // 1-10
        E( 0,  0,  0,  0,  1,  0,  0,  0, 2640.96e-6, -0.39e-6),
        E( 0,  0,  0,  0,  2,  0,  0,  0, 63.52e-6, -0.02e-6),
        E( 0,  0,  2, -2,  3,  0,  0,  0, 11.75e-6, 0.01e-6),
        E( 0,  0,  2, -2,  1,  0,  0,  0, 11.21e-6, 0.01e-6),
        E( 0,  0,  2, -2,  2,  0,  0,  0, -4.55e-6, 0.00e-6),
        E( 0,  0,  2,  0,  3,  0,  0,  0, 2.02e-6, 0.00e-6),
        E( 0,  0,  2,  0,  1,  0,  0,  0, 1.98e-6, 0.00e-6),
        E( 0,  0,  0,  0,  3,  0,  0,  0, -1.72e-6, 0.00e-6),
        E( 0,  1,  0,  0,  1,  0,  0,  0, -1.41e-6, -0.01e-6),
        E( 0,  1,  0,  0, -1,  0,  0,  0, -1.26e-6, -0.01e-6),
        // 11-20
        E( 1,  0,  0,  0, -1,  0,  0,  0, -0.63e-6, 0.00e-6),
        E( 1,  0,  0,  0,  1,  0,  0,  0, -0.63e-6, 0.00e-6),
        E( 0,  1,  2, -2,  3,  0,  0,  0, 0.46e-6, 0.00e-6),
        E( 0,  1,  2, -2,  1,  0,  0,  0, 0.45e-6, 0.00e-6),
        E( 0,  0,  4, -4,  4,  0,  0,  0, 0.36e-6, 0.00e-6),
        E( 0,  0,  1, -1,  1, -8, 12,  0, -0.24e-6, -0.12e-6),
        E( 0,  0,  2,  0,  0,  0,  0,  0, 0.32e-6, 0.00e-6),
        E( 0,  0,  2,  0,  2,  0,  0,  0, 0.28e-6, 0.00e-6),
        E( 1,  0,  2,  0,  3,  0,  0,  0, 0.27e-6, 0.00e-6),
        E( 1,  0,  2,  0,  1,  0,  0,  0, 0.26e-6, 0.00e-6),
        // 21-30
        E( 0,  0,  2, -2,  0,  0,  0,  0, -0.21e-6, 0.00e-6),
        E( 0,  1, -2,  2, -3,  0,  0,  0, 0.19e-6, 0.00e-6),
        E( 0,  1, -2,  2, -1,  0,  0,  0, 0.18e-6, 0.00e-6),
        E( 0,  0,  0,  0,  0,  8, -13, -1, -0.10e-6, 0.05e-6),
        E( 0,  0,  0,  2,  0,  0,  0,  0, 0.15e-6, 0.00e-6),
        E( 2,  0, -2,  0, -1,  0,  0,  0, -0.14e-6, 0.00e-6),
        E( 1,  0,  0, -2,  1,  0,  0,  0, 0.14e-6, 0.00e-6),
        E( 0,  1,  2, -2,  2,  0,  0,  0, -0.14e-6, 0.00e-6),
        E( 1,  0,  0, -2, -1,  0,  0,  0, 0.14e-6, 0.00e-6),
        E( 0,  0,  4, -2,  4,  0,  0,  0, 0.13e-6, 0.00e-6),
        // 31-33
        E( 0,  0,  2, -2,  4,  0,  0,  0, -0.11e-6, 0.00e-6),
        E( 1,  0, -2,  0, -3,  0,  0,  0, 0.11e-6, 0.00e-6),
        E( 1,  0, -2,  0, -1,  0,  0,  0, 0.11e-6, 0.00e-6),
    ]
}
