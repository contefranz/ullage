# Clouds (M1.6 track C2)

How the renderer draws the clouds from C1's weather, what it was checked
against, what it costs, and what other tracks read from it. Design:
docs/m16/design-earth-moon.md, clouds; plan: docs/m16/plan.md, C2.

## What is where

- **OrbitScene/Clouds** (pure Swift, Linux-tested):
  - `CloudNoise`: tileable Perlin, Worley, Perlin-Worley and curl noise, the
    reference the GPU's volumes mirror;
  - `CloudScattering`: Henyey-Greenstein, Draine, Jendersie and d'Eon's
    approximate Mie, and the march's lighting (`CloudLighting`);
  - `CloudSlab`: that lighting marched through a flat homogeneous slab,
    and the far regime's LUT baked from it;
  - `CloudCoverage`: the coverage thresholds, so the drawn cover is ERA5's,
    and the statistics that tie the march and the cirrus to C1's layer model
    (`CloudCoverageTables.swift`, baked from the shape volume);
  - `CloudFrame`: the per-frame geometry in Double (figure coordinates,
    shells, noise origin, reprojection, the shadow map's frame, regimes,
    wind advection, the cirrus's streak frame, the reprojection rule);
  - `CloudWeatherMap`: what the GPU assembles C1's weather from, and its
    mirror.
- **OrbitRender**: `Passes/CloudPass.swift` (P0, and R6's first
  half-resolution effect), `Shaders/CloudShaders.swift` (module `Cloud`, and
  the `.cloudShadow` header for other tracks), `Clouds/CloudNoise.swift` (the
  volumes and the slab LUT on the GPU, and `CloudAir`: A1's tables as A2
  shares them).
- **Settings**: `CloudSettings` (`RenderSettings.cloud`).
- **Specs**: `docs/look/shots/c2.json` (the cloud slab, look-dev goldens),
  `c2-scenes.json` (the contact sheet: Apollo 8's pad and ascent on
  `apollo8-pad`, AS-506's pad, ascent, orbit and terminator, the climb),
  `c2-near.json` (the ascent under, inside, on top of and over a uniform
  deck).

## The frame

In P0, on the command buffer:
1. **Noise volumes**, once: 128³ shape (Perlin-Worley, three Worley fBm
   octaves), 32³ detail (Worley fBm), 128² curl, mipmapped.
2. **The weather map**, 1440 × 721 like ERA5: the two snapshots around the
   time, the climatology beyond the field's span, the pad's observed sky
   (TM X-64796), then the layer model's heights (C1's `CloudWeather` and
   `CloudLayerModel`, line for line). Assembled again only when a weight
   moves by 1/500.
3. **The cloud shadow map**, 256² along the Sun around the camera's ground
   point (100 km on the ground, growing to 1,000 km from orbit on a ladder
   of 100, 200, 400 and 800 km, so its texel changes at four heights only),
   snapped to whole texels of a lattice through an anchor near the camera,
   moved by whole texels when the camera is a quarter of the map away (it
   turns about the anchor with the Sun, a quarter of a texel a minute).
   Each texel holds
   the optical depth along its line towards the Sun above 0, 2, 6 and 10 km,
   the cirrus included, marched on the curved Earth with the weather where
   the line crosses the layers (refetched every 4 km).
4. **The march** of the low and mid layers at R6's half resolution in the
   near field, a quarter of it from 20 km up. It marches one texel in four a
   frame and reprojects the rest, or every texel when reprojection is off.
5. **The resolve**: each texel marched this frame, or last frame's at the
   same body-fixed point (rescaled to this frame's pre-exposure), clamped to
   its marched neighbours. A marched texel averages with its history. This
   is `.cloudLayer` and `.cloudDepth`.

In P3, R6's half-resolution encoder: **the slot copy** adds the far layers
and the cirrus per texel of R6's targets, orders them by distance, hazes
them, cuts the clouds at the scene's depth, and writes R6's clouds layer
and its front. The haze: with the camera inside the air, one lookup of
A2's aerial-perspective froxels at the parts' combined, opacity-weighted
mean distance; above the air, A2's haze over the ground from space, as
the ground has it, each part its share by height (the air's mass above
it). The froxels reach 2,000 km along the ray, not in altitude, so from
orbit they would leave the disc's outer part unhazed.

## The regimes

- **Near and orbit** are one march. Clear-air steps are uniform across the
  shell in orbit, and grow with the distance in the near field. A ray above
  every layer jumps to the highest top on the curved Earth, and a ray below
  every layer going down stops. On meeting cloud it finds the edge by
  bisection. Through the cloud's first two optical depths it steps 0.4; after
  that the steps grow with the distance, up to 2. The detail erodes the
  shapes out to 15-60 km. A light march of 4 samples over 1.5 km looks
  towards the Sun.
- **Density:** the thresholded shape alone averages 0.1-0.2 of C1's
  in-cloud extinction, so the march scales it by `CloudCoverage`'s
  `densityScale` (5-11 by cover): in cloud its extinction averages C1's β,
  peaks at 3-4 times that.
- **Far** is a surface layer: per pixel, each layer's cover times the slab
  LUT at C1's in-cloud optical depth (`farDensity` 1), with the same phase,
  Sun and sky. With the march's extinction at C1's in cloud the two agree on
  a broken deck: the march lights each sample through its column at that
  density, which reflects as C1's slab does (an independent-pixel average
  over the march's actual column depths came out 1.5-1.7 times too dark).
  The LUT holds each slab seen from above and from below, so the far layer
  serves the pad's horizon as well as orbit.
- **Hand-over:** by the pixel's footprint on the low layer (1.5-6 km), so
  from orbit the limb is far while nadir is marched; and by the camera's
  height (3,000-6,000 km). Above 6,000 km nothing is marched. Inside the
  shell the footprint rule holds where the camera is clear of the layers
  the ray meets: under the low base, over the mid top, or between the low
  top and the mid base looking down (ramped over 50-300 m). Inside a layer
  the march does everything out to `nearReach` (150 km). The footprint is
  R6's half-resolution texel's whatever the march's scale, so a change of
  scale does not move it. The two parts' mean distances blend by their
  shares of the opacity.
- **Cirrus** is a 2D layer at 10 km, 1.8 km deep (lidar climatologies'
  mean deck; the 8-12 km band made it twice too thick): fibres of the Worley
  fBm with their own coverage thresholds and scale (its in-cloud extinction
  averages C1's, so its optical depth averages 0.37),
  stretched eight times along the 250 hPa wind in a streak frame anchored on
  the ground (body-fixed: re-anchored after 1,000 km or a 30° turn of the
  wind, the old frame fading over 2 s), warped by the curl in that frame's
  tangent plane. Lit as a thin slab: the Sun scattered once in closed form,
  and the slab's diffuse streams scattered towards the eye as the march
  does, with ice's phase (g 0.75). The fibres are drawn from the shape's
  mip 0 or 1 (their thresholds are mip 0's) and hand over to the deck's mean
  (its in-cloud depth over the cover's share) over 128-512 m footprints,
  the two blended in light and opacity, each lit at its own depth.
- **Profiles:** the low layer rises fast from its base and tapers above 0.4
  of its depth (flat bases, domed tops). The mid layer's profile peaks at
  0.35 and rounds off both ways, so a patch of altocumulus is a lens as
  thick as its density is over the cover's threshold; a plateau cut every
  patch at the same two heights, boxes when seen edge-on from afar.
- **Wind:** each layer's noise drifts with its wind; the drift starts over
  only with a scene (the extractor's first frame or a jump in time), not on
  a warp change or a camera cut.
- **Large-scale structure:** two octaves (400 km and 100 km) of the shape
  volume on the sphere move partial cover up and down, by 4c(1 − c) of
  `coverageModulation`. They are applied alike in the march and the far
  layer, so ERA5's 28 km grid does not show.

## Lighting

Per unit extinction and irradiance, at each sample:
- **The Sun's light scattered once**, with Jendersie and d'Eon's
  approximate Mie for 20 µm drops (g 0.879), through the light march's
  optical depth. The air's transmittance comes from A1's table (as A2
  binds it, `CloudAir`) at the
  sample's height and fades over the Sun's disc as it sets.
- **Multiple scattering** from the two-stream slab C1 checks clouds against
  (Bohren 1987): the diffuse streams of the sample's column, of optical depth
  σ times the layer's thickness. The sample's depth in the column is the
  lesser of its height fraction and the light march's (made vertical). The
  Sun feeds the column's top flux, less the direct beam.
- **The sky's light**, entering the same column diffusely from A1's sky
  irradiance at the sample's height.

The design's octaves (Wrenninge 2013) were tried first and dropped. Their
light comes out of the cloud's top optical depth only, so with Hillaire's
a = b = c = 0.5 a deck of τ 90 had a plane albedo of 0.09 against 0.18 for
τ 3. The two-stream slab gives 0.87 and 0.18.

## Checks

| Check | Result |
|---|---|
| Worley against a brute-force search | 1e-5 |
| Curl's divergence against its gradients | under 1e-3 |
| HG, Draine, approximate Mie normalised; Mie g at 20 µm | 1e-3; 0.879 (water clouds 0.86-0.88) |
| Streams' top flux = C1's slab reflectance; R(10, 0.85) | exact; 0.430 |
| March's single scattering against its closed form | 1 % |
| Slab plane albedo against two-stream, Sun at 60° | within 15 % from τ 10 to 90, 0.04 below |
| Drawn cover against the cover | within 0.03 |
| Weather mirror against `CloudWeather.sample` | 1e-6 |
| GPU noise volumes against `CloudNoise` | one 8-bit step |
| GPU weather map against the mirror | half-float steps |
| GPU march on a slab against `CloudSlab.march` | 1-2 % per texel |
| GPU march against the far LUT, slab from LEO | 1.6 % mean, worst texel 4.3 % |
| Shadow map under a slab of τ 20 | 5 % |
| A slab seen from below: single scattering against its closed form; a thick deck's base against two-stream's transmitted light (T/π and T/R of its top) | 1e-9; within 25 % |
| The march's in-cloud extinction against C1's β, low and mid, cover 0.1-0.9 (an independent sample) | within 8 % (15 % at 0.1) |
| Cirrus: drawn cover against the cover; in-cloud optical depth against C1's | within 0.04; 8 % (15 % at 0.1) |
| GPU: a broken low deck marched against the far layer from LEO, cover 0.3 and 0.7 | radiance within 25 %, opacity within 30 % (oblique views see more cloud than the cover) |
| GPU: 4/10 cirrus from orbit at 650 m footprints (the deck's mean drawn) | 4/10 of the deck's opacity within 20 % |
| GPU: the cirrus's opacity at 0.2-6 km footprints, 1/10 and 5/10 cover; through a re-anchor's fade | the same within 25 % (35 % at 1/10); within 10 % mid-fade |
| GPU: the hand-over at a far weight of 0.16, the march's gaps | the far layer's share shows in over 75 % (none before) |
| GPU: the shadow map at Apollo 8's dawn, a full deck but a clear pad | over 95 % of the lines crossing it 60-400 km out shaded |
| GPU: the weather map after another mission | the same as a fresh pass's |
| GPU: the wind's drift through a warp change | goes on (1 m) |
| GPU: the hand-over's pixel angle across the march's scale changes | the same |
| GPU: the pad's horizon 0.3-1.5° up, the far layer against C2's field integrated to convergence (the #73 review's port), 1/10 and 3/10 | within 0.08 (0.76 against 0.73-0.85; 0.99), and no thinner than the march |
| GPU: the far layers in front of the ground only, from 2.9 km over the ascent | the low layer the same with a 5/10 mid layer behind the Earth (0.07 of it before) |
| GPU: under a 2.8 km base at 2.2 km, rays 0.3-1° down | no far layer (0.28 opaque before) |
| GPU: the haze from above the air: at 1,500 km over the disc's outer part, and across 2,000 km | hazed (0.76-0.87 of the bare clouds); the same within 5 % (0.9997) |
| GPU: the march in its own GPU pass | four encoders, after A2's LUTs |
| GPU: the resolve after a 2 EV jump | within 2 % of a steady exposure |
| The cirrus's noise coordinate as the camera moves 400 km; the shadow map's lattice across 20 km | whole periods; whole texels |

## Cost

M3 Pro, 3024 × 1964, GPU lock held, on main with A2 (#67) and R1's #70.
One queue, clouds on and off on alternate frames; difference of the
medians (`CloudCostTests`, `ORBITSIM_CLOUD_COST=1`). The P0 pass alone,
steady (reprojecting) and fresh (every texel marched, as at 10× warp):

| Shot | Steady | Fresh |
|---|---|---|
| Pad (AS-506) | 2.3-3.0 ms | 5.0-5.4 ms |
| Ascent, 60 s | 2.0-2.6 ms | 4.2-4.4 ms |
| LEO | 1.5-1.9 ms | 3.8-4.3 ms |
| Earth from 22,000 km | under 0.1 ms | under 0.1 ms |

With every default pass (`ORBITSIM_CLOUD_COST_FULL=1`), the clouds add the
following (steady; three runs for the pad and LEO, one for the others).
R6's slots cost 0.85-1.1 ms of it whenever anything draws through them,
even a tiny test slab (`ORBITSIM_CLOUD_COST_R6=1`; R1's #70 resolves the
scene at the break), so the clouds' own share is the difference:

| Shot | Clouds added | R6's slots | Clouds' own (budget) |
|---|---|---|---|
| Pad | 2.4-2.6 ms | 0.9 ms | 1.5-1.7 ms (3.0) |
| Ascent, 60 s | 2.0 ms | 0.85 ms | 1.2 ms |
| LEO | 2.6-2.9 ms | 1.0-1.1 ms | 1.5-1.9 ms (2.0) |
| Earth from 22,000 km | 1.7 ms | 0.8 ms | 0.9 ms |

- Fresh frames add about 1 ms. Run to run the full frame varies by about
  0.3 ms, the P0 pass alone by up to 0.7 ms (the ranges above).
- LEO is within its budget, but not by much at the top of its range.
- **The march has a GPU pass of its own.** Apple's driver merges
  consecutive compute encoders into one GPU pass, and an encoder that
  depends on any part of it waits for all of it. A Metal System Trace
  (`xctrace`, the LEO shot) showed A2's LUTs and the march merged into one
  pass, "Atmosphere LUTs & Clouds". P1's planet pass reads the LUTs, so it
  waited for the march's 2 ms: the clouds added 1.2 ms more with A2 in the
  frame than without, for the same GPU work. CloudPass now encodes the
  weather and shadow maps (which P1 reads through slot 24), then a
  one-command blit, the march and resolve, and another blit. The march
  then overlaps P1. The clouds' addition went from 3.7-4.0 ms to 2.6-2.9 ms
  in LEO, from 3.3-3.8 ms to 2.4-2.6 ms on the pad and from 3.5 ms to
  2.0 ms in the ascent (`testMarchHasAGPUPassOfItsOwn` keeps the encoders
  apart).
- The clouds' haze (one froxel lookup per texel) measures nothing in LEO
  and 0.3-0.4 ms on the pad (a build with it disabled); the far layer and
  the shadow map are 0.1 ms or less in LEO.
- The far layer is evaluated only for rays that meet a layer's shell before
  the ground: under the cloud base, the downward rays used to evaluate it
  over the whole ground (1.4 ms on the pad) only for the depth cut to drop
  it.

## For other tracks

- **The cloud shadow** (E2's ground, R2/R4's vessels, P2's plumes): add
  `.cloudShadow` to a module's headers and call
  `orbit_cloudSunTransmittance(p, atmosphere, texture 24, sampler 14)` at a
  camera-relative point. It reads `AtmosphereUniforms.cloudShadowMatrix`
  (camera-relative world to the map's u, v and the height above the ground)
  and `cloudLayer` (w is 1 when the clouds draw). Off the map it is 1; from
  orbit the far layer's own cover darkens the ground beyond it.
- **Plumes and particles**: R6's composite orders the clouds layer against
  theirs by front. `.cloudLayer` (premultiplied radiance, pre-exposed, and
  1 − T) and `.cloudDepth` (log2 of the linear depth of the front, the
  opacity-weighted mean and the entry) hold the march's clouds at the march
  target's resolution, for a pass that wants the transmittance in front of a
  point: (1 − a) raised to the fraction of the way from the entry to twice
  the mean depth. These are not hazed: a pass that reads them applies A2's
  froxels at its own distance, as the slot copy does.
- **A2 (AtmosphereContext):** the clouds read A1's transmittance and sky
  irradiance from A2's LUT pass (`FrameContext.textures` `.atmosphereLUTs`
  and `.atmosphereIrradiance`, set in P0 before the clouds), and with the
  atmosphere off from A2's `AtmosphereTables` cache, uploaded once. The slot
  copy reads A2's froxels (slot 30) and `AtmosphereUniforms` (buffer 28) for
  the aerial perspective. A2's tests and look-dev goldens draw the air
  alone (clouds off); C2's slab tests and goldens draw the clouds alone
  (atmosphere off), whose pixels the adoption left unchanged.

## Open

- **Near field** (this follow-up): done are the horizon from below (the far
  layer seen from below), the ascent under, inside and over a deck
  (`c2-near.json`), the views from between the layers, and the aerial
  perspective (A2's froxels, and beyond their reach A2's haze from space).
  Open: the detail erosion up close wants tuning against photographs.
- **The 13 km step:** the march switches from near to orbit at the shell's
  top in one frame. Inside the shell its reach is 150 km, its clear-air
  steps grow with the distance and the far layer takes no ray; above, the
  ray spans the shell to the horizon in uniform steps and the far layer
  takes it by footprint. As the camera climbs through 13 km a band 3-7°
  below the horizon changes at once. This follow-up hands rays
  to the far layer by footprint from the ground up (wherever the camera is
  clear of the layers it meets), which takes the far layer's step away; the
  reach and the steps still want blending there. `CloudFrame.regimes`'
  near and orbit weights are reported, not used.
  Out there the march's clear-air steps (4 km at 100 km) find less than
  the field holds: 0.42 opaque at the pad's horizon at 1/10 where the far
  layer and the converged field give 0.76-0.79, so above the band the far
  layer takes (to about 1.2° at 1280 × 800) the clouds thin toward the
  march's.
- **The far layer from above at grazing views** keeps the cover overhead
  (the LEO limb): seen from below it takes the cover along the ray, but the
  march from orbit sees the deck's shadowed sides at oblique views as well,
  and scaling the light by the cover along the ray made it 37 % brighter
  than the march (testMarchAndFarAgreeOnABrokenDeck).
- **Water paths** (decision 29): not added. The far layer's optical depth
  is the layer model's. ERA5's total column liquid and ice water would vary
  the brightness of thin and thick decks; adding them is two OSCLOUD1
  planes, a change to C1's tool and a 3-6 minute re-fetch per mission (the fetches took 2:42-5:44).
- **Apollo 8:** `apollo8-pad` is a look-development stand-in: AS-506's
  stack, physics unchanged, dressed as AS-503 on Apollo 8's day. The
  parking orbit on that day is M2's, so the test harness
  (`CloudApollo8Shots`) only draws a daylit orbit.
