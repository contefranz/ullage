import XCTest
import OrbitCore
@testable import OrbitScene

/// Track A2's maths on the CPU: the sky-view and froxel parameterisations,
/// the march the GPU mirrors, the light shared with vessels, the Sun's limb
/// darkening, and the sky against external references (the CIE standard
/// clear sky, the Earth's shadow over an observer).
final class AtmosphereSkyTests: XCTestCase {
    /// A1's tables at the standard resolution, the renderer's (0.33 s in
    /// Release, 25 s in Debug, once per process).
    static var lut: AtmosphereLUT { AtmosphereTables.shared.tables(wait: true)! }
    static let system = try! SolarSystem.bundled()

    var lut: AtmosphereLUT { Self.lut }

    // MARK: Parameterisations

    func testSkyViewRoundTrip() {
        let rb = lut.bottomRadius
        for h in [0.0, 30, 10_000, 99_000] {
            for mu in stride(from: -0.99, through: 0.99, by: 0.07) {
                for cosAz in stride(from: -1.0, through: 1.0, by: 0.25) {
                    let uv = SkyViewParameterization.uv(radius: rb + h, bottomRadius: rb, cosZenith: mu,
                                                        cosAzimuth: cosAz, width: 192, height: 108)
                    let v = SkyViewParameterization.view(u: uv.u, v: uv.v, radius: rb + h, bottomRadius: rb,
                                                         width: 192, height: 108)
                    XCTAssertEqual(v.cosZenith, mu, accuracy: 1e-9, "h \(h) mu \(mu)")
                    XCTAssertEqual(v.cosAzimuth, cosAz, accuracy: 1e-9)
                }
            }
        }
    }

    /// The horizon, dipped by the camera's height, falls between the two
    /// middle rows, and half the rows lie within a few degrees of it.
    func testSkyViewHorizonIsTheMiddle() {
        let rb = lut.bottomRadius
        for h in [10.0, 10_000, 80_000] {
            let dip = acos(rb / (rb + h))
            let uv = SkyViewParameterization.uv(radius: rb + h, bottomRadius: rb, cosZenith: -sin(dip), cosAzimuth: 1,
                                                width: 192, height: 108)
            XCTAssertEqual(uv.v, 0.5, accuracy: 1e-6, "h \(h)")
        }
        // At 10 km, a quarter of the way up the sky's rows is within 23° of the horizon.
        let rows = SkyViewParameterization.view(u: 0.5, v: AtmosphereLUT.textureCoordinate(unit: 0.25, size: 108),
                                                radius: rb + 10_000, bottomRadius: rb, width: 192, height: 108)
        XCTAssertLessThan(90 - acos(rows.cosZenith) * 180 / .pi, 23)
    }

