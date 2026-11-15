import XCTest
import OrbitCore
@testable import OrbitScene

/// The plumes' look (P2) from P1's plume model, against what the
/// photographs show: the F-1's opaque flame and its dark film at the pad
/// (S68-56050, S69-39961), widening with altitude (KSC-69PC-413), its flame
/// gone above 40 km (P1's afterburning); the J-2 and the hypergols nearly
/// invisible in vacuum (S69-39958); the solids' incandescent cores; the
/// readable floor (decision 19), the legacy table (M1.5) and the blackbody
/// the shader uses. Luminances in cd/m²; a white surface facing the Sun at
/// 1 AU is E⊙/π, about 42,000.
final class PlumeLookTests: XCTestCase {
    let us76 = USStandardAtmosphere1976()
    let sunlitWhite = Photometry.solarIlluminanceAt1AU / Double.pi

    func member(_ engine: ApolloExhaust.Engine, altitude: Double? = nil, flow: Double = 1,
                readable: Bool = false) -> PlumeMember {
        let a = altitude.map { us76.state(altitude: $0) } ?? .vacuum
        let s = PlumeModel.state(engine.spec, flowFraction: flow, ambient: a)
        var m = PlumeLook.member(engine.spec, state: s, exit: Vec3(0, 0, 0), axis: Vec3(1, 0, 0),
                                 exitRadius: engine.spec.exitRadius, ambient: a)
        if readable { PlumeLook.applyReadableFloor(&m) }
        return m
    }

    /// The light through the plume side-on at x (m), and its transmittance.
    func sideOn(_ m: PlumeMember, x: Double) -> (luminance: Double, transmittance: Double, color: Photometry.RGB) {
        let r = m.extent(atX: x) + 1
        let seen = PlumeLook.march([m], from: Vec3(x, -r, 0), direction: Vec3(0, 1, 0), range: 0...(2 * r), steps: 400)
        return (seen.radiance.luminance, seen.transmittance, seen.radiance)
    }

    /// At the pad the F-1's flame is opaque and blinding (tens of times
    /// sunlit paint, yellow-white: warm), behind a dark band of the
    /// turbine-exhaust film within an exit diameter of the nozzle.
    func testF1AtThePad() {
        let m = member(ApolloExhaust.f1, altitude: 0)
        let de = m.exitDiameter
        let flame = sideOn(m, x: 2 * de), film = sideOn(m, x: 0.3 * de)
        XCTAssertLessThan(flame.transmittance, 0.01, "opaque")
        XCTAssertGreaterThan(flame.luminance, 20 * sunlitWhite, "blinding")
        XCTAssertGreaterThan(flame.color.r, flame.color.b, "warm")
        XCTAssertLessThan(film.luminance, 0.1 * flame.luminance, "the film's dark band")
        XCTAssertEqual(m.flameStart, 0.75 * de, accuracy: 1e-9, "P1's flame front")
        // The flame holds above about 1,900 K for 35-40 m (S68-56050), then
        // cools: far down it is smoke, dimmer than sunlit paint.
        XCTAssertGreaterThan(sideOn(m, x: 30).luminance, 5 * sunlitWhite)
        XCTAssertLessThan(sideOn(m, x: 0.9 * m.length).luminance, sunlitWhite)
        XCTAssertGreaterThan(m.length, 60)
        XCTAssertLessThan(m.length, 300)
    }

    /// The F-1's plume widens with altitude and its flame lengthens (P1's
    /// boundary angle, jet diameter and potential core); above 40 km the
    /// afterburning is gone (P1) and so is the bright flame.
    func testF1WidensWithAltitude() {
        let altitudes = [0.0, 13_000, 30_000]
        let members = altitudes.map { member(ApolloExhaust.f1, altitude: $0) }
        let x = 20 * ApolloExhaust.f1.spec.exitRadius * 2
        for (a, b) in zip(members, members.dropFirst()) {
            XCTAssertGreaterThan(b.radius(atX: 0.25 * x), a.radius(atX: 0.25 * x), "near the exit")
            XCTAssertGreaterThan(b.length, a.length)
        }
        XCTAssertGreaterThan(members[2].radius(atX: x), 1.5 * members[0].radius(atX: x))
        XCTAssertGreaterThan(members[2].radius(atX: x), 5, "each plume wider than the vehicle after max-Q")
        let high = member(ApolloExhaust.f1, altitude: 45_000)
        XCTAssertEqual(high.afterburning, 0)
        XCTAssertLessThan(sideOn(high, x: 2 * high.exitDiameter).luminance,
                          0.01 * sideOn(members[0], x: 2 * members[0].exitDiameter).luminance)
    }

