import Foundation
import OrbitCore

/// Track LR4: the launch cloud's turbulence, as each primitive's boundary
/// displaced (`GroundCloudField.Primitive.density(at:displacement:)`):
/// its level sets moved by a sum of octaves of flow noise, the eddies of
/// the flow's own Kolmogorov cascade, as fine as the pixel resolves.
///
/// - **The eddies** are LR3's `TurbulenceSpectrum`'s (`spectrum`): the
///   largest cell is `integralScale` of the flow's own size (a thermal's
///   radius, a jet's or a stem's radius, the wall jet's thickness: 0.45,
///   look round 2), octave k's 2^−k of it, drawn down to the pixel's
///   footprint (its cut-off: a cloud far away is smooth, one close by
///   cauliflowers).
/// - **Their lifetime** is the spectrum's: the largest's turnover, size over
///   the flow's speed (R/w; a stalled cloud's no slower than the morning's
///   convection, `convectiveVelocity`), octave k's τ0 2^(−2k/3).
/// - **The boundary** is a fractal surface of dimension D = 7/3 (Sreenivasan
///   and Meneveau 1986 measured 2.36 ± 0.05 on turbulent jets' and wakes'
///   interfaces: H), so octave k displaces it by 2^(−k(3 − D)) of the
///   largest's (its Hurst exponent 3 − D: a level set's height, not the
///   spectrum's 2^(−k/3) increments), the whole cascade's rms being
///   `interfaceSpread` of the flow's size (an intermittent edge's,
///   Wygnanski and Fiedler 1969's jet: L for the thermals).
/// - **The noise** is P2's flow noise (`PlumeTurbulence`): each octave's
///   lifetime falls in P2's bands of lifetimes, each band two layers cross-
///   faded half a life apart and re-seeded at each birth (Neyret 2003),
///   blended keeping the variance (Heitz and Neyret 2018), averaged over
///   the camera's exposure. Each layer is laid out where the flow carried
///   its points from since its birth, in the flow's own coordinates (a
///   jet's eddies along it, ∫dx/ℓ, a thermal's about its centre), so it
///   rides the flow and grows with it, and never repeats.
///
/// Deterministic: a function of the turbulence clock and the primitive's
/// seed, so a rebuilt field's turbulence is the frames'.
///
/// The plan's fallback, Kim et al. 2008's wavelet turbulence (its sub-grid
/// synthesis: noise bands scaled by the resolved flow's local energy along
/// the −5/3 spectrum), is not needed while the primitives are closed form;
/// it would be written from the paper only, its code being GPL.
public enum LaunchTurbulence {
    /// The boundary's fractal dimension (Kolmogorov's 7/3).
    public static let dimension = 7.0 / 3
    /// The largest eddies over the flow's own size (look round 2: 0.45 R).
    public static let integralScale = 0.45
    /// The boundary's rms displacement over the flow's own size, the whole
    /// cascade's (L).
    public static let interfaceSpread = 0.25
    /// The slowest turnover's speed, m/s: the morning mixed layer's
    /// convective velocity w* (L, the plan's flagged w*; LR5 shares it).
    public static let convectiveVelocity = 1.5
    /// The most octaves drawn (High's cap).
    public static let maximumOctaves = 8
    /// The volume noise's standard deviation about its mean (`VolumeNoiseField`,
    /// measured by `LaunchTurbulenceTests`).
    public static let noiseDeviation = 0.146

    /// Octave k's share of the largest's displacement: 2^(−k(3 − D)).
    public static func gain(_ k: Int) -> Double { pow(2, -Double(k) * (3 - dimension)) }

    /// The whole cascade's rms over the largest octave's: √Σ gain(k)².
    public static var cascade: Double { (1 / (1 - pow(2, -2 * (3 - dimension)))).squareRoot() }

    /// The cascade of a flow `size` m across moving at `speed` m/s: its
    /// largest cell `integralScale` of the size, living size / speed (the
    /// speed no less than `convectiveVelocity`), at most `limit` octaves.
    public static func spectrum(size: Double, speed: Double, limit: Int = maximumOctaves) -> TurbulenceSpectrum {
        TurbulenceSpectrum(largestCell: integralScale * size, largestLifetime: size / max(speed, convectiveVelocity),
                           maximumOctaves: limit)
    }

    /// Each octave's weight at a pixel's footprint (m): the spectrum's cut-off.
    public static func weights(_ s: TurbulenceSpectrum, footprint: Double) -> [Double] {
        (0..<s.octaves(footprint: footprint)).map { s.weight(octave: $0, footprint: footprint) }
    }

    /// The displacement (m) of `p`'s level sets at site point `x`, at
    /// turbulence time `bands` (`PlumeTurbulence.bands(time:)`), seen at a
    /// pixel of `footprint` m; `noise(c, channel)` the volume noise's value
    /// (0-1) at c in tiles.
    public static func displacement(_ p: GroundCloudField.Primitive, at x: Vec3, bands: [PlumeTurbulence.Band],
                                    footprint: Double, limit: Int = maximumOctaves,
                                    noise: (Vec3, Int) -> Double) -> Double {
        displacementAndSpread(p, at: x, bands: bands, footprint: footprint, limit: limit, noise: noise).eta
    }

