import Foundation

/// The presettings of the Saturn V iterative guidance mode (IGM) for the boost
/// to orbit, with the symbols of Boeing D5-15706-4, "Saturn V Launch Vehicle
/// Guidance Equations, SA-504" (GE504), Table 5-I. SI units and radians.
///
/// The guidance stages are: 1, the S-II at high mixture ratio; 2, the S-II
/// after the mixture-ratio shift (MRS); the S-II/S-IVB coast; 3, the S-IVB
/// burn to orbit.
public struct IGMPresettings {
    /// Exhaust velocities Vex1, Vex2, Vex3 (m/s).
    public var exhaustVelocity: (Double, Double, Double)
    /// τ2: the S-II's vehicle mass over its flow at the MRS, held until the
    /// shift; τ3N: the S-IVB's at ignition, held until ignition (s).
    public var tau2: Double
    public var tau3: Double
    /// T2: stage 2 burn time from the MRS command; Tc: the coast from S-II
    /// cutoff to S-IVB ignition (90 % thrust); T3′: the first estimate of
    /// the S-IVB burn time (s). T3 is corrected every cycle; T2 and Tc count
    /// down once their stage starts.
    public var stage2Time: Double
    public var coastTime: Double
    public var stage3Time: Double
    /// Stage 1 ends, and the IGM commands the MRS, when the S-II's
    /// characteristic velocity (its sensed velocity gained since engine
    /// start) reaches this value (m/s): AS-506's flight program, which
    /// computes the stage 1 time-to-go T1 from it (FER §6.1, §10.2.1).
    public var shiftVelocity: Double
    /// C0′: durations of the artificial tau modes after the MRS command and
    /// after S-IVB ignition (s).
    public var artificialTau: (stage2: Double, stage3: Double)
    /// ROV: range-angle bias constant.
    public var rangeAngleBias: Double
    /// t: time from the accelerometer reading to the next steering command
    /// (the K2 and K4 lead), s.
    public var lead: Double
    /// ε2: from this total time-to-go the K terms are dropped (terminal
    /// guidance); ε4: high-speed cutoff loop entry, with V + V_TC ≥ V_T (s).
    public var terminalGuidanceTime: Double
    public var cutoffLoopTime: Double
    public var cutoffLoopVelocityMargin: Double
    /// ΔV_B: the cutoff velocity is V_T − ΔV_B, for the thrust decay (m/s).
    public var cutoffVelocityBias: Double
    /// Terminal conditions: radius R_T (m), flight-path angle γ_T, and the
    /// target plane's inclination i and descending node θ_N (from the launch
    /// meridian at guidance reference release, eastwards).
    public var terminalRadius: Double
    public var terminalFlightPathAngle: Double
    public var inclination: Double
    public var descendingNode: Double
    /// Gravitational parameter μ (m^3/s^2).
    public var mu: Double
}

/// What the IGM reads each cycle: the navigation state in the space-fixed
/// frame (X_S up at guidance reference release, Z_S along the flight azimuth,
/// Y_S completing the right-handed set; origin at the Earth's centre), the
/// sensed acceleration and the stage discretes.
public struct IGMNavigation {
    public var position: Vec3
    public var velocity: Vec3
    /// Gravitational acceleration at `position` (m/s^2).
    public var gravity: Vec3
    /// F/m: the magnitude of the sensed (thrust) acceleration over the last
    /// cycle (m/s^2).
    public var sensedAcceleration: Double
    /// The S-II's characteristic velocity so far (m/s).
    public var characteristicVelocity: Double
    /// The S-II has cut off (T4); the S-IVB has reached 90 % thrust.
    public var sIICutoff: Bool
    public var sIVBIgnition: Bool
    /// The S-II engine-out discrete, as the engines the stage 2 presettings
    /// assume over those of them left (1: none out).
    public var stage2EngineFactor: Double

    public init(position: Vec3, velocity: Vec3, gravity: Vec3, sensedAcceleration: Double,
                characteristicVelocity: Double = 0, sIICutoff: Bool = false, sIVBIgnition: Bool = false,
                stage2EngineFactor: Double = 1) {
        self.position = position
        self.velocity = velocity
        self.gravity = gravity
        self.sensedAcceleration = sensedAcceleration
        self.characteristicVelocity = characteristicVelocity
        self.sIICutoff = sIICutoff
        self.sIVBIgnition = sIVBIgnition
        self.stage2EngineFactor = stage2EngineFactor
    }
}

