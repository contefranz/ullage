import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// The probe's cube geometry, its CPU references, the night floor and the
/// look-dev environments (track R3).
final class EnvironmentProbeTests: XCTestCase {
    func testSolidAnglesCoverTheSphere() {
        for size in [1, 4, 16, 128] {
            let total = EnvironmentProbe.texels(size: size).reduce(0) { $0 + $1.solidAngle }
            XCTAssertEqual(total, 4 * Double.pi, accuracy: 1e-9, "size \(size)")
        }
        // A face's centre texel against its small-angle value, (2/n)² for a unit distance.
        let n = 128
        XCTAssertEqual(EnvironmentProbe.texelSolidAngle(x: 64, y: 64, size: n), pow(2 / Double(n), 2), accuracy: 1e-7)
    }

    /// OpenGL's (and Metal's) table: +X's top-left texel looks to +x, +y, +z;
    /// +Y's top row toward −z; −Z's left column toward +x.
    func testFacesFollowTheCubeMapConvention() {
        func dir(_ f: EnvironmentProbe.Face, _ s: Double, _ t: Double) -> Vec3 {
            EnvironmentProbe.direction(face: f, s: s, t: t)
        }
        XCTAssertEqual(dir(.positiveX, -1, -1), Vec3(1, 1, 1))
        XCTAssertEqual(dir(.positiveY, 0, -1), Vec3(0, 1, -1))
        XCTAssertEqual(dir(.negativeZ, -1, 0), Vec3(1, 0, -1))
        XCTAssertEqual(dir(.positiveZ, 1, 1), Vec3(1, -1, 1))
        for face in EnvironmentProbe.Face.allCases {
            let b = EnvironmentProbe.basis(face)
            for (s, t) in [(0.3, -0.7), (-0.9, 0.2), (0.5, 0.5)] {
                let d = dir(face, s, t)
                XCTAssertEqual((b.forward + b.right * s + b.up * -t - d).length, 0, accuracy: 1e-12)
                let back = EnvironmentProbe.faceCoordinates(d * 3.7)
                XCTAssertEqual(back.face, face)
                XCTAssertEqual(back.s, s, accuracy: 1e-12)
                XCTAssertEqual(back.t, t, accuracy: 1e-12)
            }
        }
    }

    func testPrefilterReference() {
        // A uniform environment stays itself at every roughness.
        let uniform = EnvironmentProbe.CubeMap(size: 16) { _ in Spectrum3(repeating: 7) }
        for r in [0.05, 0.5, 1] {
            XCTAssertEqual(EnvironmentProbe.prefilterReference(uniform, n: Vec3(0.3, -0.5, 0.8).normalized,
                                                               roughness: r).g, 7, accuracy: 1e-9)
        }
        // A sky over a black ground: looking up, near mirror it is the sky; the
        // lobe widening over the horizon darkens it, but never below the
        // irradiance's view of it.
        let sky = EnvironmentProbe.CubeMap(size: 32) { Spectrum3(repeating: $0.z > 0 ? 1 : 0) }
        let up = Vec3(0.2, 0, 1).normalized
        var last = 2.0
        for r in [0.05, 0.3, 0.6, 1.0] {
            let v = EnvironmentProbe.prefilterReference(sky, n: up, roughness: r).g
            XCTAssertLessThanOrEqual(v, last + 1e-12)
            XCTAssertGreaterThan(v, 0.5)
            last = v
        }
        XCTAssertEqual(EnvironmentProbe.prefilterReference(sky, n: up, roughness: 0.05).g, 1, accuracy: 1e-5)
    }

    func testIrradianceReferenceOfTheUniformSky() {
        let sky = EnvironmentProbe.CubeMap(size: 32) { Spectrum3(repeating: $0.z > 0 ? 1 : 0) }
        for n in [Vec3.unitZ, Vec3.unitX, -Vec3.unitZ, Vec3(1, 1, 1).normalized] {
            XCTAssertEqual(EnvironmentProbe.irradianceReference(sky, n: n).g, (1 + n.z) / 2, accuracy: 2e-3)
        }
    }

