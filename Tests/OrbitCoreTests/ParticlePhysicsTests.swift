import XCTest
@testable import OrbitCore

/// P3's particle physics: Archimedes on an ideal gas against the US76
/// constants, the terminal speed of a falling grain, the exact sublimation
/// against Murphy and Koop's flux integrated finely, Morton, Taylor and
/// Turner's conserved buoyancy of an entraining thermal, and the long
/// advance at time warp against fine steps.
final class ParticlePhysicsTests: XCTestCase {
    typealias P = ParticlePhysics
    let g = Vec3(0, 0, -9.80665)

    // US76's sea level: 101,325 Pa, 288.15 K, M = 0.0289644 kg/mol, R* = 8.31432.
    let seaLevel = P.Air(density: 101_325 * 0.028_964_4 / (8.314_32 * 288.15), temperature: 288.15, pressure: 101_325)

    /// Archimedes: a parcel of hot air at the ambient pressure, its density
    /// from the ideal-gas law, is pushed up at g (ρa − ρp) / ρp.
    func testHotParcelBuoyancyIsArchimedesOnAnIdealGas() {
        let parcel = P.Material(density: 0)
        for tp in [288.15, 400, 900, 2_000] {
            let rhoP = 101_325 * 0.028_964_4 / (8.314_32 * tp)
            let expected = 9.80665 * (seaLevel.density - rhoP) / rhoP
            let a = P.effectiveGravity(parcel, temperature: tp, air: seaLevel, gravity: g)
            XCTAssertEqual(a.z, expected, accuracy: 1e-9 * max(1, expected), "Tp \(tp) K")
            XCTAssertEqual(a.x, 0)
        }
        // At the air's temperature it floats; ice barely notices the air
        // (ρa/ρp = 1.4e-3); in vacuum and in free fall there is none.
        XCTAssertEqual(P.effectiveGravity(parcel, temperature: 288.15, air: seaLevel, gravity: g).length, 0,
                       accuracy: 1e-12)
        let ice = P.Material(density: 917)
        XCTAssertEqual(P.effectiveGravity(ice, temperature: 260, air: seaLevel, gravity: g).z,
                       -9.80665 * (1 - seaLevel.density / 917), accuracy: 1e-12)
        XCTAssertEqual(P.effectiveGravity(parcel, temperature: 900, air: .vacuum, gravity: g), g)
        XCTAssertEqual(P.effectiveGravity(parcel, temperature: 900, air: seaLevel, gravity: .zero), .zero)
    }

    /// A gas parcel's drag time depends only on the temperature ratio, so it
    /// stays finite and the same as both densities scale together.
    func testGasParcelRelaxationTimeIsDensityFree() {
        let parcel = P.Material(density: 0, dragCoefficient: 0.5)
        var thin = seaLevel
        thin.density *= 1e-4
        let a = P.relaxationTime(parcel, radius: 5, temperature: 600, air: seaLevel, relativeSpeed: 20)
        let b = P.relaxationTime(parcel, radius: 5, temperature: 600, air: thin, relativeSpeed: 20)
        XCTAssertEqual(a, b, accuracy: 1e-12)
        // (8/3)(Ta/Tp) r / (Cd v).
        XCTAssertEqual(a, 8.0 / 3 * (288.15 / 600) * 5 / (0.5 * 20), accuracy: 1e-12)
        // A solid sphere: m / (½ ρ Cd A v), as P1's relaxationTime.
        let grain = P.Material(density: 2_500, dragCoefficient: 0.47)
        let r = 1e-3
        let m = 2_500 * 4.0 / 3 * Double.pi * r * r * r
        XCTAssertEqual(P.relaxationTime(grain, radius: r, temperature: 300, air: seaLevel, relativeSpeed: 7),
                       ParticleKinematics.relaxationTime(mass: m, dragArea: 0.47 * Double.pi * r * r,
                                                         density: seaLevel.density, relativeSpeed: 7),
                       accuracy: 1e-12)
        XCTAssertEqual(P.relaxationTime(grain, radius: r, temperature: 300, air: .vacuum, relativeSpeed: 7), .infinity)
    }

