import Foundation

extension SaturnIU {
    /// The AS-506 (Apollo 11) flight program: times, angles and gains from
    /// `AS506` (datasheet §8), as offsets from the time base that triggers
    /// them; `tilt` replaces the pitch program.
    public static func as506(tilt: TiltProgram? = nil) -> SaturnIU {
        typealias D = AS506
        let deg = D.degree
        let tilt = tilt ?? D.tiltProgram
        func gains(_ g: (start: Double, a0: Double, a1: Double), roll: (a0: Double, a1: Double)) -> Action {
            .gains(FCCGains(a0: g.a0, a1: g.a1, rollA0: roll.a0, rollA1: roll.a1))
        }

        var sequence: [Event] = [
            Event(.t1, 0, "S-IC flight control gains", gains(D.sICGains[0], roll: D.sICRollGains)),
            Event(.t1, D.cantOn, "S-IC outboard engine cant", .startCant("S-IC")),
            Event(.t1, D.sICCenterCutoffTime, "S-IC centre engine cutoff", .engineCutoff("S-IC engine 5")),
            Event(.t3, 0, "S-IC outboard engine cutoff", .mainThrottle(0)),
            Event(.t3, D.sICSeparationTime, "S-IC/S-II separation", .separate("S-IC")),
            Event(.t3, D.sIIGains[0].start, "S-II flight control gains", gains(D.sIIGains[0], roll: D.sIIRollGains)),
            Event(.t3, D.sIIIgnitionTime, "S-II ignition", .mainThrottle(1)),
            Event(.t3, D.interstageJettisonTime, "S-II aft interstage jettison", .separate("S-IC/S-II interstage")),
            Event(.t3, D.lesJettisonTime, "launch escape tower jettison", .separate("LES")),
            Event(.t3, D.igmStartTime, "IGM phase 1 (not modelled: attitude held)", .note),
            Event(.t3, D.sIICenterCutoffTime, "S-II centre engine cutoff", .engineCutoff("S-II engine 5")),
            Event(.t3, D.sIIMixtureRatioShiftTime, "S-II mixture ratio shift", .rating(part: "S-II", D.sIIJ2LowEMR)),
            Event(.t4, 0, "S-II outboard engine cutoff", .mainThrottle(0)),
            Event(.t4, D.sIISeparationTime, "S-II/S-IVB separation", .separate("S-II")),
            Event(.t4, D.sIVBIgnitionTime, "S-IVB flight control law", .gains(nil)),
            Event(.t4, D.sIVBIgnitionTime, "S-IVB ignition", .mainThrottle(1)),
            // Until IGM exists, the cutoff comes as long after T4 as on the flight.
            Event(.t4, D.sIVBCutoffTime, "S-IVB cutoff (Apollo 11's burn time: IGM not modelled)", .mainThrottle(0)),
            Event(.t5, D.tb5UllageOn, "APS ullage on", .ullage(true)),
            Event(.t5, D.orbitalGuidanceStart, "orbital guidance: local horizontal", .localHorizontal),
            Event(.t5, D.tb5UllageOff, "APS ullage off", .ullage(false)),
        ]
        for g in D.sICGains.dropFirst() {
            sequence.append(Event(.t1, g.start, "S-IC flight control gains", gains(g, roll: D.sICRollGains)))
        }
        for g in D.sIIGains.dropFirst() {
            sequence.append(Event(.t3, g.start, "S-II flight control gains", gains(g, roll: D.sIIRollGains)))
        }

        return SaturnIU(plan: Plan(
            liftoffDelay: D.liftoff - D.firstMotion,
            referenceToLiftoff: D.liftoff - D.guidanceReferenceRelease,
            flightAzimuth: D.flightAzimuth * deg,
            towerYaw: (D.towerYawAngle * deg, D.towerYawOn, D.towerYawOff),
            programStart: (D.programStartRise, D.programStartBackup),
            tilt: tilt,
            commandRateLimit: D.commandRateLimit * deg,
            coastRateLimit: Vec3(D.coastRateLimit.roll, D.coastRateLimit.pitch, D.coastRateLimit.yaw) * deg,
            cant: (D.cantAngle * deg, D.cantRampRate * deg),
            sequence: sequence,
            stages: ("S-IC", "S-II", "S-IVB"), centreEngine: "S-IC engine 5"))
    }
}

extension VesselLibrary {
    /// Apollo 11 as it stood on LC-39A at first motion: `saturnV()` at the
    /// pad's geocentric latitude, with Position I (+z) east (the 90° pad
    /// azimuth) and the IU's flight program aboard, engines off. Full
    /// throttle lights the F-1s; the IU takes over at liftoff.
    @discardableResult
    public static func apollo11OnPad(in sim: Simulation, program: SaturnIU = .as506()) -> Vessel {
        let v = saturnV()
        sim.add(v)
        // `placeLanded` points -z at the azimuth it is given.
        sim.placeLanded(v, on: sim.system.earth, latitude: AS506.padLatitude, longitude: AS506.padLongitude,
                        azimuth: AS506.padAzimuth + 180)
        v.flightProgram = program
        return v
    }
}
