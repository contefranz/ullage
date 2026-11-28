import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// The launch cloud's optics (`LaunchCloudOptics`) and moist air
/// (`MoistAir`): the two-stream is C2's where the medium does not absorb,
/// conserves energy where it does; saturation over water is IAPWS-95's; the
/// adjustment conserves water and heat.
final class LaunchCloudOpticsTests: XCTestCase {
    // The two-stream with absorption is C2's (Bohren's, `CloudLighting.
    // streams`) at albedo 1, at every depth of slabs from thin to very
    // thick, and its reflectance C1's slab reflectance.
    func testTwoStreamIsC2sAtAlbedoOne() {
        let c2 = CloudLighting()
        for tau in [0.0, 0.01, 0.5, 3, 30, 300, 3_000] {
            for f in [0.0, 0.1, 0.5, 0.9, 1] {
                let a = LaunchCloudOptics.streams(depth: f * tau, column: tau, albedo: 1, asymmetry: c2.asymmetry)
                let b = c2.streams(depth: f * tau, column: tau)
                XCTAssertEqual(a.down, b.down, accuracy: 1e-12, "τ \(tau), t \(f * tau)")
                XCTAssertEqual(a.up, b.up, accuracy: 1e-12, "τ \(tau), t \(f * tau)")
            }
            let slab = LaunchCloudOptics.slab(column: tau, albedo: 1, asymmetry: c2.asymmetry)
            XCTAssertEqual(slab.reflectance, CloudOptics.slabReflectance(opticalDepth: tau, asymmetry: c2.asymmetry),
                           accuracy: 1e-12)
            XCTAssertEqual(slab.reflectance + slab.transmittance, 1, accuracy: 1e-12, "no absorption")
        }
    }

    // Absorbing (soot), the slab conserves energy: what enters its top less
    // what leaves it, up through the top and down through the bottom, is
    // what it absorbs, (1 − ω) ∫(F↓ + F↑) dτ; a semi-infinite slab reflects
    // (γ1 − k)/γ2; and the thick branch joins the thin one.
    func testTwoStreamConservesEnergyWhenAbsorbing() {
        for (omega, g) in [(0.99, 0.85), (0.72, 0.8), (0.2, 0.4)] {
            for tau in [0.3, 4.0, 40] {
                let s = LaunchCloudOptics.slab(column: tau, albedo: omega, asymmetry: g)
                let n = 20_000, dt = tau / Double(n)
                var absorbed = 0.0
                for i in 0..<n {
                    let f = LaunchCloudOptics.streams(depth: (Double(i) + 0.5) * dt, column: tau, albedo: omega,
                                                      asymmetry: g)
                    absorbed += (1 - omega) * (f.down + f.up) * dt
                }
                XCTAssertEqual(1 - s.reflectance - s.transmittance, absorbed, accuracy: 1e-6, "ω \(omega), τ \(tau)")
                XCTAssertLessThan(s.reflectance + s.transmittance, 1)
            }
            let b = (1 - g) / 2, g1 = 1 - omega * (1 - b), g2 = omega * b, k = (g1 * g1 - g2 * g2).squareRoot()
            let deep = LaunchCloudOptics.slab(column: 1e4, albedo: omega, asymmetry: g)
            XCTAssertEqual(deep.reflectance, (g1 - k) / g2, accuracy: 1e-9)
            // Either side of the switch to the thick branch, kτ = 30.
            let tau = 30 / k
            let a = LaunchCloudOptics.streams(depth: 0.3 * tau, column: tau * (1 - 1e-9), albedo: omega, asymmetry: g)
            let c = LaunchCloudOptics.streams(depth: 0.3 * tau, column: tau * (1 + 1e-9), albedo: omega, asymmetry: g)
            XCTAssertEqual(a.down, c.down, accuracy: 1e-7)
            XCTAssertEqual(a.up, c.up, accuracy: 1e-7)
        }
    }