    /// A grain falls to the terminal speed of quadratic drag,
    /// sqrt(2 m g' / (ρ Cd A)) with g' its gravity less buoyancy, and one
    /// advance of a minute gets there as surely as 6,000 of 0.01 s.
    func testGrainReachesTerminalSpeed() {
        let grain = P.Material(density: 917, dragCoefficient: 1.1)
        let r = 0.01, m = 917 * 4.0 / 3 * Double.pi * r * r * r
        let gEff = 9.80665 * (1 - seaLevel.density / 917)
        let terminal = (2 * m * gEff / (seaLevel.density * 1.1 * Double.pi * r * r)).squareRoot()
        let start = P.State(position: Vec3(0, 0, 3_000), velocity: Vec3(30, 0, 0), radius: r, temperature: 260)
        let env = P.Environment(gravity: g)
        let one = P.advance(start, material: grain, environment: env, dt: 60) { _ in self.seaLevel }
        XCTAssertEqual(-one.velocity.z, terminal, accuracy: 1e-3 * terminal)
        XCTAssertEqual(one.velocity.x, 0, accuracy: 1e-3)
        var fine = start
        for _ in 0..<6_000 { fine = P.advance(fine, material: grain, environment: env, dt: 0.01) { _ in self.seaLevel } }
        XCTAssertEqual(-fine.velocity.z, terminal, accuracy: 1e-3 * terminal)
        // The fall itself: the GPU's bound of 16 substeps (`maxSubsteps`;
        // P1's CPU step takes up to 64) costs about 1.5 % of it in the first
        // seconds' transient, as the 30 m/s throw dies away.
        XCTAssertEqual(one.position.z, fine.position.z, accuracy: 0.02 * (start.position.z - fine.position.z))
    }

    /// The exact sublimated radius against Murphy and Koop's flux (P1's
    /// `IceSublimation.radiusRate`) integrated with RK4 at 0.01 s, in air;
    /// and in vacuum, a flake lasts `IceSublimation.vacuumLifetime`.
    func testSublimationIsExact() {
        let air = P.Air(density: 0.9, temperature: 255, pressure: 70_000)
        let r0 = 1.5e-3
        func rate(_ r: Double) -> Double {
            -IceSublimation.radiusRate(iceTemperature: 255, airPressure: 70_000, airTemperature: 255, radius: r)
        }
        var r = r0
        let h = 0.01
        for _ in 0..<60_000 {
            let k1 = rate(r), k2 = rate(r + 0.5 * h * k1), k3 = rate(r + 0.5 * h * k2), k4 = rate(r + h * k3)
            r += h / 6 * (k1 + 2 * k2 + 2 * k3 + k4)
        }
        let exact = P.sublimatedRadius(r0, dt: 600, iceTemperature: 255, air: air)
        XCTAssertLessThan(exact, r0)
        XCTAssertEqual(exact, r, accuracy: 1e-9 * r0)
        // One step or sixty: the same radius.
        var stepped = r0
        for _ in 0..<60 { stepped = P.sublimatedRadius(stepped, dt: 10, iceTemperature: 255, air: air) }
        XCTAssertEqual(stepped, exact, accuracy: 1e-12)

        let life = IceSublimation.vacuumLifetime(radius: 1e-3, temperature: 205)
        XCTAssertEqual(P.sublimatedRadius(1e-3, dt: 0.5 * life, iceTemperature: 205, air: .vacuum), 0.5e-3,
                       accuracy: 1e-12)
        XCTAssertEqual(P.sublimatedRadius(1e-3, dt: 1.001 * life, iceTemperature: 205, air: .vacuum), 0)
    }

