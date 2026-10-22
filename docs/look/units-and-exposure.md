# Units and exposure (M1.6 track R1)

The renderer's scene is linear light in photometric units, exposed like a
camera and tone mapped once. This page records the values the code pins,
where each comes from, and how sure it is (grades as in the datasheets:
H = a primary source, M = a secondary source or a derived value, L = an
estimate).

## Units

- **Light** in the scene targets is luminance in cd/m², in linear Rec. 709
  primaries, times the frame's **pre-exposure** P = 1 / (1.2 · 2^EV100)
  (`FrameUniforms.exposure.x`). A pixel value of 1 is the sensor's
  saturation. Shaders write `L × P`; nothing above 6e4 survives the
  resolve (half float's range).
- **The Sun** (`FrameUniforms.sunIlluminance`): rgb is its illuminance
  above any air in lux, coloured; w its total.

| Value | | Grade | Source |
|---|---|---|---|
| E⊙ at 1 AU | 133,334 lx | M | Darula, Kittler and Gueymard 2005, CIE V(λ) (134,108 lx with V_M(λ)); secondary sources quote the paper; earlier values span 127.5-133.8 klx |
| The Sun's radius, temperature | 695,700 km, 5772 K | H | IAU 2015 B3 |
| Angular radius at 1 AU | 0.26645° | H | from the above |
| Mean disc luminance E⊙/Ω⊙ | 1.962e9 cd/m² | M | from the above; a 5772 K blackbody gives 1.845e9 (6 % lower) |
| Limb darkening | linear, u = 0.6 | M | Allen (u ≈ 0.56-0.62 at 500-600 nm); the centre is 1.25× the mean |
| The Sun's colour | (1.110, 0.976, 0.912) at unit luminance | M | a 5772 K blackbody through the Wyman-Sloan-Shirley CMFs |
| Magnitude 0 | 2.54 µlx | M | Allen; with V⊙ = -26.76 (Willmer 2018) it gives E⊙ within 4 % |
| Star colour | blackbody at Ballesteros' T(B-V) | M | Ballesteros 2012 |
| Heat-shield glow | grey body, ε = 0.85, radiative equilibrium | L | M1.5's model, now in luminance |

Checks in `Tests/OrbitSceneTests/PhotometryTests.swift`: the 1948 candela
(60 cd/cm² at 2041.4 K, within 0.3 %), CIE illuminant A's chromaticity
(within 0.002), the Planckian locus against Kim et al. (within 0.003).

## Exposure

- EV100 = log₂(N²/t · 100/S); a meter reads an average luminance
  2^EV100 · 12.5/100 (ISO 2720); saturation at 1.2 · 2^EV100 (Lagarde and
  de Rousiers 2014). At EV 15, sunlit white paint (albedo 0.8) reads 0.86.
- **Auto** (default): a 256-bin histogram of EV100 from -6 to +26, centre
  weighted, of the bloom pyramid's eighth-resolution level, so that stars
  and other points fall below the darkest bin and only extended light
  counts; pixels darker than 0.002 cd/m² are left out. The target is the
  mean of the 50th-95th percentile less the compensation (+1 EV by
  default), but never so bright that the top 1 % goes past 2× saturation
  (a glowing heat shield, a sunlit vehicle over the night side). Under 2 %
  lit, it slides towards EV -2. The camera follows in wall-clock time, at
  most 2 EV/s brighter and 1 EV/s darker, within EV -4 to 17; the first
  histograms after a scenario loads set it at once. Histograms come back
  from frames the GPU has finished, so each frame is pre-exposed at the
  EV it is shown at.
- **Manual**: a fixed EV100. **Photo**: the Hasselblad's f-number, shutter
  and film speed; the default is the Earthrise frame's f/11, 1/250 s on
  ISO 64 film, EV100 15.5.
- **Snapshots** let the auto exposure snap and then adapt until it
  settles; look-dev shots use manual EVs.

## Tone mapping and post

- **AgX** (default), from three.js, baked into a 33³ LUT over log₂ input
  from 2^-12 to 2^5: within a step of 8-bit sRGB on average, 2 steps for 99 %
  of colours. **PBR Neutral** is evaluated in the shader (a per-channel LUT
  follows its min/max structure poorly).
- **Resolve**: the scene's last draw weights each MSAA sample by
  1 / (1 + its brightest channel), weight in alpha, so the hardware's
  average is a weighted mean and edges against the Sun or a plume do not
  alias. Passes before it blend in linear light.
- **Bloom**: six levels from half resolution, rgba16Float (rg11b10Float's
  short mantissas lost 3 % of the light), 13-tap down (the first level from
  each 6×6 neighbourhood of decoded texels, shared in threadgroups) and tent
  up; level i holds (1 - 0.6) · 0.6ⁱ of the light; the tone map makes the top
  as it reads it. 3 % of the image's light is spread, with no threshold. The
  pyramid conserves energy within 1 %.
- **Sun visibility**: 64 points over the disc against the resolved depth.
  It scales a veiling glare L = 3e-4 E⊙/θ² (a tenth of the eye's
  Stiles-Holladay glare), which fades out 10° outside the frame.
- **Dither**: ±1 step of the 8-bit output (within about 20 %), triangular,
  from a 64² blue noise moving each frame.

## The transition (until A2, E2, R2 and P2)

Today's planet, vessel and plume shaders compute light relative to a white
Lambert surface facing the Sun; they multiply it by P · E⊙/π. Their ambient
floors (0.015 for the planets, 0.02 for the vessels) instead stay as they
were on screen, a night floor relative to the exposure, so that the night
side is dark under any exposure. The Sun is drawn by the star pass, not the
planet pass. The orbit line and markers draw after tone mapping.
