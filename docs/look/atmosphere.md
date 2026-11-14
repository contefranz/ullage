# The atmosphere (M1.6 track A2)

How the renderer draws the Earth's air from A1's optics
(docs/m16/atmosphere-luts.md), and what other passes take from it. The code
is the reference: `Sources/OrbitRender/Passes/AtmospherePass.swift`,
`Shaders/AtmosphereCommon.swift` (the header other modules include),
`Shaders/AtmosphereShaders.swift`, the Earth's part of `Shaders/PlanetShaders.swift`,
and in OrbitScene `Atmosphere/` (the maths, tested on Linux) and
`Settings/AtmosphereSettings.swift`. Method: Hillaire (2020), "A Scalable and
Production Ready Sky and Atmosphere Rendering Technique", reimplemented from
the paper; nothing is ported.

## What is drawn where

- **P0, `AtmosphereLUTPass`** (compute):
  - Once per optics (the settings' aerosol and ground albedo): A1's tables,
    built on a background queue (`AtmosphereTables`, 0.33 s in Release, 25 s
    in Debug) and uploaded as they are (rgba32Float). The first frame waits
    for them (`waitForTables`), so every image has its air.
  - Each frame: `AtmosphereUniforms` (below); inside the air the sky-view LUT
    (192 × 108, Hillaire's latitude-biased parameterisation); the
    aerial-perspective froxels (32 × 32 × 32); from space the haze over the
    ground at a quarter of the resolution.
- **P1, the planet pass:** the Earth's ground is lit through the air (the
  Sun's transmittance to the ground point and the sky's irradiance there,
  A1's tables) and hazed: inside the air by the sky-view LUT's rows below the
  horizon (the light scattered on the way to the ground) and the
  transmittance from A1's table along the reversed ray; from space by P0's
  haze. Bodies without air are Lambert grounds under R1's sunlight. The
  planet shader no longer draws a sky, and R1's legacy scale is gone.
- **P2, `AtmosphereCompositePass`:** the sky, a full-screen triangle at the
  depth of the far side of the atmosphere's shell (reversed-Z,
  greater-equal, read-only), so it covers what lies behind all the air (the
  stars, the Sun's disc, the Moon) and leaves the planet and everything in
  front of it to their own shaders. Dual-source blending makes the scene
  radiance + transmittance × scene per channel: the Sun's disc is reddened
  and dimmed through the air, stars fade into the day sky. Inside the air
  the sky comes from the sky-view LUT; from space each pixel marches its ray
  through the shell (24 steps crowded toward the ray's lowest point) in the
  planet's figure coordinates, with the planet's shadow in the air (A1's
  transmittance to the Sun, zero below the horizon at each sample).

Figure coordinates: the body axes with z stretched by a/b, where the WGS-84
ellipsoid is the sphere of radius a that A1's optics stand on; the phase
functions take their angle from world directions.

## For other tracks

**`AtmosphereUniforms` (buffer 28), filled in P0** (C2's cloud members are
left alone):

| Member | Value |
|---|---|
| `worldToBody` | the Earth's rotation (rotation only) |
| `planetCenter` | xyz the Earth's centre, camera-relative (m); w the ground's radius a |
| `radii` | x ground 6,378,137 m, y top (+100 km), z the camera's altitude above the optics' sphere (m), w 1 when the Earth is in the scene and the tables are ready |
| `rayleighScattering`, `mieScattering`, `mieExtinction`, `ozoneAbsorption`, `ozoneLayer` | A1's `coefficients` (atmosphere-luts.md); `ozoneLayer.x` is the tent's half-width; `mieExtinction.w` is g |
| `groundAlbedo` | the multiple scattering's ground albedo |
| `sunTransmitted` | rgb the Sun's colour at the camera through the air, unitless: A1's transmittance per channel times R1's 5772 K colour at unit luminance; w the Sun's illuminance above the air (lux, `RenderScene.Sun.illuminance`) |
| `skyIrradiance` | rgb the sky's light (without the direct Sun) on a horizontal surface facing up at the camera, lux; 0 above the air |
| `aerialPerspective` | x the froxels' slices (0: none, as above 2,000 km), y the last slice's distance (m), z the slice exponent k |

- **The Sun's light on a surface** is `sunTransmitted.rgb * sunTransmitted.w`
  lux per channel. With no air in the way that is exactly
  `FrameUniforms.sunIlluminance.rgb`; behind the Earth the colour is black
  and w stays positive (R2 tests `w > 0` to choose the air's values). Multiply
  by Eclipse's sunlit fraction as before. At the dawn pad (Apollo 8, the Sun
  7° up) the transmittance is (0.37, 0.18, 0.052).
- **Aerial perspective** to a point at distance t along the pixel's ray:
  `atmo_aerialPerspective(froxels, sampler, uv, t, air)` returns rgb
  in-scattered luminance (cd/m², not pre-exposed) and a the transmittance
  (the channels' mean): `L = L_surface * a + rgb`, then times the exposure.
  The froxels hold the march from the camera to far × ((i + 1)/n)^k for slice
  i; nearer than slice 0 the light fades to none at the camera. Far is the
  camera's horizon distance plus a 12 km cloud top's (32-2,000 km).
- **Textures:** transmittance in slot 25, multiple scattering in 28, the
  sky-view LUT in 29 (inside the air), froxels in 30. A1's irradiance and
  profile tables, which have no reserved slot, are in `FrameContext.textures`
  (`.atmosphereIrradiance`, `.atmosphereProfile`) for a pass to bind at its
  own index (the planet module: 1 and 2). The haze from space is
  `.spaceGroundScatter` / `.spaceGroundTransmittance`.
- **Storage: P0's light is rgba32Float, in cd/m², not pre-exposed.** The
  sky-view LUT, the froxels and the haze from space (`.spaceGroundScatter`)
  hold luminance as it is, so a reader multiplies by
  `FrameUniforms.exposure.x` and clamps at 6e4, as R1's contract has it, and
  needs no scale of A2's. Half float would not hold it: toward a low Sun A1's
  aerosol (g 0.8) scatters forward far past half float's 65,504 (which a
  write turns into +∞). In red that is about 1.5e5 cd/m² along the froxels
  toward the dawn pad's Sun at 7°, and 9e4 over the ground at the silhouette
  from low orbit with the Sun 5-9° above the limb. Every froxel is finite. A
  fixed storage scale in half float (kcd/m²) would also fit, but it puts
  A2's unit into every reader. Pre-exposing ties the froxels to one frame's
  exposure. rgba32Float costs 512 KB for the froxels and 6 MB for the haze at
  3024 × 1964 (a quarter of the resolution); see the cost below. The haze's
  transmittance (0-1) stays rgba16Float.
- **The header** (`ShaderHeader.atmosphereCommon`): A1's table lookups
  (`atmo_transmittanceToTop`, `atmo_transmittanceToSun`, `atmo_sunTable`),
  the medium, the phase functions, `atmo_march` and `atmo_step`,
  `atmo_airSegment`, `atmo_skyViewUV`, `atmo_transmittanceToGround`,
  `atmo_aerialPerspective`. C2's clouds take the Sun's light at a cloud
  sample from `atmo_transmittanceToSun` and the ambient from the irradiance
  table.
- **What the composite does not haze:** anything drawn in P1-P3 nearer than
  the far side of the shell (vessels, sites, plumes, particles, the planet).
  Their shaders apply the froxels themselves, as Hillaire's forward path
  does; the vessel pass (R2) and the plumes (P2) have not yet. Far points
  (R1's FarPointPass) are not hazed.
- **R3's probe:** `AtmosphereCompositePass.encodeProbe(f, on:, formats:,
  viewToWorld:, tanHalfFov:, faceSize:, preExposure:, depth:)` draws the sky
  the camera sees over a face of the probe's cube (radiance + transmittance ×
  what the face holds), in cd/m² at pre-exposure 1. It returns false when the
  frame has no air. The planet shader marches the ground's haze itself when
  P0's reduced-resolution haze is not bound (a probe face).
- **Settings** (`RenderSettings.atmosphere`): `enabled`, `waitForTables`,
  `aerosolOpticalDepth` (0.1), `groundAlbedo` (0.1), the sky view's size and
  steps (32), the froxels' size, slices, exponent and steps (12), the limb's
  steps (24), the ground's steps from space (12) and that pass's divisor (4).

## Checks

On Linux (Tests/OrbitSceneTests/AtmosphereSkyTests.swift):

| Check | Reference | Result |
|---|---|---|
| Sky-view and froxel parameterisations | round trips | 1e-9 |
| The march the GPU mirrors | A1's `skyRadiance` (400 steps), pad and orbit, sky and limb | within 2 % |
| Sky shape: zenith over diffuse illuminance, anti-solar horizon over zenith, 90° from the Sun | CIE standard clear sky, type 12 (CIE S 011/E:2003, ISO 15469: a −1, b −0.32, c 10, d −3, e 0.45), integrated in the test | within 15 % with the Sun at 7-10°; at 20-40° the model's horizon is 30-40 % brighter against its zenith than the empirical fit (45 %) |
| The Earth's shadow over an observer | sunlit above R(sec δ − 1): 35.1 km at δ = 6° | shadow below 0.8×, light above 1.25× |
| Twilight | the zenith at −6° under 1 % of the sunset's, at −12° under 1 % of −6°'s | yes |
| The Sun at the dawn pad | A1's (0.37, 0.18, 0.052) | within 0.05 |
| `sunTransmitted` above the air | R1's sunlight | 1e-6 |
| Limb darkening | Hestroffer and Magnan (1998, A&A 333:338): μ^α, α = −0.023 + 0.292/λ[µm], cited through secondary sources (grade M) | α 0.406, 0.508, 0.641; disc mean 1 within 0.2 %; 550 nm centre/mean 1.254, R1's linear law 1.25 |

On the Mac (Tests/OrbitRenderTests/AtmospherePassTests.swift), against the
Swift march with the GPU's steps: the pad's sky (sky-view LUT) within 4 %;
the limb from orbit within 1.5 %; the ground from orbit within 3 % (the
quarter-resolution haze) and from the pad within 4 %; froxels within 2 %;
the light behind the air transmitted per channel within 2 %; the Sun's disc
at EV 27 within 3 %; the uniforms R2 reads; the probe face equal to the view
within 1 %; no NaN from the pad to lunar orbit. Two tests cover the haze
past half float's range:
- From low orbit, with the Sun 6-8° above the limb, the ground along the
  silhouette is the march's within 3 %, bilinear between P0's texels as the
  planet samples them. It is neither black nor clipped, and the haze there
  passes 65,504 cd/m².
- At the dawn pad, every froxel is finite, and the columns toward the Sun
  are the march's within 2 %, past 65,504 cd/m².

Half float's subnormals are 0.0024 cd/m² at EV 15 in the scene buffer,
which bounds what a test can read in the dark.

Look-dev goldens: `docs/look/shots/a2-look.json` (dawn toward and away from
the Sun, the daylit limb, the sunset limb, the whole Earth). Scenes with the
user's BMNG texture, contact sheet only: `docs/look/shots/a2.json`.

## Cost (M3 Pro, 3024 × 1964, orbitsnap --timings 60, GPU lock)

| View | P0 LUTs | P2 composite | Planets |
|---|---|---|---|
| Pad at dawn | 0.25 ms | 0.21 ms | 0.30 ms |
| Ascent at 150 s | 0.25 ms | 0.19 ms | 0.28 ms |
| LEO, the limb | 0.31 ms | 0.88 ms | 0.34 ms |
| LEO, nadir | 0.54 ms | 0.29 ms | 0.50 ms |
| LEO, sunset | 0.28 ms | 0.91 ms | 0.33 ms |

The plan's A2 budget is 0.3 + 0.4 ms at the pad and 1.0 + 0.4 ms in LEO; the
composite carries the limb march, so in LEO the two together (0.8-1.2 ms)
are the measure.

## Not done, and limits

- The air is US-1976's: the launch day's sounding (A1 supports it; τ +0.9 %)
  needs the scene to say which atmosphere the simulation flies.
- No refraction: the setting Sun is not flattened, and sets about 0.5° early.
- No airglow (the design's optional 557.7 nm layer).
- R1's disc keeps its linear limb darkening (u = 0.6, white);
  `SolarLimbDarkening` has the redder limb by wavelength for when R1 adopts it.
- R1's veiling glare is scaled by the Sun above the air, not
  `sunTransmitted`, so a reddened setting Sun still glares at full strength.
- In Debug the tables take 25 s to build, and the app's first frame waits
  for them.
