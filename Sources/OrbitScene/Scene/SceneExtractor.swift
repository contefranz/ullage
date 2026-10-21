import Foundation
import OrbitCore

/// Builds each frame's `RenderScene` from the simulation and the camera.
/// It keeps what a frame needs from the frames before: the heat shield's
/// thermal lag, each vessel's captured geometry, the vessels seen last time
/// (for transitions) and the event cursor. Call `reset()` when a scenario
/// loads; a new `Simulation` resets it too.
public final class SceneExtractor {
    public struct Options {
        /// Draw the focus vessel's orbit and its markers.
        public var showOrbit: Bool

        public init(showOrbit: Bool = true) {
            self.showOrbit = showOrbit
        }
    }

    /// Body-fixed sites to place each frame (the launch complex).
    public var sites: [SitePlacement] = []
    /// Where the core's events come from for this simulation: its journal's
    /// adapter once there is one; none until then, and transitions come from
    /// vessels appearing and going alone.
    public var eventSource: (Simulation) -> SceneEventSource? = { _ in nil }

    /// The temporal history goes stale when the body nearest the camera
    /// turns more than this between two scenes, rad (0.5°).
    public static let maximumTurnPerFrame = 0.5 * Double.pi / 180

    private struct Previous {
        var sim: ObjectIdentifier
        var time: Epoch
        var realTime: Double
        var warp: Double
        var target: CameraTarget
        var frameIndex: Int
        /// The epoch the scene clock counts from.
        var epoch: Epoch
        var vessels: [UUID: Seen]
    }

    /// A vessel as the last scene saw it: barycentric position, m.
    struct Seen {
        var name: String
        var position: Vec3
    }

    private var previous: Previous?
    private var thermal: [UUID: (flux: Double, time: Epoch)] = [:]
    private var geometry: [UUID: VesselGeometry] = [:]
    private var eventCursor: UInt64 = 0

    public init() {}

    /// Forget the history: the next scene starts a new sequence.
    public func reset() {
        previous = nil
        thermal = [:]
        geometry = [:]
        eventCursor = 0
    }

