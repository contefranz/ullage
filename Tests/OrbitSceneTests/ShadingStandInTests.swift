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

    /// AS-506 at first motion: one light per F-1, along the exhaust from
    /// its exit, of the order of 10⁸ cd each (P2's look: a sooty flame of
    /// some 3 m across and tens of metres glowing at about 1e6 cd/m², some
    /// 40 times sunlit white paint), so the five light the pad at about a
    /// megalux from 30 m. The cluster is lit as one light, its intensity
    /// the five's, its column holding all five exits.
    func testF1PlumesLightThePadAtLiftoff() throws {
        let s = try scene("as506-pad", advance: 0.5)
        let each: [PlumeLight] = s.emitters.compactMap { PlumeLights.light($0) }
        XCTAssertEqual(each.count, 5)
        for l in each {
            let e = try XCTUnwrap(s.emitters.min { a, b in
                let da = (a.exit + a.axis * (0.5 * l.length) - l.centre).length
                let db = (b.exit + b.axis * (0.5 * l.length) - l.centre).length
                return da < db
            })
            let offset = (e.exit + e.axis * (0.5 * l.length) - l.centre).length
            XCTAssertEqual(offset, 0, accuracy: 1e-6)
            XCTAssertEqual(l.axis.dot(e.axis), 1, accuracy: 1e-9)
            XCTAssertGreaterThan(l.luminousIntensity, 2e6)
            XCTAssertLessThan(l.luminousIntensity, 5e8)
            let r = Double(l.intensity.r), g = Double(l.intensity.g), b = Double(l.intensity.b)
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            XCTAssertEqual(luminance, l.luminousIntensity, accuracy: 1e-3 * l.luminousIntensity)
            XCTAssertGreaterThan(l.intensity.r, l.intensity.b, "a flame is warm")
        }
        let total = each.reduce(0) { $0 + $1.luminousIntensity }
        XCTAssertGreaterThan(total / (30 * 30), 1e4, "lux at 30 m")
        XCTAssertLessThan(total / (30 * 30), 3e6)
        let lights = PlumeLights.lights(s)
        XCTAssertEqual(lights.count, 1, "the five F-1s as one cluster")
        // Within 1 %: a single F-1 slows to rest in the air sooner than the
        // five's jet, so it is handed over to the trail a little earlier.
        XCTAssertEqual(lights[0].luminousIntensity, total, accuracy: 1e-2 * total)
        for e in s.emitters {
            let d = e.exit - lights[0].centre
            let across = (d - lights[0].axis * d.dot(lights[0].axis)).length
            XCTAssertLessThanOrEqual(across + e.exitRadius, lights[0].radius + 1e-9)
        }
        XCTAssertLessThanOrEqual(PlumeLights.lights(s, maximum: 0).count, 0)
    }

    /// A J-2 in vacuum (hydrogen, nearly invisible) gives no light; an F-1
    /// at sea level glows far brighter than it.
    func testHydrogenPlumeIsFaint() {
        func cluster(_ e: ApolloExhaust.Engine, _ air: AtmosphereState) -> PlumeCluster {
            let state = PlumeModel.state(e.spec, flowFraction: 1, ambient: air)
            return PlumeClusters.cluster([PlumeLook.member(e.spec, state: state, exit: .zero, axis: .unitX,
                                                           exitRadius: e.spec.exitRadius, ambient: air)])
        }
        let sea = USStandardAtmosphere1976().state(altitude: 0)
        XCTAssertNil(PlumeLights.light(cluster(ApolloExhaust.j2, .vacuum)))
        XCTAssertNotNil(PlumeLights.light(cluster(ApolloExhaust.f1, sea)))
        XCTAssertFalse(PlumeLights.glows(.hydrogen))
        XCTAssertFalse(PlumeLights.glows(.coldGas))
    }

    /// The vessel stand-in is M1.5's lighting in lux, with the ground lit
    /// at the Sun's mean cosine over the disc instead of M1.5's lit share:
    /// the Earth disc's radiance times the sphere's view factor gives
    /// albedo (R/r)² × mean cosine × cos θ × R1's Sun, and the sky is
    /// M1.5's term times E⊙. The night floor stays relative to the
    /// exposure: 0.02 of its white on a white surface, whatever the
    /// exposure.
    func testVesselStandInIsTheLegacyLightInLux() throws {
        let s = try scene("as506-parking-orbit")
        let v = try XCTUnwrap(s.vessels.first)
        let l = StandInLighting.vessel(v, in: s)
        let e = s.sun.illuminance
        XCTAssertEqual(l.sunlit, v.light.sunlit)
        XCTAssertGreaterThan(l.earthSinSigma2, 0.9, "the Earth fills most of the lower sky at 185 km")
        XCTAssertLessThan(l.earthSinSigma2, 1)
        XCTAssertEqual(l.earthLitCosine, StandInLighting.litCosine(toBody: l.earthDirection,
                                                                   sinSigma2: l.earthSinSigma2, toSun: l.toSun))
        XCTAssertEqual(Double(l.earthReflectance.g), 0.3 * Double(v.light.earthColor.g) / Double.pi, accuracy: 1e-7)
        // Facing the nadir the whole disc is above the horizon: M1.5's
        // value with the mean cosine for the lit share. Tilted, the horizon
        // cuts the disc, where M1.5's cos θ undercounts what stays visible.
        let sun = e * Photometry.sunColor.g * l.earthLitCosine
        for theta in [0.0, 0.3, 0.6, 1.4] {
            let fromDisc = Double(l.earthRadiance.g) * BRDF.sphereIrradiance(cosTheta: cos(theta), sinSigma2: l.earthSinSigma2)
            let legacy = sun * v.light.earthStrength * Double(v.light.earthColor.g) * cos(theta)
            if theta == 0 {
                XCTAssertEqual(fromDisc, legacy, accuracy: 1e-3 * max(legacy, 1))
            } else {
                XCTAssertGreaterThanOrEqual(fromDisc, legacy * (1 - 1e-6))
            }
        }
        XCTAssertEqual(l.floor, 0.02, accuracy: 1e-9)
        for p in [1e-5, 2.54e-5, 1e-3] {
            let shown = BRDF.lambert(albedo: 1) * StandInLighting.floorIlluminance(l.floor, preExposure: p) * p
            XCTAssertEqual(shown, 0.02, accuracy: 1e-12)
        }
        XCTAssertEqual(l.sky, e * v.light.sky, accuracy: 1e-9 * e)
    }

    /// The pad's light: the Sun's share from its elevation, the ground
    /// below (albedo 0.3) lit at the Sun's elevation's sine, sea-level sky
    /// in daylight; at the AS-506 launch the Sun stands well up.
    func testSiteStandIn() throws {
        let s = try scene("as506-pad", sites: [LC39A.placement()])
        let site = try XCTUnwrap(s.sites.first)
        let l = StandInLighting.site(site, in: s)
        XCTAssertEqual(l.sunlit, 1)
        XCTAssertEqual(l.earthSinSigma2, 1)
        XCTAssertEqual(l.earthDirection.dot(site.orientation.c2), -1, accuracy: 1e-9)
        let elevation = site.orientation.c2.normalized.dot(s.sun.direction)
        XCTAssertGreaterThan(elevation, 0.3)
        XCTAssertEqual(l.earthLitCosine, elevation, accuracy: 1e-9, "flat ground: the Sun's elevation's sine")
        XCTAssertEqual(Double(l.earthRadiance.r),
                       s.sun.illuminance * Photometry.sunColor.r * elevation * 0.3 * 0.78 / Double.pi, accuracy: 1)
        XCTAssertGreaterThan(l.sky, 0.1 * s.sun.illuminance, "a clear morning sky")
        // The same site with the Sun turned below its horizon.
        var night = s
        night.sun.direction = -site.orientation.c2
        let dark = StandInLighting.site(site, in: night)
        XCTAssertEqual(dark.sunlit, 0)
        XCTAssertEqual(dark.sky, 0)
        XCTAssertEqual(dark.floor, 0.02, "the night floor stays")
        XCTAssertEqual(Double(dark.earthRadiance.g), 0)
        XCTAssertEqual(dark.earthLitCosine, 0)
        // A whole lower half-space: π (1 + cos θ) / 2 of its radiance.
        XCTAssertEqual(BRDF.sphereIrradiance(cosTheta: 0, sinSigma2: 1), Double.pi / 2, accuracy: 1e-6)
        XCTAssertEqual(BRDF.sphereIrradiance(cosTheta: 1, sinSigma2: 1), Double.pi, accuracy: 1e-6)
    }

    /// The Sun's mean cosine over a sphere's disc, against closed forms: on
    /// the ground the Sun's elevation's sine; from afar the Lambert disc's
    /// 2/3 at full phase and 2/(3π) at quarter phase, 0 when new; from low
    /// orbit under a Sun at the zenith, between the cosine at the disc's
    /// edge, cos γ (γ = acos(R/r) from the centre), and 1.
    func testLitCosine() {
        let down = -Vec3.unitZ
        for elevation in [-0.2, 0.0, 0.12, 0.5, 1.2] {
            let toSun = Vec3(cos(elevation), 0, sin(elevation))
            XCTAssertEqual(StandInLighting.litCosine(toBody: down, sinSigma2: 1, toSun: toSun), max(sin(elevation), 0),
                           accuracy: 1e-12, "ground, elevation \(elevation)")
        }
        let far = 1e-6
        XCTAssertEqual(StandInLighting.litCosine(toBody: down, sinSigma2: far, toSun: .unitZ), 2.0 / 3, accuracy: 0.005)
        XCTAssertEqual(StandInLighting.litCosine(toBody: down, sinSigma2: far, toSun: .unitX), 2 / (3 * Double.pi),
                       accuracy: 0.005)
        XCTAssertEqual(StandInLighting.litCosine(toBody: down, sinSigma2: far, toSun: down), 0, accuracy: 1e-12)
        let r = 6_556_000.0, radius = 6_371_000.0
        let leo = StandInLighting.litCosine(toBody: down, sinSigma2: pow(radius / r, 2), toSun: .unitZ)
        XCTAssertGreaterThan(leo, radius / r)
        XCTAssertLessThan(leo, 1)
        // The terminator through the nadir: half the disc lit, the Sun on
        // the horizon at the nadir and at most γ (14°) up at the disc's
        // edge, which takes little of the solid angle; M1.5's lit share
        // gave this ground half the light of a noon one.
        let terminator = StandInLighting.litCosine(toBody: down, sinSigma2: pow(radius / r, 2), toSun: .unitX)
        XCTAssertGreaterThan(terminator, 0.005)
        XCTAssertLessThan(terminator, sin(acos(radius / r)) / Double.pi)
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
