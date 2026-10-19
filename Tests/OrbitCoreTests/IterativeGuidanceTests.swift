import XCTest
@testable import OrbitCore

/// `IterativeGuidance` on its own: the GE504 stage integrals, and the IGM
/// flying a point mass with the AS-506 model's S-II and S-IVB performance
/// from AS-506's state at 200 s (Boeing D5-15560-6, Postflight Trajectory
/// AS-506, Table B-II) to its target orbit. Datasheet §10.
final class IterativeGuidanceTests: XCTestCase {
    let deg = Double.pi / 180
    let mu = 3.986004418e14

    // The integrals of a = Vex/(τ - t) over T are what GE504 Table 4-IV
    // writes in closed form: L = ∫a, J = ∫a t, S = ∫(T - t)a, Q = ∫t(T - t)a,
    // P = ∫t² a, U = ∫t²(T - t)a. Simpson's rule, 2,000 intervals.
    func testStageIntegralsAreTheThrustMoments() {
        for (vex, tau, t) in [(4_175.4, 480.0, 290.0), (4_192.8, 773.5, 144.0), (4_200.6, 347.0, 53.4)] {
            let c = IterativeGuidance.integrals(vex, tau, t)
            func integral(_ f: (Double) -> Double) -> Double {
                let n = 2_000, h = t / Double(n)
                var sum = f(0) + f(t)
                for i in 1..<n { sum += f(Double(i) * h) * (i % 2 == 1 ? 4 : 2) }
                return sum * h / 3
            }
            func a(_ s: Double) -> Double { vex / (tau - s) }
            XCTAssertEqual(c.l, integral { a($0) }, accuracy: abs(c.l) * 1e-10)
            XCTAssertEqual(c.j, integral { a($0) * $0 }, accuracy: abs(c.j) * 1e-10)
            XCTAssertEqual(c.s, integral { a($0) * (t - $0) }, accuracy: abs(c.s) * 1e-10)
            XCTAssertEqual(c.q, integral { a($0) * $0 * (t - $0) }, accuracy: abs(c.q) * 1e-10)
            XCTAssertEqual(c.p, integral { a($0) * $0 * $0 }, accuracy: abs(c.p) * 1e-10)
            XCTAssertEqual(c.u, integral { a($0) * $0 * $0 * (t - $0) }, accuracy: abs(c.u) * 1e-10)
        }
        XCTAssertEqual(IterativeGuidance.integrals(4_175.4, 480, 0).l, 0)
    }

    // GE504 Fig 4-5: an S-II that burns on after T2 has run out leaves T2 at
    // 0 (stage 2 over), not negative, until its cutoff starts the coast; the
    // time to go is then the coast's and the S-IVB's.
    func testT2HoldsAtZeroWhenTheSIIBurnsLonger() {
        let f = PointMassFlight(presettings: presettings())
        var igm = IterativeGuidance(presettings: f.presettings, launchLatitude: f.latitude, azimuth: f.azimuth)
        let nav = IGMNavigation(position: f.r, velocity: f.v, gravity: f.r.normalized * -9.5, sensedAcceleration: 12,
                                characteristicVelocity: f.presettings.shiftVelocity + 1)
        XCTAssertTrue(igm.cycle(nav, interval: nil).commandShift)
        XCTAssertEqual(igm.t2, f.presettings.stage2Time)
        for _ in 0..<40 { _ = igm.cycle(nav, interval: 1.7) }   // 68 s, T2 53.4 s
        XCTAssertEqual(igm.stage, .second)
        XCTAssertEqual(igm.t1, 0)
        XCTAssertEqual(igm.t2, 0)
        XCTAssertEqual(igm.tc, f.presettings.coastTime)
    }

