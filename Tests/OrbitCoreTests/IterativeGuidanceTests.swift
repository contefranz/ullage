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

        struct Result {
            var r: Vec3, v: Vec3, cutoff: Double, shift: Double?, terminalGuidance: Double?
            var highSpeedLoop: Double?, sIIOut: Double, sIVBAtThrust: Double?, guidance: IterativeGuidance
            var pitch: [(t: Double, deg: Double)]
            /// The cycles that gave no command before the high-speed loop.
            var frozen: [Double]
        }

        mutating func fly() -> Result {
            let mu = presettings.mu, h = 0.02
            let pole = Vec3(sin(latitude), -sin(azimuth) * cos(latitude), cos(azimuth) * cos(latitude))
            let earth = CelestialBody(id: 399, name: "Earth", gm: mu, radius: 6_378_137, j2: j2, rotation: .earth,
                                      soiRadius: .infinity)
            var igm = IterativeGuidance(presettings: presettings, launchLatitude: latitude, azimuth: azimuth)
            let hi = (thrust: 1_028_303.0, flow: 1_028_303 / 4_175.37), lo = (thrust: 768_000.0, flow: 768_000 / 4_200.55)
            var engines = 5.0, low = false, shiftAt: Double?, sIIOut: Double?, ignition: Double?
            var cutoff: Double?, tg: Double?, hsl: Double?
            var target = chi, lastCycle: Double?, sensed = 0.0, bnvc = 0.0, pitch: [(Double, Double)] = []
            var frozen: [Double] = []
            func atThrust(_ t: Double) -> Bool { ignition.map { t >= $0 + 0.6 + 0.9 * 1.9 } ?? false }
            func thrust(_ t: Double) -> (Double, Double) {
                if cutoff != nil { return (0, 0) }
                if let s = ignition {
                    let f = min(1, max(0, (t - s - 0.6) / 1.9))
                    return (903_000 * f, 215.37 * f)
                }
                if sIIOut != nil { return (0, 0) }
                let e = low ? lo : hi
                return (engines * e.thrust, engines * e.flow)
            }
            while t < 760 && cutoff == nil {
                // The vehicle's events.
                if engines == 5 && t >= 460.6 - 1e-9 { engines = 4 }
                if let s = shiftAt, !low, t >= s + 2.8 - 1e-9 { low = true }
                if sIIOut == nil && m <= 214_248 {
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
                                            sIVBIgnition: atThrust(t))
                    let out = igm.cycle(nav, interval: interval)
                    if let p = out.pitch, let y = out.yaw { target = Vec3(0, p, y) }
                    if out.pitch == nil && !igm.highSpeedLoop { frozen.append(t) }
                    if out.commandShift { shiftAt = t }
                    if out.beganTerminalGuidance { tg = t }
                    if out.enteredHighSpeedLoop { hsl = t }
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
            return Result(r: r, v: v, cutoff: cutoff ?? t, shift: shiftAt, terminalGuidance: tg, highSpeedLoop: hsl,
                          sIIOut: sIIOut ?? .nan, sIVBAtThrust: ignition.map { $0 + 0.6 + 0.9 * 1.9 }, guidance: igm,
                          pitch: pitch, frozen: frozen)
        }

        func direction(_ chi: Vec3) -> Vec3 {
            Vec3(cos(chi.z) * cos(chi.y), sin(chi.z), -cos(chi.z) * sin(chi.y))
        }
    }

    /// Datasheet §10.3's presettings, except the point mass's own: V_C (its
    /// characteristic velocity is summed from 200 s, not from S-II ignition),
    /// ΔV_B (no thrust decay), and τ2 and τ3 (from its estimated masses).
    func presettings() -> IGMPresettings {
        IGMPresettings(exhaustVelocity: (4_175.37, 4_200.55, 4_192.78), tau2: 347.0, tau3: 773.5,
                       stage2Time: 53.4, coastTime: 6.3, stage3Time: 144.0, shiftVelocity: 3_652,
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
}
