import Foundation
import OrbitCore

/// The environment probe's geometry and maths (track R3), in pure Swift: the
/// reference ProbeShaders and EnvironmentProbePass mirror, and what their
/// tests compare the GPU with.
///
/// - **The cube:** Metal's (OpenGL's) cube-map convention. Face f's texel
///   (x, y) of n, s = 2(x + ½)/n − 1 rightwards and t = 2(y + ½)/n − 1
///   downwards, looks along `direction(face:s:t:)`. Rendering a face, the
///   view's x is `basis.right`, y `basis.up` and −z `basis.forward`: a
///   reflection (cube maps are left-handed), which a ray caster does not
///   mind.
/// - **Units:** radiance in cd/m², linear Rec. 709, not pre-exposed, the
///   Sun excluded (it stays the analytic light).
/// - **Derived maps:** the specular cube's mip k is the radiance prefiltered
///   with GGX at perceptual roughness k/(mips − 1) (`roughness(mip:count:)`),
///   which LightingCommon reads at level r × (mips − 1); the irradiance cube
///   holds E/π (`irradianceReference`); SH9 (`SH9`) is projected from the
///   same 32² downsample.
/// - **The night floor** (`nightFloor`, `floored`): a uniform E/π a white
///   surface shows at a fixed share of the exposure's white, merged as a
///   soft maximum so it lifts only what is darker than it.
public enum EnvironmentProbe {
    public enum Face: Int, CaseIterable {
        case positiveX, negativeX, positiveY, negativeY, positiveZ, negativeZ
    }

    // MARK: Cube geometry

    /// The (not unit) direction through face coordinates s (rightwards) and t
    /// (downwards), each in −1...1.
    public static func direction(face: Face, s: Double, t: Double) -> Vec3 {
        switch face {
        case .positiveX: return Vec3(1, -t, -s)
        case .negativeX: return Vec3(-1, -t, s)
        case .positiveY: return Vec3(s, 1, t)
        case .negativeY: return Vec3(s, -1, -t)
        case .positiveZ: return Vec3(s, -t, 1)
        case .negativeZ: return Vec3(-s, -t, -1)
        }
    }

    /// The unit direction through the centre of texel (x, y) of `face`,
    /// `size` texels to a side.
    public static func direction(face: Face, x: Int, y: Int, size: Int) -> Vec3 {
        let n = Double(size)
        return direction(face: face, s: 2 * (Double(x) + 0.5) / n - 1, t: 2 * (Double(y) + 0.5) / n - 1).normalized
    }

    /// The face a direction falls on and its face coordinates (s, t).
    public static func faceCoordinates(_ d: Vec3) -> (face: Face, s: Double, t: Double) {
        let ax = abs(d.x), ay = abs(d.y), az = abs(d.z)
        if ax >= ay, ax >= az {
            return d.x > 0 ? (.positiveX, -d.z / ax, -d.y / ax) : (.negativeX, d.z / ax, -d.y / ax)
        }
        if ay >= az {
            return d.y > 0 ? (.positiveY, d.x / ay, d.z / ay) : (.negativeY, d.x / ay, -d.z / ay)
        }
        return d.z > 0 ? (.positiveZ, d.x / az, -d.y / az) : (.negativeZ, -d.x / az, -d.y / az)
    }

    /// The view basis that renders `face`: pixel ndc (x, y) looks along
    /// right·x + up·y + forward (with tan(fov/2) = 1). Columns of the face's
    /// view-to-world matrix: right, up, −forward.
    public static func basis(_ face: Face) -> (right: Vec3, up: Vec3, forward: Vec3) {
        // ndc x = s, ndc y = −t.
        let forward = direction(face: face, s: 0, t: 0)
        let right = direction(face: face, s: 1, t: 0) - forward
        let up = forward - direction(face: face, s: 0, t: 1)
        return (right, up, forward)
    }

    /// The solid angle of texel (x, y) of a face `size` texels to a side,
    /// sr: the face's area element integrated exactly (the sum over the cube
    /// is 4π).
    public static func texelSolidAngle(x: Int, y: Int, size: Int) -> Double {
        let n = Double(size)
        let x0 = 2 * Double(x) / n - 1, x1 = 2 * Double(x + 1) / n - 1
        let y0 = 2 * Double(y) / n - 1, y1 = 2 * Double(y + 1) / n - 1
        func a(_ u: Double, _ v: Double) -> Double { atan2(u * v, (u * u + v * v + 1).squareRoot()) }
        return a(x0, y0) - a(x0, y1) - a(x1, y0) + a(x1, y1)
    }