    /// The displacement (m) and its rms there (m): every octave drawn, its
    /// weight, gain and exposure's depth (for `GroundCloudField.Primitive
    /// .density(at:displacement:spread:)`, which keeps the mass).
    public static func displacementAndSpread(_ p: GroundCloudField.Primitive, at x: Vec3,
                                             bands: [PlumeTurbulence.Band], footprint: Double,
                                             limit: Int = maximumOctaves,
                                             noise: (Vec3, Int) -> Double) -> (eta: Double, spread: Double) {
        let size = p.size(at: x)
        guard size > 0 else { return (0, 0) }
        let speed = max(p.speed(at: x), convectiveVelocity)
        let spectrum = Self.spectrum(size: size, speed: speed, limit: limit)
        let a0 = interfaceSpread * size / cascade
        let seed = PlumeTurbulence.seedOffset(p.seed)
        var eta = 0.0, variance = 0.0
        for (k, weight) in weights(spectrum, footprint: footprint).enumerated() where weight > 0 {
            let eddy = spectrum.cell(octave: k)
            let life = spectrum.lifetime(octave: k)
            let band = min(max(log2(life / PlumeTurbulence.shortestLife), 0), Double(PlumeTurbulence.bandCount - 1) - 1e-3)
            let j = Int(band), beta = PlumeTurbulence.blend(band - Double(j))
            var octave = 0.0, bandWeights = 0.0, depths = 0.0
            for (b, wb) in [(j, 1 - beta), (j + 1, beta)] where wb > 1e-3 {
                let layerLife = PlumeTurbulence.life(band: b)
                let depth = shutterDepth(speed: speed, cell: eddy, life: layerLife)
                var sum = 0.0, weights2 = 0.0
                for layer in 0..<2 {
                    let phase = layer == 0 ? bands[b].phase.0 : bands[b].phase.1
                    let cycle = layer == 0 ? bands[b].cycle.0 : bands[b].cycle.1
                    let w = 1 - abs(2 * phase - 1)
                    guard w > 1e-6 else { continue }
                    let c = carried(p, at: x, age: phase * layerLife, octave: k)
                    let r = Vec3(PlumeTurbulence.basis[0].dot(c), PlumeTurbulence.basis[1].dot(c),
                                 PlumeTurbulence.basis[2].dot(c)) / PlumeTurbulence.eddiesPerTile
                    let shift = PlumeTurbulence.offset(cycle: cycle, band: b, layer: layer) + seed
                        + octaveOffset(k)
                    let n = (noise(r + shift, k % 2) - 0.5) / noiseDeviation
                    sum += w * n
                    weights2 += w * w
                }
                guard weights2 > 0 else { continue }
                octave += wb * depth * sum / weights2.squareRoot()
                bandWeights += wb * wb
                depths += wb * wb * depth * depth
            }
            guard bandWeights > 0 else { continue }
            let amplitude = weight * a0 * gain(k)
            eta += amplitude * octave / bandWeights.squareRoot()
            variance += amplitude * amplitude * depths / bandWeights
        }
        return (eta, variance.squareRoot())
    }

    /// The depth an octave of noise cells `cell` m keeps over the camera's
    /// exposure, its layers living `life` s, in a flow of `speed` m/s: P2's
    /// shutter average, the flow sweeping u/L integral lengths a second past
    /// the point, L the noise's integral length in its cell (P2's
    /// `Flow.sweep`).
    public static func shutterDepth(speed: Double, cell: Double, life: Double) -> Double {
        PlumeTurbulence.shutterAverage(life: life, sweep: speed / (PlumeTurbulence.integralLength * cell)).depth
    }

    /// Octave k's own offset in the tile, so the octaves are independent.
    static func octaveOffset(_ k: Int) -> Vec3 {
        PlumeTurbulence.offset(cycle: 0x4C52_3400 &+ UInt32(k), band: 0, layer: 0)
    }

