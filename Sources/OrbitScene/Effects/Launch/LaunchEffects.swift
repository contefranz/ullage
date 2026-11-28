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
        public var groundCloud, startSmoke, ignitionFlash: ParticleMaterialID
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
    /// The ground cloud's two jets and clouds (`GroundCloud`), from the first
    /// start command.
    private(set) var cloud: GroundCloud?
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
                              trail: (0..<ExhaustTrail.palette).map { table.register(LaunchMaterials.trail($0)) },
                              groundCloud: table.register(LaunchMaterials.groundCloud),
                              startSmoke: table.register(LaunchMaterials.startSmoke),
                              ignitionFlash: table.register(LaunchMaterials.ignitionFlash))
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
        cloud = nil
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
        let ignition: Ignition
        let firstMotion: Epoch
        /// Where the pad's windows count from: first motion, or a scrubbed
        /// launch's cutoff (the engines stopped there, nothing lifts off),
        /// or for a stack still on the rods now while an F-1 burns there,
        /// where the last stopped after.
        let windowStart: Epoch
        let now: Epoch
        /// Where this frame's interval starts: the last frame's epoch, or on
        /// a rebuilt history the thrust buildup's.
        let from: Epoch
        let rebuilt: Bool
        let vehicle: Vehicle
        /// Site axes to the anchor's (the body's).
        let toAnchor: Mat3
        var anchor: EffectAnchorID?
        /// The controlled release the vehicle rose against (the live
        /// count's; none for the first-motion stands), and when its pitch
        /// program starts after first motion as a rebuilt climb has it
        /// (`LiftoffRise`).
        var release: LiftoffRise.Release? { ignition.record?.plan.controlledRelease }
        let programStart: Double

        func range(_ t: Epoch) -> Double { countdown.rangeTime(at: t) }
    }

    /// The S-IC's ignition as the scene knows it: the terminal count's
    /// record (each engine's start and thrust as the core ran them), or, for
    /// a scene without a count, AS-506's plan on the historic countdown.
    struct Ignition {
        let plan: TerminalCount.Plan
        let record: TerminalCount.Record?
        /// Range zero: the count's (while it holds, where it would fall now).
        let zero: Epoch

        init(scene: RenderScene, countdown: LC39A.Countdown) {
            record = scene.launch
            plan = scene.launch?.plan ?? PadIgnition.plan
            zero = countdown.rangeZero
        }

        /// Engine `i`'s thrust over full at `t`.
        func fraction(_ i: Int, at t: Epoch) -> Double {
            record.map { $0.fraction(i, at: t) } ?? plan.fraction(i, rangeTime: t - zero)
        }

        /// The engines' mean thrust fraction at `t`.
        func meanFraction(at t: Epoch) -> Double {
            plan.starts.indices.reduce(0) { $0 + fraction($1, at: t) } / Double(plan.starts.count)
        }

        /// Engine `i`'s start command and ignition; nil before the count
        /// runs, or for an engine that never started.
        func start(_ i: Int) -> (command: Epoch, ignition: Epoch)? {
            if let r = record { return r.start(i) }
            return (zero + plan.starts[i].command, zero + plan.starts[i].ignition)
        }

        /// Where engine `i` stopped while the stack stood, if it did.
        func stop(_ i: Int) -> Epoch? { record?.stop(i) }

        /// When a scrubbed launch was cut off (it never released).
        var scrubbed: Epoch? { record.flatMap { $0.released == nil ? $0.scrubbed : nil } }
        /// When the hold-down arms released, if they have.
        var released: Epoch? { record?.released }

        /// True at `t` while the released stack stood on the rods: after the
        /// release and before its first motion (none when it lifted at the
        /// release, as five F-1s lift it).
        func onTheRods(at t: Epoch) -> Bool {
            guard let r = record, let released = r.released, t > released else { return false }
            return r.firstMotion.map { t < $0 } ?? true
        }

        /// While the released stack stands on the rods, its first motion not
        /// yet found: `now` while an F-1 still burns there, else where the
        /// last stopped (lost, run dry or shut down: the record's stops), or
        /// the release. Nil otherwise.
        func lastBurning(at now: Epoch) -> Epoch? {
            guard let r = record, let released = r.released, r.firstMotion == nil else { return nil }
            var last = released
            for i in plan.starts.indices {
                guard let stop = r.stop(i) else { return now }
                last = max(last, stop)
            }
            return last
        }

        /// The first start command, and the first ignition; nil while the count holds.
        var firstCommand: Epoch? { plan.starts.indices.compactMap { start($0)?.command }.min() }
        var firstIgnition: Epoch? { plan.starts.indices.compactMap { start($0)?.ignition }.min() }
    }

    /// The launch vehicle as this frame sees it.
    struct Vehicle {
        let vessel: RenderScene.Vessel
        /// The S-IC's nozzle exits, site frame, gimbals at null, and each by
        /// its engine's name.
        let exits: [(centre: Vec3, radius: Double)]
        let exitByEngine: [String: (centre: Vec3, radius: Double)]
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
        // The pad stands in the simulation's count when it has one (the
        // site's countdown runs on it), else in the historic launch's.
        let countdown = site.countdown(at: now)
        let ignition = Ignition(scene: f.scene, countdown: countdown)
        let range = countdown.rangeTime(at: now)
        let firstMotion = LaunchCountdown.epoch(countdown.firstMotion, in: countdown)
        // The pad's windows run from first motion; a scrub's from its
        // cutoff, and those of a stack released but still standing on the
        // rods (its first motion not yet found) from now while an F-1 burns
        // there, then from where the last stopped: so they only ever move
        // later, and close once nothing burns.
        let windowStart = ignition.scrubbed
            ?? (countdown.firstMotion.isFinite ? firstMotion : ignition.lastBurning(at: now) ?? firstMotion)
        // The loaded stack vents while it stands, whatever the count did (a
        // scrubbed one too): its fog and umbilicals' trickle, until their
        // decay after first motion is over.
        let venting = now - firstMotion < Self.padWindow + ParticleLifetimes.padExhaust.upperBound
        // A history is rebuilt only on the first frame after a reset; later
        // frames carry on from the last one's epoch, whatever happened in
        // between (a staging's new vessels, a stretch with no vehicle). With
        // a count the pad's vapour streams from the count's start; without
        // one the effects start at the first engine's start command.
        let last = seen
        let open = now - windowStart < Self.window
        guard f.scene.launch != nil || range >= PadIgnition.firstCommand, open || venting,
              let vehicle = Self.vehicle(in: f.scene, site: site)
        else {
            seen = Seen(epoch: now, vessel: nil, climb: 0)
            return
        }
        seen = Seen(epoch: now, vessel: vehicle.vessel.id, climb: vehicle.climb)
        let rebuilt = last == nil
        let from = last.map { min($0.epoch, now) } ?? (ignition.firstCommand.map { min($0, now) } ?? now)
        guard now > from || rebuilt else { return }
        let toAnchor = body.orientation.icrfToBody * site.orientation
        var c = Context(frame: f, site: site, body: body, countdown: countdown, ignition: ignition,
                        firstMotion: firstMotion, windowStart: windowStart, now: now, from: from, rebuilt: rebuilt,
                        vehicle: vehicle, toAnchor: toAnchor, anchor: nil,
                        programStart: LiftoffRise.programStart(release: ignition.record?.plan.controlledRelease))
        let previousClimb = last?.vessel == vehicle.vessel.id ? last?.climb : nil
        if open, now - windowStart < Self.cloudWindow + ParticleLifetimes.groundCloud.upperBound {
            if now - windowStart < Self.padWindow + ParticleLifetimes.padExhaust.upperBound {
                ignitionFlashes(&c, m)
                startSmoke(&c, m)
                padExhaust(&c, m, previousClimb: previousClimb)
            }
            if venting { vapour(&c, m) }
            groundCloud(&c, m, previousClimb: previousClimb)
        } else if venting {
            vapour(&c, m)
        }
        guard open else { return }
        frost(&c, m)
        trail.update(&c, materials: m.trail, owner: self)
    }

    /// The vessel carrying the S-IC (the stack until staging), and its
    /// nozzles and flow.
    static func vehicle(in scene: RenderScene, site: RenderScene.Site) -> Vehicle? {
        guard let v = scene.vessels.first(where: { $0.geometry.parts.contains { $0.name == "S-IC" } }) else { return nil }
        let toSite = site.orientation.transposed
        var exits: [(centre: Vec3, radius: Double)] = []
        var byEngine: [String: (centre: Vec3, radius: Double)] = [:]
        for p in v.geometry.parts where p.name == "S-IC" {
            for t in p.thrusters where t.name.hasPrefix("S-IC engine") {
                guard let n = v.geometry.nozzles[t.key] else { continue }
                let world = v.position + v.attitude.rotate(v.structureOrigin + n.exit)
                exits.append((toSite * (world - site.origin), n.radius))
                byEngine[t.name] = exits.last!
            }
        }
        guard !exits.isEmpty else { return nil }
        let height = exits.reduce(0) { $0 + $1.centre.z } / Double(exits.count)
        let kerosene = scene.emitters.filter { $0.vesselID == v.id && $0.style == .kerosene && !$0.isJet && !$0.isSolid }
        let flow = kerosene.reduce(0) { $0 + min(1, $1.thrustFraction / seaLevelThrustFraction) } / Double(exits.count)
        let own = scene.emitters.filter { $0.vesselID == v.id }
        return Vehicle(vessel: v, exits: exits, exitByEngine: byEngine, exitHeight: height,
                       climb: max(0, height - PadExhaust.exitHeightOnPad), flow: flow,
                       clusterRadius: PadExhaust.clusterRadius(exits: exits),
                       trailHead: PlumeAirflow.trailHandover(own),
                       airspeed: own.first { $0.name.hasPrefix("S-IC engine") }?.relativeWind.length ?? 0)
    }

    // MARK: Time

    /// The five F-1s' flow fraction at `t`: the ignition's while the
    /// stack was held down (before first motion, and on the rods only up to
    /// the release); after it the scene's on a frame after another (a
    /// cutoff's tail-off, and a relit engine the count keeps stopped,
    /// included), and on a rebuilt history the journal's: each engine at
    /// full flow until its recorded cutoff, tailing off linearly over
    /// `tailOff`, none from one the count lost by the release.
    func flow(_ c: Context, _ t: Epoch) -> Double {
        if t <= c.firstMotion, !c.ignition.onTheRods(at: t) { return c.ignition.meanFraction(at: t) }
        guard c.rebuilt else { return c.vehicle.flow }
        return Self.flow(at: t, cutoffs: rebuiltCutoffs(c), engines: c.vehicle.exits.count)
    }

    /// The cutoffs a rebuilt history's flow follows after the release: the
    /// journal's, and −∞ for each engine the count lost by the release
    /// (after commit): the journal has none for it, as only the release
    /// put the F-1s under the throttle, and it never fired after.
    func rebuiltCutoffs(_ c: Context) -> [Epoch] {
        var all = Array(cutoffs.values)
        guard let r = c.ignition.record, let released = r.released else { return all }
        for (i, s) in r.plan.starts.enumerated() where cutoffs[s.engine] == nil {
            if let stop = r.stop(i), stop <= released { all.append(Epoch(tdbSecondsPastJ2000: -.infinity)) }
        }
        return all
    }

    /// `engines` F-1s' mean flow fraction at `t` with `cutoffs`, after the release.
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
        guard d > c.programStart else {
            let u = tau / max(d, 1e-9)
            return now * u * u
        }
        return min(now, LiftoffRise.rise(after: tau, release: c.release))
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

    // MARK: Pad exhaust: the trench's jets and the deck's

    /// The trench jets' particles: eddies of half the jet's half-width,
    /// filling this share of the volume the jet carries out of an exit (L,
    /// the look's density), for `ParticleLifetimes.padExhaust`.
    public static let jetEddy = 0.7
    public static let jetFill = 0.3
    /// The clouds' particles: eddies of this share of a cloud's radius, as
    /// many as fill `cloudFill` of its volume (L).
    public static let cloudEddy = 0.2
    public static let cloudFill = 3.0
    /// The plume stems' eddies, of the jet's half-width at its end (L).
    public static let stemEddy = 0.4
    /// The clouds are filled until this long after first motion, s: they
    /// have stabilised and drift off by then (Apollo 16's in 6 minutes,
    /// TM X-2935).
    public static let cloudWindow = 480.0

    /// What reaches the ground at `t` (`GroundCloud.Sources`): the F-1s'
    /// flow and thrust (`LiftoffRise`'s at full, times their fraction:
    /// the count's before first motion), the shares with the climb, and the
    /// deluge's water.
    func sources(_ c: Context, _ t: Epoch, previousClimb: Double?) -> GroundCloud.Sources {
        let fraction = flow(c, t)
        let shares = PadExhaust.shares(exitHeight: PadExhaust.exitHeightOnPad + climb(c, t, previous: previousClimb),
                                       radius: c.vehicle.clusterRadius)
        let gpm = GroundCloud.gallon / GroundCloud.minute
        return GroundCloud.Sources(exhaust: LiftoffRise.flow * fraction, thrust: LiftoffRise.thrust * fraction,
                                   trench: shares.trench, deck: shares.deck,
                                   trenchWater: PadExhaust.trenchWater * gpm,
                                   deckWater: PadExhaust.deckWater(sinceFirstMotion: t - c.firstMotion) * gpm)
    }

    /// The air at the deck: its density and temperature.
    func deckAir(_ c: Context) -> (rho: Double, temperature: Double) {
        let a = c.body.air?.sample(altitude: c.site.placement.height)
        return (a?.density ?? 1.225, a?.temperature ?? 288.15)
    }

    /// The two jets out of the flame trench (`GroundCloud`): round momentum
    /// jets from the deflector, out of each exit at 7.0 √(M/ρ) / x with a
    /// half-width of 0.107 x, hot with the heat their volume carries; and,
    /// once the plume outgrows the ML's opening, the deck's wall jet, radial
    /// from under the vehicle at the same law. Each eddy follows its jet's
    /// similarity solution (`LaunchMaterials.padExhaust`), born with the
    /// jet's speed, size and temperature at the exit and as many a second as
    /// the jet's volume flux fills (`jetFill`).
    func padExhaust(_ c: inout Context, _ m: Materials, previousClimb: Double?) {
        guard let start = c.ignition.firstIgnition else { return }
        let ctx = c
        let up = c.toAnchor * .unitZ
        let air = deckAir(c)
        let x = GroundCloud.exitDistance, b = GroundCloud.jetSpread * x
        let eddy = Self.jetEddy * b, eddyVolume = 4 / 3 * Double.pi * eddy * eddy * eddy
        func jet(_ t: Epoch) -> (speed: Double, rate: Double, temperature: Double) {
            let f = GroundCloud.side(sources(ctx, t, previousClimb: previousClimb), density: air.rho,
                                     ambient: air.temperature)
            let m = f.momentum.squareRoot()
            guard m > 0 else { return (0, 0, air.temperature) }
            let volume = GroundCloud.jetVolume * m * x
            // The heat the jet carries out, in its volume.
            let excess = f.heat / (air.rho * GroundCloud.airHeat * volume)
            return (GroundCloud.jetVelocity * m / x, Self.jetFill * volume / eddyVolume,
                    min(air.temperature + excess, 2_000))
        }
        let now = jet(c.now)
        for (k, exit) in PadExhaust.trenchExits.enumerated() {
            let origin = c.toAnchor * exit.position
            // Out along the trench's floor, which opens to grade.
            let axis = (c.toAnchor * (exit.direction + Vec3(0, 0, 0.15))).normalized
            guard let a = anchor(&c) else { return }
            emitSlices("trench \(k)", &c, lifetime: ParticleLifetimes.padExhaust, from: max(c.from, start),
                       to: c.windowStart + Self.padWindow, maxSlices: c.rebuilt ? 48 : 24,
                       expected: { s, e in Self.integral(s, e) { jet($0).rate } },
                       make: { s, e in
                           let j = jet(s + 0.5 * (e - s))
                           guard j.speed > 0 else { return nil }
                           var r = EmitRequest(anchor: a, material: m.padExhaust, count: 0)
                           r.origin = origin
                           r.axis = axis
                           r.shape = .disc(radius: exit.radius * 0.8)
                           r.direction = .axis(spread: atan(GroundCloud.jetSpread))
                           r.speed = (0.8 * j.speed)...(1.2 * j.speed)
                           r.radius = (0.8 * eddy)...(1.2 * eddy)
                           r.temperature = j.temperature
                           return r
                       })
        }
        _ = now
        // Onto the deck, once the envelope outgrows the opening: an
        // impinging jet turned radial, its momentum the deck's share of the
        // thrust, from the envelope's edge.
        func deck(_ t: Epoch) -> (speed: Double, rate: Double, r0: Double, temperature: Double) {
            let s = sources(ctx, t, previousClimb: previousClimb)
            guard s.deck > 0, s.exhaust > 0 else { return (0, 0, 0, air.temperature) }
            let z = PadExhaust.exitHeightOnPad + climb(ctx, t, previous: previousClimb)
            let r0 = max(PadExhaust.envelopeRadius(atDeckFrom: z, radius: ctx.vehicle.clusterRadius),
                         PadExhaust.openingHalf)
            let j = Self.deckJet(s, from: r0, density: air.rho, ambient: air.temperature)
            return (j.speed, j.rate, r0, j.temperature)
        }
        guard let a = anchor(&c) else { return }
        emitSlices("deck", &c, lifetime: ParticleLifetimes.padExhaust, from: max(c.from, c.firstMotion),
                   to: c.firstMotion + Self.padWindow, maxSlices: c.rebuilt ? 48 : 24,
                   expected: { s, e in Self.integral(s, e) { deck($0).rate } },
                   make: { s, e in
                       let d = deck(s + 0.5 * (e - s))
                       guard d.speed > 0 else { return nil }
                       // Under the vehicle on a frame after another; on the
                       // pad's axis in a rebuilt history, where the vehicle
                       // was while it was low enough to reach.
                       let centre = ctx.rebuilt ? Vec3.zero
                           : ctx.vehicle.exits.reduce(Vec3.zero) { $0 + $1.centre } * (1 / Double(ctx.vehicle.exits.count))
                       let e = Self.jetEddy * GroundCloud.jetSpread * d.r0
                       var r = EmitRequest(anchor: a, material: m.padExhaust, count: 0)
                       r.origin = ctx.toAnchor * Vec3(centre.x, centre.y, 2)
                       r.axis = up
                       r.shape = .ring(radius: d.r0, width: 2)
                       r.direction = .radial(spread: atan(GroundCloud.jetSpread))
                       r.speed = (0.8 * d.speed)...(1.2 * d.speed)
                       r.radius = (0.8 * e)...(1.2 * e)
                       r.temperature = d.temperature
                       return r
                   })
    }

    /// The deck's wall jet at `s` from `r0` m off the pad's axis, in air of
    /// `rho` and `ambient` K: its speed there, its eddies a second (as many
    /// as fill `jetFill` of its volume flux), and their temperature, hot
    /// with the heat its cloud gets: the deck share's once the deck's water
    /// has boiled (`GroundCloud.fluxes`), in the volume it carries.
    static func deckJet(_ s: GroundCloud.Sources, from r0: Double, density rho: Double, ambient: Double)
        -> (speed: Double, rate: Double, temperature: Double) {
        guard s.deck > 0, s.exhaust > 0, r0 > 0 else { return (0, 0, ambient) }
        let m = (s.thrust * s.deck / rho).squareRoot()
        let volume = GroundCloud.jetVolume * m * r0
        let e = jetEddy * GroundCloud.jetSpread * r0
        let heat = GroundCloud.fluxes(s, lobe: .deck, density: rho, ambient: ambient).heat
        let excess = heat / (rho * GroundCloud.airHeat * volume)
        return (GroundCloud.jetVelocity * m / r0, jetFill * volume / (4 / 3 * .pi * e * e * e),
                min(ambient + excess, 2_000))
    }

    // MARK: The ground cloud

    /// The two clouds the jets feed (`GroundCloud`), integrated on to this
    /// frame (from the first start command after a reset), and filled with
    /// eddies of `cloudEddy` of their radius, born inside them with their
    /// rise and the wind there, expanding with them, each living
    /// `ParticleLifetimes.groundCloud`: as many as keep `cloudFill` of the
    /// volume filled, fewer once the water and soot they carry are spread
    /// too thin to hide what is behind (an optical depth through the cloud
    /// under the eddies' own).
    func groundCloud(_ c: inout Context, _ m: Materials, previousClimb: Double?) {
        guard let origin = c.ignition.firstCommand, origin < c.now else { return }
        if cloud == nil || c.rebuilt || cloud!.origin != origin { cloud = GroundCloud(origin: origin) }
        let ctx = c
        let east = c.site.placement.azimuth, toSite = c.site.orientation.transposed
        let o = c.body.orientation
        let lat = c.site.placement.latitude, lon = c.site.placement.longitude
        let upBF = Vec3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
        let eastBF = Vec3(-sin(lon), cos(lon), 0), northBF = upBF.cross(eastBF)
        let eastSite = toSite * o.toInertial(eastBF), northSite = toSite * o.toInertial(northBF)
        _ = east
        cloud!.advance(to: c.now, sources: { self.sources(ctx, $0, previousClimb: previousClimb) }, air: c.body.air,
                       deckHeight: c.site.placement.height,
                       siteFromEastNorth: { e, n in eastSite * e + northSite * n })
        guard let state = cloud, c.now - c.windowStart < Self.cloudWindow + ParticleLifetimes.groundCloud.upperBound,
              let a = anchor(&c) else { return }
        let life = ParticleLifetimes.groundCloud, stemLife = ParticleLifetimes.stem
        let deck = c.site.placement.height
        func wind(_ e: Double, _ n: Double) -> Vec3 { eastSite * e + northSite * n }
        /// A lobe's eddies to keep alive, its stem's, and how it grows.
        func fill(_ lobe: GroundCloud.Lobe) -> (eddies: Double, stem: Double, growth: Double, feed: Double) {
            guard lobe.volume > 0 else { return (0, 0, 0, 0) }
            let radius = lobe.radius
            let feed = lobe.jet.momentum > 0 ? GroundCloud.jetVolume * lobe.jet.momentum.squareRoot() * lobe.front : 0
            let growth = GroundCloud.thermalEntrainment * abs(lobe.rise) + feed / (4 * .pi * radius * radius)
            // The water and soot it carries, as an optical depth through it.
            let column = 1.5 * LaunchMaterials.cloudExtinction(exhaust: lobe.exhaust, water: lobe.water)
                / (.pi * radius * radius)
            let share = min(1, column * Self.cloudEddy / LaunchMaterials.groundCloud.opticalDepth)
            var stem = 0.0
            if feed > 0, case .trench = lobe.kind, lobe.centre.z - radius > 1 {
                let b = GroundCloud.jetSpread * lobe.front, e = Self.stemEddy * b
                stem = Self.cloudFill * .pi * b * b * (lobe.centre.z - radius) / (4 / 3 * .pi * e * e * e)
            }
            return (share * Self.cloudFill / pow(Self.cloudEddy, 3), stem, growth, feed)
        }
        func births(_ count: Double, _ l: ClosedRange<Double>) -> Double { 2 * count / (l.lowerBound + l.upperBound) }
        for k in state.lobes.indices {
            // Each slice from the lobe as it was then (its last sample on a
            // rebuilt history), placed on to now along its motion then.
            func lobe(_ s: Epoch, _ e: Epoch) -> (time: Epoch, lobe: GroundCloud.Lobe) {
                let then = state.state(at: s + 0.5 * (e - s))
                return (then.time, then.lobes[k])
            }
            func velocity(_ lobe: GroundCloud.Lobe) -> Vec3 {
                let air = GroundCloud.air(ctx.body.air, at: lobe.centre.z, deckHeight: deck, wind: wind)
                return air.wind + Vec3(0, 0, lobe.rise)
            }
            // The stem: the plume rising from the jet's end into the cloud
            // while the jet feeds it, eddies of `stemEddy` of the jet's
            // half-width there, rising with the cloud.
            if case .trench(let side) = state.lobes[k].kind {
                emitSlices("stem \(k)", &c, lifetime: stemLife, from: max(c.from, origin), longest: 1,
                           expected: { s, e in births(fill(lobe(s, e).lobe).stem, stemLife) * (e - s) },
                           make: { s, e in
                               let l = lobe(s, e).lobe
                               let base = l.centre.z - l.radius
                               guard l.volume > 0, base > 1 else { return nil }
                               let b = GroundCloud.jetSpread * l.front, size = Self.stemEddy * b
                               var r = EmitRequest(anchor: a, material: m.groundCloud, count: 0)
                               r.origin = ctx.toAnchor * Vec3(side * l.front + l.drift.x, l.drift.y, 0)
                               r.axis = ctx.toAnchor * .unitZ
                               r.shape = .line(length: base)
                               r.direction = .radial(spread: 0.8)
                               r.speed = 0...max(0, fill(l).growth)
                               r.velocity = ctx.toAnchor * velocity(l)
                               r.radius = (0.8 * size)...(1.2 * size)
                               return r
                           })
            }
            // The cloud's eddies, born moving with it: placed back along its
            // motion by their ages (`sourceVelocity`), from where it would
            // be now at that motion.
            emitSlices("cloud \(k)", &c, lifetime: life, from: max(c.from, origin),
                       to: c.windowStart + Self.cloudWindow, longest: 1,
                       expected: { s, e in births(fill(lobe(s, e).lobe).eddies, life) * (e - s) },
                       make: { s, e in
                           let (time, l) = lobe(s, e)
                           guard l.volume > 0 else { return nil }
                           let radius = l.radius, v = velocity(l)
                           var r = EmitRequest(anchor: a, material: m.groundCloud, count: 0)
                           r.origin = ctx.toAnchor * (l.centre + v * (ctx.now - time))
                           r.axis = ctx.toAnchor * .unitZ
                           r.shape = .ball(radius: radius)
                           r.direction = .radial(spread: 0.6)
                           r.speed = 0...max(0, fill(l).growth)
                           r.sourceVelocity = ctx.toAnchor * v
                           r.radius = (0.8 * Self.cloudEddy * radius)...(1.2 * Self.cloudEddy * radius)
                           return r
                       })
        }
    }

    // MARK: The F-1s' start

    /// The F-1's start: from each engine's start command its gas generator
    /// spins the turbopumps and its fuel-rich turbine exhaust, 2.9 % of the
    /// engine's rated flow at 887 K (`ApolloExhaust.f1`'s film: R-3896-1),
    /// leaves through the nozzle before the chamber lights: dark kerosene
    /// smoke. Falling into the flame trench, it fills the trench and leaves
    /// it as it comes, hot: half up through the ML's opening around the
    /// vehicle, a chimney (rising at about √(g h ΔT/T) for the trench's
    /// depth), half out of the trench's exits at the speed the trench's
    /// section gives its volume flux (L, the split). Eddies of 1.5 m, as
    /// many as fill its volume, until each engine's ignition.
    public static let startSmokeEddy = 1.5

    func startSmoke(_ c: inout Context, _ m: Materials) {
        let spec = ApolloExhaust.f1.spec
        guard let film = spec.film else { return }
        let flow = film.massFraction * ApolloExhaust.f1.ratedFlow
        let air = deckAir(c)
        let density = air.rho * air.temperature / film.temperature   // at the air's pressure
        let eddy = Self.startSmokeEddy
        let volume = flow / density
        let rate = volume / (4 / 3 * .pi * eddy * eddy * eddy)
        let up = c.toAnchor * .unitZ
        let depth = PadExhaust.exitHeightOnPad - PadExhaust.trenchExits[0].position.z
        let chimney = (9.80665 * depth * (film.temperature - air.temperature) / film.temperature).squareRoot()
        let exitArea = 2 * PadExhaust.trenchExits[0].radius * 12.8
        for (i, _) in c.ignition.plan.starts.enumerated() {
            guard let start = c.ignition.start(i), let a = anchor(&c) else { continue }
            let ctx = c
            // Until the chamber lights, or the engine is lost.
            let end = c.ignition.stop(i).map { min($0, start.ignition) } ?? start.ignition
            for outlet in 0..<3 {
                emitSlices("start smoke \(i) \(outlet)", &c, lifetime: ParticleLifetimes.startSmoke,
                           from: max(c.from, start.command), to: end, longest: 0.25,
                           expected: { s, e in (outlet == 0 ? 0.5 : 0.25) * rate * (e - s) },
                           make: { _, _ in
                               var r = EmitRequest(anchor: a, material: m.startSmoke, count: 0)
                               if outlet == 0 {
                                   r.origin = ctx.toAnchor * Vec3(0, 0, 1)
                                   r.axis = up
                                   r.shape = .ring(radius: 0.8 * PadExhaust.openingHalf, width: 4)
                                   r.direction = .axis(spread: 0.4)
                                   r.speed = (0.5 * chimney)...chimney
                               } else {
                                   let exit = PadExhaust.trenchExits[outlet - 1]
                                   r.origin = ctx.toAnchor * exit.position
                                   r.axis = (ctx.toAnchor * (exit.direction + Vec3(0, 0, 0.15))).normalized
                                   r.shape = .disc(radius: exit.radius * 0.8)
                                   r.direction = .axis(spread: 0.5)
                                   let out = 0.25 * volume / exitArea
                                   r.speed = out...(2 * out)
                               }
                               r.radius = (0.7 * eddy)...(1.3 * eddy)
                               r.temperature = film.temperature
                               return r
                           })
            }
        }
    }

    /// The F-1's ignition: the hypergolic igniter's TEA-TEB (triethyl-
    /// aluminium and triethylborane) bursts into the chamber and lights the
    /// LOX there, its boron burning green (BO₂'s bands about 545 nm), for
    /// the fraction of a second before the RP-1 takes over: one flash at
    /// each engine's ignition, from the count.
    public static let flashCount = 16

    func ignitionFlashes(_ c: inout Context, _ m: Materials) {
        let down = c.toAnchor * -Vec3.unitZ
        // Above 10× a flash is held into the frame after it ended (P3's
        // `EffectTimeRules.spawns`), so one a frame's interval old still shows.
        let clock = c.frame.clock
        let oldest = ParticleLifetimes.ignitionFlash.upperBound + (clock.holdsFlashes ? max(clock.dt, 0) : 0)
        for (i, s) in c.ignition.plan.starts.enumerated() {
            guard let start = c.ignition.start(i), let exit = c.vehicle.exitByEngine[s.engine] else { continue }
            let t = start.ignition
            // An engine lost before its chamber lit never flashes.
            if let stop = c.ignition.stop(i), stop <= t { continue }
            guard t <= c.now, t > c.from || c.rebuilt, c.now - t < oldest, let a = anchor(&c) else { continue }
            var r = EmitRequest(anchor: a, material: m.ignitionFlash, count: Self.flashCount)
            r.origin = c.toAnchor * (c.rebuilt ? Vec3(exit.centre.x, exit.centre.y, PadExhaust.exitHeightOnPad)
                                               : exit.centre)
            r.axis = down
            r.shape = .disc(radius: exit.radius * 0.8)
            r.direction = .axis(spread: 0.4)
            r.speed = 30...80
            r.radius = 0.6...1.4
            r.lifetime = ParticleLifetimes.ignitionFlash
            r.ages = 0...0.05
            r.seed = nextSeed("ignition flash \(i)")
            c.frame.burst(r, at: t)
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
        if recent && d > c.programStart {
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
                if c.rebuilt && !before && c.now - c.firstMotion > c.programStart {
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
    /// The trench's and the deck's jets: they feed the clouds, which carry
    /// on as `groundCloud`'s eddies.
    public static let padExhaust = 12.0...20.0
    public static let groundCloud = 20.0...32.0
    public static let startSmoke = 6.0...10.0
    public static let ignitionFlash = 0.2...0.35
    public static let stem = 8.0...14.0
    public static let deluge = 100.0...180.0
    public static let vapour = 6.0...12.0
    public static let flake = 25.0...45.0
    public static let slab = 40.0...90.0
}
