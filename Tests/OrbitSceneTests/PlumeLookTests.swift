import XCTest
import OrbitCore
@testable import OrbitScene

/// The plumes' look (P2) from P1's plume model: each family's look against
/// the photographs' qualities, the readable floor, the legacy stub, and
/// the blackbody the shader uses.
final class PlumeLookTests: XCTestCase {
    let us76 = USStandardAtmosphere1976()

    func member(_ engine: ApolloExhaust.Engine, altitude: Double? = nil, air: AtmosphereState? = nil,
                flow: Double = 1, readable: Bool = false) -> PlumeMember {
        let a = air ?? (altitude.map { us76.state(altitude: $0) } ?? .vacuum)
        let s = PlumeModel.state(engine.spec, flowFraction: flow, ambient: a)
        var m = PlumeLook.member(engine.spec, state: s, exit: Vec3(0, 0, 0), axis: Vec3(1, 0, 0),
                                 exitRadius: engine.spec.exitRadius, ambient: a)
        if readable { PlumeLook.applyReadableFloor(&m) }
        return m
    }

    /// The light through the plume side-on at x (m), and its transmittance.
    func sideOn(_ m: PlumeMember, x: Double) -> (luminance: Double, transmittance: Double) {
        let r = m.extent(atX: x) + 1
        let seen = PlumeLook.march([m], from: Vec3(x, -r, 0), direction: Vec3(0, 1, 0), range: 0...(2 * r), steps: 400)
        return (seen.radiance.luminance, seen.transmittance)
    }

    func testPrintCalibrationTable() {
        let cases: [(String, ApolloExhaust.Engine, Double?)] = [
            ("F-1 pad", ApolloExhaust.f1, 0), ("F-1 6.7 km", ApolloExhaust.f1, 6_700),
            ("F-1 13 km", ApolloExhaust.f1, 13_000), ("F-1 30 km", ApolloExhaust.f1, 30_000),
            ("F-1 45 km", ApolloExhaust.f1, 45_000), ("F-1 67 km", ApolloExhaust.f1, 67_000),
            ("J-2 sea", ApolloExhaust.j2, 0), ("J-2 67 km", ApolloExhaust.j2, 67_000), ("J-2 vac", ApolloExhaust.j2, nil),
            ("SPS vac", ApolloExhaust.sps, nil), ("SM RCS vac", ApolloExhaust.smRCS, nil),
            ("retro 67 km", ApolloExhaust.sICRetro, 67_000), ("ullage 67 km", ApolloExhaust.sIIUllage, 67_000),
            ("TJM 90 km", ApolloExhaust.towerJettison, 90_000), ("TJM sea", ApolloExhaust.towerJettison, 0),
        ]
        for (name, e, alt) in cases {
            let m = member(e, altitude: alt)
            let de = m.exitDiameter
            let near = sideOn(m, x: 0.4 * de), mid = sideOn(m, x: 2 * de), far = sideOn(m, x: 10 * de)
            let st = PlumeModel.state(e.spec, flowFraction: 1, ambient: alt.map { us76.state(altitude: $0) } ?? .vacuum)
            print(String(format: "  P1: lum %.0f m, core %.0f m, Dj %.1f m, n %.3g, δ0 %.0f°, Mj %.1f", st.luminousLength,
                         st.potentialCoreLength, st.jetDiameter, st.pressureRatio, st.boundaryAngle * 180 / .pi, st.jetMach))
            print(String(format: "%@: L %.0f m (%.1f De), R(2De) %.2f, R(10De) %.2f, v %.2f, Tc %.0f, flame %.0f@%.1f ab %.2f;"
                         + " side L/T at 0.4De %.3g/%.2f, 2De %.3g/%.2f, 10De %.3g/%.2f",
                         name, m.length, m.length / de, m.radius(atX: 2 * de) / m.exitRadius,
                         m.radius(atX: 10 * de) / m.exitRadius, m.vacuumBlend, m.coreTemperature,
                         m.flameTemperature, m.flameStart, m.afterburning,
                         near.luminance, near.transmittance, mid.luminance, mid.transmittance, far.luminance,
                         far.transmittance))
        }
        for t in [1_000.0, 1_500, 2_000, 2_300, 3_000] {
            let b = PlumeLook.blackbody(t), p = Photometry.blackbody(t)
            print(String(format: "B(%.0f K): fit %.4g, Photometry %.4g", t, b.luminance, p.luminance))
        }
    }
}
