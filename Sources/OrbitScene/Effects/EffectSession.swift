import Foundation
import OrbitCore

// The effect director's logic, in plain Swift so effect tracks can test
// their emitters on Linux: the anchors, the time rules, journal bursts at
// their true age, continuous emitters over the last lifetime, the resets.
// OrbitRender's EffectDirector runs one session a frame and hands its output
// to the GPU particles. Frozen API: see docs/m16/design-plumes-particles.md,
// "P3 API (frozen)".

/// An effect track's emitters (P4's launch, P5's staging and spacecraft,
/// P6's entry and recovery). The director calls, each frame: `handle` for
/// every journal event not seen before, oldest first, then `update`. A
/// producer keeps no particles of its own: it asks the frame for anchors and
/// emits requests into them.
public protocol EffectProducer: AnyObject {
    var name: String { get }
    /// Registers its materials, once, when it joins a session; it keeps the ids.
    func registerMaterials(_ table: ParticleMaterialTable)
    /// A journal record (`EffectEvent`), at its own epoch: spawn bursts with
    /// `frame.burst(_:at:)`, which ages them to the frame.
    func handle(_ event: EffectEvent, in frame: EffectFrame)
    /// Continuous emitters (`frame.emitContinuous`) and state-driven effects.
    func update(_ frame: EffectFrame)
    /// Everything was cleared (a scenario change, a time jump): forget any state.
    func reset()
}

extension EffectProducer {
    public func handle(_ event: EffectEvent, in frame: EffectFrame) {}
    public func update(_ frame: EffectFrame) {}
    public func reset() {}
}

/// Where a point of a vessel is in an anchor, and how it moves there.
public struct EffectPlacement: Equatable {
    /// Anchor axes, relative to the anchor: m, m/s, m/s².
    public var position: Vec3
    public var velocity: Vec3
    public var acceleration: Vec3
    /// The vessel's body axes to the anchor's.
    public var toAnchor: Mat3

    /// A body-axes direction in the anchor's axes.
    public func direction(_ d: Vec3) -> Vec3 { toAnchor * d }
}

/// What one frame of effects asks of the GPU particles.
public struct EffectFrameOutput {
    public var clock: EffectClock
    /// Clear every particle before this frame's emission.
    public var resets: Bool
    public var requests: [EmitRequest]
    /// The live anchors, by slot.
    public var anchors: [(id: EffectAnchorID, frame: AnchorFrame)]
    /// The air the anchors read (`AnchorFrame.airProfile`).
    public var airProfiles: [AirProfile]
    /// The render classes that may have particles alive: the others cost nothing.
    public var drawn: Set<ParticleRenderClass>
    public var materials: ParticleMaterialTable
    /// Requests dropped this frame (too old, no anchor, over the budget).
    public var dropped: Int

    public init(clock: EffectClock, resets: Bool, requests: [EmitRequest], anchors: [(id: EffectAnchorID, frame: AnchorFrame)],
                airProfiles: [AirProfile], drawn: Set<ParticleRenderClass>, materials: ParticleMaterialTable,
                dropped: Int = 0) {
        self.clock = clock
        self.resets = resets
        self.requests = requests
        self.anchors = anchors
        self.airProfiles = airProfiles
        self.drawn = drawn
        self.materials = materials
        self.dropped = dropped
    }
}

/// One frame's handle for the producers: the scene, the clocks, the
/// materials, anchors, and emitting.
public final class EffectFrame {
    public let scene: RenderScene
    public let clock: EffectClock
    public let materials: ParticleMaterialTable
    private unowned let session: EffectSession

    init(scene: RenderScene, clock: EffectClock, session: EffectSession) {
        self.scene = scene
        self.clock = clock
        materials = session.materials
        self.session = session
    }

    public func body(_ id: Int) -> RenderScene.Body? { scene.bodies.first { $0.id == id } }

    // MARK: Anchors

    /// A new anchor, carried on to the frame's epoch; nil when all
    /// `ParticleBudget.anchors` are in use. It lives while particles emitted
    /// into it may.
    public func anchor(_ a: EffectAnchor) -> EffectAnchorID? {
        session.makeAnchor(a.propagated(to: clock.epoch, body: a.bodyID.flatMap(body)), frame: clock.frame,
                           epoch: clock.epoch)
    }

