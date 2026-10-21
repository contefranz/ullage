import Foundation
import OrbitCore

/// Launch Complex 39A as Apollo 8 (AS-503) and Apollo 11 (AS-506) stood on
/// it: the Mobile Launcher (ML) base on its pedestals, the Launch Umbilical
/// Tower (LUT) with its nine swing arms and the hammerhead crane, the four
/// hold-down arms and three tail service masts on the deck, and the pad's
/// hardstand, ramp, flame trench and deflector.
///
/// A body-fixed site, not a vessel: the simulation never sees it.
/// `placement(bodyID:)` stands it on the core's geodetic pad
/// (`VesselLibrary.lc39A`) with its x axis towards the tower, the way the
/// core's vehicle faces it with Position II. The site frame is
/// `RenderScene.Site`'s: x forward (north, towards the tower), y left
/// (west), z up along the geodetic normal; its origin is on the vehicle's
/// axis at the ML deck (tower level 0). Metres.
///
/// The set is a list of rigid `Element`s, each tessellated once in its own
/// frame and turned about its hinge as the countdown and launch drive it
/// (`Element.transform(at:_:)`, range time from a `Countdown`): the swing
/// arms, the hold-down arms' upper links and the tail service masts' booms.
/// `attachments` gives P4 the exhaust's way out: the ML's opening, the
/// deflector's ridge and the flame trench's two exits.
///
/// Every number is in docs/LC39A-datasheet.md with its source and grade, as
/// in `ApolloShapeData`: (H) high, (M) medium, (L) low; "derived" is
/// arithmetic on sourced values, "scaled" read off a drawing, "estimate" a
/// value that only has to look right, with how it was made.
public enum LC39A {
    static let foot = 0.3048
    static let inch = 0.0254
    static let degree = Double.pi / 180

    // MARK: Placement (datasheet §1)

    /// Azimuth of the site's x axis, the tower's side of the vehicle (rad,
    /// from north towards east): north. M503 Fig. 8-7 marks "TOWER" with
    /// the north arrow and puts Position II on that side (H); the core
    /// stands the vehicle with Position I east, so Position II faces north.
    public static let towerAzimuth = 0.0

    /// Vehicle station of the hold-down posts, which rest on the arms'
    /// heads: STA 113.31 (M503 Fig. 8-7, H).
    static let holdDownPostStation = 113.31            // in
    /// The arm's head top above its base, the ML deck: 100.75 in (Phillips
    /// and Tolson 1975 Fig. 10, H; shims adjust it by 1 in).
    static let holdDownHeadHeight = 100.75             // in
    /// The core's vehicle base, the F-1 exit plane, as a station:
    /// STA -115.0 (`AS506.baseStation`; datasheet §4 of AS506, L-M).
    static let vehicleBaseStation = -115.0             // in

    /// The ML deck above the vehicle base the core places: STA 113.31 less
    /// the 100.75 in head height is the deck, STA 12.56; the base, STA -115,
    /// is 127.56 in (3.240 m) below it (derived, H).
    public static let deckAboveVehicleBase: Double = {
        let post = (holdDownPostStation - vehicleBaseStation) * inch
        return post - holdDownHeadHeight * inch
    }()

    /// Where the site stands on `bodyID` (the Earth, NAIF 399): the core's
    /// geodetic pad, its origin on the vehicle's axis at the ML deck, its x
    /// axis towards the tower.
    public static func placement(bodyID: Int = 399) -> SitePlacement {
        let pad = VesselLibrary.lc39A
        return SitePlacement(name: "LC-39A", bodyID: bodyID, latitude: pad.latitude * degree,
                             longitude: pad.longitude * degree,
                             height: pad.elevation + deckAboveVehicleBase, azimuth: towerAzimuth)
    }

    // MARK: Heights (datasheet §1-§2, §8)

    /// The ML base, 25 ft deep (A8PK, H), on pedestals 22 ft high (A8PK;
    /// Balke Fig. 1: 7.6 and 6.7 m, H): the deck is 47 ft above the
    /// hardstand.
    static let baseDepth = 25 * foot
    static let pedestalHeight = 22 * foot
    /// The hardstand's top, the pad's surface, below the deck.
    public static let hardstandHeight = -(baseDepth + pedestalHeight)
    /// The pad stands 42 ft above the surrounding grade (M503 p. 8-8, H),
    /// where the flame trench's floor is (A11PK PDF p. 171, H).
    public static let gradeHeight = hardstandHeight - 42 * foot
    /// The surface the renderer draws, the ellipsoid, below the deck: the
    /// core's pad elevation puts the vehicle base that far above it.
    public static var ellipsoidHeight: Double { -(VesselLibrary.lc39A.elevation + deckAboveVehicleBase) }
    /// Where the pad's fill and the trench floor end below: a metre under
    /// the drawn surface, so no gap shows at its edge (estimate).
    static var footingHeight: Double { ellipsoidHeight - 1 }

    // MARK: Mobile Launcher base (datasheet §2)

    /// The vehicle's axis from the tower end's mount line along the ML:
    /// 6.09 + 27.4 m (Balke Fig. 1, H).
    static let axisFromTowerEndMounts = 6.09 + 27.4
    /// Mount lines along the ML: 18.28 m from the tower end to the interior
    /// girder, 29.87 m on to the far end (Balke Fig. 1, H), so x of each
    /// line (the tower end north).
    static let mountLinesX: [Double] = {
        let north = axisFromTowerEndMounts
        return [north, north - 18.28, north - 18.28 - 29.87]
    }()
    /// Across the ML the mount lines are 40.5 m apart (Balke Fig. 1, H).
    static let mountLineY = 40.5 / 2
    /// The base's outline: 48.87 m long, 0.406 m beyond the tower end's
    /// mount line; 41.15 m wide (Balke Fig. 1, H; 160 by 135 ft, A8PK).
    static let baseNorth = axisFromTowerEndMounts + 0.406
    static let baseSouth = baseNorth - 48.87
    static let baseHalfWidth = 41.15 / 2
    /// The exhaust opening, 45 ft square, the vehicle over it (A8PK, H).
    static let openingHalf = 45 * foot / 2
    /// Pedestal columns, 914 mm tubes (Balke p. 375, H).
    static let pedestalDiameter = 0.914
    /// The four extensible columns: 6.55 m in from the side mount lines
    /// (Balke Fig. 1, H), about 8.2 m either side of the axis along the ML
    /// (scaled off Balke Fig. 1, which is not drawn to scale: L).
    static let extensibleColumnY = mountLineY - 6.55
    static let extensibleColumnX = 8.2

    // MARK: Launch Umbilical Tower (datasheet §3)

