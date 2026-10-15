import Foundation

/// Generic test vehicles for M0. Real Apollo/Shuttle vehicles arrive in M1+.
public enum VesselLibrary {

    /// A small crew capsule with a service module: one main engine (OMS-like)
    /// and a full RCS. ~6.8 t.
    public static func capsule(name: String = "Capsule") -> Vessel {
        Vessel(name: name, parts: [capsulePart()], reference: placeholderBody)
    }

    /// Two-stage launcher with the capsule on top. ~288 t at liftoff, enough
    /// Δv to reach low Earth orbit with a reasonable gravity turn.
    public static func testRocket(name: String = "Pathfinder") -> Vessel {
        // Stage 1: x from 0 to 30 m.
        let t1 = PropellantTank(name: "S1 propellant", capacity: 220_000)
        let s1 = VesselPart(name: "Stage 1", dryMass: 18_000, offset: Vec3(15, 0, 0), length: 30, radius: 1.85,
                            tanks: [t1])
        s1.thrusters.append(Thruster(name: "S1 engine", position: Vec3(-15, 0, 0), direction: .unitX,
                                     maxThrustVacuum: 4_500_000, ispVacuum: 305, ispSeaLevel: 270,
                                     tank: t1, groups: [.main]))
        s1.addRCS(foreX: 12, aftX: -14, radius: 1.85, thrust: 25_000, isp: 270, tank: t1)
        s1.shapes = [.frustum(from: Vec3(-15, 0, 0), length: 30, baseRadius: 1.85, topRadius: 1.85, color: (0.85, 0.85, 0.82)),
                     .frustum(from: Vec3(-16.2, 0, 0), length: 1.2, baseRadius: 1.4, topRadius: 0.6, color: (0.25, 0.25, 0.27))]

        // Stage 2: x from 30 to 42 m.
        let t2 = PropellantTank(name: "S2 propellant", capacity: 40_000)
        let s2 = VesselPart(name: "Stage 2", dryMass: 3_500, offset: Vec3(36, 0, 0), length: 12, radius: 1.85,
                            tanks: [t2])
        s2.thrusters.append(Thruster(name: "S2 engine", position: Vec3(-6, 0, 0), direction: .unitX,
                                     maxThrustVacuum: 450_000, ispVacuum: 345, ispSeaLevel: 250,
                                     tank: t2, groups: [.main]))
        s2.addRCS(foreX: 5, aftX: -5.5, radius: 1.85, thrust: 3_000, isp: 290, tank: t2)
        s2.shapes = [.frustum(from: Vec3(-6, 0, 0), length: 12, baseRadius: 1.85, topRadius: 1.85, color: (0.92, 0.92, 0.9)),
                     .frustum(from: Vec3(-7.5, 0, 0), length: 1.5, baseRadius: 1.0, topRadius: 0.4, color: (0.3, 0.3, 0.32))]

        let cap = capsulePart()
        cap.offset = Vec3(44.5, 0, 0)
        return Vessel(name: name, parts: [s1, s2, cap], reference: placeholderBody)
    }

    static func capsulePart() -> VesselPart {
        let mainTank = PropellantTank(name: "SM propellant", capacity: 1_500)
        let rcsTank = PropellantTank(name: "RCS propellant", capacity: 300)
        let cap = VesselPart(name: "Capsule", dryMass: 5_000, length: 5, radius: 1.9, dragCoefficient: 1.2,
                             tanks: [mainTank, rcsTank])
        cap.thrusters.append(Thruster(name: "SM engine", position: Vec3(-2.6, 0, 0), direction: .unitX,
                                      maxThrustVacuum: 20_000, ispVacuum: 310, ispSeaLevel: 200,
                                      tank: mainTank, groups: [.main]))
        cap.addRCS(foreX: 1.5, aftX: -1.8, radius: 1.9, thrust: 450, isp: 280, tank: rcsTank)
        cap.shapes = [.frustum(from: Vec3(-2.5, 0, 0), length: 2.6, baseRadius: 1.9, topRadius: 1.9, color: (0.7, 0.72, 0.75)),
                      .frustum(from: Vec3(0.1, 0, 0), length: 2.4, baseRadius: 1.9, topRadius: 0.45, color: (0.55, 0.45, 0.35)),
                      .frustum(from: Vec3(-3.1, 0, 0), length: 0.6, baseRadius: 0.7, topRadius: 0.3, color: (0.25, 0.25, 0.25))]
        return cap
    }

    /// Placeholder reference used until a vessel is placed in a simulation.
    static let placeholderBody = CelestialBody(id: -1, name: "None", gm: 1, radius: 1, rotation: .none, soiRadius: .infinity)
}