    /// In vacuum the J-2's, the SPS's and the RCS jets' plumes are nearly
    /// invisible: under 0.3 % of sunlit paint unlit; readable, each glows at
    /// least M1.5's 0.3 of it near its exit.
    func testClearExhaustsNearlyInvisibleUnlessReadable() {
        for engine in [ApolloExhaust.j2, ApolloExhaust.sps, ApolloExhaust.smRCS, ApolloExhaust.cmRCS] {
            let m = member(engine)
            let x = 0.5 * m.exitDiameter
            XCTAssertLessThan(sideOn(m, x: x).luminance, 0.003 * sunlitWhite, "\(engine.spec.source)")
            XCTAssertGreaterThan(sideOn(m, x: x).transmittance, 0.95)
            let readable = member(engine, readable: true)
            XCTAssertGreaterThan(sideOn(readable, x: x).luminance, 0.95 * PlumeLook.readableFloor,
                                 "\(engine.spec.source) readable")
        }
        XCTAssertEqual(PlumeLook.readableFloor, 0.3 * sunlitWhite, accuracy: 1e-9)
    }

    /// The J-2 shows a Mach disk only where one forms: in air at 25 km,
    /// not in vacuum, and only faintly far downstream in the thin air of
    /// S-II ignition.
    func testMachDiskOnlyWhereOneForms() {
        let air = member(ApolloExhaust.j2, altitude: 25_000)
        XCTAssertGreaterThan(air.machDiskExtinction, 0)
        let disk = sideOn(air, x: air.machDiskDistance)
        XCTAssertGreaterThan(disk.luminance, 10 * sideOn(air, x: 0.5 * air.machDiskDistance).luminance)
        XCTAssertEqual(member(ApolloExhaust.j2).machDiskExtinction, 0)
        let thin = member(ApolloExhaust.j2, altitude: 67_000)
        XCTAssertLessThan(thin.machDiskExtinction, 0.01 * air.machDiskExtinction)
    }

    /// The solids' aluminium-oxide cores glow white-hot at their exits in
    /// near-vacuum (the retros at S-IC/S-II separation, the S-II ullage
    /// motors, the LES's tower jettison motor); their smoke scatters.
    func testSolidsHaveIncandescentCores() {
        for (engine, altitude) in [(ApolloExhaust.sICRetro, 65_000.0), (ApolloExhaust.towerJettison, 90_000),
                                   (ApolloExhaust.sIIUllage, 65_000)] {
            let m = member(engine, altitude: altitude)
            XCTAssertEqual(m.family, .solid)
            XCTAssertGreaterThan(m.particleTemperature, 1_900)
            XCTAssertGreaterThan(sideOn(m, x: 0.5 * m.exitDiameter).luminance, 2 * sunlitWhite, engine.spec.source)
            XCTAssertGreaterThan(m.particleAlbedo, 0.8)
        }
    }

    /// P1's chamber pressure follows the flow: at 30 % of it the F-1's
    /// plume carries less soot and is no longer.
    func testTransientsShrinkThePlume() {
        let full = member(ApolloExhaust.f1, altitude: 0), low = member(ApolloExhaust.f1, altitude: 0, flow: 0.3)
        XCTAssertLessThan(low.gasExtinction, full.gasExtinction)
        XCTAssertLessThanOrEqual(low.length, full.length)
    }

    /// The legacy look is M1.5's table: at the pad an F-1 glows at 0.75 of
    /// E⊙/π through its axis in kerosene's colour, 24 exit radii long; a
    /// J-2 in vacuum at the 0.35 the floor of 0.3 does not raise.
    func testLegacyReproducesTheM15Table() {
        let f1 = PlumeLook.legacy(exit: .zero, axis: .unitX, radius: 1.78, family: .kerosene, fraction: 1,
                                  pressureRatio: 1, jet: false)
        XCTAssertEqual(f1.glow.luminance, 0.75 * sunlitWhite, accuracy: 1e-6 * sunlitWhite)
        XCTAssertEqual(f1.length, 24 * 1.78, accuracy: 1e-9)
        let j2 = PlumeLook.legacy(exit: .zero, axis: .unitX, radius: 0.98, family: .hydrogen, fraction: 1,
                                  pressureRatio: 0, jet: false)
        XCTAssertEqual(j2.glow.luminance, 0.35 * sunlitWhite, accuracy: 1e-6 * sunlitWhite)
        XCTAssertEqual(j2.length, 12 * 0.98, accuracy: 1e-9)
        // The light through the axis near the exit is the table's.
        let seen = PlumeLook.march([j2], from: Vec3(3, -5, 0), direction: Vec3(0, 1, 0), range: 0...10, steps: 2_000)
        XCTAssertEqual(seen.radiance.luminance, 0.35 * sunlitWhite * pow(1 - 3 / j2.length, 1.6),
                       accuracy: 0.1 * sunlitWhite)
    }