    /// The tower's centre 80 ft from the vehicle's axis, its nearest
    /// columns 60 ft (M503 p. 8-6, H): a 40 ft square.
    static let towerCentreX = 80 * foot
    static let towerHalf = 20 * foot
    /// The tower's face towards the vehicle, where the swing arms hinge.
    public static let towerFaceX = towerCentreX - towerHalf
    /// "An open steel structure 380 feet high" (M503 p. 8-6, H; 114 in at
    /// 1/40 scale above the platform, TN D-4870, M).
    public static let towerTop = 380 * foot
    /// The flared base: four legs from the 40 ft square at about 80 ft down
    /// to the deck, 117 ft apart across the ML (scaled off TN D-4870 Fig. 2,
    /// an early architectural drawing: M). The outboard legs stand on the
    /// end girder (Balke p. 374, H), 10 ft behind the tower's back face. The
    /// inboard legs rise in the plane of the tower's face, their fronts
    /// flush with it, rather than from the interior girder 3.08 m in front
    /// of it (Balke, H): the retracted arms lie flat against the face
    /// (`armRetractedAngle`), and arm 1, at 60 ft, would fold through legs
    /// leaning out from that girder (estimate, L).
    static let flareTop = 80 * foot
    static let legFootHalfAcross = 117 * foot / 2
    static let legSection = 1.5                         // m, estimate (L)
    /// The legs' centrelines along the ML, (foot, top): the outboard pair's
    /// from the end girder's mount line to the back corners, the inboard
    /// pair's half a leg behind the face, foot to top.
    static let flareLegsX: [(foot: Double, top: Double)] = {
        let inboard = towerFaceX + legSection / 2
        return [(mountLinesX[0], towerCentreX + towerHalf), (inboard, inboard)]
    }()
    /// Tie frames across the flare at about 32 and 63 ft (scaled off TN
    /// D-4870 Fig. 2, M).
    static let flareTies = [32 * foot, 63 * foot]

    // MARK: Hammerhead crane (datasheet §5)

    /// The crane's top 398 ft above the deck, its hook reaching 85 ft from
    /// the tower's centre (A8PK, H).
    static let craneTop = 398 * foot
    static let craneReach = 85 * foot
    /// Jib 6 ft wide and 8 ft deep, counter-jib 25 ft, turntable 20 ft
    /// square up to the jib (estimates from M503 Fig. 8-8's photograph, L).
    static let jibWidth = 6 * foot
    static let jibDepth = 8 * foot
    static let counterJib = 25 * foot
    static let turntableSide = 20 * foot
    /// Parked pointing north, away from the vehicle (estimate, L: at
    /// liftoff fin A cleared the tower top by 11 m, FER-503 §11.3.1, so the
    /// jib was not over the vehicle's path; which way it pointed is not
    /// sourced).
    public static let craneHeading = 0.0

    // MARK: Swing arms (datasheet §4)

    /// One of the LUT's nine service arms.
    public struct SwingArm {
        public var number: Int
        public var name: String
        /// Retracts before liftoff (preflight) or at liftoff (in-flight).
        public var inFlight: Bool
        /// Tower level (ft above the deck) of its control distributor, where
        /// the arm's walkway is.
        public var level: Double
        /// The radius (m) the arm reaches: the drawn vehicle's largest
        /// (`vehicleOutline`) over the height of its umbilical carrier, or of
        /// arm 9's white room. An item off the axis in front of it can stop
        /// the arm further out (`armLength`, `accessArmRoomRadius`).
        public var vehicleRadius: Double
        /// The arm's centreline offset east of the tower's (m, site y).
        public var offset: Double
        /// Retract time (s): withdrawal of the umbilical carrier and the
        /// swing, M503 Fig. 8-8's figure ("max" for the in-flight arms).
        public var retractTime: Double

        /// Height of its walkway above the deck (m).
        public var height: Double { level * LC39A.foot }
    }

    /// The nine arms, numbered from the bottom (M503 Fig. 8-8, H); levels
    /// from the KSC electrical handbook's distributors (H as printed; M as
    /// the arms' heights), arm 9's from A8PK (H).
    public static let swingArms: [SwingArm] = [
        umbilicalArm(1, "S-IC intertank", inFlight: false, level: 60, retractTime: 8),
        umbilicalArm(2, "S-IC forward", inFlight: false, level: 120, retractTime: 8),
        umbilicalArm(3, "S-II aft", inFlight: false, level: 140, retractTime: 8),
        umbilicalArm(4, "S-II intermediate", inFlight: true, level: 160, retractTime: 6.4),
        umbilicalArm(5, "S-II forward", inFlight: true, level: 200, retractTime: 7.4),
        umbilicalArm(6, "S-IVB aft", inFlight: true, level: 220, retractTime: 7.7),
        umbilicalArm(7, "S-IVB forward", inFlight: true, level: 260, retractTime: 8.4),
        umbilicalArm(8, "Service module", inFlight: true, level: 300, retractTime: 9.0),
        SwingArm(number: 9, name: "Command module access", inFlight: false, level: accessArmLevel,
                 vehicleRadius: accessArmRoomRadius, offset: -(accessArmRoomRadius + chamber.depth / 2),
                 retractTime: 12),
    ]

    /// An umbilical arm (1-8) at `level`, reaching the drawn vehicle's
    /// largest radius over its carrier's height (derived, M: the vehicle's
    /// outline is the core's dressed Saturn V, exterior datasheet §1-§12).
    static func umbilicalArm(_ number: Int, _ name: String, inFlight: Bool, level: Double,
                             retractTime: Double) -> SwingArm {
        let z = level * foot
        let r = vehicleOutline.largestRadius(from: z + carrierHeights.low, to: z + carrierHeights.high)
        return SwingArm(number: number, name: name, inFlight: inFlight, level: level, vehicleRadius: r,
                        offset: armOffset, retractTime: retractTime)
    }
    /// The umbilical arms' centrelines 1.5 m east of the tower's, so their
    /// carriers meet the vehicle between Positions I and II, near II, where
    /// its umbilical plates and doors are (exterior datasheet §2.6, §4,
    /// §7; estimate, L).
    static let armOffset = -1.5
    /// Arm 9's level: "the 320-foot level above the launcher base" (A8PK, H).
    static let accessArmLevel = 320.0
    /// Arm 9's white room, centred on the CM's side hatch (Position I, east),
    /// stands off the drawn vehicle's largest radius over its height, or
    /// the items off its axis in front of the room if they reach further
    /// east: the boost protective cover's radius at the room's floor, Xa
    /// 1046 (derived, M). The real CM's 1.46 m at the hatch (exterior
    /// datasheet §9) lies inside the drawn, idealised outer mould line
    /// (ibid. §9.1).
    static let accessArmRoomRadius: Double = {
        let floor = accessArmLevel * foot + chamber.floor, heights = floor...(floor + chamber.height)
        let items = vehicleItems.reach(towards: Vec3(0, -1, 0), across: -chamber.depth / 2...chamber.depth / 2,
                                       heights: heights)
        return max(vehicleOutline.largestRadius(from: heights.lowerBound, to: heights.upperBound), items ?? 0)
    }()
    /// Arm width: the retracted arms' near face 8.63 m from fin tip A
    /// (FER-503 Table 11-1's available clearance) with fin A 6.76 m from
    /// the axis towards the tower puts it 2.90 m in front of the tower
    /// face, the width of an arm folded flat against it (derived, L-M).
    static let armWidth = 18.288 - 8.628 - 6.757
    /// Truss depth at the root and the tip (estimates, L: two 1.2 m hinges
    /// per arm, Moonport p. 336).
    static let armDepth = (root: 3.0, tip: 2.0)
    /// The umbilical carrier at an arm's tip (estimate, L).
    static let carrier = (length: 1.0, side: 1.6)
    /// The carrier's bottom and top below the arm's walkway (m): centred on
    /// the truss's depth at the tip.
    static let carrierHeights = (low: -armDepth.tip / 2 - carrier.side / 2, high: -armDepth.tip / 2 + carrier.side / 2)
    /// Arm 9's environmental chamber, the white room: 2.4 m each way, its
    /// floor 1.28 m below level 320 at the CM's hatch sill (Xa 1046, 315.8
    /// ft above the deck; derived, M; size estimate, L).
    static let chamber = (depth: 2.4, height: 2.4, floor: -1.28)
    /// The truss's depth at arm `a`'s tip. Arm 9's tapers to its room's
    /// floor, so that it clears the CM's shoulder below the hatch, which the
    /// 2.0 m of the others would reach (derived, L).
    static func tipDepth(_ a: SwingArm) -> Double { a.number == 9 ? -chamber.floor : armDepth.tip }
    /// Retracted, an arm lies folded against the tower's face, swung 90°
    /// east about the hinge at its east edge (estimate, L; consistent with
    /// FER-503 Table 11-1), in the `armWidth` in front of the face that the
    /// LUT leaves clear (`flareLegsX`).
    public static let armRetractedAngle = 90 * degree
    /// Arm 9's park position, 12° from the spacecraft, about 3 ft from it
    /// (A8PK, A11PK, H).
    public static let accessArmParkAngle = 12 * degree

