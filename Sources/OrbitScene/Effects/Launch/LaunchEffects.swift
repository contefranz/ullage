import Foundation
import OrbitCore

/// Track P4's launch effects, one producer for P3's particles: the pad's
/// exhaust and deluge steam, the cold vapour off the LOX tank and out of the
/// umbilicals, the frost shed on FER Table 20-1's schedule, and the exhaust
/// trail (`ExhaustTrail`). Everything lives in one body-fixed anchor at
/// LC-39A's deck: the pad's clouds stay for minutes, the frost and the trail
/// fall and drift through the Earth-fixed air, and the launch day's sounding
/// (`RenderScene.Body.air`, `sim.atmosphere(of:)`) blows them on its winds.
///
/// Time: each frame emits what was born over its interval, with true ages,
/// from rates that are functions of time (`emitSlices`). The first frame
/// after a reset (a scenario opening, a snapshot, a time jump) has no
/// interval: it rebuilds the history instead, from the thrust buildup at
/// T−5.3 s (`PadIgnition`):
/// - the pad's sources stay at the pad, the vehicle rising straight up off
///   it (`LiftoffRise`);
/// - the F-1s' flow follows the journal's cutoffs (CECO, OECO, an engine
///   out), not the frame's;
/// - in flight, the frost's last second follows the vehicle's own motion;
/// - the trail is rebuilt along the climb and a monotone cubic after the
///   pitch program starts (`ExhaustTrail`).
/// So AS-506's pad opens with its 5.6 s of exhaust already out of the
/// trench, and a snapshot shows about the clouds and trail the frames to
/// it would have made (`LaunchEffectsTests`).
public final class LaunchEffects: EffectProducer {
    public let name = "P4 launch effects"

    public struct Materials {
        public var padExhaust, deluge, coldVapour, iceFlake, iceSlab: ParticleMaterialID
        public var trail: [ParticleMaterialID]
    }

    public private(set) var materials: Materials?
    public let trail = ExhaustTrail()

    /// The last frame's vehicle: its epoch and the exits' climb.
    struct Seen {
        var epoch: Epoch
        var vessel: UUID?
        var climb: Double
    }

    private var seen: Seen?
    private var pad: EffectAnchorID?
    private var carry: [String: Double] = [:]
    private var serial = 0
    /// The S-IC engines' cutoffs the journal recorded (CECO, OECO, an engine
    /// out), by thruster name: the flow a rebuilt history follows.
    private(set) var cutoffs: [String: Epoch] = [:]
    /// The latest of them, with the vehicle's state then: where a rebuilt
    /// trail ends once the S-IC has stopped firing (the spent stage's
    /// present, ballistic state is not the path it laid the trail on).
    private(set) var lastCutoff: EffectEvent?

    public init() {}

    public func registerMaterials(_ table: ParticleMaterialTable) {
        materials = Materials(padExhaust: table.register(LaunchMaterials.padExhaust),
                              deluge: table.register(LaunchMaterials.deluge),
                              coldVapour: table.register(LaunchMaterials.coldVapour),
                              iceFlake: table.register(LaunchMaterials.iceFlake),
                              iceSlab: table.register(LaunchMaterials.iceSlab),
                              trail: (0..<3).map { table.register(LaunchMaterials.trail($0)) })
    }

    /// A journal record: an S-IC engine's cutoff. A new simulation's frame
    /// delivers every record since the scenario opened, before `update`.
    public func handle(_ event: EffectEvent, in frame: EffectFrame) {
        guard case let .cutoff(thruster, part) = event.kind, part == "S-IC", thruster.hasPrefix("S-IC engine") else {
            return
        }
        cutoffs[thruster] = event.epoch
        if lastCutoff.map({ event.epoch >= $0.epoch }) ?? true { lastCutoff = event }
    }

    public func reset() {
        seen = nil
        pad = nil
        carry = [:]
        serial = 0
        cutoffs = [:]
        lastCutoff = nil
        trail.reset()
    }

    // MARK: The frame