    /// The AS-506 model's S-II and S-IVB as a point mass: five J-2s at high
    /// EMR to the centre engine cutoff at 460.6 s, then four; the low EMR
    /// 2.8 s after the IGM's shift command; the S-II's LOX gone at the model's
    /// OECO mass; separation, the S-IVB's start ramp, and the velocity cutoff.
    /// `outboardEngineOut`: an outboard J-2 out from this range time, with
    /// the IU's discrete (the factor 4/3) unless `ignoreDiscrete`.
    /// `sIIDropped`: the S-II dropped by hand at this range time, its cutoff
    /// discrete with it.
    struct PointMassFlight {
        var presettings: IGMPresettings
        var latitude = 28.6084 * Double.pi / 180     // the PFT's X_S: the geodetic vertical
        var azimuth = 72.058 * Double.pi / 180
        /// Range time, PACSS 13 position (m) and velocity (m/s), and mass (kg).
        var t = 200.0
        var r = Vec3(6_464_247, 44_119, 264_596)
        var v = Vec3(576.4, 120.7, 2_884.5)
        var m = 608_178.0
        var chi = Vec3(0, -68.74 * Double.pi / 180, -0.05 * Double.pi / 180)
        var j2 = 1.08262668e-3
        var outboardEngineOut: Double?
        var ignoreDiscrete = false
        var sIIDropped: Double?
        /// The S-IVB's vacuum thrust (N), on its 215.37 kg/s.
        var sIVBThrust = 903_000.0
        /// The flight stops here if the S-IVB has not cut off (range time, s).
        var end = 760.0

        struct Result {
            var r: Vec3, v: Vec3, cutoff: Double, shift: Double?, terminalGuidance: Double?
            /// The IGM's T2 on the cycle that commanded the shift.
            var t2AtShift: Double?
            var highSpeedLoop: Double?, sIIOut: Double, sIVBAtThrust: Double?, guidance: IterativeGuidance
            var pitch: [(t: Double, deg: Double)]
            /// The cycles that gave no command before the high-speed loop.
            var frozen: [Double]
            /// Every cycle's T3 and τ3 after it, and its commands (rad).
            var cycles: [(t: Double, t3: Double, tau3: Double, pitch: Double?, yaw: Double?)]
        }