    /// Hinge (pivot) of arm `a` in the site frame: on the tower's face at
    /// the arm's east edge, at its walkway.
    static func hinge(_ a: SwingArm) -> Vec3 {
        Vec3(towerFaceX, a.offset - armWidth / 2, a.height)
    }

    /// Length of arm `a` from the tower's face to its carrier's end, whose
    /// nearer corner touches the vehicle where it is widest over the
    /// carrier's height, with the truss's tip clear of it over the tip's
    /// depth; arm 9's to the white room's tower side, the room centred on
    /// the hatch (derived from the drawn vehicle, L-M). Where an item off
    /// the vehicle's axis (`vehicleItems`) stands further out in front of
    /// the carrier or the truss's tip, the arm stops on it.
    public static func armLength(_ a: SwingArm) -> Double {
        if a.number == 9 { return towerFaceX - chamber.depth / 2 }
        let north = Vec3(1, 0, 0), tip = (a.height - tipDepth(a))...a.height
        let carrierItems = vehicleItems.reach(towards: north, across: span(a.offset, carrier.side),
                                              heights: (a.height + carrierHeights.low)...(a.height + carrierHeights.high))
        let carrierX = max(reach(a.vehicleRadius, nearSide(a.offset, carrier.side)), carrierItems ?? -.infinity)
        let trussRadius = vehicleOutline.largestRadius(from: tip.lowerBound, to: tip.upperBound)
        let trussItems = vehicleItems.reach(towards: north, across: span(a.offset, armWidth), heights: tip)
        let trussX = max(reach(trussRadius, nearSide(a.offset, armWidth)), trussItems ?? -.infinity) - carrier.length
        return towerFaceX - max(carrierX, trussX)
    }

    /// The site y (m) that something `width` wide centred `offset` off the
    /// x axis spans.
    static func span(_ offset: Double, _ width: Double) -> ClosedRange<Double> {
        (offset - width / 2)...(offset + width / 2)
    }

    /// The x (m) at which an upright edge `y` off the site's x axis meets a
    /// circle of radius `r` about the vehicle's axis.
    static func reach(_ r: Double, _ y: Double) -> Double { max(r * r - y * y, 0).squareRoot() }

    /// Distance from the x axis (m) of the nearer side of something `width`
    /// wide centred `offset` off it.
    static func nearSide(_ offset: Double, _ width: Double) -> Double { max(abs(offset) - width / 2, 0) }

    // MARK: Hold-down arms (datasheet §6)

    /// Four, at Positions I-IV (M503 Fig. 8-7, H): vehicle azimuth θ from
    /// Position I (east) towards Position II (north).
    static let holdDownAzimuths = [0.0, 90, 180, 270]
    /// Head centre under the post, on the lower thrust ring at the skin,
    /// 198 in from the axis (M503 p. 4-1, Fig. 8-7; L-M).
    static let holdDownHeadRadius = 198 * inch
    /// Base 117 by 76 in, 125 in overall, the head 32 in across, cantilevered
    /// 23.75 in ahead of the base (Phillips and Tolson Fig. 10, H).
    static let holdDownBase = (length: 117 * inch, width: 76 * inch)
    static let holdDownOverall = 125 * inch
    static let holdDownHeadDiameter = 32 * inch
    static let holdDownCantilever = 23.75 * inch
    /// The upper link's main pin 10 in behind the base's front and 104 in
    /// up (scaled off Phillips and Tolson Fig. 11, L); at release its jaw
    /// swings up and back through about 90° (ibid. p. 336, H).
    static let holdDownPin = (back: 10 * inch, up: 104 * inch)
    public static let holdDownReleaseAngle = 90 * degree
    /// The linkage collapses within 0.2 s of release (estimate, L: the
    /// separators act in 0.13-0.18 s, ibid. p. 340).
    static let holdDownSwingTime = 0.2

    // MARK: Tail service masts (datasheet §7)

    /// TSM 1-2 13° from Position I towards II; TSM 3-2 and 3-4 12° either
    /// side of Position III (scaled off M503 Fig. 8-7, M).
    static let tailMasts: [(name: String, azimuth: Double, retract: Double)] = [
        ("1-2", 13, 2.62), ("3-2", 168, 2.77), ("3-4", 192, 2.54),
    ]
    /// The mast's tower centred 10.4 m from the axis (scaled off M503 Fig.
    /// 8-7 against the 45 ft opening, M); 2.7 m square at the deck, 0.6 of
    /// that at its 8 m top, with a 1.4 m hood (estimates from the figure's
    /// drawing, L).
    static let tailMastRadius = 10.4
    static let tailMastBase = 2.7
    static let tailMastTop = 8.0
    static let tailMastHood = 1.4
    /// The boom from the hood to the S-IC's tail plate, about 4.76 m above
    /// the deck at the skin (STA 200 on the thrust structure, estimate, L).
    static let tailMastPivot = (radius: 9.5, height: 8.4)
    static let tailPlate = (radius: 5.3, height: 4.76)
    /// The boom swings up and away into the hood (Moonport p. 287): 140°
    /// (estimate, L).
    public static let tailMastRetractAngle = 140 * degree

    // MARK: Pad (datasheet §8)

    /// The hardstand, 390 by 325 ft (NASA photo caption, 1965-11-02, M),
    /// its long side north-south along the pad's axis (M503 p. 8-8, H),
    /// centred on the vehicle (estimate, L).
    static let hardstandHalfLength = 390 * foot / 2
    static let hardstandHalfWidth = 325 * foot / 2
    /// The fill's sides slope 2:1 (estimate, L).
    static let fillSlope = 2.0
    /// The flame trench: 58 ft wide, 450 ft long, north-south through the
    /// pad (M503 p. 8-8, H), open to grade at its ends, centred on the
    /// vehicle (estimate, L).
    public static let trenchHalfWidth = 58 * foot / 2
    public static let trenchHalfLength = 450 * foot / 2
    /// The deflector: a two-way wedge 12 m high, 15 m wide and 23 m long
    /// (Moonport p. 537, M), on the trench floor under the vehicle.
    static let deflector = (height: 12.0, width: 15.0, length: 23.0, ridge: 1.0)
    /// The ramp from the south at 5 percent (A8PK, H), two 40 ft lanes
    /// (the crawlerway's, Moonport p. 537, H) either side of the trench
    /// (estimate, L).
    static let rampGrade = 0.05
    static let rampLane = 40 * foot

