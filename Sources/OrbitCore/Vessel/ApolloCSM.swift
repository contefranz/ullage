import Foundation

extension ApolloCSM {
    /// The CSM's drag in orbit, along the wind (68-FM-184 Table I(d), H): it
    /// flies while the SM and the CM are both aboard and no launch model
    /// does.
    static var dragModel: AerodynamicModel {
        AerodynamicModel(name: "Apollo CSM, free-molecular flow", requiredParts: ["SM", "CM"],
                         referenceArea: csmDragArea * foot * foot, referenceDiameter: AS506.csmDiameter * inch,
                         referenceStation: 0, forebodyAxial: LinearTable([(0, csmDragCoefficient)]),
                         dragAlongWind: true)
    }

    /// The SPS and SM RCS loads of Apollo 7 at Table A.5-I row `row` (11 to
    /// 18), lb: the SPS has what it had at CM/SM separation (§5.21) and the
    /// weight drops of the burns still to come, split at the mixture ratio
    /// the flight burned (4,812.4 / 2,998.7); the SM RCS has the rest of the
    /// row's weight once the CM (row 19) and the SM structure are counted.
    /// Earlier rows also hold cryogenics, which the SM's structure does not
    /// count at their weight.
    static func apollo7Loads(row k: Int) -> (spsOxidizer: Double, spsFuel: Double, rcs: Double) {
        guard let row = apollo7Rows[k], let cm = ApolloCM.row(.apollo7, .separation) else {
            preconditionFailure("no Apollo 7 row \(k)")
        }
        let ratio = 4_812.4 / 2_998.7
        let extra = apollo7BurnDrops.filter { $0.key >= k && $0.key < 18 }.values.reduce(0, +)
        let ox = apollo7SPSAtSeparation.oxidizer + extra * ratio / (1 + ratio)
        let fuel = apollo7SPSAtSeparation.fuel + extra / (1 + ratio)
        let structure = apollo7Rows[18]!.weight - cm.weight - apollo7SPSAtSeparation.oxidizer
            - apollo7SPSAtSeparation.fuel - apollo7RCSAtSeparation
        return (ox, fuel, row.weight - cm.weight - structure - ox - fuel)
    }

    /// Put `spsOxidizer`, `spsFuel` and `rcs` lb (the four quads' total,
    /// shared as they were loaded) in `v`'s SM tanks, and re-centre it.
    static func setLoads(_ v: Vessel, spsOxidizer: Double, spsFuel: Double, rcs: Double) {
        guard let sm = v.parts.first(where: { $0.name == "SM" }) else { return }
        for t in sm.tanks where t.name == "SPS oxidizer" { t.mass = spsOxidizer * pound }
        for t in sm.tanks where t.name == "SPS fuel" { t.mass = spsFuel * pound }
        let quads = sm.tanks.filter { $0.name.hasPrefix("SM RCS") }
        let loaded = quads.reduce(0) { $0 + $1.capacity }
        for t in quads { t.mass = t.capacity * rcs * pound / loaded }
        v.recenter()
    }

    /// A state of the Apollo 7 trajectory, `TrajectoryState`, as an inertial
    /// position and velocity at its epoch: on the geodetic latitude and
    /// longitude above the figure, the velocity on the geocentric
    /// flight-path angle and heading, as `Simulation.place` reads them.
    static func inertialState(_ s: TrajectoryState, system: SolarSystem) -> (position: Vec3, velocity: Vec3) {
        let probe = Simulation(system: system, time: apollo7RangeZero + s.groundElapsedTime)
        let v = Vessel(name: "probe", parts: [VesselPart(name: "probe", dryMass: 1, length: 1, radius: 1)],
                       reference: system.earth)
        probe.place(v, geodeticLatitude: s.latitude, longitude: s.longitude, height: s.altitude * foot,
                    inertialSpeed: s.speed * foot, flightPathAngle: s.flightPathAngle, azimuth: s.heading)
        return (v.position, v.velocity)
    }

