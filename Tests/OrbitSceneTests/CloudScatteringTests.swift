import XCTest
@testable import OrbitScene

/// Track C2's cloud lighting: the phase functions' normalisation, the
/// two-stream streams against C1's slab reflectance, the march against its
/// closed form, and the slab-BRDF LUT against the two-stream slab.
final class CloudScatteringTests: XCTestCase {
    /// ∫ p dω and ∫ p cos θ dω, by the midpoint rule in cos θ, densest where
    /// a forward peak needs it (cos θ near 1).
    private func moments(_ p: (Double) -> Double) -> (norm: Double, meanCosine: Double) {
        var norm = 0.0, mean = 0.0
        let n = 400_000
        for k in 0..<n {
            // x in (0, 1) mapped as cos θ = 1 − 2 x², fine near 1.
            let x = (Double(k) + 0.5) / Double(n), c = 1 - 2 * x * x, dc = 4 * x / Double(n)
            norm += 2 * .pi * p(c) * dc
            mean += 2 * .pi * p(c) * c * dc
        }
        return (norm, mean)
    }

    func testHenyeyGreensteinAndDraineAreNormalised() {
        for g in [0.0, 0.5, 0.85, 0.99] {
            let m = moments { CloudPhase.henyeyGreenstein($0, g: g) }
            XCTAssertEqual(m.norm, 1, accuracy: 1e-3, "HG g = \(g)")
            XCTAssertEqual(m.meanCosine, g, accuracy: 2e-3, "HG g = \(g)")
        }
        let d = moments { CloudPhase.draine($0, g: 0.6, alpha: 27) }
        XCTAssertEqual(d.norm, 1, accuracy: 1e-3)
        XCTAssertEqual(d.meanCosine, CloudPhase.draineAsymmetry(g: 0.6, alpha: 27), accuracy: 2e-3)
    }

    /// Jendersie and d'Eon's fit for 20 µm drops: normalised, with the
    /// asymmetry of water clouds of 10 µm effective radius in the visible,
    /// about 0.86-0.88 (Hansen and Travis 1974, Fig. 12).
    func testApproximateMie() {
        let mie = CloudPhase.ApproximateMie(diameter: 20)
        let m = moments { mie.phase($0) }
        XCTAssertEqual(m.norm, 1, accuracy: 2e-3)
        XCTAssertEqual(m.meanCosine, mie.asymmetry, accuracy: 3e-3)
        XCTAssertGreaterThan(mie.asymmetry, 0.85)
        XCTAssertLessThan(mie.asymmetry, 0.89)
        // The diffraction peak and a glory-like rise towards the back.
        XCTAssertGreaterThan(mie.phase(1), 1_000)
        XCTAssertGreaterThan(mie.phase(-1), mie.phase(-0.5))
    }

    /// The streams' upward flux at the top is C1's two-stream slab
    /// reflectance; the net flux is the same at every depth (no absorption).
    func testStreamsAreTheTwoStreamSlab() {
        let l = CloudLighting()
        for tau in [0.5, 3, 10, 40] {
            let top = l.streams(depth: 0, column: tau), base = l.streams(depth: tau, column: tau)
            XCTAssertEqual(top.down, 1, accuracy: 1e-12)
            XCTAssertEqual(top.up, CloudOptics.slabReflectance(opticalDepth: tau, asymmetry: l.asymmetry), accuracy: 1e-12)
            XCTAssertEqual(base.up, 0, accuracy: 1e-12)
            XCTAssertEqual(base.down, CloudOptics.slabTransmittance(opticalDepth: tau, asymmetry: l.asymmetry),
                           accuracy: 1e-12)
            let mid = l.streams(depth: tau / 3, column: tau)
            XCTAssertEqual(mid.down - mid.up, base.down, accuracy: 1e-12)
        }
        // C1's pin: R(10, 0.85) = 0.43.
        XCTAssertEqual(l.streams(depth: 0, column: 10).up, 0.43, accuracy: 0.005)
    }