    /// The F-1's sea-level thrust over its vacuum thrust (Betts' rated
    /// 1,522,000 and 1,748,200 lbf, H): an emitter's `thrustFraction` over
    /// this is its flow fraction near the ground.
    public static let seaLevelThrustFraction = 1_522_000.0 / 1_748_200.0
    /// The pad's effects run from the thrust buildup until this long after
    /// first motion, s: the climb has faded the exhaust out by then.
    public static let padWindow = 60.0
    /// The cold vapour streams for this long after first motion, s (the
    /// design's "about 10 s"), decaying over `vapourDecay`.
    public static let vapourWindow = 10.0
    public static let vapourDecay = 3.0
    /// Frost is shed from first motion to CECO (`FrostShedding`); a rebuilt
    /// history (a reset in flight) covers at most this much of it, s, since
    /// the vehicle's path before the frame is known only near the pad.
    public static let rebuiltFrostHistory = 1.0
    /// The F-1's tail-off after a cutoff, s (AS506's 0.66 s shutdown
    /// transient, FER §5.4: H impulse, L shape), linear here.
    public static let tailOff = 0.66
    /// The producer runs until this long after first motion, s: the S-IC
    /// has stopped laying the trail by OECO and tail-off (161.6 + 0.7 s,
    /// past its 40 km ceiling), and its puffs live `ExhaustTrail.lifetime`.
    public static let window = 170 + ExhaustTrail.lifetime.upperBound

    /// Everything the frame's emitters need: the site, its anchor, the
    /// vehicle and the time.
    struct Context {
        let frame: EffectFrame
        let site: RenderScene.Site
        let body: RenderScene.Body
        let countdown: LC39A.Countdown
        let firstMotion: Epoch
        let now: Epoch
        /// Where this frame's interval starts: the last frame's epoch, or on
        /// a rebuilt history the thrust buildup's.
        let from: Epoch
        let rebuilt: Bool
        let vehicle: Vehicle
        /// Site axes to the anchor's (the body's).
        let toAnchor: Mat3
        var anchor: EffectAnchorID?

        func range(_ t: Epoch) -> Double { countdown.rangeTime(at: t) }
    }

    /// The launch vehicle as this frame sees it.
    struct Vehicle {
        let vessel: RenderScene.Vessel
        /// The S-IC's nozzle exits, site frame, gimbals at null.
        let exits: [(centre: Vec3, radius: Double)]
        /// Their plane's height (site z) and climb since the pad.
        let exitHeight: Double
        let climb: Double
        /// The five F-1s' flow over their full flow, from the scene's emitters.
        let flow: Double
        let clusterRadius: Double
        /// Where P2's plume hands the exhaust over to the trail, slowed to
        /// the air (`PlumeAirflow.trailHandover`): its distance along the
        /// nozzles' axis and its point from their exits, world axes.
        let trailHead: PlumeAirflow.Handover?
        /// Its speed through the air, m/s (the F-1s' relative wind).
        let airspeed: Double
    }

    public func update(_ f: EffectFrame) {
        guard let m = materials, let site = f.scene.sites.first(where: { $0.name == LC39A.placement().name }),
              let body = f.body(site.bodyID) else { return }
        let now = f.clock.epoch
        let countdown = LaunchCountdown.nearest(now)
        let range = countdown.rangeTime(at: now)
        let buildup = LaunchCountdown.epoch(PadIgnition.thrustBuildup, in: countdown)
        let firstMotion = LaunchCountdown.epoch(countdown.firstMotion, in: countdown)
        // A history is rebuilt only on the first frame after a reset; later
        // frames carry on from the last one's epoch, whatever happened in
        // between (a staging's new vessels, a stretch with no vehicle).
        let last = seen
        guard range >= PadIgnition.thrustBuildup, range < countdown.firstMotion + Self.window,
              let vehicle = Self.vehicle(in: f.scene, site: site)
        else {
            seen = Seen(epoch: now, vessel: nil, climb: 0)
            return
        }
        seen = Seen(epoch: now, vessel: vehicle.vessel.id, climb: vehicle.climb)
        let rebuilt = last == nil
        let from = last.map { min($0.epoch, now) } ?? buildup
        guard now > from || rebuilt else { return }
        let toAnchor = body.orientation.icrfToBody * site.orientation
        var c = Context(frame: f, site: site, body: body, countdown: countdown, firstMotion: firstMotion, now: now,
                        from: from, rebuilt: rebuilt, vehicle: vehicle, toAnchor: toAnchor, anchor: nil)
        let previousClimb = last?.vessel == vehicle.vessel.id ? last?.climb : nil
        if now - firstMotion < Self.padWindow + ParticleLifetimes.padExhaust.upperBound {
            padExhaust(&c, m, previousClimb: previousClimb)
            vapour(&c, m)
        }
        frost(&c, m)
        trail.update(&c, materials: m.trail, owner: self)
    }

