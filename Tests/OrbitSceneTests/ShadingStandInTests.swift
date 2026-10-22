import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// The vessel pass's stand-ins until the tracks that own each piece land:
/// plume lights from P1's specs, the lighting around vessels and the pad,
/// the material defaults, VM1's paint as vertex ids, and the settings.
final class ShadingStandInTests: XCTestCase {
    static let system = try! SolarSystem.bundled()
    static let viewport = RenderScene.Viewport(width: 640, height: 400)

    func scene(_ id: String, advance seconds: Double = 0, sites: [SitePlacement] = []) throws -> RenderScene {
        let scenario = try XCTUnwrap(Scenario.named(id))
        let sim = scenario.build(Self.system)
        var camera = OrbitCamera()
        if let focus = sim.focus {
            camera.target = .vessel(focus.id)
            camera.distance = max(focus.boundingRadius * 3, 30)
        }
        sim.paused = false
        sim.stepBudget = nil
        var left = seconds
        while left > 1e-9 {
            sim.advance(by: min(5, left))
            left -= min(5, left)
        }
        camera.update(sim: sim)
        let x = SceneExtractor()
        x.sites = sites
        return x.extract(sim: sim, camera: camera, viewport: Self.viewport, realTime: 0)
    }

    /// The 1948 candela: a blackbody at the freezing point of platinum,
    /// 2041.4 K (IPTS-68), has a luminance of 60 cd/cm², 6.0e5 cd/m².
    func testBlackbodyLuminanceAtThePlatinumPoint() {
        XCTAssertEqual(PlumeLights.blackbodyLuminance(2_041.4), 6.0e5, accuracy: 0.03 * 6.0e5)
        XCTAssertGreaterThan(PlumeLights.blackbodyLuminance(3_000), 10 * PlumeLights.blackbodyLuminance(2_000))
        XCTAssertEqual(PlumeLights.blackbodyLuminance(0), 0)
    }

    /// AS-506 at first motion: one light per F-1, along the exhaust from
    /// its exit, afterburning in air (2,300 K), of the order of 10⁸ cd each
    /// (a sooty column of 1.8 m radius and 36 m glowing at about 1e6
    /// cd/m², some 40 times sunlit white paint), so the five light the pad
    /// at about a megalux from 30 m. The cluster is lit as one light, its
    /// intensity the five's, its column holding all five.
    func testF1PlumesLightThePadAtLiftoff() throws {
        let s = try scene("as506-pad", advance: 0.5)
        let each = s.emitters.compactMap(PlumeLights.light)
        XCTAssertEqual(each.count, 5)
        for l in each {
            let e = try XCTUnwrap(s.emitters.min {
                ($0.exit + $0.axis * (0.5 * l.length) - l.centre).length < ($1.exit + $1.axis * (0.5 * l.length) - l.centre).length
            })
            XCTAssertEqual((e.exit + e.axis * (0.5 * l.length) - l.centre).length, 0, accuracy: 1e-6)
            XCTAssertEqual(l.axis.dot(e.axis), 1, accuracy: 1e-9)
            XCTAssertGreaterThan(l.luminousIntensity, 2e6)
            XCTAssertLessThan(l.luminousIntensity, 5e8)
            XCTAssertLessThanOrEqual(l.length, 10 * 2 * l.radius + 1e-9)
            let luminance = 0.2126 * Double(l.intensity.r) + 0.7152 * Double(l.intensity.g)
                + 0.0722 * Double(l.intensity.b)
            XCTAssertEqual(luminance, l.luminousIntensity, accuracy: 1e-3 * l.luminousIntensity)
            XCTAssertGreaterThan(l.intensity.r, l.intensity.b, "a flame is warm")
        }
        let total = each.reduce(0) { $0 + $1.luminousIntensity }
        XCTAssertGreaterThan(total / (30 * 30), 1e4, "lux at 30 m")
        XCTAssertLessThan(total / (30 * 30), 3e6)
        let lights = PlumeLights.lights(s)
        XCTAssertEqual(lights.count, 1, "the five F-1s as one cluster")
        XCTAssertEqual(lights[0].luminousIntensity, total, accuracy: 1e-9 * total)
        for l in each {
            XCTAssertLessThanOrEqual((l.centre - lights[0].centre).length + l.radius, lights[0].radius + 1e-9)
        }
        XCTAssertLessThanOrEqual(PlumeLights.lights(s, maximum: 0).count, 0)
    }

