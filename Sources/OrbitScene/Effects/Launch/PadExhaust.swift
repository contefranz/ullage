import Foundation
import OrbitCore

/// Where the F-1s' exhaust goes on LC-39A, and how much of it (P4; one
/// model with P2's wall jet since look round 2's LR4). The exhaust drops
/// through the Mobile Launcher's 45 ft opening onto the deflector, which
/// splits it north and south out of the flame trench (`LC39A.attachments`).
/// As the vehicle climbs:
/// - **The split** is P2's per-jet geometry (`PlumeImpingement`): each
///   F-1 jet's cross-section where its axis meets the deck, P1's radius
///   R(h) (P2's member at sea level and the rated flow, M), against the
///   opening's square (LC39A, H). What lies outside meets the deck and
///   spreads across it as a wall jet; the rest goes down the opening.
/// - **The reach** is the jets' penetration as a fountain: a hot jet aimed
///   down is turned back by its buoyancy at z_m = 1.85 M^¾ F^−½ (Turner
///   1966, J. Fluid Mech. 26, 779: his constant with the physical fluxes, π
///   included, as Cooper and Hunt 2004 quote it; the same as z_m = 2.46 r0
///   Fr0 with the fluxes per π, as Burridge and Hunt 2012 write it, 1.85 ×
///   π^¼ = 2.46: M), M the cluster's kinematic momentum flux and F the
///   jets' own buoyancy flux, GroundCloud's (`buoyancyFlux`). Seban et al.'s
///   1978 2.35 r0 Fr0 for heated air jets aimed down, 1.77 with physical
///   fluxes, cross-checks it. All of the exhaust reaches the pad while the
///   exits are below z_m; none from the fountain's initial height, about
///   1.5 z_m (Turner 1966), smoothly between. At the rated flow z_m is
///   about 400 m. P2's wall jet takes the same reach
///   (`PlumeImpingement.meeting`); what does not reach the pad is the
///   trail's (LR5).
/// - **One model** for a centred, vertical cluster: P4's sources put the
///   cluster on the pad's axis with its jets straight down (a rebuilt
///   history rises straight up), while P2's members see the tower-clearance
///   yaw's drift of up to about 7 m by T+8 s. The split differs by that
///   while the yaw lasts (T+1 to T+8.75 s).
///
/// Site frame throughout (`LC39A`): x north towards the tower, y west, z up
/// from the ML deck, m.
public enum PadExhaust {
    static func attachment(_ name: String) -> VisualAttachment {
        LC39A.attachments.first { $0.name == name }!
    }

    /// The ML's exhaust opening, half its 45 ft side.
    public static let openingHalf = attachment("ML exhaust opening").radius
    /// The flame trench's two exits at grade: their centres (mid-depth),
    /// the way the exhaust leaves (horizontal, north and south) and their
    /// half width.
    public static let trenchExits: [VisualAttachment] = [attachment("Flame trench north exit"),
                                                         attachment("Flame trench south exit")]
    /// The F-1 exit plane's height on the pad: the vehicle base, the deck's
    /// 3.24 m above it (LC39A, derived, H).
    public static let exitHeightOnPad = -LC39A.deckAboveVehicleBase

    /// The share of the exhaust's flow that reaches the ground: down the
    /// opening into the trench, and onto the deck around it.
    public struct Shares: Equatable {
        public var trench: Double
        public var deck: Double
        public var total: Double { trench + deck }
    }

    // MARK: The split

    /// The five F-1s' exits about the cluster's axis (horizontal offsets,
    /// site frame): the centre engine and the four outboard 182 in off it
    /// (L) on the diagonals; the scene's own nozzles where it has them
    /// (`pattern(exits:)`).
    public static let exitPattern: [Vec3] = {
        let d = 182 * 0.0254 / 2.0.squareRoot()
        return [Vec3(0, 0, 0), Vec3(d, d, 0), Vec3(-d, d, 0), Vec3(-d, -d, 0), Vec3(d, -d, 0)]
    }()

    /// The exits' offsets about their centroid, horizontal.
    public static func pattern(exits: [Vec3]) -> [Vec3] {
        guard !exits.isEmpty else { return exitPattern }
        let c = exits.reduce(Vec3.zero, +) * (1 / Double(exits.count))
        return exits.map { Vec3($0.x - c.x, $0.y - c.y, 0) }
    }

    /// An F-1's jet as P2 draws it at sea level and the rated flow (P1's
    /// `PlumeModel`): its radius R(x) down the jet.
    static let jet: PlumeMember = {
        let spec = ApolloExhaust.f1.spec
        let air = USStandardAtmosphere1976().state(altitude: 0)
        let state = PlumeModel.state(spec, flowFraction: 1, ambient: air, streamAlong: 0, streamAcross: 0)
        return PlumeLook.member(spec, state: state, exit: .zero, axis: -.unitZ, exitRadius: spec.exitRadius, ambient: air)
    }()

    /// The deck, the opening's square about the pad's axis.
    static let deck = PlumeImpingement(centre: .zero, normal: .unitZ, openingHalf: openingHalf, openingAxis: .unitX)

    /// The share of the jets' flow that meets the deck outside the opening,
    /// their exits `h` m above it (site z) about the pad's axis in
    /// `pattern`: each jet's cross-section there against the opening's
    /// square, P2's `shareOutside`; none while the exits are inside it.
    public static func deckShare(height h: Double, pattern: [Vec3] = exitPattern) -> Double {
        guard h > 0, !pattern.isEmpty else { return 0 }
        let r = jet.radius(atX: h)
        return pattern.reduce(0.0) { $0 + deck.shareOutside(point: $1, radius: r) } / Double(pattern.count)
    }

