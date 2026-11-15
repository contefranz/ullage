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
        // The fall itself, in at most 32 pieces (`maxSubsteps`), within 2 %
        // of fine steps through the first seconds' transient, as the 30 m/s
        // throw dies away.
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
    /// uniform environment keeps its buoyancy, the weight of the air it
    /// displaces less its own. For an ideal-gas parcel at the air's pressure
    /// that is ρa V (1 − Ta/T): r³ (1 − Ta/T) is conserved, Boussinesq's
    /// (T − Ta) r³ only near Ta. The radius grows by α per metre of path
    /// through the air.
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
        func buoyancy(_ x: P.State) -> Double { pow(x.radius, 3) * (1 - 288.15 / x.temperature) }
        XCTAssertEqual(buoyancy(s), buoyancy(start), accuracy: 1e-9 * buoyancy(start))
        XCTAssertEqual(s.radius - start.radius, 0.25 * path, accuracy: 2e-3 * 0.25 * path)
        XCTAssertLessThan(s.temperature, start.temperature)
    }

    /// The mixture of a 2,000 K puff grown from 4 to 7 m in 288 K air: by
    /// enthalpy and volume, Ta / (1 − (4/7)³ (1 − Ta/T)) = 343 K (the
    /// Boussinesq law would leave it at 608 K).
    func testIdealGasMixing() {
        let air = P.Air(density: 1.225, temperature: 288, pressure: 101_325)
        let puff = P.Material(density: 0, spreadRate: 3)
        let s = P.State(position: .zero, velocity: .zero, radius: 4, temperature: 2_000)
        let after = P.grown(s, material: puff, air: air, dt: 1, path: 0)
        XCTAssertEqual(after.radius, 7)
        XCTAssertEqual(after.temperature, 288 / (1 - pow(4.0 / 7, 3) * (1 - 288.0 / 2_000)), accuracy: 1e-9)
        XCTAssertEqual(after.temperature, 342.7, accuracy: 0.1)
        // Spreading into vacuum cools adiabatically: T (r0/r)^(3(γ−1)).
        let gone = P.grown(s, material: puff, air: .vacuum, dt: 1, path: 0)
        XCTAssertEqual(gone.temperature, 2_000 * pow(4.0 / 7, 1.2), accuracy: 1e-9)
    }

    /// A falling frame is the same physics: a particle's slip through the
    /// air does not depend on the anchor. Steam at the air's temperature, a
    /// hot puff and a grain, from rest relative to still air, in a
    /// body-fixed anchor and in a free-fall one that starts at rest and
    /// falls with g (where the air rises at −g t): over 10 s of 1/60 s
    /// frames and in one advance, the free-fall positions are the
    /// body-fixed ones less ½ g t², the velocities less g t. Steam at the
    /// air's temperature stays where it was in the air.
    func testFreeFallFrameMatchesBodyFixed() {
        let air = P.Air(density: 1.225, temperature: 288.15, pressure: 101_325)
        let cases: [(String, P.Material, P.State)] = [
            ("steam", P.Material(density: 0, dragCoefficient: 0.5, entrainment: 0.1, spreadRate: 0.5, coolingTime: 8),
             P.State(position: .zero, velocity: .zero, radius: 5, temperature: 288.15)),
            ("hot puff", P.Material(density: 0, dragCoefficient: 0.5, entrainment: 0.1, coolingTime: 30),
             P.State(position: .zero, velocity: Vec3(3, 0, 0), radius: 2, temperature: 400)),
            ("grain", P.Material(density: 917, dragCoefficient: 1.2), 
             P.State(position: .zero, velocity: Vec3(5, 0, 0), radius: 2e-3, temperature: 260)),
        ]
        for (name, m, start) in cases {
            var settled = start
            for frames in [600, 1] {
                let h = 10.0 / Double(frames)
                var fixed = start, falling = start
                for k in 1...frames {
                    fixed = P.advance(fixed, material: m, environment: P.Environment(gravity: g), dt: h) { _ in air }
                    var rising = air
                    rising.velocity = g * -(Double(k) * h)
                    falling = P.advance(falling, material: m, environment: .freeFall(gravity: g), dt: h) { _ in rising }
                }
                let t = 10.0
                XCTAssertEqual((falling.position - (fixed.position - g * (0.5 * t * t))).length, 0,
                               accuracy: 1e-6 * max(1, fixed.position.length, 0.5 * 9.8 * t * t), "\(name), \(frames)")
                XCTAssertEqual((falling.velocity - (fixed.velocity - g * t)).length, 0, accuracy: 1e-6 * 98, "\(name)")
                XCTAssertEqual(falling.radius, fixed.radius, accuracy: 1e-9 * fixed.radius, name)
                XCTAssertEqual(falling.temperature, fixed.temperature, accuracy: 1e-9 * fixed.temperature, name)
                if frames == 600 { settled = fixed }
            }
            if name == "steam" { XCTAssertLessThan(settled.position.length, 0.01, "neutral steam stays put") }
            if name == "hot puff" { XCTAssertGreaterThan(settled.position.z, 5, "the hot puff rises") }
        }
    }

    /// A gas parcel carried up through US76 cools on the dry adiabat, g/cp =
    /// 9.76 K/km (dry air, cp 1,004.7 J/(kg K)), steeper than the
    /// standard atmosphere's 6.5 K/km; so a parcel thrown up from 1 km in
    /// the stable troposphere comes back down rather than running away.
    func testAdiabaticLiftAndStability() {
        let us76 = USStandardAtmosphere1976()
        func air(_ updraft: Double) -> (Vec3) -> P.Air {
            { p in
                let s = us76.state(altitude: p.z)
                return P.Air(density: s.density, temperature: s.temperature, pressure: s.pressure,
                             velocity: Vec3(0, 0, updraft))
            }
        }
        let parcel = P.Material(density: 0, dragCoefficient: 0.5)
        let t0 = us76.state(altitude: 1_000).temperature
        var s = P.State(position: Vec3(0, 0, 1_000), velocity: Vec3(0, 0, 5), radius: 1, temperature: t0)
        let carried = air(5)
        while s.position.z < 2_000 {
            s = P.advance(s, material: parcel, environment: P.Environment(gravity: g), dt: 0.5, air: carried)
        }
        let rate = (s.temperature - t0) / (s.position.z - 1_000) * 1_000
        XCTAssertEqual(rate, -9.76, accuracy: 0.25, "K/km on the dry adiabat")

        var thrown = P.State(position: Vec3(0, 0, 1_000), velocity: Vec3(0, 0, 10), radius: 5, temperature: t0)
        var highest = thrown.position.z
        for _ in 0..<1_200 {
            thrown = P.advance(thrown, material: parcel, environment: P.Environment(gravity: g), dt: 0.5, air: air(0))
            highest = max(highest, thrown.position.z)
        }
        XCTAssertLessThan(highest, 1_400, "it was stopped by the stable air")
        XCTAssertEqual(thrown.position.z, 1_000, accuracy: 300, "and settled back near where it started")
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

    /// One advance against fine ones (1 ms): a hot puff over a 1,000× frame
    /// (16.7 s); a 0.5 m, 1,500 K pyro puff thrown at 300 m/s through a
    /// 100× frame (1.67 s) and through a 1,000× one; the F-1's 2,000 K
    /// exhaust at 1,000 m/s and a 5 m puff at 200 m/s, aged 8.9 s at once
    /// as P4 pre-ages the ignition. Quadratic drag's slip dies as 1/t: the
    /// schedule's growing pieces keep the throw and the entrainment.
    func testLongAdvanceMatchesFineSteps() {
        let puff = P.Material(density: 0, dragCoefficient: 0.5, entrainment: 0.1, spreadRate: 0.2, coolingTime: 30)
        var air = seaLevel
        air.velocity = Vec3(4, -1, 0)
        let env = P.Environment(gravity: g)
        let cases: [(String, P.State, Double)] = [
            ("hot puff, 1000x", P.State(position: Vec3(0, 0, 50), velocity: Vec3(0, 0, 40), radius: 6,
                                        temperature: 1_200), 16.7),
            ("pyro puff, 100x", P.State(position: .zero, velocity: Vec3(300, 0, 0), radius: 0.5, temperature: 1_500), 1.67),
            ("pyro puff, 1000x", P.State(position: .zero, velocity: Vec3(300, 0, 0), radius: 0.5, temperature: 1_500), 16.7),
            ("F-1 exhaust, 8.9 s", P.State(position: Vec3(0, 0, 10), velocity: Vec3(1_000, 0, -50), radius: 2,
                                           temperature: 2_000), 8.9),
            ("puff at 200 m/s, 8.9 s", P.State(position: .zero, velocity: Vec3(200, 0, 0), radius: 5,
                                               temperature: 1_200), 8.9),
        ]
        for (name, start, dt) in cases {
            let one = P.advance(start, material: puff, environment: env, dt: dt) { _ in air }
            var fine = start
            for _ in 0..<Int((dt / 1e-3).rounded()) {
                fine = P.advance(fine, material: puff, environment: env, dt: 1e-3) { _ in air }
            }
            let travelled = (fine.position - start.position).length
            XCTAssertLessThan((one.position - fine.position).length, 0.03 * travelled, "\(name): \(one.position) vs \(fine.position)")
            XCTAssertEqual(one.radius, fine.radius, accuracy: 0.03 * fine.radius, name)
            XCTAssertEqual(one.temperature - 288.15, fine.temperature - 288.15,
                           accuracy: 0.05 * (fine.temperature - 288.15) + 0.5, name)
        }
        // The schedule: equal pieces while 32 of twice τ do, then geometric.
        XCTAssertEqual(P.schedule(dt: 1, shortest: 1).count, 1)
        let equal = P.schedule(dt: 10, shortest: 1)
        XCTAssertEqual([equal.count, Int(equal.ratio)], [5, 1])
        let growing = P.schedule(dt: 557, shortest: 1)
        XCTAssertEqual(growing.count, 32)
        XCTAssertEqual(growing.first, 1, accuracy: 1e-9)
        XCTAssertEqual(growing.first * (pow(growing.ratio, 32) - 1) / (growing.ratio - 1), 557, accuracy: 1e-6)
    }

    /// The golden vectors are finite, each case moves something, and they
    /// are what `advance` gives.
    func testGoldenCases() {
        XCTAssertEqual(P.goldenCases.count, 10)
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
