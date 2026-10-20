import Foundation
import OrbitCore

/// DEORBIT: a retrograde deorbit burn, planned like an Apollo P30 PAD with
/// `DeorbitPlanner` (impulsive, along the anti-velocity, vacuum coast with
/// J2):
/// - the time of ignition (TIG), set at the next apsis or moved by steps,
///   and the time to it; the TIG shown is the burn's centred ignition (the
///   impulsive time less half the burn), when the pilot lights the engine;
/// - the target: the inertial flight-path angle at entry interface (EI,
///   400,000 ft) or the perigee altitude after the burn;
/// - Δv, in total and per local-vertical axis (X forward along the
///   horizontal velocity, Y opposite the orbit normal, Z down);
/// - the burn time and propellant on the active stage's main engines;
/// - the apoapsis and periapsis altitudes after the burn (radii less the
///   equatorial radius, as ORBIT gives them);
/// - the predicted EI: time, speed, angle and place.
///
/// SET loads the Δv into the vessel's ΔV counter (`DeltaVCounting`, the
/// Apollo SCS's EMS counter), which cuts the engine off when it has counted
/// the Δv down, and the burn into the navball's manoeuvre marker
/// (`ActiveManeuver`); CLR clears both. Both do nothing on a vessel
/// without one.
/// Once TIG has passed, the page plans from now: its Δv is the Δv still to
/// go to the target.
public final class DeorbitMFD: MFDMode {
    public enum Target: Hashable, Sendable {
        /// The inertial flight-path angle at EI, rad (negative).
        case entryAngle(Double)
        /// The perigee altitude after the burn, m (radius less the
        /// equatorial radius).
        case perigeeAltitude(Double)
    }

    public static let steps: [Double] = [10, 60, 600]
    public static let defaultLead = 600.0

    /// The impulsive TIG; nil until the page first plans, which sets it
    /// `defaultLead` ahead, on a whole minute.
    public var ignition: Epoch?
    public var step = 60.0
    /// Apollo 7's EI was at -1.759° (68-FM-184 Table IX(b)).
    public static let defaultEntryAngle = -1.75 * Double.pi / 180
    public var target = Target.entryAngle(defaultEntryAngle)
    /// What the last page planned, for SET.
    public private(set) var plan: DeorbitPlanner.Plan?
    /// The centred ignition of the last plan made before TIG: the time the
    /// page keeps showing once the burn has started.
    public private(set) var centredIgnition: Epoch?

    public init() {}

    public var id: MFDModeID { .deorbit }

    public func buttons(_ c: MFDContext?) -> [MFDButton?] {
        let counter = c?.deltaVCounter != nil
        return [
            MFDButton("AP", .a, "TIG at the next apoapsis"),
            MFDButton("PE", .e, "TIG at the next periapsis"),
            MFDButton("T-", .minus, "TIG a step earlier"),
            MFDButton("T+", .equal, "TIG a step later"),
            MFDButton("STP", .i, "TIG step 10s/1m/10m"),
            nil,
            MFDButton("TGT", .g, "Target: EI angle or HP"),
            MFDButton("V-", .leftBracket, "Target down a step"),
            MFDButton("V+", .rightBracket, "Target up a step"),
            nil,
            MFDButton("SET", .s, "Load the dV counter", active: counter && plan != nil),
            MFDButton("CLR", .c, "Clear the dV counter", active: counter),
        ]
    }

    public func press(_ b: MFDButton, _ c: MFDContext?) -> Bool {
        switch b.key {
        case .a, .e:
            guard let c, let el = c.elements, el.eccentricity > 1e-10 else { return false }
            let wait = b.key == .a ? (el.isBound ? el.timeToApoapsis : .infinity) : el.timeToPeriapsis
            guard wait.isFinite, wait >= 0 else { return false }
            ignition = c.time + wait
            centredIgnition = nil
        case .minus, .equal:
            guard let c else { return false }
            let base = ignition ?? defaultIgnition(c)
            ignition = base + (b.key == .minus ? -step : step)
            centredIgnition = nil
        case .i:
            step = Self.steps[((Self.steps.firstIndex(of: step) ?? 0) + 1) % Self.steps.count]
        case .g:
            switch target {
            case .entryAngle: target = .perigeeAltitude(40_000)
            case .perigeeAltitude: target = .entryAngle(Self.defaultEntryAngle)
            }
        case .leftBracket, .rightBracket:
            let up = b.key == .rightBracket
            switch target {
            case .entryAngle(let g): target = .entryAngle(min(-0.05 * .pi / 180, g + (up ? 1 : -1) * 0.05 * .pi / 180))
            case .perigeeAltitude(let h): target = .perigeeAltitude(h + (up ? 5_000 : -5_000))
            }
        case .s:
            guard let counter = c?.deltaVCounter, let plan else { return false }
            counter.loadDeltaV(plan.deltaVMagnitude)
            c?.data.maneuver = ActiveManeuver(deorbit: plan)
        case .c:
            guard let counter = c?.deltaVCounter else { return false }
            counter.loadDeltaV(nil)
            c?.data.maneuver = nil
        default: return false
        }
        return true
    }

    func defaultIgnition(_ c: MFDContext) -> Epoch {
        let t = c.time + Self.defaultLead
        let zero = c.missionClockZero ?? Epoch(tdbSecondsPastJ2000: 0)
        return zero + ((t - zero) / 60).rounded(.up) * 60
    }