    /// Morton, Taylor and Turner (1956): a thermal entraining the air of a
    /// uniform environment keeps its buoyancy, g (Tp − Ta)/Ta × volume, so
    /// with no other cooling the excess temperature times r³ is conserved,
    /// and the radius grows by α per metre of its path through the air.
    func testEntrainingThermalConservesBuoyancy() {
        let thermal = P.Material(density: 0, dragCoefficient: 0.5, entrainment: 0.25)
        let start = P.State(position: .zero, velocity: Vec3(0, 0, 5), radius: 3, temperature: 600)
        var s = start, path = 0.0
        let env = P.Environment(gravity: g), h = 0.01
        for _ in 0..<2_000 {
            let next = P.advance(s, material: thermal, environment: env, dt: h) { _ in self.seaLevel }
            path += 0.5 * (s.velocity.length + next.velocity.length) * h
            s = next
        }
        XCTAssertGreaterThan(s.position.z, 10, "it rose")
        let b0 = (start.temperature - 288.15) * pow(start.radius, 3), b1 = (s.temperature - 288.15) * pow(s.radius, 3)
        XCTAssertEqual(b1, b0, accuracy: 1e-9 * b0)
        XCTAssertEqual(s.radius - start.radius, 0.25 * path, accuracy: 1e-3 * 0.25 * path)
        XCTAssertLessThan(s.temperature, start.temperature)
    }

    /// A spark cools towards the air (here vacuum's 3 K) with its time
    /// constant: T − 3 falls as e^(−t/τc) whatever the steps.
    func testSparkCoolsWithItsTimeConstant() {
        let spark = P.Material(density: 3_950, coolingTime: 1.5)
        let s = P.State(position: .zero, velocity: Vec3(10, 0, 0), radius: 1e-4, temperature: 2_600)
        let one = P.advance(s, material: spark, environment: P.Environment(gravity: .zero), dt: 2) { _ in .vacuum }
        XCTAssertEqual(one.temperature, 3 + 2_597 * exp(-2 / 1.5), accuracy: 1e-9)
        XCTAssertEqual(one.position, Vec3(20, 0, 0), "ballistic in vacuum")
    }

    /// At 1,000× one frame is 16.7 s: the advance splits it and lands within
    /// 2 % of 1,670 advances of 0.01 s, for a hot puff rising and entraining.
    func testLongAdvanceMatchesFineSteps() {
        let puff = P.Material(density: 0, dragCoefficient: 0.5, entrainment: 0.1, spreadRate: 0.2, coolingTime: 30)
        var air = seaLevel
        air.velocity = Vec3(4, -1, 0)
        let start = P.State(position: Vec3(0, 0, 50), velocity: Vec3(0, 0, 40), radius: 6, temperature: 1_200)
        let env = P.Environment(gravity: g)
        XCTAssertGreaterThan(P.substeps(start, material: puff, environment: env, dt: 16.7, air: air), 1)
        let one = P.advance(start, material: puff, environment: env, dt: 16.7) { _ in air }
        var fine = start
        for _ in 0..<1_670 { fine = P.advance(fine, material: puff, environment: env, dt: 0.01) { _ in air } }
        let travelled = (fine.position - start.position).length
        XCTAssertLessThan((one.position - fine.position).length, 0.02 * travelled)
        XCTAssertEqual(one.radius, fine.radius, accuracy: 0.02 * fine.radius)
        XCTAssertEqual(one.temperature - 288.15, fine.temperature - 288.15, accuracy: 0.05 * (fine.temperature - 288.15))
    }

    /// The golden vectors are finite, each case moves something, and they
    /// are what `advance` gives.
    func testGoldenCases() {
        XCTAssertEqual(P.goldenCases.count, 7)
        for c in P.goldenCases {
            let e = c.expected
            for x in [e.position.x, e.position.y, e.position.z, e.velocity.x, e.velocity.y, e.velocity.z, e.radius,
                      e.temperature] {
                XCTAssertTrue(x.isFinite, c.name)
            }
            XCTAssertNotEqual(e, c.state, c.name)
            XCTAssertEqual(P.advance(c.state, material: c.material, environment: c.environment, dt: c.dt) { _ in c.air },
                           e, c.name)
        }
        let flake = P.goldenCases.first { $0.name == "flake in sunlit vacuum" }!
        XCTAssertLessThan(flake.expected.radius, flake.state.radius, "it sublimated")
    }
}
