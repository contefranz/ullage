import Foundation

/// Track P2's render settings: the ray-marched plumes' quality, their level
/// of detail, the "readable plumes" toggle (plan decision 36 and design
/// option 1) and the look-dev engines shots draw. P2 owns this file;
/// `RenderSettings` holds one.
public struct PlumeSettings: Codable, Equatable {
    /// Plumes at all: off, P2 draws nothing (no plume, impostor or nozzle
    /// glow) and writes no plume light, for shots and tests that need a
    /// plain frame. R2's vessel pass then lights from the emitters itself
    /// unless `ShadingSettings.plumeLights` is 0.
    public var enabled = true
    /// The plumes' tier (R7's tiers set it): impostors only, or a march of
    /// 16, 32 or 48 steps.
    public var quality = PlumeQuality.high
    /// Physical by default: a J-2, the SPS or an RCS jet in vacuum is
    /// nearly invisible, and the cue that an engine runs is the SPS
    /// extension's glow and the near-exit light. Readable restores M1.5's
    /// floor (decision 19): every firing engine glows at least 0.3 of a
    /// sunlit white surface in its family's colour.
    public var readable = false
    /// Where the look comes from: P1's plume model (`physical`), or M1.5's
    /// look table (`legacy`), the stub the switch-over was checked against.
    public var model = PlumeLookModel.physical
    /// The SPS extension's glow on its drawn bell.
    public var nozzleGlow = true
    /// The eddies' noise; off, the march draws `PlumeLook`'s field as the
    /// reference march does (tests).
    public var turbulence = true
    /// Level of detail by a cluster's size on screen, pixels across its
    /// longest extent: marched from `marchPixels`, an impostor from
    /// `impostorPixels`, nothing below (the vessel's far point carries it).
    public var marchPixels = 48.0
    public var impostorPixels = 6.0
    /// Attitude jets are impostors unless the camera is within this (m).
    public var jetMarchDistance = 20.0
    /// Look-dev: engines placed at the camera's target, drawn in place of
    /// the scene's (whose emitters are then ignored), the same every frame.
    public var testEngines: [PlumeTestEngine] = []

    /// The kerosene exhaust's soot at the exit over P2's photo fit (its
    /// optical depth across the exit, `PlumeLook.Optics.sootDepth` per soot
    /// index): 1 keeps P2's, which implies 0.39 % of the exhaust at the
    /// exit and 0.096 % past the afterburning. For decision 4's renders (look
    /// round 2); P4's trail takes the far field over with it.
    public var sootScale = 1.0
    /// Decision 4: the kerosene exhaust's soot at the nozzle exit, kg per
    /// kg (`KeroseneSoot.exit` by default, 22 g/kg), which P2's plume, P4's
    /// trail and LR4's launch cloud all read through
    /// `KeroseneSoot.surviving(pressure:exit:)`.
    public var sootExit = KeroseneSoot.exit

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, quality, readable, model, nozzleGlow, turbulence, marchPixels, impostorPixels, jetMarchDistance, testEngines,
             sootScale, sootExit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PlumeSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        quality = try c.decodeIfPresent(PlumeQuality.self, forKey: .quality) ?? d.quality
        readable = try c.decodeIfPresent(Bool.self, forKey: .readable) ?? d.readable
        model = try c.decodeIfPresent(PlumeLookModel.self, forKey: .model) ?? d.model
        nozzleGlow = try c.decodeIfPresent(Bool.self, forKey: .nozzleGlow) ?? d.nozzleGlow
        turbulence = try c.decodeIfPresent(Bool.self, forKey: .turbulence) ?? d.turbulence
        marchPixels = try c.decodeIfPresent(Double.self, forKey: .marchPixels) ?? d.marchPixels
        impostorPixels = try c.decodeIfPresent(Double.self, forKey: .impostorPixels) ?? d.impostorPixels
        jetMarchDistance = try c.decodeIfPresent(Double.self, forKey: .jetMarchDistance) ?? d.jetMarchDistance
        testEngines = try c.decodeIfPresent([PlumeTestEngine].self, forKey: .testEngines) ?? []
        sootScale = try c.decodeIfPresent(Double.self, forKey: .sootScale) ?? d.sootScale
        sootExit = try c.decodeIfPresent(Double.self, forKey: .sootExit) ?? d.sootExit
    }
}

