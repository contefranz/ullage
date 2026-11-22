import Foundation
import OrbitCore

/// A plume meeting the ground while the vehicle is low (P2): the Mobile
/// Launcher's deck on LC-39A. The F-1s' exits sit 3.24 m below the deck at
/// rest, inside its 45 ft opening, and their jets drop through it onto the
/// flame deflector (hidden in the trench); as the vehicle climbs and the
/// jets widen, what the opening no longer takes meets the deck and spreads
/// across it as a radial wall jet.
///
/// The wall jet is the free jet continued along the deck: at ρ from where
/// the jet's axis meets the deck, its flow has travelled x = h + ρ from the
/// exit (h the exit's distance to the deck along the axis) and keeps the
/// free jet's state there (its flame to the flame's length, its mixing),
/// but hotter: where the deck stops the jet its kinetic energy comes back
/// as heat, the gas nearing its total temperature (a turbulent recovery
/// factor, Pr^(1/3) ≈ 0.89, H), the blinding fireball on the deck. Its
/// layer thickens as a radial wall jet entrains air, δ = R(h)/2 + 0.087 ρ
/// (Poreh, Tsuei and Cermak 1967: δ½/ρ ≈ 0.087, M), so a point z above the
/// deck lies at r = z R(x)/δ of the equivalent free jet, the exhaust
/// diluted over the larger area (R(x)²/2ρδ, the jet's flow kept). Where the
/// free jet is the more inside of the two it takes the sample. The flow is
/// the share of each jet's cross-section at the deck that lands outside
/// the opening's square.
///
/// The seam with the launch effects (P4's `PadExhaust`, whose smoke follows
/// the same shares): this reads the scene's LC-39A site and `LC39A`'s
/// opening, nothing of the launch track's.
public struct PlumeImpingement: Equatable {
    /// The deck: a camera-relative point on it (the opening's centre) and
    /// its unit normal (up).
    public var centre: Vec3
    public var normal: Vec3
    /// The opening's square: its half side (m) and one unit axis in the
    /// deck (the other is normal × it).
    public var openingHalf: Double
    public var openingAxis: Vec3
    /// The share of the jet's flow that meets the deck around the opening.
    public var deckShare = 0.0
    /// How far along the deck the wall jet is drawn (m from where the axis
    /// meets it).
    public var reach = 0.0

    public init(centre: Vec3, normal: Vec3, openingHalf: Double, openingAxis: Vec3) {
        self.centre = centre
        self.normal = normal
        self.openingHalf = openingHalf
        self.openingAxis = openingAxis
    }

    /// LC-39A's deck in `scene`, if the pad is there.
    public static func deck(_ scene: RenderScene) -> PlumeImpingement? {
        guard let site = scene.sites.first(where: { $0.name == LC39A.placement().name }) else { return nil }
        let north = site.orientation.c0, up = site.orientation.c2
        return PlumeImpingement(centre: site.origin, normal: up.normalized, openingHalf: LC39A.openingHalf,
                                openingAxis: north.normalized)
    }

    /// The exit's distance to the deck along `m`'s axis (m); nil where its
    /// jet does not point down at it or its exit is below it (inside the
    /// opening).
    public func distance(_ m: PlumeMember) -> Double? {
        let an = m.axis.dot(normal)
        guard an < -0.1 else { return nil }
        let h = (centre - m.exit).dot(normal) / an
        return h > 0 ? h : nil
    }

    /// Whether camera-relative `p` lies over the deck, outside the opening.
    public func overDeck(_ p: Vec3) -> Bool {
        let d = p - centre, v = normal.cross(openingAxis)
        return max(abs(d.dot(openingAxis)), abs(d.dot(v))) > openingHalf
    }

    /// The share of a disc of `radius` about `point` (on the deck) outside
    /// the opening, sampled on a polar grid.
    public func shareOutside(point: Vec3, radius: Double) -> Double {
        guard radius > 0 else { return overDeck(point) ? 1 : 0 }
        let u = openingAxis, v = normal.cross(openingAxis)
        var outside = 0.0, total = 0.0
        for i in 0..<12 {
            let s = (Double(i) + 0.5) / 12, rr = radius * s.squareRoot()
            for k in 0..<24 {
                let a = 2 * Double.pi * (Double(k) + 0.5) / 24
                total += 1
                if overDeck(point + u * (rr * cos(a)) + v * (rr * sin(a))) { outside += 1 }
            }
        }
        return outside / total
    }

    /// `m` meeting this deck: its share and reach set (`deckShare`, the jet
    /// out to its length or one and a half flame lengths, whichever is
    /// less); nil where it does not meet it.
    public func meeting(_ m: PlumeMember) -> PlumeImpingement? {
        guard let h = distance(m), h < m.length else { return nil }
        var i = self
        let hit = m.exit + m.axis * h
        i.deckShare = shareOutside(point: hit, radius: m.radius(atX: h))
        let flame = m.flameLength > 0 ? 1.5 * m.flameLength : m.length
        i.reach = max(0, min(m.length, flame) - h)
        guard i.deckShare > 1e-3, i.reach > 0 else { return nil }
        return i
    }

    /// A turbulent layer's recovery factor, Pr^(1/3) at Pr ≈ 0.7.
    public static let recovery = 0.89
    /// A radial wall jet's half-thickness growth, δ½/ρ (Poreh, Tsuei and
    /// Cermak 1967).
    public static let wallGrowth = 0.087

    /// The wall jet's thickness ρ from the impact (m): `wallGrowth` ρ on
    /// half the jet's radius there.
    public func thickness(_ m: PlumeMember, h: Double, rho: Double) -> Double {
        0.5 * m.radius(atX: h) + Self.wallGrowth * rho
    }

    /// The temperature the wall jet's core recovers to (K): its static
    /// temperature and `recovery` of the rest of its total (the chamber's).
    public static func recovered(static t: Double, total: Double) -> Double {
        t + recovery * max(total - t, 0)
    }

    /// Where camera-relative `p` lies in `m`'s wall jet: the equivalent free
    /// jet's x and r, and the dilution over the free jet's to scale it by;
    /// nil where the free jet takes it (inside the opening, beyond the
    /// reach, below the deck).
    public func wallJet(_ m: PlumeMember, at p: Vec3) -> (x: Double, r: Double, dilution: Double)? {
        guard let h = distance(m) else { return nil }
        let z = (p - centre).dot(normal)
        guard z >= 0, overDeck(p) else { return nil }
        let hit = m.exit + m.axis * h
        var d = p - hit
        d = d - normal * d.dot(normal)
        let rho = d.length
        guard rho <= reach else { return nil }
        let x = h + rho, big = m.radius(atX: x), delta = thickness(m, h: h, rho: rho)
        let r = z * big / delta
        // The free jet where it is the more inside of the two.
        let free = (p - m.exit).dot(m.axis)
        if free < h {
            let rFree = ((p - m.exit) - m.axis * free).length
            guard r / big < rFree / max(m.radius(atX: free), 1e-6) else { return nil }
        }
        return (x, r, min(1, big * big / (2 * max(rho, 1e-6) * delta)))
    }
}