    func plannerTarget(_ c: MFDContext) -> DeorbitPlanner.Target {
        switch target {
        case .entryAngle(let g): .entryFlightPathAngle(g)
        case .perigeeAltitude(let h): .perigeeRadius(c.body.radius + h)
        }
    }

    // MARK: Page

    public func page(_ c: MFDContext) -> MFDPage {
        var page = MFDPage(title: "DEORBIT  " + c.body.name)
        page.add(35, 0, "STP " + MFDFormat.duration(step), .referenceDim, alignment: .trailing)
        guard c.vessel.landed == nil else {
            plan = nil
            page.add(4, 2, "On the ground", .referenceDim)
            return page
        }
        if ignition == nil { ignition = defaultIgnition(c) }
        let tig = ignition!
        let engine = c.mainEngine
        let passed = tig < c.time
        plan = DeorbitPlanner.plan(c.vessel, snapshot: c.snapshot, ignition: passed ? .now : .at(tig),
                                   target: plannerTarget(c), engine: engine)
        if !passed { centredIgnition = plan?.centredIgnition ?? tig }
        let lit = centredIgnition ?? tig
        let zero = c.missionClockZero

        var row = 2
        func put(_ label: String, _ value: String, _ style: MFDStyle = .own, end: Int = 20) {
            page.field(4, row, label, value, valueEnd: end, style, labelStyle: .reference)
            row += 1
        }
        put("TIG", MFDFormat.clock(lit, zero: zero))
        put("TTG", passed ? "PASSED" : MFDFormat.duration(lit - c.time), passed ? .warn : .own)
        switch target {
        case .entryAngle(let g): put("TGT", "EI " + MFDFormat.degrees(g, signed: true), .target)
        case .perigeeAltitude(let h): put("TGT", "HP " + MFDFormat.si(h), .target)
        }
        row += 1
        guard let plan else {
            // A retrograde burn cannot make the entry shallower: past TIG
            // with the EI already steeper than the target, the burn is over.
            if passed, case .entryAngle(let g) = target, let ei = c.data.entryInterface,
               ei.inertialFlightPathAngle < g {
                put("DV TO GO", "0.0 m/s")
                put("OVERBURN", MFDFormat.degrees(ei.inertialFlightPathAngle - g, signed: true), .warn)
            } else {
                put("NO SOLUTION", "", .warn)
                page.add(4, row, "Target out of reach", .referenceDim)
                row += 1
            }
            row += 1
            entry(&page, &row, c.data.entryInterface, label: "EI NOW", zero: zero)
            counter(&page, c)
            return page
        }
        put(passed ? "DV TO GO" : "DV", MFDFormat.fixed(plan.deltaVMagnitude, 1) + " m/s")
        let x = plan.deltaVLocal
        page.add(4, row, "X", .reference)
        page.add(11, row, MFDFormat.fixed(x.x, 1, signed: true), alignment: .trailing)
        page.add(13, row, "Y", .reference)
        page.add(20, row, MFDFormat.fixed(x.y, 1, signed: true), alignment: .trailing)
        page.add(22, row, "Z", .reference)
        page.add(29, row, MFDFormat.fixed(x.z, 1, signed: true), alignment: .trailing)
        row += 1
        if let bt = plan.burnTime, let prop = plan.propellantMass, let engine {
            put("BT", MFDFormat.fixed(bt, 1) + " s")
            put("PROP", MFDFormat.si(prop) + " kg")
            put("ENG", MFDFormat.si(engine.thrust) + "N " + MFDFormat.fixed(engine.specificImpulse, 0) + "s",
                .ownDim)
        } else {
            put("BT", "no engine", .warn)
        }
        row += 1
        let post = plan.postBurnElements, r = c.body.radius
        put("HA", post.isBound ? MFDFormat.si(post.apoapsisRadius - r) : "---")
        put("HP", MFDFormat.si(post.periapsisRadius - r))
        row += 1
        entry(&page, &row, plan.entry, label: "EI", zero: zero)
        counter(&page, c)
        return page
    }

    /// The entry interface: time, speed, angle and place.
    func entry(_ page: inout MFDPage, _ row: inout Int, _ ei: EntryInterface?, label: String, zero: Epoch?) {
        func put(_ l: String, _ value: String, _ style: MFDStyle) {
            page.field(4, row, l, value, valueEnd: 20, style, labelStyle: .reference)
            row += 1
        }
        guard let ei else {
            put(label, "none", .warn)
            return
        }
        put(label, MFDFormat.clock(ei.time, zero: zero), .aux)
        put("VI", MFDFormat.si(ei.inertialSpeed), .aux)
        put("GAM", MFDFormat.degrees(ei.inertialFlightPathAngle, signed: true), .aux)
        page.add(4, row, MFDFormat.latitude(ei.latitude) + " " + MFDFormat.longitude(ei.longitude), .aux)
        row += 1
    }

    /// The ΔV counter's line, and the predictions' caveat.
    func counter(_ page: inout MFDPage, _ c: MFDContext) {
        if let counter = c.deltaVCounter {
            page.field(4, 22, "DVC", counter.deltaVRemaining.map { MFDFormat.fixed($0, 1) + " m/s" } ?? "not set",
                       valueEnd: 20, .target, labelStyle: .reference)
        } else {
            page.add(4, 22, "DVC n/a (no dV counter)", .referenceDim)
        }
        if let caveat = c.predictionCaveat { page.add(4, 23, "PRED: " + caveat, .warn) }
    }
}