    /// A free-fall anchor at the event's vessel's state then: its origin the
    /// vessel's centre of mass at the event.
    public func freeFallAnchor(for e: EffectEvent) -> EffectAnchorID? {
        anchor(.freeFall(bodyID: e.reference.id, position: e.position, velocity: e.velocity, epoch: e.epoch))
    }

    /// A free-fall anchor at the vessel's state now.
    public func freeFallAnchor(for v: RenderScene.Vessel) -> EffectAnchorID? {
        guard let b = body(v.referenceBodyID) else { return nil }
        return anchor(.freeFall(bodyID: b.id, position: v.position - b.position, velocity: v.velocity,
                                epoch: clock.epoch))
    }

    /// A body-fixed anchor at a site's origin (the pad).
    public func bodyFixedAnchor(at site: RenderScene.Site) -> EffectAnchorID? {
        guard let b = body(site.bodyID) else { return nil }
        return anchor(.bodyFixed(bodyID: b.id, origin: b.orientation.toBody(site.origin - b.position)))
    }

    /// The vessel's tracking anchor for `key`: one free-fall anchor that its
    /// continuous emitters share, started afresh at its state once it is
    /// `EffectSession.rebaseAge` old or the vessel is `rebaseDistance` from
    /// it (a body-fixed one while the vessel is landed). Old anchors live on
    /// while their particles do.
    public func vesselAnchor(_ id: UUID, key: String = "") -> EffectAnchorID? {
        session.vesselAnchor(id, key: key, frame: self)
    }

    /// The anchor's state now.
    public func anchorState(_ id: EffectAnchorID) -> EffectAnchor? { session.anchorState(id) }

    /// The anchor as this frame draws it.
    public func anchorFrame(_ id: EffectAnchorID) -> AnchorFrame? {
        session.anchorState(id).flatMap { session.frame(of: $0, in: scene) }
    }

    // MARK: Placing

    /// A point of the event's vessel (body axes from its centre of mass), at
    /// the event's epoch, in the anchor: where `burst` takes a request's
    /// origin (`sourceVelocity` zero: the event's instant). A body-fixed
    /// anchor is turned back to the event by the body's rotation.
    public func place(_ point: Vec3, of e: EffectEvent, in id: EffectAnchorID) -> EffectPlacement? {
        guard let a = session.anchorState(id) else { return nil }
        let toICRF = e.attitude.matrix
        let r = e.position + toICRF * point
        let v = e.velocity + toICRF * e.angularVelocity.cross(point)
        return Self.place(r: r, v: v, acceleration: .zero, toICRF: toICRF, at: e.epoch, in: a, now: clock.epoch,
                          body: body(e.reference.id))
    }

    /// A point of a vessel now (body axes from its centre of mass), in the
    /// anchor, with the vessel's acceleration over the last frame: a
    /// continuous emitter's origin, `sourceVelocity` and `sourceAcceleration`.
    public func place(_ point: Vec3, of v: RenderScene.Vessel, in id: EffectAnchorID) -> EffectPlacement? {
        guard let a = session.anchorState(id), let b = body(v.referenceBodyID) else { return nil }
        let toICRF = v.attitude.matrix
        return Self.place(r: v.position - b.position + toICRF * point, v: v.velocity,
                          acceleration: session.acceleration(of: v.id), toICRF: toICRF, at: clock.epoch, in: a,
                          now: clock.epoch, body: b)
    }

    static func place(r: Vec3, v: Vec3, acceleration: Vec3, toICRF: Mat3, at epoch: Epoch, in a: EffectAnchor,
                      now: Epoch, body: RenderScene.Body?) -> EffectPlacement? {
        switch a {
        case let .freeFall(id, _, _, _):
            guard let state = body.map({ a.propagated(to: epoch, body: $0) }), body?.id == id,
                  case let .freeFall(_, ra, va, _) = state else { return nil }
            return EffectPlacement(position: r - ra, velocity: v - va, acceleration: acceleration, toAnchor: toICRF)
        case let .bodyFixed(id, origin):
            guard let body, body.id == id else { return nil }
            // The body's axes then: B(t) = B(now) R_ω(now − t).
            let omega = body.orientation.angularVelocity
            let turn = omega.length > 0 ? Quat(axis: omega.normalized, angle: omega.length * (now - epoch)).matrix
                : Mat3.identity
            let toBody = body.orientation.icrfToBody * turn
            let p = toBody * r
            return EffectPlacement(position: p - origin, velocity: toBody * (v - omega.cross(r)),
                                   acceleration: toBody * acceleration, toAnchor: toBody * toICRF)
        case .studio:
            return nil
        }
    }