        mutating func fly() -> Result {
            let mu = presettings.mu, h = 0.02
            let pole = Vec3(sin(latitude), -sin(azimuth) * cos(latitude), cos(azimuth) * cos(latitude))
            let earth = CelestialBody(id: 399, name: "Earth", gm: mu, radius: 6_378_137, j2: j2, rotation: .earth,
                                      soiRadius: .infinity)
            var igm = IterativeGuidance(presettings: presettings, launchLatitude: latitude, azimuth: azimuth)
            let hi = (thrust: 1_028_303.0, flow: 1_028_303 / 4_175.37), lo = (thrust: 768_000.0, flow: 768_000 / 4_200.55)
            var outboard = 4.0, centre = 1.0, low = false, shiftAt: Double?, sIIOut: Double?, ignition: Double?
            var t2AtShift: Double?
            var cutoff: Double?, tg: Double?, hsl: Double?
            var target = chi, lastCycle: Double?, sensed = 0.0, bnvc = 0.0, pitch: [(Double, Double)] = []
            var frozen: [Double] = []
            var cycles: [(t: Double, t3: Double, tau3: Double, pitch: Double?, yaw: Double?)] = []
            func atThrust(_ t: Double) -> Bool { ignition.map { t >= $0 + 0.6 + 0.9 * 1.9 } ?? false }
            func thrust(_ t: Double) -> (Double, Double) {
                if cutoff != nil { return (0, 0) }
                if let s = ignition {
                    let f = min(1, max(0, (t - s - 0.6) / 1.9))
                    return (sIVBThrust * f, 215.37 * f)
                }
                if sIIOut != nil { return (0, 0) }
                let e = low ? lo : hi
                return ((outboard + centre) * e.thrust, (outboard + centre) * e.flow)
            }
            while t < end && cutoff == nil {
                // The vehicle's events.
                if centre == 1 && t >= 460.6 - 1e-9 { centre = 0 }
                if let out = outboardEngineOut, outboard == 4 && t >= out - 1e-9 { outboard = 3 }
                if let s = shiftAt, !low, t >= s + 2.8 - 1e-9 { low = true }
                if sIIOut == nil && (m <= 214_248 || sIIDropped.map { t >= $0 - 1e-9 } ?? false) {
                    sIIOut = t
                    m = 166_751
                }
                if let s = sIIOut, ignition == nil, t >= s + 4.0 - 1e-9 { ignition = t }
                let (f, _) = thrust(t)
                let fm = f / m
                // A guidance cycle every 1.7 s, on the cycle's mean F/m.
                if lastCycle == nil || t - lastCycle! >= 1.7 - 1e-9 {
                    let interval = lastCycle.map { t - $0 }
                    let nav = IGMNavigation(position: r, velocity: v, gravity: earth.gravity(at: r, pole: pole),
                                            sensedAcceleration: interval.map { sensed / $0 } ?? fm,
                                            characteristicVelocity: bnvc, sIICutoff: sIIOut != nil,
                                            sIVBIgnition: atThrust(t),
                                            stage2EngineFactor: outboard < 4 && !ignoreDiscrete ? 4 / outboard : 1)
                    let out = igm.cycle(nav, interval: interval)
                    if let p = out.pitch, let y = out.yaw { target = Vec3(0, p, y) }
                    if out.pitch == nil && !igm.highSpeedLoop { frozen.append(t) }
                    if out.commandShift {
                        shiftAt = t
                        t2AtShift = igm.t2
                    }
                    if out.beganTerminalGuidance { tg = t }
                    if out.enteredHighSpeedLoop { hsl = t }
                    cycles.append((t, igm.t3, igm.tau3, out.pitch, out.yaw))
                    lastCycle = t
                    sensed = 0
                    pitch.append((t, target.y / Double.pi * 180))
                }
                // The velocity cutoff in the high-speed loop: the last step
                // ends on it.
                var dt = h
                if igm.highSpeedLoop {
                    let rate = v.normalized.dot(direction(chi)) * fm + earth.gravity(at: r, pole: pole)
                        .dot(v.normalized)
                    dt = min(h, igm.cutoffTimeToGo(speed: v.length, rate: rate))
                }
                // The attitude follows the command at 1°/s.
                let step = 1.0 * Double.pi / 180 * dt
                chi.y += max(-step, min(step, target.y - chi.y))
                chi.z += max(-step, min(step, target.z - chi.z))
                // Midpoint step.
                let a0 = earth.gravity(at: r, pole: pole) + direction(chi) * fm
                let rm = r + v * (dt / 2), vm = v + a0 * (dt / 2)
                let (fh, mdh) = thrust(t + dt / 2)
                let am = earth.gravity(at: rm, pole: pole) + direction(chi) * (fh / (m - mdh * dt / 2))
                r += vm * dt
                v += am * dt
                m -= mdh * dt
                sensed += fh / m * dt
                if sIIOut == nil { bnvc += fh / m * dt }
                t += dt
                if dt < h { cutoff = t }
            }
            return Result(r: r, v: v, cutoff: cutoff ?? t, shift: shiftAt, terminalGuidance: tg, t2AtShift: t2AtShift,
                          highSpeedLoop: hsl,
                          sIIOut: sIIOut ?? .nan, sIVBAtThrust: ignition.map { $0 + 0.6 + 0.9 * 1.9 }, guidance: igm,
                          pitch: pitch, frozen: frozen, cycles: cycles)
        }

        func direction(_ chi: Vec3) -> Vec3 {
            Vec3(cos(chi.z) * cos(chi.y), sin(chi.z), -cos(chi.z) * sin(chi.y))
        }
    }

    /// Datasheet §10.3's presettings, except the point mass's own: V_C (its
    /// characteristic velocity is summed from 200 s, not from S-II ignition),
    /// ΔV_B (no thrust decay) and τ2 (from its estimated mass).
    func presettings() -> IGMPresettings {
        IGMPresettings(exhaustVelocity: (4_175.37, 4_200.55, 4_192.78), tau2: 347.0, tau3: 773.5,
                       stage2Time: 53.4, coastTime: 6.3, stage3Time: 144.8, shiftVelocity: 3_652,
                       artificialTau: (9.0, 6.0), rangeAngleBias: 1.5, lead: 2.0, terminalGuidanceTime: 35,
                       cutoffLoopTime: 8, cutoffLoopVelocityMargin: 300, cutoffVelocityBias: 1.6,
                       terminalRadius: 6_563_365, terminalFlightPathAngle: 0, inclination: 32.531 * deg,
                       descendingNode: 123.100 * deg, mu: mu)
    }