    /// A J-2 in vacuum (hydrogen, nearly invisible) lights far less than an
    /// F-1 at sea level; cold gas not at all.
    func testHydrogenPlumeIsFaint() {
        let f1 = PlumeLights.emissivity(.keroseneLOX, sootIndex: 1) * PlumeLights.blackbodyLuminance(2_300)
        let j2 = PlumeLights.emissivity(.hydrogenLOX, sootIndex: 0) * PlumeLights.blackbodyLuminance(1_300)
        XCTAssertGreaterThan(f1, 100 * j2)
        XCTAssertEqual(PlumeLights.emissivity(.coldGas, sootIndex: 0), 0)
    }

    /// The vessel stand-in is M1.5's lighting in lux: the Earth disc's
    /// radiance times the sphere's view factor gives M1.5's
    /// albedo (R/r)² × lit × cos θ × E⊙, and sky and floor are M1.5's
    /// relative terms times E⊙.
    func testVesselStandInIsTheLegacyLightInLux() throws {
        let s = try scene("as506-parking-orbit")
        let v = try XCTUnwrap(s.vessels.first)
        let l = StandInLighting.vessel(v, in: s)
        let e = s.sun.illuminance
        XCTAssertEqual(l.sunlit, v.light.sunlit)
        XCTAssertGreaterThan(l.earthSinSigma2, 0.9, "the Earth fills most of the lower sky at 185 km")
        XCTAssertLessThan(l.earthSinSigma2, 1)
        // Facing the nadir the whole disc is above the horizon: M1.5's
        // value. Tilted, the horizon cuts the disc, where M1.5's cos θ
        // undercounts what stays visible.
        for theta in [0.0, 0.3, 0.6, 1.4] {
            let fromDisc = Double(l.earthRadiance.g) * BRDF.sphereIrradiance(cosTheta: cos(theta), sinSigma2: l.earthSinSigma2)
            let legacy = e * v.light.earthStrength * v.light.earthLit * Double(v.light.earthColor.g) * cos(theta)
            if theta == 0 {
                XCTAssertEqual(fromDisc, legacy, accuracy: 1e-3 * max(legacy, 1))
            } else {
                XCTAssertGreaterThanOrEqual(fromDisc, legacy * (1 - 1e-6))
            }
        }
        XCTAssertEqual(l.floor, e * Double(LegacyLighting.ambientFloor), accuracy: 1e-9 * e)
        XCTAssertEqual(l.sky, e * v.light.sky, accuracy: 1e-9 * e)
    }

    /// The pad's light: the Sun's share from its elevation, the ground's
    /// lit radiance below (albedo 0.3), sea-level sky in daylight; at the
    /// AS-506 launch the Sun stands well up.
    func testSiteStandIn() throws {
        let s = try scene("as506-pad", sites: [LC39A.placement()])
        let site = try XCTUnwrap(s.sites.first)
        let l = StandInLighting.site(site, in: s)
        XCTAssertEqual(l.sunlit, 1)
        XCTAssertEqual(l.earthSinSigma2, 1)
        XCTAssertEqual(l.earthDirection.dot(site.orientation.c2), -1, accuracy: 1e-9)
        XCTAssertEqual(Double(l.earthRadiance.r), s.sun.illuminance * 0.3 * 0.78 / Double.pi, accuracy: 1)
        XCTAssertGreaterThan(l.sky, 0.1 * s.sun.illuminance, "a clear morning sky")
        // The same site with the Sun turned below its horizon.
        var night = s
        night.sun.direction = -site.orientation.c2
        let dark = StandInLighting.site(site, in: night)
        XCTAssertEqual(dark.sunlit, 0)
        XCTAssertEqual(dark.sky, 0)
        XCTAssertEqual(Double(dark.earthRadiance.g), 0)
        // A whole lower half-space: π (1 + cos θ) / 2 of its radiance.
        XCTAssertEqual(BRDF.sphereIrradiance(cosTheta: 0, sinSigma2: 1), Double.pi / 2, accuracy: 1e-6)
        XCTAssertEqual(BRDF.sphereIrradiance(cosTheta: 1, sinSigma2: 1), Double.pi, accuracy: 1e-6)
    }