    func testFroxelSlices() {
        let s = FroxelSlices(count: 32, far: 400_000, exponent: 2)
        for i in 0..<32 {
            let c = s.coordinate(distance: s.distance(slice: i))
            XCTAssertEqual(c.w, (Double(i) + 0.5) / 32, accuracy: 1e-12)
            XCTAssertEqual(c.weight, 1)
        }
        XCTAssertEqual(s.coordinate(distance: s.distance(slice: 0) / 2).weight, 1 / 2.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(s.coordinate(distance: 0).weight, 0)
        // The far distance from the pad: its horizon (36 km at 100 m) and a
        // 12 km cloud top's (391 km).
        XCTAssertEqual(FroxelSlices.far(cameraAltitude: 100, bottomRadius: 6_378_137), 427_000, accuracy: 1_000)
        XCTAssertEqual(FroxelSlices.far(cameraAltitude: 1e7, bottomRadius: 6_378_137), 2_000_000)
    }

    // MARK: The Sun's limb

    /// Hestroffer and Magnan's exponents at A1's wavelengths, the disc's
    /// mean normalised, R1's linear law matched at 550 nm, the limb redder.
    func testSolarLimbDarkening() {
        let a = SolarLimbDarkening.exponents
        XCTAssertEqual(a.r, -0.023 + 0.292 / 0.68, accuracy: 1e-12)
        XCTAssertEqual(a.g, 0.5079, accuracy: 1e-4)
        XCTAssertEqual(a.b, 0.6406, accuracy: 1e-4)
        // The relative luminance averages to 1 over the disc, per channel.
        let radius = 0.004654, n = 2_000
        var sum = Spectrum3.zero, area = 0.0
        for k in 0..<n {
            let theta = radius * (Double(k) + 0.5) / Double(n)
            let ring = 2 * Double.pi * sin(theta) * radius / Double(n)
            sum += SolarLimbDarkening.relativeLuminance(angle: theta, angularRadius: radius) * ring
            area += ring
        }
        for c in [sum.r, sum.g, sum.b] { XCTAssertEqual(c / area, 1, accuracy: 2e-3) }
        let centre = SolarLimbDarkening.relativeLuminance(angle: 0, angularRadius: radius)
        XCTAssertEqual(centre.g, Photometry.solarCentreOverMean, accuracy: 0.01 * Photometry.solarCentreOverMean,
                       "R1's linear law, u = 0.6, at 550 nm")
        let limb = SolarLimbDarkening.relativeLuminance(angle: 0.95 * radius, angularRadius: radius)
        XCTAssertGreaterThan(limb.r / limb.b, centre.r / centre.b * 1.2, "the limb is redder")
        XCTAssertEqual(SolarLimbDarkening.relativeLuminance(angle: 1.01 * radius, angularRadius: radius), .zero)
    }

    // MARK: The march

    /// The march the GPU mirrors converges to A1's sky (black ground): from
    /// the pad and from orbit, across the sky and the limb.
    func testMarchMatchesA1Sky() {
        let rb = lut.bottomRadius
        for (h, sunElevation) in [(10.0, 7.0), (10.0, 40.0), (12_000.0, -2.0), (400_000.0, 20.0), (400_000.0, -5.0)] {
            let e = sunElevation * Double.pi / 180
            let sun = Vec3(cos(e), 0, sin(e)), o = Vec3(0, 0, rb + h)
            for (zenith, azimuth) in [(0.0, 0.0), (60.0, 0.0), (85.0, 180.0), (88.0, 90.0), (100.0, 30.0), (95, 0)] {
                let z = zenith * Double.pi / 180, a = azimuth * Double.pi / 180
                if h > 100_000 && zenith < 100 { continue }
                // From orbit, rays below the horizontal toward the limb.
                let zz = h > 100_000 ? Double.pi / 2 + acos(rb / (rb + h)) - 0.004 * (zenith - 100) : z
                let d = Vec3(sin(zz) * cos(a), sin(zz) * sin(a), cos(zz))
                let m = AtmosphereMarch.sky(lut, origin: o, direction: d, steps: 200, sun: sun, cosView: d.dot(sun))
                let ref = lut.skyRadiance(radius: rb + h, cosZenith: cos(zz), cosSun: sin(e), cosView: d.dot(sun),
                                          steps: 400, groundAlbedo: .zero)
                for (x, y) in [(m.radiance.r, ref.r), (m.radiance.g, ref.g), (m.radiance.b, ref.b)] {
                    XCTAssertEqual(x, y, accuracy: 0.02 * y + 1e-9, "h \(h), Sun \(sunElevation)°, view \(zenith)°/\(azimuth)°")
                }
            }
        }
    }

    // MARK: External references

    /// The CIE standard clear sky, low turbidity (type 12 of CIE S 011/E:2003,
    /// ISO 15469): gradation a = -1, b = -0.32; indicatrix c = 10, d = -3,
    /// e = 0.45. Relative to the zenith, at the given zenith angle Z and
    /// angular distance χ from the Sun (Sun at zenith angle Zs).
    static func cieClearSky(zenith z: Double, fromSun chi: Double, sunZenith zs: Double) -> Double {
        func phi(_ z: Double) -> Double { z < Double.pi / 2 ? 1 - exp(-0.32 / cos(z)) : 1 }
        func f(_ x: Double) -> Double { 1 + 10 * (exp(-3 * x) - exp(-3 * Double.pi / 2)) + 0.45 * cos(x) * cos(x) }
        return phi(z) * f(chi) / (phi(0) * f(zs))
    }

    /// The model's sky (AOD 0.1, the US-1976 air) has the shape of the CIE
    /// standard clear sky: the zenith luminance over the diffuse
    /// illuminance (which the CIE's distribution gives by integration), and
    /// the anti-solar horizon and the sky 90° from the Sun over the zenith.
    /// Within 15 % with the Sun at 7° and 10° (Apollo 8's launch); with it at
    /// 20-40° the physical sky's horizon is 30-40 % brighter against its
    /// zenith than the empirical fit's (45 %).
    func testSkyShapeMatchesTheCIEClearSky() {
        let rb = lut.bottomRadius, o = Vec3(0, 0, rb + 10)
        func luminance(_ s: Spectrum3) -> Double {
            let c = Photometry.sunColor
            return 0.2126 * s.r * c.r + 0.7152 * s.g * c.g + 0.0722 * s.b * c.b
        }
        for elevation in [7.0, 10, 20, 30, 40, 60] {
            let e = elevation * Double.pi / 180, zs = Double.pi / 2 - e
            let sun = Vec3(cos(e), 0, sin(e))
            func model(_ elev: Double, _ azimuth: Double) -> Double {
                let a = elev * Double.pi / 180, p = azimuth * Double.pi / 180
                let d = Vec3(cos(a) * cos(p), cos(a) * sin(p), sin(a))
                return luminance(AtmosphereMarch.sky(lut, origin: o, direction: d, steps: 64, sun: sun,
                                                     cosView: d.dot(sun)).radiance)
            }
            func cie(_ elev: Double, _ azimuth: Double) -> Double {
                let z = Double.pi / 2 - elev * Double.pi / 180, p = azimuth * Double.pi / 180
                let chi = acos(min(max(cos(zs) * cos(z) + sin(zs) * sin(z) * cos(p), -1), 1))
                return Self.cieClearSky(zenith: z, fromSun: chi, sunZenith: zs)
            }
            // ∫ L/Lz cos Z dω over the sky, midpoint rule.
            var cieDiffuse = 0.0
            let nz = 90, na = 180
            for i in 0..<nz {
                let z = (Double(i) + 0.5) / Double(nz) * Double.pi / 2
                for j in 0..<na {
                    let p = (Double(j) + 0.5) / Double(na) * 2 * Double.pi
                    let chi = acos(min(max(cos(zs) * cos(z) + sin(zs) * sin(z) * cos(p), -1), 1))
                    cieDiffuse += Self.cieClearSky(zenith: z, fromSun: chi, sunZenith: zs) * cos(z) * sin(z)
                        * (Double.pi / 2 / Double(nz)) * (2 * Double.pi / Double(na))
                }
            }
            let zenith = model(90, 0)
            let diffuse = luminance(lut.skyIrradiance(radius: rb + 10, cosSun: sin(e)))
            let tolerance = elevation <= 10 ? 0.15 : 0.45
            let checks = [("zenith over diffuse", zenith / diffuse, 1 / cieDiffuse),
                          ("anti-solar horizon", model(5, 180) / zenith, cie(5, 180)),
                          ("90° from the Sun", model(3, 90) / zenith, cie(3, 90))]
            for (name, got, want) in checks {
                XCTAssertEqual(got, want, accuracy: tolerance * want, "Sun at \(elevation)°: \(name)")
            }
        }
    }

    /// The Earth's shadow over an observer after sunset: with the Sun δ
    /// below the horizon, the air straight up is sunlit from R(sec δ − 1)
    /// up (6° gives 35 km, the end of civil twilight), shadowed below, and
    /// the zenith darkens by orders of magnitude through twilight.
    func testEarthShadowOverAnObserver() {
        let rb = lut.bottomRadius
        func sunlit(_ h: Double, depression: Double) -> Double {
            lut.transmittanceToSun(radius: rb + h, cosSun: -sin(depression)).g
        }
        for degrees in [2.0, 4.0, 6.0, 8.0] {
            let delta = degrees * Double.pi / 180
            let h = rb * (1 / cos(delta) - 1)
            XCTAssertLessThan(sunlit(0.8 * h, depression: delta), 1e-9, "δ \(degrees)°: below the shadow")
            XCTAssertGreaterThan(sunlit(1.25 * h + 2_000, depression: delta), 0, "δ \(degrees)°: above it")
        }
        XCTAssertEqual(rb * (1 / cos(6 * Double.pi / 180) - 1), 35_100, accuracy: 100)
        let o = Vec3(0, 0, rb + 10), up = Vec3.unitZ
        func zenith(_ elevation: Double) -> Double {
            let e = elevation * Double.pi / 180, sun = Vec3(cos(e), 0, sin(e))
            return AtmosphereMarch.sky(lut, origin: o, direction: up, steps: 64, sun: sun, cosView: sin(e)).radiance.g
        }
        XCTAssertLessThan(zenith(-6), 0.01 * zenith(0))
        XCTAssertLessThan(zenith(-12), 0.01 * zenith(-6))
    }

    // MARK: The light shared with vessels

    func scene(_ scenario: Scenario, camera: (inout OrbitCamera) -> Void = { _ in }) -> RenderScene {
        let sim = scenario.build(Self.system)
        var cam = OrbitCamera()
        if let focus = sim.focus { cam.target = .vessel(focus.id) }
        cam.distance = 100
        camera(&cam)
        cam.update(sim: sim)
        return SceneExtractor().extract(sim: sim, camera: cam, viewport: RenderScene.Viewport(width: 64, height: 40),
                                        realTime: 0)
    }

    /// On the pad at Apollo 8's launch the Sun is about 7° up and comes
    /// through the air as A1 has it, (0.37, 0.18, 0.052): the colour R2's
    /// vessel pass multiplies by the lux is that times R1's sunlight
    /// colour; the sky lights a horizontal surface with about 5 klx.
    func testSunAndSkyAtTheDawnPad() throws {
        let s = scene(.apollo8FirstMotion)
        let frame = try XCTUnwrap(AtmosphereFrame(scene: s, tables: lut))
        XCTAssertTrue(frame.isInside)
        XCTAssertEqual(asin(frame.cosSunZenith) * 180 / .pi, 7, accuracy: 1.5, "the Sun about 7° up")
        let t = frame.sunTransmittance
        XCTAssertEqual(t.r, 0.37, accuracy: 0.05)
        XCTAssertEqual(t.g, 0.18, accuracy: 0.04)
        XCTAssertEqual(t.b, 0.052, accuracy: 0.02)
        let sun = frame.sunTransmitted, c = Photometry.sunColor
        XCTAssertEqual(sun.illuminance, s.sun.illuminance)
        XCTAssertEqual(sun.color.r, c.r * t.r, accuracy: 1e-12)
        XCTAssertEqual(sun.color.b, c.b * t.b, accuracy: 1e-12)
        let sky = frame.skyIrradiance
        XCTAssertEqual(sky.luminance, 5_000, accuracy: 2_000)
        XCTAssertGreaterThan(sky.b / sky.r, 1.1, "the sky's light is blue")
    }

    /// In orbit, in sunlight, nothing is in the way: the colour times the
    /// lux is FrameUniforms' sunlight exactly, and there is no sky. Behind
    /// the Earth the colour is black and the lux stays (R2 tests w > 0).
    func testSunAboveTheAir() throws {
        let s = scene(.lowEarthOrbit)
        let frame = try XCTUnwrap(AtmosphereFrame(scene: s, tables: lut))
        XCTAssertFalse(frame.isInside)
        XCTAssertEqual(frame.skyIrradiance, Photometry.RGB(0, 0, 0))
        let sun = frame.sunTransmitted, expected = Photometry.sunColor.scaled(by: s.sun.illuminance)
        if frame.sunTransmittance.g > 0.5 {
            XCTAssertEqual(sun.color.r * sun.illuminance, expected.r, accuracy: 1e-6 * expected.r)
            XCTAssertEqual(sun.color.g * sun.illuminance, expected.g, accuracy: 1e-6 * expected.g)
            XCTAssertEqual(sun.color.b * sun.illuminance, expected.b, accuracy: 1e-6 * expected.b)
        }
        // Half an orbit on: the night side.
        let sim = Scenario.lowEarthOrbit.build(Self.system)
        var night: RenderScene?
        for _ in 0..<12 {
            sim.advance(by: 500)
            var cam = OrbitCamera()
            cam.target = .vessel(sim.focus!.id)
            cam.update(sim: sim)
            let candidate = SceneExtractor().extract(sim: sim, camera: cam,
                                                     viewport: RenderScene.Viewport(width: 64, height: 40),
                                                     realTime: 0)
            if let f = AtmosphereFrame(scene: candidate, tables: lut), f.cosSunZenith < -0.5 {
                night = candidate
                break
            }
        }
        let dark = try XCTUnwrap(AtmosphereFrame(scene: try XCTUnwrap(night), tables: lut))
        XCTAssertEqual(dark.sunTransmitted.color, Photometry.RGB(0, 0, 0))
        XCTAssertGreaterThan(dark.sunTransmitted.illuminance, 0)
    }

    /// Figure coordinates: the camera on the pad is a few metres above the
    /// sphere of radius a, though the ellipsoid there is 4.9 km inside it.
    func testFigureCoordinates() throws {
        let frame = try XCTUnwrap(AtmosphereFrame(scene: scene(.apollo8FirstMotion), tables: lut))
        XCTAssertEqual(frame.cameraAltitude, 0, accuracy: 300, "the camera near the pad's elevation")
        XCTAssertEqual(frame.up.length, 1, accuracy: 1e-12)
        XCTAssertEqual(frame.sunAzimuth.dot(frame.up), 0, accuracy: 1e-12)
        // A view straight at the Sun is at its zenith angle and azimuth 0.
        let toSun = frame.skyViewAngles(scene(.apollo8FirstMotion).sun.direction)
        XCTAssertEqual(toSun.cosZenith, frame.cosSunZenith, accuracy: 1e-9)
        XCTAssertEqual(toSun.cosAzimuth, 1, accuracy: 1e-9)
    }
}
