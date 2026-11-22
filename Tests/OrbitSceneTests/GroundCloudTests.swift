import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// The ground cloud's physics (`GroundCloud`): its sources against the
/// F-1's exhaust and the pad's water, the deflector's jets, and the two
/// clouds on AS-506's sounding, with Apollo 10's and 16's photographed
/// clouds as the plausibility check (not a fit).
final class GroundCloudTests: XCTestCase {
    static let system = try! SolarSystem.bundled()

    /// AS-506's launch, as the count and the climb run it: the F-1s' flow
    /// and thrust from FER-506's start to first motion, then full; the
    /// shares with `LiftoffRise`'s climb; the trench's water through the
    /// ignition and the deck's from first motion.
    static func sources(at t: Epoch, zero: Epoch) -> GroundCloud.Sources {
        let plan = TerminalCount.Plan.as506
        let range = t - zero, fm = plan.release
        let fraction = range < fm ? plan.meanFraction(rangeTime: range) : 1
        let climb = range < fm ? 0 : LiftoffRise.rise(after: range - fm)
        let shares = PadExhaust.shares(exitHeight: PadExhaust.exitHeightOnPad + climb)
        let gpm = GroundCloud.gallon / GroundCloud.minute
        return GroundCloud.Sources(exhaust: LiftoffRise.flow * fraction, thrust: LiftoffRise.thrust * fraction,
                                   trench: shares.trench, deck: shares.deck, trenchWater: PadExhaust.trenchWater * gpm,
                                   deckWater: PadExhaust.deckWater(sinceFirstMotion: range - fm) * gpm)
    }

    static func air() -> AirProfile {
        let sim = Simulation(system: system, time: VesselLibrary.apollo11RangeZero)
        VesselLibrary.apollo11OnPad(in: sim)
        return AirProfile(sim.atmosphere(of: sim.system.earth)!)
    }

    func cloud(to range: Double, every: Double = 1, _ each: (Double, GroundCloud) -> Void = { _, _ in }) -> GroundCloud {
        let zero = VesselLibrary.apollo11RangeZero
        let start = zero + TerminalCount.Plan.as506.starts.map(\.command).min()!
        var c = GroundCloud(origin: start)
        let air = Self.air()
        var t = (start - zero).rounded(.down)
        while t < range - 1e-9 {
            t = min(range, t + every)
            c.advance(to: zero + t, sources: { Self.sources(at: $0, zero: zero) }, air: air,
                      deckHeight: LC39A.placement().height,
                      siteFromEastNorth: { e, n in Vec3(n, -e, 0) })
            each(t, c)
        }
        return c
    }

    // At full thrust on the pad: 13.2 t/s of exhaust at 11.7 MJ/kg (its
    // stagnation enthalpy and afterburning, CEA), a quarter radiated, the
    // trench's 28,000 gpm boiled: a buoyancy flux of about 3.1 × 10⁶ m⁴/s³,
    // and each side's jet half the trench's thrust at the deflector's half,
    // 7.2 × 10⁶ m⁴/s² of kinematic momentum flux, out of the exits at about
    // 270 m/s, 7.3 m in half-width: the trench's own 58 ft by 42 ft.
    func testSourcesAtFullThrust() {
        XCTAssertEqual(GroundCloud.exhaustHeat(ambient: 300) / 1e6, 11.7, accuracy: 0.2)
        XCTAssertEqual(GroundCloud.deflectorMomentum, 0.5, accuracy: 0.01)
        let s = GroundCloud.Sources(exhaust: LiftoffRise.flow, thrust: LiftoffRise.thrust, trench: 1, deck: 0,
                                    trenchWater: PadExhaust.trenchWater * GroundCloud.gallon / 60, deckWater: 0)
        let side = GroundCloud.side(s, density: 1.17, ambient: 300)
        XCTAssertEqual(2 * side.buoyancy / 1e6, 3.1, accuracy: 0.2)
        XCTAssertEqual(side.momentum / 1e6, 7.3, accuracy: 0.3)
        let x = GroundCloud.exitDistance
        XCTAssertEqual(x, 68.58, accuracy: 0.01)
        XCTAssertEqual(GroundCloud.jetVelocity * side.momentum.squareRoot() / x, 270, accuracy: 15)
        XCTAssertEqual(GroundCloud.jetSpread * x, 7.3, accuracy: 0.1)
        let exit = PadExhaust.trenchExits[0]
        XCTAssertEqual(GroundCloud.jetSpread * x, (2 * exit.radius * 12.8 / .pi).squareRoot(), accuracy: 1.5)
    }

