import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// SH9 (track R3) against analytic environments: a constant one, the
/// linear and quadratic ones SH9 holds exactly, the uniform sky over a black
/// ground (exact as well: its l = 2 term vanishes), the clamped cosine lobe
/// against brute force (Ramamoorthi and Hanrahan's few per cent), the Earth
/// below at 185 km against Howell's sphere factor, and Henyey-Greenstein
/// in-scattering against direct quadrature.
final class SphericalHarmonicsTests: XCTestCase {
    /// Directions over the sphere, the poles and the axes among them.
    static let directions: [Vec3] = {
        var d: [Vec3] = [.unitX, -.unitX, .unitY, -.unitY, .unitZ, -.unitZ]
        for i in 0..<40 {
            // A Fibonacci spiral.
            let z = 1 - 2 * (Double(i) + 0.5) / 40, r = (1 - z * z).squareRoot()
            let phi = Double(i) * 2.399_963_229_728_653
            d.append(Vec3(r * cos(phi), r * sin(phi), z))
        }
        return d
    }()

    static func grey(_ v: Double) -> Spectrum3 { Spectrum3(repeating: v) }

    func testBasisIsOrthonormal() {
        let texels = EnvironmentProbe.texels(size: 48)
        var gram = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 9)
        for t in texels {
            let y = SH9.basis(t.direction)
            for i in 0..<9 { for j in 0..<9 { gram[i][j] += y[i] * y[j] * t.solidAngle } }
        }
        for i in 0..<9 {
            for j in 0..<9 { XCTAssertEqual(gram[i][j], i == j ? 1 : 0, accuracy: 2e-3, "⟨Y\(i), Y\(j)⟩") }
        }
    }

    func testConstantEnvironment() {
        let sh = SH9.project(size: 16) { _ in Spectrum3(2, 3, 5) }
        for n in Self.directions {
            let e = sh.irradianceOverPi(n)
            XCTAssertEqual(e.r, 2, accuracy: 1e-9)
            XCTAssertEqual(e.g, 3, accuracy: 1e-9)
            XCTAssertEqual(e.b, 5, accuracy: 1e-9)
            XCTAssertEqual(sh.inScatter(view: n, asymmetry: 0.7).g, 3, accuracy: 1e-9)
        }
        XCTAssertEqual(sh.meanRadiance.b, 5, accuracy: 1e-9)
    }

    /// L = 1 + ω·z: E/π = 1 + (2/3) n·z. L = (ω·z)²: E/π = 1/3 + P₂(n·z)/6.
    func testLinearAndQuadraticAreExact() {
        let linear = SH9.project(size: 64) { Self.grey(1 + $0.z) }
        let quadratic = SH9.project(size: 64) { Self.grey($0.z * $0.z) }
        for n in Self.directions {
            XCTAssertEqual(linear.irradianceOverPi(n).g, 1 + 2.0 / 3.0 * n.z, accuracy: 2e-4)
            let p2 = (3 * n.z * n.z - 1) / 2
            XCTAssertEqual(quadratic.irradianceOverPi(n).g, 1.0 / 3.0 + p2 / 6, accuracy: 2e-4)
            // HG in-scattering of the linear sky: 1 + g (v·z).
            XCTAssertEqual(linear.inScatter(view: n, asymmetry: 0.6).g, 1 + 0.6 * n.z, accuracy: 2e-4)
        }
    }

    /// A uniform sky of radiance L over a black ground: E/π = L (1 + cos β)/2
    /// on a surface tilted β from the zenith, which nine coefficients hold.
    func testUniformSkyOverBlackGround() {
        let sh = SH9.project(size: 64) { Self.grey($0.z > 0 ? 4_000 : 0) }
        for n in Self.directions {
            XCTAssertEqual(sh.irradianceOverPi(n).g, 4_000 * (1 + n.z) / 2, accuracy: 2)
        }
    }

    /// The clamped cosine lobe L = max(0, ω·z): SH9's irradiance within 3 %
    /// of its peak of brute force everywhere (Ramamoorthi and Hanrahan:
    /// about 1 % on average, a few per cent at worst).
    func testCosineLobeAgainstBruteForce() {
        let cube = EnvironmentProbe.CubeMap(size: 32) { Self.grey(max($0.z, 0)) }
        let sh = SH9.project(cube.samples)
        let peak = EnvironmentProbe.irradianceReference(cube, n: .unitZ).g
        XCTAssertEqual(peak, 2.0 / 3.0, accuracy: 2e-3)
        for n in Self.directions {
            let exact = EnvironmentProbe.irradianceReference(cube, n: n).g
            XCTAssertEqual(sh.irradianceOverPi(n).g, exact, accuracy: 0.03 * peak, "n \(n)")
        }
    }

    /// The Earth as a uniform disc from 185 km (sin²σ = (R/r)²): E/π at the
    /// nadir is L sin²σ (Howell's factor, the sphere fully seen); tilted, the
    /// horizon-clipped factor (`BRDF.sphereIrradiance`). Within 3 % of the
    /// nadir value.
    func testEarthBelowAgainstHowell() {
        let s2 = LookDevScenes.earthSinSigma2, cosSigma = (1 - s2).squareRoot()
        let sh = SH9.project(size: 64) { Self.grey(-$0.z >= cosSigma ? 1_000 : 0) }
        let nadir = 1_000 * s2
        XCTAssertEqual(sh.irradianceOverPi(-.unitZ).g, nadir, accuracy: 0.03 * nadir)
        for n in Self.directions {
            let exact = 1_000 * BRDF.sphereIrradiance(cosTheta: -n.z, sinSigma2: s2) / Double.pi
            XCTAssertEqual(sh.irradianceOverPi(n).g, exact, accuracy: 0.03 * nadir, "n \(n)")
        }
    }

    /// ∫ L(ω) p(ω·v) dω by quadrature, Henyey-Greenstein's p, against
    /// Σ g^l L_lm Y_lm(v) for a smooth sky (exact to second order).
    func testInScatterAgainstQuadrature() {
        let radiance: (Vec3) -> Spectrum3 = { Self.grey(2 + $0.z + 0.5 * $0.x * $0.y) }
        let sh = SH9.project(size: 48, radiance)
        let texels = EnvironmentProbe.texels(size: 48)
        for g in [0.0, 0.3, -0.4] {
            for v in Self.directions.prefix(12) {
                var sum = 0.0
                for t in texels {
                    let c = t.direction.dot(v)
                    let p = (1 - g * g) / (4 * Double.pi * pow(1 + g * g - 2 * g * c, 1.5))
                    sum += radiance(t.direction).g * p * t.solidAngle
                }
                // The radiance has no band above 2: exact but for g^l's
                // higher bands of the phase, which see nothing.
                XCTAssertEqual(sh.inScatter(view: v, asymmetry: g).g, sum, accuracy: 3e-3, "g \(g) v \(v)")
            }
        }
    }

    func testPublishedCoefficientsRoundTrip() {
        let sh = SH9.project(size: 16) { Spectrum3(1 + $0.x, 2 + $0.y * $0.z, 3 - $0.z) }
        let back = SH9(irradianceOverPi: sh.irradianceOverPi)
        for i in 0..<9 {
            XCTAssertEqual(back.coefficients[i].r, sh.coefficients[i].r, accuracy: 1e-12)
            XCTAssertEqual(back.coefficients[i].b, sh.coefficients[i].b, accuracy: 1e-12)
        }
        // The published l = 0 term is the mean radiance over Y₀₀.
        XCTAssertEqual(sh.irradianceOverPi[0].g * 0.282_094_791_773_878_1, sh.meanRadiance.g, accuracy: 1e-12)
    }
}
