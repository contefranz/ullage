import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// The launch cloud's medium as the GPU gets it (`EffectMedium`): its
/// records evaluate in Float to the field's densities, its box holds the
/// field, its humidity table is the field's air.
final class EffectMediumTests: XCTestCase {
    // The Float evaluation (the shader's, line by line) is the field's
    // primitives' within 1e-4 of each one's peak, displaced or not.
    func testRecordsEvaluateToTheField() {
        for t in [-4.5, 5, 30] {
            let f = GroundCloudFieldTests.field(GroundCloudFieldTests.cloud(to: t), at: t)
            let m = EffectMedium(f)
            XCTAssertEqual(m.count, f.primitives.count)
            for (i, p) in f.primitives.enumerated() {
                var peak = 0.0
                var points: [Vec3] = []
                for k in 0..<400 {
                    // Points about the primitive: along it and across it.
                    let u = Double(k % 20) / 19, v = Double(k / 20) / 19
                    let x: Vec3
                    switch p.shape {
                    case .thermal: x = p.origin + Vec3((2 * u - 1) * 1.5 * p.radius, 0.2 * p.radius, (2 * v - 1) * p.radius)
                    case .roundJet, .stem:
                        let s = (p.shape == .stem ? 0 : p.start) + u * (p.end - (p.shape == .stem ? 0 : p.start))
                        x = p.origin + p.axis * s + Vec3(0, (2 * v - 1) * 2 * p.size(at: p.origin + p.axis * s), 0)
                    case .wallJet: x = Vec3(p.start + u * (p.end - p.start), 0, v * 2 * p.thickness(p.end))
                    }
                    points.append(x)
                    peak = max(peak, p.density(at: x))
                }
                for x in points {
                    for eta in [0.0, 3, -3] {
                        let want = p.density(at: x, displacement: eta)
                        let got = Double(m.density(i, at: SIMD3(Float(x.x), Float(x.y), Float(x.z)),
                                                   displacement: Float(eta)))
                        XCTAssertEqual(got, want, accuracy: 1e-4 * peak + 1e-4 * want, "T\(t) s \(p.shape) at \(x)")
                    }
                }
            }
        }
    }

    // The box the far field's grids cover holds every primitive (where its
    // density is a millionth of its peak or more), and the humidity table
    // is the field's air at AirProfile's levels.
    func testBoxHoldsTheFieldAndHumidityIsItsAir() {
        let f = GroundCloudFieldTests.field(GroundCloudFieldTests.cloud(to: 8), at: 8)
        let m = EffectMedium(f)
        for p in f.primitives {
            let (lo, hi) = EffectMedium.box(p)
            XCTAssertTrue(lo.x >= m.lower.x - 1e-9 && lo.y >= m.lower.y - 1e-9 && lo.z >= m.lower.z - 1e-9)
            XCTAssertTrue(hi.x <= m.upper.x + 1e-9 && hi.y <= m.upper.y + 1e-9 && hi.z <= m.upper.z + 1e-9)
        }
        // Points well outside the box hold nothing.
        let far = [m.upper + Vec3(5, 5, 5), m.lower - Vec3(5, 5, 0), Vec3(m.upper.x + 10, 0, 10)]
        for p in f.primitives {
            let inside: Vec3
            switch p.shape {
            case .thermal: inside = p.origin + Vec3(GroundCloudField.ringRadius * p.radius, 0, 0)
            case .roundJet: inside = p.origin + p.axis * (p.start + 1)
            case .wallJet: inside = Vec3(p.start + 1, 0, 0.1)
            case .stem: inside = p.origin + p.axis * 1
            }
            let peak = p.density(at: inside)
            XCTAssertGreaterThan(peak, 0, "\(p.shape)")
            for x in far { XCTAssertLessThanOrEqual(p.density(at: x), 1e-6 * peak, "\(p.shape) at \(x)") }
        }
        XCTAssertEqual(m.humidity.count, AirProfile.count)
        XCTAssertEqual(Double(m.humidity[1]), f.ambient(height: AirProfile.altitude(1) - f.deckHeight).humidity,
                       accuracy: 1e-6)
        // At High the grid's cells are the plan's 8-16 m at T+8 s.
        let cell = m.cell(.high)
        print(String(format: "T+8 s: box %.0f × %.0f × %.0f m, High cells %.1f × %.1f × %.1f m",
                     m.upper.x - m.lower.x, m.upper.y - m.lower.y, m.upper.z - m.lower.z, cell.x, cell.y, cell.z))
    }
}
