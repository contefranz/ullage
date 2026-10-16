import XCTest
@testable import OrbitCore

/// Small vehicles with round numbers for the mechanism tests. They are not
/// real vehicles: every expected value in the tests is worked out from the
/// literals below.
enum Toy {
    /// 1 MN, 300 s in vacuum, 0.8 m^2 nozzle exit, mixture ratio 2.5.
    static let engine = EngineRating.fixedNozzle(name: "Toy engine", thrustVacuum: 1e6, ispVacuum: 300,
                                                 exitArea: 0.8, mixtureRatio: 2.5)
    /// A second setting of the same nozzle: 0.8 MN, 305 s, mixture ratio 2.0.
    static let lowRating = EngineRating.fixedNozzle(name: "Toy engine low MR", thrustVacuum: 0.8e6, ispVacuum: 305,
                                                    exitArea: 0.8, mixtureRatio: 2.0)

    /// A 51 t stage, 20 m long (part frame x from -10 to 10), radius 2 m:
    /// - dry 8 t at x = -4;
    /// - oxidizer 30 t (300 kg unusable) in a column centred at x = 5 when full;
    /// - fuel 13 t (200 kg unusable) in a column centred at x = -6 when full;
    /// - two `engine`s at x = -10, z = ±1 on one bipropellant feed.
    /// `columns: false` makes both tanks lumped (M0 placement).
    static func stage(_ name: String = "Stage", offset: Vec3 = .zero, columns: Bool = true,
                      throttleRange: ClosedRange<Double> = 1...1, staging: StagingRule = .bottomOfStack) -> VesselPart {
        func tank(_ kind: String, _ load: Double, unusable: Double, centroid: Double, density: Double) -> PropellantTank {
            PropellantTank(name: "\(name) \(kind)", capacity: load, unusableMass: unusable,
                           geometry: columns ? .column(fullLoadCentroid: Vec3(centroid, 0, 0), radius: 1.9,
                                                       capacity: load, density: density) : .lumped)
        }
        let ox = tank("ox", 30_000, unusable: 300, centroid: 5, density: 1141)
        let fuel = tank("fuel", 13_000, unusable: 200, centroid: -6, density: 810)
        let part = VesselPart(name: name, dryMass: 8_000, offset: offset, length: 20, radius: 2, tanks: [ox, fuel],
                              dryCenterOfMass: Vec3(-4, 0, 0), staging: staging)
        for (i, z) in [1.0, -1.0].enumerated() {
            part.thrusters.append(Thruster(name: "\(name) engine \(i + 1)", position: Vec3(-10, 0, z),
                                           direction: .unitX, rating: engine,
                                           feed: .bipropellant(oxidizer: ox, fuel: fuel), groups: [.main],
                                           throttleRange: throttleRange))
        }
        return part
    }

    /// A passive part (interstage, payload, tower...) spanning construction
    /// stations `x0...x1`, its dry CoM at the middle.
    static func block(_ name: String, from x0: Double, to x1: Double, radius: Double = 2, mass: Double,
                      staging: StagingRule) -> VesselPart {
        VesselPart(name: name, dryMass: mass, offset: Vec3((x0 + x1) / 2, 0, 0), length: x1 - x0, radius: radius,
                   staging: staging)
    }

    /// `stage` on stations 0...20 with a 2 t payload on 20...24.
    static func rocket(columns: Bool = true, throttleRange: ClosedRange<Double> = 1...1) -> Vessel {
        Vessel(name: "Toy", parts: [stage(offset: Vec3(10, 0, 0), columns: columns, throttleRange: throttleRange),
                                    block("Payload", from: 20, to: 24, mass: 2_000, staging: .fixed)],
               reference: VesselLibrary.placeholderBody)
    }

    /// A pitch-plane (+z) and a yaw-plane (-y) actuator, ±5° at 5°/s unless given.
    static func actuators(limit: Double = 5 * .pi / 180, rate: Double = 5 * .pi / 180,
                          lag: Double = 0) -> [GimbalActuator] {
        [GimbalActuator(tilt: .unitZ, limit: limit, rateLimit: rate, timeConstant: lag),
         GimbalActuator(tilt: -Vec3.unitY, limit: limit, rateLimit: rate, timeConstant: lag)]
    }