    // The medium's optics from its mass: droplets of 10 µm at 150 m²/kg
    // (3 Q / 4 ρ r), soot at 7.5 m²/g and 0.2 albedo; a cloud of water
    // alone scatters as C2's.
    func testOpticsFromMass() {
        XCTAssertEqual(LaunchCloudOptics.dropletExtinction, 150, accuracy: 1e-9)
        let water = LaunchCloudOptics.optics(.init(condensate: 1e-3, soot: 0, temperature: 300))
        XCTAssertEqual(water.extinction, 0.15, accuracy: 1e-12)
        XCTAssertEqual(water.albedo, 1)
        XCTAssertEqual(water.asymmetry, CloudLighting().asymmetry)
        let soot = LaunchCloudOptics.optics(.init(condensate: 0, soot: 1e-5, temperature: 300))
        XCTAssertEqual(soot.extinction, 0.075, accuracy: 1e-12)
        XCTAssertEqual(soot.albedo, 0.2, accuracy: 1e-12)
        // Mixed: the albedo is the extinctions' weighting.
        let both = LaunchCloudOptics.optics(.init(condensate: 1e-3, soot: 1e-5, temperature: 300))
        XCTAssertEqual(both.albedo, (0.15 + 0.2 * 0.075) / 0.225, accuracy: 1e-12)
        XCTAssertEqual(LaunchCloudOptics.phase(0.3, dropletShare: 1), LaunchCloudOptics.dropletPhase.phase(0.3))
        // The phase integrates to one over the sphere (μ = 1 − 2u², to
        // resolve the droplets' diffraction peak).
        var sum = 0.0
        let n = 40_000
        for i in 0..<n {
            let u = (Double(i) + 0.5) / Double(n)
            sum += LaunchCloudOptics.phase(1 - 2 * u * u, dropletShare: 0.6) * 2 * .pi * 4 * u / Double(n)
        }
        XCTAssertEqual(sum, 1, accuracy: 2e-3)
        // Cold soot gives off nothing; hot soot its absorption's blackbody.
        XCTAssertEqual(LaunchCloudOptics.emission(.init(condensate: 0, soot: 1e-5, temperature: 290)).luminance, 0)
        XCTAssertGreaterThan(LaunchCloudOptics.emission(.init(condensate: 0, soot: 1e-5, temperature: 1_200)).luminance, 0)
    }

    // The soot yield is P2's (decision 4, until LR5 PR1's renders choose):
    // its plume's soot depth across an F-1 exit, 8, over 7.5 m²/g, the exit's
    // 3.55 m and P1's 0.078 kg/m³ at sea level, 0.38 %, a quarter of it left
    // by the flame: 0.096 % (the plan's study estimated 0.07 %).
    func testSootYieldIsP2s() {
        let f1 = ApolloExhaust.f1.spec
        let exit = PlumeModel.state(f1, flowFraction: 1, ambient: USStandardAtmosphere1976().state(altitude: 0),
                                    streamAlong: 0, streamAcross: 0)
        XCTAssertEqual(exit.exitDensity, 0.078, accuracy: 0.005)
        let column = LaunchCloudOptics.sootYield / PlumeLook.Optics.burntSoot * exit.exitDensity
            * LaunchCloudOptics.sootExtinction * 2 * f1.exitRadius
        XCTAssertEqual(column, PlumeLook.Optics.sootDepth * f1.sootIndex, accuracy: 1e-9, "P2's depth across the exit")
        XCTAssertEqual(LaunchCloudOptics.sootYield * 100, 0.096, accuracy: 0.005)
    }

    // Saturation over water is IAPWS-95's (its Table 8's check values and
    // the normal boiling point), within 0.01 %; below the triple point
    // Murphy and Koop's, continuous at it.
    func testSaturationPressureIsIAPWS95s() {
        for (t, p) in [(275.0, 698.451_167), (450, 932_203.564), (625, 16_908_269.3), (373.124, 101_325)] {
            XCTAssertEqual(MoistAir.saturationPressure(t), p, accuracy: 1e-4 * p, "\(t) K")
        }
        let below = MoistAir.saturationPressure(273.16 - 1e-9), above = MoistAir.saturationPressure(273.16)
        XCTAssertEqual(below, above, accuracy: 1e-6 * above)
        XCTAssertEqual(above, 611.657, accuracy: 0.01)
    }

    // The adjustment conserves the water and the heat: the condensate's
    // latent heat is the warming, c_p (T − T*) = L(T) q_c, and the vapour
    // left is saturated; an unsaturated mixture is left as it is.
    func testAdjustmentConservesWaterAndHeat() {
        for (t, qt, p) in [(300.0, 0.03, 101_325.0), (290, 0.02, 85_000), (285, 0.012, 80_000), (310, 0.06, 101_325)] {
            let a = MoistAir.adjust(temperature: t, water: qt, pressure: p)
            XCTAssertGreaterThan(a.condensate, 0)
            XCTAssertEqual(MoistAir.specificHeat * (a.temperature - t), MoistAir.latentHeat(a.temperature) * a.condensate,
                           accuracy: 1e-6)
            XCTAssertEqual(qt - a.condensate, MoistAir.saturationHumidity(a.temperature, pressure: p), accuracy: 1e-12)
        }
        let dry = MoistAir.adjust(temperature: 300, water: 0.01, pressure: 101_325)
        XCTAssertEqual(dry.temperature, 300)
        XCTAssertEqual(dry.condensate, 0)
    }
}