    // MARK: Emitting

    /// Emits `r` as it is: its ages are the particles' at the frame.
    public func emit(_ r: EmitRequest) { session.emit(r, frame: self) }

    /// A burst that happened at `epoch`: its ages are taken from then, so it
    /// appears as it is by now (at 100× a separation a frame ago is a second
    /// on). A burst older than its lifetime is dropped, unless it is a
    /// flash above 10× that ended within this frame (`EffectTimeRules.spawns`).
    public func burst(_ r: EmitRequest, at epoch: Epoch) {
        var r = r
        let age = EffectTimeRules.burstAge(event: epoch, frame: clock.epoch)
        r.ages = (r.ages.lowerBound + age)...(r.ages.upperBound + age)
        guard r.material.index < materials.count else { return session.drop(r) }
        let flash = materials[r.material].isFlash
        guard EffectTimeRules.spawns(age: r.ages.lowerBound, lifetime: r.lifetime.upperBound, isFlash: flash,
                                     clock: clock) else { return session.drop(r) }
        emit(r)
    }

    /// A continuous emitter, `key` naming it across frames: `rate` particles
    /// a second of `r` (its count and ages are set here), covering only the
    /// last lifetime of the frame's interval, with stratified ages. Stops at
    /// 1,000× and above unless `persistsAtHighWarp` (the trail).
    public func emitContinuous(_ key: String, rate: Double, _ r: EmitRequest, persistsAtHighWarp: Bool = false) {
        session.emitContinuous(key, rate: rate, r, persists: persistsAtHighWarp, frame: self)
    }
}

/// The director's state across frames.
public final class EffectSession {
    public let materials = ParticleMaterialTable()
    public private(set) var producers: [EffectProducer] = []

    /// A vessel's tracking anchor is started afresh after this many seconds...
    public static let rebaseAge = 2.0
    /// ...or once the vessel is this far from it, m.
    public static let rebaseDistance = 500.0

    struct Slot {
        var anchor: EffectAnchor
        var generation: Int
        /// It lives while the frame is before this, or within a held flash's frames of its last use.
        var expires: Epoch
        var lastUse: Int
    }

    private var slots = [Slot?](repeating: nil, count: ParticleBudget.anchors)
    private var generations = [Int](repeating: 0, count: ParticleBudget.anchors)
    private var tracking: [String: (id: EffectAnchorID, since: Epoch)] = [:]
    private var continuous: [String: ContinuousEmission] = [:]
    private var lastVelocity: [UUID: (velocity: Vec3, epoch: Epoch, acceleration: Vec3)] = [:]
    /// Per class: when its last particles die, and the last frame a held flash may show.
    private var liveUntil: [ParticleRenderClass: Epoch] = [:]
    private var flashFrames: [ParticleRenderClass: Int] = [:]
    private var requests: [EmitRequest] = []
    private var dropped = 0
    private var lastSequence = -1
    private var last: (frameIndex: Int, simTime: Epoch, vessels: Set<UUID>)?
    private var turbulenceTime = 0.0
    private var frameCount = 0
    private var iceTemperatures: [Double]?

    public init(producers: [EffectProducer] = []) {
        for p in producers { add(p) }
    }

    public func add(_ p: EffectProducer) {
        producers.append(p)
        p.registerMaterials(materials)
    }

    /// Forget every particle, anchor and emitter's state; on a new
    /// simulation, the journal's place too.
    public func reset(newSimulation: Bool) {
        slots = [Slot?](repeating: nil, count: ParticleBudget.anchors)
        tracking = [:]
        continuous = [:]
        lastVelocity = [:]
        liveUntil = [:]
        flashFrames = [:]
        frameCount = 0
        if newSimulation { lastSequence = -1 }
        for p in producers { p.reset() }
    }

    // MARK: The frame

