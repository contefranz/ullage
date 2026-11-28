import Foundation
import OrbitCore

/// The plumes' turbulence (P2), procedural and never repeating: flow noise
/// in the jet's own terms. PlumeShaders' `plume_noise` evaluates the same
/// field on the GPU; `value` here is its reference.
///
/// - **Eddies** are born at the nozzle's lip at `lipEddy` exit radii and
///   grow downstream with the mixing layer, ℓ(x) = ℓ0 + k x: k is the
///   compressible shear layer's vorticity-thickness growth (Brown and
///   Roshko's incompressible rate in its velocity and density ratio form,
///   times Dimotakis's compressibility factor on the convective Mach
///   number), mixed towards half the free expansion's cone in vacuum. ℓ is
///   the noise's cell, whose integral length is `integralLength` of it.
///   Along the axis the noise is laid out in eddies, s(x) = ∫dx/ℓ = ln(1 +
///   k x/ℓ0)/k, across it in ℓ(x): the pattern grows with the jet.
/// - **They are carried at the local mean speed**: the stream's along the
///   jet (the coflow) plus the jet's excess, which holds through the
///   potential core and falls as 1/x beyond it, across the jet a Gaussian
///   of half-width R/2 outside the core's shrinking top hat (uniform in a
///   free expansion). The axis runs faster than the edge. Each layer's
///   pattern is laid out where the flow carried each point from since the
///   layer's birth (`carriedFrom`), so it rides the decelerating jet; at most
///   half-way back to the exit (`carryLimit`), so that a layer outliving its
///   transit (a ballooned plume's, carried at the whole exhaust speed) keeps
///   cells near the local ones (ℓ grows as x) instead of drawing the exit's
///   small cells far downstream as thin plates across the jet.
/// - **They decay** as a jet's turbulence does following the flow: its
///   Lagrangian integral time is `lagrangianTime` L/u' (L the integral
///   length, u' the turbulence's intensity times the centreline's excess
///   speed), both from where the eddies are: the shear layer about the
///   potential core, then the jet developing towards its self-similar far
///   field (`intensity(coreLengths:)`, `lagrangianTime(coreLengths:)`). Each
///   octave band of lifetimes holds two layers of the noise, cross-faded
///   half a life apart and re-seeded at each birth with a fresh
///   pseudo-random offset (a hash of the band's cycle, moved by the
///   cluster's seed's offset): flow noise (Neyret 2003), never repeating. A sample blends the
///   two bands about its own lifetime, keeping the noise's variance (Heitz
///   and Neyret 2018), so nothing pulses.
/// - **One flow through a cluster** (`flow(_:merged:mergeX:origin:axis:at:)`):
///   at each point the jet whose bent axis passes nearest, of those the
///   point lies along (0 ≤ x ≤ length), carries the noise (in a cluster of
///   like engines the strongest there, its profile's share the largest);
///   where that one does not reach the point, the first member that does
///   (the march: the member asking for the noise), as when an engine tails
///   off among full ones; and the merged far field takes over across the
///   merge's window, so that the field is continuous where jets meet.
/// - **The shutter.** The camera sees the field averaged over its exposure
///   (`shutter`): at a point the field holds for an Eulerian time T_E,
///   1/T_E = u/L + 1/T_L (swept past, and decaying), so the average's
///   depth is 1/√(1 + Δ/(2 T_E)), and it streaks along the flow by what the
///   self-similar mixing layer carries past in the exposure, at most in a
///   Lagrangian time, per band and the same down the whole jet
///   (`streakRate`; a streak varying with x would warp the axial
///   coordinate). The F-1's fast near field shimmers in streaks; its slow
///   far field billows. The depth is returned beside the noise (`field`):
///   `JetFluctuations` weighs its factor by it.
/// - **What it does to the field** is `JetFluctuations`': the noise here
///   has zero mean and unit variance.
///
/// Deterministic: a function of the turbulence clock (real time × min(warp,
/// 4), reset with the scene) and the cluster's seed.
public enum PlumeTurbulence {
    /// The turbulence's intensity u'/ΔU, ΔU the centreline's excess over
    /// the stream, in the shear layer about the potential core: the
    /// self-similar mixing layer's peak, ⟨u²⟩/ΔU² ≈ 0.032 (Bell and Mehta
    /// 1990, as Rogers and Moser 1994 compile it), M.
    public static let shearIntensity = 0.18
    /// On the axis of a round jet's self-similar far field: ⟨u²⟩/Uc² ≈ 0.076
    /// (Hussein, Capp and George 1994, LDA, as Pope 2000's Fig. 5.7 fits
    /// it), H.
    public static let similarIntensity = 0.28
    /// Where the far field is self-similar, in core lengths: z ≳ 20 D
    /// (Pope 2000, as Viggiano et al. 2021 take it), an incompressible
    /// round jet's potential core being about 5 D, L.
    public static let similarFrom = 4.0
    /// The intensity `coreLengths` (x over the potential core's length)
    /// down the jet: the shear layer's through the core, rising linearly to
    /// the self-similar centreline's (L between).
    public static func intensity(coreLengths xi: Double) -> Double {
        shearIntensity + (similarIntensity - shearIntensity) * min(max((xi - 1) / (similarFrom - 1), 0), 1)
    }
    /// The Lagrangian integral time of the axial velocity on a jet's axis
    /// over the eddy turnover time L/u', at x/core = `lagrangianStart` +
    /// `lagrangianStep` i: 1/(T_E/T_L), T_E/T_L = 0.6, 1.6, 1.5, 1.8 at z/D
    /// = 15, 25, 35, 45 with T_E = L_E/σ_u (Viggiano et al. 2021, Table 2),
    /// a core of 5 D, M; held before and beyond (L).
    public static let lagrangianTimes = [1 / 0.6, 1 / 1.6, 1 / 1.5, 1 / 1.8]
    public static let lagrangianStart = 3.0, lagrangianStep = 2.0
    /// It `coreLengths` down the jet, linearly between the stations.
    public static func lagrangianTime(coreLengths xi: Double) -> Double {
        let t = min(max((xi - lagrangianStart) / lagrangianStep, 0), Double(lagrangianTimes.count - 1))
        let i = min(Int(t), lagrangianTimes.count - 2), f = t - Double(i)
        return lagrangianTimes[i] + (lagrangianTimes[i + 1] - lagrangianTimes[i]) * f
    }
    /// The cross-fade's own Lagrangian integral time over a layer's life:
    /// two triangles half a life apart, normalised (`PlumeTurbulenceTests`
    /// integrates it).
    public static let fadeIntegral = 0.389
    /// The volume noise's integral length over its coarsest cell, its
    /// correlation integrated to the first zero (`PlumeTurbulenceTests`):
    /// the eddy cell ℓ holds an integral length of 0.39 ℓ.
    public static let integralLength = 0.39
    /// A layer's life over ℓ/u' `coreLengths` down the jet, so that the
    /// field's Lagrangian integral time is `lagrangianTime` L/u'.
    public static func lifeOverTurnover(coreLengths xi: Double) -> Double {
        lagrangianTime(coreLengths: xi) * integralLength / fadeIntegral
    }
    /// The eddies at the lip, over the exit radius: the nozzle's boundary
    /// layer and film (L).
    public static let lipEddy = 0.25
    /// The camera's exposure the eddies are averaged over, s of turbulence
    /// time: a 180° shutter at 60 frames a second, the cinematographer's
    /// convention (L).
    public static let shutter = 1.0 / 120
    /// The bands of lifetimes: band j's layers live 2^(j - 13) s, from
    /// 0.12 ms (a J-2's lip in vacuum) to 64 s (smoke kilometres out).
    public static let bandCount = 20
    public static let shortestLife = 1.0 / 8_192
    /// The volume noise's standard deviation, 2 n − 1 over its texels
    /// (measured, `PlumeTurbulenceTests`): `field` divides by it, so that
    /// the noise has unit variance, near enough a Gaussian's (kurtosis 2.7)
    /// for `JetFluctuations`' factor to keep its mean.
    public static let noiseDeviation = 0.29
    /// ln 16: the mean speed's Gaussian across the jet, exp(-ln 2 (r/r½)²)
    /// with r½ = R/2.
    public static let profileShape = 4 * log(2.0)
    /// How far back towards the exit a layer's pattern is carried, at most,
    /// over the distance from it: half (L). A jet's layers are carried 1-30 %
    /// of it; a ballooned plume's would reach the exit and beyond.
    public static let carryLimit = 0.5

