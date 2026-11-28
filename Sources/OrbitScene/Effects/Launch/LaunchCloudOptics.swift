import Foundation
import OrbitCore

/// Track LR4: how light meets the launch cloud's medium (`GroundCloudField`):
/// its extinction from the mass it carries, its single-scattering albedo and
/// phase, the two-stream of its multiple scattering, and what its hot soot
/// gives off. The cloud is water condensed on droplets and kerosene soot;
/// both are counted in kilograms, so the optical depth follows the cloud's
/// mass, not a photograph (look round 2, decision 5).
///
/// L inputs, flagged (docs/m16/look-round-2.md §6): the droplets' 10 µm
/// radius, the soot yield (P2's until decision 4 picks one from LR5 PR1's
/// renders) and its albedo.
public enum LaunchCloudOptics {
    // MARK: The particles

    /// The condensate's droplets: 10 µm in radius (L), extinction
    /// efficiency 2 (the geometric limit, C1's `CloudOptics.extinction`), so
    /// 3 Q / (4 ρ r) = 150 m²/kg.
    public static let dropletRadius = 10e-6
    public static var dropletExtinction: Double {
        CloudOptics.extinction(waterContent: 1, effectiveRadius: dropletRadius)
    }
    /// Kerosene soot: 7.5 m²/g of extinction at 550 nm and a single-
    /// scattering albedo of 0.2, fresh soot's (Bond and Bergstrom 2006: M).
    public static let sootExtinction = 7_500.0
    public static let sootAlbedo = 0.2
    /// Soot's asymmetry in the visible: small aggregates scatter about
    /// evenly forward and back (L).
    public static let sootAsymmetry = 0.4

    /// The soot the F-1's exhaust leaves in the air, kg a kilogram of it:
    /// P2's, implied by its plume (decision 4 picks the round's value from
    /// LR5 PR1's renders; until then P2's): its soot's optical depth across
    /// an F-1 exit at the rated flow (`PlumeLook.Optics.sootDepth` times the
    /// spec's soot index) over this extinction, the exit's diameter and the
    /// exit's density at sea level (P1's `PlumeModel`), what the
    /// afterburning flame leaves of it (`burntSoot`): about 0.075 %.
    public static let sootYield: Double = {
        let f1 = ApolloExhaust.f1.spec
        let air = USStandardAtmosphere1976().state(altitude: 0)
        let exit = PlumeModel.state(f1, flowFraction: 1, ambient: air, streamAlong: 0, streamAcross: 0)
        let depth = PlumeLook.Optics.sootDepth * f1.sootIndex
        let atExit = depth / (sootExtinction * exit.exitDensity * 2 * f1.exitRadius)
        return atExit * PlumeLook.Optics.burntSoot
    }()

    /// The water the F-1's exhaust brings, kg a kilogram of it: its own
    /// water and what its hydrogen makes burning in the air (CEA's mole
    /// fractions, `GroundCloud`), H for the run.
    public static let exhaustWater = (GroundCloud.exhaustH2 + GroundCloud.exhaustH2O) * 0.018015
        / ApolloExhaust.f1.spec.molarMass

    // MARK: The medium at a point

    /// What the medium holds at a point, kg/m³: the condensed water and the
    /// soot; and its temperature (K).
    public struct Content: Equatable {
        public var condensate: Double
        public var soot: Double
        public var temperature: Double

        public init(condensate: Double, soot: Double, temperature: Double) {
            self.condensate = condensate
            self.soot = soot
            self.temperature = temperature
        }
    }

    /// The medium's optics at a point: extinction (1/m), single-scattering
    /// albedo, the asymmetry its diffuse streams scatter with, and the
    /// droplets' share of the scattering (the rest is soot's: the phase is
    /// blended by it).
    public struct Optics: Equatable {
        public var extinction: Double
        public var albedo: Double
        public var asymmetry: Double
        public var dropletShare: Double

        public var absorption: Double { extinction * (1 - albedo) }
        public var scattering: Double { extinction * albedo }
    }

    /// The optics of `c`.
    public static func optics(_ c: Content) -> Optics {
        let drops = dropletExtinction * max(c.condensate, 0), soot = sootExtinction * max(c.soot, 0)
        let sigma = drops + soot
        guard sigma > 0 else { return Optics(extinction: 0, albedo: 1, asymmetry: 0, dropletShare: 1) }
        let scattering = drops + sootAlbedo * soot
        let share = scattering > 0 ? drops / scattering : 1
        let g = share * dropletAsymmetry + (1 - share) * sootAsymmetry
        return Optics(extinction: sigma, albedo: scattering / sigma, asymmetry: g, dropletShare: share)
    }

    // MARK: Phase