    /// `rocket` with a five-engine cluster instead of its two engines, all on
    /// one feed with their gimbal points at construction x = 0: engines 1-4 on
    /// the diagonals at radius 2 m with `actuators` (`actuators()` unless
    /// given), engine 5 fixed on the axis. `engines` keeps only the first ones.
    static func clusterRocket(engines: Int = 5, actuators: [GimbalActuator] = Toy.actuators()) -> Vessel {
        let s = stage(offset: Vec3(10, 0, 0))
        s.thrusters.removeAll()
        let d = 2 / 2.squareRoot()
        for (i, (y, z)) in [(-d, d), (-d, -d), (d, -d), (d, d), (0.0, 0.0)].prefix(engines).enumerated() {
            s.thrusters.append(Thruster(name: "Engine \(i + 1)", position: Vec3(-10, y, z), direction: .unitX,
                                        rating: engine, feed: .bipropellant(oxidizer: s.tanks[0], fuel: s.tanks[1]),
                                        groups: [.main], throttleRange: 1...1, gimbal: i < 4 ? actuators : []))
        }
        return Vessel(name: "Cluster", parts: [s, block("Payload", from: 20, to: 24, mass: 2_000, staging: .fixed)],
                      reference: VesselLibrary.placeholderBody)
    }

    /// A squat drum, 2 m long and 3 m in radius, 5 t dry, with `addRCS`
    /// thrusters of 200 N at radius 0.5 m, 1 m fore and aft of its middle, on
    /// a 100 kg lumped tank. Roll is its weakest axis: 200 N m on Ixx 22,950
    /// kg m^2 is 0.0087 rad/s^2, against 400 N m on Iyy 13,175 (0.030) in
    /// pitch and yaw.
    static func rollWeakDrum() -> Vessel {
        let tank = PropellantTank(name: "Drum RCS", capacity: 100)
        let part = VesselPart(name: "Drum", dryMass: 5_000, length: 2, radius: 3, tanks: [tank], staging: .fixed)
        part.addRCS(foreX: 1, aftX: -1, radius: 0.5, thrust: 200, isp: 280, tank: tank)
        return Vessel(name: "Drum", parts: [part], reference: VesselLibrary.placeholderBody)
    }

    /// Saturn-like staging on toy parts, bottom to top (construction stations):
    /// Booster 0-20 `.event(1)`, Interstage 20-22 `.event(2)`, Core 22-42 and
    /// Adapter 42-44 `.event(4)`, Upper 44-64 and Payload 64-68 `.fixed`,
    /// Tower 68-74 `.event(3)`.
    static func stack() -> Vessel {
        Vessel(name: "Toy stack",
               parts: [stage("Booster", offset: Vec3(10, 0, 0), staging: .event(1)),
                       block("Interstage", from: 20, to: 22, mass: 1_000, staging: .event(2)),
                       stage("Core", offset: Vec3(32, 0, 0), staging: .event(4)),
                       block("Adapter", from: 42, to: 44, mass: 500, staging: .event(4)),
                       stage("Upper", offset: Vec3(54, 0, 0), staging: .fixed),
                       block("Payload", from: 64, to: 68, mass: 2_000, staging: .fixed),
                       block("Tower", from: 68, to: 74, radius: 0.5, mass: 2_000, staging: .event(3))],
               reference: VesselLibrary.placeholderBody)
    }
}

extension Simulation {
    /// Simulation at the Apollo 11 launch epoch. Without perturbations only
    /// Earth's central field acts.
    static func forTests(perturbations: Bool) throws -> Simulation {
        let system = try SolarSystem.bundled()
        if !perturbations {
            system.perturbers = []
            system.earth.j2 = 0
        }
        return Simulation(system: system, time: Epoch(utcYear: 1969, month: 7, day: 16, hour: 13, minute: 32))
    }

    /// Put `v` at rest 500 000 km from Earth, opposite the Moon, with its +x
    /// axis perpendicular to the radius, so gravity has no component along
    /// it. Returns that axis (ICRF).
    @discardableResult
    func placeInFreeSpace(_ v: Vessel) -> Vec3 {
        let s = snapshot
        let moonDir = (s.position(system.moon) - s.position(system.earth)).normalized
        v.reference = system.earth
        v.position = moonDir * -5e8
        v.velocity = .zero
        let x = moonDir.cross(.unitZ).normalized, z = moonDir, y = z.cross(x)
        v.attitude = Quat(matrix: Mat3(columns: x, y, z))
        return x
    }

    /// One fixed step of `h` seconds, applying the controls first as `advance` does.
    func tick(_ h: Double = 0.02) {
        for v in vessels { prepareControls(v) }
        step(h)
    }

    /// `seconds` of fixed 0.02 s steps; `afterEach` runs after every step.
    func run(seconds: Double, afterEach: () -> Void = {}) {
        for _ in 0..<Int((seconds / 0.02).rounded()) {
            tick()
            afterEach()
        }
    }
}