    /// The noise's tile: eddies per repeat of the volume noise (its
    /// coarsest octave's cells across the 128³ texture).
    public static let eddiesPerTile = 8.0

    /// Over a band's life T, in the self-similar mixing layer's middle
    /// (half the jet's excess speed, no coflow): the rate the flow sweeps
    /// integral lengths past a point (u/L = this / T), the streak's, the
    /// same down the whole jet (a streak varying with x would warp the
    /// noise's axial coordinate, and the pattern would ride the flow at
    /// two-thirds of its speed); and the layers' decay (1/T_L = this / T).
    public static var streakRate: Double {
        0.5 * lagrangianTimes[lagrangianTimes.count - 1] / (fadeIntegral * similarIntensity)
    }
    public static var decayRate: Double { 1 / fadeIntegral }

    /// The shutter's average for layers living `life` s where the flow
    /// sweeps `sweep` integral lengths a second past the point (u/L): the
    /// depth it keeps, 1/√(1 + Δ/(2 T_E)), 1/T_E = u/L + 1/T_L; and how far
    /// it streaks the pattern along the flow (a factor on the axial
    /// coordinate, the same through a band: the self-similar mixing
    /// layer's, `streakRate`).
    public static func shutterAverage(life: Double, sweep: Double) -> (depth: Double, stretch: Double) {
        let depth = 1 / (1 + shutter * (sweep + decayRate / life) / 2).squareRoot()
        let stretch = 1 + streakRate * min(shutter, fadeIntegral * life) / life
        return (depth, stretch)
    }