    /// The noise's coordinate at `x` for a layer `age` s old, in octave k's
    /// eddies: where the flow carried the point from since the layer's
    /// birth, in the flow's own coordinates.
    /// - A thermal: about its centre, which carries it.
    /// - A round jet, the wall jet, a stem: along the flow in eddies
    ///   (∫ds/ℓ, ℓ growing with the flow), carried back at the flow's speed
    ///   (exactly for the jet, dx/dt = C/x; in one midpoint step for the
    ///   others), across it in eddies there.
    public static func carried(_ p: GroundCloudField.Primitive, at x: Vec3, age: Double, octave k: Int) -> Vec3 {
        let scale = pow(2, Double(k)) / integralScale
        switch p.shape {
        case .thermal:
            return (x - p.origin) * (scale / max(p.radius, 1e-6))
        case .roundJet:
            let (s, _) = p.axial(x)
            let d = x - p.origin, across = d - p.axis * s
            let (u, v) = perpendicular(p.axis)
            let xs = max(s, p.start)
            let c = GroundCloud.jetVelocity * p.flux.squareRoot()
            let from = max(xs * xs - 2 * c * age, 0.25 * p.start * p.start).squareRoot()
            let b = p.jetRadius(xs)
            let k0 = GroundCloudField.concentrationSpread * GroundCloud.jetSpread
            return Vec3(across.dot(u) / b * scale, across.dot(v) / b * scale, log(from) / k0 * scale)
        case .wallJet:
            let (rho, z) = p.radial(x)
            let r = max(rho, p.start)
            let u0 = p.speed(at: x)
            let mid = max(r - 0.5 * age * u0, 0.5 * p.start)
            let from = max(r - age * GroundCloudField.wallSpeed(momentum: p.flux, rho: mid, thickness: p.thickness(mid)),
                           0.5 * p.start)
            // In local eddies of 0.45 δ(ρ) every way: across the flow on a
            // circle of (ρ + z)/δ eddies in the noise's plane (its arc ρ dφ/δ
            // and its height dz/δ, with no seam), along it in the third
            // axis, ∫dρ/δ = ln(δ/δ0)/g from the layer's start, carried back
            // at the layer's speed.
            let d = x - p.origin
            let dir = rho > 1e-6 ? (d.x / rho, d.y / rho) : (1.0, 0.0)
            let delta = p.thickness(r)
            let around = (r + max(z, 0)) / delta * scale
            let along = log(max(p.thickness(from), 1e-3) / max(p.radius, 1e-3)) / max(p.growth, 1e-6) * scale
            return Vec3(dir.0 * around, dir.1 * around, along)
        case .stem:
            let (s, _) = p.axial(x)
            let d = x - p.origin, across = d - p.axis * s
            let (u, v) = perpendicular(p.axis)
            let l = max(s, 0)
            let w = p.speed(at: x)
            let midSpeed = GroundCloudField.plumeSpeed(buoyancy: p.flux, height: max(l - 0.5 * age * w, 0) + p.virtualOrigin)
            let from = l - age * midSpeed
            let b = p.stemRadius(l)
            let g = max(p.growth, 1e-6)
            let along = log(max(p.radius + g * from, 0.1 * p.radius)) / (g)
            return Vec3(across.dot(u) / b * scale, across.dot(v) / b * scale, along * scale)
        }
    }

    /// Two unit vectors across `axis`.
    static func perpendicular(_ axis: Vec3) -> (Vec3, Vec3) {
        let a = abs(axis.z) < 0.9 ? Vec3.unitZ : Vec3.unitX
        let u = axis.cross(a).normalized
        return (u, axis.cross(u).normalized)
    }

    /// The field's primitives' densities at `x`, their boundaries displaced:
    /// for `GroundCloudField.sample(at:density:)`.
    public static func densities(_ f: GroundCloudField, at x: Vec3, bands: [PlumeTurbulence.Band], footprint: Double,
                                 limit: Int = maximumOctaves, noise: @escaping (Vec3, Int) -> Double)
        -> (GroundCloudField.Primitive) -> Double {
        { p in
            let d = displacementAndSpread(p, at: x, bands: bands, footprint: footprint, limit: limit, noise: noise)
            return p.density(at: x, displacement: d.eta, spread: d.spread)
        }
    }

    /// The volume noise as the GPU samples it: P3's 128³ texture
    /// (`VolumeNoiseField`), trilinearly, wrapping, at c in tiles.
    public static func volumeNoise(_ c: Vec3, _ channel: Int) -> Double {
        let n = Double(VolumeNoiseField.size)
        let p = (c.x * n - 0.5, c.y * n - 0.5, c.z * n - 0.5)
        let i = (Int(p.0.rounded(.down)), Int(p.1.rounded(.down)), Int(p.2.rounded(.down)))
        let f = (p.0 - Double(i.0), p.1 - Double(i.1), p.2 - Double(i.2))
        let m = VolumeNoiseField.size
        func w(_ a: Int) -> Int { ((a % m) + m) % m }
        var v = 0.0
        for k in 0..<8 {
            let o = (k & 1, (k >> 1) & 1, (k >> 2) & 1)
            let weight = (o.0 == 1 ? f.0 : 1 - f.0) * (o.1 == 1 ? f.1 : 1 - f.1) * (o.2 == 1 ? f.2 : 1 - f.2)
            v += weight * VolumeNoiseField.value(w(i.0 + o.0), w(i.1 + o.1), w(i.2 + o.2), channel: channel)
        }
        return v
    }

    /// The field P3's texture samples, evaluated where `volumeNoise`
    /// interpolates it (`VolumeNoiseField.value(at:channel:)`): smooth below
    /// a texel, for measuring the cascade itself.
    public static func smoothNoise(_ c: Vec3, _ channel: Int) -> Double {
        let n = Double(VolumeNoiseField.size)
        func wrap(_ x: Double) -> Double { x - (x / n).rounded(.down) * n }
        return VolumeNoiseField.value(at: (wrap(c.x * n), wrap(c.y * n), wrap(c.z * n)), channel: channel)
    }
}