    /// Inclination and descending node of (r, v) in the space-fixed frame
    /// (FER §7 definitions, as the targeting uses them).
    func plane(_ r: Vec3, _ v: Vec3, latitude: Double, azimuth: Double) -> (i: Double, node: Double) {
        let pole = Vec3(sin(latitude), -sin(azimuth) * cos(latitude), cos(azimuth) * cos(latitude))
        let h = r.cross(v).normalized
        let i = acos(h.dot(pole))
        let meridian = (Vec3.unitX - pole * pole.x).normalized, east = pole.cross(meridian)
        let node = -pole.cross(h).normalized   // descending node direction
        var n = atan2(node.dot(east), node.dot(meridian))
        if n < 0 { n += 2 * Double.pi }
        return (i, n)
    }

    // The IGM takes the point mass from AS-506's state at 200 s to its target:
    // the velocity cutoff at V_T - ΔV_B, on the target radius and flight-path
    // angle, in the target plane: 100 m, 0.005° and 0.002° (it gets 49 m,
    // 0.0007° and 0.001°). Its MRS command comes once the S-II's
    // characteristic velocity is gained, the steering freezes through the
    // S-II/S-IVB coast, terminal guidance and the high-speed loop start at
    // their total times to go, and the cutoff comes about where AS-506's did
    // (699.34 s, FER Table 2-2). The pitch history follows AS-506's commands
    // (FER Figure 10-4, LVDC: about -64° at 240 s, -82° at 400 s, -97.8° at
    // S-II OECO, -113.8° at 680 s) within 3°; it is within about 1°.
    func testIGMFliesAPointMassFromAS506StateToTheTargetOrbit() throws {
        var flight = PointMassFlight(presettings: presettings())
        let res = flight.fly()
        let p = presettings(), igm = res.guidance
        XCTAssertEqual(res.v.length, igm.terminalVelocity - p.cutoffVelocityBias, accuracy: 0.01)
        XCTAssertEqual(res.r.length, p.terminalRadius, accuracy: 100)
        XCTAssertEqual(asin(res.r.normalized.dot(res.v.normalized)) / deg, 0, accuracy: 0.005)
        let (i, node) = plane(res.r, res.v, latitude: flight.latitude, azimuth: flight.azimuth)
        XCTAssertEqual(i / deg, 32.531, accuracy: 0.002)
        XCTAssertEqual(node / deg, 123.100, accuracy: 0.002)
        // The point mass's S-II is the model's only roughly (its mass at 200 s
        // is estimated), so the burn times are checked to a few seconds.
        XCTAssertEqual(res.cutoff, 699.34, accuracy: 4)
        XCTAssertEqual(try XCTUnwrap(res.shift), 494.8, accuracy: 3)
        XCTAssertEqual(res.sIIOut, 548.2, accuracy: 3)
        XCTAssertEqual(try XCTUnwrap(res.terminalGuidance), res.cutoff - 35, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(res.highSpeedLoop), res.cutoff - 8, accuracy: 2)
        // The steering freezes from the first cycle after the S-II cutoff
        // until the S-IVB's 90 % thrust, and only then.
        let atThrust = try XCTUnwrap(res.sIVBAtThrust)
        XCTAssertEqual(try XCTUnwrap(res.frozen.first), res.sIIOut, accuracy: 1.7)
        XCTAssertEqual(try XCTUnwrap(res.frozen.last), atThrust, accuracy: 1.7)
        XCTAssertTrue(res.frozen.allSatisfy { $0 >= res.sIIOut && $0 < atThrust }, "\(res.frozen)")
        XCTAssertGreaterThanOrEqual(res.frozen.count, 3)
        for (t, fer) in [(240.0, -64.1), (400, -81.6), (548, -97.8), (680, -113.8)] {
            let near = res.pitch.min { abs($0.t - t) < abs($1.t - t) }!
            XCTAssertEqual(near.deg, fer, accuracy: 3, "\(t) s")
        }
    }