    func testNightFloor() {
        // The vessels' stand-in floor, as E/π.
        let p = 3.2e-5
        XCTAssertEqual(EnvironmentProbe.nightFloor(share: 0.02, preExposure: p),
                       StandInLighting.floorIlluminance(0.02, preExposure: p) / Double.pi, accuracy: 1e-9)
        let f = 10.0
        XCTAssertEqual(EnvironmentProbe.floored(0, floor: f), f)
        XCTAssertEqual(EnvironmentProbe.floored(f, floor: f), 1.5 * f)
        XCTAssertEqual(EnvironmentProbe.floored(1_000, floor: f), 1_000, accuracy: 0.11)
        XCTAssertEqual(EnvironmentProbe.floored(5, floor: 0), 5)
        // Monotone.
        var last = 0.0
        for x in stride(from: 0.0, through: 100, by: 0.5) {
            let y = EnvironmentProbe.floored(x, floor: f)
            XCTAssertGreaterThan(y, last)
            last = y
        }
    }

    /// The look-dev Earth: the sub-solar ground at its albedo's radiance,
    /// none past the disc's edge or over the night side, and the nadir
    /// plate's irradiance under a high Sun near the stand-in's (the disc's
    /// mean cosine times Howell's factor).
    func testLookDevEarthBelow() {
        let sun = Vec3(0, 0, 1)
        let env = EnvironmentProbe.LookDevEnvironment.earthBelow(toSun: sun, sunLux: 100_000)
        let c = Photometry.sunColor
        let nadir = env.radiance(-.unitZ)
        XCTAssertEqual(nadir.g, 0.88 * 0.3 / Double.pi * c.g * 100_000, accuracy: 1e-6)
        let s2 = LookDevScenes.earthSinSigma2, sigma = asin(s2.squareRoot())
        let inside = Vec3(sin(sigma - 0.01), 0, -cos(sigma - 0.01)), outside = Vec3(sin(sigma + 0.01), 0, -cos(sigma + 0.01))
        XCTAssertGreaterThan(env.radiance(inside).g, 0)
        XCTAssertEqual(env.radiance(outside).g, 0)
        XCTAssertEqual(env.radiance(.unitZ).g, 0)
        let night = EnvironmentProbe.LookDevEnvironment.earthBelow(toSun: -.unitZ, sunLux: 100_000)
        XCTAssertEqual(night.radiance(-.unitZ).g, 0)

        let cube = EnvironmentProbe.CubeMap(size: 64) { env.radiance($0) }
        let e = EnvironmentProbe.irradianceReference(cube, n: -.unitZ).g
        let mean = StandInLighting.litCosine(toBody: -.unitZ, sinSigma2: s2, toSun: sun)
        let standIn = 0.88 * 0.3 / Double.pi * c.g * 100_000 * mean
            * BRDF.sphereIrradiance(cosTheta: 1, sinSigma2: s2) / Double.pi
        // The stand-in spreads the disc's mean evenly; the true disc is
        // brightest at its centre, where the plate's cosine is highest.
        XCTAssertGreaterThan(e, standIn)
        XCTAssertLessThan(e, 1.3 * standIn)
    }

    func testSettingsDecodeAndResolve() throws {
        let s = try JSONDecoder().decode(ProbeSettings.self, from: Data("{\"faceSize\": 100}".utf8))
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.resolvedFaceSize, 128)
        XCTAssertEqual(s.resolvedSpecularMips, 6)
        var low = ProbeSettings()
        low.faceSize = 64
        XCTAssertEqual(low.resolvedSpecularMips, 5)
        let off = try JSONDecoder().decode(ProbeSettings.self,
                                           from: Data("{\"enabled\": false, \"environment\": \"furnace\"}".utf8))
        XCTAssertFalse(off.enabled)
        XCTAssertEqual(off.environment, .furnace)
        XCTAssertEqual(EnvironmentProbe.roughness(mip: 5, count: 6), 1)
        XCTAssertEqual(EnvironmentProbe.roughness(mip: 1, count: 6), 0.2, accuracy: 1e-12)
    }
}