    /// The droplets' phase: C2's approximate Mie (Jendersie and d'Eon 2023)
    /// at their 20 µm diameter, so the cloud's glory and forward peak are
    /// C2's.
    public static var dropletPhase: CloudPhase.ApproximateMie {
        CloudPhase.ApproximateMie(diameter: 2 * dropletRadius * 1e6)
    }
    /// The asymmetry the droplets' diffuse streams scatter with: C1's water
    /// droplets', as C2's clouds' (`CloudLighting.asymmetry`), so that the
    /// two-stream is C2's where the medium is water alone.
    public static let dropletAsymmetry = CloudLayerModel.waterAsymmetry

    /// The phase (1/sr) at the cosine of the scattering angle (the view ray
    /// outward from the eye against the direction to the light, as C2's),
    /// for scattering of which `dropletShare` is the droplets'.
    public static func phase(_ cosTheta: Double, dropletShare: Double) -> Double {
        dropletShare * dropletPhase.phase(cosTheta)
            + (1 - dropletShare) * CloudPhase.henyeyGreenstein(cosTheta, g: sootAsymmetry)
    }

    // MARK: Multiple scattering: the two-stream

    /// The two-stream slab of optical depth τ, single-scattering albedo ω
    /// and asymmetry g: the diffuse fluxes F↓, F↑ obey
    ///   dF↓/dτ = −γ1 F↓ + γ2 F↑,  dF↑/dτ = γ1 F↑ − γ2 F↓,
    /// γ1 = 1 − ω(1 − b), γ2 = ω b, b = (1 − g)/2 the backscattered fraction:
    /// C2's slab (Bohren 1987; `CloudLighting.streams`) with absorption
    /// added. With F↓ = 1 entering the top and nothing entering the bottom,
    /// at depth t (x = τ − t below it):
    ///   F↓ = (cosh kx + γ1 x sinhc kx) / D,  F↑ = γ2 x sinhc kx / D,
    ///   D = cosh kτ + γ1 τ sinhc kτ,  k = √(γ1² − γ2²),
    /// sinhc z = sinh z / z. At ω = 1, k = 0 and they are C2's
    /// 1 − bt/(1 + bτ) and b(τ − t)/(1 + bτ) (`LaunchCloudOpticsTests`).
    public static func streams(depth t: Double, column tau: Double, albedo omega: Double,
                               asymmetry g: Double) -> (down: Double, up: Double) {
        let b = (1 - g) / 2, tau = max(tau, 0), t = min(max(t, 0), tau)
        let g1 = 1 - omega * (1 - b), g2 = omega * b
        let k = max(g1 * g1 - g2 * g2, 0).squareRoot()
        let x = tau - t
        guard k * tau > 30 else {
            let d = cosh(k * tau) + g1 * tau * sinhc(k * tau)
            return ((cosh(k * x) + g1 * x * sinhc(k * x)) / d, g2 * x * sinhc(k * x) / d)
        }
        // Thick and absorbing: the same over 2 e^(kτ), which would overflow.
        let e1 = exp(k * (x - tau)), e2 = exp(-k * (x + tau)), e3 = exp(-2 * k * tau)
        let d = 1 + e3 + g1 * (1 - e3) / k
        return ((e1 + e2 + g1 * (e1 - e2) / k) / d, g2 * (e1 - e2) / k / d)
    }

    /// sinh z / z, its series near 0.
    static func sinhc(_ z: Double) -> Double {
        let a = abs(z)
        return a > 1e-4 ? sinh(a) / a : 1 + z * z / 6
    }

    /// The slab's reflectance and transmittance (diffuse, per unit flux
    /// entering its top): F↑ at its top, F↓ at its bottom.
    public static func slab(column tau: Double, albedo omega: Double, asymmetry g: Double)
        -> (reflectance: Double, transmittance: Double) {
        (streams(depth: 0, column: tau, albedo: omega, asymmetry: g).up,
         streams(depth: tau, column: tau, albedo: omega, asymmetry: g).down)
    }

    /// The radiance of the diffuse streams going in a direction whose
    /// upward cosine is `muUp`, per unit flux entering the top: each stream
    /// isotropic over its hemisphere, blended by the direction (C2's
    /// `CloudLighting.streamRadiance`).
    public static func streamRadiance(down: Double, up: Double, muUp: Double) -> Double {
        CloudLighting.streamRadiance(down: down, up: up, muUp: muUp)
    }

    // MARK: Emission

    /// What the hot soot gives off, cd/m³ per metre of path: its absorption
    /// times the blackbody's luminance at its temperature (`PlumeLook`'s
    /// fit, none below 300 K); the condensate is cold.
    public static func emission(_ c: Content) -> Photometry.RGB {
        let a = sootExtinction * max(c.soot, 0) * (1 - sootAlbedo)
        guard a > 0 else { return Photometry.RGB(0, 0, 0) }
        return PlumeLook.blackbody(c.temperature).scaled(by: a)
    }
}
