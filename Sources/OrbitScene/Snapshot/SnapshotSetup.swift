import Foundation
import OrbitCore

extension SnapshotSpec.Shot {
    /// A shot's scenario after its script, with the camera placed and the
    /// extractor that followed the flight.
    public struct Prepared {
        public let scenario: Scenario
        public let sim: Simulation
        public let camera: OrbitCamera
        public let extractor: SceneExtractor
        /// What the extractor saw happen while the script ran (the journal's
        /// events and vessels appearing), which the shot's frame carries too.
        public let advanceTransitions: [RenderScene.Transition]
    }

    public enum Failure: Error, CustomStringConvertible {
        case unknownScenario(String)
        case badCamera(String)

        public var description: String {
            switch self {
            case .unknownScenario(let id): "no scenario \"\(id)\""
            case .badCamera(let what): "bad camera \(what)"
            }
        }
    }

    public var viewport: RenderScene.Viewport {
        RenderScene.Viewport(width: Double(width), height: Double(height), pointScale: pointScale)
    }

    /// Builds the scenario as the app loads it, runs the advance script (the
    /// extractor following the flight once per simulated second or so, which
    /// warms the heat shield's thermal lag), places the camera and pauses.
    public func prepare(system: SolarSystem) throws -> Prepared {
        guard let scenario = Scenario.named(self.scenario) else { throw Failure.unknownScenario(self.scenario) }
        let sim = scenario.build(system)
        let extractor = SceneExtractor()
        var camera = OrbitCamera()
        if let focus = sim.focus {
            camera.target = .vessel(focus.id)
            camera.distance = max(focus.boundingRadius * 3, 30)
        }
        camera.update(sim: sim)
        let viewport = self.viewport, realTime = self.realTime
        var transitions: [RenderScene.Transition] = []
        try ScenarioScript(advance).run(on: sim, missionClockZero: scenario.missionClockZero) { sim in
            camera.update(sim: sim)
            transitions += extractor.extract(sim: sim, camera: camera, viewport: viewport, realTime: realTime).transitions
        }
        try self.camera.apply(to: &camera, sim: sim)
        sim.paused = true
        return Prepared(scenario: scenario, sim: sim, camera: camera, extractor: extractor,
                        advanceTransitions: transitions)
    }

    /// The frame's scene. Its transitions are everything since the scenario
    /// opened, oldest first, so effects can start every burst still alive
    /// at its true age, as they would have in the app.
    public func scene(_ p: Prepared) -> RenderScene {
        var scene = p.extractor.extract(sim: p.sim, camera: p.camera, viewport: viewport, realTime: realTime,
                                        options: SceneExtractor.Options(showOrbit: showOrbit))
        scene.transitions = p.advanceTransitions + scene.transitions
        return scene
    }
}

extension SnapshotSpec.CameraSpec {
    /// Places `camera` as the spec says, for `sim` as it is now.
    public func apply(to camera: inout OrbitCamera, sim: Simulation) throws {
        let t = target.lowercased()
        if t == "focus" {
            guard let v = sim.focus else { throw SnapshotSpec.Shot.Failure.badCamera("target: no focus vessel") }
            camera.target = .vessel(v.id)
        } else if t.hasPrefix("vessel:") {
            let name = String(target.dropFirst("vessel:".count))
            guard let v = ScenarioScript.vessel(named: name, in: sim) else {
                throw SnapshotSpec.Shot.Failure.badCamera("target: no vessel \"\(name)\"")
            }
            camera.target = .vessel(v.id)
        } else if t.hasPrefix("body:"), let id = Int(t.dropFirst("body:".count)), sim.system.body(id: id) != nil {
            camera.target = .body(id)
        } else {
            throw SnapshotSpec.Shot.Failure.badCamera("target \"\(target)\"")
        }
        guard let f = OrbitCamera.Frame.allCases.first(where: { $0.rawValue.lowercased() == frame.lowercased() }) else {
            throw SnapshotSpec.Shot.Failure.badCamera("frame \"\(frame)\"")
        }
        camera.frame = f
        camera.yaw = yaw * Double.pi / 180
        camera.pitch = pitch * Double.pi / 180
        switch (distance, camera.target) {
        case (let d?, _): camera.distance = d
        case (nil, .vessel(let id)):
            camera.distance = max((sim.vessels.first { $0.id == id }?.boundingRadius ?? 10) * 3, 30)
        case (nil, .body(let id)):
            camera.distance = (sim.system.body(id: id)?.radius ?? 1e6) * 3
        }
        switch lens?.lowercased() {
        case nil: camera.fovY = fov * Double.pi / 180
        case "hasselblad80": camera.fovY = OrbitCamera.hasselblad80mm
        case "hasselblad250": camera.fovY = OrbitCamera.hasselblad250mm
        default: throw SnapshotSpec.Shot.Failure.badCamera("lens \"\(lens!)\"")
        }
        camera.update(sim: sim)
    }
}