/// The Saturn V LVDC's iterative guidance mode for the boost to orbit (S-II
/// and S-IVB first burn), as GE504 gives it (§3.1, §4.1.3-4.1.8, Figures 4-1,
/// 4-5, 4-8, 4-9, 4-11, 4-12, Tables 4-III and 4-IV, and Table 4-V's chi
/// freeze), with AS-506's own stage 1 logic and phase timing from its Flight
/// Evaluation Report (FER).
///
/// Each guidance cycle it estimates the time to go to the terminal point from
/// the velocity still to be gained, in two passes; steers along the velocity
/// to be gained (χ̃), corrected by linear terms in time (K1..K4) that bring the
/// radius to the target and the vehicle into the target plane; and drops
/// those terms near the end (terminal guidance), then freezes the attitude
/// and cuts off on velocity (the high-speed loop). It assumes a constant
/// exhaust velocity per stage and a thrust acceleration Vex/(τ - t), with τ
/// measured as Vex/(F/m) once a stage burns. Commands are the space-fixed
/// pitch χ_Y and yaw χ_Z of the thrust direction (GE504 §5.1 convention:
/// nose downrange is negative pitch).
///
/// Departures from GE504, all documented in datasheet §10: the stage 1
/// time-to-go comes from the S-II characteristic velocity, and stage 1 ends
/// with the IGM's own MRS command (AS-506; GE504 takes a timed MRS discrete
/// and a 50 s transition); an artificial tau mode follows the MRS command
/// (AS-506); the terminal gravity G_T is computed with the targeting (GE504
/// omits it on this path); the range angle's, χ̃_p's and the commanded
/// pitch's arctangents are four-quadrant; the cutoff time-to-go comes from the
/// speed's present rate, not Table 4-V's quadratic fit to the last three
/// speeds; the stage logic runs on the cycle, so the coast starts on the first
/// cycle after the S-II cutoff; an S-II engine out (the IU's discrete) scales
/// the remaining T2, τ2 and τ2N by the engines the stage 2 presettings assume
/// over those left: GE504 Fig 4-6's 5/4 generalised to AS-506's planned S-II
/// centre engine cutoff (4/3 for an outboard J-2, 1 for the centre engine,
/// which the presettings already leave out), with T1 left to the
/// characteristic velocity (datasheet §16). Not modelled: the steering
/// misalignment correction and direct staging.
public struct IterativeGuidance {
    public enum Stage: Equatable { case first, second, coast, third }

    public let presettings: IGMPresettings
    /// [G]: the space-fixed frame to the target orbit's reference frame (X_4
    /// the descending node, Z_4 90° on in the orbit plane, Y_4 against the
    /// orbit normal), GE504 Table 4-I.
    public let orbitFrame: Mat3
    /// V_T and the terminal gravity G_T (GE504 Table 4-IV).
    public let terminalVelocity: Double
    public let terminalGravity: Double

    public private(set) var stage = Stage.first
    /// Times to go (s): T1, T2, Tc, T3 and the total T_T′.
    public private(set) var t1 = 0.0
    public private(set) var t2: Double
    public private(set) var tc: Double
    public private(set) var t3: Double
    public private(set) var totalTime = 0.0
    public private(set) var tau1 = 0.0
    public private(set) var tau2: Double
    public private(set) var tau3: Double
    /// The latest χ̃ (pitch, yaw in the terminal frame), K1..K4 and range angle φ_T.
    public private(set) var chiTilde = (pitch: 0.0, yaw: 0.0)
    public private(set) var k = (k1: 0.0, k2: 0.0, k3: 0.0, k4: 0.0)
    public private(set) var rangeAngle = 0.0
    /// The steering is frozen: the S-II/S-IVB coast (GATE) or the high-speed loop.
    public private(set) var frozen = false
    public private(set) var terminalGuidance = false
    public private(set) var highSpeedLoop = false
    public private(set) var artificialTau = false

    private var tau2N: Double
    private var tau3N: Double
    /// The S-II engine-out factor applied to T2, τ2 and τ2N so far.
    public private(set) var stage2EngineFactor = 1.0
    private var c2 = 0.0
    private var c3 = 0.0
    private var cycles = 0