    /// The velocity of speed, flight-path angle and heading of `s` at the
    /// inertial position `r` (geocentric horizontal, as `inertialState`).
    static func velocity(_ s: TrajectoryState, at r: Vec3, system: SolarSystem) -> Vec3 {
        let o = system.snapshot(at: apollo7RangeZero + s.groundElapsedTime).orientation(system.earth)
        let up = r.normalized, east = o.pole.cross(up).normalized, north = up.cross(east)
        let deg = Double.pi / 180, gamma = s.flightPathAngle * deg, az = s.heading * deg
        let horizontal = north * cos(az) + east * sin(az)
        return (horizontal * cos(gamma) + up * sin(gamma)) * (s.speed * foot)
    }

    /// The position and velocity reached from `r`, `v` at `t0` at `t1` (either
    /// way) under the system's gravity and a constant `thrust` acceleration
    /// (ICRF, m/s^2), by RK4 in steps of 1 s or less.
    static func coast(_ r: Vec3, _ v: Vec3, from t0: Epoch, to t1: Epoch, system: SolarSystem,
                      body: CelestialBody, thrust: Vec3 = .zero) -> (position: Vec3, velocity: Vec3) {
        let span = t1 - t0
        guard abs(span) > 0 else { return (r, v) }
        let n = Int(abs(span).rounded(.up)), h = span / Double(n)
        var r = r, v = v, t = t0
        func a(_ at: Epoch, _ p: Vec3) -> Vec3 {
            system.acceleration(relativeTo: body, at: p, snapshot: system.snapshot(at: at)) + thrust
        }
        for _ in 0..<n {
            let k1r = v, k1v = a(t, r)
            let k2r = v + k1v * (h / 2), k2v = a(t + h / 2, r + k1r * (h / 2))
            let k3r = v + k2v * (h / 2), k3v = a(t + h / 2, r + k2r * (h / 2))
            let k4r = v + k3v * h, k4v = a(t + h, r + k3r * h)
            r += (k1r + k2r * 2 + k3r * 2 + k4r) * (h / 6)
            v += (k1v + k2v * 2 + k3v * 2 + k4v) * (h / 6)
            t = t + h
        }
        return (r, v)
    }

    /// Apollo 7's SPS-8 velocity change (ICRF, m/s): Table 3-III's cutoff
    /// velocity, read at the position the ignition state coasts to, less the
    /// velocity it coasts to without the burn.
    public static func apollo7SPS8DeltaV(system: SolarSystem) -> Vec3 {
        let ignition = inertialState(apollo7SPS8Ignition, system: system)
        let t0 = apollo7RangeZero + apollo7SPS8Ignition.groundElapsedTime
        let t1 = apollo7RangeZero + apollo7SPS8Cutoff.groundElapsedTime
        let coasted = coast(ignition.position, ignition.velocity, from: t0, to: t1, system: system, body: system.earth)
        return velocity(apollo7SPS8Cutoff, at: coasted.position, system: system) - coasted.velocity
    }

    /// The attitude (body -> ICRF) that points the SPS's thrust, trimmed
    /// through `v`'s centre of mass, along `direction` (ICRF), with the
    /// crew's head (-Z_A, body +z) towards the Earth below: heads down, the
    /// CM's lift up.
    static func burnAttitude(_ v: Vessel, along direction: Vec3) -> Quat {
        let d = direction.normalized, down = -v.position.normalized
        let z = (down - d * down.dot(d)).normalized
        let aligned = Quat(matrix: Mat3(columns: d, z.cross(d), z))
        guard let sm = v.parts.first(where: { $0.name == "SM" }),
              let sps = sm.thrusters.first(where: { $0.name == "SPS" }) else { return aligned }
        let thrust = (v.centerOfMass - (sps.position + sm.offset)).normalized   // body axes, through the CoM
        return (shortestTurn(from: aligned.rotate(thrust), to: d, fallbackAxis: z) * aligned).normalized
    }
}