    /// The vessel carrying the S-IC (the stack until staging), and its
    /// nozzles and flow.
    static func vehicle(in scene: RenderScene, site: RenderScene.Site) -> Vehicle? {
        guard let v = scene.vessels.first(where: { $0.geometry.parts.contains { $0.name == "S-IC" } }) else { return nil }
        let toSite = site.orientation.transposed
        var exits: [(centre: Vec3, radius: Double)] = []
        for p in v.geometry.parts where p.name == "S-IC" {
            for t in p.thrusters where t.name.hasPrefix("S-IC engine") {
                guard let n = v.geometry.nozzles[t.key] else { continue }
                let world = v.position + v.attitude.rotate(v.structureOrigin + n.exit)
                exits.append((toSite * (world - site.origin), n.radius))
            }
        }
        guard !exits.isEmpty else { return nil }
        let height = exits.reduce(0) { $0 + $1.centre.z } / Double(exits.count)
        let kerosene = scene.emitters.filter { $0.vesselID == v.id && $0.style == .kerosene && !$0.isJet && !$0.isSolid }
        let flow = kerosene.reduce(0) { $0 + min(1, $1.thrustFraction / seaLevelThrustFraction) } / Double(exits.count)
        let own = scene.emitters.filter { $0.vesselID == v.id }
        return Vehicle(vessel: v, exits: exits, exitHeight: height,
                       climb: max(0, height - PadExhaust.exitHeightOnPad), flow: flow,
                       clusterRadius: PadExhaust.clusterRadius(exits: exits),
                       trailHead: PlumeAirflow.trailHandover(own),
                       airspeed: own.first { $0.name.hasPrefix("S-IC engine") }?.relativeWind.length ?? 0)
    }

    // MARK: Time

    /// The five F-1s' flow fraction at `t`: the ignition's before first
    /// motion; after it the scene's on a frame after another, and on a
    /// rebuilt history the journal's: each engine at full flow until its
    /// recorded cutoff, tailing off linearly over `tailOff`.
    func flow(_ c: Context, _ t: Epoch) -> Double {
        if t <= c.firstMotion { return PadIgnition.thrustFraction(rangeTime: c.range(t)) }
        guard c.rebuilt else { return c.vehicle.flow }
        return Self.flow(at: t, cutoffs: Array(cutoffs.values), engines: c.vehicle.exits.count)
    }

    /// `engines` F-1s' mean flow fraction at `t` with `cutoffs`, after first motion.
    static func flow(at t: Epoch, cutoffs: [Epoch], engines: Int) -> Double {
        guard engines > 0 else { return 0 }
        let lost = cutoffs.reduce(0.0) { $0 + min(1, max(0, (t - $1) / tailOff)) }
        return max(0, Double(engines) - lost) / Double(engines)
    }

    /// The exits' climb at `t`: none before first motion; between the last
    /// frame's and this one's linearly; on a rebuilt history, uniformly
    /// accelerated from first motion: through this frame's climb while the
    /// pitch program has not started, at `LiftoffRise`'s acceleration after.
    func climb(_ c: Context, _ t: Epoch, previous: Double?) -> Double {
        guard t > c.firstMotion else { return 0 }
        let now = c.vehicle.climb
        if let p = previous, !c.rebuilt, c.now > c.from {
            let u = min(1, max(0, (t - c.from) / (c.now - c.from)))
            return p + (now - p) * u
        }
        let d = c.now - c.firstMotion, tau = min(t - c.firstMotion, d)
        guard d > LiftoffRise.programStart else {
            let u = tau / max(d, 1e-9)
            return now * u * u
        }
        return min(now, LiftoffRise.rise(after: tau))
    }

