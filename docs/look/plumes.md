# Plumes (M1.6 track P2)

How the engine plumes are drawn, where each number comes from, and what was
calibrated against which photograph. The physics is P1's
(`Sources/OrbitCore/Effects/PlumeModel.swift`, `docs/exhaust-datasheet.md`);
this page is the look on top of it. Grades as in the datasheets: H high, M
medium, L low (visual, calibrated or assumed).

## The pipeline

1. **Members** (`OrbitScene/Look/PlumeLook.swift`). Each emitter (a thruster
   delivering thrust) becomes a `PlumeMember`: P1's `PlumeState` for its
   engine family (`ApolloExhaust`), at its flow over the family's rated
   flow (P1: the chamber pressure follows the flow, so start and shutdown
   transients shrink the plume), in the air the simulation flies through
   (AS-506's launch-day sounding at the pad). Engines the exhaust library
   does not know (the M0 test vehicles) take M1.5's look table
   (`PlumeLook.legacy`), which is also the stub the switch-over was checked
   against (`"model": "legacy"`).
2. **Clusters** (`OrbitScene/Look/PlumeClusters.swift`). Members of one
   family on one vessel whose axes agree within 12° and whose exits are
   within three of their summed radii join, up to eight: the S-IC's five
   F-1s and the S-II's five J-2s are one cluster each, the S-IC retros eight.
   Each cluster gets a convex proxy: the upper concave hull of every
   member's extent (sampled cross-sections at their offsets and tilts), with
   a 4 % margin, reduced to at most eight rings.
3. **Detail.** By the cluster's size on screen at its nearest point: marched
   from 48 px, an impostor from 6 px, nothing below (the vessel's far point
   carries it). Attitude jets are impostors beyond 20 m. Low draws only
   impostors; Off draws nothing.
4. **The march** (`OrbitRender/Passes/PlumePass.swift`, `Shaders/PlumeShaders`),
   at R6's half resolution into the volumes layer: one instanced draw of
   every proxy's back faces; each fragment intersects its ray with the
   proxy analytically (the slab between its end rings and one cone per
   edge: `PlumeCluster.interval` is the Swift mirror), clamps it at the
   scene, and marches 16/32/48 steps (Medium/High/Ultra), half of them in
   the near field (ten exit diameters), jittered by interleaved gradient
   noise, Hillaire's energy-conserving step, stopping under 1 %
   transmittance. The field is `PlumeMember.sample`, line by line, plus
   the turbulence. `PlumeRenderTests` checks the GPU against the CPU
   reference through the same rays (within 5 % on average).
5. **Lighting of the plume:** its own emission (absorption times the
   blackbody at each phase's temperature); single scattering of the Sun
   (Henyey-Greenstein, R4's shadow at four points, C2's cloud shadow, the
   Sun's chord through the plume as self-shadowing); the ambient behind
   one function, `plume_ambient` (A2's sky irradiance in air, the earthshine
   stand-in in vacuum, until R3's SH9); the cluster's own light on its
   smoke outside the luminous column.
6. **Air and clouds:** A2's froxels at the plume's light-weighted depth dim
   it and add their light (L·T + a·S). C2's clouds: the march keeps a
   second accumulation dimmed by the cloud layer's opacity from its entry
   on; when the plume's front lies before the clouds' it is composited over
   them carrying that dimming, else the clouds lie over it.
7. **Impostors** (small plumes): camera-facing strips along each member,
   coloured at ten stations by the reference march through the axis (lit
   by the Sun and the ambient), premultiplied over the scene, hazed.
8. **Plume lights** (`OrbitScene/Look/PlumeLights.swift`): one line light
   per cluster that glows (kerosene, solids), from the exits to where
   nine-tenths of its light is reached; its intensity is the members'
   side-on luminance times their width, summed. P2 writes them into the
   lighting uniforms in P0; R2's vessel pass shades the vehicle, the pad
   and the deck with them.
9. **The SPS extension's glow** (`NozzleGlow`): the SPS's drawn bell drawn
   again, emissive, added over the vessel pass.

## The look by family

| Item | Value | Source, grade |
|---|---|---|
| Kerosene soot, optical depth across the exit at rated flow | 8 × soot index | L: the opaque yellow flame of S68-56050, S69-39961 |
| Soot albedo | 0.25 | L, soot aggregates |
| Afterburning flame | 2,300 K, from P1's flame front (0.75 De), fading 28-40 km | P1 (D5-15796-1 §4.1.1) |
| Flame hold | 2 × P1's potential core | L: S68-56050, the F-1 flame above ~1,900 K for 35-40 m at T+10 s |
| Flame brush spread | 0.035 dR/dx from the front | L: the five flames one column within 15-20 m |
| Far-field spread | 0.06 dR/dx beyond the core (or 3 boundary lengths) | L, turbulent jets; S69-39957's billowing plume |
| The film (turbine exhaust) | optical depth 1.5 through 0.15 R, 887 K, to the flame front | P1's film (R-3896-1, M); band L |
| Soot burnt by the flame | to 25 %, from 0.6 of the flame's length | L: the white-grey column below the flame (S68-56050) |
| Kerosene condensate | depth 3 across the exit, albedo 0.8 | L: the white cloud at staging (S69-39957), the white column at liftoff |
| Base recirculation at high n | depth 1.5 over an exit diameter, 1,750-2,000 K, from n ≈ 3 | L: the base glow at altitude |
| Hydrogen and hypergolic gas | depth 0.002 / 0.004 | L: nearly invisible (S69-39958) |
| Their condensate | depth 0.01 / 0.005, albedo 0.95, g 0.6, from 4 / 2 De | L |
| Their near-exit light | (18, 22, 40) / (60, 34, 26) cd/m² over 1.5 De | L, about invisible in daylight |
| Mach disk | P1's distance and radius; 0.85 Tc; emissivity 0.5 soot/alumina, 0.02 hydrogen, 0.05 hypergols; diluted as the free expansion there | L |
| Shock cells | P1's length and count; ±30 % of temperature and density, times P1's structure visibility | L |
| Alumina | depth 80 × alumina mass fraction across the exit; leaves at Te + (Tc − Te)/2; cools by radiation (3 µm, ε 0.3); cone lip + 5°; albedo 0.5 hot, 0.9 cold | L |
| Turbulence | 128³ gradient noise (P3's), two octaves, eddies 0.8 re growing with R, moving downstream at 10 re/s on the turbulence clock; ragged boundary ±; temperature ±5 %; density ±70 % | L |
| Blackbody | per channel exp(c0 + c1/T + c2/T²), fitted to `Photometry.blackbody` | within 6 % in luminance over 1,200-3,500 K |
| SPS extension | 1,480 K at the 6:1 top, T ∝ r^-0.45, ε 0.8, 4 s heating, 12 s cooling | L (AOH: columbium, radiation-cooled) |
| Readable floor | 0.3 E⊙/π near the exit, the family's colour | decision 19 (M1.5) |

## References used (NASA, public domain; viewed, not stored)

- **S68-56050** (Apollo 8 at about T+10 s, sun 7° up): one merged white
  column the width of the S-IC base, blown out for some 35-40 m, orange at
  the nozzles, then a white-grey turbulent column to the pad.
- **6901001** and **S69-39961** (Apollo 11 at liftoff): the flame into the
  deck, the deck and tower lit from below.
- **KSC-69PC-413** (Apollo 11 climbing, deep blue sky): a long luminous
  yellow-orange flame many vehicle lengths, widening, mottled, ragged
  orange edges.
- **S69-39957** (ALOTS, near S-IC cutoff, about 60 km): a huge white
  billowing sunlit plume with a glowing cone at the base.
- **S69-39958** (ALOTS, at separation): the S-II's J-2s nearly invisible,
  only faint lines at the plume's edges.

## Known limits

- The plume looks are calibrated to stills; the far field's mottling is
  frozen turbulence, not a simulation.
- C2's clouds are treated as one sheet at their mean depth for the plume
  inside them.
- Members are evaluated per sample with an early radial reject; the cost
  grows with overlapping members (the five F-1s at altitude).
- The S-IC's plume-induced flow separation (the bright envelope around the
  lower stack at high altitude) is not modelled.
- The SPS glow's temperatures are not sourced (L); the J-2's and the
  hypergols' near-exit light is an estimate.