extension VesselLibrary {
    /// The Apollo CSM's parts in the Saturn V construction frame, built in
    /// Apollo axes (`ApolloAxes`), loaded as `mission` launched:
    /// - "SM": the service module, staging event 7 (CM/SM separation). Its
    ///   SPS (`groups` `.main`: the active stage once the S-IVB has gone)
    ///   gimbals in pitch and yaw about its thrusting nulls and draws from
    ///   two lumped tanks, "SPS oxidizer" and "SPS fuel"; its four SM RCS
    ///   quads (`addSMRCSQuad`) are `activeStageOnly`, silent on the
    ///   Saturn stack; its jettison controller fires the -X and roll jets
    ///   as it leaves. The springs give nothing (`separationSpeed` 0).
    /// - The command module's (`commandModuleParts`): "CM", the crewed part
    ///   (`isCrewed`, the crew's frame `ApolloAxes.rotation`), whose RCS
    ///   event 7 arms, then "Apex cover", "Drogue parachutes" and "Main
    ///   parachutes".
    ///
    /// The SM's structure is a Mission Report row less the CM and the SPS
    /// and SM RCS propellant: Apollo 11's at transposition and docking
    /// (Table A-I, with its SPS loaded and the RCS 33.3 lb lighter than
    /// loaded, so the CSM is the FER's 28,806 kg at launch), Apollo 7's at
    /// CM/SM separation (Table A.5-I row 18, with what §5.21 says was left;
    /// its structure holds that time's cryogenics, so the launch loads give
    /// 32,208 lb: 68-FM-184 Table I(c)'s 32,458 less the 499 lb of
    /// cryogenics the flight used, its 91 lb SLA ring and 20 lb of the CM,
    /// with the 358 lb more SPS propellant the flight loaded). Its
    /// mass, CG and full inertia tensor are what the row leaves, so the CSM
    /// is the row at the row's loads; at others the tanks' geometry moves
    /// its CG and inertia (`CSMMassPropertiesTests`).
    public static func apolloCSMParts(_ mission: ApolloCSM.Mission) -> [VesselPart] {
        typealias C = ApolloCSM
        let lb = C.pound, inch = C.inch
        let cmParts = commandModuleParts(mission)
        if let cm = cmParts.first(where: { $0.name == "CM" }) {
            cm.isCrewed = true
            cm.crewFrame = ApolloAxes.rotation
        }

        let sm = VesselPart(name: "SM", dryMass: 0, offset: ApolloAxes.construction(xa: (C.smBottom + C.smTop) / 2),
                            length: (C.smTop - C.smBottom) * inch, radius: AS506.csmDiameter / 2 * inch,
                            dragCoefficient: C.csmDragCoefficient, staging: .event(7))
        sm.separationSpeed = 0
        func local(_ xa: Double, _ ya: Double = 0, _ za: Double = 0) -> Vec3 {
            ApolloAxes.construction(xa: xa, ya: ya, za: za) - sm.offset
        }
        func polar(_ r: Double, _ angle: Double) -> (ya: Double, za: Double) {
            (r * cos(angle * C.degree), r * sin(angle * C.degree))
        }

        // SPS tanks, each propellant's lumped into one settled column: the
        // tanks' capacity and their mean height, a cross-section of their
        // sum, at their capacity-weighted place. Its lines hold their load
        // below it, which the engine empties last.
        let load = C.spsLoad(mission)
        func spsTank(_ name: String, lines: Double,
                     _ tanks: [(capacity: Double, angle: Double, height: Double, diameter: Double)]) -> PropellantTank {
            let capacity = tanks.reduce(0) { $0 + $1.capacity }
            let ya = tanks.reduce(0) { $0 + $1.capacity * polar(C.tankRadius, $1.angle).ya } / capacity
            let za = tanks.reduce(0) { $0 + $1.capacity * polar(C.tankRadius, $1.angle).za } / capacity
            let height = tanks.reduce(0) { $0 + $1.capacity * $1.height } / capacity
            let radius = tanks.reduce(0) { $0 + $1.diameter * $1.diameter / 4 }.squareRoot()
            let line = polar(C.lineRadius, tanks[0].angle)
            return PropellantTank(name: name, capacity: (capacity + lines) * lb,
                                  geometry: .settledColumn(aftEnd: local(C.tankBottom, ya, za), length: height * inch,
                                                           radius: radius * inch),
                                  feedLines: (lines * lb, local(C.lineStation, line.ya, line.za)))
        }
        let oxSump = (C.oxidizerSump, C.oxidizerSumpAngle, C.sumpHeight, C.sumpDiameter)
        let oxStorage = (C.oxidizerStorage, C.oxidizerStorageAngle, C.storageHeight, C.storageDiameter)
        let fuelSump = (C.fuelSump, C.fuelSumpAngle, C.sumpHeight, C.sumpDiameter)
        let fuelStorage = (C.fuelStorage, C.fuelStorageAngle, C.storageHeight, C.storageDiameter)
        let sumpsOnly = mission == .apollo7
        let oxidizer = spsTank("SPS oxidizer", lines: load.oxidizerLines, sumpsOnly ? [oxSump] : [oxSump, oxStorage])
        let fuel = spsTank("SPS fuel", lines: load.fuelLines, sumpsOnly ? [fuelSump] : [fuelSump, fuelStorage])
        sm.tanks = [oxidizer, fuel]

        // The SPS, gimballed at its thrusting nulls: the pitch actuator leans
        // the thrust towards +Z_A, the yaw actuator towards +Y_A.
        let exitArea = Double.pi * pow(C.spsExitDiameter / 2 * inch, 2)
        let rating = EngineRating.fixedNozzle(name: "SPS", thrustVacuum: C.spsThrust * C.poundForce,
                                              ispVacuum: C.spsIsp, exitArea: exitArea, mixtureRatio: C.spsMixtureRatio)
        func actuator(towards tilt: Vec3, null: Double) -> GimbalActuator {
            var a = GimbalActuator(tilt: tilt, range: (null - C.spsGimbalTravel) * C.degree...(null + C.spsGimbalTravel) * C.degree,
                                   rateLimit: C.spsGimbalRate)
            a.bias = null * C.degree
            a.angle = a.bias
            a.command = a.bias
            return a
        }
        let sps = Thruster(name: "SPS", position: local(C.spsGimbalStation), direction: .unitX, rating: rating,
                           feed: .bipropellant(oxidizer: oxidizer, fuel: fuel), groups: [.main], throttleRange: 1...1,
                           gimbal: [actuator(towards: ApolloAxes.direction(xa: 0, ya: 0, za: 1), null: C.spsPitchNull),
                                    actuator(towards: ApolloAxes.direction(xa: 0, ya: 1, za: 0), null: C.spsYawNull)])
        // The build-up and tail-off as linear ramps of their delta Ts.
        sps.transients = EngineTransients(startRise: C.spsBuildupDelay, shutdown: C.spsTailoffDelay)
        sm.thrusters = [sps]

        for (quad, loads) in zip(C.quadAngles, C.rcsLoads(mission)) {
            addSMRCSQuad(to: sm, name: quad.name, angle: quad.angle, loads: loads)
        }

        // The SM's structure: the mission's row less everything else, at
        // the row's loads; then the launch loads.
        let derivation: (row: ApolloCM.MassRow, oxidizer: Double, fuel: Double, rcs: Double)
        let rcsLoaded = C.rcsLoads(mission).reduce(0) { $0 + $1.fuel + $1.oxidizer }
        switch mission {
        case .apollo7:
            derivation = (C.apollo7Rows[18]!, C.apollo7SPSAtSeparation.oxidizer, C.apollo7SPSAtSeparation.fuel,
                          C.apollo7RCSAtSeparation)
        case .apollo11:
            derivation = (C.apollo11Docking, load.oxidizer, load.fuel, rcsLoaded - C.apollo11RCSUsedByDocking)
        }
        oxidizer.mass = derivation.oxidizer * lb
        fuel.mass = derivation.fuel * lb
        let quadTanks = sm.tanks.filter { $0.name.hasPrefix("SM RCS") }
        for t in quadTanks { t.mass = t.capacity * derivation.rcs / rcsLoaded }
        var elements: [(mass: Double, com: Vec3, inertia: Mat3)] =
            cmParts.map { ($0.mass, $0.offset + $0.centerOfMass, $0.localInertia) }
        elements += sm.tanks.map { ($0.mass, sm.offset + ($0.centroid ?? .zero), $0.ownInertia) }
        let row = derivation.row
        let mass = row.mass - elements.reduce(0) { $0 + $1.mass }
        let com = (row.centerOfMass * row.mass - elements.reduce(Vec3.zero) { $0 + $1.com * $1.mass }) / mass
        var inertia = row.inertia + .parallelAxis(mass: row.mass, offset: row.centerOfMass - com)
        for e in elements { inertia = inertia + (e.inertia + .parallelAxis(mass: e.mass, offset: e.com - com)) * -1 }
        sm.dryMass = mass
        sm.dryCenterOfMass = com - sm.offset
        sm.dryInertia = inertia
        oxidizer.mass = load.oxidizer * lb
        fuel.mass = load.fuel * lb
        for t in quadTanks { t.mass = t.capacity }

        return [sm] + cmParts
    }

