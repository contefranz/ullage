import Foundation

/// Something that happened to a vessel that effects draw (a retro's flash,
/// a separation's debris, a splash), with its exact epoch and the vessel's
/// state then. Effects spawn from these records rather than from what they
/// see frame to frame, so that at 100× (1.7 s a frame) or 1000× an event is
/// neither lost nor misplaced in time: a burst can start at its true age.
public struct EffectEvent {
    public enum Kind: Equatable {
        /// The vessel left the ground: its thrust overcame its weight.
        case liftoff
        /// The vessel left `parent` (its `Vessel.id`) at a separation,
        /// carrying `parts`: staging event `event`, or the bottom part of a
        /// stack with no events (nil).
        case separation(event: Int?, parts: [String], parent: UUID)
        /// A thruster (`thruster`, in part `part`) was commanded on: its
        /// start signal, a solid lit, a firing sequence's window opening.
        /// Its start transient (`Thruster.transients`) follows.
        case ignition(thruster: String, part: String)
        /// A thruster stopped being commanded: its cutoff, a failure, a
        /// sequence's window closing, its propellant or grain gone. Its
        /// shutdown transient follows.
        case cutoff(thruster: String, part: String)
        /// A parachute cluster (`Parachute.name`) changed state: deployed
        /// (`.deploying`), reefed, disreefed (`.open`) or released.
        case parachute(name: String, state: Parachute.State)
        /// The vessel came to rest on water, at `speed` over the surface (m/s).
        case splashdown(speed: Double)
        /// The vessel came to rest on land, at `speed` (m/s).
        case touchdown(speed: Double)
        /// The vessel hit `surface` too fast to survive, at `speed` (m/s).
        case impact(surface: SurfaceKind, speed: Double)
        /// The vessel broke up in flight. Nothing in the core decides that
        /// yet: the entry effects record it (`Simulation.recordEffect`).
        case breakup
    }

    /// Its place in the journal: 0 for the first record, one more for each
    /// after, never reused.
    public let sequence: Int
    public let epoch: Epoch
    public let kind: Kind
    /// The vessel (`Vessel.id`) and its name then.
    public let vessel: UUID
    public let vesselName: String
    /// The vessel's state at `epoch`, as `Vessel` keeps it: relative to the
    /// reference body's centre, ICRF axes; attitude body -> ICRF; angular
    /// velocity in body axes.
    public let reference: CelestialBody
    public let position: Vec3
    public let velocity: Vec3
    public let attitude: Quat
    public let angularVelocity: Vec3
    /// Where on the vessel it happened, body axes from its centre of mass
    /// (the vessel's origin): a thruster's position; zero for the vessel as
    /// a whole.
    public let point: Vec3
    /// Unit, body axes: a thruster's exhaust, against its thrust as the
    /// gimbal pointed it; +x otherwise.
    public let direction: Vec3
}

/// The simulation's record of effect events (`EffectEvent`): a bounded ring,
/// the oldest records dropped once it holds `capacity`. A reader keeps the
/// sequence it has read up to and asks for what came after it
/// (`events(from:)`), each frame; it learns of records it missed.
public final class EffectJournal {
    public let capacity: Int
    private var ring: [EffectEvent] = []
    /// Index in `ring` of the oldest record once the ring is full.
    private var oldest = 0
    /// The sequence the next record will have: how many were ever recorded.
    public private(set) var nextSequence = 0

    public init(capacity: Int = 4096) {
        precondition(capacity > 0, "the journal holds at least one record")
        self.capacity = capacity
        ring.reserveCapacity(capacity)
    }

    /// Records held, at most `capacity`.
    public var count: Int { ring.count }

    /// Every record held, oldest first.
    public var events: [EffectEvent] { Array(ring[oldest...] + ring[..<oldest]) }

    /// The records from sequence `sequence` on, oldest first, and how many
    /// of those the ring has already dropped.
    public func events(from sequence: Int) -> (events: [EffectEvent], missed: Int) {
        let first = nextSequence - ring.count
        let start = max(sequence, first)
        guard start < nextSequence else { return ([], max(0, first - sequence)) }
        let held = events
        return (Array(held[(start - first)...]), max(0, first - sequence))
    }

