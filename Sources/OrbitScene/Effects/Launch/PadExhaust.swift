import Foundation
import OrbitCore

/// Where the F-1s' exhaust goes on LC-39A, and how much of it (P4). The
/// exhaust drops through the Mobile Launcher's 45 ft opening onto the
/// deflector, which splits it north and south out of the flame trench
/// (`LC39A.attachments`). As the vehicle climbs, the five plumes' envelope
/// grows past the opening and what it no longer covers spreads across the
/// deck as a wall jet; past some 100-200 m of climb (the design's figure)
/// the plume no longer reaches the ground with any force.
///
/// Site frame throughout (`LC39A`): x north towards the tower, y west, z up
/// from the ML deck, m. Every number here is visual (L) unless it says
/// otherwise; the geometry is LC's (H to L as its datasheet grades it).
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

    /// The five plumes' outer radius at the exit plane: the outboard
    /// engines' axes about 4.6 m off the vehicle's (182 in, L) plus an F-1
    /// exit's 1.78 m (ApolloExhaust's gas side, H). The scene's nozzles give
    /// it when they can (`clusterRadius(exits:)`).
    public static let clusterRadius = 6.4
    /// The envelope's spreading half-angle below the exits at sea level,
    /// where the overexpanded F-1 plume barely widens (L).
    public static let spreadAngle = 10 * Double.pi / 180
    /// The fade's scale and the climb past which no exhaust reaches the
    /// ground with force (L: "faded out by about 100-200 m of climb"): half
    /// of it still does at about 45 m, 36 % at 60 m, 5 % at 150 m.
    public static let fadeClimb = 60.0
    public static let cutoffClimb = 400.0

    /// The share of the exhaust's flow that reaches the ground: down the
    /// opening into the trench, and onto the deck around it.
    public struct Shares: Equatable {
        public var trench: Double
        public var deck: Double
        public var total: Double { trench + deck }
    }

    /// The shares with the exit plane `exitHeight` m above the deck (site z;
    /// below it on the pad) and the envelope `radius` m at the exits. The
    /// trench takes the part of the envelope's cross-section at the deck
    /// that the opening's square covers; the rest meets the deck.
    public static func shares(exitHeight z: Double, radius: Double = clusterRadius) -> Shares {
        let r = envelopeRadius(atDeckFrom: z, radius: radius)
        let opening = 4 * openingHalf * openingHalf
        let down = min(1, opening / (Double.pi * r * r))
        let reach = reaching(climb: z - exitHeightOnPad)
        return Shares(trench: reach * down, deck: reach * (1 - down))
    }

    /// The envelope's radius where it meets the deck, m.
    public static func envelopeRadius(atDeckFrom z: Double, radius: Double = clusterRadius) -> Double {
        radius + max(0, z) * tan(spreadAngle)
    }

    /// The share of the exhaust that still reaches the ground after `climb`
    /// m of rise: 1 / (1 + (climb / 60 m)²), tapered by (1 − climb / 400 m)².
    public static func reaching(climb: Double) -> Double {
        let c = max(0, climb)
        guard c < cutoffClimb else { return 0 }
        let taper = 1 - c / cutoffClimb
        return taper * taper / (1 + (c / fadeClimb) * (c / fadeClimb))
    }

    /// The envelope's radius from the nozzle exits (site frame): the
    /// farthest exit's distance from their centroid plus its radius.
    public static func clusterRadius(exits: [(centre: Vec3, radius: Double)]) -> Double {
        guard !exits.isEmpty else { return clusterRadius }
        let c = exits.reduce(Vec3.zero) { $0 + $1.centre } * (1 / Double(exits.count))
        return exits.map { Vec3($0.centre.x - c.x, $0.centre.y - c.y, 0).length + $0.radius }.max()!
    }

    // MARK: Water

    /// The pad's water, as steam made where the exhaust meets it (relative
    /// to the trench's): the flame trench and deflector nozzles' 28,000 gpm
    /// (SA-501's, MSFC 6760617, H) run through the ignition; the ML deck's
    /// 29 nozzles, 50,000 gal/min for 30 s from liftoff and 20,000 after
    /// (A11PK through LC39A-datasheet.md §12, M; from first motion, L).
    public static let trenchWater = 28_000.0
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