    // MARK: Materials

    static let latticeColor = (0.30, 0.07, 0.04)    // red oxide, colour photos (L)
    static let steelColor = (0.32, 0.32, 0.32)
    static let concreteColor = (0.50, 0.49, 0.46)
    static let refractoryColor = (0.28, 0.27, 0.26)
}

extension MaterialKey {
    // The LC-39A set's finishes (`LC39A`).
    /// The LUT, its arms and crane: painted open steel lattice, drawn as
    /// prisms with lattice relief.
    public static let lc39aLattice: MaterialKey = "lc39a.lattice"
    /// The ML base, pedestals, hold-down arms and tail service masts.
    public static let lc39aSteel: MaterialKey = "lc39a.steel"
    /// The hardstand, the pad's fill and the ramp.
    public static let lc39aConcrete: MaterialKey = "lc39a.concrete"
    /// The trench floor and the deflector's refractory concrete.
    public static let lc39aRefractory: MaterialKey = "lc39a.refractory"
}

// MARK: - Vehicle outline

extension LC39A {
    /// Whether `s`, a shape of `part`, is a frustum or a surface of
    /// revolution about `vessel`'s axis: the x axis of the frame it was
    /// built in, through `structureOrigin`.
    static func turnsAboutAxis(_ s: VisualShape, of part: VesselPart, in vessel: Vessel) -> Bool {
        switch s.kind {
        case .frustum, .revolution:
            let o = part.offset + s.origin - vessel.structureOrigin
            let a = s.axis
            return abs(o.y) < 1e-6 && abs(o.z) < 1e-6 && a.y * a.y + a.z * a.z < 1e-18 * a.lengthSquared
        default:
            return false
        }
    }

    /// The drawn Saturn V's outline: its radius about its axis by height
    /// above the ML deck (m). It holds every shape of a dressed stack that
    /// turns about the vehicle's axis (`turnsAboutAxis`): the stages' skins,
    /// the SLA, the CM and the boost protective cover over it, the centre
    /// engines, as the straight segments between their profile points that
    /// the renderer draws. A shape swept through part of a turn counts as a
    /// whole one (the SLA's four panels make its cone). The shapes off the
    /// axis or not turning about it (fins, engine fairings, tunnels, plates
    /// and doors, APS modules, RCS quads, the LES tower's legs) are not in
    /// it but in `VehicleItems`. The swing arms reach it (datasheet §4.1).
    public struct VehicleOutline {
        struct Segment {
            var z0: Double, r0: Double, z1: Double, r1: Double

            /// The radius at height `z`, z0 ≤ z ≤ z1; a step's larger one.
            func radius(at z: Double) -> Double {
                if z1 - z0 < 1e-12 { return max(r0, r1) }
                return r0 + (r1 - r0) * (z - z0) / (z1 - z0)
            }
        }

        var segments: [Segment] = []

        /// The outline of `vessel` standing with its base `deckAboveBase`
        /// below the deck, as the core places it on the pad.
        public init(_ vessel: Vessel, deckAboveBase: Double) {
            // A site z is the vessel-frame x plus `base`: the vessel's base,
            // x = -baseHeight, is `deckAboveBase` below the deck.
            let base = vessel.baseHeight - deckAboveBase
            for part in vessel.parts {
                for s in part.shapes where LC39A.turnsAboutAxis(s, of: part, in: vessel) {
                    let z = part.offset.x + s.origin.x + base, k: Double = s.axis.x > 0 ? 1 : -1
                    switch s.kind {
                    case let .frustum(r0, r1):
                        add(z, r0, z + k * s.length, r1)
                    case let .revolution(profile, _, _):
                        for (p, q) in zip(profile, profile.dropFirst()) { add(z + k * p.x, p.r, z + k * q.x, q.r) }
                    default:
                        continue
                    }
                }
            }
        }

        mutating func add(_ za: Double, _ ra: Double, _ zb: Double, _ rb: Double) {
            segments.append(za <= zb ? Segment(z0: za, r0: ra, z1: zb, r1: rb) : Segment(z0: zb, r0: rb, z1: za, r1: ra))
        }

        /// The radius (m) at height `z` above the deck: the largest shape's
        /// there, 0 above and below the vehicle.
        public func radius(at z: Double) -> Double { largestRadius(from: z, to: z) }

        /// The largest radius (m) between heights `z0` and `z1` above the
        /// deck. Each segment is straight, so its largest is at an end.
        public func largestRadius(from z0: Double, to z1: Double) -> Double {
            var r = 0.0
            for s in segments where s.z1 >= z0 && s.z0 <= z1 {
                r = max(r, s.radius(at: max(z0, s.z0)), s.radius(at: min(z1, s.z1)))
            }
            return r
        }
    }

    /// The drawn Saturn V's other shapes, those `VehicleOutline` leaves out
    /// (fins, engine fairings, tunnels, umbilical plates and doors, APS
    /// modules, RCS quads, the LES tower's legs and motors), as the
    /// triangles the renderer draws, in the site frame: the vehicle standing
    /// where the core places it, Position II towards the tower (+x) and
    /// Position I east (-y). The swing arms stand off them too: a carrier
    /// that would sink into one stops on it (datasheet §4.1).
    public struct VehicleItems {
        struct Item {
            var low: Vec3, high: Vec3
            var triangles: [(Vec3, Vec3, Vec3)]
        }

        var items: [Item] = []

        /// The items of `vessel` standing with its base `deckAboveBase`
        /// below the deck, as the core places it on the pad.
        public init(_ vessel: Vessel, deckAboveBase: Double) {
            let base = vessel.baseHeight - deckAboveBase, axis = vessel.structureOrigin
            // Vessel axes to site axes: x (nose) up, -y (Position II)
            // forward, +z (Position I) east, which is -y.
            func site(_ p: Vec3) -> Vec3 { Vec3(-(p.y - axis.y), -(p.z - axis.z), p.x + base) }
            for part in vessel.parts {
                for s in part.shapes where !LC39A.turnsAboutAxis(s, of: part, in: vessel) {
                    let m = s.mesh(offset: part.offset)
                    let p = m.vertices.map { site($0.position) }
                    guard let first = p.first else { continue }
                    var low = first, high = first
                    for q in p {
                        low = Vec3(min(low.x, q.x), min(low.y, q.y), min(low.z, q.z))
                        high = Vec3(max(high.x, q.x), max(high.y, q.y), max(high.z, q.z))
                    }
                    let triangles = stride(from: 0, to: m.indices.count - 2, by: 3).map { i in
                        (p[Int(m.indices[i])], p[Int(m.indices[i + 1])], p[Int(m.indices[i + 2])])
                    }
                    items.append(Item(low: low, high: high, triangles: triangles))
                }
            }
        }