    /// Emits the particles a source gives over `start`...`end` (by default
    /// the frame's interval), with their true ages at the frame: in slices
    /// of at most `longest` s (at most `maxSlices`), each one request from
    /// `make`, its count `expected` over the slice plus what the slices
    /// before left over. Only the last `lifetime` is covered: what was born
    /// before it is dead.
    func emitSlices(_ key: String, _ c: inout Context, lifetime: ClosedRange<Double>, from start: Epoch? = nil,
                    to end: Epoch? = nil, longest: Double = 0.5, maxSlices: Int = 24,
                    expected: (Epoch, Epoch) -> Double, make: (Epoch, Epoch) -> EmitRequest?) {
        let a = max(start ?? c.from, c.now + -lifetime.upperBound), b = min(end ?? c.now, c.now)
        guard b > a else { return }
        let n = min(maxSlices, max(1, Int(((b - a) / longest).rounded(.up))))
        let h = (b - a) / Double(n)
        for i in 0..<n {
            let s = a + Double(i) * h, e = i == n - 1 ? b : a + Double(i + 1) * h
            let x = expected(s, e) + (carry[key] ?? 0)
            let count = Int(x.rounded(.down))
            carry[key] = x - Double(count)
            guard count > 0, var r = make(s, e) else { continue }
            r.count = count
            r.ages = (c.now - e)...(c.now - s)
            r.lifetime = lifetime
            r.seed = nextSeed(key)
            c.frame.emit(r)
        }
    }

    func nextSeed(_ key: String) -> UInt32 {
        serial += 1
        return ParticleRandom.seed(key, serial)
    }

    /// The pad's anchor, made on first use.
    func anchor(_ c: inout Context) -> EffectAnchorID? {
        if let a = c.anchor { return a }
        if let a = pad, c.frame.anchorState(a) != nil {
            c.anchor = a
            return a
        }
        pad = c.frame.bodyFixedAnchor(at: c.site)
        c.anchor = pad
        return pad
    }

    /// The air's temperature at the deck, K.
    func airTemperature(_ c: Context) -> Double {
        let h = c.site.placement.height
        return c.body.air.map { $0.sample(altitude: h).temperature } ?? 288
    }

    /// Simpson's rule for a rate over `s`...`e`.
    static func integral(_ s: Epoch, _ e: Epoch, _ rate: (Epoch) -> Double) -> Double {
        let mid = s + 0.5 * (e - s)
        return (e - s) * (rate(s) + 4 * rate(mid) + rate(e)) / 6
    }

    // MARK: Pad exhaust and deluge

    func padExhaust(_ c: inout Context, _ m: Materials, previousClimb: Double?) {
        let ctx = c
        let up = c.toAnchor * .unitZ
        func shares(_ t: Epoch) -> PadExhaust.Shares {
            PadExhaust.shares(exitHeight: PadExhaust.exitHeightOnPad + climb(ctx, t, previous: previousClimb),
                              radius: ctx.vehicle.clusterRadius)
        }
        // Each exit's exhaust and steam, out of the trench at grade.
        for (k, exit) in PadExhaust.trenchExits.enumerated() {
            let origin = c.toAnchor * exit.position
            let axis = (c.toAnchor * (exit.direction + Vec3(0, 0, 0.15))).normalized
            for steam in [false, true] {
                let rate = steam ? PadExhaust.trenchSteamRate : PadExhaust.trenchPuffRate
                let life = steam ? ParticleLifetimes.deluge : ParticleLifetimes.padExhaust
                guard let a = anchor(&c) else { return }
                emitSlices("trench \(k) \(steam)", &c, lifetime: life, to: c.firstMotion + Self.padWindow,
                           maxSlices: c.rebuilt ? 48 : 24,
                           expected: { s, e in Self.integral(s, e) { rate * self.flow(ctx, $0) * shares($0).trench } },
                           make: { _, _ in
                               var r = EmitRequest(anchor: a, material: steam ? m.deluge : m.padExhaust, count: 0)
                               r.origin = origin
                               r.axis = axis
                               r.shape = .disc(radius: exit.radius * 0.8)
                               r.direction = .axis(spread: 0.3)
                               r.speed = steam ? 60...120 : 70...150
                               r.radius = steam ? 5...8 : 6...10
                               r.temperature = steam ? 380 : 700
                               return r
                           })
            }
        }
        // Onto the deck, once the envelope outgrows the opening, with the
        // deck deluge's steam from first motion.
        for steam in [false, true] {
            let life = steam ? ParticleLifetimes.deluge : ParticleLifetimes.padExhaust
            guard let a = anchor(&c) else { return }
            emitSlices("deck \(steam)", &c, lifetime: life, to: c.firstMotion + Self.padWindow,
                       maxSlices: c.rebuilt ? 48 : 24,
                       expected: { s, e in
                           Self.integral(s, e) { t in
                               let water = steam ? PadExhaust.deckWater(sinceFirstMotion: t - ctx.firstMotion) / 50_000 : 1
                               return (steam ? PadExhaust.deckSteamRate : PadExhaust.deckPuffRate) * water
                                   * self.flow(ctx, t) * shares(t).deck
                           }
                       },
                       make: { s, e in
                           let t = s + 0.5 * (e - s)
                           let z = PadExhaust.exitHeightOnPad + self.climb(ctx, t, previous: previousClimb)
                           let r0 = max(PadExhaust.envelopeRadius(atDeckFrom: z, radius: ctx.vehicle.clusterRadius),
                                        PadExhaust.openingHalf)
                           // Under the vehicle on a frame after another; on the
                           // pad's axis in a rebuilt history, where the
                           // vehicle was while it was low enough to reach.
                           let centre = ctx.rebuilt ? Vec3.zero
                               : ctx.vehicle.exits.reduce(Vec3.zero) { $0 + $1.centre } * (1 / Double(ctx.vehicle.exits.count))
                           var r = EmitRequest(anchor: a, material: steam ? m.deluge : m.padExhaust, count: 0)
                           r.origin = ctx.toAnchor * Vec3(centre.x, centre.y, 2)
                           r.axis = up
                           r.shape = .ring(radius: r0, width: 2)
                           r.direction = .radial(spread: 0.25)
                           r.speed = steam ? 30...70 : 40...90
                           r.velocity = up * 4
                           r.radius = steam ? 4...7 : 5...8
                           r.temperature = steam ? 380 : 800
                           return r
                       })
        }
    }

