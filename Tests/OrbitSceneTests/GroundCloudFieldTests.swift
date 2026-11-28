import Foundation
import XCTest
import OrbitCore
@testable import OrbitScene

/// The launch cloud's medium (`GroundCloudField`): its primitives carry
/// GroundCloud's exhaust, water, smoke, soot and heat; its wall jet carries
/// on from P2's; it is a function of GroundCloud's state alone, so a
/// rebuilt field is the frames' to the bit; its condensate is the
/// saturation adjustment's, on the launch day's humidity.
final class GroundCloudFieldTests: XCTestCase {
    /// AS-506's launch as `GroundCloudTests` runs it, with the gas
    /// generators' start smoke from the plan's start commands to its
    /// ignitions and the deck's wall jet from the plume's envelope.
    static func sources(at t: Epoch, zero: Epoch) -> GroundCloud.Sources {
        var s = GroundCloudTests.sources(at: t, zero: zero)
        let plan = TerminalCount.Plan.as506
        let range = t - zero, fm = plan.release
        let film = ApolloExhaust.f1.spec.film!
        let each = film.massFraction * ApolloExhaust.f1.ratedFlow
        s.startSmoke = Double(plan.starts.filter { range >= $0.command && range < $0.ignition }.count) * each
        let climb = range < fm ? 0 : LiftoffRise.rise(after: range - fm)
        s.deckRadius = PadExhaust.footprint(height: PadExhaust.exitHeightOnPad + climb)
        return s
    }

    static let air = GroundCloudTests.air()
    static let deck = LC39A.placement().height
    static let zero = VesselLibrary.apollo11RangeZero
    static let start = zero + TerminalCount.Plan.as506.starts.map(\.command).min()!

    /// The cloud at range time `range`, advanced in frames of `every` s.
    static func cloud(to range: Double, every: Double? = nil) -> GroundCloud {
        var c = GroundCloud(origin: start)
        func advance(to t: Double) {
            c.advance(to: zero + t, sources: { Self.sources(at: $0, zero: zero) }, air: air, deckHeight: deck,
                      siteFromEastNorth: { e, n in Vec3(n, -e, 0) })
        }
        guard let every else {
            advance(to: range)
            return c
        }
        var t = start - zero
        while t < range { t = min(range, t + every); advance(to: t) }
        return c
    }

    static func field(_ c: GroundCloud, at range: Double,
                      handover: GroundCloudField.WallJetHandover? = nil) -> GroundCloudField {
        GroundCloudField(c, at: zero + range, air: air, deckHeight: deck, handover: handover)
    }

    /// GroundCloud's totals: exhaust, water (boiled and the exhaust's),
    /// smoke, soot and heat.
    static func totals(_ c: GroundCloud, field f: GroundCloudField)
        -> (exhaust: Double, water: Double, smoke: Double, soot: Double, heat: Double) {
        var t = (0.0, 0.0, 0.0, 0.0, 0.0)
        for l in c.state(at: f.epoch).lobes {
            let a = f.ambient(height: l.centre.z)
            t.0 += l.exhaust
            t.1 += l.water + LaunchCloudOptics.exhaustWater * l.exhaust
            t.2 += l.smoke
            t.3 += l.soot
            t.4 += l.heat(density: a.rho, ambient: a.temperature)
        }
        return t
    }

    /// The integral of `p`'s density over the space about it (site
    /// points), by the midpoint rule: a thermal's over a box, cells a tenth
    /// of its radius; a jet's or a stem's about its axis, out to 3.5
    /// e-folds; the wall jet's over a polar grid.
    static func integral(_ p: GroundCloudField.Primitive) -> Double {
        switch p.shape {
        case .thermal:
            let r = p.radius * 2.6, cell = p.radius / 10
            let lo = p.origin - Vec3(r, r, r * 1.2), hi = p.origin + Vec3(r, r, r * 1.2)
            let n = [(hi.x - lo.x), (hi.y - lo.y), (hi.z - lo.z)].map { Int(($0 / cell).rounded(.up)) }
            let d = Vec3((hi.x - lo.x) / Double(n[0]), (hi.y - lo.y) / Double(n[1]), (hi.z - lo.z) / Double(n[2]))
            var sum = 0.0
            for i in 0..<n[0] {
                let x = lo.x + (Double(i) + 0.5) * d.x
                for j in 0..<n[1] {
                    let y = lo.y + (Double(j) + 0.5) * d.y
                    for k in 0..<n[2] { sum += p.density(at: Vec3(x, y, lo.z + (Double(k) + 0.5) * d.z)) }
                }
            }
            return sum * d.x * d.y * d.z
        case .roundJet, .stem:
            let (u, v) = LaunchTurbulence.perpendicular(p.axis)
            let a = p.shape == .stem ? 0 : p.start, b = p.end
            let nx = 300, nr = 60, nphi = 24
            let dx = (b - a) / Double(nx)
            var sum = 0.0
            for i in 0..<nx {
                let x = a + (Double(i) + 0.5) * dx
                let e = 3.5 * (p.shape == .stem ? p.stemRadius(x) : p.jetRadius(x)), dr = e / Double(nr)
                var ring = 0.0
                for j in 0..<nr {
                    let r = (Double(j) + 0.5) * dr
                    for k in 0..<nphi {
                        let phi = 2 * Double.pi * (Double(k) + 0.5) / Double(nphi)
                        ring += p.density(at: p.origin + p.axis * x + u * (r * cos(phi)) + v * (r * sin(phi))) * r
                    }
                }
                sum += ring * dr * (2 * .pi / Double(nphi))
            }
            return sum * dx
        case .wallJet:
            return polarIntegral(p, from: p.start, to: p.end) { p.density(at: $0) }
        }
    }

