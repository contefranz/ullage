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
- The Sun is `FrameUniforms.sunIlluminance` (lux), or A2's
  `AtmosphereUniforms.sunTransmitted.rgb` when there is air (`radii.w` 1 and
  `sunTransmitted.w` > 0). Its disc is an area light for the specular lobe.
- A fragment's radiance times the pre-exposure (`FrameUniforms.exposure.x`,
  R1's), clamped to 6e4 and NaN-guarded (`orbit_exposed`), is the output. The
  vessel pipeline Karis-encodes it (`orbit_encodeHDR`) when the scene target
  is a float format (function constant 0, set from `PassSetup.formats.color`).
- **Until R1:** with `exposure` still (1, 0, 1, 0) the pass uses a stand-in
  pre-exposure of EV 15 (`StandInLighting.preExposure`), so sunlit white
  paint reads about 0.84 in today's LDR target.

## The BRDF

- Lambert diffuse; GGX, height-correlated Smith visibility, Schlick Fresnel.
  Perceptual roughness r, α = r², r ≥ 0.045.
- Multiple scattering from the 64² DFG table (texture 22, rg = A, B, read at
  (n·v, √α)): Fdez-Agüera's weights for the environment, Kulla and Conty's
  1 + F0 (1/Ess − 1) for lights. The table is baked in Swift
  (`BRDF.dfgTable`); the pass binds it and leaves it in the frame's slot for
  later encoders.
- Specular anti-aliasing: Tokuyoshi and Kaplanyan's conservative isotropic
  NDF filtering (JCGT 2021, listing 5: σ² = 1/(2π), κ = 0.18) on the shading
  normal. Map mips: `MipBuilder` (Toksvig: α'² = mean α² + 2 (1 − |n̄|)/|n̄|).
- Thin tubes (frusta ≤ 10 cm in radius and ≥ 8 radii long: the LES truss,
  struts; and the risers) use Persson's phone-wire AA: never thinner than
  `ShadingSettings.wireMinimumRadius` (0.7 px), their coverage blended after
  the opaque geometry, depth-tested without writing depth. Alpha to coverage
  was tried and drops a sub-pixel tube's last samples, breaking it up.
- Tests (Linux): `BRDFTests` (GGX normalisation, Heitz's projected-area
  identity, Schlick's mirror limit, the table against direct quadrature, the
  white furnace ≥ 0.98, Rakić's aluminium F0 0.914, the filter, the Sun disc,
  Howell's sphere factor, the shading path's furnace and Sun plate),
  `MipBuilderTests`. GPU: `VesselPassTests` (the radiance equals the Swift
  reference within 1 %).

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
| `coverage` | 1 opaque |

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
  fades from the previous bake. A bake is applied only once its fade has
  begun, so a snapshot's frame (whose clock stands still) never changes;
  `ShadingSettings.waitForAmbientOcclusion` bakes before the frame.

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
  the reference body as a disc of its lit mean radiance (diffuse through the
  sphere's view factor with its horizon, specular where the reflection meets
  it, blurred with roughness), plus a uniform sky (A2's
  `skyIrradiance.rgb` in air, else M1.5's sky term) and M1.5's night floor
  (0.02 E⊙). Baked AO and Lagarde's specular occlusion weight it.
- **Glow:** the heat shield's (`LegacyLighting.glowColor` × E⊙/π), strongest
  facing the flow, until R1's blackbody glow.

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