    // MARK: The mixing layer

    /// A compressible mixing layer's growth over the incompressible one's
    /// at convective Mach number `mc`: Dimotakis's (1991) fit to the
    /// Langley curve (Birch and Eggers 1972), 0.2 + 0.8 exp(-3 Mc²), as
    /// Padnos et al. (2018, eq. 3.7) quote it, M; about 0.2 at supersonic
    /// Mc, as Papamoschou and Roshko (1988) report.
    public static func compressibility(convectiveMach mc: Double) -> Double {
        0.2 + 0.8 * exp(-3 * mc * mc)
    }

    /// The vorticity thickness's growth dδω/dx of a mixing layer between
    /// the jet and the stream, at velocity ratio `r` = U2/U1 and density
    /// ratio `s` = ρ2/ρ1 (stream over jet): Brown's (1974) form C (1 -
    /// r)(1 + √s) / (2 (1 + r √s)) with Brown and Roshko's C = 0.181 (as
    /// Pantano and Sarkar 2002 give the form), H, times the compressibility
    /// factor.
    public static func shearGrowth(velocityRatio r: Double, densityRatio s: Double, convectiveMach mc: Double) -> Double {
        let r = min(max(r, 0), 0.99), q = max(s, 1e-6).squareRoot()
        return 0.181 * (1 - r) * (1 + q) / (2 * (1 + r * q)) * compressibility(convectiveMach: mc)
    }

    /// The isentropic convective Mach number (Papamoschou and Roshko 1988),
    /// (U1 - U2) / (a1 + a2).
    public static func convectiveMach(jetSpeed u1: Double, streamSpeed u2: Double, jetSound a1: Double,
                                      streamSound a2: Double) -> Double {
        abs(u1 - u2) / max(a1 + a2, 1)
    }

    // MARK: The field's frame

    /// The eddies' size at x (m).
    public static func eddySize(_ m: PlumeMember, atX x: Double) -> Double {
        m.eddySize + m.eddyGrowth * max(x, 0)
    }