    /// Every finish the dressed Apollo vehicles and the pad use has its own
    /// row (none falls back); metals and dielectrics where expected.
    func testMaterialDefaultsCoverEveryFinish() {
        var keys = Set<MaterialKey>()
        for variant in [ApolloVariant.apollo8, .apollo11] {
            let stack = VesselLibrary.saturnV()
            for p in stack.parts { p.appearance = variant }
            VesselLibrary.dressApollo(stack)
            for p in stack.parts { for s in p.shapes { keys.insert(s.material) } }
        }
        for e in LC39A.elements { for s in e.shapes { keys.insert(s.material) } }
        keys.remove(.unspecified)
        for k in keys { XCTAssertNotNil(MaterialDefaults.table[k], "no shading for \(k)") }
        XCTAssertEqual(MaterialDefaults.entry(for: .apolloCMFoil).model, .metal)
        XCTAssertEqual(MaterialDefaults.entry(for: .apolloWhitePaint).model, .dielectric)
        XCTAssertEqual(MaterialDefaults.entry(for: .apolloCMWindow).model, .glass)
    }

    /// VM1's evaluator as vertex ids: ids round-trip; the S-IC carries its
    /// black and white roll pattern; ids pack into vertex v2's float.
    func testPaintIdsFromTheMarkings() {
        for c in PaintColour.allCases {
            XCTAssertEqual(PaintStandIn.colour(PaintStandIn.id(c)), c)
        }
        XCTAssertNil(PaintStandIn.colour(0))
        let stack = VesselLibrary.saturnV()
        for p in stack.parts { p.appearance = .apollo11 }
        VesselLibrary.dressApollo(stack)
        let sic = stack.parts.first { $0.name == "S-IC" }!
        var seen = Set<UInt8>()
        for shape in sic.shapes {
            let ids = PaintStandIn.ids(part: sic.name, shape: shape, mesh: shape.mesh(),
                                       partOffset: sic.offset - stack.structureOrigin, variant: .apollo11)
            XCTAssertEqual(ids.count, shape.mesh().vertices.count)
            seen.formUnion(ids)
        }
        XCTAssertTrue(seen.contains(PaintStandIn.id(.white)))
        XCTAssertTrue(seen.contains(PaintStandIn.id(.black)))
        let packed = SurfaceIDs(material: 200, paint: PaintStandIn.id(.black), decal: 0).packed
        XCTAssertEqual(SurfaceIDs(packed: packed).paint, PaintStandIn.id(.black))
    }

    /// A spec may give any member of the settings, or none.
    func testShadingSettingsDecodePartially() throws {
        let s = try JSONDecoder().decode(ShadingSettings.self, from: Data(#"{"plumeLights": 3}"#.utf8))
        XCTAssertEqual(s.plumeLights, 3)
        XCTAssertTrue(s.specularAntiAliasing)
        XCTAssertEqual(s.wireMinimumRadius, 0.7)
        XCTAssertEqual(try JSONDecoder().decode(ShadingSettings.self, from: Data("{}".utf8)), ShadingSettings())
    }
}
