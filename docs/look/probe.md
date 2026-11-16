# The environment probe and image-based lighting (R3)

What lights a surface besides the Sun and the plumes: the sky, the ground,
the Earth below in orbit, its clouds and its night side. One probe a frame,
at the camera target, gives the vessels their reflections and diffuse
light, and the plumes and particles their ambient light.

Code: `OrbitRender/Passes/EnvironmentProbePass`, `Shaders/ProbeShaders`
(and its `.sphericalHarmonics` header), `OrbitScene/Look/{EnvironmentProbe,
SphericalHarmonics}`, `OrbitScene/Settings/ProbeSettings`. The vessels read
it in LightingCommon's `orbit_environmentLight`.

## The radiance cube

- **Where:** at the camera target when it is a vessel within 50 km of the
  camera, else at the camera (`EnvironmentProbePass.center`), in
  `LightingUniforms.probe.xyz` (camera-relative). The planets are drawn from
  there exactly; A2's sky and C2's clouds from the camera, within a few
  hundred metres of it in practice. The vessels are not in it, so they do
  not reflect each other; the pad is (below).
- **What:** six 90° faces of `ProbeSettings.faceSize`² (128; 64 at Low),
  each its own render pass, drawn through the other tracks' probe entry
  points, in this order:
  1. `PlanetPass.encodeProbe`: every body more than a texel across, as the
     planet pass draws it (E1's albedo tiles, A2's light through the air),
     without the night floor or the grid; from above the air the ground's
     haze is marched in the shader (8 steps), A2's reduced-resolution haze
     being the camera's view. Depth written.
  2. `AtmosphereCompositePass.encodeProbe`: A2's sky behind the planets
     (radiance + transmittance × what the face holds).
  3. `CloudPass.encodeProbe`: C2's far layers, low and mid, for the whole
     sphere, premultiplied over the face, with the air between the probe
     and the cloud marched (6 steps), so the face becomes (1 − a) face +
     T cloud + a in-scatter: the haze in front of the cloud stays whole.
     No cirrus and no march: the probe wants the clouds' light, not their
     detail.
  4. `VesselPass.encodeProbe`: LC-39A when it is within 2 km of the centre
     (`ProbeSettings.sites`), opaque over the sky and the clouds and in
     front of the ground, lit by the Sun with R4's shadows and R2's stand-in
     environment (a second bounce): the concrete and steel under the stack,
     a large part of its lower sky. Not the vessels, which would see
     themselves.
  Each entry point only adds a function and a pipeline of its own: what
  its pass draws for the frame does not change.