    /// The integral of the wall jet's density over a polar grid (site
    /// points), ρ from `a` to `b`: ∫∫∫ d ρ dρ dφ dz.
    static func polarIntegral(_ p: GroundCloudField.Primitive, from a: Double, to b: Double,
                              _ f: (Vec3) -> Double) -> Double {
        let nr = 400, nphi = 24, nz = 60
        let dr = (b - a) / Double(nr), top = 1.6 * p.thickness(b), dz = top / Double(nz)
        var sum = 0.0
        for i in 0..<nr {
            let rho = a + (Double(i) + 0.5) * dr
            for j in 0..<nphi {
                let phi = 2 * Double.pi * (Double(j) + 0.5) / Double(nphi)
                for k in 0..<nz {
                    sum += f(p.origin + Vec3(rho * cos(phi), rho * sin(phi), (Double(k) + 0.5) * dz)) * rho
                }
            }
        }
        return sum * dr * (2 * .pi / Double(nphi)) * dz
    }

    // The field carries GroundCloud's exhaust, water, smoke, soot and heat:
    // its primitives' contents (and what P2 draws) add up to the clouds',
    // and each primitive's shape integrates to one over the space it fills
    // (its image in the ground folded back), so the medium holds them
    // within 1 % (look round 2, LR4's first test). From the start smoke
    // to a cloud a minute old.
    func testFieldCarriesTheCloudsMassAndHeat() {
        for t in [-4.5, 2, 5, 8, 15, 60] {
            let c = Self.cloud(to: t), f = Self.field(c, at: t)
            XCTAssertLessThanOrEqual(f.primitives.count, GroundCloudField.maximum)
            let want = Self.totals(c, field: f), got = f.totals
            for (name, a, b) in [("exhaust", got.exhaust, want.exhaust), ("water", got.water, want.water),
                                 ("smoke", got.smoke, want.smoke), ("soot", got.soot, want.soot),
                                 ("heat", got.heat, want.heat)] {
                XCTAssertEqual(a, b, accuracy: 1e-9 * max(abs(b), 1), "T\(t) s: \(name)")
            }
            // Integrated over space, as the renderer meets them.
            var integrated = (source: f.inPlume.source, soot: f.inPlume.soot, heat: f.inPlume.heat)
            for p in f.primitives {
                let i = Self.integral(p)
                XCTAssertEqual(i, 1, accuracy: 0.01, "T\(t) s: \(p.shape) \(p.lobe)")
                integrated.source += p.source * i
                integrated.soot += p.soot * i
                integrated.heat += p.heat * i
            }
            XCTAssertEqual(integrated.source, want.exhaust + want.water + want.smoke,
                           accuracy: 0.01 * (want.exhaust + want.water + want.smoke), "T\(t) s")
            XCTAssertEqual(integrated.soot, want.soot, accuracy: 0.01 * want.soot, "T\(t) s")
            XCTAssertEqual(integrated.heat, want.heat, accuracy: 0.01 * abs(want.heat), "T\(t) s")
        }
    }