    /// Record `kind` for `vessel` at `epoch`, in the vessel's present state.
    public func record(_ kind: EffectEvent.Kind, vessel v: Vessel, at epoch: Epoch, point: Vec3 = .zero,
                       direction: Vec3 = .unitX) {
        let e = EffectEvent(sequence: nextSequence, epoch: epoch, kind: kind, vessel: v.id, vesselName: v.name,
                            reference: v.reference, position: v.position, velocity: v.velocity,
                            attitude: v.attitude, angularVelocity: v.angularVelocity, point: point,
                            direction: direction)
        nextSequence += 1
        if ring.count < capacity {
            ring.append(e)
        } else {
            ring[oldest] = e
            oldest = (oldest + 1) % capacity
        }
    }

    /// Drop every record; the sequence carries on.
    public func removeAll() {
        ring.removeAll(keepingCapacity: true)
        oldest = 0
    }
}

/// What the journal last saw of each thruster and parachute, to find the
/// edges between one look and the next. Each vessel has a view of its
/// thrusters and parachutes, kept while its parts stay the same, so a look
/// walks arrays; a vessel whose parts changed (a separation) gets a new
/// view, which takes each object's last state from wherever it was seen.
/// The objects are held, so an identifier is never reused while here.
///
/// A vessel's baseline, the states no edge is recorded for, is taken when
/// it is added to a simulation that has stepped (a stage that separates,
/// its retros lit, records their ignition at its first look). A vessel
/// added before the first step, as a scenario builds it, waits for that
/// step's look, once its program, autopilot and pilot have set the
/// controls: a vessel that arrives burning has not just lit its engines,
/// though its liquid engines' levels are only set by the first control pass.
final class EffectEdges {
    final class ThrusterEntry {
        let thruster: Thruster
        let part: VesselPart
        var on: Bool
        init(_ thruster: Thruster, _ part: VesselPart, _ on: Bool) {
            self.thruster = thruster
            self.part = part
            self.on = on
        }
    }

    final class ParachuteEntry {
        let parachute: Parachute
        let part: VesselPart
        var state: Parachute.State
        init(_ parachute: Parachute, _ part: VesselPart, _ state: Parachute.State) {
            self.parachute = parachute
            self.part = part
            self.state = state
        }
    }

    final class View {
        let parts: [VesselPart]
        let thrusters: [ThrusterEntry]
        let parachutes: [ParachuteEntry]
        init(parts: [VesselPart], thrusters: [ThrusterEntry], parachutes: [ParachuteEntry]) {
            self.parts = parts
            self.thrusters = thrusters
            self.parachutes = parachutes
        }

        func matches(_ parts: [VesselPart]) -> Bool {
            guard parts.count == self.parts.count else { return false }
            for i in parts.indices where parts[i] !== self.parts[i] { return false }
            return true
        }
    }

    /// Every entry ever made, by its object's identity: the last state seen.
    private var thrusters: [ObjectIdentifier: ThrusterEntry] = [:]
    private var parachutes: [ObjectIdentifier: ParachuteEntry] = [:]
    private var views: [ObjectIdentifier: View] = [:]
    /// Set by the first step's look.
    private(set) var started = false
    /// Vessels added before the first step, their baseline still to take.
    private var awaitingControls: Set<ObjectIdentifier> = []

    /// `v` joined the simulation: take its baseline now, or at the first
    /// step's look if the simulation has not stepped yet.
    func arrive(_ v: Vessel) {
        if started { _ = view(of: v) } else { awaitingControls.insert(ObjectIdentifier(v)) }
    }

    func isAwaitingControls(_ v: Vessel) -> Bool { awaitingControls.contains(ObjectIdentifier(v)) }