    /// Eddies from the exit to x, ∫dx/ℓ; upstream of the exit at the lip's
    /// size.
    public static func eddies(_ m: PlumeMember, atX x: Double) -> Double {
        let l0 = max(m.eddySize, 1e-6), k = m.eddyGrowth
        guard x > 0 else { return x / l0 }
        return k > 1e-5 ? log(1 + k * x / l0) / k : x / l0
    }

    /// The flow that carries the noise at a point: x along the jet that
    /// carries it (m), the share of its excess speed there (`profile`), the
    /// stream along it and the jet's excess over it at the exit (m/s), its
    /// potential core (m), its eddies at the lip (m) and their growth.
    public struct Flow: Equatable {
        public var x, profile, coflow, excess, coreLength, eddySize, eddyGrowth: Double

        public init(_ m: PlumeMember, atX x: Double, profile: Double) {
            self.x = max(x, 0)
            self.profile = profile
            coflow = m.coflow
            excess = m.exhaustSpeed - m.coflow
            coreLength = m.coreLength
            eddySize = m.eddySize
            eddyGrowth = m.eddyGrowth
        }

        /// Mixed towards `b` by `w` (0-1), linearly.
        public func mixed(_ b: Flow, _ w: Double) -> Flow {
            var f = self
            func mix(_ a: Double, _ c: Double) -> Double { a + (c - a) * w }
            f.x = mix(x, b.x)
            f.profile = mix(profile, b.profile)
            f.coflow = mix(coflow, b.coflow)
            f.excess = mix(excess, b.excess)
            f.coreLength = mix(coreLength, b.coreLength)
            f.eddySize = mix(eddySize, b.eddySize)
            f.eddyGrowth = mix(eddyGrowth, b.eddyGrowth)
            return f
        }

        /// x over the potential core's length.
        public var coreLengths: Double { x / max(coreLength, 1e-6) }
        /// The centreline's speed in excess of the stream at x (m/s).
        public var centreline: Double { speed(atX: x, profile: 1) - coflow }
        /// The mean speed at x (m/s): the stream's plus the excess's share.
        public var speed: Double { speed(atX: x, profile: profile) }
        func speed(atX y: Double, profile g: Double) -> Double {
            coflow + excess * g * min(1, max(coreLength, 1e-6) / max(y, 1e-3))
        }
        /// The eddies' cell at x (m).
        public var eddy: Double { eddySize + eddyGrowth * x }
        /// The eddies' turnover time ℓ / u' (s).
        public var turnover: Double {
            eddy / max(PlumeTurbulence.intensity(coreLengths: coreLengths) * abs(centreline), 0.5)
        }
        /// Its band of lifetimes (fractional).
        public var band: Double { PlumeTurbulence.band(turnover: turnover, coreLengths: coreLengths) }
        /// Integral lengths the flow sweeps past here a second, at its speed
        /// here (the camera rides with the vessel).
        public var sweep: Double { abs(speed) / (integralLength * eddy) }

        /// Where the flow here carried a parcel from over `age` s: back
        /// along the jet at its mean speed, Ua + E(x) g, g the profile's
        /// share held along the way (a parcel keeps its place in the jet's
        /// self-similar profile), in one midpoint step (a layer lives less
        /// than a turnover, over which the speed changes little).
        public func carriedFrom(age: Double) -> Double {
            let mid = x - 0.5 * age * speed
            return x - age * speed(atX: mid, profile: profile)
        }
    }

    /// Member `m`'s flow at camera-relative `p`: in its wall jet on the
    /// ground it meets (`PlumeImpingement.wallJet`), the equivalent free
    /// jet's.
    public static func flow(_ m: PlumeMember, at p: Vec3) -> Flow {
        if let i = m.impingement, let w = i.wallJet(m, at: p) {
            return Flow(m, atX: w.x, profile: profile(m, atX: w.x, r: w.r))
        }
        let d = p - m.exit, x = max(d.dot(m.axis), 0)
        let r = (d - m.axis * x - m.bend.direction * m.bend.offset(atX: x)).length
        return Flow(m, atX: x, profile: profile(m, atX: x, r: r))
    }