    /// One SM RCS quad on `part` (the SM) at `angle` degrees round the axis
    /// (from +Y_A towards +Z_A), with its oxidizer and fuel tanks ("SM RCS
    /// ox", "SM RCS fuel": one HUD row for the four quads) and four R-4Ds
    /// named as AOH Fig. 2.5-1 numbers them: 1 the clockwise (+roll) and 2
    /// the counterclockwise (-roll) tangential jets, 3 the + and 4 the -
    /// axial jet of the quad's axis, pitch on quads A and C, yaw on B and D.
    /// Each jet is in the rotation group of its torque's dominant axis about
    /// the CSM's axis at the quad's station (the 7°15′ offset gives the
    /// axial jets a small torque on the other axis, which a sign rule would
    /// put in a second group) and the translation group of its force's.
    /// Every jet is `activeStageOnly`. The SM jettison controller (MSC-03466)
    /// fires the -X jets from the SM's separation until their propellant
    /// runs out, and the +roll jets from 2 s for 5.5 s (`Thruster.sequence`).
    static func addSMRCSQuad(to part: VesselPart, name quad: String, angle: Double,
                             loads: (fuel: Double, oxidizer: Double)) {
        typealias C = ApolloCSM
        let c = cos(angle * C.degree), s = sin(angle * C.degree)
        func local(_ r: Double) -> Vec3 {
            ApolloAxes.construction(xa: C.quadStation, ya: r * c, za: r * s) - part.offset
        }
        let ox = PropellantTank(name: "SM RCS ox", capacity: loads.oxidizer * C.pound, geometry: .point(local(C.quadTankRadius)))
        let fuel = PropellantTank(name: "SM RCS fuel", capacity: loads.fuel * C.pound, geometry: .point(local(C.quadTankRadius)))
        part.tanks += [ox, fuel]
        let rating = EngineRating(name: "R-4D", thrustVacuum: C.rcsFourJetThrust / 4 * C.poundForce, ispVacuum: C.rcsIsp,
                                  mixtureRatio: C.rcsMixtureRatio)
        let at = local(C.quadRadius), axisPoint = ApolloAxes.construction(xa: C.quadStation) - part.offset
        let roll = ApolloAxes.direction(xa: 0, ya: -s, za: c)       // +R: X_A × the quad's outward radial
        // The + jet of the quad's axis: +pitch pushes -X_A on the -Z_A side,
        // +yaw pushes -X_A on the +Y_A side.
        let pitchQuad = abs(s) > abs(c)
        let plus = Vec3.unitX * (pitchQuad ? (s > 0 ? 1 : -1) : (c > 0 ? -1 : 1))
        func dominant(_ v: Vec3, _ groups: (x: (ThrusterGroup, ThrusterGroup), y: (ThrusterGroup, ThrusterGroup),
                                            z: (ThrusterGroup, ThrusterGroup))) -> ThrusterGroup {
            if abs(v.x) >= abs(v.y) && abs(v.x) >= abs(v.z) { return v.x > 0 ? groups.x.0 : groups.x.1 }
            if abs(v.y) >= abs(v.z) { return v.y > 0 ? groups.y.0 : groups.y.1 }
            return v.z > 0 ? groups.z.0 : groups.z.1
        }
        for (n, direction) in [(1, roll), (2, -roll), (3, plus), (4, -plus)] {
            let torque = (at - axisPoint).cross(direction)
            let rotation = dominant(torque, ((.rollRight, .rollLeft), (.pitchUp, .pitchDown), (.yawRight, .yawLeft)))
            let translation = dominant(direction, ((.translateForward, .translateBack), (.translateRight, .translateLeft),
                                                   (.translateDown, .translateUp)))
            let t = Thruster(name: "SM RCS \(quad)\(n)", position: at, direction: direction, rating: rating,
                             feed: .bipropellant(oxidizer: ox, fuel: fuel), groups: [rotation, translation])
            t.activeStageOnly = true
            if direction.x < -0.5 {
                t.trigger = .ownSeparation
                t.sequence = FiringSequence(start: 0, duration: nil)
            } else if n == 1 {
                t.trigger = .ownSeparation
                t.sequence = FiringSequence(start: C.jettisonRollStart, duration: C.jettisonRollDuration)
            }
            part.thrusters.append(t)
        }
    }