/// The plume tiers (the design's quality presets).
public enum PlumeQuality: String, Codable, CaseIterable, Comparable {
    /// No plumes at all (tests that need a plain frame).
    case off
    /// Impostors only, reshaped by the plume model.
    case low
    case medium, high, ultra

    /// Steps of the ray march; 0 at Low and Off.
    public var steps: Int {
        switch self {
        case .off, .low: 0
        case .medium: 16
        case .high: 32
        case .ultra: 48
        }
    }

    public static func < (a: PlumeQuality, b: PlumeQuality) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// Where a plume's look comes from.
public enum PlumeLookModel: String, Codable, CaseIterable {
    /// P1's plume model through `PlumeLook`.
    case physical
    /// M1.5's look table (`PlumeLook.legacy`), drawn through the march.
    case legacy
}

/// A look-dev engine, or a cluster of them, placed in the camera target's
/// frame (`EffectTargetFrame`: metres east, north and up), firing into air
/// at `altitude` on US 1976 (or `pressure`, Pa, when given), at
/// `flowFraction` of its rated flow.
public struct PlumeTestEngine: Codable, Equatable {
    /// A family of `ApolloExhaust` by its table row ("F-1", "J-2", "SPS",
    /// "SM RCS", "S-IC retro", "Tower jettison"...).
    public var engine: String
    /// The exit's centre, m east, north and up of the target.
    public var position = [0.0, 0.0, 0.0]
    /// The exhaust's direction (east, north, up); down by default.
    public var axis = [0.0, 0.0, -1.0]
    /// Altitude on US 1976, m, or the ambient pressure, Pa (overrides it).
    public var altitude = 0.0
    public var pressure: Double?
    public var flowFraction = 1.0
    /// Engines in a ring of `ringRadius` m about the position, one more on
    /// the axis when `centre` (the S-IC's and S-II's five: 4, 4.9 m... ).
    public var ring = 0
    public var ringRadius = 0.0
    public var centre = true
    /// The air's velocity relative to the engine (east, north, up; m/s):
    /// the stream it fires into (the airspeed against the vehicle's
    /// motion, any wind); none by default.
    public var stream = [0.0, 0.0, 0.0]

    public init(engine: String, position: [Double] = [0, 0, 0], axis: [Double] = [0, 0, -1], altitude: Double = 0,
                pressure: Double? = nil, flowFraction: Double = 1, ring: Int = 0, ringRadius: Double = 0,
                centre: Bool = true, stream: [Double] = [0, 0, 0]) {
        self.engine = engine
        self.position = position
        self.axis = axis
        self.altitude = altitude
        self.pressure = pressure
        self.flowFraction = flowFraction
        self.ring = ring
        self.ringRadius = ringRadius
        self.centre = centre
        self.stream = stream
    }

    private enum CodingKeys: String, CodingKey {
        case engine, position, axis, altitude, pressure, flowFraction, ring, ringRadius, centre, stream
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decode(String.self, forKey: .engine)
        position = try c.decodeIfPresent([Double].self, forKey: .position) ?? [0, 0, 0]
        axis = try c.decodeIfPresent([Double].self, forKey: .axis) ?? [0, 0, -1]
        altitude = try c.decodeIfPresent(Double.self, forKey: .altitude) ?? 0
        pressure = try c.decodeIfPresent(Double.self, forKey: .pressure)
        flowFraction = try c.decodeIfPresent(Double.self, forKey: .flowFraction) ?? 1
        ring = try c.decodeIfPresent(Int.self, forKey: .ring) ?? 0
        ringRadius = try c.decodeIfPresent(Double.self, forKey: .ringRadius) ?? 0
        centre = try c.decodeIfPresent(Bool.self, forKey: .centre) ?? true
        stream = try c.decodeIfPresent([Double].self, forKey: .stream) ?? [0, 0, 0]
    }
}