    /// Where the flow at x carried a parcel from over `age` s (`Flow.carriedFrom`).
    public static func carriedFrom(_ m: PlumeMember, x: Double, profile g: Double, age: Double) -> Double {
        Flow(m, atX: x, profile: g).carriedFrom(age: age)
    }

    /// The centreline's speed in excess of the stream at x (m/s).
    public static func excessSpeed(_ m: PlumeMember, atX x: Double) -> Double {
        Flow(m, atX: x, profile: 1).centreline
    }

    /// The mean speed along the jet at x, r off its axis (m/s), relative
    /// to the nozzle: the stream's plus the jet's excess, a top hat in the
    /// potential core and a Gaussian outside it; uniform in a free
    /// expansion.
    public static func meanSpeed(_ m: PlumeMember, atX x: Double, r: Double) -> Double {
        Flow(m, atX: x, profile: profile(m, atX: x, r: r)).speed
    }

    /// The excess speed's share at r off the axis at x: 1 in the potential
    /// core's top hat (its radius shrinking to nothing at the core's end),
    /// a Gaussian outside it, 1 in a free expansion.
    public static func profile(_ m: PlumeMember, atX x: Double, r: Double) -> Double {
        let x = max(x, 0), re = m.exitRadius
        let core = m.coreLength, big = m.radius(atX: x)
        let rc = re * max(0, 1 - x / max(core, 1e-6))
        let eta = max(r - rc, 0) / max(big - rc, 0.05 * re)
        let gauss = exp(-profileShape * eta * eta)
        return gauss + (1 - gauss) * m.vacuumBlend
    }

    /// The eddies' turnover time at x (s): ℓ / u', ℓ the cell.
    public static func turnover(_ m: PlumeMember, atX x: Double) -> Double {
        Flow(m, atX: x, profile: 1).turnover
    }

    /// The band (fractional) of a turnover time `coreLengths` down the jet:
    /// its layers live `lifeOverTurnover` τ.
    public static func band(turnover tau: Double, coreLengths xi: Double) -> Double {
        min(max(log2(lifeOverTurnover(coreLengths: xi) * tau / shortestLife), 0), Double(bandCount - 1) - 1e-3)
    }

    /// The band of `m`'s eddies at x.
    public static func band(_ m: PlumeMember, atX x: Double) -> Double { Flow(m, atX: x, profile: 1).band }

    /// The next band's weight at a fraction `f` of the octave: blended in
    /// over its middle 30 %, so that most samples read one band.
    public static func blend(_ f: Double) -> Double { PlumeMember.smoothstep(0.35, 0.65, f) }

    /// Band j's layers' lifetime (s).
    public static func life(band j: Int) -> Double { shortestLife * pow(2, Double(j)) }

    // MARK: The clock

    /// One band's two layers at a moment: each one's phase in its life
    /// (0-1) and its birth's count, which seeds its offset.
    public struct Band: Equatable {
        public var phase: (Double, Double)
        public var cycle: (UInt32, UInt32)

        public static func == (a: Band, b: Band) -> Bool { a.phase == b.phase && a.cycle == b.cycle }
    }

    /// Every band at turbulence time `t` (s, not wrapped): its layers half
    /// a life apart.
    public static func bands(time t: Double) -> [Band] {
        (0..<bandCount).map { j in
            let u0 = max(t, 0) / life(band: j), u1 = u0 + 0.5
            let c0 = u0.rounded(.down), c1 = u1.rounded(.down)
            return Band(phase: (u0 - c0, u1 - c1),
                        cycle: (UInt32(truncatingIfNeeded: Int64(c0)), UInt32(truncatingIfNeeded: Int64(c1))))
        }
    }