    // MARK: Cold vapour

    /// Where a point of the vehicle (body axes from its centre of mass) was
    /// and how it moved, for a source on it, and the vehicle's axis (body
    /// +x) in the anchor:
    /// - before first motion, standing on the pad: the point's height on it
    ///   above the exits' plane, on the pad's axis;
    /// - on a frame after another, the scene's placement;
    /// - on a rebuilt history, uniformly accelerated straight up through
    ///   this frame's place: near enough while the vehicle is low (the
    ///   vapour streams for `vapourWindow` after first motion, its puffs
    ///   live 12 s);
    /// - on a rebuilt history after the pitch program for a `recent`
    ///   source, of which only the last second is rebuilt (the frost), the
    ///   vehicle's own velocity now (its acceleration is not known on a
    ///   frame with none before: none is taken).
    struct SourceMotion {
        var origin: Vec3
        var velocity: Vec3
        var acceleration: Vec3
        var axis: Vec3
    }

    func motion(_ point: Vec3, _ c: inout Context, before firstMotion: Bool, recent: Bool = false) -> SourceMotion? {
        guard let a = anchor(&c), let p = c.frame.place(point, of: c.vehicle.vessel, in: a) else { return nil }
        let up = c.toAnchor * .unitZ
        if firstMotion {
            let exits = ExhaustTrail.exitCentroid(c.vehicle.vessel) ?? point
            let height = PadExhaust.exitHeightOnPad + (point.x - exits.x)
            return SourceMotion(origin: c.toAnchor * Vec3(0, 0, height), velocity: .zero, acceleration: .zero, axis: up)
        }
        let axis = p.direction(.unitX)
        guard c.rebuilt else {
            return SourceMotion(origin: p.position, velocity: p.velocity, acceleration: p.acceleration, axis: axis)
        }
        let d = c.now - c.firstMotion
        guard d > 0 else { return SourceMotion(origin: p.position, velocity: .zero, acceleration: .zero, axis: axis) }
        if recent && d > LiftoffRise.programStart {
            return SourceMotion(origin: p.position, velocity: p.velocity, acceleration: .zero, axis: axis)
        }
        let accel = 2 * c.vehicle.climb / (d * d)
        return SourceMotion(origin: p.position, velocity: up * (accel * d), acceleration: up * accel, axis: axis)
    }

    /// The vapour's strength at `t`: steady on the pad, decaying from first
    /// motion, gone after `vapourWindow`.
    static func vapourStrength(_ t: Epoch, firstMotion: Epoch) -> Double {
        let s = t - firstMotion
        guard s < vapourWindow else { return 0 }
        return s <= 0 ? 1 : exp(-s / vapourDecay)
    }

