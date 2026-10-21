# M1.6/M2 design: Renderer core

> Planning document for the M1.5 close-out, milestone M1.6 (graphics overhaul) and M2 (Apollo 8), written on 2026-10-20 by a design study (six design reports checked by a planner) and accepted by Franz on 2026-10-21 with all recommended defaults (US keyboard). Track briefs refer to it. Where code has moved on, the code wins.


This is a design report. Where it conflicts with plan.md, the plan wins: the planner checked and corrected the reports.


## Current state

main is at 6a1851b. The renderer is Sources/OrbitSim/Rendering, about 1,930 lines.

**Frame loop**
- Renderer.swift:62-90 sets up the MTKView: bgra8Unorm_srgb with no HDR, depth32Float, MTKView-managed 4× MSAA (:72, stored, not memoryless), reversed-Z cleared to 0, 60 fps.
- :94-167 builds six pipelines from one library compiled from one MSL string. A compile error disables the whole renderer (:77-82).
- :170-194 loads optional user textures from Application Support.
- :230-467 is the frame:
  - `model.tick(dt)` runs the simulation inside the draw callback (:237).
  - One render pass draws, in order: stars (:270-278), bodies farthest first with premultiplied sky (:280-329), vessels per mesh group with setVertexBytes (:331-381), the orbit line (:385-428), additive plume impostors (:430-438), far points (:440-448) and marker sprites (:450-461).
  - It commits and presents (:463-466).
- FrameArena (:748-780) is a 3-frame ring buffer. FrameTimes (:783-792) measures GPU and encode time, but nothing displays it.

**Lighting**
- vesselLight (:491-517) gives the sunlit fraction from Eclipse.sunlitFraction, an analytic earthshine (albedo × (R/r)² × lit cap), a skylight hack (0.25·√ρ, :482) and an ambient floor of 0.02 (:479).
- The heat-shield glow (:543-574) uses a first-order lag in sim time and Tanner Helland's blackbody fit.
- There are no shadows, no IBL, no specular term and no tone mapping. Values above 1 clip in the sRGB drawable.

**Shaders (Shaders.swift:10-346)**
- planet_fragment (:62-142) ray-traces the WGS-84 ellipsoid with CPU-double origin terms (:73-79). It draws the sky at 85% opacity (:95-96) and lights the surface with Lambert plus haze (:129-136). The Sun is drawn as baseColor × 4 (:113).
- mesh_fragment (:186-198) is Lambert from the Sun plus earthshine plus ambient, with an emissive glow on role-1 vertices.
- Point, line, plume and sprite shaders follow (:200-345).
- RenderTypes.swift keeps the float4-only uniform rule (:5-6) and defines `reversedInfinitePerspective` (:119-127). The near plane is 0.25 m (Renderer.swift:60).

**Meshes and appearance**
- Meshes.swift:15-97 builds closed, open and gimballed vertex groups. A vertex is position, normal and colour, with the emissive role in w (:99-105). There are no UVs, tangents or material IDs.
- VisualShape.swift has three kinds: frustum, sphere and revolution. It carries an RGB colour and an EmissiveRole only.
- ApolloShapes.swift:225-228 defines the whole appearance as 11 RGB constants (white, dark, grey, aluminium, silver, ablator, nozzle extension, gold, canvas).
- Plumes.swift:17-135 draws additive cone impostors with a visibility floor of 0.3 in arbitrary units.

**HUD, camera, packaging and timing**
- HUD/NavballRenderer.swift draws the navball in its own transparent MTKView. It already renders offscreen (`renderToImage`, :203-254, with the ORBITSIM_NAVBALL_GALLERY env var at NavballView.swift:27), which is the precedent for a snapshot mode.
- Camera.swift is pure Swift with Double poses.
- Scenarios.swift lives in the app target, so no tool or test outside the app can build scenarios.
- Package.swift builds the OrbitSim executable on macOS only. There is no render library and no render test target, so nothing in the renderer is tested.
- AppModel.swift:86-88 sets stepBudget to 0.04 s and maxFrameInterval to 0.1 s. Simulation.swift:99-117 honours the deadline.
- Measured baseline (project memory): 22 fps at any warp, 60 fps at 10× in Debug, 290–730× achieved powered-flight warp in Release.

**Earlier plan and hardware**
- docs/m15/design-graphics.md listed this exact work as out of scope: HDR and bloom, PBR with IBL, shadow maps, precomputed scattering.
- The owner's Mac is an M3 Pro (18-core GPU, Metal 4) with a 3024×1964 XDR display that can show EDR, running macOS 27 and Xcode 27.1. The package deploys to macOS 14.

## Design

## Principles

- **One HDR scene in physical units.** The scene is linear HDR in photometric units: luminance in cd/m², illuminance in lux. It is rendered camera-relative with infinite reversed-Z, exposed like a camera and tone mapped once. The orbit line and markers are drawn after tone mapping.
- **The renderer reads a snapshot.** It reads a value snapshot (RenderScene) built each frame, never live Vessel classes while it encodes.
- **Everything that is not Metal is pure Swift.** Scene extraction, camera and projection maths, shadow fitting, photometry, exposure, tone curves, the BRDF reference and LUT bakes, SH, AO baking, snapshot specs and image metrics all go in a new pure-Swift target that builds and tests on Linux.
- **Each pass owns its files.** A pass is a Swift file plus its own shader-source file, compiled into its own MTLLibrary. The cloud, plume, particle and vehicle-look sessions own disjoint files, and a broken shader disables one pass, not the renderer.
- **Everything is visible offscreen.** Every look change can be rendered deterministically by an AI session (`orbitsnap`), measured by numeric look tests and guarded by a small golden set.

## 1. Targets (R0)

- **OrbitScene** (new; pure Swift + Foundation, no simd; builds on Linux):
  - Scenarios, moved from OrbitSim/Scenarios.swift.
  - OrbitCamera, moved from Rendering/Camera.swift.
  - Scene/RenderScene and SceneExtractor.
  - Look/: Photometry, Exposure, ToneCurves, BRDF, Materials, MipBuilder, SphericalHarmonics, ShadowFitting, AmbientOcclusion with a BVH, RenderSettings.
  - Snapshot/: SnapshotSpec, ScenarioScript, ImageMetrics.
  - LookDev/: scenes.
  - Tests: Tests/OrbitSceneTests.
- **OrbitRender** (new; macOS-only library inside `#if os(macOS)`): today's Rendering files, moved and split.
  - Core/: SceneRenderer (offscreen-capable), ViewRenderer (the MTKView delegate: calls model.tick, then SceneRenderer), RenderPass, FrameGraph, RenderTargets, ShaderLibrary, GPUProfiler, OffscreenTarget, ImageWriters.
  - Passes/ and Shaders/.
  - Tests: Tests/OrbitRenderTests (macOS, needs the GPU).
- **orbitsnap** (new macOS executable): renders snapshot specs offscreen, with no window.
- **OrbitSim** keeps SwiftUI, input, HUD and MFDs, and links OrbitRender.

M1.5 split OrbitInstruments out the same way.

## 2. RenderScene (R0)

RenderScene is a value type, with Double wherever precision matters.

