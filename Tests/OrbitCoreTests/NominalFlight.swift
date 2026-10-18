import XCTest
@testable import OrbitCore

/// Apollo 11 flown once, IU and all, for the tests that only read its
/// history: the stack and every spent stage, recorded after each step around
/// the S-IC/S-II separation, the tower jettison and the S-II/S-IVB separation,
/// and every 0.5 s otherwise. Steps
/// are 0.02 s at most and end on IU events and solid-motor burnouts, as
/// `Simulation.advance` steps; the flight runs on to 1,300 s of range time,
/// so the spent S-IC and S-II come down.
final class NominalFlight {
    struct State {
        let position: Vec3, velocity: Vec3, attitude: Quat, angularVelocity: Vec3
        let structureOrigin: Vec3, mass: Double, thrustAcceleration: Double, altitude: Double
        let status: VesselStatus
        let tanks: [String: Double]

        /// Inertial position of a point in construction coordinates.
        func inertialPosition(ofStructuralPoint p: Vec3) -> Vec3 { position + attitude.rotate(p + structureOrigin) }
    }

    struct Sample {
        let range: Double
        /// By vessel name: "Apollo 11", "Apollo 11 – S-IC", ...
        let vessels: [String: State]
    }

    static let shared = NominalFlight()
    static let end = 1_300.0
    /// Range times recorded at every step.
    static let dense: [ClosedRange<Double>] = [160...175, 196...215, 545...570]

    let sim: Simulation
    let stack: Vessel
    let iu: SaturnIU
    private(set) var samples: [Sample] = []

    private init() {
        sim = try! Simulation.forTests(perturbations: true)
        stack = VesselLibrary.apollo11OnPad(in: sim)
        stack.mainThrottle = 1
        iu = stack.flightProgram as! SaturnIU
        record()
        var lastSparse = 0.0
        while range() < Self.end {
            for v in sim.vessels { sim.prepareControls(v) }
            sim.step(min(0.02, sim.maxStep()))
            let r = range()
            if Self.dense.contains(where: { $0.contains(r) }) || r - lastSparse >= 0.5 {
                record()
                lastSparse = r
            }
        }
    }

    /// Range time now, s.
    func range() -> Double { sim.time - AS506.rangeZero }
    /// Range time of an epoch (an IU log entry).
    func range(_ e: Epoch) -> Double { e - AS506.rangeZero }

    private func record() {
        var states: [String: State] = [:]
        for v in sim.vessels {
            states[v.name] = State(position: v.position, velocity: v.velocity, attitude: v.attitude,
                                   angularVelocity: v.angularVelocity, structureOrigin: v.structureOrigin,
                                   mass: v.mass, thrustAcceleration: v.thrustAcceleration, altitude: v.altitude,
                                   status: v.status,
                                   tanks: Dictionary(v.parts.flatMap(\.tanks).map { ($0.name, $0.mass) },
                                                     uniquingKeysWith: +))
        }
        samples.append(Sample(range: range(), vessels: states))
    }

    /// The last sample at or before `range` (the first one before the start).
    func sample(at range: Double) -> Sample {
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if samples[mid].range <= range + 1e-9 { lo = mid } else { hi = mid - 1 }
        }
        return samples[lo]
    }

    /// The samples within `range`.
    func samples(in range: ClosedRange<Double>) -> [Sample] { samples.filter { range.contains($0.range) } }

    /// Range time of the IU log entry `event`, if it was logged.
    func time(of event: String) -> Double? { iu.log.first { $0.event == event }.map { range($0.time) } }
}
