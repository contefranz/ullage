import Foundation
import OrbitCore

/// Order-2 real spherical harmonics, nine coefficients per channel: the
/// environment probe's low-frequency light for the plumes and particles
/// (track R3), and the Swift reference of ProbeShaders' `.sphericalHarmonics`
/// header.
///
/// - **Basis:** the real SH Y_lm in world (ICRF) axes, in the order
///   (0,0), (1,−1), (1,0), (1,1), (2,−2), (2,−1), (2,0), (2,1), (2,2), with
///   the usual constants (`basis`): Y₀₀ = 0.282095, Y₁ = 0.488603 (y, z, x),
///   Y₂ = 1.092548 xy, 1.092548 yz, 0.315392 (3z² − 1), 1.092548 xz,
///   0.546274 (x² − y²). Directions point away from the surface, toward the
///   light.
/// - **This struct** holds the radiance's projection L_lm = ∫ L(ω) Y_lm(ω) dω
///   (cd/m² sr, linear Rec. 709), so L(ω) ≈ Σ L_lm Y_lm(ω).
/// - **What the renderer publishes** (`LightingUniforms.sh9`, buffer 29) is
///   `irradianceOverPi`: Â_l/π · L_lm, with Ramamoorthi and Hanrahan's
///   (2001) cosine-lobe bands Â₀ = π, Â₁ = 2π/3, Â₂ = π/4, so that
///   Σ c_lm Y_lm(n) = E(n)/π, the luminance of a white Lambertian surface
///   facing n: the irradiance cube's quantity, in cd/m², not pre-exposed.
public struct SH9: Equatable {
    public static let count = 9
    /// The band l of coefficient i.
    public static let bands = [0, 1, 1, 1, 2, 2, 2, 2, 2]
    /// Â_l / π: a band's share through the clamped cosine (Ramamoorthi and
    /// Hanrahan 2001, eq. 8): 1, 2/3, 1/4.
    public static let irradianceBand = [1.0, 2.0 / 3.0, 0.25]

    /// L_lm, cd/m² sr, rgb.
    public var coefficients: [Spectrum3]

    public init(coefficients: [Spectrum3] = Array(repeating: .zero, count: SH9.count)) {
        precondition(coefficients.count == Self.count, "SH9 has nine coefficients")
        self.coefficients = coefficients
    }

    // MARK: The basis

    /// Y_0 ... Y_8 at the unit direction `d`.
    public static func basis(_ d: Vec3) -> [Double] {
        let x = d.x, y = d.y, z = d.z
        return [
            0.282_094_791_773_878_1,
            0.488_602_511_902_919_9 * y,
            0.488_602_511_902_919_9 * z,
            0.488_602_511_902_919_9 * x,
            1.092_548_430_592_079_2 * x * y,
            1.092_548_430_592_079_2 * y * z,
            0.315_391_565_252_520_1 * (3 * z * z - 1),
            1.092_548_430_592_079_2 * x * z,
            0.546_274_215_296_039_6 * (x * x - y * y),
        ]
    }

    // MARK: Projection

    /// The projection of radiance samples, each a unit direction, the solid
    /// angle it stands for (sr) and its radiance (cd/m²): L_lm = Σ L Y_lm Ω.
    public static func project<S: Sequence>(_ samples: S) -> SH9
        where S.Element == (direction: Vec3, solidAngle: Double, radiance: Spectrum3) {
        var c = [Spectrum3](repeating: .zero, count: count)
        for s in samples {
            let y = basis(s.direction)
            for i in 0..<count { c[i] = c[i] + s.radiance * (y[i] * s.solidAngle) }
        }
        return SH9(coefficients: c)
    }

    /// The projection of a radiance function by a midpoint rule over a cube's
    /// texels (`EnvironmentProbe.texels`), `size` texels to a face's side.
    public static func project(size: Int = 64, _ radiance: (Vec3) -> Spectrum3) -> SH9 {
        project(EnvironmentProbe.texels(size: size).map {
            (direction: $0.direction, solidAngle: $0.solidAngle, radiance: radiance($0.direction))
        })
    }

    // MARK: What it gives

    /// The radiance it holds toward `d` (rings where the light is sharp).
    public func radiance(_ d: Vec3) -> Spectrum3 { evaluate(coefficients, d) }

    /// The coefficients the renderer publishes: Â_l/π L_lm.
    public var irradianceOverPi: [Spectrum3] {
        (0..<Self.count).map { coefficients[$0] * Self.irradianceBand[Self.bands[$0]] }
    }

    /// The radiance coefficients from the published ones.
    public init(irradianceOverPi c: [Spectrum3]) {
        precondition(c.count == Self.count, "SH9 has nine coefficients")
        self.init(coefficients: (0..<Self.count).map { c[$0] / Self.irradianceBand[Self.bands[$0]] })
    }

    /// E(n)/π, cd/m²: the luminance of a white Lambertian surface facing the
    /// unit `n`, clamped at 0 (nine coefficients can ring below it).
    public func irradianceOverPi(_ n: Vec3) -> Spectrum3 {
        let e = evaluate(irradianceOverPi, n)
        return Spectrum3(max(e.r, 0), max(e.g, 0), max(e.b, 0))
    }

    /// The mean radiance over the sphere, (1/4π) ∫ L dω = L₀₀ Y₀₀: what an
    /// isotropic scatterer sends toward the eye per unit albedo.
    public var meanRadiance: Spectrum3 { coefficients[0] * Self.basis(Vec3(0, 0, 1))[0] }

    /// The radiance a medium scatters toward the eye per unit albedo, ∫ L(ω)
    /// p(ω·v) dω with Henyey and Greenstein's phase function of asymmetry
    /// `g`, `v` the unit view ray (camera to the point): by Funk and Hecke,
    /// Σ g^l L_lm Y_lm(v). g = 0 is `meanRadiance`; forward scattering (g >
    /// 0) favours the light from behind the point. Clamped at 0.
    public func inScatter(view v: Vec3, asymmetry g: Double) -> Spectrum3 {
        let y = Self.basis(v), gl = [1, g, g * g]
        var s = Spectrum3.zero
        for i in 0..<Self.count { s = s + coefficients[i] * (gl[Self.bands[i]] * y[i]) }
        return Spectrum3(max(s.r, 0), max(s.g, 0), max(s.b, 0))
    }

    private func evaluate(_ c: [Spectrum3], _ d: Vec3) -> Spectrum3 {
        let y = Self.basis(d)
        var s = Spectrum3.zero
        for i in 0..<Self.count { s = s + c[i] * y[i] }
        return s
    }
}