    /// `launchLatitude` is the latitude of X_S (the launch vertical) and
    /// `azimuth` the flight azimuth of Z_S, both rad: they place the Earth's
    /// axis in the space-fixed frame ([A], GE504 Table 4-I).
    public init(presettings p: IGMPresettings, launchLatitude: Double, azimuth: Double) {
        presettings = p
        let sl = sin(launchLatitude), cl = cos(launchLatitude), sa = sin(azimuth), ca = cos(azimuth)
        let a = Mat3(rows: Vec3(cl, sl * sa, -sl * ca), Vec3(-sl, cl * sa, -cl * ca), Vec3(0, ca, sa))
        let si = sin(p.inclination), ci = cos(p.inclination), sn = sin(p.descendingNode), cn = cos(p.descendingNode)
        let b = Mat3(rows: Vec3(cn, 0, sn), Vec3(sn * si, ci, -cn * si), Vec3(-sn * ci, si, cn * ci))
        orbitFrame = b * a
        // Unrotated terminal conditions (GE504 ROT = 0), with G_T computed here.
        terminalVelocity = (p.mu / p.terminalRadius).squareRoot()
        terminalGravity = -p.mu / (p.terminalRadius * p.terminalRadius)
        t2 = p.stage2Time
        tc = p.coastTime
        t3 = p.stage3Time
        tau2 = p.tau2
        tau3 = p.tau3
        tau2N = p.tau2
        tau3N = p.tau3
    }

    /// What one cycle asks of the vehicle.
    public struct Output: Equatable {
        /// The commanded pitch χ_Y and yaw χ_Z (rad); nil while frozen.
        public var pitch: Double?
        public var yaw: Double?
        /// This cycle ended stage 1: command the S-II mixture-ratio shift.
        public var commandShift = false
        /// This cycle began terminal guidance, or entered the high-speed loop.
        public var beganTerminalGuidance = false
        public var enteredHighSpeedLoop = false
    }

    /// One guidance cycle, `interval` s after the previous one (nil for the first).
    public mutating func cycle(_ nav: IGMNavigation, interval: Double?) -> Output {
        var out = Output()
        guard !highSpeedLoop else { return out }
        let p = presettings, vex = p.exhaustVelocity
        let dt = interval ?? 0
        cycles += 1
        // Guidance time update (Fig 4-12), for the interval just flown.
        switch stage {
        case .first: break
        case .second: t2 -= dt
        case .coast: tc -= dt
        case .third: t3 -= dt
        }

        // Stage logic (Fig 4-5).
        let fm = nav.sensedAcceleration
        if nav.sIVBIgnition && stage != .third {
            stage = .third
            c3 = 0
        } else if nav.sIICutoff && (stage == .first || stage == .second) {
            stage = .coast
        }
        // S-II engine out (Fig 4-5's IGM engine-out presettings, Fig 4-6):
        // the rest of stage 2 burns longer, on less flow, by the factor.
        if (stage == .first || stage == .second) && nav.stage2EngineFactor != stage2EngineFactor {
            let r = nav.stage2EngineFactor / stage2EngineFactor
            t2 *= r
            tau2 *= r
            tau2N *= r
            stage2EngineFactor = nav.stage2EngineFactor
        }
        artificialTau = false
        switch stage {
        case .first:
            if fm > 0.1 { tau1 = vex.0 / fm }
            // AS-506: T1 from the characteristic velocity still to go, once
            // the stage has been seen to burn.
            if tau1 > 0 { t1 = tau1 * (1 - exp(-(p.shiftVelocity - nav.characteristicVelocity) / vex.0)) }
            if tau1 > 0 && t1 <= 0 {
                stage = .second
                out.commandShift = true
                t1 = 0
                // T2 and τ2 hold their presettings (scaled by an engine out) to here.
                tau2N = tau2
                c2 = 0
                fallthrough
            }
        case .second:
            t1 = 0
            // T2 run out before the S-II cutoff: stage 2 is over (Fig 4-5).
            t2 = max(0, t2)
            if c2 < p.artificialTau.stage2 {
                tau2 = artificialTauValue(tau2N, vex.1, fm, dt, c2, p.artificialTau.stage2)
                tau2N -= dt
                c2 += dt
                artificialTau = true
            } else if fm > 0.1 {
                tau2 = vex.1 / fm
            }
        case .coast:
            t1 = 0
            t2 = 0
            tc = max(0, tc)
        case .third:
            t1 = 0
            t2 = 0
            tc = 0
            if c3 < p.artificialTau.stage3 {
                tau3 = artificialTauValue(tau3N, vex.2, fm, dt, c3, p.artificialTau.stage3)
                tau3N -= dt
                c3 += dt
                artificialTau = true
            } else if fm > 0.1 {
                tau3 = vex.2 / fm
            }
        }
        frozen = stage == .coast
        let t1c = t1 + t2 + tc
        totalTime = t1c + t3

        steer(nav, t1c: t1c)

        // Terminal guidance, and the high-speed loop entry (Fig 4-1).
        if totalTime <= p.terminalGuidanceTime && stage == .third {
            if !terminalGuidance { out.beganTerminalGuidance = true }
            terminalGuidance = true
            k = (0, 0, 0, 0)
            if totalTime <= p.cutoffLoopTime
                && nav.velocity.length + p.cutoffLoopVelocityMargin >= terminalVelocity {
                highSpeedLoop = true
                frozen = true
                out.enteredHighSpeedLoop = true
                return out
            }
        }
        guard !frozen else { return out }
        // IGM steering angles (Table 4-IV p6).
        let yaw = chiTilde.yaw - k.k3 + k.k4 * p.lead
        let pitch = chiTilde.pitch - k.k1 + k.k2 * p.lead
        let d = commandFrame.transposed * Vec3(sin(pitch) * cos(yaw), sin(yaw), cos(pitch) * cos(yaw))
        out.yaw = max(-Double.pi / 4, min(Double.pi / 4, asin(max(-1, min(1, d.y)))))
        out.pitch = atan2(-d.z, d.x)
        return out
    }