    public func extract(sim: Simulation, camera cam: OrbitCamera, viewport: RenderScene.Viewport, realTime: Double,
                        options: Options = Options()) -> RenderScene {
        if let p = previous, p.sim != ObjectIdentifier(sim) { reset() }
        let snap = sim.snapshot
        let sunPos = snap.position(sim.system.sun)
        let prev = previous

        // Clock.
        let simDt = prev.map { sim.time - $0.time } ?? 0
        let epoch = prev?.epoch ?? sim.time
        var reset = prev == nil || prev!.target != cam.target || prev!.warp != sim.warp
        if !reset, let near = sim.system.bodies.min(by: {
            (snap.position($0) - cam.position).length < (snap.position($1) - cam.position).length
        }) {
            reset = snap.orientation(near).angularVelocity.length * abs(simDt) > Self.maximumTurnPerFrame
        }
        let clock = RenderScene.Clock(simTime: sim.time, simDt: simDt, realTime: realTime,
                                      realDt: prev.map { realTime - $0.realTime } ?? 0, warp: sim.warp,
                                      paused: sim.paused, frameIndex: (prev?.frameIndex ?? 0) + 1,
                                      simTimeOfScene: sim.time - epoch, temporalReset: reset)

        let camera = RenderScene.Camera(position: cam.position, worldToView: cam.worldToView, fovY: cam.fovY,
                                        viewport: viewport, target: cam.target, targetName: cam.targetName)
        let sunRel = sunPos - cam.position, sunDistance = sunRel.length
        let sun = RenderScene.Sun(position: sunRel, direction: sunRel.normalized, distance: sunDistance,
                                  illuminance: Photometry.solarIlluminance(distance: sunDistance),
                                  angularRadius: asin(min(1, sim.system.sun.radius / max(sunDistance, 1))))

        // Bodies, farthest first.
        let ordered = sim.system.bodies.sorted {
            (snap.position($0) - cam.position).length > (snap.position($1) - cam.position).length
        }
        let bodies = ordered.map { body in
            RenderScene.Body(id: body.id, name: body.name, position: snap.position(body) - cam.position,
                             orientation: snap.orientation(body), figure: body.figure, radius: body.radius,
                             isSun: body === sim.system.sun, toSun: (sunPos - snap.position(body)).normalized)
        }

        // Vessels, their emitters and canopies.
        var vessels: [RenderScene.Vessel] = [], emitters: [RenderScene.Emitter] = []
        var canopies: [RenderScene.Canopy] = []
        for v in sim.vessels {
            let geo = vesselGeometry(v)
            let rel = snap.position(v.reference) + v.position - cam.position
            var poses: [RenderScene.ThrusterKey: RenderScene.ThrusterPose] = [:]
            for t in v.thrusters {
                poses[ObjectIdentifier(t)] = RenderScene.ThrusterPose(direction: t.direction,
                                                                     thrustDirection: t.thrustDirection)
            }
            let tinted = v.thrusters.first { $0.isDelivering && ($0.groups.contains(.main) || $0.isSolid) }
            vessels.append(RenderScene.Vessel(
                id: v.id, name: v.name, isFocus: v === sim.focus, status: v.status, isLanded: v.landed != nil,
                referenceBodyID: v.reference.id, position: rel, attitude: v.attitude,
                structureOrigin: v.structureOrigin, boundingRadius: v.boundingRadius, geometry: geo, thrusters: poses,
                light: LegacyLighting.light(v, snapshot: snap, system: sim.system, sun: sunPos),
                glow: heatShieldGlow(v, time: snap.time), flowDirection: LegacyLighting.flowDirection(v, snapshot: snap),
                farPointStyle: tinted.map(PlumeStyle.init), heatFlux: v.heatFlux, heatLoad: v.heatLoad))
            emitters += Self.emitters(of: v, geometry: geo, at: rel)
            canopies += CanopyGeometry.canopies(of: v, at: rel, snapshot: snap)
        }
        let live = Set(sim.vessels.map(\.id))
        if thermal.keys.contains(where: { !live.contains($0) }) { thermal = thermal.filter { live.contains($0.key) } }
        if geometry.keys.contains(where: { !live.contains($0) }) { geometry = geometry.filter { live.contains($0.key) } }

        var transitions: [RenderScene.Transition] = []
        if let source = eventSource(sim) {
            let drained = source.sceneEvents(after: eventCursor)
            eventCursor = drained.cursor
            transitions += drained.events.map { .event($0) }
        }
        if let prev { transitions += Self.diff(sim.vessels, against: prev.vessels, camera: cam.position, snapshot: snap) }

        previous = Previous(sim: ObjectIdentifier(sim), time: sim.time, realTime: realTime, warp: sim.warp,
                            target: cam.target, frameIndex: clock.frameIndex, epoch: epoch,
                            vessels: Dictionary(uniqueKeysWithValues: sim.vessels.map {
                                ($0.id, Seen(name: $0.name, position: snap.position($0.reference) + $0.position))
                            }))
        return RenderScene(clock: clock, camera: camera, sun: sun, bodies: bodies, vessels: vessels,
                           emitters: emitters, canopies: canopies, sites: placeSites(sim: sim, snapshot: snap, camera: cam),
                           transitions: transitions,
                           orbit: options.showOrbit ? Self.orbitOverlay(sim: sim, snapshot: snap, camera: cam) : nil)
    }

    // MARK: Vessels

    private func vesselGeometry(_ v: Vessel) -> VesselGeometry {
        if let g = geometry[v.id], g.signature == VesselGeometry.signature(of: v) { return g }
        let g = VesselGeometry(of: v)
        geometry[v.id] = g
        return g
    }