    public struct Texel {
        public var face: Face
        public var x: Int, y: Int
        public var direction: Vec3
        public var solidAngle: Double
    }

    /// Every texel of a cube `size` to a side, face by face, row by row.
    public static func texels(size: Int) -> [Texel] {
        var out: [Texel] = []
        out.reserveCapacity(6 * size * size)
        for face in Face.allCases {
            for y in 0..<size {
                for x in 0..<size {
                    out.append(Texel(face: face, x: x, y: y, direction: direction(face: face, x: x, y: y, size: size),
                                     solidAngle: texelSolidAngle(x: x, y: y, size: size)))
                }
            }
        }
        return out
    }

    // MARK: A cube of radiance

    /// A radiance cube on the CPU: texel (x, y) of face f at
    /// `values[(f × size + y) × size + x]`.
    public struct CubeMap {
        public let size: Int
        public var values: [Spectrum3]

        public init(size: Int, values: [Spectrum3]) {
            precondition(values.count == 6 * size * size, "six faces of size²")
            self.size = size
            self.values = values
        }

        /// The cube of `radiance` at the texel centres.
        public init(size: Int, radiance: (Vec3) -> Spectrum3) {
            self.init(size: size, values: EnvironmentProbe.texels(size: size).map { radiance($0.direction) })
        }

        public func value(_ face: Face, _ x: Int, _ y: Int) -> Spectrum3 {
            values[(face.rawValue * size + y) * size + x]
        }

        /// The texel `d` falls in (no filtering).
        public func nearest(_ d: Vec3) -> Spectrum3 {
            let c = EnvironmentProbe.faceCoordinates(d)
            let n = Double(size)
            let x = min(max(Int(((c.s + 1) / 2 * n).rounded(.down)), 0), size - 1)
            let y = min(max(Int(((c.t + 1) / 2 * n).rounded(.down)), 0), size - 1)
            return value(c.face, x, y)
        }

        /// The 2 × 2 box average, half the size (the GPU's mipmaps).
        public func downsampled() -> CubeMap {
            let h = size / 2
            var out: [Spectrum3] = []
            out.reserveCapacity(6 * h * h)
            for face in Face.allCases {
                for y in 0..<h {
                    for x in 0..<h {
                        let s = value(face, 2 * x, 2 * y) + value(face, 2 * x + 1, 2 * y)
                            + value(face, 2 * x, 2 * y + 1) + value(face, 2 * x + 1, 2 * y + 1)
                        out.append(s * 0.25)
                    }
                }
            }
            return CubeMap(size: h, values: out)
        }

        /// (direction, solid angle, radiance) of every texel, for `SH9.project`.
        public var samples: [(direction: Vec3, solidAngle: Double, radiance: Spectrum3)] {
            zip(EnvironmentProbe.texels(size: size), values).map { ($0.direction, $0.solidAngle, $1) }
        }
    }

    // MARK: Derived maps

    /// The perceptual roughness the specular cube's mip `mip` of `count` is
    /// prefiltered at: mip/(count − 1), as LightingCommon reads it.
    public static func roughness(mip: Int, count: Int) -> Double {
        count > 1 ? Double(mip) / Double(count - 1) : 0
    }

    /// The GGX-prefiltered radiance toward the unit `n` at perceptual
    /// roughness `roughness`, by brute force over every texel: Karis' (2013)
    /// split-sum prefilter with n = v = r, Σ L(l) D(h) (n·l) Ω / Σ D(h) (n·l) Ω,
    /// h the half vector (the importance-sampled estimator's limit, whose
    /// weight is the light's pdf D(h)/4 times n·l).
    public static func prefilterReference(_ cube: CubeMap, n: Vec3, roughness: Double) -> Spectrum3 {
        let alpha = BRDF.alpha(roughness: roughness)
        var sum = Spectrum3.zero, weight = 0.0
        for (t, l) in zip(texels(size: cube.size), cube.values) {
            let nl = n.dot(t.direction)
            guard nl > 0 else { continue }
            let h = (n + t.direction).normalized
            let w = BRDF.ggx(nh: max(n.dot(h), 0), alpha: alpha) * nl * t.solidAngle
            sum = sum + l * w
            weight += w
        }
        return weight > 0 ? sum / weight : .zero
    }

