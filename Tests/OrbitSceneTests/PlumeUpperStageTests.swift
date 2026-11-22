import XCTest
import OrbitCore
@testable import OrbitScene

/// The upper stages' plumes from their physics (2026-11-22): the J-2's
/// water freezing as it expands into vacuum (onset at saturation over ice,
/// Mie scattering of sunlight), its chamber's gas glowing through the
/// throat, and the F-1s' wall jet on the Mobile Launcher's deck at liftoff;
/// against Bohren and Huffman's Mie, Marti and Mauersberger's ice pressure,
/// Wu's onset, the HITRAN-based chamber luminance and the round jet's
/// spread.
final class PlumeUpperStageTests: XCTestCase {
    let us76 = USStandardAtmosphere1976()
    let sunlitWhite = Photometry.solarIlluminanceAt1AU / Double.pi

    func member(_ engine: ApolloExhaust.Engine, altitude: Double? = nil, flow: Double = 1) -> PlumeMember {
        let a = altitude.map { us76.state(altitude: $0) } ?? .vacuum
        let s = PlumeModel.state(engine.spec, flowFraction: flow, ambient: a)
        return PlumeLook.member(engine.spec, state: s, exit: .zero, axis: .unitX, exitRadius: engine.spec.exitRadius,
                                ambient: a)
    }

    /// Side-on through x, lit by the Sun across the plume (lux, white).
    func sideOn(_ m: PlumeMember, x: Double, sun: Double = 128_000) -> (light: Photometry.RGB, transmittance: Double) {
        let r = m.extent(atX: x) + 1
        let seen = PlumeLook.march([m], from: Vec3(x, -r, 0), direction: Vec3(0, 1, 0), range: 0...(2 * r), steps: 400,
                                   sun: sun > 0 ? (Vec3(0, 0, 1), Photometry.RGB(sun, sun, sun)) : nil)
        return (seen.radiance, seen.transmittance)
    }

    // MARK: Ice

    /// Bohren and Huffman's BHMIE example (m 1.55, x 5.213): Qext = Qsca =
    /// 3.10543, g 0.63314; and the Rayleigh limit, Qsca = 8/3 x⁴ |K|².
    func testMieIsBohrenAndHuffmans() {
        let q = Mie.efficiencies(sizeParameter: 5.213, index: 1.55)
        XCTAssertEqual(q.extinction, 3.10543, accuracy: 2e-3)
        XCTAssertEqual(q.scattering, 3.10543, accuracy: 2e-3)
        XCTAssertEqual(q.asymmetry, 0.63314, accuracy: 5e-4)
        let x = 0.02, m2 = 1.31 * 1.31, k = (m2 - 1) / (m2 + 2)
        let small = Mie.efficiencies(sizeParameter: x, index: 1.31)
        XCTAssertEqual(small.scattering / (8.0 / 3 * pow(x, 4) * k * k), 1, accuracy: 0.01)
        XCTAssertEqual(small.asymmetry, 0, accuracy: 0.01)
    }

    /// Murphy and Koop's ice pressure against Marti and Mauersberger's
    /// measurements (1993: log10 p = -2663.5/T + 12.537 Pa, 170-250 K),
    /// within 3 %; the triple point, 611.657 Pa.
    func testIceSaturationIsMeasured() {
        for t in stride(from: 170.0, through: 250, by: 10) {
            let measured = pow(10, -2_663.5 / t + 12.537)
            XCTAssertEqual(PlumeLook.Ice.saturationPressure(t) / measured, 1, accuracy: 0.03, "\(t) K")
        }
        XCTAssertEqual(PlumeLook.Ice.saturationPressure(273.16), 611.657, accuracy: 0.6)
    }

    /// The J-2's water saturates as its free expansion cools it 60-80 m
    /// out on the axis: Wu (1975) put condensation's onset 41-55 m from the
    /// S-IVB's nozzle; within half again of that range. Before it no ice,
    /// beyond it the water's share of 10 % (Kung et al.), as dense as the
    /// gas; the plume's thin outer layer freezes first (a conical shell).
    func testJ2FreezesNearWusOnset() throws {
        let m = member(ApolloExhaust.j2)
        let onset = try XCTUnwrap(m.condensationOnset)
        print(String(format: "PlumeUpperStageTests: the J-2's ice from %.0f m on the axis (Wu: 41-55 m)", onset))
        XCTAssertGreaterThan(onset, 41 / 1.5)
        XCTAssertLessThan(onset, 55 * 1.5)
        XCTAssertEqual(m.sample(x: 0.5 * onset, r: 0).scattering, 0, accuracy: 1e-15, "no ice yet")
        XCTAssertGreaterThan(m.sample(x: 3 * onset, r: 0).scattering, 0)
        // Off the axis, where the gas is thinner, it has frozen already.
        let x = 0.6 * onset, off = 0.6 * m.extent(atX: x)
        XCTAssertGreaterThan(m.sample(x: x, r: off).scattering, 0, "the shell")
        // The ice's mass: 10 % of the exhaust's water (CEA's mole fraction).
        let s = PlumeModel.state(ApolloExhaust.j2.spec, flowFraction: 1, ambient: .vacuum)
        let water = ApolloExhaust.j2.spec.waterFraction * 0.018015 / ApolloExhaust.j2.spec.molarMass
        XCTAssertEqual(water, 0.917, accuracy: 0.005)
        XCTAssertEqual(m.particleExtinction,
                       PlumeLook.Ice.optics.massScattering * 0.1 * water * s.exitDensity, accuracy: 1e-9)
    }