    /// The heat flux through the heat shield's thermal lag
    /// (`LegacyLighting.thermalLag`, simulation time), as a glow.
    private func heatShieldGlow(_ v: Vessel, time: Epoch) -> RenderScene.RGB {
        var state = thermal[v.id] ?? (v.heatFlux, time)
        let dt = time - state.time
        if dt < 0 || dt > 600 {
            state = (v.heatFlux, time)     // a reload or a long jump: no history
        } else if dt > 0 {
            state.flux += (v.heatFlux - state.flux) * (1 - exp(-dt / LegacyLighting.thermalLag))
            state.time = time
        }
        thermal[v.id] = state
        return LegacyLighting.glowColor(heatFlux: state.flux)
    }

    /// One emitter per thruster delivering thrust, from its nozzle's exit
    /// turned with its gimbal (or from its position, with a nominal exit, for
    /// a jet without a nozzle shape).
    static func emitters(of v: Vessel, geometry: VesselGeometry, at rel: Vec3) -> [RenderScene.Emitter] {
        var out: [RenderScene.Emitter] = []
        let pressure = v.atmosphere.pressure
        for part in v.parts {
            for t in part.thrusters where t.isDelivering {
                let rating = t.currentRating.thrustVacuum
                guard rating > 0 else { continue }
                let fraction = t.thrust(ambientPressure: pressure, seaLevelPressure: standardAtmosphere) / rating
                let r = t.gimbal.isEmpty ? Mat3.identity : Mat3.rotation(from: t.direction, to: t.thrustDirection)
                let exit: Vec3, radius: Double
                if let n = geometry.nozzles[ObjectIdentifier(t)] {
                    exit = n.pivot + r * (n.exit - n.pivot)
                    radius = n.radius
                } else {
                    exit = t.position + part.offset - v.structureOrigin
                    radius = PlumeStyle.nominalExitRadius(thrust: rating, solid: t.isSolid)
                }
                out.append(RenderScene.Emitter(
                    vesselID: v.id, thruster: ObjectIdentifier(t), name: t.name,
                    exit: rel + v.attitude.rotate(v.structureOrigin + exit), axis: v.attitude.rotate(-t.thrustDirection),
                    exitRadius: radius, style: PlumeStyle(t), thrustFraction: fraction,
                    pressureRatio: pressure / standardAtmosphere, isSolid: t.isSolid,
                    isJet: !t.isSolid && !t.groups.contains(.main)))
            }
        }
        return out
    }

    /// Vessels appearing and going since the last scene. A new vessel's
    /// parent is the nearest one that was there before.
    static func diff(_ vessels: [Vessel], against before: [UUID: Seen], camera: Vec3,
                     snapshot snap: SystemSnapshot) -> [RenderScene.Transition] {
        var out: [RenderScene.Transition] = []
        let now = Set(vessels.map(\.id))
        func position(_ v: Vessel) -> Vec3 { snap.position(v.reference) + v.position }
        for v in vessels where before[v.id] == nil {
            let p = position(v)
            let parent = vessels.filter { before[$0.id] != nil }
                .min { (position($0) - p).length < (position($1) - p).length }
            let relative = parent.map { $0.reference === v.reference ? v.velocity - $0.velocity : .zero } ?? .zero
            out.append(.vesselAppeared(id: v.id, name: v.name, parts: v.parts.map(\.name), parentID: parent?.id,
                                       position: p - camera, relativeVelocity: relative))
        }
        for (id, seen) in before where !now.contains(id) {
            out.append(.vesselRemoved(id: id, name: seen.name))
        }
        return out
    }

    // MARK: Sites

    private func placeSites(sim: Simulation, snapshot snap: SystemSnapshot, camera cam: OrbitCamera) -> [RenderScene.Site] {
        sites.compactMap { s in
            guard let body = sim.system.body(id: s.bodyID) else { return nil }
            let o = snap.orientation(body)
            let fixed = body.figure.bodyFixed(latitude: s.latitude, longitude: s.longitude, height: s.height)
            let up = Vec3(cos(s.latitude) * cos(s.longitude), cos(s.latitude) * sin(s.longitude), sin(s.latitude))
            let east = Vec3(-sin(s.longitude), cos(s.longitude), 0)
            let north = up.cross(east)
            let forward = north * cos(s.azimuth) + east * sin(s.azimuth)
            let left = up.cross(forward)
            let axes = Mat3(columns: o.toInertial(forward), o.toInertial(left), o.toInertial(up))
            return RenderScene.Site(name: s.name, bodyID: s.bodyID,
                                    origin: snap.position(body) + o.toInertial(fixed) - cam.position,
                                    orientation: axes, placement: s)
        }
    }