        /// How far the items reach horizontally towards `d` (a horizontal
        /// unit vector, site frame) within `across`, along up × d, and
        /// between `heights` above the deck: the largest p·d of their
        /// surfaces there (m); nil when none is there.
        public func reach(towards d: Vec3, across: ClosedRange<Double>, heights: ClosedRange<Double>) -> Double? {
            let e = Vec3(0, 0, 1).cross(d)
            var best: Double?
            for item in items {
                guard item.low.z <= heights.upperBound, item.high.z >= heights.lowerBound else { continue }
                // The item's box across d: its corners' least and largest p·e.
                let xs = [item.low.x, item.high.x], ys = [item.low.y, item.high.y]
                let spread = xs.flatMap { x in ys.map { y in Vec3(x, y, 0).dot(e) } }
                guard let lo = spread.min(), let hi = spread.max(), lo <= across.upperBound,
                      hi >= across.lowerBound else { continue }
                for t in item.triangles {
                    var polygon = [t.0, t.1, t.2]
                    polygon = Self.clip(polygon) { $0.dot(e) - across.lowerBound }
                    polygon = Self.clip(polygon) { across.upperBound - $0.dot(e) }
                    polygon = Self.clip(polygon) { $0.z - heights.lowerBound }
                    polygon = Self.clip(polygon) { heights.upperBound - $0.z }
                    for q in polygon { best = max(best ?? -.infinity, q.dot(d)) }
                }
            }
            return best
        }

        /// The part of `polygon` where `inside` is not negative.
        static func clip(_ polygon: [Vec3], _ inside: (Vec3) -> Double) -> [Vec3] {
            var out: [Vec3] = []
            for (i, p) in polygon.enumerated() {
                let q = polygon[(i + 1) % polygon.count]
                let fp = inside(p), fq = inside(q)
                if fp >= 0 { out.append(p) }
                if (fp >= 0) != (fq >= 0) { out.append(p + (q - p) * (fp / (fp - fq))) }
            }
            return out
        }
    }

    /// The vehicle the arms reach: the core's dressed Saturn V, its base
    /// where the core places it, `deckAboveVehicleBase` below the deck.
    /// Apollo 8's stack has the same outline.
    public static let vehicleOutline = VehicleOutline(VesselLibrary.saturnV(), deckAboveBase: deckAboveVehicleBase)
    /// That vehicle's other shapes, off its axis or not turning about it.
    public static let vehicleItems = VehicleItems(VesselLibrary.saturnV(), deckAboveBase: deckAboveVehicleBase)
}

// MARK: - Countdown

extension LC39A {
    /// When things move: range time (s from range zero, T-0) of a launch's
    /// events, from its Flight Evaluation Report and press kit.
    public struct Countdown {
        public var name: String
        public var rangeZero: Epoch
        /// All hold-down arms released.
        public var holdDownRelease: Double
        public var firstMotion: Double
        /// Arm 9 swings to its 12° park position, and is fully retracted.
        public var accessArmPark: Double
        public var accessArmRetracted: Double
        /// Arm 3, "retracted early in the count".
        public var sIIAftArmRetracted: Double
        /// Arm 1's retract command, its carrier's withdrawal time and its
        /// total time to the safe angle.
        public var sICIntertankCommand: Double
        public var sICIntertankWithdrawal: Double
        public var sICIntertankSafeAngle: Double
        /// Arm 2's retract command.
        public var sICForwardCommand: Double

        /// Range time (s) at `epoch`.
        public func rangeTime(at epoch: Epoch) -> Double { epoch - rangeZero }

        /// The primary liftoff switches on the hold-down arms close at about
        /// an inch of rise (M503 p. 8-8: 3/4 in; FER-503 §3.6: "1-inch
        /// liftoff"), 0.16 s after first motion: about 1 m of rise in the
        /// first second (FER-503 Fig. 11-1), so 2 m/s² (derived, M). The
        /// in-flight arms and the tail service masts start then.
        public var liftoffSwitch: Double { firstMotion + 0.16 }

        /// Apollo 8: range zero 1968-12-21 12:51:00 UTC (FER-503 Table 2-2:
        /// 7:51:00 EST); hold-down release 0.27 s, first motion 0.33 s; arm 1
        /// withdrew in 6.14 s and reached its safe angle 11.1 s after its
        /// command, 2.69 s before arm 2's at T-16.2 s, so its command was at
        /// T-30.0 s (FER-503 §3.6, H; A8PK: "a third is released at T-30
        /// seconds"); arm 9 parked at about T-42 min and fully retracted at
        /// T-5 min (A8PK, H).
        public static let apollo8 = Countdown(
            name: "Apollo 8", rangeZero: Epoch(utcYear: 1968, month: 12, day: 21, hour: 12, minute: 51),
            holdDownRelease: 0.27, firstMotion: 0.33, accessArmPark: -42 * 60, accessArmRetracted: -5 * 60,
            sIIAftArmRetracted: -3600, sICIntertankCommand: -30.0, sICIntertankWithdrawal: 6.14,
            sICIntertankSafeAngle: 11.1, sICForwardCommand: -16.2)

        /// Apollo 11: range zero and first motion the core's
        /// (`VesselLibrary.apollo11RangeZero`, `apollo11FirstMotion`); the
        /// hold-down arms released at 0.3 s; arm 1 withdrew in 5.06 s and
        /// reached its safe angle in 9.9 s, 3.9 s before arm 2's command at
        /// T-16.2 s (FER-506 §3.6, H); arm 9 parked at T-43 min and fully
        /// retracted at T-5 min (A11PK, H).
        public static let apollo11 = Countdown(
            name: "Apollo 11", rangeZero: VesselLibrary.apollo11RangeZero, holdDownRelease: 0.30,
            firstMotion: VesselLibrary.apollo11FirstMotion - VesselLibrary.apollo11RangeZero,
            accessArmPark: -43 * 60, accessArmRetracted: -5 * 60, sIIAftArmRetracted: -3600,
            sICIntertankCommand: -30.0, sICIntertankWithdrawal: 5.06, sICIntertankSafeAngle: 9.9,
            sICForwardCommand: -16.2)
    }

    /// One swing of a moving element: from `from` to `to` (rad) between
    /// range times `start` and `end`, easing in and out.
    public struct Swing: Equatable {
        public var start: Double
        public var end: Double
        public var from: Double
        public var to: Double

        public init(start: Double, end: Double, from: Double, to: Double) {
            self.start = start
            self.end = end
            self.from = from
            self.to = to
        }

        /// The angle (rad) at range time `t`, held before and after.
        public func angle(at t: Double) -> Double {
            if t <= start { return from }
            if t >= end { return to }
            let u = (t - start) / (end - start)
            let s = u * u * (3 - 2 * u)
            return from + (to - from) * s
        }
    }

    /// Arm 9 moves at the rate it extends from park, 12° in 12 s (M503
    /// Fig. 8-8, H), so its full retraction from park takes 78 s (derived,
    /// L).
    static let accessArmRate = 1 * degree

    /// Arm 2's carrier withdraws for about 3 s before the arm swings, like
    /// arm 1's when dry (FER-506 §3.6.2: "approximately 3 seconds";
    /// estimate, L).
    static let sICForwardWithdrawal = 3.0

    /// The swings of arm `number` in countdown `c`, in order.
    public static func armSwings(_ number: Int, _ c: Countdown) -> [Swing] {
        let arm = swingArms[number - 1], out = armRetractedAngle
        switch number {
        case 1:
            let start = c.sICIntertankCommand + c.sICIntertankWithdrawal
            return [Swing(start: start, end: c.sICIntertankCommand + c.sICIntertankSafeAngle, from: 0, to: out)]
        case 2:
            let start = c.sICForwardCommand + sICForwardWithdrawal
            return [Swing(start: start, end: c.sICForwardCommand + arm.retractTime, from: 0, to: out)]
        case 3:
            return [Swing(start: c.sIIAftArmRetracted - arm.retractTime, end: c.sIIAftArmRetracted, from: 0, to: out)]
        case 9:
            let park = accessArmParkAngle
            let parkEnd = c.accessArmPark + park / accessArmRate
            let fullStart = c.accessArmRetracted - (out - park) / accessArmRate
            return [Swing(start: c.accessArmPark, end: parkEnd, from: 0, to: park),
                    Swing(start: fullStart, end: c.accessArmRetracted, from: park, to: out)]
        default:
            // In-flight: the carrier's ejection starts its withdrawal and
            // the arm's swing together (M503 p. 8-8).
            let start = c.liftoffSwitch
            return [Swing(start: start, end: start + arm.retractTime, from: 0, to: out)]
        }
    }
}