    /// The shader's blackbody, Wien per channel, against Photometry's
    /// integration over 1,200-3,500 K: luminance within 6 %, red over green
    /// within 6 %, and blue over green within 20 % from 2,000 K, below which
    /// Rec. 709 clips blue.
    func testBlackbodyFit() {
        for t in stride(from: 1_200.0, through: 3_500, by: 100) {
            let fit = PlumeLook.blackbody(t), ref = Photometry.blackbody(t)
            let c = ref.color.scaled(by: ref.luminance)
            XCTAssertEqual(fit.luminance, ref.luminance, accuracy: 0.06 * ref.luminance, "\(t) K")
            XCTAssertEqual(fit.r / fit.g, c.r / c.g, accuracy: 0.06 * c.r / c.g, "\(t) K red")
            if t >= 2_000 {
                XCTAssertEqual(fit.b / fit.g, c.b / c.g, accuracy: 0.2 * c.b / c.g + 1e-3, "\(t) K blue")
            }
        }
        XCTAssertEqual(PlumeLook.blackbody(250).luminance, 0)
    }

    /// The field outside a member's extent is nothing, and its length is
    /// finite.
    func testExtentHoldsTheField() {
        let cases: [(ApolloExhaust.Engine, Double?)] = [(ApolloExhaust.f1, 0), (ApolloExhaust.f1, 30_000),
                                                        (ApolloExhaust.j2, nil), (ApolloExhaust.sICRetro, 65_000)]
        for (engine, altitude) in cases {
            let m = member(engine, altitude: altitude)
            for i in 1...20 {
                let x = m.length * Double(i) / 21
                let s = m.sample(x: x, r: 1.02 * m.extent(atX: x))
                XCTAssertLessThan(s.extinction * m.exitDiameter, 1e-3, "\(engine.spec.source) at \(x)")
            }
            XCTAssertGreaterThan(m.length, 2 * m.exitDiameter)
            XCTAssertLessThanOrEqual(m.length, 1_500)
        }
    }

    /// Prints the look across conditions (ORBITSIM_PLUME_TABLE=1), for the
    /// calibration notes.
    func testPrintCalibrationTable() throws {
        guard ProcessInfo.processInfo.environment["ORBITSIM_PLUME_TABLE"] != nil else {
            throw XCTSkip("set ORBITSIM_PLUME_TABLE=1 to print the table")
        }
        let cases: [(String, ApolloExhaust.Engine, Double?)] = [
            ("F-1 pad", ApolloExhaust.f1, 0), ("F-1 6.7 km", ApolloExhaust.f1, 6_700),
            ("F-1 13 km", ApolloExhaust.f1, 13_000), ("F-1 30 km", ApolloExhaust.f1, 30_000),
            ("F-1 45 km", ApolloExhaust.f1, 45_000), ("F-1 67 km", ApolloExhaust.f1, 67_000),
            ("J-2 25 km", ApolloExhaust.j2, 25_000), ("J-2 67 km", ApolloExhaust.j2, 67_000),
            ("J-2 vac", ApolloExhaust.j2, nil), ("SPS vac", ApolloExhaust.sps, nil),
            ("SM RCS vac", ApolloExhaust.smRCS, nil), ("retro 67 km", ApolloExhaust.sICRetro, 67_000),
            ("ullage 67 km", ApolloExhaust.sIIUllage, 67_000), ("TJM 90 km", ApolloExhaust.towerJettison, 90_000),
        ]
        for (name, e, alt) in cases {
            let m = member(e, altitude: alt)
            let de = m.exitDiameter
            let near = sideOn(m, x: 0.4 * de), mid = sideOn(m, x: 2 * de), far = sideOn(m, x: 10 * de)
            print(String(format: "%@: L %.0f m (%.1f De), R(2De)/re %.2f, R(10De)/re %.2f, v %.2f, Tc %.0f, "
                         + "flame %.0f K@%.1f m ab %.2f; side L/T at 0.4De %.3g/%.2f, 2De %.3g/%.2f, 10De %.3g/%.2f",
                         name, m.length, m.length / de, m.radius(atX: 2 * de) / m.exitRadius,
                         m.radius(atX: 10 * de) / m.exitRadius, m.vacuumBlend, m.coreTemperature,
                         m.flameTemperature, m.flameStart, m.afterburning,
                         near.luminance, near.transmittance, mid.luminance, mid.transmittance, far.luminance,
                         far.transmittance))
        }
    }
}
