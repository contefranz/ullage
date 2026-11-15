# Shading: the vessel pass and its contracts (track R2)

How vessels, their canopies and risers, and the pad are lit in M1.6, and
what the tracks that come after R2 plug into. The code is the reference:
`Sources/OrbitRender/Shaders/LightingCommon.swift` (the lighting),
`VesselShaders.swift` (the vessel module), `Passes/VesselPass.swift` and
`Meshes.swift` (the pass and its mesh cache), and in OrbitScene `Look/BRDF`,
`MipBuilder`, `MaterialDefaults`, `StandInLighting`, `PlumeLights`,
`ShadingReference` and `LookDevScenes`.

## Units and output

- Light is photometric: illuminance in lux, luminance in cd/m², linear Rec. 709.
- The Sun is `FrameUniforms.sunIlluminance.rgb` (lux per channel, coloured
  as R1's 5772 K blackbody), or, when there is air (`radii.w` 1 and
  `sunTransmitted.w` > 0), A2's `sunTransmitted.rgb * sunTransmitted.w`: rgb
  is unitless (A1's transmittance times R1's colour at unit luminance), w is
  the lux above the air, and the lux per channel is their product
  (docs/look/atmosphere.md). Its disc is an area light for the specular
  lobe; R1's StarPass draws the disc itself.
- **Aerial perspective:** the light leaving the surface (lit and emitted)
  passes through A2's froxels (slot 30) to the camera, L × a + in-scattered,
  in the shader's one exit, on every path (opaque and wires); none without
  air (`aerialPerspective.x` 0).