    /// A layer's offset in the noise's tile, in [0, 1)³: PCG hashes of its
    /// birth, band and layer (the renderer's per frame, PlumeFrame.layers).
    public static func offset(cycle: UInt32, band: Int, layer: Int) -> Vec3 {
        let pcg = ParticleRandom.pcg
        var h = pcg(cycle ^ pcg(UInt32(2 * band + layer) &+ 0x2545_F491))
        func next() -> Double {
            h = pcg(h)
            return Double(h >> 8) / 16_777_216
        }
        let x = next(), y = next(), z = next()
        return Vec3(x, y, z)
    }

    /// A cluster's own offset in the tile, in [0, 1)³, from its seed: its
    /// field is the frame's moved by it.
    public static func seedOffset(_ seed: UInt32) -> Vec3 {
        let pcg = ParticleRandom.pcg
        var h = pcg(seed ^ 0x9E37_79B9)
        func next() -> Double {
            h = pcg(h)
            return Double(h >> 8) / 16_777_216
        }
        let x = next(), y = next(), z = next()
        return Vec3(x, y, z)
    }

    /// A stable seed for a name (FNV-1a): a cluster's, from its parts and
    /// engines, so that it does not change from run to run.
    public static func seed(_ name: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for b in name.utf8 {
            h ^= UInt32(b)
            h = h &* 16_777_619
        }
        return h
    }

    /// The noise's fixed rotation off the texture's lattice (rows), so that
    /// no axis runs along a lattice direction and the tile's repeat is not
    /// laid along the plume: the rotation by 1 rad about (1, φ, φ²)/|…|, φ
    /// the golden ratio.
    public static let basis: [Vec3] = {
        let phi = (1 + 5.0.squareRoot()) / 2
        let k = Vec3(1, phi, phi * phi).normalized
        let a = 1.0, c = cos(a), s = sin(a), t = 1 - c
        return [Vec3(t * k.x * k.x + c, t * k.x * k.y - s * k.z, t * k.x * k.z + s * k.y),
                Vec3(t * k.x * k.y + s * k.z, t * k.y * k.y + c, t * k.y * k.z - s * k.x),
                Vec3(t * k.x * k.z - s * k.y, t * k.y * k.z + s * k.x, t * k.z * k.z + c)]
    }()

    // MARK: The field

    /// The turbulence at camera-relative `p` in a cluster whose first
    /// member is `frame` (the noise's frame), carried by `flow` (the
    /// cluster's there, `flow(_:merged:mergeX:origin:axis:at:)`): the
    /// noise, of zero mean and unit variance, and the depth the shutter's
    /// average keeps of it (the bands' depths weighed as the blend weighs
    /// them): the shader's `plume_noise`. `bands` from `bands(time:)`;
    /// `noise(c, channel)` the volume noise's value (0-1) at c in tiles.
    public static func field(frame m: PlumeMember, flow f: Flow, at p: Vec3, bands: [Band], seed: UInt32,
                             noise: (Vec3, Int) -> Double) -> (noise: Double, depth: Double) {
        let d0 = p - m.exit
        let x = max(d0.dot(m.axis), 0)
        let d = d0 - m.bend.direction * m.bend.offset(atX: x)
        let perp = d - m.axis * x
        let l = eddySize(m, atX: x)
        let b = f.band, sweep = f.sweep
        let j = Int(b), beta = blend(b - Double(j))
        var total = 0.0, weight = 0.0, depths = 0.0
        for (band, wb) in [(j, 1 - beta), (j + 1, beta)] where wb > 1e-3 {
            let life = life(band: band)
            let (depth, stretch) = shutterAverage(life: life, sweep: sweep)
            let layers = bands[band]
            for layer in 0..<2 {
                let phase = layer == 0 ? layers.phase.0 : layers.phase.1
                let cycle = layer == 0 ? layers.cycle.0 : layers.cycle.1
                let w = wb * (1 - abs(2 * phase - 1))
                let age = phase * life
                // Laid out where the flow carried it from since the layer's
                // birth, at most half-way back to the exit.
                let from = x - min(f.x - f.carriedFrom(age: age), carryLimit * x)
                let c = perp / l + m.axis * (eddies(m, atX: from) / stretch)
                let rotated = Vec3(basis[0].dot(c), basis[1].dot(c), basis[2].dot(c)) / eddiesPerTile
                let shift = offset(cycle: cycle, band: band, layer: layer) + seedOffset(seed)
                let n = 2 * noise(rotated + shift, layer) - 1
                total += w * n
                weight += w * w
                depths += w * w * depth * depth
            }
        }
        let norm = max(weight, 1e-12)
        return (total / (norm.squareRoot() * noiseDeviation), (depths / norm).squareRoot())
    }

