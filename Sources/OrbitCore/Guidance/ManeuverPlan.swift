import Foundation

/// A burn as the ground plans it and the computer loads it: the PAD of
/// docs/m2/design-flight-controls.md §3, which TRANSFER's and DEORBIT's SET
/// uplink into the computer's P30 and the crew may key by hand. It is a
/// value with the epoch of the state it was solved from, so a stale plan can
/// be told from a fresh one.
public struct ManeuverPlan: Equatable {
    /// The engine that flies it: the SPS through P40, the SM RCS through P41.
    public enum Engine: String, Equatable, Sendable {
        case sps = "SPS"
        case rcs = "RCS"
    }

    /// Where the plan came from.
    public enum Source: String, Equatable, Sendable {
        /// The DEORBIT page's planner.
        case deorbit = "DEORBIT"
        /// TRANSFER, the RTCC desk.
        case transfer = "RTCC"
        /// Keyed by the crew into P30.
        case keyed = "PAD"
    }

    /// The +X ullage before the burn: the SM RCS jets and for how long.
    public struct Ullage: Equatable, Sendable {
        public var jets: Int
        public var duration: Double
        public init(jets: Int, duration: Double) {
            self.jets = jets
            self.duration = duration
        }
    }

    /// The orbit a prediction gives: apoapsis and periapsis altitudes (m,
    /// radii less the body's equatorial radius; the apoapsis nil when the
    /// orbit is not bound), and the entry interface when it comes down
    /// through it.
    public struct Prediction: Equatable {
        public var apoapsisAltitude: Double?
        public var periapsisAltitude: Double
        /// The entry interface's time and inertial flight-path angle (rad).
        public var entry: (time: Epoch, flightPathAngle: Double)?

        public init(apoapsisAltitude: Double?, periapsisAltitude: Double,
                    entry: (time: Epoch, flightPathAngle: Double)? = nil) {
            self.apoapsisAltitude = apoapsisAltitude
            self.periapsisAltitude = periapsisAltitude
            self.entry = entry
        }

        public static func == (a: Prediction, b: Prediction) -> Bool {
            a.apoapsisAltitude == b.apoapsisAltitude && a.periapsisAltitude == b.periapsisAltitude
                && a.entry?.time == b.entry?.time && a.entry?.flightPathAngle == b.entry?.flightPathAngle
        }
    }

    /// What the burn is ("DEORBIT", "MCC-1").
    public var name: String
    public var engine: Engine
    /// The time of ignition: when the engine lights, the burn centred on the
    /// impulsive time when its length is known.
    public var ignition: Epoch
    /// The velocity change, ICRF, m/s.
    public var deltaV: Vec3
    /// The same in P30's local vertical axes at TIG (N81): X along the
    /// horizontal velocity, Y opposite the orbit normal, Z down; m/s.
    public var deltaVLocal: Vec3
    /// The burn's length on its engine, s; nil when not known.
    public var burnTime: Double?
    /// The attitude to burn in (body -> ICRF), when the planner gives one;
    /// nil leaves it to the computer (thrust along the Δv through the centre
    /// of mass, rolled heads up or down).
    public var attitude: Quat?
    /// The crew's heads away from the Earth (true) or towards it.
    public var headsUp: Bool
    /// The EMS counter's setting: the Δv less the engine's predicted
    /// tail-off, m/s; nil when not computed.
    public var deltaVCounter: Double?
    /// The ullage before the burn; nil for none.
    public var ullage: Ullage?
    /// The orbit without the burn and with it.
    public var without: Prediction?
    public var with: Prediction?
    /// The epoch of the state the plan was solved from.
    public var stateEpoch: Epoch
    public var source: Source

    public init(name: String, engine: Engine = .sps, ignition: Epoch, deltaV: Vec3, deltaVLocal: Vec3,
                burnTime: Double? = nil, attitude: Quat? = nil, headsUp: Bool = false, deltaVCounter: Double? = nil,
                ullage: Ullage? = nil, without: Prediction? = nil, with: Prediction? = nil, stateEpoch: Epoch,
                source: Source) {
        self.name = name
        self.engine = engine
        self.ignition = ignition
        self.deltaV = deltaV
        self.deltaVLocal = deltaVLocal
        self.burnTime = burnTime
        self.attitude = attitude
        self.headsUp = headsUp
        self.deltaVCounter = deltaVCounter
        self.ullage = ullage
        self.without = without
        self.with = with
        self.stateEpoch = stateEpoch
        self.source = source
    }

    /// The Δv's size, m/s (P30's ΔVT).
    public var deltaVMagnitude: Double { deltaV.length }
    /// The thrust direction, ICRF.
    public var direction: Vec3 { deltaV.normalized }
}