    // An outboard J-2 out at 328.6 s (Apollo 13's time, on an outboard engine)
    // leaves three of the four engines the stage 2 presettings assume. With
    // the IU's discrete the IGM stretches T2 and τ2 by 4/3 (GE504 Fig 4-6,
    // generalised: datasheet §16), so on the shift command its T2 is the
    // three engines' burn to S-II cutoff within 3 s (71.2 s against 70.8 s),
    // as the presetting is the four engines'; without it, T2 is a quarter
    // short. Either way the shift waits for the characteristic velocity, and
    // the S-IVB still cuts off on the target: the same 100 m, 0.005° and
    // 0.002° as the nominal flight.
    func testIGMFliesAPointMassWithAnOutboardSIIEngineOut() throws {
        func fly(ignoringTheDiscrete ignore: Bool) -> PointMassFlight.Result {
            var flight = PointMassFlight(presettings: presettings())
            flight.outboardEngineOut = 328.6
            flight.ignoreDiscrete = ignore
            flight.end = 900
            return flight.fly()
        }
        let res = fly(ignoringTheDiscrete: false), blind = fly(ignoringTheDiscrete: true)
        let p = presettings(), igm = res.guidance
        XCTAssertEqual(igm.stage2EngineFactor, 4.0 / 3)
        let shift = try XCTUnwrap(res.shift), t2 = try XCTUnwrap(res.t2AtShift)
        XCTAssertEqual(t2, p.stage2Time * 4 / 3, accuracy: 1e-9)
        XCTAssertEqual(t2, res.sIIOut - shift, accuracy: 3)
        XCTAssertEqual(try XCTUnwrap(blind.t2AtShift), (blind.sIIOut - shift) * 3 / 4, accuracy: 3)
        XCTAssertEqual(try XCTUnwrap(blind.shift), shift, accuracy: 1e-9)
        XCTAssertEqual(res.v.length, igm.terminalVelocity - p.cutoffVelocityBias, accuracy: 0.01)
        XCTAssertEqual(res.r.length, p.terminalRadius, accuracy: 100)
        XCTAssertEqual(asin(res.r.normalized.dot(res.v.normalized)) / deg, 0, accuracy: 0.005)
        var flight = PointMassFlight(presettings: p)
        let (i, node) = plane(res.r, res.v, latitude: flight.latitude, azimuth: flight.azimuth)
        XCTAssertEqual(i / deg, 32.531, accuracy: 0.002)
        XCTAssertEqual(node / deg, 123.100, accuracy: 0.002)
        // Later than the nominal point mass's S-II cutoff and S-IVB cutoff.
        let nominal = flight.fly()
        XCTAssertGreaterThan(res.sIIOut - nominal.sIIOut, 20)
        XCTAssertGreaterThan(res.cutoff - nominal.cutoff, 20)
    }