    /// The turbulence as the camera sees it, `field`'s noise times its
    /// depth: zero mean, a variance of the depth's square.
    public static func value(frame m: PlumeMember, flow f: Flow, at p: Vec3, bands: [Band], seed: UInt32,
                             noise: (Vec3, Int) -> Double) -> Double {
        let v = field(frame: m, flow: f, at: p, bands: bands, seed: seed, noise: noise)
        return v.noise * v.depth
    }

    /// Whether member `k`'s field reaches camera-relative `p` (as the
    /// shader's early reject finds it, downstream of the exit).
    public static func reaches(_ k: PlumeMember, _ p: Vec3) -> Bool {
        if let i = k.impingement, let w = i.wallJet(k, at: p) { return w.r <= k.fieldExtent(atX: w.x) }
        let dk = p - k.exit, xk = dk.dot(k.axis)
        guard xk >= 0, xk <= k.length else { return false }
        let rk = (dk - k.axis * xk - k.bend.direction * k.bend.offset(atX: xk)).length
        return rk <= k.fieldExtent(atX: xk)
    }

    /// The member of a cluster whose axis passes nearest camera-relative
    /// `p`, bent as the first member's is there (the bend is the
    /// cluster's), of those p lies along (0 ≤ x ≤ length): in a cluster of
    /// like engines the jet strongest at p (the largest share of its
    /// excess), found from the exits and axes alone; the first of equals.
    /// With p's x along it and r off its bent centreline.
    public static func nearest(_ members: [PlumeMember], at p: Vec3) -> (index: Int, x: Double, r: Double)? {
        guard let m0 = members.first else { return nil }
        let x0 = max((p - m0.exit).dot(m0.axis), 0)
        let q = p - m0.bend.direction * m0.bend.offset(atX: x0)
        var best: (index: Int, x: Double, r: Double)?, closest = Double.infinity
        for (k, m) in members.enumerated() {
            let d = q - m.exit, x = d.dot(m.axis), e = d - m.axis * x
            if x >= 0, x <= m.length, e.dot(e) < closest {
                closest = e.dot(e)
                best = (k, x, e.length)
            }
        }
        return best
    }

    /// The flow that carries a cluster's noise at camera-relative `p`: the
    /// flow of the member whose axis passes nearest (`nearest`), where its
    /// field reaches p (else the first member's that does: an engine
    /// tailing off among full ones), which is continuous wherever the
    /// cluster's jets are alike; beyond `mergeX` along `axis` from `origin`, mixed into the
    /// merged far field's over the merge's window (15 % of that distance),
    /// as the march mixes their fields. Nil where neither reaches p.
    public static func flow(_ members: [PlumeMember], merged: PlumeMember? = nil, mergeX: Double = 0,
                            origin: Vec3 = .zero, axis: Vec3 = .unitX, at p: Vec3) -> Flow? {
        let wm = merged != nil && mergeX > 0
            ? PlumeMember.smoothstep(mergeX, 1.15 * mergeX, (p - origin).dot(axis)) : 0
        var best: Flow?
        if wm < 1 {
            if let n = nearest(members, at: p) {
                let m = members[n.index]
                if m.impingement != nil || members.count == 1 {
                    // A lone member, or one meeting the deck (its wall jet's
                    // own geometry).
                    if reaches(m, p) { best = flow(m, at: p) }
                } else if n.r <= m.fieldExtent(atX: n.x) {
                    best = Flow(m, atX: n.x, profile: profile(m, atX: n.x, r: n.r))
                }
            }
            if best == nil, let k = members.first(where: { reaches($0, p) }) { best = flow(k, at: p) }
        }
        var far: Flow?
        if wm > 0, let merged, reaches(merged, p) { far = flow(merged, at: p) }
        if let best, let far { return best.mixed(far, wm) }
        return best ?? far
    }