    /// With fine steps and a light march that reaches the slab's top, the
    /// march's single scattering converges to its closed form.
    func testSingleScatteringConvergesToItsClosedForm() {
        var lighting = CloudLighting()
        lighting.lightSamples = 400
        lighting.lightDistance = 40_000
        let slab = CloudSlab(thickness: 1_500, lighting: lighting)
        for (tau, mu0, mu) in [(0.5, 0.9, 0.7), (4.0, 0.5, 0.8), (20.0, 0.3, 0.4)] {
            let r = slab.march(opticalDepth: tau, mu0: mu0, mu: mu, steps: 800)
            XCTAssertEqual(r.single, slab.singleScatteringClosedForm(opticalDepth: tau, mu0: mu0, mu: mu),
                           accuracy: 0.01 * r.single, "τ \(tau)")
            XCTAssertEqual(r.transmittance, exp(-tau / mu), accuracy: 1e-9)
        }
    }

    /// The slab's plane albedo (the Sun 60° from the zenith) against the
    /// two-stream slab: within 15 % from τ = 10 to 90, within 0.04 below,
    /// where the march's single scattering, which the two-stream streams
    /// count as well, is a larger part of the light.
    /// It grows with τ and stays under 1, for any Sun.
    func testPlaneAlbedoAgainstTwoStream() {
        let slab = CloudSlab(thickness: CloudLayerModel.lowDepth)
        var last = 0.0
        for tau in [0.3, 1, 3, 10, 30, 90] {
            let a = slab.planeAlbedo(opticalDepth: tau, mu0: 0.5, muSteps: 12, azimuths: 24)
            let r = CloudOptics.slabReflectance(opticalDepth: tau, asymmetry: CloudLayerModel.waterAsymmetry)
            if tau >= 10 {
                XCTAssertEqual(a, r, accuracy: 0.15 * r, "τ \(tau)")
            } else {
                XCTAssertEqual(a, r, accuracy: 0.04, "τ \(tau)")
            }
            XCTAssertGreaterThan(a, last)
            last = a
        }
        for mu0 in [0.1, 0.3, 1.0] {
            XCTAssertLessThan(slab.planeAlbedo(opticalDepth: 200, mu0: mu0, muSteps: 12, azimuths: 24), 1)
        }
    }

    func testSlabLUT() {
        let lut = CloudSlabLUT.standard()
        XCTAssertEqual(lut.texels.count, 4 * 16 * 16 * 24 * 2)
        for k in [0, 7, 23] {
            XCTAssertEqual(CloudSlabLUT.depthCoordinate(CloudSlabLUT.depth(k)), Double(k), accuracy: 1e-9)
        }
        XCTAssertEqual(CloudSlabLUT.cosineCoordinate(CloudSlabLUT.cosine(9)), 9, accuracy: 1e-9)
        // A texel is the march at its grid point; the mid layer's block
        // follows the low one's.
        let (l, k, j, i) = (1, 12, 5, 11)
        let r = lut.slabs[l].march(opticalDepth: CloudSlabLUT.depth(k), mu0: CloudSlabLUT.cosine(j),
                                   mu: CloudSlabLUT.cosine(i))
        let at = 4 * (((l * CloudSlabLUT.depths + k) * CloudSlabLUT.cosines + j) * CloudSlabLUT.cosines + i)
        XCTAssertEqual(Double(lut.texels[at]), r.single, accuracy: 1e-6)
        XCTAssertEqual(Double(lut.texels[at + 1]), r.sunDiffuse, accuracy: 1e-6)
        XCTAssertEqual(Double(lut.texels[at + 2]), r.sky, accuracy: 1e-6)
        XCTAssertEqual(Double(lut.texels[at + 3]), r.transmittance, accuracy: 1e-6)
        XCTAssertTrue(lut.texels.allSatisfy { $0.isFinite && $0 >= 0 })
    }
}