    /// The SLA's parts, staging event 6: "SLA ring", the lower 7 ft that
    /// stays on the S-IVB, and "SLA panel 1"-"4", each a quarter of the
    /// upper 21 ft (68-FM-160's numbering: 1 at +Z_A, 2 at -Z_A, 3 at +Y_A,
    /// 4 at -Y_A), in its own separation group. Each is a thin conical shell
    /// from the IU's 260 in to the SM's 154 in; a panel leaves at 68-FM-160's
    /// 8 ft/s, 110° from +X, tumbling outwards about its hinge at 33.5°/s,
    /// its drag 1.7 on 239 ft² (the part's radius gives that area).
    static func slaParts() -> [VesselPart] {
        typealias C = ApolloCSM
        typealias D = AS506
        let base = D.iuTop - D.apolloStationOffset, top = D.slaTop
        let r0 = D.sIVBDiameter / 2, r1 = D.csmDiameter / 2
        func radius(_ xa: Double) -> Double { r0 + (r1 - r0) * (xa - base) / (top - base) }
        /// A shell's dry CoM and inertia (construction axes) over stations
        /// `from...to` and angles `angles` (deg, from +Y_A towards +Z_A).
        func shell(mass: Double, from a: Double, to b: Double, angles: ClosedRange<Double>) -> (com: Vec3, inertia: Mat3) {
            var points: [(Vec3, Double)] = []
            let nx = 48, na = 36
            for i in 0..<nx {
                let xa = a + (b - a) * (Double(i) + 0.5) / Double(nx), r = radius(xa)
                for j in 0..<na {
                    let t = (angles.lowerBound + (angles.upperBound - angles.lowerBound) * (Double(j) + 0.5) / Double(na))
                        * C.degree
                    points.append((ApolloAxes.construction(xa: xa, ya: r * cos(t), za: r * sin(t)), r))
                }
            }
            let w = points.reduce(0) { $0 + $1.1 }
            let com = points.reduce(Vec3.zero) { $0 + $1.0 * $1.1 } / w
            let inertia = points.reduce(Mat3.zero) { $0 + .parallelAxis(mass: mass * $1.1 / w, offset: $1.0 - com) }
            return (com, inertia)
        }
        func part(_ name: String, from a: Double, to b: Double, radius r: Double, mass: Double,
                  angles: ClosedRange<Double>) -> VesselPart {
            let p = VesselPart(name: name, dryMass: mass, offset: ApolloAxes.construction(xa: (a + b) / 2),
                               length: (b - a) * C.inch, radius: r, staging: .event(6))
            let s = shell(mass: mass, from: a, to: b, angles: angles)
            p.dryCenterOfMass = s.com - p.offset
            p.dryInertia = s.inertia
            p.separationSpeed = 0
            return p
        }
        let ring = part("SLA ring", from: base, to: C.slaHinge, radius: r0 * C.inch, mass: C.slaRing, angles: 0...360)
        let panelRadius = (C.panelArea * C.foot * C.foot / Double.pi).squareRoot()
        var parts = [ring]
        for (i, angle) in C.panelAngles.enumerated() {
            let p = part("SLA panel \(i + 1)", from: C.slaHinge, to: top, radius: panelRadius, mass: C.slaPanels / 4,
                         angles: (angle - 45)...(angle + 45))
            p.dragCoefficient = C.panelDragCoefficient
            p.separationGroup = p.name
            let out = ApolloAxes.direction(xa: 0, ya: cos(angle * C.degree), za: sin(angle * C.degree))
            let leave = C.panelDirection * C.degree
            p.separationVelocity = (Vec3.unitX * cos(leave) + out * sin(leave)) * (C.panelSpeed * C.foot)
            p.separationRate = Vec3.unitX.cross(out) * (C.panelRate * C.degree)
            parts.append(p)
        }
        return parts
    }