    /// The turbulence at `p` in a cluster of `members` (as `field(frame:
    /// flow:)`, on the cluster's flow there; nil where no member reaches it).
    public static func field(_ members: [PlumeMember], merged: PlumeMember? = nil, mergeX: Double = 0,
                             origin: Vec3 = .zero, axis: Vec3 = .unitX, at p: Vec3, bands: [Band], seed: UInt32,
                             noise: (Vec3, Int) -> Double) -> (noise: Double, depth: Double)? {
        guard let m = members.first,
              let f = flow(members, merged: merged, mergeX: mergeX, origin: origin, axis: axis, at: p) else {
            return nil
        }
        return field(frame: m, flow: f, at: p, bands: bands, seed: seed, noise: noise)
    }

    /// `field`'s noise times its depth at `p` in a cluster (0 where no
    /// member reaches it).
    public static func value(_ members: [PlumeMember], merged: PlumeMember? = nil, mergeX: Double = 0,
                             origin: Vec3 = .zero, axis: Vec3 = .unitX, at p: Vec3, bands: [Band], seed: UInt32,
                             noise: (Vec3, Int) -> Double) -> Double {
        field(members, merged: merged, mergeX: mergeX, origin: origin, axis: axis, at: p, bands: bands, seed: seed,
              noise: noise).map { $0.noise * $0.depth } ?? 0
    }

    /// The volume noise as its texels hold it, evaluated where it is asked
    /// (no trilinear filter): `VolumeNoiseField`'s three octaves at c in
    /// tiles, channel 0 or 1, 0-1. The statistics' stand-in for the GPU's
    /// texture (`texel` is the texture's exact value).
    public static func continuousNoise(_ c: Vec3, channel: Int) -> Double {
        let n = Double(VolumeNoiseField.size)
        let p = (c.x * n, c.y * n, c.z * n)
        let seed = 0x2545_F491 &+ UInt32(channel) &* 0x9E37_79B9
        func at(_ cell: Double) -> (Double, Double, Double) { (p.0 / cell, p.1 / cell, p.2 / cell) }
        let v = 0.6 * VolumeNoiseField.gradientNoise(at(16), period: 8, seed: seed)
            + 0.3 * VolumeNoiseField.gradientNoise(at(8), period: 16, seed: seed &+ 1)
            + 0.1 * VolumeNoiseField.gradientNoise(at(4), period: 32, seed: seed &+ 2)
        return min(max(0.5 + 0.8 * v, 0), 1)
    }

    /// The texture's trilinear sample at c in tiles, repeating: what the
    /// GPU reads (`VolumeNoiseField.value` at the eight texels about it).
    public static func texel(_ c: Vec3, channel: Int) -> Double {
        let n = VolumeNoiseField.size
        let p = (c.x * Double(n) - 0.5, c.y * Double(n) - 0.5, c.z * Double(n) - 0.5)
        let i = (Int(p.0.rounded(.down)), Int(p.1.rounded(.down)), Int(p.2.rounded(.down)))
        let f = (p.0 - Double(i.0), p.1 - Double(i.1), p.2 - Double(i.2))
        func w(_ x: Int) -> Int { ((x % n) + n) % n }
        var v = 0.0
        for k in 0..<8 {
            let o = (k & 1, (k >> 1) & 1, (k >> 2) & 1)
            let weight = (o.0 == 1 ? f.0 : 1 - f.0) * (o.1 == 1 ? f.1 : 1 - f.1) * (o.2 == 1 ? f.2 : 1 - f.2)
            v += weight * VolumeNoiseField.value(w(i.0 + o.0), w(i.1 + o.1), w(i.2 + o.2), channel: channel)
        }
        return v
    }
}