    // An S-IVB that cannot reach the target: the S-II dropped by hand at
    // 200, 201.5 or 210 s (SaturnIUTests.testEarlierTimeBaseEventsDropWhen-
    // TheNextStarts drops it at 200 s), the S-IVB lit 4 s later on 166.8 t,
    // on 903 and 912 kN, to 700 s (its 107 t of propellant, SP-4029, about
    // gone). On the first cycle of the coast GE504's linearised ΔT3
    // overshoots τ3. Unbounded (Table 4-IV prints no bound), T3 went to
    // -1,016 s on the IU flight's first cycle on 912 kN and NaN by its
    // fifth, the yaw command on its 45° limit; here, the S-II dropped at
    // 201.5 s, between the IGM's first two cycles, it went from stage 1's
    // 151 s to -162 s, -1.3e4 s, -7.1e6 s and on (at 200 s it happened to
    // converge). Held 1 s inside (0, τ3) (datasheet §10.2), T3 lands within
    // 5 s of τ3 on that cycle, settles in about four more (near 567 s) and
    // then counts down with the clock, within 0.5 s a cycle (0.22 s) from
    // 10 s after the S-IVB's 90 % thrust; every command is finite, the yaw
    // within 3° of the plane (1.9°), the pitch between -15° and AS-506's
    // -114° at insertion (-21° to -94°: the IGM lofts the S-IVB towards R_T,
    // 182 km up at 700 s, 2 km/s short). Nothing cuts it off: no terminal
    // guidance and no high-speed loop.
    func testIGMStaysFiniteWhenTheSIVBCannotReachTheTarget() throws {
        for drop in [200, 201.5, 210] {
            for thrust in [903_000.0, 912_000.0] {
                var flight = PointMassFlight(presettings: presettings())
                flight.sIIDropped = drop
                flight.sIVBThrust = thrust
                flight.end = 700
                let res = flight.fly(), name = "S-II dropped at \(drop) s, \(thrust) N"
                XCTAssertEqual(res.sIIOut, drop, accuracy: 0.02, name)
                XCTAssertNil(res.terminalGuidance, name)
                XCTAssertNil(res.highSpeedLoop, name)
                let first = try XCTUnwrap(res.cycles.first { $0.t >= res.sIIOut }, name)
                XCTAssertGreaterThan(first.t3, first.tau3 - 5, name)
                let settled = try XCTUnwrap(res.sIVBAtThrust, name) + 10
                let drift = zip(res.cycles, res.cycles.dropFirst()).filter { $1.t >= settled }
                    .map { abs($1.t3 - ($0.t3 - ($1.t - $0.t))) }
                XCTAssertTrue(drift.allSatisfy { $0 <= 0.5 }, "\(name): \(drift.max() ?? .nan) s")
                let bad = res.cycles.filter { c in
                    !(c.t3 >= 1 && c.t3 <= c.tau3 - 1) || c.pitch.map { !($0 < -15 * deg && $0 > -114 * deg) } ?? false
                        || c.yaw.map { !(abs($0) < 3 * deg) } ?? false
                }
                XCTAssertTrue(bad.isEmpty, "\(name): \(bad.count) cycles, the first \(bad.first.map { "\($0)" } ?? "")")
                XCTAssertGreaterThan(res.cycles.filter { $0.pitch != nil }.count, 250, name)
            }
        }
    }

    // T3 run out by the clock before the high-speed loop (here a cycle
    // late by T3 and 300 s more, by T3 and 1 ns, and by T3 exactly, on
    // AS-506's state at 200 s with the S-IVB alone, past its artificial
    // tau): the iteration restarts from T3′ = 1 s, the bound's lower end,
    // where GE504's L3′ would be negative (T3′ < 0) or zero (T3′ = 0, a
    // division by zero in ΔL3 with no S-II left in L_Y′). T3 and the
    // commands stay finite.
    func testT3RunOutByTheClockRestartsFromItsBound() {
        let f = PointMassFlight(presettings: presettings())
        var igm = IterativeGuidance(presettings: f.presettings, launchLatitude: f.latitude, azimuth: f.azimuth)
        let nav = IGMNavigation(position: f.r, velocity: f.v, gravity: f.r.normalized * -9.5, sensedAcceleration: 6,
                                sIICutoff: true, sIVBIgnition: true)
        _ = igm.cycle(nav, interval: nil)
        for _ in 0..<5 { _ = igm.cycle(nav, interval: 1.7) }
        XCTAssertFalse(igm.artificialTau)
        for interval in [igm.t3 + 300, igm.t3 + 1e-9, igm.t3] {
            var late = igm
            let out = late.cycle(nav, interval: interval)
            XCTAssertTrue(late.t3.isFinite && late.t3 >= 1 && late.t3 <= late.tau3 - 1, "\(interval): \(late.t3)")
            XCTAssertTrue(late.totalTime.isFinite, "\(interval)")
            XCTAssertTrue(out.pitch?.isFinite ?? false, "\(interval)")
            XCTAssertTrue(out.yaw?.isFinite ?? false, "\(interval)")
        }
    }
}