    /// The first step's look, its controls set: take the baseline of every
    /// vessel waiting for it, as its thrusters and parachutes are now.
    func start(_ vessels: [Vessel]) {
        for v in vessels where isAwaitingControls(v) {
            views[ObjectIdentifier(v)] = nil
            for p in v.parts {
                for t in p.thrusters { thrusters[ObjectIdentifier(t)] = nil }
                for c in p.parachutes { parachutes[ObjectIdentifier(c)] = nil }
            }
            _ = view(of: v)
        }
        awaitingControls.removeAll()
        started = true
    }

    /// `v`'s view, made afresh if its parts changed. A thruster or parachute
    /// never seen before is taken as it is, with no edge.
    func view(of v: Vessel) -> View {
        if let view = views[ObjectIdentifier(v)], view.matches(v.parts) { return view }
        var ts: [ThrusterEntry] = [], cs: [ParachuteEntry] = []
        for p in v.parts {
            for t in p.thrusters {
                let last = thrusters[ObjectIdentifier(t)]
                let e = ThrusterEntry(t, p, last?.on ?? t.isCommanded)
                thrusters[ObjectIdentifier(t)] = e
                ts.append(e)
            }
            for c in p.parachutes {
                let last = parachutes[ObjectIdentifier(c)]
                let e = ParachuteEntry(c, p, last?.state ?? c.state)
                parachutes[ObjectIdentifier(c)] = e
                cs.append(e)
            }
        }
        let view = View(parts: v.parts, thrusters: ts, parachutes: cs)
        views[ObjectIdentifier(v)] = view
        return view
    }

    /// Forget `v` and its thrusters and parachutes (it left the simulation).
    func forget(_ v: Vessel) {
        awaitingControls.remove(ObjectIdentifier(v))
        views[ObjectIdentifier(v)] = nil
        for p in v.parts {
            for t in p.thrusters { thrusters[ObjectIdentifier(t)] = nil }
            for c in p.parachutes { parachutes[ObjectIdentifier(c)] = nil }
        }
    }
}

extension Simulation {
    /// Record `kind` for `v` now, in its present state (`EffectJournal`).
    public func recordEffect(_ kind: EffectEvent.Kind, _ v: Vessel, point: Vec3 = .zero, direction: Vec3 = .unitX) {
        journal.record(kind, vessel: v, at: time, point: point, direction: direction)
    }

    /// Record the thrusters commanded on or off and the parachutes that
    /// changed state since the last look, at the present epoch. `step`
    /// looks as it starts, once the controls are set: commands from the
    /// flight programs and the pilot then carry their own epoch, and what a
    /// step ended (a burnout, a sequence's window, a reefing stage) carries
    /// the step's end, which is where the next one starts. The steps end on
    /// those, so neither the time warp nor the frame rate moves them; only
    /// what the last step of a frame ended waits for the next step to be
    /// recorded, at its own epoch, unless a reader looks first: one that
    /// calls this before reading the journal has it in the same frame.
    /// Before the first step it records nothing for the vessels added so
    /// far, whose baseline waits for that step (`EffectEdges`).
    public func recordEffectEdges() { lookForEffectEdges(controlsSet: false) }

    /// `recordEffectEdges`; `step` looks with `controlsSet`, which takes the
    /// baseline of the vessels added before the first step.
    func lookForEffectEdges(controlsSet: Bool) {
        if controlsSet && !effectEdges.started { effectEdges.start(vessels) }
        for v in vessels {
            if !effectEdges.started && effectEdges.isAwaitingControls(v) { continue }
            let view = effectEdges.view(of: v)
            for e in view.thrusters {
                let on = e.thruster.isCommanded
                guard on != e.on else { continue }
                e.on = on
                let t = e.thruster, p = e.part
                let kind: EffectEvent.Kind = on ? .ignition(thruster: t.name, part: p.name)
                    : .cutoff(thruster: t.name, part: p.name)
                recordEffect(kind, v, point: p.offset + t.position, direction: -t.thrustDirection)
            }
            for e in view.parachutes where e.parachute.state != e.state {
                e.state = e.parachute.state
                recordEffect(.parachute(name: e.parachute.name, state: e.state), v,
                             point: e.part.offset + e.parachute.attachPoint)
            }
        }
    }
}