    /// E(n)/π, cd/m², by brute force over every texel: (1/π) Σ L max(0, n·l) Ω.
    public static func irradianceReference(_ cube: CubeMap, n: Vec3) -> Spectrum3 {
        var sum = Spectrum3.zero
        for (t, l) in zip(texels(size: cube.size), cube.values) {
            let nl = n.dot(t.direction)
            if nl > 0 { sum = sum + l * (nl * t.solidAngle) }
        }
        return sum / Double.pi
    }

    // MARK: The night floor

    /// The night floor as E/π (cd/m²) at pre-exposure `preExposure`: a white
    /// Lambertian surface lit by it alone shows `share` of the exposure's
    /// white (StandInLighting's floor, `floorIlluminance` / π).
    public static func nightFloor(share: Double, preExposure: Double) -> Double {
        share / max(preExposure, 1e-30)
    }

    /// `x` (an E/π or a radiance, ≥ 0) with the floor `f` merged as a soft
    /// maximum, x + f²/(x + f): f where x is 0, 1.5 f where x is f, and x +
    /// f²/x, all but x, where x is far above it.
    public static func floored(_ x: Double, floor f: Double) -> Double {
        guard f > 0 else { return x }
        return x + f * f / (max(x, 0) + f)
    }

    // MARK: Look-development environments

    /// An analytic environment the probe can take instead of the scene's
    /// (`ProbeSettings.environment`), for the look-dev goldens.
    public struct LookDevEnvironment: Equatable {
        public enum Kind: Int { case furnace = 1, earthBelow = 2, earthUniform = 3 }
        public var kind: Kind
        /// The furnace's uniform radiance, cd/m².
        public var radiance: Spectrum3
        /// The body's centre (unit, world), sin² of its angular radius, its
        /// ground's reflectance (albedo × colour / π, per lux) and the Sun
        /// (unit, world) with its illuminance (lux, rgb) on it.
        public var bodyDirection: Vec3
        public var bodySinSigma2: Double
        public var reflectance: Spectrum3
        public var toSun: Vec3
        public var sunIlluminance: Spectrum3

        /// A white furnace of radiance `radiance` (cd/m²).
        public static func furnace(_ radiance: Double) -> LookDevEnvironment {
            LookDevEnvironment(kind: .furnace, radiance: Spectrum3(repeating: radiance), bodyDirection: .zero,
                               bodySinSigma2: 0, reflectance: .zero, toSun: .unitZ, sunIlluminance: .zero)
        }

        /// R2's look-dev Earth (`LookDevScenes`) drawn point by point: a
        /// Lambertian sphere of albedo 0.3 in StandInLighting's blue-white
        /// below (world −z) at 185 km, lit by `sunLux` at `toSun`, in black
        /// space.
        public static func earthBelow(toSun: Vec3, sunLux: Double) -> LookDevEnvironment {
            let colour = Photometry.sunColor
            let albedo = 0.3 / Double.pi
            return LookDevEnvironment(kind: .earthBelow, radiance: .zero, bodyDirection: Vec3(0, 0, -1),
                                      bodySinSigma2: LookDevScenes.earthSinSigma2,
                                      reflectance: Spectrum3(0.78 * albedo, 0.88 * albedo, 1.0 * albedo),
                                      toSun: toSun.normalized,
                                      sunIlluminance: Spectrum3(colour.r, colour.g, colour.b) * sunLux)
        }

        /// The same Earth lit evenly, its ground at the radiance of the
        /// sub-solar point everywhere: a uniform disc, whose irradiance is
        /// Howell's sphere factor (`BRDF.sphereIrradiance`).
        public static func earthUniform(sunLux: Double) -> LookDevEnvironment {
            var e = earthBelow(toSun: .unitZ, sunLux: sunLux)
            e.kind = .earthUniform
            return e
        }

        /// The radiance toward the unit `d`, cd/m².
        public func radiance(_ d: Vec3) -> Spectrum3 {
            switch kind {
            case .furnace:
                return radiance
            case .earthBelow, .earthUniform:
                // The sphere of radius 1 at distance 1/sin σ along the body's
                // direction; the ground's normal where the ray meets it.
                let s2 = bodySinSigma2
                guard s2 > 0 else { return .zero }
                let r = 1 / s2.squareRoot()
                let b = d.dot(bodyDirection) * r
                let disc = b * b - (r * r - 1)
                guard disc >= 0, b > 0 else { return .zero }
                let t = b - disc.squareRoot()
                let normal = (d * t - bodyDirection * r).normalized
                let cosine = kind == .earthUniform ? 1 : max(normal.dot(toSun), 0)
                return reflectance * sunIlluminance * cosine
            }
        }
    }
}