    /// How far out from the pad's axis the jets meet the deck, m: the
    /// farthest jet's edge, at least the opening's half side. The deck's
    /// wall jet starts there.
    public static func footprint(height h: Double, pattern: [Vec3] = exitPattern) -> Double {
        guard h > 0 else { return openingHalf }
        let r = jet.radius(atX: h)
        return max(openingHalf, pattern.map { $0.length + r }.max() ?? r)
    }

    /// The deck's wall jet's half-thickness at ρ from the pad's axis, the
    /// exits `h` m above the deck: P2's law (`PlumeImpingement.thickness`),
    /// half the jet's radius there and 0.087 a metre (Poreh, Tsuei and
    /// Cermak 1967), the cluster's from its axis.
    public static func wallThickness(rho: Double, height h: Double) -> Double {
        0.5 * jet.radius(atX: max(h, 0)) + PlumeImpingement.wallGrowth * max(rho, 0)
    }

    // MARK: The reach: a fountain

    /// Turner's (1966) constant for a round fountain's steady penetration
    /// with the physical fluxes, 1.85 (2.46 per π; M), and Seban et al.'s
    /// (1978) for heated air jets aimed down, 2.35 per π, 1.77 with the
    /// physical fluxes: the cross-check.
    public static let fountainConstant = 1.85
    public static var sebanConstant: Double { 2.35 / pow(Double.pi, 0.25) }
    /// A fountain's initial penetration over its steady one (Turner 1966, M).
    public static let initialPenetration = 1.5

    /// The cluster's fountain penetration at flow fraction `f`, m: C M^¾
    /// F^−½, M = thrust / ρ (LiftoffRise's five F-1s) and F the jets' own
    /// buoyancy flux, `buoyancyFlux`. It goes as f^¼. In the standard
    /// sea-level air, as P2's members see it, so that the two agree.
    public static func penetration(flowFraction f: Double = 1, constant c: Double = fountainConstant) -> Double {
        guard f > 0 else { return 0 }
        let m = f * LiftoffRise.thrust / seaLevel.density
        let b = f * buoyancyFlux
        guard b > 0 else { return .infinity }
        return c * pow(m, 0.75) / b.squareRoot()
    }

    /// The standard sea-level air (US76) the reach is taken in.
    static let seaLevel = USStandardAtmosphere1976().state(altitude: 0)

    /// The five F-1s' buoyancy flux at the rated flow, m⁴/s³: GroundCloud's
    /// for the same jets, g Q / (ρ c_p T), Q the heat their exhaust brings
    /// (its stagnation enthalpy and afterburning, `GroundCloud.exhaustHeat`)
    /// less what the flames radiate, before any of it boils water.
    public static var buoyancyFlux: Double {
        let air = seaLevel
        let q = LiftoffRise.flow * GroundCloud.exhaustHeat(ambient: air.temperature) * (1 - GroundCloud.radiantFraction)
        return 9.80665 * q / (air.density * GroundCloud.airHeat * air.temperature)
    }

    /// The share of the exhaust that reaches the pad from exits `h` m above
    /// the deck: all below the fountain's penetration, none from its
    /// initial height, smoothly between.
    public static func reaching(height h: Double, flowFraction f: Double = 1) -> Double {
        let zm = penetration(flowFraction: f)
        return 1 - PlumeMember.smoothstep(zm, initialPenetration * zm, h)
    }

    /// The shares with the exit plane `exitHeight` m above the deck (site
    /// z; below it on the pad), the exits in `pattern`, at flow fraction
    /// `f` in air of `rho`.
    public static func shares(exitHeight z: Double, pattern: [Vec3] = exitPattern, flowFraction f: Double = 1) -> Shares {
        let reach = reaching(height: z, flowFraction: f)
        let deck = deckShare(height: z, pattern: pattern)
        return Shares(trench: reach * (1 - deck), deck: reach * deck)
    }

    // MARK: Water

    /// The pad's water, gal/min, as AS-506's press kit gives it (NASA News
    /// Release 69-83K, pp. 167-168, H): the trench-side nozzles' 8,000 gpm,
    /// from 10 s before liftoff, aimed over the deflector, run through the
    /// ignition; the ML deck's 29 nozzles, 50,000 gpm for 30 s from liftoff
    /// and 20,000 after (from first motion, L). Apollo 16's report gives
    /// 8,000 gpm into the trench and 20,000 onto the ML, pad and trench
    /// from T−2 min, 28,000 in all (NASA TM X-2935, p. 18), and SA-501's
    /// caption 28,000 "to cool the flame deflector and trench" (MSFC
    /// 6760617; SP-350 §6.3): P4 had 28,000 in the trench and 50,000 on the
    /// deck, counting the 20,000 twice.
    public static let trenchWater = 8_000.0
    public static func deckWater(sinceFirstMotion t: Double) -> Double {
        t < 0 ? 0 : t < 30 ? 50_000 : 20_000
    }

    // MARK: Rates (L, the look)

    /// Exhaust puffs a second out of each trench exit with all five F-1s
    /// at full flow and all of it down the opening.
    public static let trenchPuffRate = 20.0
    /// Exhaust puffs a second spreading over the deck with all of it there.
    public static let deckPuffRate = 45.0
}