    /// In sunlight the J-2's ice is seen side-on 100 m out, above the least
    /// light a chase camera's daylight exposure shows (EV 15, 79 cd/m²),
    /// bluish (Mie at 0.1 µm); thin (it shows through); in the Earth's
    /// shadow it gives nothing.
    func testSunlitJ2IceIsSeen() {
        let m = member(ApolloExhaust.j2)
        let lit = sideOn(m, x: 100), dark = sideOn(m, x: 100, sun: 0)
        print(String(format: "PlumeUpperStageTests: the J-2's ice side-on at 100 m: %.0f cd/m² (%.2f %.2f %.2f), "
                     + "transmittance %.3f", lit.light.luminance, lit.light.r, lit.light.g, lit.light.b, lit.transmittance))
        XCTAssertGreaterThan(lit.light.luminance, 0.002 * 1.2 * pow(2, 15))
        XCTAssertLessThan(lit.light.luminance, 0.2 * sunlitWhite, "dimmer than sunlit paint")
        XCTAssertGreaterThan(lit.light.b, lit.light.g)
        XCTAssertGreaterThan(lit.light.g, lit.light.r)
        XCTAssertGreaterThan(lit.transmittance, 0.8)
        XCTAssertLessThan(dark.light.luminance, 1)
        // The trim keeps it at that exposure in sunlight (in the Earth's
        // shadow it still dims what lies behind it, and the chamber's glow
        // is the cue).
        var kept = m
        XCTAssertTrue(PlumeLook.trim(&kept, faintest: 0.002 * 1.2 * pow(2, 15), sun: 128_000))
    }

    // MARK: The chamber's glow

    /// The J-2's chamber gas seen through 0.5 m of it gives about 1.2×10⁴
    /// cd/m² at the rated flow (HITRAN 2020's water lines with the hot
    /// bands: 3×10³ to 2×10⁴), orange (the 590 and 650 nm bands); it
    /// follows the chamber's pressure, so the S-II's low mixture ratio and a
    /// shutdown dim it, and off it is dark.
    func testChamberGlow() throws {
        let spec = ApolloExhaust.j2.spec, chamber = try XCTUnwrap(ApolloExhaust.j2.chamber)
        let rated = ChamberGlow.emission(spec, flowFraction: 1).scaled(by: 0.5)
        XCTAssertGreaterThan(rated.luminance, 3e3)
        XCTAssertLessThan(rated.luminance, 2e4)
        XCTAssertGreaterThan(rated.r, rated.g)
        XCTAssertGreaterThan(rated.g, rated.b)
        XCTAssertEqual(ChamberGlow.emission(spec, flowFraction: 0.8).luminance / rated.luminance, 0.8 * 2, accuracy: 1e-9)
        XCTAssertEqual(ChamberGlow.emission(spec, flowFraction: 0).luminance, 0)
        // The light a surface behind the throat shows: the gas in front of it.
        let e = ChamberGlow.emission(spec, flowFraction: 1)
        XCTAssertEqual(ChamberGlow.luminance(e, chamber: chamber, depth: chamber.throatDepth - 0.1, cosine: 1).luminance,
                       0, "in front of the throat")
        let face = ChamberGlow.luminance(e, chamber: chamber, depth: chamber.injectorDepth, cosine: 1)
        XCTAssertEqual(face.luminance, e.luminance * (chamber.injectorDepth - chamber.throatDepth), accuracy: 1e-6)
    }

    // MARK: Liftoff

    /// The ML's deck in the test's frame: the opening's centre at the
    /// origin, up +z, its sides along x (north) and y, as LC39A has it.
    let deck = PlumeImpingement(centre: .zero, normal: .unitZ, openingHalf: 45 * 0.3048 / 2, openingAxis: .unitX)

    /// The S-IC's F-1s with their exits `height` above the deck (-3.24 m at
    /// rest): the centre one and the four outboard ones on the opening's
    /// diagonals, 182 in out (SaturnV.cluster: under fins A-D, Position II
    /// north), firing down; each meeting the deck as PlumeSystem has them.
    func sIC(height: Double) -> [PlumeMember] {
        let air = us76.state(altitude: 0)
        let s = PlumeModel.state(ApolloExhaust.f1.spec, flowFraction: 1, ambient: air)
        let d = 182 * 0.0254 / 2.squareRoot()
        let exits = [Vec3(0, 0, height)] + [(1.0, 1.0), (-1, 1), (-1, -1), (1, -1)].map {
            Vec3(d * $0.0, d * $0.1, height)
        }
        return exits.map { e in
            var m = PlumeLook.member(ApolloExhaust.f1.spec, state: s, exit: e, axis: -.unitZ,
                                     exitRadius: ApolloExhaust.f1.spec.exitRadius, ambient: air)
            m.impingement = deck.meeting(m)
            return m
        }
    }