- **Times:** sim Epoch, simDt, realTime, realDt, warp, paused. `temporalReset` is set on a camera cut, a scenario load, a warp change, or when the planet turns more than 0.5° under the camera in one frame.
- **Camera:** barycentric position, worldToView, fovY, near, viewport, render scale.
- **Sun:** direction, distance, illuminance at the camera, angular radius.
- **Bodies:** camera-relative centre, orientation, radii, texture key, pixel radius.
- **Vessels:**
  - mesh signature;
  - camera-relative centre of mass and structure origin;
  - attitude and per-group gimbal rotations;
  - Eclipse sunlit fraction;
  - heatFlux and heatLoad;
  - frost (FER Table 20-1 masses);
  - bounding radius, pixel size and status.
- **Emitters:** one per firing thruster, with exit, axis, exit radius, Plumes.Style, thrust fraction, pressure ratio, solid and jet flags. This moves out of Renderer.appendPlumes :578-600.
- **Canopies:** moved out of drawCanopies :620-670.
- **Transitions:** derived by diffing against the previous frame, with world positions and relative velocities. No new core events are needed:
  - vesselAppeared(id, parent, parts, relative velocity), which covers staging, separation and jettison;
  - vesselRemoved;
  - ignition and cutoff per thruster;
  - chuteDeployed;
  - splashdown.

`SceneExtractor.extract(sim:camera:previous:clock:)` is tested on Linux.

## 3. Frame structure

R0 creates every slot; an empty slot costs nothing.

**P0 prepare** (each pass uses its own encoders):
- environment probe (R3);
- shadow maps (R4);
- cloud prepasses (cloud track): coverage, cloudShadow, and a low-resolution raymarch into cloudLayer (radiance and transmittance) plus cloudDepth. The raymarch works against the analytic planet, so it needs no scene depth.
- particle simulation (particle track);
- last frame's exposure.

**P1 opaque:** one MSAA 4× pass with memoryless rgba16Float colour and depth32Float.
- It draws stars and the Sun's disc, the planet surfaces, vessels, canopies and far points.
- Shaders write `encodeHDR(c) = c/(1+max(c))` (Karis), so the hardware resolve does not alias bright highlights.
- It resolves to hdrColor (rgba16Float, 1×) and sceneDepth (depth32Float, depthResolveFilter .min, which is the farthest sample in reversed-Z).

**P2 composite:** full-screen at 1×.
- It decodes and applies the atmosphere (sky, and aerial perspective, including over vessels) and the cloud layer, using sceneDepth.
- The slot belongs to the atmosphere/cloud track. R0's default is today's sky and haze, moved out of planet_fragment.
- Option: an in-tile per-sample composite before the resolve, if goldens show 1-px fringes where vessels stand against clouds.

**P3 transparent:** on hdrColor with sceneDepth read-only, plus an optional half-resolution premultiplied target (halfResTransparent) with a depth-aware upsample.
- Plumes (plume track), particles (particle track) and the plasma sheath.
- Each pass sorts its own items.

**P4 post (R1):**
- NaN guard, downsample and histogram;
- exposure;
- bloom;
- Sun visibility and starburst;
- tone-map 3D LUT, grade and vignette;
- optional MetalFX spatial upscale (R7);
- grain and dither into the drawable or the offscreen output.