- **Units:** rgba16Float, luminance in cd/m², linear Rec. 709, not
  pre-exposed (the faces' frame uniforms carry a pre-exposure of 1), NaN
  cleaned, clamped below 6e4 (the aureole within a few degrees of a low Sun
  can pass it; the Sun itself is not in the probe).
- **The Sun** is excluded: it stays the analytic light (the Sun's disc as
  an area light, R4's `orbit_sunShadow`). The Moon is drawn when it is over
  a texel across (in lunar orbit), not from the Earth.
- **The cube's convention** is Metal's (OpenGL's) cube map
  (`EnvironmentProbe.direction`); a face is rendered with the view basis
  `EnvironmentProbe.basis` (a reflection: cube maps are left-handed, and the
  ray casters do not mind). A GPU test checks the GPU's texels, the Swift
  convention and Metal's sampler agree.
- **Look-dev environments** (`ProbeSettings.environment`) replace the scene
  with an analytic one, for the goldens: `furnace` (uniform
  `furnaceRadiance`), `earthBelow` (R2's look-dev Earth, a Lambertian
  sphere of albedo 0.3 below at 185 km under the scene's Sun) and
  `earthUniform` (the same lit evenly: Howell's uniform disc).

## Derived maps

- **Specular (texture slot 20):** the radiance's own mips (a box filter)
  are the source; mip 0 is the radiance, mip k ≥ 1 is GGX-prefiltered at
  perceptual roughness k/(mips − 1) with Karis' split-sum assumption n = v =
  r: GGX samples per texel, each reading the source mip its solid angle
  covers (Křivánek and Colbert's filtered importance sampling, lod bias ½,
  32 samples at mip 1 doubling to 256, never the 2² and 1² source faces). Six mips
  from 128² go down to 4² (22° a texel at roughness 1). The vessels read it
  trilinearly at level √α × (mips − 1), √α being the perceptual roughness
  after specular anti-aliasing. `EnvironmentProbe.prefilterReference` (brute
  force over every texel) is its limit; a GPU test holds each mip to it.
- **Irradiance (slot 21):** 16², E/π in cd/m² (a white Lambertian surface's
  luminance), by brute-force cosine convolution of the 32² downsample: exact,
  with none of SH's ringing at the terminator.
  `EnvironmentProbe.irradianceReference` is its reference.
- **SH9:** the same downsample projected on nine real spherical harmonics,
  for the plumes and particles. See below.

## SH9: the interface

- **Where:** `LightingUniforms.sh9[0..8]` (buffer 29), every stage after
  P0. The probe computes it on the GPU and a blit copies it into this
  frame's uploaded lighting uniforms before P1 (`FrameContext.
  copyIntoLighting`): it is this frame's, not last frame's. Valid while
  `lighting.probe.w > 0.5`; zero otherwise.
- **What:** the coefficients of E(n)/π, the irradiance over π: the
  luminance of a white Lambertian surface facing n, the irradiance cube's
  quantity. rgb the coefficients, w = 0. cd/m², linear Rec. 709, **not
  pre-exposed**: multiply by `FrameUniforms.exposure.x` when writing, as R1
  requires. The Sun and the night floor are not in it.
- **Basis:** real SH over world (ICRF, camera-relative) directions pointing
  toward the light, in the order (0,0), (1,−1), (1,0), (1,1), (2,−2),
  (2,−1), (2,0), (2,1), (2,2): 0.282095, 0.488603 (y, z, x), 1.092548 xy,
  1.092548 yz, 0.315392 (3z² − 1), 1.092548 xz, 0.546274 (x² − y²). The
  radiance's own coefficients are these times 1, 3/2 and 4 for bands 0, 1
  and 2 (Ramamoorthi and Hanrahan's Â_l/π = 1, 2/3, 1/4).
- **Helpers** (add `.sphericalHarmonics` to a module's headers):
  - `orbit_sh9Irradiance(lighting, n)`: E(n)/π, cd/m², clamped at 0;
  - `orbit_sh9InScatter(lighting, v, g)`: the radiance a medium scatters
    toward the eye per unit albedo, Henyey and Greenstein's phase of
    asymmetry g, v the view ray (camera to the point): Σ g^l L_lm Y_lm(v);
  - `orbit_sh9MeanRadiance(lighting)`: (1/4π) ∫ L dω, an isotropic
    scatterer's light;
  - `orbit_probeNightFloor(x, lighting)`: the night floor merged into x.
- **Swift mirror:** `OrbitScene/Look/SphericalHarmonics` (`SH9`), tested on
  Linux against a constant sky, the linear and quadratic skies it holds
  exactly, the uniform sky over a black ground (exact too), the clamped
  cosine lobe against brute force, the Earth from 185 km against Howell's
  factor, and Henyey-Greenstein in-scattering against quadrature.
- **Users:** P3's smoke and chunks (`particle_ambient`: E/π on the side
  facing the camera, or the chunk's face); P2's plumes.

## The night floor and the scale

- `LightingUniforms.ambient.rgb`: the night floor as E/π (cd/m²), at
  `ProbeSettings.nightFloor` (0.02, StandInLighting's) of the exposure's
  white: 0.02 / P for pre-exposure P, so a white surface lit by it alone
  shows 0.02 of white whatever the exposure, and the auto exposure does not
  lift the night side to day (R1's rule).
- It is merged as a soft maximum, x + f²/(x + f) (`EnvironmentProbe.
  floored`): f where the environment is black, x where it is far above
  (daylight keeps its contrast). The vessels apply it to both cubes'
  values; SH9 users call `orbit_probeNightFloor`.
- `ambient.w`: `ProbeSettings.intensity`, a scale on the probe's light (1).

## Ambient occlusion

R5's baked AO (times the material's own occlusion) multiplies the diffuse
environment; the specular environment takes Lagarde and de Rousiers'
specular occlusion from it, saturate((n·v + ao)^(2^(−16α − 1)) − 1 + ao),
which leaves a mirror facing the viewer unoccluded and closes a rough lobe
as the diffuse one. Neither touches the Sun (R4's shadows do) nor the plume
lights.

## Cost

- **Faces:** two a frame in turn while nothing moves enough to make one
  stale; all six on a temporal reset, a frame that does not follow the last,
  new settings, a warp above 10× (so the Earth turning under the vessel at
  1000× is never stale), a centre moved over 1 km or a Sun turned over 0.05°
  (`EnvironmentProbePass.fullUpdate`). At 1× a face is at most two frames
  old: 400 m of LEO, 0.0002° of Sun.
- **Derived maps** every frame, their dispatches concurrent: the prefilter
  a SIMD group of 32 to a texel (the rough mips' few texels do not wait on
  long loops), the irradiance tiled through threadgroup memory (each group
  loads every source texel once).
- **No stall:** the lighting uniforms live in a buffer of their own while
  the SH9 copy writes them (`FrameArena.pushSeparately`). In the arena,
  Metal's per-buffer hazard tracking made every later encoder wait for the
  copy and the copy for C2's march: 6.2 ms on the pad.
- A one-command blit ends the pass, so the driver does not merge its
  compute with the next P0 pass's.
- **Measured** (`ProbeCostTests`, ORBITSIM_TIMINGS=1, 3024×1964, High, the
  whole frame with every default pass, the probe on and off on alternate
  frames, three runs of 300 rounds, medians of the on/off pairs): 0.18 ms on
  the pad, 0.20 ms at 60 s of ascent, 0.25 ms in LEO, against 0.3 ms; the
  runs scatter by about ±0.15 ms.