    /// Seconds to the velocity cutoff, V_T - ΔV_B, at speed `v` rising at `rate`.
    public func cutoffTimeToGo(speed v: Double, rate: Double) -> Double {
        let target = terminalVelocity - presettings.cutoffVelocityBias
        guard v < target else { return 0 }
        return rate > 0 ? (target - v) / rate : .infinity
    }

    /// Artificial tau mode (Table 4-III): from the nominal τN to the measured
    /// tau over C0′ s, weighted (C′/C0′)^4.
    private func artificialTauValue(_ tauN: Double, _ vex: Double, _ fm: Double, _ dt: Double,
                                    _ c: Double, _ c0: Double) -> Double {
        guard fm > 0.1 else { return tauN }
        let w = pow(c / c0, 4)
        return tauN + (vex / fm - dt / 2 - tauN) * w
    }

    /// [K] = [φ_T][G], the terminal frame of the last cycle.
    private var commandFrame = Mat3.identity

    // MARK: Chi-tilde and K calculations

    /// GE504 Table 4-IV: the stage integrals, two passes of range angle 1,
    /// terminal frame and time-to-go, then χ̃ and the K terms.
    private mutating func steer(_ nav: IGMNavigation, t1c: Double) {
        let p = presettings, vex = p.exhaustVelocity
        let s1 = Self.integrals(vex.0, tau1, t1), s2 = Self.integrals(vex.1, tau2, t2)
        let t1v = t1, t2v = t2, tcv = tc
        let l12 = s1.l + s2.l
        let j12 = s1.j + s2.j + s2.l * t1v
        let s12 = s1.s - s2.j + l12 * (t2v + tcv)
        let q12 = s1.q + s2.q + s2.s * t1v + s1.j * t2v
        let p12 = s1.p + s2.p + t1v * (2 * s2.j + s2.l * t1v)
        let u12 = s1.u + s2.u + t1v * (2 * s2.q + s2.s * t1v) + t2v * s1.p
        let tau3v = tau3
        var t3p = min(t3, tau3v - 1)
        var ttp = t1c + t3p
        var l3p = vex.2 * log(tau3v / (tau3v - t3p))
        var j3p = l3p * tau3v - vex.2 * t3p
        var lyp = l12 + l3p
        let r = nav.position, v = nav.velocity, speed = v.length
        let x4 = orbitFrame * r
        let rt = p.terminalRadius, gammaT = p.terminalFlightPathAngle
        let xiT = rt, zetaDotT = terminalVelocity * cos(gammaT), xiDotT = terminalVelocity * sin(gammaT)
        var pos = Vec3.zero, vel = Vec3.zero, grav = Vec3.zero, dv = Vec3.zero
        var dl3 = 0.0, dt3 = 0.0, t3n = t3p, ttn = ttp
        var kMatrix = Mat3.identity
        for pass in 0..<2 {
            // Range angle 1.
            let bias = (p.rangeAngleBias / vex.2)
                * ((tau1 - t1v) * s1.l + (tau2 - t2v) * s2.l + (tau3v - t3p) * l3p)
                * (lyp + speed - terminalVelocity)
            let delta2 = speed * ttp - j3p + lyp * t3p - bias
            let phiT = atan2(x4.z, x4.x) + (s12 + delta2) * cos(gammaT) / rt
            rangeAngle = phiT
            let phi = Mat3(rows: Vec3(cos(phiT), 0, sin(phiT)), Vec3(0, 1, 0), Vec3(-sin(phiT), 0, cos(phiT)))
            kMatrix = phi * orbitFrame
            pos = kMatrix * r
            vel = kMatrix * v
            grav = (Vec3(terminalGravity, 0, 0) + kMatrix * nav.gravity) * 0.5
            // Velocity to be gained, and the T3 correction.
            dv = Vec3(xiDotT - vel.x - grav.x * ttp, -vel.y - grav.y * ttp, zetaDotT - vel.z - grav.z * ttp)
            dl3 = (dv.lengthSquared / lyp - lyp) / 2
            dt3 = dl3 * (tau3v - t3p) / vex.2
            t3n = t3p + dt3
            ttn = ttp + dt3
            if pass == 0 {
                t3p = t3n
                ttp = ttn
                l3p += dl3
                lyp += dl3
                j3p += dl3 * t3n
            }
        }
        commandFrame = kMatrix
        t3 = t3n
        totalTime = ttp
        // χ̃ (Table 4-IV p4).
        let l3 = l3p + dl3, j3 = j3p + dl3 * t3n
        let s3 = l3 * t3n - j3
        let q3 = s3 * tau3v - vex.2 * t3n * t3n / 2
        let p3 = j3 * (tau3v + 2 * t1c) - vex.2 * t3n * t3n / 2
        let u3 = q3 * (tau3v + 2 * t1c) - vex.2 * t3n * t3n * t3n / 6
        let dvf = dv - grav * dt3
        let ly = l12 + l3
        let chiY = atan(dvf.y / (dvf.x * dvf.x + dvf.z * dvf.z).squareRoot())
        let chiP = atan2(dvf.x, dvf.z)
        chiTilde = (chiP, chiY)
        guard ttp > p.terminalGuidanceTime || stage != .third else {
            k = (0, 0, 0, 0)
            return
        }
        // Yaw and pitch steering parameters (Table 4-IV p5).
        let jy = j12 + j3 + l3 * t1c
        let sy = s12 - j3 + ly * t3n
        let qy = q12 + q3 + s3 * t1c + (tcv + t3n) * j12
        let ky = ly / jy, dy = sy - ky * qy
        let deta = pos.y + vel.y * ttn + grav.y * ttn * ttn / 2 + sy * sin(chiY)
        let k3 = deta / (dy * cos(chiY)), k4 = ky * k3
        let lp = ly * cos(chiY)
        let c2 = cos(chiY) + k3 * sin(chiY), c4 = k4 * sin(chiY)
        let jp = jy * c2 - c4 * (p12 + p3 + t1c * t1c * l3)
        let sp = sy * c2 - c4 * qy
        let qp = qy * c2 - c4 * (u12 + u3 + t1c * t1c * s3 + (t3n + tcv) * p12)
        let kp = lp / jp, dp = sp - kp * qp
        let dxi = pos.x - xiT + vel.x * ttn + grav.x * ttn * ttn / 2 + sp * sin(chiP)
        let k1 = dxi / (dp * cos(chiP)), k2 = kp * k1
        k = (k1, k2, k3, k4)
    }

    /// The stage integrals of a thrust acceleration Vex/(τ - t) over T s
    /// (Table 4-IV p1): L = ∫a, J = ∫a t, S = ∫∫a, Q = ∫J, P = ∫a t^2, U = ∫P.
    static func integrals(_ vex: Double, _ tau: Double, _ t: Double)
        -> (l: Double, j: Double, s: Double, q: Double, p: Double, u: Double) {
        guard t > 0, tau > t else { return (0, 0, 0, 0, 0, 0) }
        let l = vex * log(tau / (tau - t))
        let j = l * tau - vex * t
        let s = l * t - j
        let q = s * tau - vex * t * t / 2
        let p = j * tau - vex * t * t / 2
        let u = q * tau - vex * t * t * t / 6
        return (l, j, s, q, p, u)
    }
}