**P5 overlay** (display space):
- the orbit line as anti-aliased quads, plus markers and labels (today's steps 4, 5 and 8);
- depth-tested by sampling sceneDepth.
- The navball stays in its own MTKView.

**Pass protocol** (OrbitRender/Core/RenderPass.swift):

```swift
@MainActor protocol RenderPass: AnyObject {
    var name: String { get }
    var stage: PassStage { get }
    var order: Int { get }
    var reads: Set<ResourceID> { get }
    var writes: Set<ResourceID> { get }
    func setUp(_ s: PassSetup) throws
    func resize(_ size: RenderSize)
    func encode(_ f: FrameContext, _ e: PassEncoding)
}
```

- PassEncoding is either `.commandBuffer` (for prepare and post) or `.render(MTLRenderCommandEncoder)` (for the shared opaque, transparent and overlay encoders).
- FrameContext carries the scene, the FrameUniforms buffer (buffer 30 in every stage), the LightingUniforms buffer (buffer 29: shadow matrices and bounds, SH9, up to 8 local lights; R0 reserves every field), the targets, the settings, the FrameArena and the profiler.
- FrameGraph:
  - sorts passes by stage and order;
  - checks at setup that every read is written earlier or is persistent (exposure, probe, history);
  - allocates transient textures from a pool keyed by descriptor, and reallocates them on resize or a render-scale change.

**Shader headers and modules:**
- ShaderCommon.swift (R0) holds:
  - the float4-only structs and the binding table: textures 20–27 are env specular, env irradiance, DFG LUT, shadow atlas, cloud shadow, transmittance LUT, blue noise and tone LUT; samplers 14 and 15 are linear-clamp and shadow-compare;
  - linear depth = near/d (exact for the infinite projection) and the view ray from a pixel;
  - encodeHDR and decodeHDR;
  - a NaN test written with `as_type<uint>`, since fast math may fold `isnan`.
- LightingCommon.swift (R2) holds the BRDF, IBL, sun disc, spec AA and local lights.
- ShadowCommon.swift holds `sunShadow()`. R0 ships it as a stub returning 1; R4 fills it in.
- Modules compile asynchronously at startup. scripts/check-shaders.sh runs `xcrun metal -Wall` on each one.

## 4. Units, exposure, tone mapping (R1)

**Units and pre-exposure.** Shaders multiply light by preExposure = 1/(1.2·2^EV100) from the previous frame, as Frostbite does, and post corrects by the ratio to this frame's exposure. Values are clamped to 6e4, because FP16 overflows above that.

**The Sun.**
- Illuminance E⊙ ≈ 1.28–1.34e5 lx at 1 AU (pin the value from Darula et al. 2005), scaled by 1/r².
- Colour: a 5772 K blackbody integrated with the Wyman CMFs into linear Rec.709, computed rather than hand-picked.
- Disc: 0.2666° radius with limb darkening, about 1.9e9 cd/m².
- With these numbers, sunlit white paint (albedo 0.8) has L ≈ 0.8·E/π ≈ 33,000 cd/m², which reads 0.84 at EV 15 ("sunny 16").

**Stars and far points.**
- Stars are V magnitude converted to lux and drawn as an energy-conserving 2-px point spread. They vanish beside a sunlit vehicle, as in the Apollo photographs, and come out in eclipse.
- Far vessels drawn as points get their brightness from albedo × cross-section × a Lambert-sphere phase. This replaces the fixed 0.9 at :604-611.

**Emissive surfaces.**
- `Photometry.blackbody(T)` gives luminance and chromaticity. It replaces Tanner Helland's fit and drives the glow and the plume cores.
- A legacy bridge scales today's planet colours by E⊙/π until the atmosphere track lands.

**Exposure.**
- **Auto (default):**
  - a 128-bin log-luminance histogram over EV −6 to +20, taken on the half-resolution bloom mip and centre-weighted;
  - the mean of the 50th to 95th percentile gives the target EV100 = log2(L·100/12.5) − compensation;
  - adaptation runs in wall-clock time: up 2 EV/s, down 1 EV/s;
  - EV is clamped to [−4, 17].
- **Manual:** a fixed EV100.
- **Snapshots:** manual unless the spec asks for auto with warm-up frames.

**Tone mapping.**
- One 33³ 3D LUT over log2 input, baked at startup from OrbitScene/Look/ToneCurves.swift, so the GPU and the tests share one implementation.
- **AgX (default):** a film-like roll-off in which fire and the Sun go to white. Port it from three.js (MIT; its constants come from Filament, Apache-2.0).
- **Khronos PBR Neutral (option):** keeps paint colours exact.

**Display.**
- SDR bgra8Unorm_srgb by default.
- Optional EDR: CAMetalLayer.wantsExtendedDynamicRangeContent, rgba16Float and extendedLinearDisplayP3, with the curve's white mapped to NSScreen.maximumExtendedDynamicRangeColorComponentValue. Goldens are always SDR.
- Triangular blue-noise dither of ±1 LSB before 8-bit output.

## 5. BRDF and materials (R2)

**Vertex v2** (64 bytes, four float4s):
- position + AO;
- normal + material index;
- tangent + sign;
- UV: lathe coordinates in metres (arc length along the profile and r·azimuth), which the vehicle-look track's procedural textures use, plus decal coordinates.

`VisualShape.triangles` gains UV and tangent output; this is a core change, tested in VisualShapeTests.

**Materials.**
- VisualShape gains a `material` name; the default is derived from the colour constants at ApolloShapes.swift:225-228.
- MaterialDefinition holds: model (paint, metal, foil, ablator, fabric or emissive), baseColor, roughness, metalness, F0 (metals computed from n,k), anisotropy, textureSet and emissiveRole.
- The GPU gets a material table and texture arrays.

**BRDF.**
- Lambert diffuse, GGX, Smith height-correlated visibility and Schlick Fresnel.
- Multiscatter compensation (Fdez-Agüera) from a 64² DFG LUT baked in Swift and checked by a furnace test.

**Material models.**
- **Paint:** F0 0.04, roughness 0.35–0.7.
- **Metal:** aluminium F0 ≈ 0.91 from Rakić's n,k data (CC0), roughness 0.2–0.5, optionally anisotropic along the lathe tangent.
- **Foil** (the CM's aluminised Kapton tape): aluminium with roughness 0.04–0.12 and a crinkle normal map.
- **Ablator:** a rough dielectric, charred according to heatLoad.
- **Fabric:** rough, with thin translucency, so back-lit gores glow.

**Lights.**
- **Sun:** illuminance × eclipse fraction × sunShadow × cloud shadow × atmospheric transmittance. The Sun's disc acts as an area light for specular: roughness widened by 0.2666° with Karis' normalisation.
- **IBL:** split-sum, multiplied by baked AO and specular occlusion.
- **Up to 8 plume line lights.**
- **Emissive.**

This replaces vesselLight's analytic earthshine and skylight (:471-517). Eclipse stays.

## 6. Specular anti-aliasing (R2)

- **Geometric:** Tokuyoshi–Kaplanyan NDF filtering (σ² 0.25, κ 0.18) on every specular lobe, the planet's ocean glint included.
- **Textures:** mipmapped, 8× anisotropic, with roughness mips widened by normal variance (Toksvig) through OrbitScene's MipBuilder, which the vehicle-look track must use.
- **Thin geometry:** Persson's phone-wire AA for the LES truss, the risers and the antennas. Radius is clamped to at least 0.7 px, with alpha-to-coverage. Risers become quads.
- **Bright highlights:** the Sun-disc highlight and the Karis-weighted resolve stop fireflies on foil.

## 7. IBL and earthshine (R3)

**Probe.**
- A radiance cube centred on the camera target: 128², or 64² at Low.
- Rendered each frame by planet_fragment itself. It already takes a view-to-world rotation and tan(fov/2), so six 90° faces need no new ray-tracing code.
- The atmosphere/cloud track adds its cheap probe path.
- The Sun is excluded (it is the analytic light) and the Moon is included.

**From the cube:**
- GGX-prefiltered specular mips (filtered importance sampling, 16–32 samples per texel);
- a 16² irradiance cube by brute-force cosine convolution of a 32² downsample, which is exact and has no SH ringing at the terminator;
- SH9 for particles and plumes.

Cost is about 0.3 ms.

**What it gives:**
- the real Earth lights the vehicle from below, with its colour, clouds and terminator;
- the Earth is reflected in foil and aluminium;
- the sky lights the Saturn V on the pad;
- in lunar orbit, the Moon and the Earth light it.

**Night floor.** An optional floor relative to the current exposure keeps the night side readable.

## 8. Shadows from 1 m to 110 m (R4)

Only vessels (and later the pad structures) cast shadows. The Earth's shadow stays the analytic eclipse.

**Level 0, per cluster.**
- One orthographic map along the Sun for each cluster of vessels within about 300 m of each other that is more than 64 px on screen.
- Footprint 2R: about 115 m for the Saturn V. At 4096² that is 2.8 cm texels; Low uses 2048².
- Receivers outside the footprint cannot be shadowed by those casters, so the long evening shadow on the pad is covered at any Sun elevation.
- Casters are drawn with depth clamp (pancaking).

**Level 1, detail.**
- A 2048² map over a sphere about the camera target, of radius 2·d·tan(fovY/2), clamped to [2 m, R] and quantised in steps of √2.
- With the camera 5 m from the CM, texels are about 5 mm.

**Debris.** Up to two more 1024² maps.

**Storage.** One depth16Unorm 2D texture array, about 50 MB at High.

**Stability.**
- The light frame is anchored on the vessel's structure origin, which is fixed in the construction frame (unlike the centre of mass), and snapped to texels.
- The matrices are built in Double: S = Ortho·R_sun·T(−anchor_camrel).

**Filtering.**
- PCSS with the Sun's real disc: penumbra ≈ 0.0093·Δd. The LES tower's shadow on the CM is about 3 cm soft; the stack's shadow on the ground about 0.9 m.
- 16 blocker plus 16 PCF Vogel samples, hardware compare. Low uses 3×3 PCF.
- Normal-offset plus slope bias.
- Two-sided casters with culling off.

**Receivers.** Meshes, canopies, the ground (planet_fragment samples level 0; coordinate this with the atmosphere track) and, optionally, smoke.

## 9. AO (R5)

- Baked whenever a vessel's mesh signature changes.
- Pure-Swift BVH: 32 cosine-weighted rays per vertex, 3 m maximum distance, spread with concurrentPerform.
- Stored in position.w, and faded in over 0.5 s once ready.
- Lathe facets are subdivided to at most 0.5 m, so the fins, fairings and interstage insides resolve.
- GTAO is a later option.

## 10. Slots for the effect tracks (R0 stubs, R6 integration)

- **Clouds and atmosphere:**
  - write cloudLayer, cloudDepth and cloudShadow;
  - own the P2 composite and the probe path;
  - use noiseOrigin;
  - honour temporalReset.
- **Plumes:**
  - draw in P3 at full or half resolution;
  - read emitters;
  - write up to 8 PlumeLights;
  - get preExposure, so the M1.5 visibility floor becomes a minimum display luminance.
- **Particles:**
  - simulate in P0 and draw in P3;
  - read transitions;
  - use a soft depth fade;
  - are lit through LightingCommon;
  - use dt = min(simDt, 0.1 s), with no spawning above 100× warp.
- **Vehicle look:** the material schema, vertex v2, the texture arrays and MipBuilder.
- **All tracks:** per-pass GPU timings, and golden shots for each new pass.

## 11. Precision rules

**Kept from today:**
- Doubles are camera-relative on the CPU, then converted to Float.
- Infinite reversed-Z: depth32Float cleared to 0, compare greaterEqual. Planets write near/(−z).

**Added:**
- Linear depth is near/d everywhere.
- Planet-fixed noise (clouds, ocean, terrain): noiseOrigin is the camera's body-fixed position modulo a 2^15 m tile, computed in Double.
- Never pass TDB seconds as Float: about 1e9 s would give 64 s steps. The uniforms carry realTime mod 3600 and sim time since the scene's epoch mod 86400.
- Shadow, probe and plume frames are anchored on vessel-fixed points.
- Near plane: 0.25 m for the external camera, 0.05 m for a future cockpit view.

## 12. Bloom, glare, lens (R1)

- **Bloom:** a 6-level rg11b10Float pyramid. Jimenez 13-tap downsample (with Karis average on the first level), tent upsample, mixed in at 2–4% with no threshold, so it conserves energy.
- **Sun visibility:** a 64-sample probe of sceneDepth over the disc, so the Earth's limb and the vehicle occlude the Sun at sunrise.
- **Starburst:** the FFT of a 5–6-blade aperture, computed at startup with vDSP. Ghosts are off by default.
- **Lens looks:** Clean (default), Hasselblad 70 mm, 16 mm DAC.

## 13. Snapshots and goldens (R0, grown in R8)

**Command.** `swift run -c release orbitsnap spec.json --out DIR [--shot N] [--update-goldens]`

**SnapshotSpec** (Codable, in OrbitScene), per shot:
- scenario, or a look-dev scene;
- an advance script: the flight harness's trigger language made real (liftoff, t3, met:s, ev:text, stage, warp, autopilot), stepped headless at full speed;
- camera, size, quality, exposure, debug view and outputs.

**Outputs:**
- PNG;
- PFM (linear HDR in physical units, with preExposure in the header);
- AOVs: albedo, normal, roughness/metalness, AO, sun visibility, shadow level, IBL-only, sun-only, EV false colour, NaN map, overdraw;
- JSON: camera, EV, per-pass GPU ms;
- index.html, a contact sheet of goldens, renders, diffs and reference photographs. The photographs come from ~/Library/Application Support/OrbitSim/LookRefs and are not committed.

**Determinism:** fixed size, manual EV, render scale 1, seeds by frame index, realTime from the spec, and K warm-up frames with the sim paused.

**In the app:**
- F12 dumps PNG, PFM and AOVs to ~/Library/Application Support/OrbitSim/Snapshots, or to ORBITSIM_SNAPSHOT_DIR for the harness.
- F9 cycles the debug views.
- F10 shows per-pass GPU ms.

**Golden set.**
- About 16 shots at 640×400, stored in Tests/OrbitRenderTests/Goldens/<gpu-family>/ (about 5 MB).
- Pass criteria: mean linear error under 0.5% and 99.5th-percentile ΔE76 under 3.
- Other GPU families skip the pixel comparison but run the metric tests.
- `ORBITSIM_UPDATE_GOLDENS=1` regenerates them, on the owner's Mac.

## 14. Performance architecture (R7)

- **Own render targets:** memoryless MSAA targets of our own; the MTKView drops to sampleCount 1 with no depth. This saves about 190 MB plus the bandwidth of storing MSAA.
- **Late drawable:** the drawable is acquired only for the last pass.
- **Cheaper encoding:** per-vessel uniforms through the FrameArena.
- **Dynamic resolution:** render scale 0.5–1.0 holding GPU time at or under 13 ms, then MetalFX spatial upscaling before grain and overlays.
- **Frame-paced step budget:** AppModel's budget becomes max(4 ms, 16.7 − EMA(other CPU) − 1.5 ms) in Smooth mode.
- **Quality tiers:** Low, Medium and High, chosen from the GPU at startup.

## Phasing

## Tracks

**R0: seams and offscreen renderer**
- One Mac session; it must merge before the other Mac tracks start (as G0 and S0 did in M1.5). 3.0–4.5 days.
- Contents:
  - Package.swift gains OrbitScene, OrbitSceneTests, OrbitRender, OrbitRenderTests and orbitsnap.
  - It moves Rendering/*, Camera.swift and Scenarios.swift.
  - It adds RenderScene and SceneExtractor, the SceneRenderer/ViewRenderer split, RenderPass and FrameGraph, ShaderCommon, and the shader modules split pixel for pixel.
  - It adds every slot stub, all binding indices and every LightingUniforms field, so no later track edits ShaderCommon.
  - It adds orbitsnap, SnapshotSpec, PNG/PFM writers, the GPU profiler, and about 8 baseline goldens of today's look.
- Exit criterion: the images are identical to main.

**R1: HDR, units, exposure, tone mapping, bloom, glare, dither, EDR**
- Track α, Mac; 3.5–5 days.
- Owns Passes/Post/*, PostShaders, StarShaders, and OrbitScene Look/{Photometry, Exposure, ToneCurves}.
- First priority after R0: the effect tracks can build structure before it, but cannot tune brightness until it lands.

**R2: vertex v2, materials, BRDF, DFG LUT, specular AA, Sun area light, local lights**
- Track β, Mac plus a Linux half; 4–6 days.
- Owns LightingCommon, MeshShaders, Passes/Opaque/VesselDraw plus Meshes, OrbitScene Look/{Materials, BRDF, MipBuilder}, and OrbitCore VisualShape.swift.
- Agree the material schema with the vehicle-look track in R0's first day.

**R3: environment probe IBL and earthshine**
- Track β after R2; 2.5–4 days.
- Owns EnvironmentProbePass, ProbeShaders and SphericalHarmonics.
- Needs R1's units and the atmosphere track's probe path (R0's legacy planet shader works until then).

**R4: shadows**
- Track γ, Mac plus Linux maths; 3–5 days; can start right after R0 thanks to the `sunShadow()` stub.
- Owns ShadowPass, ShadowShaders/ShadowCommon and ShadowFitting.
- The ground-receiver edit in PlanetShaders is a patch handed to the atmosphere track.

**R5: AO baker**
- Track δ, Linux; 1.5–3 days; can start at once (pure Swift).
- The 10-line vertex wiring lands after R2.

**R6: integrating the effect slots**
- Track ε, Mac; 1.5–2.5 days.
- Covers halfResTransparent with the depth-aware upsample, PlumeLights in shading, the soft-particle depth contract, the composite-slot hand-off to the atmosphere/cloud track, and the optional in-tile composite.
- Runs alongside the cloud, plume and particle tracks.

**R7: performance**
- Track α after R1; 2–3 days.
- Covers the frame-paced step budget in AppModel, dynamic resolution, MetalFX, quality tiers and the late drawable.

**R8: look-dev kit**
- Track ε; 2–3 days; grows with every phase.
- Covers look-dev scenes, AOV debug views, the contact sheet, photo-match shots, the golden set and docs/look.

## Order and critical path

R0 → (R1 ∥ R2 ∥ R4 ∥ R5) → (R3 ∥ R6 ∥ R7) → R8 close-out.

- The critical path is R0 → R2 → R3 plus look tuning: about 10–15 days.
- With 4 parallel sessions this is about 3–4 calendar weeks.

## Sibling tracks

**Vehicle look (geometry, paint, textures).**
- Its pure-Swift texture generation can start on Linux now.
- Its Mac work starts after R0 and needs R2's vertex v2, material table and MipBuilder.
- It shades correctly only once R2 and R3 are in.

**Clouds and atmosphere.**
- They take over PlanetShaders and the P2 composite after R0, and provide a probe path for R3.
- They must follow the noiseOrigin and time precision rules.

**Plumes.**
- P3 slot after R0; they tune brightness after R1 and feed PlumeLights to R6.

**Particles.**
- P0 and P3 slots after R0; they need SceneExtractor's transitions (R0) and R1's units.

**Every track** adds its own golden shots and runs orbitsnap.

## Close-out

- README: How it works, renderer section; new controls (F9, F10, F12); EDR.
- ROADMAP: the new milestone's graphics items.
- CLAUDE.md: the new targets; OrbitScene is Linux-testable; the orbitsnap command; the shader-check script.

## Data and sources

- Karis 2013, Real Shading in Unreal Engine 4 (GGX, split-sum IBL, sphere-light roughness normalisation): https://cdn2.unrealengine.com/Resources/files/2013SiggraphPresentationsNotes-26915738.pdf
- Lagarde & de Rousiers 2014, Moving Frostbite to PBR (photometric units, EV100, pre-exposure, specular occlusion): https://seblagarde.wordpress.com/wp-content/uploads/2015/07/course_notes_moving_frostbite_to_pbr_v32.pdf
- Filament documentation (equations only; the code is Apache-2.0): https://google.github.io/filament/Filament.html
- Fdez-Agüera 2019, A Multiple-Scattering Microfacet Model for Real-Time IBL, JCGT 8(1): https://jcgt.org/published/0008/01/03/
- Tokuyoshi & Kaplanyan 2021, Stable Geometric Specular Antialiasing with Projected-Space NDF Filtering, JCGT 10(2): https://jcgt.org/published/0010/02/02/ (and their I3D 2019 paper)
- Křivánek & Colbert 2008, GPU-Based Importance Sampling (filtered importance sampling), GPU Gems 3 ch. 20: https://developer.nvidia.com/gpugems/gpugems3/part-iii-rendering/chapter-20-gpu-based-importance-sampling
- Ramamoorthi & Hanrahan 2001, An Efficient Representation for Irradiance Environment Maps: https://graphics.stanford.edu/papers/envmap/
- Fernando 2005, Percentage-Closer Soft Shadows: https://developer.download.nvidia.com/shaderlibrary/docs/shadow_PCSS.pdf
- Jimenez 2014, Next Generation Post Processing in Call of Duty: Advanced Warfare (bloom pyramid, Karis average): https://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare/
- Persson (Humus), Phone-wire AA: http://www.humus.name/index.php?page=3D&ID=89
- three.js tone mapping, AgX and Neutral (MIT; AgX constants via Filament PR 7236, Apache-2.0): https://github.com/mrdoob/three.js/blob/dev/src/renderers/shaders/ShaderChunk/tonemapping_pars_fragment.glsl.js and https://github.com/google/filament/pull/7236
- Khronos PBR Neutral tone mapper (repository Apache-2.0; analytic, invertible): https://github.com/KhronosGroup/ToneMapping/tree/main/PBR_Neutral
- Wyman, Sloan & Shirley 2013, Simple Analytic Approximations to the CIE XYZ Colour Matching Functions, JCGT 2(2): https://jcgt.org/published/0002/02/01/ (avoids depending on licensed CIE tables)
- refractiveindex.info database (CC0) for metal n,k, e.g. Rakić 1998 aluminium: https://github.com/polyanskiy/refractiveindex.info-database
- Howell, A Catalog of Radiation Heat Transfer Configuration Factors (sphere-to-element and coaxial-disc factors for the earthshine and AO tests): http://www.thermalradiation.net/indexCat.html
- Darula, Kittler & Gueymard 2005, Reference luminous solar constant and solar luminance, Solar Energy 79(5):559-565 (luminous solar constant, about 128–134 klx; pin the value from the paper)
- IAU 2015 Resolution B3: nominal solar radius 695,700 km, effective temperature 5772 K (Sun's angular radius 0.2666° at 1 AU; Sun colour)
- 1948 candela definition: a full radiator at the freezing point of platinum (2041.4 K, ITS-90) has a luminance of 60 cd/cm² (external check for blackbody luminance)
- Allen's Astrophysical Quantities: V magnitude to illuminance, E = 10^(-0.4(V+14.18)) lx (constant to confirm: 13.99–14.18 appears in the literature)
- Hillaire 2020 sky-atmosphere reference (MIT) and Bruneton precomputed scattering (BSD-3), for the atmosphere track's composite: https://github.com/sebh/UnrealEngineSkyAtmosphere and https://github.com/ebruneton/precomputed_atmospheric_scattering
- NVIDIA FLIP image metric (BSD-3-Clause), optional external tool for golden diffs: https://github.com/NVlabs/flip
- Apple: Displaying HDR content in a Metal layer (EDR): https://developer.apple.com/documentation/metal/displaying-hdr-content-in-a-metal-layer ; MetalFX (macOS 13+): https://developer.apple.com/documentation/metalfx ; GPU counters and counter sample buffers: https://developer.apple.com/documentation/metal/gpu_counters_and_counter_sample_buffers
- Reference photographs (NASA, public domain; credit NASA; not committed): AS07-03-1545 (Apollo 7 S-IVB with the SLA panels open over Earth), AS08-16-2582/2583/2584 (Apollo 8 S-IVB with the LTA after TLI, including the 'fireflies'), AS08-14-2383 (Earthrise), KSC launch photographs of AS-503, and the AS-501/502 S-IC/S-II separation engineering films
- NASA TN D-6844, which the earlier study cited for optical properties: not verified in this pass. Neighbouring numbers (D-6848 to D-6855) are June 1972 Apollo Experience Reports. Confirm the report on NTRS before using it for paint and foil calibration.

## Licensing

Everything stays MIT by construction.

- **Techniques implemented in-house from papers.** Karis 2013, Lagarde 2014, Fdez-Agüera 2019, Tokuyoshi & Kaplanyan 2019/2021, Křivánek & Colbert 2008, Ramamoorthi & Hanrahan 2001, PCSS, Jimenez 2014, Persson's phone-wire AA and the Wyman CMF fits are methods and equations. They are credited in docs/look and in code comments.
- **AgX.** The one place where constants may be ported verbatim is three.js's AgX (MIT; its constants come from Filament, which is Apache-2.0). Keep the three.js MIT notice and the Filament credit in a new THIRD_PARTY_NOTICES.md.
- **PBR Neutral.** Khronos PBR Neutral (repository Apache-2.0) is reimplemented from its published formula and credited. Copying Apache-2.0 code verbatim would also be MIT-compatible, as long as the notice is kept.
- **Atmosphere references.** Hillaire (MIT) and Bruneton (BSD-3) are references for the atmosphere track. They are compatible if ported, with notices.
- **Data.**
  - Metal n,k from refractiveindex.info is CC0. Credit the original measurements, e.g. Rakić.
  - NASA reference photographs are public domain. Credit NASA, and keep them out of the repo by default.
  - Colour-checker patch values are published measurements; cite the source.
- **Tools.** NVIDIA FLIP (BSD-3) may be used as an external diff tool; do not vendor it.
- **Do not copy:**
  - Orbiter's D3D9Client shaders (LGPL); Orbiter's core is MIT, so keep its notice if anything from it is ported;
  - NASSP (GPL);
  - Blender's code or OCIO configs (GPL), beyond the published method;
  - Shadertoy code, which defaults to CC BY-NC-SA;
  - KSP assets (proprietary);
  - the MERL BRDF database (non-commercial).
- **Generated content.** The aperture starburst, blue noise, tone LUT and DFG LUT are all generated at startup from our own code.

## Performance

## GPU budget

Target: 60 fps, a 16.7 ms frame.

**Hardware:**
- The owner's Mac: M3 Pro, 18-core GPU, roughly 7 TFLOPS FP32 and 150 GB/s.
- Floor target: base M1, 8-core GPU, about 2.6 TFLOPS and 68 GB/s.

**Pixel counts:**
- default 1400×900 pt window: 2800×1800 = 5.0 Mpx;
- full screen on the XDR panel: 3024×1964 = 5.9 Mpx.

**Estimates at High, 1.0 scale, 5.9 Mpx, M3 Pro.** These are to be replaced by R0's per-pass profiler.

| Pass | ms |
|---|---|
| Probe, prefilter and irradiance | 0.3 |
| Shadows (2–4 maps, ≤ 200k triangles each) | 0.3–0.5 |
| Opaque MSAA (planet ray trace ~0.5; vessels PBR 0.5–1.0; stars and Sun 0.1) | 1.2–1.8 |
| Atmosphere and cloud composite | 0.4–0.6 |
| Clouds (cloud track's budget) | 3–4 |
| Plumes (half resolution when a plume fills the screen) | 1–2 |
| Particles | 0.5–1 |
| Post (histogram 0.1, bloom 0.6, glare 0.1, tone map and dither 0.3) | ≈ 1.1 |
| Overlay | 0.1 |
| **Total** | **≈ 8–11.5** |

- That leaves headroom under the 13 ms dynamic-resolution target.
- On a base M1, the Low tier at 0.6–0.7 scale with MetalFX lands at about 12–14 ms.

**Memory:**
- hdrColor 47 MB, sceneDepth 24 MB, bloom 16 MB;
- shadows about 50 MB at High, about 12 MB at Low;
- probe under 2 MB, LUTs under 1 MB;
- MSAA attachments are memoryless (0 MB). That frees about 190 MB that MTKView's stored 4× colour and depth use today.

**Bandwidth:**
- One full-screen rgba16F read plus write is about 95 MB, or 5.7 GB/s at 60 fps.
- The whole post chain stays under 25 GB/s.
- On the TBDR GPU, the MSAA samples never leave tile memory.

## CPU budget

The main thread has 16.7 ms per frame. It spends it on:
- simulation stepping;
- RenderScene extraction (0.5 ms or less);
- encoding (1.5 ms or less; FrameTimes.encode already measures it);
- the SwiftUI HUD refresh at 10 Hz, subtracted as an EMA;
- 1.5 ms of slack.

**Smooth mode (proposed default).**
- Stepping gets about 10 ms per frame, which is about 600 ms of stepping per second. Today it gets 22 fps × 40 ms = 880 ms per second.
- Powered-flight warp is about 30% lower: roughly 200–500× in Release instead of 290–730×.
- Coast warp is unaffected: 5.3 s steps, so 100,000× needs about 6 ms of stepping per frame.

**Throughput mode** keeps today's 40 ms budget and 22 fps.

**Later option:** run the simulation on its own thread, with the renderer reading published RenderScene values. R0's extraction is what makes this possible, and it gives 60 fps with full throughput.

## Time-warp interaction

- **Clocks:**
  - Wall-clock time drives procedural animation (plume turbulence and flicker, grain) and exposure adaptation.
  - Sim time drives physical evolution (glow lag, already at Renderer.swift:543-554; char; frost).
  - Particle dt is min(simDt, 0.1 s), and nothing spawns above 100× warp.
- **No stale lighting:** the probe and the shadow maps are redrawn every frame, so the Earth turning under the vessel at 1000× is never stale.
- **History:** temporalReset makes the cloud reprojection drop its history when the planet turns more than 0.5° per frame, or when the warp changes.
- **Exposure pumping:** at 1000× a 185 km orbit's day/night cycle lasts 5.3 s, so auto exposure will pump. An option holds the exposure above 100×.
- **Heat-shield glow:** already integrates in sim time, so warp does not make it flicker.

## Quality tiers

Dynamic resolution is off in snapshots.

| Setting | Low | Medium | High |
|---|---|---|---|
| Render scale | 0.6–0.8, dynamic | 0.8–1.0, dynamic | 1.0, dynamic |
| MSAA | 4× | 4× | 4× |
| Shadow maps | 2048 + 1024, 3×3 PCF | 4096 + 2048, PCSS 16 | 4096 + 2048 + 2×1024, PCSS 32 |
| Probe | 64² | 128² | 128² |
| Bloom levels | 5 | 6 | 6 |
| Half-resolution transparents | always | over 25% of the screen | never |

- The cloud tier is set by the cloud track.
- EDR is an option on any tier.

## Monitoring

- Per-pass GPU timestamps through MTLCounterSampleBuffer at stage boundaries.
- Shown in the app with F10, and written by orbitsnap.
- A perf-report shot set is compared with the previous run. It is a report, not a hard test.

## Verification

## Linux

Run `swift test --filter OrbitSceneTests` (seconds; part of the full run). The checks are against external references:

- **Photometry:**
  - Blackbody luminance at the platinum point (2041.4 K) is 6.0e5 cd/m², from the 1948 candela definition of 60 cd/cm², within 3%, using the Wyman–Sloan–Shirley CMFs.
  - Planckian chromaticity at 2856 K matches CIE illuminant A (0.4476, 0.4074) within 0.002.
  - The 5772 K Sun colour.
  - V magnitude to lux (Allen).
  - Sun illuminance scales as 1/r².
- **Exposure:**
  - EV100 to luminance, per Lagarde & de Rousiers 2014.
  - Sunny 16: white paint in sun gives EV ≈ 15.
  - Histogram percentile cases.
- **Tone curves:**
  - Swift AgX and Neutral match the three.js and Khronos reference outputs at transcribed sample points.
  - Each curve is monotonic per channel.
  - Neutral round-trips through its inverse.
- **BRDF:**
  - White furnace: GGX with multiscatter has albedo ≥ 0.98 at every roughness for F0 = 1.
  - DFG LUT corner values.
  - Aluminium F0 from Rakić's n,k ≈ 0.91–0.92.
- **Irradiance:** a plate facing nadir at 185 km over a uniformly lit Earth receives M·(R/r)² (Howell's sphere-to-element factor), within 3%; tilted cases too.
- **Shadow fitting:**
  - The footprint contains the cluster for random attitudes and Sun directions.
  - Moving the vessel by whole texels leaves the map unchanged.
  - Level-1 radius quantisation.
  - The penumbra formula.
- **AO baker:**
  - The centre of a cup's floor equals the view factor of its opening (Howell's coaxial-disc factor).
  - The inside of an open tube.
  - A free sphere gives AO = 1.
- **Scene and snapshots:**
  - SceneExtractor: AS-506 at first motion has 5 F-1 emitters at the exit planes; a staging transition appears; the eclipse fraction passes through.
  - SnapshotSpec decoding.
  - ImageMetrics on synthetic buffers.

## Mac

Tests/OrbitRenderTests runs in about 1–2 minutes and is also part of `swift test` on the Mac.

**Shaders:**
- every module compiles with no warnings (scripts/check-shaders.sh);
- pipelines validate under MTL_DEBUG_LAYER=1 and MTL_SHADER_VALIDATION=1.

**Look metrics** on the HDR PFM output, with tolerances that do not depend on the GPU:
- **Sun plate:** albedo-0.8 Lambert facing the Sun at 1 AU renders 0.8·E⊙/π ± 1%.
- **Furnace:** a sphere in a uniform environment renders that radiance ± 2%; rough metal ± 3%.
- **Earthshine:** the plate through the real probe path matches the analytic factor ± 5%.
- **Shadows:** the edge falls within 1 texel; the penumbra is within 20% of 0.0093·Δd.
- **Auto exposure:** converges to a uniform scene's EV ± 0.1 EV within 5 s.
- **Bloom:** conserves energy ± 1%.
- **NaN:** one injected NaN does not spread.
- **Stars:** the integrated energy ratio of a magnitude-1 and a magnitude-6 star is 100 ± 3%.
- **Resolve:** a 1e4 highlight on an edge resolves without ringing.

**Goldens:** about 16 shots at 640×400 against Goldens/<gpu-family>/, with diffs written on failure.

**Performance:** a report of per-pass ms at 1600×1000, High, recorded and compared with the last run (not asserted).

## Golden and screenshot shots

The specs live in docs/look/golden-shots.json. The owner reviews the contact sheet at each phase close, as with the M1.5 screenshot set.

1. AS-503 on LC-39A at 12:51 UTC, 21 Dec 1968: morning sun and the ground shadow, against KSC launch photographs.
2. Ascent at about 60 s against the sky: probe sky light and the plume.
3. S-IC/S-II separation: the open interstage, retros and ullage.
4. The S-IVB with the CSM at noon over the ocean: earthshine from below and foil reflections.
5. The same crossing the terminator: an 8–10 s penumbra, exposure adapting and stars appearing.
6. The S-IVB with the LTA after separation, against AS08-16-2584.
7. The S-IVB with the SLA panels open (Apollo 7), against AS07-03-1545.
8. The CSM in lunar orbit with the Earth rising, against AS08-14-2383.
9. CM entry at night (Apollo 8's pre-dawn entry): glow and sheath.
10. Main parachutes over the Pacific, then the CM floating.
11. Look-dev scenes:
    - a colour-checker plate in sunlight, against the published patch values;
    - the white furnace;
    - an array of metal and foil roughness spheres;
    - shadow test cubes;
    - the star field at EV 0;
    - the Sun plate.

The reference photographs are NASA, public domain. Fetch them locally with a tools script; do not commit them.

## Files touched

- /Users/grossetti/sw/ullage/Package.swift (new targets: OrbitScene, OrbitSceneTests, and, macOS-only, OrbitRender, OrbitRenderTests, orbitsnap)
- /Users/grossetti/sw/ullage/Sources/OrbitScene/Scenarios.swift (moved from Sources/OrbitSim/Scenarios.swift)
- /Users/grossetti/sw/ullage/Sources/OrbitScene/Camera/OrbitCamera.swift (moved from Sources/OrbitSim/Rendering/Camera.swift) and Camera/CameraState.swift
- /Users/grossetti/sw/ullage/Sources/OrbitScene/Scene/RenderScene.swift, SceneExtractor.swift, SceneTransitions.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitScene/Look/Photometry.swift, Exposure.swift, ToneCurves.swift, BRDF.swift, Materials.swift, MipBuilder.swift, SphericalHarmonics.swift, ShadowFitting.swift, AmbientOcclusion.swift, BVH.swift, RenderSettings.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitScene/Snapshot/SnapshotSpec.swift, ScenarioScript.swift, ImageMetrics.swift (new); Sources/OrbitScene/LookDev/LookDevScenes.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitSceneTests/ (new: PhotometryTests, ExposureTests, ToneCurveTests, BRDFTests, MaterialTests, SphericalHarmonicsTests, ShadowFittingTests, AmbientOcclusionTests, SceneExtractorTests, SnapshotSpecTests, ImageMetricsTests)
- /Users/grossetti/sw/ullage/Sources/OrbitRender/Core/SceneRenderer.swift and ViewRenderer.swift (from Sources/OrbitSim/Rendering/Renderer.swift, which is deleted)
- /Users/grossetti/sw/ullage/Sources/OrbitRender/Core/RenderPass.swift, FrameGraph.swift, RenderTargets.swift, ShaderLibrary.swift, FrameUniforms.swift (from RenderTypes.swift), GPUProfiler.swift, OffscreenTarget.swift, ImageWriters.swift, Snapshot.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitRender/Passes/EnvironmentProbePass.swift, ShadowPass.swift, OpaquePass.swift, VesselDraw.swift, StarsAndSun.swift, CompositeSlot.swift, TransparentSlot.swift, HalfResTransparent.swift, Post/ExposurePass.swift, Post/BloomPass.swift, Post/GlarePass.swift, Post/ToneMapPass.swift, Post/Upscale.swift, OverlayPass.swift, DebugViewPass.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitRender/Shaders/ShaderCommon.swift, LightingCommon.swift, ShadowCommon.swift, MeshShaders.swift, PlanetShaders.swift (handed to the atmosphere/cloud track after R0), StarShaders.swift, ProbeShaders.swift, ShadowShaders.swift, PostShaders.swift, OverlayShaders.swift, PlumeShaders.swift (today's impostor; handed to the plume track) (from Sources/OrbitSim/Rendering/Shaders.swift, which is deleted)
- /Users/grossetti/sw/ullage/Sources/OrbitRender/Meshes.swift, Plumes.swift, SpriteAtlas.swift (moved from Sources/OrbitSim/Rendering/)
- /Users/grossetti/sw/ullage/Sources/orbitsnap/main.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitRenderTests/LookMetricTests.swift, GoldenImageTests.swift, ShaderCompileTests.swift, Goldens/<gpu-family>/*.png (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/VisualShape.swift (material name; UV and tangent in the tessellated vertex)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Vessel/ApolloShapes.swift (material names on shapes; shared with the vehicle-look track)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/VisualShapeTests.swift (UV, tangent and material checks)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Views.swift (MetalView hosts ViewRenderer; sampleCount 1, no depth)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/AppModel.swift (frame-paced step budget around :86-88 and :118; render settings)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/OrbitSimApp.swift (View menu: exposure, tone curve, EDR, lens look, quality)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Input.swift and /Users/grossetti/sw/ullage/Sources/OrbitInstruments (F9, F10, F12 debug keys by physical position)
- /Users/grossetti/sw/ullage/scripts/check-shaders.sh (new)
- /Users/grossetti/sw/ullage/docs/look/README.md, golden-shots.json, units-and-exposure.md (new)
- /Users/grossetti/sw/ullage/THIRD_PARTY_NOTICES.md (new: three.js MIT notice, plus credits for Filament, Khronos and the papers)
- /Users/grossetti/sw/ullage/README.md, /Users/grossetti/sw/ullage/docs/ROADMAP.md, /Users/grossetti/sw/ullage/CLAUDE.md (close-out)

## Options (owner decisions)

1. **Tone mapper.**
   - Recommended default: AgX. It has a film-like roll-off, and plumes and the Sun go to white, as in 1960s Ektachrome.
   - Alternative: Khronos PBR Neutral, which keeps paint colours exact.
   - Or both, selectable in the View menu.
2. **Exposure model.**
   - Recommended default: an auto-exposing physical camera. Stars show only in darkness, as in the Apollo photographs.
   - Alternative: astronaut eye, with a floor so stars stay faintly visible.
   - Alternative: manual EV.
3. **Night-side visibility.**
   - Recommended default: a small floor relative to the exposure, so the vessel stays readable in eclipse.
   - Alternative: strictly physical (earthshine of the night side and moonlight only).
4. **EDR on the XDR display.**
   - Recommended default: off, with a View-menu toggle. Goldens are always SDR.
   - Alternative: on automatically when the display has headroom.
5. **Lens look.**
   - Recommended default: Clean (bloom and the Sun's starburst, no ghosts or grain).
   - Alternatives: Hasselblad 70 mm (fine grain, slight vignette); 16 mm DAC (grain, halation, flares).
6. **Frame pacing during warp.**
   - Recommended default: Smooth, 60 fps, with a step budget of about 10 ms. Powered-flight warp is about 30% lower; coast warp is unaffected.
   - Alternative: Throughput, today's 40 ms budget at about 22 fps.
   - Later: a simulation thread for both (about 3–5 days, after the overhaul).
7. **Shadow softness.**
   - Recommended default: PCSS with the Sun's real 0.53° disc on Medium and High.
   - Alternative: fixed PCF only.
8. **Ambient occlusion.**
   - Recommended default: baked per vertex, in pure Swift, at each mesh change.
   - Alternative: add GTAO screen-space contact AO later.
9. **Code layout.**
   - Recommended default: the new OrbitScene (Linux) and OrbitRender (macOS) targets plus orbitsnap.
   - Alternative: keep everything in OrbitSim. That means no Linux tests of the look maths and no offscreen tool.
10. **Goldens in git.**
    - Recommended default: small PNGs per GPU family, about 5 MB, in Tests/OrbitRenderTests/Goldens.
    - Alternatives: Git LFS; not committed (generated per machine).
11. **Deployment target.**
    - Recommended default: stay on macOS 14, gating newer Metal features.
    - Alternative: raise it to macOS 26 for Metal 4. Nothing in this design needs it.
12. **Where clouds are composited.**
    - Recommended default: after the MSAA resolve. This is simpler, at the cost of possible 1-px fringes where vessels stand against clouds.
    - Alternative: an in-tile per-sample composite before the resolve, if goldens show the fringes.
13. **Holding exposure during high warp.**
    - Recommended default: off. At 1000× the exposure follows a 5.3 s day/night cycle.
    - Alternative: hold the exposure above 100× warp.
14. **Sun illuminance.**
    - Recommended default: pin Darula et al.'s reference value, grade it M, and record it in docs/look/units-and-exposure.md.
    - Alternative: the round 128 klx used by many engines.

## Effort

**Total: about 23–36 focused session-days**, mostly on the Mac. About 5–7 of those days are Linux-capable pure-Swift work.

| Phase | Days |
|---|---|
| R0 seams, offscreen renderer, orbitsnap and baseline goldens | 3.0–4.5 |
| R1 HDR, units, exposure, tone mapping, bloom, glare, dither, EDR | 3.5–5 |
| R2 vertex v2, materials, BRDF and DFG LUT, specular AA, Sun area light, local lights | 4–6 |
| R3 environment probe IBL and earthshine | 2.5–4 |
| R4 two-level object-fitted shadows with PCSS and ground receiving | 3–5 |
| R5 pure-Swift AO baker | 1.5–3 |
| R6 effect-slot integration (half-resolution transparents, plume lights, composite hand-off) | 1.5–2.5 |
| R7 frame pacing, dynamic resolution and MetalFX, quality tiers | 2–3 |
| R8 look-dev kit, AOVs, contact sheet, photo-match goldens, docs | 2–3 |

**Critical path** (R0 → R2 → R3 plus tuning): about 10–15 days. With 4 parallel sessions, about 3–4 calendar weeks.

**What drives the range:**
- Every shader change needs a Mac build and a snapshot. Nothing in OrbitRender compiles on Linux.
- Look tuning against the reference photographs is open-ended; time-box it to about 1 day per phase.
- Golden-image tolerances that hold across GPU families and driver versions.
- How much the atmosphere/cloud track rewrites planet_fragment while R1 and R3 depend on it.
- The vehicle-look track's final mesh density, which sets the AO baker's speed and the shadow pass cost.
- EDR verification on the XDR display.
- Whether the in-tile composite option is needed.

## Risks

- **Mac-only testing.** Nothing in OrbitRender builds on Linux. Linux sessions can only do OrbitScene, and every pass needs a Mac session with orbitsnap. Mitigation: move as much as possible into OrbitScene, and use look-metric tests that pin numbers rather than pixels.
- **R0 touches everything.** It moves and splits Renderer.swift and Shaders.swift, which every graphics track wants. It must merge, image-identical, before the parallel Mac work starts. It also reserves every binding and uniform field, so that ShaderCommon is never contested afterwards.
- **Physical units change all brightnesses at once.** Plumes (the 0.3 floor), glow, stars, sky and planets are all tuned in arbitrary units today. R1 must convert every pass together, behind the legacy planet scale, and check against the baseline goldens. Otherwise the scene goes black or white during the transition.
- **FP16 overflow and NaN.**
  - The Sun's disc at 1.9e9 cd/m² overflows FP16 at low EV.
  - NaNs spread through bloom, and Metal fast math can fold `isnan`.
  - Mitigation: pre-exposure, a clamp to 6e4, a bit-pattern NaN guard, and a NaN map AOV.
- **Highlight fireflies.** Without Karis weighting, the MSAA resolve of HDR highlights makes fireflies on foil. The cost of the weighting is that premultiplied blending in the opaque pass happens in compressed space. That is acceptable once the sky moves to the composite.
- **Composite fringes.** The post-resolve composite can leave 1-px fringes where vessels stand against clouds. The fallback is the in-tile per-sample composite: more complex, and about 1 ms more at 6 Mpx.
- **Flaky goldens.** Golden images can break across GPUs, macOS versions and Metal compilers. Mitigation:
  - tolerances on mean error and percentile ΔE;
  - goldens per GPU family;
  - metric tests as the main guard;
  - updates on the owner's Mac only, reviewed in the contact sheet.
- **Lower powered-flight warp.** 60 fps during warp costs about 30% of the achieved powered-flight warp in Smooth mode. The full fix is a simulation thread, which needs snapshots for the HUD and MFDs too.
- **Probe staleness.** The probe is centred on the camera target, so distant vessels' reflections are slightly wrong, and vessels do not reflect each other. Beyond about 50 km, vessels fall back to SH9 only.
- **Shadow artefacts.**
  - Acne and peter-panning on thin two-sided shapes (bells, SLA panels).
  - Shimmer if the anchor is the moving centre of mass instead of the structure origin.
  - Cascade seams at level-1 bounds; mitigated by a 10% blend band.
- **Exposure realism versus readability.** No stars beside a sunlit vehicle, and a black night side. These are owner options, not defects; decide them early so goldens are stable.
- **AO baker.** A pure-Swift BVH may be slow on dense procedural meshes (hundreds of thousands of vertices). Mitigations: async baking with a fade-in, a lower ray count, or a Metal ray-tracing bake later.
- **Performance at retina resolution.** The volumetric passes at 5–6 Mpx on base M1 and M2 depend on dynamic resolution and MetalFX working well. The per-pass budgets in the performance section must be held by the cloud, plume and particle tracks.
- **Licensing slips.** Copying shader code from LGPL (Orbiter D3D9Client), GPL (NASSP, Blender) or Shadertoy (default CC BY-NC-SA) sources would break MIT. See the licensing section for the rule.
- **Unverified numbers.**
  - NASA TN D-6844, cited by the earlier study, is not verified (see sources).
  - The luminous solar constant (128–134 klx) and the magnitude-to-lux constant (13.99–14.18) must be pinned and graded.