    /// AS-506's five F-1s on the pad, `climb` m up, as P2's members
    /// (site-relative: the deck's centre at the origin), and the deck.
    static func p2(climb: Double) -> (members: [PlumeMember], deck: PlumeImpingement) {
        let spec = ApolloExhaust.f1.spec
        let air = USStandardAtmosphere1976().state(altitude: 0)
        let state = PlumeModel.state(spec, flowFraction: 1, ambient: air, streamAlong: 0, streamAcross: 0)
        let z = PadExhaust.exitHeightOnPad + climb, d = 4.6 / 2.0.squareRoot()
        let exits = [Vec3(0, 0, z), Vec3(d, d, z), Vec3(-d, d, z), Vec3(-d, -d, z), Vec3(d, -d, z)]
        let deck = PlumeImpingement(centre: .zero, normal: .unitZ, openingHalf: LC39A.openingHalf, openingAxis: .unitX)
        let members = exits.map {
            PlumeLook.member(spec, state: state, exit: $0, axis: -.unitZ, exitRadius: spec.exitRadius, ambient: air)
        }
        return (members, deck)
    }

    // The deck's wall jet carries on from P2's (`PlumeImpingement`): from
    // where P2's ends, with P2's half-thickness there and its growth, 0.087
    // a metre (Poreh, Tsuei and Cermak 1967), within 1 %; and its flow is
    // continuous through the joint: what P2 draws ahead of it and what the
    // field draws past it carry the same share of the deck lobe's feed, the
    // flux through every cylinder the feed's within 1 % (the mass the wall
    // jet holds per unit radius is the flow over the layer's speed there,
    // the speed that keeps all its momentum).
    func testWallJetCarriesOnFromP2s() throws {
        let t = 8.0
        let c = Self.cloud(to: t)
        let fm = TerminalCount.Plan.as506.release
        let climb = LiftoffRise.rise(after: t - fm)
        let (members, deck) = Self.p2(climb: climb)
        let handover = try XCTUnwrap(GroundCloudField.WallJetHandover.p2(members, deck: deck), "P2 meets the deck")
        let f = Self.field(c, at: t, handover: handover)
        let wall = try XCTUnwrap(f.primitives.first { $0.shape == .wallJet })
        XCTAssertEqual(wall.start, handover.radius, accuracy: 1e-9)
        // P2's own thickness at the joint, its central engine's.
        let centre = members[0]
        let meeting = try XCTUnwrap(deck.meeting(centre))
        let h = try XCTUnwrap(deck.distance(centre))
        let p2 = meeting.thickness(centre, h: h, rho: meeting.reach)
        XCTAssertEqual(wall.thickness(wall.start), p2, accuracy: 0.01 * p2, "half-thickness at the joint")
        XCTAssertEqual(wall.growth, PlumeImpingement.wallGrowth)
        // The flux through cylinders: ∫ c u dA, the speed u0 p(z/δ).
        let lobe = try XCTUnwrap(c.state(at: f.epoch).lobes.first { $0.kind == .deck })
        let feed = lobe.feed.exhaust + lobe.feed.water + LaunchCloudOptics.exhaustWater * lobe.feed.exhaust
        let share = wall.source / feed / (wallTime(wall, lobe))
        XCTAssertLessThanOrEqual(share, 1 + 1e-9)
        for rho in [wall.start + 0.5, wall.start + 5, 0.5 * (wall.start + wall.end), wall.end - wall.taper - 1] {
            let d = wall.thickness(rho), u0 = GroundCloudField.wallSpeed(momentum: wall.flux, rho: rho, thickness: d)
            var flux = 0.0
            let n = 4_000, dz = 2 * d / Double(n)
            for k in 0..<n {
                let z = (Double(k) + 0.5) * dz
                let q = GroundCloudField.wallProfile(z / d)
                flux += wall.source * wall.density(at: Vec3(rho, 0, z)) * u0 * q * dz
            }
            flux *= 2 * .pi * rho
            XCTAssertEqual(flux, share * feed, accuracy: 0.01 * share * feed, "flux at ρ = \(rho) m")
        }
        // P2's part ahead of it: the same share of the feed over its own
        // stretch, so nothing is lost or gained at the joint.
        if f.inPlume.source > 0 {
            var behind = wall
            behind.start = lobe.start
            behind.end = wall.start
            behind.radius = wall.radius - wall.growth * (wall.start - lobe.start)
            let time = GroundCloudField.gauss(lobe.start, wall.start) { rho in
                GroundCloudField.wallProfileIntegral / GroundCloudField.wallProfileSquare
                    / GroundCloudField.wallSpeed(momentum: wall.flux, rho: rho, thickness: behind.thickness(rho))
            }
            XCTAssertEqual(f.inPlume.source, share * feed * time, accuracy: 1e-6 * f.inPlume.source)
        }
        // What P2 itself puts on the deck, against the deck lobe's (P4's
        // envelope model): reported, the two models' split is not the same.
        let p2Share = members.reduce(0.0) { $0 + (deck.meeting($1)?.deckShare ?? 0) } / Double(members.count)
        print(String(format: "T+%.0f s, climb %.1f m: P2's wall jet to %.1f m (δ %.2f m); the deck's share P2 %.3f, PadExhaust %.3f",
                     t, climb, handover.radius, handover.thickness, p2Share,
                     PadExhaust.shares(exitHeight: PadExhaust.exitHeightOnPad + climb).deck))
    }

