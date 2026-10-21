import Foundation
import simd

// The shared uniforms every pass can read, and the binding table: Swift
// mirrors of ShaderCommon's structs. F0 reserves every field now, so no
// track edits ShaderCommon: a track fills the fields it owns (noted per
// field) and leaves the rest. A change to this contract is a small PR to
// the render foundation, merged first.

/// Fixed binding slots, the same in every module and every stage
/// (ShaderCommon's `ORBIT_*` defines). Buffers 0-27, textures 0-18 and
/// samplers 0-13 are each pass's own.
public enum Binding {
    // Buffers.
    /// `AtmosphereUniforms` (A2, C2).
    public static let atmosphereBuffer = 28
    /// `LightingUniforms` (R3, R4, P2).
    public static let lightingBuffer = 29
    /// `FrameUniforms` (the frame graph).
    public static let frameBuffer = 30

    // Textures.
    /// The resolved scene depth (depth2d<float>, reversed-Z), for passes after P1.
    public static let sceneDepth = 19
    /// Prefiltered environment radiance (texturecube<float>, GGX mips; R3).
    public static let environmentSpecular = 20
    /// Environment irradiance (texturecube<float>, 16²; R3).
    public static let environmentIrradiance = 21
    /// The split-sum DFG LUT (texture2d<float>, rg; R2).
    public static let dfgLUT = 22
    /// Sun shadow maps (depth2d_array<float>; R4).
    public static let shadowAtlas = 23
    /// Cloud shadow over the ground (texture2d<float>; C2).
    public static let cloudShadow = 24
    /// Atmospheric transmittance (texture2d<float>; A2).
    public static let transmittanceLUT = 25
    /// Blue noise (texture2d<float>; R1).
    public static let blueNoise = 26
    /// The tone curve, 33³ over log2 input (texture3d<float>; R1).
    public static let toneLUT = 27
    /// Multiple scattering (texture2d<float>; A2).
    public static let multipleScatteringLUT = 28
    /// The sky as seen from the camera (texture2d<float>; A2).
    public static let skyViewLUT = 29
    /// Aerial-perspective froxels (texture3d<float>; A2).
    public static let aerialPerspective = 30

    // Samplers.
    /// Linear filtering, clamped to the edge.
    public static let linearClampSampler = 14
    /// Depth comparison (greater-equal, reversed-Z) for the shadow maps.
    public static let shadowCompareSampler = 15
}

/// Per-frame values (buffer 30, every stage). Written by the frame graph
/// before P0, except the members marked for a track.
public struct FrameUniforms {
    /// Camera-relative world to clip: the rotation-only view, then the
    /// reversed-Z infinite projection.
    public var viewProjection = matrix_identity_float4x4
    /// World to view, rotation only.
    public var view = matrix_identity_float4x4
    public var projection = matrix_identity_float4x4
    /// View to world, rotation only.
    public var viewToWorld = matrix_identity_float4x4
    /// Last frame's `viewProjection` (its own camera-relative frame), for
    /// reprojection; this frame's on a temporal reset.
    public var previousViewProjection = matrix_identity_float4x4
    /// xy: size in pixels, zw: their reciprocals.
    public var viewport = SIMD4<Float>.zero
    /// x: near plane (m), y: tan(fovY/2), z: aspect, w: render scale.
    public var camera = SIMD4<Float>.zero
    /// x: wall-clock s mod 3600, y: wall-clock dt (s), z: scene simulation
    /// s mod 86400, w: simulation dt (s).
    public var time = SIMD4<Float>.zero
    /// x: frame index mod 2^24, y: warp, z: 1 when paused, w: 1 on a temporal reset.
    public var frame = SIMD4<Float>.zero
    /// x: pre-exposure (1 until R1), y: EV100, z: pre-exposure over last
    /// frame's, w: exposure compensation (EV). R1.
    public var exposure = SIMD4<Float>(1, 0, 1, 0)
    /// xyz: unit vector from the camera to the Sun (world), w: its angular radius (rad).
    public var sunDirection = SIMD4<Float>.zero
    /// rgb: the Sun's illuminance at the camera above any air (lux, linear
    /// Rec. 709; white until R1 colours it), w: total (lux).
    public var sunIlluminance = SIMD4<Float>.zero
    /// xyz: the camera's position fixed to the body nearest it, modulo the
    /// tile (m), for planet-fixed noise; w: the tile, 2^15 m.
    public var noiseOrigin = SIMD4<Float>.zero
    /// xy: subpixel jitter (pixels), zw: blue-noise offset (pixels). R1, R7.
    public var jitter = SIMD4<Float>.zero
    /// x: the debug view (`DebugView`'s index), y: 1 when timings show.
    public var debug = SIMD4<Float>.zero
    /// x: pixels per point.
    public var pointScale = SIMD4<Float>.zero
    public var reserved = (SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero)

    public init() {}
}