    // The two clouds on AS-506's sounding: the jets out to a few hundred
    // metres within seconds, the clouds past the tower's 120 m within about
    // 15 s, hundreds of metres across by then; at 30 s and 60 s within a
    // factor of two of Apollo 16's south lobe (0.5 km, 1 km, TM X-2935
    // Fig. 3) and Apollo 10's and 16's widths (1.2-1.3 km at 30 s; CR-61326
    // Fig. E-9, TM X-2935 Fig. 4).
    func testCloudsRiseAndGrowAsPhotographed() {
        var printed: [String] = []
        let marks: Set<Double> = [1, 3, 5, 8, 10, 15, 20, 30, 45, 60, 90, 120, 180]
        let c = cloud(to: 180) { t, c in
            guard marks.contains(t.rounded()) && abs(t - t.rounded()) < 1e-6 else { return }
            let n = c.lobes[0], s = c.lobes[1], d = c.lobes[2]
            let width = (n.centre.x + n.radius) - (s.centre.x - s.radius)
            printed.append(String(format: "T%+5.0f s: jet %4.0f m, cloud R %4.0f m top %5.0f m w %5.1f m/s; deck R %4.0f m top %5.0f m; N-S %5.0f m",
                                  t, n.front, n.radius, n.top, n.rise, d.radius, d.top, width))
        }
        print(printed.joined(separator: "\n"))
        // The lobes at a few times: (range s, jet front m, top m, N-S width m).
        var at: [Double: (front: Double, top: Double, deckTop: Double, width: Double)] = [:]
        _ = cloud(to: 180) { t, c in
            let n = c.lobes[0], s = c.lobes[1]
            at[t.rounded()] = (n.front - GroundCloud.exitDistance, max(n.top, s.top), c.lobes[2].top,
                               (n.centre.x + n.radius) - (s.centre.x - s.radius))
        }
        let t5 = try! XCTUnwrap(at[5]), t15 = try! XCTUnwrap(at[15]), t30 = try! XCTUnwrap(at[30])
        let t60 = try! XCTUnwrap(at[60]), t180 = try! XCTUnwrap(at[180])
        // The jets out of the trench a few hundred metres within seconds
        // (Apollo 10's lobes, CR-61326 Fig. E-9), the clouds past the tower
        // (121 m to its crane's top above the deck) within seconds of T−0.
        XCTAssert((150...400).contains(t5.front), "jets \(t5.front) m beyond the exits at T+5 s")
        XCTAssertGreaterThan(t5.top, 136)
        XCTAssertGreaterThan(t15.deckTop, 136, "the deck's cloud past the tower by T+15 s")
        // Within a factor of two of Apollo 16's cloud (TM X-2935): 750 m
        // across at 15 s, 1.2 km at 30 s; its top 0.5 km at 30 s, 1 km at
        // 60 s, stabilising near 2 km.
        XCTAssert((375...1_500).contains(t15.width), "\(t15.width) m across at 15 s")
        XCTAssert((600...2_400).contains(t30.width), "\(t30.width) m across at 30 s")
        XCTAssert((250...1_000).contains(t30.top), "top \(t30.top) m at 30 s")
        XCTAssert((500...2_000).contains(t60.top), "top \(t60.top) m at 60 s")
        XCTAssert((1_000...3_000).contains(t180.top), "top \(t180.top) m at 180 s")
        _ = c
    }

    // The deck's wall jet carries the heat its cloud gets: the deck share's
    // once its share of the deck's 50,000 gpm has boiled (with 30 % of the
    // exhaust on the deck, about 7 % of that heat), and its eddies are that
    // much less hot than they would be dry. From 40 m off the axis (the
    // envelope of a stack some way up), below the 2,000 K cap: nearer, at
    // the ML's opening, the volume is too small for the heat and both are
    // capped.
    func testDeckJetCarriesTheHeatLeftByItsWater() {
        let gpm = GroundCloud.gallon / GroundCloud.minute
        let wet = GroundCloud.Sources(exhaust: LiftoffRise.flow, thrust: LiftoffRise.thrust, trench: 0.7, deck: 0.3,
                                      trenchWater: PadExhaust.trenchWater * gpm,
                                      deckWater: PadExhaust.deckWater(sinceFirstMotion: 1) * gpm)
        var dry = wet
        dry.deckWater = 0
        let rho = 1.17, ambient = 300.0, r0 = 40.0
        let w = LaunchEffects.deckJet(wet, from: r0, density: rho, ambient: ambient)
        let d = LaunchEffects.deckJet(dry, from: r0, density: rho, ambient: ambient)
        let left = GroundCloud.fluxes(wet, lobe: .deck, density: rho, ambient: ambient).heat
        let all = GroundCloud.fluxes(dry, lobe: .deck, density: rho, ambient: ambient).heat
        let boiled = wet.deckWater * wet.deck * (GroundCloud.waterHeat * (373.15 - ambient) + GroundCloud.waterLatent)
        XCTAssertEqual(all - left, boiled, accuracy: 1e-9 * all)
        XCTAssertEqual(1 - left / all, 0.07, accuracy: 0.02)
        // The excess is the heat over the volume's heat capacity.
        XCTAssertLessThan(d.temperature, 2_000, "below the cap")
        XCTAssertLessThan(w.temperature, d.temperature)
        XCTAssertEqual((w.temperature - ambient) / (d.temperature - ambient), left / all, accuracy: 1e-9)
        XCTAssertEqual(w.speed, d.speed)
    }

    // The state is integrated on a fixed grid from the first start command:
    // advanced in frames of any length to the same epoch, it is the same,
    // and its samples give the lobes as they were.
    func testGridMakesFramesAndRebuildsAgree() {
        let zero = VesselLibrary.apollo11RangeZero
        let start = zero + TerminalCount.Plan.as506.starts.map(\.command).min()!
        let air = Self.air()
        func advance(_ c: inout GroundCloud, to t: Double) {
            c.advance(to: zero + t, sources: { Self.sources(at: $0, zero: zero) }, air: air,
                      deckHeight: LC39A.placement().height, siteFromEastNorth: { e, n in Vec3(n, -e, 0) })
        }
        var once = GroundCloud(origin: start), framed = GroundCloud(origin: start)
        advance(&once, to: 20)
        var t = -6.4
        while t < 20 { t = min(20, t + 1.0 / 30); advance(&framed, to: t) }
        XCTAssertEqual(once, framed)
        XCTAssertEqual(once.lobes(at: zero + 10.2), framed.lobes(at: zero + 10.2))
        var tenth = GroundCloud(origin: start)
        advance(&tenth, to: 10.2)
        XCTAssertEqual(once.lobes(at: zero + 10.2)[0].front, tenth.lobes[0].front, accuracy: 30, "within a sample")
    }
}