    /// Runs one frame of `scene`: its clock, the resets, the journal's new
    /// events and every producer, or the settings' look-dev bursts instead.
    public func frame(_ scene: RenderScene, settings: ParticleSettings) -> EffectFrameOutput {
        let c = scene.clock
        let vessels = Set(scene.vessels.map(\.id))
        var newSimulation = last == nil
        if let last {
            newSimulation = c.frameIndex < last.frameIndex
                || !last.vessels.isEmpty && !vessels.isEmpty && last.vessels.isDisjoint(with: vessels)
        }
        let again = !newSimulation && last.map { c.frameIndex == $0.frameIndex && c.simTime == $0.simTime } ?? false
        var dt = newSimulation || again ? 0 : c.simTime - last!.simTime
        if c.paused { dt = 0 }
        let jump = EffectTimeRules.isTimeJump(dt)
        if jump { dt = 0 }
        let studio = !settings.testBursts.isEmpty
        let resets = newSimulation || jump || studio
        if resets { reset(newSimulation: newSimulation) }
        last = (c.frameIndex, c.simTime, vessels)
        var turbulenceDt = 0.0
        if !again {
            turbulenceDt = EffectTimeRules.turbulenceDt(realDt: c.realDt, warp: c.warp, paused: c.paused)
            turbulenceTime = (turbulenceTime + turbulenceDt).truncatingRemainder(dividingBy: EffectTimeRules.turbulencePeriod)
            if !resets { frameCount += 1 }
        }
        let clock = EffectClock(epoch: c.simTime, dt: dt, realDt: c.realDt, warp: c.warp, paused: c.paused,
                                turbulenceDt: turbulenceDt, turbulenceTime: turbulenceTime, frame: frameCount)
        requests = []
        dropped = 0
        propagateAnchors(scene, clock: clock)
        if !again { noteVelocities(scene, clock: clock) }
        let f = EffectFrame(scene: scene, clock: clock, session: self)

        if studio {
            if let id = f.anchor(.studio(settings.studio.anchor)) {
                for b in settings.testBursts {
                    guard let m = b.resolvedMaterial else { continue }
                    f.emit(b.request(anchor: id, material: materials.register(m)))
                }
            }
        } else if !again {
            for t in scene.transitions {
                guard case .event(let e) = t, e.sequence > lastSequence else { continue }
                lastSequence = e.sequence
                for p in producers { p.handle(e, in: f) }
            }
            for p in producers { p.update(f) }
        }
        retireAnchors(clock: clock)

        var airProfiles: [AirProfile] = [], airIndex: [Int: Int] = [:]
        for b in scene.bodies {
            if let air = b.air {
                airIndex[b.id] = airProfiles.count
                airProfiles.append(air)
            }
        }
        var studioIndex: Int?
        if studio {
            let s = settings.studio.anchor.air
            studioIndex = airProfiles.count
            airProfiles.append(AirProfile(constant: s, windEast: s.velocity.x, windNorth: s.velocity.y))
        }
        var anchors: [(id: EffectAnchorID, frame: AnchorFrame)] = []
        for (i, s) in slots.enumerated() {
            guard let s, let frame = s.anchor.frame(in: scene, airProfile: { airIndex[$0] }, studioProfile: studioIndex,
                                                    iceTemperature: iceTemperature) else { continue }
            anchors.append((EffectAnchorID(slot: i, generation: s.generation), frame))
        }
        var drawn = Set<ParticleRenderClass>()
        for k in ParticleRenderClass.allCases {
            if let t = liveUntil[k], clock.epoch < t { drawn.insert(k) }
            if let n = flashFrames[k], clock.frame <= n { drawn.insert(k) }
        }
        return EffectFrameOutput(clock: clock, resets: resets, requests: requests, anchors: anchors,
                                 airProfiles: airProfiles, drawn: drawn, materials: materials, dropped: dropped)
    }

    // MARK: Anchors

    func makeAnchor(_ a: EffectAnchor, frame: Int, epoch: Epoch) -> EffectAnchorID? {
        guard let i = slots.firstIndex(where: { $0 == nil }) else { return nil }
        generations[i] += 1
        slots[i] = Slot(anchor: a, generation: generations[i], expires: epoch, lastUse: frame)
        return EffectAnchorID(slot: i, generation: generations[i])
    }

    func anchorState(_ id: EffectAnchorID) -> EffectAnchor? {
        guard id.slot >= 0, id.slot < slots.count, let s = slots[id.slot], s.generation == id.generation else {
            return nil
        }
        return s.anchor
    }

    func frame(of a: EffectAnchor, in scene: RenderScene) -> AnchorFrame? {
        a.frame(in: scene, airProfile: { _ in nil }, studioProfile: nil, iceTemperature: iceTemperature)
    }