/// A local light (plume lights: P2 writes, R2 shades).
public struct LocalLight {
    /// xyz: camera-relative position (m), w: source radius (m).
    public var positionRadius = SIMD4<Float>.zero
    /// xyz: unit axis of a line light, w: its length (m; 0 for a point).
    public var axisLength = SIMD4<Float>.zero
    /// rgb: luminous intensity (cd), w: range (m).
    public var intensity = SIMD4<Float>.zero

    public init() {}
}

/// Lights and shadows (buffer 29, every stage), written in P0.
public struct LightingUniforms {
    public static let maxLocalLights = 8
    public static let maxShadowMaps = 4

    /// Camera-relative world to each shadow map's clip space: level 0 per
    /// vessel cluster, level 1 around the camera target, debris. R4.
    public var shadowMatrices = (matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4,
                                 matrix_identity_float4x4)
    /// Per map: x: atlas layer, y: texel size (m), z: depth range (m), w: 1 in use. R4.
    public var shadowMaps = (SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero)
    /// x: maps in use, y: filter samples, z: normal-offset bias (texels), w: slope bias. R4.
    public var shadowParams = SIMD4<Float>.zero
    /// rgb: the probe's irradiance as SH9 coefficients. R3.
    public var sh9 = (SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero,
                      SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero)
    /// xyz: the probe's centre (camera-relative, m), w: specular mip count. R3.
    public var probe = SIMD4<Float>.zero
    /// rgb: the night floor relative to the exposure, w: earthshine scale. R3.
    public var ambient = SIMD4<Float>.zero
    /// x: local lights in use. P2.
    public var lightCount = SIMD4<Float>.zero
    public var lights = (LocalLight(), LocalLight(), LocalLight(), LocalLight(), LocalLight(), LocalLight(),
                         LocalLight(), LocalLight())
    public var reserved = (SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero)

    public init() {}
}

/// The atmosphere's state for every pass that looks through air (buffer
/// 28, every stage): A2 writes it in P0, C2 its cloud members.
public struct AtmosphereUniforms {
    /// World to the planet's body axes, rotation only.
    public var worldToBody = matrix_identity_float4x4
    /// xyz: camera-relative centre of the planet the camera is in or
    /// nearest (m), w: its bottom radius (m).
    public var planetCenter = SIMD4<Float>.zero
    /// x: bottom radius, y: top of the atmosphere (m), z: camera altitude (m), w: 1 when there is air.
    public var radii = SIMD4<Float>.zero
    /// rgb: Rayleigh scattering at the ground (1/m), w: its scale height (m).
    public var rayleighScattering = SIMD4<Float>.zero
    /// rgb: aerosol scattering at the ground (1/m), w: its scale height (m).
    public var mieScattering = SIMD4<Float>.zero
    /// rgb: aerosol extinction (1/m), w: the phase function's asymmetry g.
    public var mieExtinction = SIMD4<Float>.zero
    /// rgb: ozone absorption at the layer's peak (1/m), w: the layer's centre altitude (m).
    public var ozoneAbsorption = SIMD4<Float>.zero
    /// x: the ozone layer's width (m).
    public var ozoneLayer = SIMD4<Float>.zero
    /// rgb: the ground's mean albedo.
    public var groundAlbedo = SIMD4<Float>.zero
    /// rgb: the Sun's colour transmitted to the camera, w: its illuminance (lux).
    public var sunTransmitted = SIMD4<Float>.zero
    /// rgb: sky irradiance at the camera (lux), for vessels and clouds.
    public var skyIrradiance = SIMD4<Float>.zero
    /// x: froxel slices, y: their far distance (m), z: slice distribution exponent.
    public var aerialPerspective = SIMD4<Float>.zero
    /// Camera-relative world to the cloud shadow map's uv (C2).
    public var cloudShadowMatrix = matrix_identity_float4x4
    /// x: cloud base, y: cloud top (m above the ground), z: mean cover, w: 1 when clouds are drawn (C2).
    public var cloudLayer = SIMD4<Float>.zero
    public var reserved = (SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero, SIMD4<Float>.zero)

    public init() {}
}

/// Vertex v2, 64 bytes (R2 adopts it; VisualShape's surface coordinates fill it).
public struct VertexV2 {
    /// xyz: construction frame (m), w: baked ambient occlusion (1 = open).
    public var positionAO: SIMD4<Float>
    /// xyz: unit normal, w: `SurfaceIDs.packed`.
    public var normalIDs: SIMD4<Float>
    /// xyz: unit tangent along increasing azimuth, w: the bitangent's sign (±1).
    public var tangent: SIMD4<Float>
    /// x: station u (m), y: azimuth v (rad), z: local radius r (m), w: profile arc s (m).
    public var surface: SIMD4<Float>

    public init(positionAO: SIMD4<Float>, normalIDs: SIMD4<Float>, tangent: SIMD4<Float>, surface: SIMD4<Float>) {
        self.positionAO = positionAO
        self.normalIDs = normalIDs
        self.tangent = tangent
        self.surface = surface
    }
}