    /// The LOX tank fog's puffs a second on the pad, and an in-flight
    /// umbilical's (L); the burst at each umbilical's disconnection.
    public static let fogRate = 24.0
    public static let umbilicalTrickle = 2.0
    public static let umbilicalStreamRate = 14.0
    public static let umbilicalBurst = 30

    func vapour(_ c: inout Context, _ m: Materials) {
        let cold = airTemperature(c) - 25
        let ctx = c
        // On a rebuilt history the vapour on the pad goes back its lifetime:
        // it was streaming long before the ignition.
        let start: Epoch? = c.rebuilt ? c.now + -ParticleLifetimes.vapour.upperBound : nil
        // Fog off the S-IC LOX tank's frost, sinking along the skin.
        if let zone = Frost.zones.first(where: { $0.stage == .sIC && $0.name == "LOX tank" }) {
            let inch = 0.0254
            let mid = 0.5 * (zone.stations.lowerBound + zone.stations.upperBound) * inch
            let point = c.vehicle.vessel.structureOrigin + Vec3(mid, 0, 0)
            let length = (zone.stations.upperBound - zone.stations.lowerBound) * inch
            for before in [true, false] {
                guard let s = motion(point, &c, before: before), let a = c.anchor else { return }
                emitSlices("fog \(before)", &c, lifetime: ParticleLifetimes.vapour,
                           from: before ? start : max(start ?? c.from, c.firstMotion),
                           to: before ? c.firstMotion : nil, longest: 1,
                           expected: { s, e in
                               Self.integral(s, e) { Self.fogRate * Self.vapourStrength($0, firstMotion: ctx.firstMotion) }
                           },
                           make: { _, _ in
                               var r = EmitRequest(anchor: a, material: m.coldVapour, count: 0)
                               r.origin = s.origin
                               r.axis = s.axis
                               r.shape = .band(radius: zone.radius * inch + 0.3, height: length)
                               r.direction = .radial(spread: 0.6)
                               r.speed = 0.2...1.0
                               r.velocity = s.axis * -1.5
                               r.sourceVelocity = s.velocity
                               r.sourceAcceleration = s.acceleration
                               r.radius = 0.8...1.6
                               r.temperature = cold
                               return r
                           })
            }
        }
        // The in-flight umbilicals (arms 4-8): a trickle on the pad, a burst
        // at disconnection (the liftoff switch), then a decaying stream as
        // their carriers swing away.
        let disconnect = LaunchCountdown.epoch(c.countdown.liftoffSwitch, in: c.countdown)
        for arm in LC39A.swingArms where arm.inFlight {
            guard let a = anchor(&c) else { return }
            let origin = c.toAnchor * Vec3(arm.vehicleRadius + 0.6, arm.offset, arm.height - 1)
            func request(_ count: Int) -> EmitRequest {
                var r = EmitRequest(anchor: a, material: m.coldVapour, count: count)
                r.origin = origin
                r.shape = .ball(radius: 0.6)
                r.direction = .axis(spread: .pi)
                r.speed = 1...4
                r.radius = 0.5...1.1
                r.lifetime = ParticleLifetimes.vapour
                r.temperature = cold - 10
                return r
            }
            emitSlices("umbilical \(arm.number)", &c, lifetime: ParticleLifetimes.vapour, from: start, longest: 1,
                       expected: { s, e in Self.integral(s, e) { Self.umbilicalRate(at: $0, disconnect: disconnect) } },
                       make: { _, _ in request(0) })
            // The burst, once: in the frame whose interval holds it, or in
            // a rebuilt history that does.
            if disconnect <= c.now && (disconnect > c.from || c.rebuilt)
                && c.now - disconnect < ParticleLifetimes.vapour.upperBound {
                var r = request(Self.umbilicalBurst)
                r.ages = 0...0.4
                r.speed = 2...7
                r.radius = 0.6...1.4
                r.seed = nextSeed("umbilical burst \(arm.number)")
                c.frame.burst(r, at: disconnect)
            }
        }
    }

    /// An in-flight umbilical's vapour puffs a second at `t`.
    static func umbilicalRate(at t: Epoch, disconnect: Epoch) -> Double {
        let s = t - disconnect
        if s < 0 { return umbilicalTrickle }
        return s < vapourWindow ? umbilicalStreamRate * exp(-s / vapourDecay) : 0
    }

    // MARK: Frost