- The vessel shader writes linear radiance times the frame's pre-exposure
  (`FrameUniforms.exposure.x`, R1's, valid from P0 on) and blends linearly.
  `orbit_exposed` follows R1's scene rule per channel: after the
  pre-exposure, a NaN or −∞ gives 0 in its channel, +∞ saturates at 6e4, and
  the rest is clamped to [0, 6e4]; the bit test comes first (`min` would
  turn a NaN into 6e4). `VesselPassTests.testEveryVesselPathClampsItsLight`
  checks the opaque, glow and wire paths at EV −4.
- **Exactly one side encodes:** R1's `HDRResolvePass` weights every sample at
  the end of P3 (docs/look/units-and-exposure.md); no scene shader calls
  `orbit_encodeHDR`. `VesselPassTests.testRadianceMatchesTheSwiftReference`
  checks the light R1 captures against the Swift reference at EV 15 and at
  EV 11 (13 times the exposure's white), so it fails if a shader encodes
  too or forgets the pre-exposure.

## The BRDF

- Lambert diffuse; GGX, height-correlated Smith visibility, Schlick Fresnel.
  Perceptual roughness r, α = r², r ≥ 0.045.
- Multiple scattering from the 64² DFG table (texture 22, rg = A, B, read at
  (n·v, √α); texel i at i / 63, so 0 and 1 are texel centres: `orbit_dfg`): Fdez-Agüera's weights for the environment, Kulla and Conty's
  1 + F0 (1/Ess − 1) for lights. The table is baked in Swift
  (`BRDF.dfgTable`); the pass binds it and leaves it in the frame's slot for
  later encoders.
- Specular anti-aliasing: Tokuyoshi and Kaplanyan's conservative isotropic
  NDF filtering (JCGT 2021, listing 5: σ² = 1/(2π), κ = 0.18) on the shading
  normal. Map mips: `MipBuilder` (Toksvig: α'² = mean α² + 2 (1 − |n̄|)/|n̄|).
- Thin tubes (frusta ≤ 10 cm in radius and ≥ 8 radii long: the LES truss,
  struts; and the risers) use Persson's phone-wire AA: never thinner than
  `ShadingSettings.wireMinimumRadius` (0.7 px), their coverage c blended as
  c × L + (1 − c) × what is behind, depth-tested without writing depth.
  What is behind must be final, sky included, and A2 draws the sky in P2
  where the scene has no depth: so the vessel pass holds its wires and
  `VesselWirePass` (P2, order 10, after A2's composite; `VesselPass.wirePass`,
  in `SceneRenderer.defaultPasses`) draws them. A graph without it gets them
  at the end of P1. Alpha to coverage was tried and drops a sub-pixel
  tube's last samples, breaking it up. After their colour the wire pass
  draws their depth where their coverage is at least 0.5
  (`vessel_wireDepth`), so what lies behind them there is hidden as by
  opaque geometry: C2's clouds and the plumes through R6's slots (R6's
  half-resolution depth and its composite see the wire, after R1's break),
  P3's full-resolution passes and P5's overlays. A thinner wire stays
  depthless, and a P3 or P5 draw behind it covers it (it is under half a
  pixel wide). `VesselPassTests.testCloudsBehindAWireStayBehindIt` checks
  the pad with C2's cirrus on.
- Tests (Linux): `BRDFTests` (GGX normalisation, Heitz's projected-area
  identity, Schlick's mirror limit, the table against direct quadrature, the
  white furnace ≥ 0.98, Rakić's aluminium F0 0.914, the filter, the Sun disc,
  Howell's sphere factor, the shading path's furnace and Sun plate),
  `MipBuilderTests`. GPU: `VesselPassTests` (the radiance equals the Swift
  reference within 1 %; at A2's dawn pad a wire against the sky at
  coverage 1 is the same tube drawn opaque, and at coverage 0.3 takes its
  share of the sky; a plate a few kilometres off is the near one through
  A2's march).

## SurfaceSample: what a material or paint evaluation returns (VM1, VM2)

Defined in LightingCommon; `SurfaceSample` in OrbitScene mirrors it.

| Field | Meaning |
|---|---|
| `albedo` | linear Rec. 709, 0-1: a dielectric's diffuse albedo, or a metal's F0 colour |
| `metalness` | 0 dielectric, 1 conductor: F0 = mix(reflectance, albedo, metalness), diffuse = (1 − metalness) albedo |
| `roughness` | perceptual r, before specular AA (the lighting applies it) |
| `reflectance` | a dielectric's F0: 0.04 for paint, glass, plastics |
| `normal` | the shading normal, world, unit, on the side seen: the geometric normal plus relief |
| `occlusion` | cavity occlusion of the indirect light, 1 none; the baked AO multiplies it; neither touches the Sun |
| `emission` | cd/m², added after the lighting |
| `anisotropy`, `tangent` | reserved; every lobe is isotropic until a track needs it |
| `coverage` | honoured on thin-wire draws only (blended in P2, over the final sky); other draws are opaque. Holes: `discard_fragment()` in the hook, at the cost of hidden-surface removal (LightingCommon has the contract) |

A material evaluation never lights: it fills these and returns.

**Hooks.** The vessel module is ShaderCommon, ShadowCommon, LightingCommon,
`VesselSurface` (R2's header: `VesselSurface`, `VesselResources`,
`VesselMaterial`, `VesselPaint`), VM1's `VesselPaint` header, VM2's
`VesselMaterial` header, then R2's source. In your header, define the macro
and the function to replace R2's default:

```metal
// VM2 (VesselMaterialShaders):
#define ORBIT_VESSEL_MATERIAL 1
SurfaceSample vessel_material(thread const VesselSurface &s, thread const VesselResources &r);
// VM1 (VesselPaintShaders): paint, decals, frost, char over the material.
#define ORBIT_VESSEL_PAINT 1
void vessel_paint(thread SurfaceSample &sample, thread const VesselSurface &s, thread const VesselResources &r);
```

`VesselSurface` gives the camera-relative position, the geometric normal (on
the side seen), tangent and bitangent, the view vector, vertex v2's surface
coordinates (station u m, azimuth v rad, radius r m, arc s m), its ids
(material, paint, decal) and the face. `VesselResources` holds the material
table and the paint palette; textures and tables of your own need a slot in
it and a binding in `VesselPass`: ask R2.

**Today's defaults.** The material id indexes `VesselMaterialTable`: one
entry per finish (material key, the shape's colour, emissive role), its
model and roughness from `MaterialDefaults` (L estimates until VM2's
`SurfaceMaterial`). The paint id is VM1's Swift evaluator's region colour at
the vertex (`PaintStandIn`: 1 + the `PaintColour` index; decals wait for the
atlas), front faces only. Per-vertex, flat: its edges follow the mesh until
VM1 evaluates per fragment.

## Vertex v2, the mesh cache and AO (R5)

- One indexed mesh per part, in the part's frame (`PartMesh`), built the
  first time the part is seen; a vessel's draw list places its parts. A
  separation builds no geometry (`VesselPassTests.testSeparationReusesThePartMeshes`).
- R5's bakes (`AmbientOcclusionBaker`) run in the background. The first bake
  covering a part swaps in its subdivided mesh (built off the main thread);
  each bake gives each part a stream of packed AO codes, one per vertex
  (vertex buffer 3, the previous bake's at 4). The vertex function decodes
  its own vertex's code (`AmbientOcclusion.unpack`), the rasteriser
  interpolates (front, back), the fragment function picks the face seen and
  fades from the previous bake.
- A part is refined to a bake's own subdivision (`maxEdge`): a bake under
  another edge refines it again and drops the old streams.
- While the renderer's clock stands still (snapshots, tests, R1's exposure
  warm-up) the pass asks the baker for nothing, so no bake runs that could
  never show and the meshes never change between renders;
  `ShadingSettings.waitForAmbientOcclusion` bakes before the frame instead.
  Queued bakes are dropped with the pass.

## Lights and the environment

- **Sun:** illuminance × eclipse share × `orbit_sunShadow` (R4).
- **Plume lights (P2):** up to 8 line lights (`LocalLight`: the segment's
  centre and radius, unit axis and length, broadside intensity in cd and
  range). The pass uses `LightingUniforms.lights` when P2 writes them
  (`lightCount.x` > 0), else `PlumeLights` from the emitters and P1's specs:
  a grey-body column at the exit or afterburning temperature, emissivity by
  propellant, engine clusters merged into one light.
- **Environment (R3):** with a probe (`LightingUniforms.probe.w` = its
  specular mip count) the prefiltered cube (texture 20, radiance in cd/m²,
  mip = √α × (mips − 1)) and the irradiance cube (texture 21, E/π in cd/m²,
  the night floor included). Until then, the stand-in (`StandInLighting`):
  the reference body as a disc of uniform radiance (diffuse through the
  sphere's view factor with its horizon, specular where the reflection meets
  it, blurred with roughness). That radiance is the ground's reflectance
  (M1.5's albedo and colour, / π) times the light on the ground: the Sun at
  `StandInLighting.litCosine` (the solid-angle mean of the Sun's cosine over
  the disc seen: the Sun's elevation's sine on the pad, the Lambert disc's
  2/3 at full phase from afar) and, in air, A2's sky; while the camera is in
  the air the Sun is A2's transmitted one (handing over to the Sun above
  the air over the air's upper fifth). At the dawn pad (the Sun 7° up)
  this ground is (920, 690, 690) cd/m², near the 1e3 A2's planet pass
  draws; M1.5's lit share gave it 1.1e4, as bright as at noon, which lit
  the stack's shaded side with a white-blue bounce. Then a uniform sky (A2's
  `skyIrradiance.rgb` in air, else M1.5's sky term) and M1.5's night floor,
  relative to the exposure: lux of 0.02 π / P, so a white surface shows 0.02
  of the exposure's white whatever the exposure (R1's rule: scaled with the
  Sun, the auto exposure would lift the night side to day). Baked AO and
  Lagarde's specular occlusion weight it.
- **Glow:** the heat shield's luminance (`RenderScene.Vessel.glow`, R1's
  grey body at radiative equilibrium), strongest facing the flow.

## Sites (LC)

`RenderScene.sites` named "LC-39A" within 100 km are drawn by the same pass:
`LC39A.elements` meshed once, placed by the countdown of the launch nearest
the clock (Apollo 8's or Apollo 11's). Nothing yet places the site: the app
and `orbitsnap` need `SceneExtractor.sites = [LC39A.placement()]` (F0 or GI).

## Look-dev

- Hard goldens (`ShadingLookDevTests`): the material spheres and the Saturn
  V's side (`LookDevScenes`), `Tests/OrbitRenderTests/Goldens/<gpu>/r2-*.png`.
- Scene shots: `docs/look/shots/r2.json` (no goldens).
- `ORBITSIM_PERF=1` runs `VesselPassTests.testPassTimeReport` (GPU lock,
  3024 × 1964): the pass's time on the pad and in LEO.