    /// The F-1s' wall jet on the ML's deck: none while the exits are below
    /// the deck, in the opening, nor while an outboard jet still fits the
    /// opening (its exit 3.59 m from two of the square's sides; some 34 m of
    /// climb); as the vehicle climbs on, the share of each jet landing
    /// outside the opening grows; over the deck the wall jet's core is hot
    /// (it recovers 0.89 of its total temperature) and glows; inside the
    /// opening and beyond its reach the free jet takes the sample.
    func testWallJetOnTheDeck() throws {
        let heights = [-3.24, 20, 35, 50]
        let shares = heights.map { sIC(height: $0)[1].impingement?.deckShare ?? 0 }
        var low = 0.0, high = 60.0
        for _ in 0..<40 {
            let h = 0.5 * (low + high)
            if (sIC(height: h)[1].impingement?.deckShare ?? 0) > 0 { high = h } else { low = h }
        }
        print(String(format: "PlumeUpperStageTests: an outboard F-1's share on the deck at %@ m: "
                     + "%@; it meets the deck from %.1f m (%.1f m of climb)", heights.map { String(format: "%.2f", $0) }
                         .joined(separator: ", "),
                     shares.map { String(format: "%.3f", $0) }.joined(separator: ", "), high, high + 3.24))
        XCTAssertEqual(shares[0], 0, "inside the opening")
        XCTAssertEqual(shares[1], 0, "the jet fits the opening")
        XCTAssertGreaterThan(shares[2], shares[1])
        XCTAssertGreaterThan(shares[3], shares[2])
        XCTAssertGreaterThan(high, 25)
        XCTAssertLessThan(high, 35)

        let m = sIC(height: 35)[1]
        let impingement = try XCTUnwrap(m.impingement)
        XCTAssertEqual(PlumeImpingement.recovered(static: 1_500, total: 3_600), 1_500 + 0.89 * 2_100, accuracy: 1e-9)
        let d = m.exit.x, out = Vec3(d, d, 0).normalized
        let onDeck = m.sample(at: Vec3(d, d, 0) + out * 14 + Vec3(0, 0, 0.3))
        XCTAssertGreaterThan(onDeck.emission.luminance, 0, "the wall jet glows")
        XCTAssertNil(impingement.wallJet(m, at: Vec3(0, 0, 0.3)), "inside the opening")
        XCTAssertNil(impingement.wallJet(m, at: Vec3(d, d, 0) + out * (impingement.reach + 5) + Vec3(0, 0, 0.3)),
                     "beyond its reach")
        XCTAssertNil(impingement.wallJet(m, at: Vec3(d, d, 0) + out * 14 - Vec3(0, 0, 0.5)), "below the deck")
    }

    /// The merged far field meets the deck as its own column does: wherever
    /// the deck lies in the merged zone (past 1.15 mergeX, where the march
    /// reads the merged member alone) and an outboard jet meets it, so does
    /// the merged one, its share growing as the vehicle climbs until its
    /// reach is spent; and it is not the centre engine's (whose jet fits
    /// the opening longer).
    func testMergedFarFieldMeetsTheDeck() throws {
        var last = 0.0, merging = 0
        for h in stride(from: 0.0, through: 90, by: 1) {
            let members = sIC(height: h)
            let c = PlumeClusters.cluster(members, deck: deck)
            guard let merged = c.merged else { continue }
            let deckInMerged = h >= 1.15 * c.mergeX
            let outboard = members[1].impingement?.deckShare ?? 0
            let share = merged.impingement?.deckShare ?? 0
            if deckInMerged && outboard > 0 && (members[1].impingement?.reach ?? 0) > 0 {
                merging += 1
                XCTAssertNotNil(merged.impingement, "at \(h) m the merged far field meets the deck")
                XCTAssertGreaterThanOrEqual(share, last - 1e-9, "at \(h) m its share grows")
                XCTAssertNotEqual(merged.impingement, members[0].impingement, "not the centre engine's")
            }
            if merged.impingement != nil { last = share }
        }
        print("PlumeUpperStageTests: the merged far field met the deck at", merging, "heights")
        XCTAssertGreaterThan(merging, 5)
    }

    /// Beyond its core the jet's half-value radius grows as a round
    /// turbulent jet's, 0.094 (Hussein, Capp and George 1994), times P1's
    /// structure visibility (1 at sea level); the flame brush adds the
    /// mixing layer's outer half while it burns.
    func testFarFieldSpreadsAsARoundJet() {
        let m = member(ApolloExhaust.f1, altitude: 0)
        let x = 3 * m.coreLength + m.flameStart
        let slope = (m.radius(atX: x + 1) - m.radius(atX: x)) / 1
        XCTAssertEqual(m.farSpread, 0.094, accuracy: 1e-12)
        XCTAssertEqual(slope, 0.094 + m.flameSpread, accuracy: 2e-3)
        XCTAssertEqual(m.flameSpread, 0.5 * m.eddyGrowth * m.afterburning, accuracy: 1e-9)
    }
}