    private func propagateAnchors(_ scene: RenderScene, clock: EffectClock) {
        for i in slots.indices {
            guard var s = slots[i], case .freeFall(let id, _, _, _) = s.anchor else { continue }
            s.anchor = s.anchor.propagated(to: clock.epoch, body: scene.bodies.first { $0.id == id })
            slots[i] = s
        }
    }

    private func retireAnchors(clock: EffectClock) {
        for i in slots.indices {
            guard let s = slots[i] else { continue }
            if clock.epoch >= s.expires && clock.frame > s.lastUse + EffectTimeRules.flashHoldFrames { slots[i] = nil }
        }
    }

    func vesselAnchor(_ id: UUID, key: String, frame f: EffectFrame) -> EffectAnchorID? {
        guard let v = f.scene.vessel(id), let b = f.body(v.referenceBodyID) else { return nil }
        let k = "\(id.uuidString)/\(key)"
        if let t = tracking[k], let a = anchorState(t.id) {
            switch a {
            case let .freeFall(_, r, _, _) where !v.isLanded:
                if f.clock.epoch - t.since < Self.rebaseAge && (v.position - b.position - r).length < Self.rebaseDistance {
                    return t.id
                }
            case .bodyFixed where v.isLanded:
                return t.id
            default:
                break
            }
        }
        let made = v.isLanded
            ? f.anchor(.bodyFixed(bodyID: b.id, origin: b.orientation.toBody(v.position - b.position)))
            : f.freeFallAnchor(for: v)
        guard let made else { return nil }
        tracking[k] = (made, f.clock.epoch)
        return made
    }

    /// Each vessel's acceleration over the last frame (ICRF), for continuous
    /// emitters' `sourceAcceleration`.
    func acceleration(of id: UUID) -> Vec3 { lastVelocity[id]?.acceleration ?? .zero }

    private func noteVelocities(_ scene: RenderScene, clock: EffectClock) {
        var next: [UUID: (velocity: Vec3, epoch: Epoch, acceleration: Vec3)] = [:]
        for v in scene.vessels {
            var a = Vec3.zero
            if let p = lastVelocity[v.id] {
                let dt = clock.epoch - p.epoch
                a = dt > 0 ? (v.velocity - p.velocity) / dt : p.acceleration
            }
            next[v.id] = (v.velocity, clock.epoch, a)
        }
        lastVelocity = next
    }

    private func iceTemperature(_ sunlit: Double) -> Double {
        if iceTemperatures == nil {
            iceTemperatures = (0...32).map {
                IceSublimation.radiativeEquilibriumTemperature(sunlitFraction: Double($0) / 32)
            }
        }
        let t = iceTemperatures!, u = min(max(sunlit, 0), 1) * 32
        let i = min(Int(u), 31), w = u - Double(i)
        return t[i] + w * (t[i + 1] - t[i])
    }

    // MARK: Emitting

    func drop(_ r: EmitRequest) { dropped += 1 }

    func emit(_ r: EmitRequest, frame f: EffectFrame) {
        guard r.count > 0 else { return }
        guard requests.count < ParticleBudget.requests, r.material.index < materials.count,
              var s = slots.indices.contains(r.anchor.slot) ? slots[r.anchor.slot] : nil,
              s.generation == r.anchor.generation else { return drop(r) }
        let m = materials[r.material]
        let life = max(0, r.lifetime.upperBound - r.ages.lowerBound)
        s.expires = max(s.expires, f.clock.epoch + life)
        s.lastUse = f.clock.frame
        slots[r.anchor.slot] = s
        liveUntil[m.renderClass] = max(liveUntil[m.renderClass] ?? f.clock.epoch, f.clock.epoch + life)
        if m.isFlash { flashFrames[m.renderClass] = f.clock.frame + EffectTimeRules.flashHoldFrames }
        requests.append(r)
    }

    func emitContinuous(_ key: String, rate: Double, _ r: EmitRequest, persists: Bool, frame f: EffectFrame) {
        if f.clock.suspendsContinuous && !persists {
            continuous[key] = nil
            return
        }
        var e = continuous[key] ?? ContinuousEmission()
        let s = e.schedule(rate: rate, dt: f.clock.dt, lifetime: r.lifetime.upperBound)
        continuous[key] = e
        guard s.count > 0 else { return }
        var r = r
        r.count = s.count
        r.ages = s.ages
        r.seed ^= ParticleRandom.seed(key, f.clock.frame)
        emit(r, frame: f)
    }
}