    /// The time's worth of the feed the wall jet holds at its steady flow.
    func wallTime(_ w: GroundCloudField.Primitive, _ l: GroundCloud.Lobe) -> Double {
        GroundCloudField.gauss(w.start, w.end) { rho in
            GroundCloudField.wallProfileIntegral / GroundCloudField.wallProfileSquare * w.along(rho)
                / (rho * w.thickness(rho)).squareRoot()
                / GroundCloudField.wallSpeed(momentum: l.feed.momentum, rho: rho, thickness: w.thickness(rho))
        }
    }

    // The field is a function of GroundCloud's state alone: advanced at
    // once or in frames of 1/30 s (through the start smoke, the ignition,
    // first motion), the fields at the same epoch are identical to the
    // bit, and so are their GPU records; and a field built twice is.
    func testRebuiltFieldIsBitIdentical() {
        let frames = Self.cloud(to: 20, every: 1.0 / 30)
        let once = Self.cloud(to: 20)
        XCTAssertEqual(frames, once)
        for t in [20.0, 20 - 0.01, 12.3, -4.2] {
            let a = Self.field(frames, at: t), b = Self.field(once, at: t)
            XCTAssertEqual(a, b, "T\(t) s")
            XCTAssertEqual(EffectMedium(a), EffectMedium(b), "T\(t) s")
            XCTAssertEqual(a, Self.field(frames, at: t))
        }
        // A frame after another sees the field move on smoothly: its cloud
        // centres carried along their velocity between grid steps.
        let f0 = Self.field(once, at: 20), f1 = Self.field(once, at: 20 + 0.02)
        for (a, b) in zip(f0.primitives, f1.primitives) where a.shape == .thermal {
            XCTAssertLessThan((b.origin - a.origin).length, 2, "\(a.lobe)")
        }
    }

    // The condensate is the saturation adjustment's: where the mixture of
    // the pad's water and heat with the air is unsaturated, none. The jets
    // out of the trench are far too hot to hold any; a jet whose exhaust
    // has faded while the deluge still runs carries saturated steam, which
    // condenses. Printed at the clouds' cores and tops: L inputs, flagged.
    func testCondensateIsTheSaturationAdjustments() throws {
        let hot = Self.field(Self.cloud(to: 3), at: 3)
        let jet = try XCTUnwrap(hot.primitives.first { $0.shape == .roundJet })
        let exit = hot.sample(at: jet.origin + jet.axis * (jet.start + 1))
        XCTAssertGreaterThan(exit.temperature, 600)
        XCTAssertEqual(exit.condensate, 0)
        // The trench's exhaust fades as the jets outgrow the opening while
        // its water runs on: find when its jet first holds condensate.
        var white: Double?
        for t in stride(from: 4.0, through: 40, by: 2) {
            let f = Self.field(Self.cloud(to: t), at: t)
            guard let jet = f.primitives.first(where: { $0.shape == .roundJet }) else { continue }
            if f.sample(at: jet.origin + jet.axis * (0.5 * (jet.start + jet.end))).condensate > 0 { white = t; break }
        }
        let t = try XCTUnwrap(white, "the deluge's steam, its exhaust faded")
        print(String(format: "the trench jets first hold condensate at T+%.0f s", t))
        for t in [10.0, 30, 60, 120, 180, 240, 300] {
            let f = Self.field(Self.cloud(to: t), at: t)
            for p in f.primitives where p.shape == .thermal && p.lobe != .startSmoke(0) {
                let core = f.sample(at: p.origin), top = f.sample(at: p.origin + Vec3(0, 0, p.radius))
                let a = f.ambient(height: p.origin.z)
                print(String(format: "T+%3.0f s %@: %4.0f m up, R %4.0f m; core %5.1f K (air %5.1f K, RH %3.0f %%) %.2e kg/m³ condensate, %.2e soot; top %5.1f K %.2e kg/m³",
                             t, "\(p.lobe)", p.origin.z, p.radius, core.temperature, a.temperature,
                             100 * MoistAir.vapourPressure(specificHumidity: core.airHumidity, pressure: a.pressure)
                                 / MoistAir.saturationPressure(a.temperature),
                             core.condensate, core.soot, top.temperature, top.condensate))
            }
        }
    }