    /// The Apollo CSM alone (`apolloCSMParts`), as it flies after the
    /// CSM/LV separation: its SCS (`ApolloSCS`, with the CM's entry program
    /// for once the SM has gone: `ApolloMission`) aboard, the crew's control
    /// frame, the CM's impact limits, the CSM's drag and the CM's
    /// aerodynamics for once the SM has gone. Place it with
    /// `Simulation.place`.
    public static func apolloCSM(_ mission: ApolloCSM.Mission, name: String? = nil) -> Vessel {
        let parts = apolloCSMParts(mission)
        let scs = ApolloMission.spacecraftControl()
        parts.first { $0.name == "CM" }?.standbyProgram = scs
        let v = Vessel(name: name ?? mission.rawValue, parts: parts, reference: placeholderBody)
        v.controlFrame = ApolloAxes.rotation
        v.impactLimits = ApolloCM.impactLimits
        v.aerodynamics = [ApolloCSM.dragModel, .apolloCommandModule()]
        v.flightProgram = scs
        v.phasePlane = ApolloCSM.phasePlaneLaw(deadband: ApolloCSM.narrowDeadband)
        v.tvcGains = ApolloCSM.spsTVCGains
        dressApollo(v)
        return v
    }

    /// Apollo 11's parking-orbit insertion, range time 709.33 s (PFT Table
    /// B-II's insertion row): 1969-07-16 13:43:49.33 UTC.
    public static let apollo11Insertion = AS506.rangeZero + AS506Postflight.Event.insertion.time

