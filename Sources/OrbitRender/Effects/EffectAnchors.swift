import Foundation
import simd
import OrbitCore
import OrbitScene

// The frame's anchors and air on the GPU: each `AnchorFrame` (double
// precision, camera-relative, OrbitScene) becomes ParticleShaders'
// ParticleAnchor in float, the only place an anchor's large numbers meet
// the camera's; each `AirProfile` becomes 64 levels of two float4.

/// ParticleShaders' ParticleAnchor.
struct ParticleAnchorGPU: Equatable {
    var origin = SIMD4<Float>.zero
    var toWorld0 = SIMD4<Float>.zero
    var toWorld1 = SIMD4<Float>.zero
    var toWorld2 = SIMD4<Float>.zero
    var up = SIMD4<Float>.zero
    var east = SIMD4<Float>.zero
    var north = SIMD4<Float>.zero
    var gravity = SIMD4<Float>(0, 0, 0, -1)
    var air = SIMD4<Float>.zero
    var rotation = SIMD4<Float>.zero

    /// An empty slot: particles left in it die.
    static let none = ParticleAnchorGPU()

    init() {}

    init(_ a: AnchorFrame) {
        origin = SIMD4(a.origin, 1)
        toWorld0 = SIMD4(a.toWorld.c0, 0)
        toWorld1 = SIMD4(a.toWorld.c1, 0)
        toWorld2 = SIMD4(a.toWorld.c2, 0)
        up = SIMD4(a.up, Float(a.altitude))
        // Float has no infinity under fast math: no ground is very far below.
        east = SIMD4(a.east, Float(max(a.groundAltitude, -1e30)))
        north = SIMD4(a.north, Float(a.radius))
        gravity = SIMD4(a.gravity, Float(a.airProfile ?? -1))
        air = SIMD4(a.airVelocity, Float(a.sunlitFraction))
        rotation = SIMD4(a.rotation, Float(a.vacuumIceTemperature))
    }

    /// The live anchors, dense by slot (empty slots between), at least one.
    static func pack(_ anchors: [(id: EffectAnchorID, frame: AnchorFrame)]) -> [ParticleAnchorGPU] {
        let count = max(1, (anchors.map(\.id.slot).max() ?? -1) + 1)
        var out = [ParticleAnchorGPU](repeating: .none, count: count)
        for a in anchors { out[a.id.slot] = ParticleAnchorGPU(a.frame) }
        return out
    }
}

/// The frame's air profiles as ParticleShaders reads them: per profile, per
/// level, (density, temperature, pressure, 0) then (wind east, north, 0, 0).
enum AirProfilesGPU {
    static func pack(_ profiles: [AirProfile]) -> [SIMD4<Float>] {
        var out: [SIMD4<Float>] = []
        for p in profiles {
            for i in 0..<AirProfile.count {
                out.append(SIMD4(Float(p.density[i]), Float(p.temperature[i]), Float(p.pressure[i]), 0))
                out.append(SIMD4(Float(p.windEast[i]), Float(p.windNorth[i]), 0, 0))
            }
        }
        // One level of vacuum when there is no air, so the buffer is never empty.
        return out.isEmpty ? [SIMD4(0, 3, 0, 0), .zero] : out
    }
}