    // The launch day's humidity is TM X-64796's surface observation for
    // AS-506 (its Table 1, tools/data/tmx64796_table1_saturn.csv): 29.4 °C
    // and 73 % at 10.203 N/cm², a mixing ratio of 18.8 g/kg and a dew point
    // of 24.0 °C. Lifted, it saturates at about 0.7 km: the base FER-506's
    // Appendix A gives the launch's 1/10 cumulus. Aloft it is the 1983 Cape
    // RRA's July means (12-18Z): 72.4 % at 1 km, 65.1 % at 2 km, 57.5 % at
    // 3 km (the relative humidity of its mean temperature and vapour pressure).
    func testHumidityIsTMX64796sAndTheRRAs() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/data/tmx64796_table1_saturn.csv")
        let text = try String(contentsOf: url, encoding: .utf8)
        let row = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("145,AS-506,") })
        let cells = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let h = LaunchHumidity.as506
        XCTAssertEqual(Double(cells[7])! * 1e4, h.pressure, accuracy: 0.5)
        XCTAssertEqual(Double(cells[8])! + 273.15, h.temperature, accuracy: 1e-9)
        XCTAssertEqual(Double(cells[9])! / 100, h.relativeHumidity, accuracy: 1e-9)
        XCTAssertEqual(h.mixingRatio * 1_000, 18.8, accuracy: 0.05)
        // The dew point: where the vapour's pressure saturates.
        var lo = 270.0, hi = 310.0
        for _ in 0..<60 {
            let m = 0.5 * (lo + hi)
            if MoistAir.saturationPressure(m) < h.vapourPressure { lo = m } else { hi = m }
        }
        XCTAssertEqual(lo - 273.15, 24.05, accuracy: 0.05)
        let base = h.condensationLevel(Self.air, surfaceHeight: Self.deck)
        XCTAssertEqual(base, 700, accuracy: 100, "FER-506: the cumulus's base at 0.7 km")
        // Aloft: the RRA's means, and the field's air.
        for (z, rh) in [(1_000.0, 0.724), (2_000, 0.651), (3_000, 0.575)] {
            XCTAssertEqual(h.relativeHumidity(height: z), rh, accuracy: 0.001, "\(z) m")
        }
        XCTAssertEqual(h.relativeHumidity(height: 500), 0.5 * (0.73 + h.relativeHumidity(height: 1_000)), accuracy: 1e-12)
        let f = Self.field(Self.cloud(to: -5), at: -5)
        for z in [0.0, 1_000, 2_000] {
            let a = f.ambient(height: z)
            let rh = MoistAir.vapourPressure(specificHumidity: a.humidity, pressure: a.pressure)
                / MoistAir.saturationPressure(a.temperature)
            XCTAssertEqual(rh, h.relativeHumidity(height: z), accuracy: 1e-6, "\(z) m")
        }
        print(String(format: "the surface air's condensation level %.0f m; RH 1 km %.1f %%, 2 km %.1f %%", base,
                     100 * h.relativeHumidity(height: 1_000), 100 * h.relativeHumidity(height: 2_000)))
    }

    // The field at a few moments of AS-506's launch, printed.
    func testFieldPrintout() {
        for t in [-4.0, 2, 5, 10, 15, 30, 60, 120] {
            let c = Self.cloud(to: t)
            let f = Self.field(c, at: t)
            print(String(format: "T%+5.0f s: %d primitives", t, f.primitives.count))
            for p in f.primitives {
                let a = f.ambient(height: p.origin.z)
                let s = f.sample(at: p.shape == .thermal ? p.origin : p.origin + p.axis * (0.5 * (p.start + p.end)))
                print(String(format: "  %@ %@ at (%6.0f %6.0f %6.0f) %5.0f-%5.0f m r %5.1f: exhaust %8.0f kg water %8.0f smoke %6.0f soot %6.1f heat %.2e J q_air %.4f (amb %.4f); mid T %.1f K cond %.2e kg/m³ src %.2e",
                             "\(p.shape)", "\(p.lobe)", p.origin.x, p.origin.y, p.origin.z, p.start, p.end, p.radius,
                             p.exhaust, p.water, p.smoke, p.soot, p.heat, p.airHumidity, a.humidity,
                             s.temperature, s.condensate, s.source))
            }
        }
    }
}