    // MARK: Orbit overlay

    /// The focus vessel's osculating conic about its reference body
    /// (camera-relative: the whole ellipse, or the arc through periapsis
    /// inside the sphere of influence) and the markers on it no body hides;
    /// nil while it stands on the ground.
    static func orbitOverlay(sim: Simulation, snapshot snap: SystemSnapshot,
                             camera cam: OrbitCamera) -> RenderScene.OrbitOverlay? {
        guard let focus = sim.focus, focus.landed == nil else { return nil }
        let center = snap.position(focus.reference) - cam.position
        let el = focus.elements(snapshot: snap)
        var strips: [[Vec3]] = []
        let points = el.conicPoints(512, maxRadius: min(focus.reference.soiRadius, 5e9))
        if points.count > 1 { strips.append(points.map { center + $0 }) }
        let occulters = sim.system.bodies.map { (snap.position($0) - cam.position, $0.figure.polarRadius) }
        var markers: [RenderScene.OrbitMarker] = []
        for marker in orbitMarkers(elements: el, body: focus.reference) {
            let p = center + marker.position
            // Whole or not at all: hidden when a body is in the way of its anchor.
            if occulters.contains(where: { segmentHits(to: p, sphere: $0.0, radius: $0.1) }) { continue }
            markers.append(RenderScene.OrbitMarker(kind: marker.kind, position: p, text: marker.text))
        }
        return RenderScene.OrbitOverlay(strips: strips, markers: markers)
    }

    /// Whether the segment from the camera (the origin) to `p` passes
    /// through the sphere at `c` of radius `r` (all camera-relative, m).
    static func segmentHits(to p: Vec3, sphere c: Vec3, radius r: Double) -> Bool {
        let t = max(0, min(1, c.dot(p) / max(p.lengthSquared, 1e-12)))
        return (c - p * t).length < r
    }

    /// Where the markers sit on the conic, from the body's centre (ICRF, m):
    /// Pe at ν = 0 and Ap at ν = π (an ellipse inside the sphere of
    /// influence), with their heights above the equatorial radius as the HUD
    /// gives them; AN and DN on the body's equator; EI where the orbit comes
    /// down through 400,000 ft over the equatorial radius
    /// (`EntryInterface.standardHeight`).
    static func orbitMarkers(elements el: OrbitalElements,
                             body: CelestialBody) -> [(kind: OrbitMarkerKind, position: Vec3, text: String?)] {
        let a = body.figure.equatorialRadius, limit = min(body.soiRadius, 5e9)
        func height(_ r: Double) -> String {
            let km = (r - a) / 1_000
            return abs(km) < 10_000 ? String(format: "%.1f km", km) : String(format: "%.0f km", km)
        }
        var out: [(kind: OrbitMarkerKind, position: Vec3, text: String?)] = []
        guard el.semiLatusRectum > 0 else { return out }
        if el.periapsisRadius < limit {
            out.append((.periapsis, el.position(atTrueAnomaly: 0), height(el.periapsisRadius)))
        }
        if el.isBound, el.apoapsisRadius < limit {
            out.append((.apoapsis, el.position(atTrueAnomaly: Double.pi), height(el.apoapsisRadius)))
        }
        if let p = el.ascendingNode, p.length < limit { out.append((.ascendingNode, p, nil)) }
        if let p = el.descendingNode, p.length < limit { out.append((.descendingNode, p, nil)) }
        if let nus = el.trueAnomalies(atRadius: a + EntryInterface.standardHeight) {
            out.append((.entryInterface, el.position(atTrueAnomaly: nus.inbound), nil))
        }
        return out
    }
}