    /// Apollo 11 in its parking orbit at insertion (`apollo11Insertion`; the
    /// simulation's clock is set there, so build it in a fresh simulation):
    /// `saturnV()` with staging events 1-5 gone, the S-IVB holding what burn
    /// 1 left (FER Table 20-5's 25,873 kg of LOX and 5,339 kg of LH2 used),
    /// at AS-506's postflight insertion state (PFT Table B-II, PACSS 13,
    /// turned to ICRF through the space-fixed frame the IU fixes on the pad,
    /// as `AscentResidualTests` turns it), in the IU's orbital attitude
    /// (local horizontal, Position I towards the Earth: the crew heads
    /// down), and its IU picked up after the cutoff at AS-506's time bases
    /// (`SaturnIU.as506InParkingOrbit`): the APS ullage on to T5 + 87 s, the
    /// turn to the local horizontal at T5 + 19.8 s. Space separates the CSM.
    @discardableResult
    public static func apollo11InParkingOrbit(in sim: Simulation) -> Vessel {
        typealias D = AS506
        let earth = sim.system.earth
        // The frame the IU fixes at liftoff, from the stack on the pad then.
        let pad = Simulation(system: sim.system, time: D.rangeZero + D.liftoff)
        let onPad = saturnV()
        pad.add(onPad)
        pad.placeLanded(onPad, on: earth, latitude: lc39A.latitude, longitude: lc39A.longitude,
                        azimuth: D.padAzimuth + 180, elevation: lc39A.elevation)
        let program = SaturnIU.as506()
        let frame = program.spaceFixedFrame(at: onPad.position, of: earth, orientation: pad.snapshot.orientation(earth))

        sim.setTime(apollo11Insertion)
        let v = saturnV()
        v.parts.removeAll { if case .event(let n) = $0.staging { return n <= 5 } else { return false } }
        for t in v.parts.flatMap(\.tanks) {
            if t.name == "S-IVB LOX" { t.mass -= D.sIVBBurn1LOXUsed }
            if t.name == "S-IVB LH2" { t.mass -= D.sIVBBurn1LH2Used }
        }
        v.recenter()
        guard let row = AS506Postflight.row(at: AS506Postflight.Event.insertion.time) else {
            preconditionFailure("no PFT insertion row")
        }
        v.reference = earth
        v.position = frame.rotate(row.position)
        v.velocity = frame.rotate(row.velocity)
        let up = v.position.normalized, x = (v.velocity - up * v.velocity.dot(up)).normalized
        v.attitude = Quat(matrix: Mat3(columns: x, (-up).cross(x), -up))
        v.angularVelocity = v.attitude.inverseRotate(v.position.cross(v.velocity) / v.position.lengthSquared)
        sim.add(v)
        sim.updateTelemetry(v, snapshot: sim.snapshot)
        v.flightProgram = SaturnIU.as506InParkingOrbit(on: v, spaceFixed: frame, at: sim.time, program: program)
        return v
    }