// MARK: - Elements

extension LC39A {
    /// What drives an element.
    public enum Motion: Equatable {
        case fixed
        /// Swing arm 1-9.
        case swingArm(Int)
        /// The hold-down arm at Position 1-4 (I-IV): its upper link.
        case holdDownArm(Int)
        /// Tail service mast 0-2 (1-2, 3-2, 3-4): its boom.
        case tailServiceMast(Int)
    }

    /// A rigid piece of the set. Its shapes are in its own frame: the
    /// site's axes, with the origin at `pivot`; `transform(at:_:)` places
    /// it in the site frame.
    public struct Element {
        public var name: String
        public var motion: Motion
        public var shapes: [VisualShape]
        /// The element's origin in the site frame (m): its hinge if it moves.
        public var pivot: Vec3
        /// The hinge's axis (site frame, unit); positive angles retract.
        public var axis: Vec3

        /// The swings that move it in countdown `c` (none for a fixed one).
        public func swings(_ c: Countdown) -> [Swing] {
            switch motion {
            case .fixed:
                return []
            case let .swingArm(n):
                return LC39A.armSwings(n, c)
            case .holdDownArm:
                let t = c.holdDownRelease
                return [Swing(start: t, end: t + LC39A.holdDownSwingTime, from: 0, to: LC39A.holdDownReleaseAngle)]
            case let .tailServiceMast(i):
                let t = c.liftoffSwitch
                return [Swing(start: t, end: t + LC39A.tailMasts[i].retract, from: 0, to: LC39A.tailMastRetractAngle)]
            }
        }

        /// Its angle (rad) about `axis` at range time `t`.
        public func angle(at t: Double, _ c: Countdown) -> Double {
            var a = 0.0
            for s in swings(c) where t > s.start { a = s.angle(at: t) }
            return a
        }

        /// Site-frame placement at range time `t`: a point p of the element
        /// is at `rotation * p + translation`.
        public func transform(at t: Double, _ c: Countdown) -> (rotation: Mat3, translation: Vec3) {
            let a = angle(at: t, c)
            let r = a == 0 ? Mat3.identity : Quat(axis: axis, angle: a).matrix
            return (r, pivot)
        }
    }

    /// The whole set, built once.
    public static let elements: [Element] = {
        var out = [Element(name: "Pad", motion: .fixed, shapes: padShapes(), pivot: .zero, axis: .unitZ),
                   Element(name: "ML base", motion: .fixed, shapes: baseShapes(), pivot: .zero, axis: .unitZ),
                   Element(name: "LUT", motion: .fixed, shapes: towerShapes(), pivot: .zero, axis: .unitZ),
                   Element(name: "Hammerhead crane", motion: .fixed, shapes: craneShapes(),
                           pivot: Vec3(towerCentreX, 0, towerTop), axis: .unitZ)]
        for a in swingArms {
            out.append(Element(name: "Swing arm \(a.number)", motion: .swingArm(a.number), shapes: armShapes(a),
                               pivot: hinge(a), axis: .unitZ))
        }
        for (i, theta) in holdDownAzimuths.enumerated() {
            let (r, t) = radialAndTangent(theta)
            let base = holdDownHeadRadius + holdDownCantilever
            out.append(Element(name: "Hold-down arm \(i + 1)", motion: .fixed, shapes: holdDownBaseShapes(theta),
                               pivot: .zero, axis: .unitZ))
            let pin = r * (base + holdDownPin.back) + Vec3(0, 0, holdDownPin.up)
            out.append(Element(name: "Hold-down arm \(i + 1) link", motion: .holdDownArm(i + 1),
                               shapes: holdDownLinkShapes(theta), pivot: pin, axis: t))
        }
        for (i, m) in tailMasts.enumerated() {
            let (r, t) = radialAndTangent(m.azimuth)
            out.append(Element(name: "Tail service mast \(m.name)", motion: .fixed, shapes: tailMastShapes(m.azimuth),
                               pivot: .zero, axis: .unitZ))
            let pivot = r * tailMastPivot.radius + Vec3(0, 0, tailMastPivot.height)
            out.append(Element(name: "Tail service mast \(m.name) boom", motion: .tailServiceMast(i),
                               shapes: tailBoomShapes(m.azimuth), pivot: pivot, axis: t))
        }
        return out
    }()

    /// The element called `name`.
    public static func element(_ name: String) -> Element? { elements.first { $0.name == name } }

    /// Outward unit vector at vehicle azimuth `theta` (deg, from Position I,
    /// east, towards Position II, north) and the horizontal tangent z × r:
    /// positive turns about it lift what points back at the vehicle.
    static func radialAndTangent(_ theta: Double) -> (Vec3, Vec3) {
        let a = theta * degree
        let r = Vec3(sin(a), -cos(a), 0)
        return (r, Vec3.unitZ.cross(r))
    }
}

// MARK: - Attachments

extension LC39A {
    /// Where P4's exhaust leaves the set, site frame: the ML's opening (down
    /// into the pad), the deflector's ridge (the plume splits there) and the
    /// flame trench's exits at grade, north and south. `radius` is a half
    /// width: the opening and the trench are rectangles. K0's kinds have no
    /// trench exit, so all four are vents.
    public static let attachments: [VisualAttachment] = {
        let floor = gradeHeight, mid = floor + (hardstandHeight - floor) / 2
        let ridge = floor + deflector.height
        return [
            VisualAttachment(name: "ML exhaust opening", kind: .vent, position: .zero, direction: -.unitZ,
                             radius: openingHalf),
            VisualAttachment(name: "Flame deflector ridge", kind: .vent, position: Vec3(0, 0, ridge),
                             direction: -.unitZ, radius: deflector.width / 2),
            VisualAttachment(name: "Flame trench north exit", kind: .vent, position: Vec3(trenchHalfLength, 0, mid),
                             direction: .unitX, radius: trenchHalfWidth),
            VisualAttachment(name: "Flame trench south exit", kind: .vent, position: Vec3(-trenchHalfLength, 0, mid),
                             direction: -.unitX, radius: trenchHalfWidth),
        ]
    }()
}

// MARK: - Geometry

extension LC39A {
    static func dressed(_ s: VisualShape, _ m: MaterialKey) -> VisualShape {
        var s = s
        s.material = m
        return s
    }

    static func color(_ m: MaterialKey) -> (Double, Double, Double) {
        switch m {
        case .lc39aLattice: latticeColor
        case .lc39aConcrete: concreteColor
        case .lc39aRefractory: refractoryColor
        default: steelColor
        }
    }

    /// A box upright in site axes: `sx` along x, `sy` along y, from `z0` to
    /// `z1`, centred on (x, y).
    static func block(x: Double, y: Double, z0: Double, z1: Double, sx: Double, sy: Double,
                      _ m: MaterialKey) -> VisualShape {
        let s = VisualShape.box(from: Vec3(x, y, z0), length: z1 - z0, width: sx, height: sy, axis: .unitZ,
                                reference: .unitX, color: color(m))
        return dressed(s, m)
    }