    /// Visual particles a kilogram of frost shed makes (L, the budget): of
    /// flakes, and of slabs.
    public static let flakesPerKilogram = 20.0
    public static let slabsPerKilogram = 3.0

    /// Frost shed from `stage` between `t0` and `t1` (s from first motion),
    /// kg: FrostShedding's decay after first motion; its burst spread over
    /// the thrust buildup, as the ignition's shaking sheds it (L), so the
    /// totals are FER Table 20-1's.
    public static func shed(_ stage: FrostShedding.Band, from t0: Double, to t1: Double, firstMotionRange: Double) -> Double {
        guard t1 > t0 else { return 0 }
        var m = 0.0
        let shed = FrostShedding.initialMass(stage) - FrostShedding.massAtCutoff(stage)
        let lo = PadIgnition.thrustBuildup - firstMotionRange
        if t0 < 0 {
            let whole = PadIgnition.integral(from: PadIgnition.thrustBuildup, to: firstMotionRange)
            let part = PadIgnition.integral(from: max(t0, lo) + firstMotionRange, to: min(t1, 0) + firstMotionRange)
            m += shed * FrostShedding.burstShare * part / whole
        }
        if t1 > 0 { m += FrostShedding.shedMass(stage, from: max(t0, 0), to: t1) }
        return m
    }

    func frost(_ c: inout Context, _ m: Materials) {
        let parts = Set(c.vehicle.vessel.geometry.parts.map(\.name))
        let fm = c.countdown.firstMotion
        guard c.range(c.from) < FrostShedding.cutoffTime + fm || c.rebuilt else { return }
        let ctx = c
        let inch = 0.0254
        for zone in Frost.zones where parts.contains(zone.stage.rawValue) {
            guard let band = FrostShedding.Band(rawValue: zone.stage.rawValue) else { continue }
            let share = zone.weightedArea / Frost.weightedArea(zone.stage)
            let mid = 0.5 * (zone.stations.lowerBound + zone.stations.upperBound) * inch
            let point = c.vehicle.vessel.structureOrigin + Vec3(mid, 0, 0)
            let length = (zone.stations.upperBound - zone.stations.lowerBound) * inch
            for before in [true, false] {
                guard let s = motion(point, &c, before: before, recent: true), let a = c.anchor else { return }
                // In flight a rebuilt history keeps only its last second:
                // the path before the frame is not known there.
                var start = before ? c.from : max(c.from, c.firstMotion)
                if c.rebuilt && !before && c.now - c.firstMotion > LiftoffRise.programStart {
                    start = max(start, c.now + -Self.rebuiltFrostHistory)
                }
                for slab in [false, true] {
                    let perKg = slab ? (1 - FrostShedding.flakeShare) * Self.slabsPerKilogram
                        : FrostShedding.flakeShare * Self.flakesPerKilogram
                    emitSlices("frost \(zone.name) \(before) \(slab)", &c,
                               lifetime: slab ? ParticleLifetimes.slab : ParticleLifetimes.flake, from: start,
                               to: before ? c.firstMotion : nil, longest: 1,
                               expected: { s, e in
                                   perKg * share * Self.shed(band, from: ctx.range(s) - fm, to: ctx.range(e) - fm,
                                                             firstMotionRange: fm)
                               },
                               make: { _, _ in
                                   var r = EmitRequest(anchor: a, material: slab ? m.iceSlab : m.iceFlake, count: 0)
                                   r.origin = s.origin
                                   r.axis = s.axis
                                   r.shape = .band(radius: zone.radius * inch + 0.05, height: length)
                                   r.direction = .radial(spread: 0.8)
                                   r.speed = slab ? 0.5...2 : 0.5...3
                                   r.sourceVelocity = s.velocity
                                   r.sourceAcceleration = s.acceleration
                                   r.radius = slab ? (FrostShedding.slabSizes.lowerBound / 2)...(FrostShedding.slabSizes.upperBound / 2)
                                       : (FrostShedding.flakeDiameters.lowerBound / 2)...(FrostShedding.flakeDiameters.upperBound / 2)
                                   return r
                               })
                }
            }
        }
    }
}

/// P4's particle lifetimes, s (L).
public enum ParticleLifetimes {
    public static let padExhaust = 150.0...240.0
    public static let deluge = 100.0...180.0
    public static let vapour = 6.0...12.0
    public static let flake = 25.0...45.0
    public static let slab = 40.0...90.0
}