    /// Apollo 7's range zero, 1968-10-11 15:02:45 UTC (Mission Report Table
    /// 2-I): its ground elapsed time (GET) 0.
    public static var apollo7RangeZero: Epoch { ApolloCSM.apollo7RangeZero }

    /// Apollo 7 (CSM-101) before its deorbit burn, SPS-8, at GET
    /// `groundElapsedTime` s (259:38:00 by default, before 259:39:01.3; the
    /// simulation's clock is set there): the CSM alone
    /// (`apolloCSM(.apollo7)`) at Table A.5-I row 17's weight, 24,262 lb,
    /// plus the SM RCS for 15 s of four-jet ullage; on Table 3-III's
    /// ignition state at 259:39:16.3 taken back to then, through that
    /// ullage over its last 15 s; in the burn's attitude, held (thrust
    /// through the CG along the burn's Δv, `ApolloCSM.apollo7SPS8DeltaV`;
    /// heads down), with the EMS counter loaded with the burn's Δv along
    /// X_A. The crew's steps (Mission Report Table 2-I):
    /// 1. U from 259:39:01.3 for 15 s (ullage: the SPS has 2,735 lb, below
    ///    the 22,300 lb mark);
    /// 2. Z at 259:39:16.3 (SPS on); the counter cuts it off (the flight's
    ///    cutoff was at 259:39:28.2);
    /// 3. Space twice at 259:43:33.8 (CM/SM separation);
    /// then entry interface at 259:53:27, splashdown at 260:09:03 near 27.6°
    /// N, 64.1° W.
    @discardableResult
    public static func apollo7BeforeDeorbit(in sim: Simulation,
                                            groundElapsedTime get: Double = 259 * 3_600 + 38 * 60) -> Vessel {
        typealias C = ApolloCSM
        let v = apolloCSM(.apollo7)
        let loads = C.apollo7Loads(row: 17)
        let ullage = C.rcsFourJetThrust / C.rcsIsp * 15   // lb
        C.setLoads(v, spsOxidizer: loads.spsOxidizer, spsFuel: loads.spsFuel, rcs: loads.rcs + ullage)

        let ignition = C.apollo7SPS8Ignition, tig = C.apollo7RangeZero + ignition.groundElapsedTime
        let state = C.inertialState(ignition, system: sim.system)
        v.reference = sim.system.earth
        v.position = state.position
        v.attitude = C.burnAttitude(v, along: C.apollo7SPS8DeltaV(system: sim.system))
        let ullageAcceleration = v.attitude.rotate(.unitX) * (C.rcsFourJetThrust * C.poundForce / (v.mass - ullage / 2 * C.pound))
        let started = C.coast(state.position, state.velocity, from: tig, to: tig + (-15), system: sim.system,
                              body: sim.system.earth, thrust: ullageAcceleration)
        let back = C.coast(started.position, started.velocity, from: tig + (-15), to: C.apollo7RangeZero + get,
                           system: sim.system, body: sim.system.earth)
        sim.setTime(C.apollo7RangeZero + get)
        v.position = back.position
        v.velocity = back.velocity
        v.angularVelocity = .zero
        v.autopilot = .attitudeHold
        v.attitudeCommand = AttitudeCommand(attitude: v.attitude)
        sim.add(v)
        sim.updateTelemetry(v, snapshot: sim.snapshot)
        (v.flightProgram as? DeltaVCounting)?.loadDeltaV(C.apollo7SPS8CounterLoad)
        return v
    }
}