    /// A box from `a` to `b`, `across` wide horizontally and `up` high,
    /// centred on the line.
    static func beam(_ a: Vec3, _ b: Vec3, across: Double, up: Double, _ m: MaterialKey) -> VisualShape {
        let d = b - a
        let vertical = abs(d.normalized.z) > 0.999
        let s = VisualShape.box(from: a, length: d.length, width: vertical ? across : up, height: vertical ? up : across,
                                axis: d, reference: vertical ? .unitX : .unitZ, color: color(m))
        return dressed(s, m)
    }

    /// An upright column of `diameter` from `z0` to `z1` at (x, y).
    static func column(x: Double, y: Double, z0: Double, z1: Double, diameter: Double) -> VisualShape {
        let s = VisualShape.frustum(from: Vec3(x, y, z0), length: z1 - z0, baseRadius: diameter / 2,
                                    topRadius: diameter / 2, axis: .unitZ, color: steelColor)
        return dressed(s, .lc39aSteel)
    }

    // MARK: Pad

    static func padShapes() -> [VisualShape] {
        var out: [VisualShape] = []
        let bottom = footingHeight
        let height = hardstandHeight - bottom
        let top = hardstandHalfWidth - trenchHalfWidth
        let toe = top + fillSlope * height
        let section = [VisualShape.SectionPoint(0, 0, crease: true), VisualShape.SectionPoint(height, 0, crease: true),
                       VisualShape.SectionPoint(height, top, crease: true), VisualShape.SectionPoint(0, toe, crease: true)]
        // Each half of the pad beside the trench: a prism along the trench,
        // its section across it (height up, outward from the trench wall),
        // flat over the hardstand and sloping to the ground at the trench's
        // ends. Section a is up (`reference` z), b outward (axis x z).
        let run = trenchHalfLength - hardstandHalfLength
        let stations = [VisualShape.PrismStation(0, width: 0, height: 1),
                        VisualShape.PrismStation(run),
                        VisualShape.PrismStation(run + 2 * hardstandHalfLength),
                        VisualShape.PrismStation(2 * trenchHalfLength, width: 0, height: 1)]
        for side in [-1.0, 1.0] {
            // West half (side +1): axis -x, so b = (-x) × z = +y; east half: axis +x.
            let axis = Vec3(-side, 0, 0)
            let origin = Vec3(side * trenchHalfLength, side * trenchHalfWidth, bottom)
            var s = VisualShape.prism(section, from: origin, axis: axis, reference: .unitZ, stations: stations,
                                      color: concreteColor)
            s.material = .lc39aConcrete
            out.append(s)
        }
        // The trench floor at grade, down to the footing.
        let length = 2 * trenchHalfLength
        out.append(block(x: 0, y: 0, z0: bottom, z1: gradeHeight, sx: length, sy: 2 * trenchHalfWidth, .lc39aRefractory))
        // The deflector: a wedge across the trench, its ridge east-west.
        let h = deflector.height, half = deflector.length / 2, r = deflector.ridge / 2
        let wedge = [VisualShape.SectionPoint(-half, 0, crease: true), VisualShape.SectionPoint(half, 0, crease: true),
                     VisualShape.SectionPoint(r, h, crease: true), VisualShape.SectionPoint(-r, h, crease: true)]
        var d = VisualShape.prism(wedge, from: Vec3(0, deflector.width / 2, gradeHeight), length: deflector.width,
                                  axis: -.unitY, reference: .unitX, color: refractoryColor)
        d.material = .lc39aRefractory
        out.append(d)
        // The ramp from the south: two lanes either side of the trench,
        // falling at 5 percent from the hardstand's edge to the footing.
        let rampLength = height / rampGrade
        let lane = [VisualShape.SectionPoint(0, 0, crease: true), VisualShape.SectionPoint(height, 0, crease: true),
                    VisualShape.SectionPoint(height, rampLane, crease: true), VisualShape.SectionPoint(0, rampLane, crease: true)]
        for side in [-1.0, 1.0] {
            // Axis -x; b = (-x) × z = +y, so the east lane's section runs
            // from its outer edge.
            let y = side > 0 ? trenchHalfWidth : -trenchHalfWidth - rampLane
            let stations = [VisualShape.PrismStation(0), VisualShape.PrismStation(rampLength, width: 0, height: 1)]
            var s = VisualShape.prism(lane, from: Vec3(-hardstandHalfLength, y, bottom), axis: -.unitX,
                                      reference: .unitZ, stations: stations, color: concreteColor)
            s.material = .lc39aConcrete
            out.append(s)
        }
        return out
    }

    // MARK: ML base

    static func baseShapes() -> [VisualShape] {
        var out: [VisualShape] = []
        let z0 = -baseDepth, o = openingHalf, w = baseHalfWidth
        // Four blocks round the exhaust opening.
        let north = baseNorth - o, south = -o - baseSouth
        out.append(block(x: (baseNorth + o) / 2, y: 0, z0: z0, z1: 0, sx: north, sy: 2 * w, .lc39aSteel))
        out.append(block(x: (baseSouth - o) / 2, y: 0, z0: z0, z1: 0, sx: south, sy: 2 * w, .lc39aSteel))
        for side in [-1.0, 1.0] {
            out.append(block(x: 0, y: side * (w + o) / 2, z0: z0, z1: 0, sx: 2 * o, sy: w - o, .lc39aSteel))
        }
        // Six pedestals on the hardstand and four extensible columns.
        for x in mountLinesX {
            for side in [-1.0, 1.0] {
                out.append(column(x: x, y: side * mountLineY, z0: hardstandHeight, z1: z0, diameter: pedestalDiameter))
            }
        }
        for x in [-extensibleColumnX, extensibleColumnX] {
            for side in [-1.0, 1.0] {
                out.append(column(x: x, y: side * extensibleColumnY, z0: hardstandHeight, z1: z0,
                                  diameter: pedestalDiameter))
            }
        }
        // Under each hold-down arm, where its base overhangs the opening, a
        // ledge (estimate, L).
        let inner = holdDownHeadRadius + holdDownCantilever
        for theta in holdDownAzimuths {
            let (r, _) = radialAndTangent(theta)
            let c = r * ((inner + o) / 2)
            let s = beam(c - r * ((o - inner) / 2) + Vec3(0, 0, -0.5), c + r * ((o - inner) / 2) + Vec3(0, 0, -0.5),
                         across: holdDownBase.width, up: 1, .lc39aSteel)
            out.append(s)
        }
        return out
    }

    // MARK: LUT

    static func towerShapes() -> [VisualShape] {
        var out: [VisualShape] = []
        let side = 2 * towerHalf
        out.append(block(x: towerCentreX, y: 0, z0: 0, z1: towerTop, sx: side, sy: side, .lc39aLattice))
        // The flared base: legs from the deck to the body's corners at the
        // flare's top (`flareLegsX`), and tie frames across them.
        for leg in flareLegsX {
            for s in [-1.0, 1.0] {
                let foot = Vec3(leg.foot, s * legFootHalfAcross, 0)
                let corner = Vec3(leg.top, s * towerHalf, flareTop)
                out.append(beam(foot, corner, across: legSection, up: legSection, .lc39aLattice))
            }
        }
        for z in flareTies {
            let f = z / flareTop
            let across = legFootHalfAcross + (towerHalf - legFootHalfAcross) * f
            for leg in flareLegsX {
                let x = leg.foot + (leg.top - leg.foot) * f
                out.append(beam(Vec3(x, -across, z), Vec3(x, across, z), across: 1, up: 1, .lc39aLattice))
            }
        }
        return out
    }

    // MARK: Crane

    /// In the crane's frame: its turntable on the tower's top, the jib out
    /// to its reach along `craneHeading`, the counter-jib behind.
    static func craneShapes() -> [VisualShape] {
        let a = craneHeading
        let d = Vec3(cos(a), -sin(a), 0)    // azimuth from north towards east; y is west
        let jibZ = craneTop - towerTop - jibDepth / 2
        let turntableTop = jibZ - jibDepth / 2
        return [
            block(x: 0, y: 0, z0: 0, z1: turntableTop, sx: turntableSide, sy: turntableSide, .lc39aLattice),
            beam(d * -counterJib + Vec3(0, 0, jibZ), d * craneReach + Vec3(0, 0, jibZ), across: jibWidth, up: jibDepth,
                 .lc39aLattice),
            beam(d * -counterJib + Vec3(0, 0, jibZ - jibDepth), d * (-counterJib + 3) + Vec3(0, 0, jibZ - jibDepth),
                 across: jibWidth, up: jibDepth, .lc39aSteel),
        ]
    }

    // MARK: Swing arms

    /// Arm `a` extended, in its frame: from the hinge south along -x, its
    /// walkway at z 0 and its truss below, its width west of the hinge.
    static func armShapes(_ a: SwingArm) -> [VisualShape] {
        var out: [VisualShape] = []
        let length = armLength(a)
        let isAccess = a.number == 9
        let truss = isAccess ? length : length - carrier.length
        let section = [VisualShape.SectionPoint(-armDepth.root, -armWidth / 2, crease: true),
                       VisualShape.SectionPoint(0, -armWidth / 2, crease: true),
                       VisualShape.SectionPoint(0, armWidth / 2, crease: true),
                       VisualShape.SectionPoint(-armDepth.root, armWidth / 2, crease: true)]
        let taper = tipDepth(a) / armDepth.root
        let stations = [VisualShape.PrismStation(0), VisualShape.PrismStation(truss, width: taper, height: 1)]
        // Axis -x, reference z: a is up, b = (-x) × z = +y, west.
        var s = VisualShape.prism(section, from: Vec3(0, armWidth / 2, 0), axis: -.unitX, reference: .unitZ,
                                  stations: stations, color: latticeColor)
        s.material = .lc39aLattice
        out.append(s)
        let tipCentre = Vec3(-truss, armWidth / 2, 0)
        if isAccess {
            let c = tipCentre + Vec3(-chamber.depth / 2, 0, 0)
            out.append(block(x: c.x, y: c.y, z0: chamber.floor, z1: chamber.floor + chamber.height, sx: chamber.depth,
                             sy: chamber.depth, .lc39aSteel))
        } else {
            out.append(block(x: tipCentre.x - carrier.length / 2, y: tipCentre.y, z0: carrierHeights.low,
                             z1: carrierHeights.high, sx: carrier.length, sy: carrier.side, .lc39aSteel))
        }
        return out
    }

    // MARK: Hold-down arms

    /// The arm's cast base at azimuth `theta`, site frame: a sloping body
    /// on its base plate, the head on a cantilever ahead of it.
    static func holdDownBaseShapes(_ theta: Double) -> [VisualShape] {
        let (r, t) = radialAndTangent(theta)
        let front = holdDownHeadRadius + holdDownCantilever
        let w = holdDownBase.width, len = holdDownBase.length
        let headTop = holdDownHeadHeight * inch
        let shoulder = headTop - 6 * inch
        // Section a along r (outward from the front face), b up; the prism
        // runs along -t, so b = (-t) × r = z.
        let body = [VisualShape.SectionPoint(0, 0, crease: true), VisualShape.SectionPoint(len, 0, crease: true),
                    VisualShape.SectionPoint(len, 8 * inch, crease: true),
                    VisualShape.SectionPoint(40 * inch, shoulder, crease: true),
                    VisualShape.SectionPoint(0, shoulder, crease: true)]
        var s = VisualShape.prism(body, from: r * front + t * (w / 2), length: w, axis: -t, reference: r,
                                  color: steelColor)
        s.material = .lc39aSteel
        let head = holdDownHeadDiameter
        let ledge = beam(r * (holdDownHeadRadius - head / 2) + Vec3(0, 0, shoulder - 6 * inch),
                         r * front + Vec3(0, 0, shoulder - 6 * inch), across: head, up: 12 * inch, .lc39aSteel)
        var cap = VisualShape.frustum(from: r * holdDownHeadRadius + Vec3(0, 0, shoulder), length: headTop - shoulder,
                                      baseRadius: head / 2, topRadius: head / 2, axis: .unitZ, color: steelColor)
        cap.material = .lc39aSteel
        return [s, ledge, cap]
    }

    /// The upper link and hood, in the link's frame (origin at the main pin,
    /// site axes): over the head towards the vehicle, latched.
    static func holdDownLinkShapes(_ theta: Double) -> [VisualShape] {
        let (r, _) = radialAndTangent(theta)
        let reach = holdDownPin.back + holdDownCantilever + holdDownHeadDiameter / 2
        let top = holdDownOverall - holdDownPin.up
        let z = top / 2
        return [beam(r * -reach + Vec3(0, 0, z), r * (40 * inch) + Vec3(0, 0, z), across: 30 * inch, up: top,
                     .lc39aSteel)]
    }

    // MARK: Tail service masts

    static func tailMastShapes(_ theta: Double) -> [VisualShape] {
        let (r, _) = radialAndTangent(theta)
        let c = r * tailMastRadius
        let square = [VisualShape.SectionPoint(-0.5, -0.5, crease: true), VisualShape.SectionPoint(0.5, -0.5, crease: true),
                      VisualShape.SectionPoint(0.5, 0.5, crease: true), VisualShape.SectionPoint(-0.5, 0.5, crease: true)]
        let b = tailMastBase
        let stations = [VisualShape.PrismStation(0, width: b, height: b),
                        VisualShape.PrismStation(tailMastTop, width: 0.6 * b, height: 0.6 * b)]
        var tower = VisualShape.prism(square, from: c, axis: .unitZ, reference: r, stations: stations, color: steelColor)
        tower.material = .lc39aLattice
        let hood = beam(c + Vec3(0, 0, tailMastTop), c + Vec3(0, 0, tailMastTop + tailMastHood), across: 0.6 * b,
                        up: 0.6 * b, .lc39aSteel)
        return [tower, hood]
    }

    /// The boom in its frame (origin at the pivot by the hood, site axes):
    /// down to the tail plate, its carrier at the end.
    static func tailBoomShapes(_ theta: Double) -> [VisualShape] {
        let (r, _) = radialAndTangent(theta)
        let plate = r * tailPlate.radius + Vec3(0, 0, tailPlate.height)
        let pivot = r * tailMastPivot.radius + Vec3(0, 0, tailMastPivot.height)
        let end = plate - pivot
        return [beam(.zero, end, across: 0.9, up: 0.9, .lc39aSteel),
                beam(end * 0.85, end, across: 1.3, up: 1.3, .lc39aSteel)]
    }
}
