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
   F-1s and the S-II's five J-2s are one cluster each, the S-IC retros
   four (their pairs, side by side in their fairings).
   Each cluster gets a convex proxy: the upper concave hull of every
   member's extent (sampled cross-sections at their offsets and tilts, the
   eddies' reach of 15 % beyond the jet included), with a 4 % margin,
   reduced to at most eight rings.
3. **Visibility and detail.** Each member is first trimmed to what can
   show at the frame's exposure (`PlumeLook.trim`; the least light drawn
   is 0.002 pre-exposed): its light near the exit (its own, and the Sun's
   at the phase towards the camera) decides whether it is drawn at all, how
   far out the free expansion's cone is cut, and how long it is. A J-2's,
   the SPS's or an RCS jet's physical plume in vacuum is therefore not
   drawn, at no cost. The trim also finds, at twelve stations along the
   member, how far out it can show (the column across it marched where an
   upper bound says it might, half the least light or 2 % opacity, 15 %
   spare): the proxy holds no more. Without it a strongly underexpanded
   jet's proxy (a retro's at 65 km, P1's boundary some 27 m out) is many
   times its visible alumina cone. The Sun counted is the member's
   vessel's sunlight, so in the Earth's shadow only the glow can show. Then by the cluster's size
   on screen at its nearest point: marched from 48 px, an impostor from
   6 px, nothing below (the vessel's far point carries it). A plume only
   its glow shows (readable in vacuum, or in the Earth's shadow; not one
   with an opaque film band, as the legacy kerosene look's) is marched too
   when it is that large, so that it lies in R6's volumes layer with the
   clouds and keeps its form seen end on: with its proxy held to the glow
   (1.15 R), at a quarter of the steps for one member (equiangular) and
   half for several. Solid motors' clusters, small dense cores the
   equiangular steps resolve, march at half the steps (at least 16). Attitude jets are impostors beyond 20 m. Low draws only
   impostors; Off, or `enabled: false`, nothing. The looks, trims and light
   profiles are kept across frames, keyed on their inputs to 0.25 % (flow,
   the air) and 1 % (the exposure, the Sun). Beyond where a cluster's
   plumes have run together (a member's jet as wide as the furthest
   member's offset) one merged member stands for them: the member of the
   most flow, its radius widened by their RMS offset, its density times
   the members' flow over its own (N when alike), so a centre engine
   shutting down neither carries nor empties it.
4. **The march** (`OrbitRender/Passes/PlumePass.swift`, `Shaders/PlumeShaders`),
   at R6's half resolution into the volumes layer: one instanced draw of
   every proxy's back faces; each fragment intersects its ray with the
   proxy analytically (the slab between its end rings and one cone per
   edge: `PlumeCluster.interval` is the Swift mirror), clamps it at the
   scene, and marches 16/32/48 steps (Medium/High/Ultra), half of them in
   the near field (ten exit diameters), jittered by interleaved gradient
   noise, Hillaire's energy-conserving step, stopping under 2 %
   transmittance. A cluster seen more than 30° off its axis is stepped
   equiangularly about its axis instead (Kulla and Fajardo 2012: the steps
   as dense as 1/(h² + d²) along the ray, h the ray's closest approach or
   half the members' spread about the axis and their dense radius), so a
   small dense core (a retro's alumina, or a pair of them) is not stepped
   over. The marched clusters blend far to
   near. The field is `PlumeMember.sample`, line by line, plus the
   turbulence. `PlumeRenderTests` checks the GPU against the CPU reference
   through the same rays (within 1 % on average; the test allows 10 %).
5. **Lighting of the plume:** its own emission (absorption times the
   blackbody at each phase's temperature); single scattering of the Sun
   (Henyey-Greenstein, R4's shadow at four points, C2's cloud shadow, the
   Sun's chord through the plume as self-shadowing); the ambient behind
   one function, `plume_sh9InScatter`: R3's probe's SH9 in-scatter
   (`orbit_sh9InScatter`, the Earth and the sky the probe draws, in air
   and in vacuum alike) while the probe is drawn, else a fallback (A2's
   sky irradiance with the camera below the air's top, the earthshine
   stand-in above it); the cluster's own light on its smoke outside the
   luminous column. The impostors carry each station's response to the
   ambient and add the same in-scatter in their fragment, so they light as
   the march does.
6. **Air and clouds:** A2's froxels at the plume's light-weighted depth dim
   it and add their light (L·T + a·S). C2's layer and depth codes are read
   texel for texel where they are the march's size, else the nearest of
   the four depth codes (never filtered across the no-depth code). C2's clouds: the march keeps a
   second accumulation dimmed by the cloud layer's opacity from its entry
   on; when the plume's front lies before the clouds' it is composited over
   them carrying that dimming, else the clouds lie over it.
7. **Impostors** (small plumes): camera-facing strips along each member,
   coloured at ten stations by the reference march through the axis from
   the camera's side (lit by the Sun at the view ray's phase and the
   ambient as the march takes it, stepped equiangularly), and M1.5's disc
   over the exit carrying the plume seen end on, as wide as the jet near
   its exit (two exit radii at most), weighed in from about 35° off the
   axis; premultiplied over the scene, hazed. `PlumeRenderTests` checks
   the stations against the reference along the camera's own ray, the Sun
   ahead and behind.
8. **Plume lights** (`OrbitScene/Look/PlumeLights.swift`): one line light
   per cluster that glows (kerosene, solids), from the exits to where
   nine-tenths of its light is reached; its intensity is the members'
   side-on luminance times their width, summed (the members' bins summed
   on one grid along the axis, the end found within the cell that crosses
   it, so that it moves smoothly). P2 writes them into the lighting uniforms in P0,
   with lightCount.y = 1 to say it ran (the vessel pass then takes them
   however many, and builds its own only without P2); R2's vessel pass
   shades the vehicle, the pad and the deck with them, each segment clipped
   to the receiving surface's horizon (Karis 2013), so the jet below the
   deck lights it from the part above.
9. **The SPS extension's glow** (`NozzleGlow`): the SPS's drawn bell drawn
   again, emissive, added over the vessel pass.

## The look by family

| Item | Value | Source, grade |
|---|---|---|
| Kerosene soot, optical depth across the exit at rated flow | 8 × soot index | L: the opaque yellow flame of S68-56050, S69-39961 |
| Soot albedo | 0.25 | L, soot aggregates |
| Afterburning flame | 2,300 K, from P1's flame front (0.75 De) to P1's flame length, beyond it Ta + (Tf − Ta) L_f/x (the mixture fraction's 1/x); fading 28-40 km | P1 (D5-15796-1 §4.1.1) |
| Flame length | P1's: Delichatsios's jet flame into still air, L_f = L* Dj √(ρj/ρa)/f_s on the fully expanded jet, L* about 23 (momentum-dominated: Fr 96 at the pad, 28 at 40 km), f_s the stoichiometric mixture fraction of CEA's exhaust (its CO and H2, diluted by its CO2, H2O and N2: 0.426 for the F-1): 51.5 m at the pad, 105 m at 13 km, 381 m at 30 km | M (Delichatsios 1993, as Turns and arXiv:2008.12209 Table 6 quote it; docs/exhaust-datasheet.md §3) |
| Flame brush spread | 0.035 dR/dx from the front | L: the five flames one column within 15-20 m |
| Far-field spread | 0.06 dR/dx beyond the core (or 3 boundary lengths) | L, turbulent jets; S69-39957's billowing plume |
| The film (turbine exhaust) | optical depth 1.5 through 0.15 R, 887 K, to the flame front | P1's film (R-3896-1, M); band L |
| Soot burnt by the flame | to 25 % by the flame's tip, from 2/3 of its length, as much as the flame burns | the tip: Delichatsios's length is the visible flame's; 25 % L: the white-grey column below the flame (S68-56050) |
| Kerosene condensate | depth 3 across the exit, albedo 0.8; from 3 De in the free expansion, beyond the flame's tip (the core as the afterburning fades) in dense air | L: the white cloud at staging (S69-39957), the white column at liftoff; the onset P1's |
| Base recirculation at high n | depth 1.5 over an exit diameter, 1,750-2,000 K, from n ≈ 3 | L: the base glow at altitude |
| Hydrogen and hypergolic gas | depth 0.002 / 0.004 | L: nearly invisible (S69-39958) |
| Their condensate | depth 0.01 / 0.005, albedo 0.95, g 0.6, from 4 / 2 De | L |
| Their near-exit light | (2, 2.4, 4.4) / (6, 3.4, 2.6) cd/m² over 1.5 De | L: invisible in daylight, under the SPS glow at night |
| Mach disk | P1's distance and radius; 0.85 Tc; emissivity 0.5 soot/alumina, 0.02 hydrogen, 0.05 hypergols; diluted as the free expansion there; faded in from n 2 to 3 | L |
| Shock cells | P1's length and count; ±30 % of temperature and density, times P1's structure visibility; faded in from n 0.30 to 0.36 and out from 4 to 5 (P1's bounds) | L |
| Alumina | extinction 3 Q Y ρe/(2 ρp d): Q 2 (particles much larger than the light's wavelength), Y the alumina's mass fraction, ρe P1's exit density, ρp 3,950 kg/m³, d 3 µm (3.0 across the S-IC retro's exit, 1.5 across the TJM's); leaves at Te + (Tc − Te)/2; cools by radiation (ε 0.3); cone lip + 5°; albedo 0.5 hot, 0.9 cold | H the optics and density, P1 the exit; L the diameter, the lag, ε, the albedos |
| Turbulence | 128³ gradient noise (P3's), two octaves, eddies 0.8 re growing with R, moving downstream at 10 re/s on the turbulence clock; ragged boundary, outwards within 15 % (the proxy's reach); temperature ±5 %; density ±70 %; faded out where the eddies are under 1.5-4 half-resolution texels | L |
| Blackbody | per channel exp(c0 + c1/T + c2/T²), fitted to `Photometry.blackbody` | within 6 % in luminance over 1,200-3,500 K |
| SPS extension | 1,480 K at the 6:1 top, T ∝ r^-0.45, ε 0.8, 4 s heating, 12 s cooling | L (AOH: columbium, radiation-cooled) |
| Readable floor | 0.3 E⊙/π near the exit, the family's colour, times the flow fraction (at most 1), over M1.5's length times 0.5 + 0.5 of it; B in the app | decision 19 (M1.5) |

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

## The flame as the air thins

Two things happen at once, both P1's. The flame lengthens as √(ρj/ρa)
(Delichatsios: the jet's momentum carries the exhaust further before it
has entrained enough air to burn), and from 28 to 40 km the afterburning
fades (D5-15796-1's films: luminous to 25-28 km, greying from 28 to 40,
grey above). The look takes the length from the first and the strength
from the second: the flame's temperature excess over the jet's, and how
much of its soot it burns, both scale with `afterburning`. So above 28 km
the flame grows longer while it dims and greys (its soot unburnt, cooler),
and at 40 km it is gone, leaving the inert jet; nowhere is a several
hundred metre flame at full brightness where the films show grey.

The correlation is for a jet into still air. The vehicle's airspeed is a
coflow (u∞/uj near 0.2 at max-Q) that cuts the entrainment and lengthens a
jet flame; it is left out here, with the plume turning into the relative
wind, for the airflow follow-up.

## The photographs as checks

The look comes from P1's physics where P1 has it; the photographs check
it, they do not set it.

- **The F-1's flame at the pad.** P1's flame is 51.5 m; the axis stays
  above about 1,900 K (blown out white against sunlit paint) for 64 m.
  S68-56050 (Apollo 8 at about T+10 s) shows some 35-40 m blown out: the
  model's flame is about 1.6 times the photograph's. The photograph is a
  visual estimate of a moving vehicle with the column partly hidden; the
  correlation's constant (23) is for momentum-dominated flames whose
  visible length it was fitted to.
- **Widening with altitude** (KSC-69PC-413): the flame lengthens as
  √(ρj/ρa), 105 m at 13 km and 381 m at 30 km, and widens with P1's
  boundary; the photograph's cone near 13 km is still wider than ours.
- **The white column below the flame** (S68-56050) and **the cloud at
  staging** (S69-39957): the condensate's depth and albedo (L).
- **The J-2 nearly invisible** (S69-39958): P1's clear exhaust and the
  exposure's trim.

## Constants still L, and why

- **Soot** (depth 8 per soot index, albedo 0.25), **the film's band**
  (depth 1.5 through 0.15 R): P1 gives the film's share of the flow and
  its temperature, not the soot yield or the band's optical depth; no
  source in hand measures the F-1's soot.
- **The flame brush's spread** (0.035) and **the far field's** (0.06):
  P1 has no mixing layer's growth. A compressible shear layer's
  (Papamoschou and Roshko 1988, normalised by the convective Mach
  number) and a round jet's spreading rate would replace them; that, and
  the plume turning into the relative wind, is the follow-up after this
  PR (Franz's B).
- **The soot left burnt** (25 %), **the kerosene condensate** (depth 3,
  albedo 0.8), **the clear exhausts' condensate and gas depths**, **their
  near-exit light**: no measured column densities.
- **The base glow** (depth 1.5, 1,750-2,000 K), **the shock cells'
  strength** (±30 %), **the Mach disk's emissivity**, **the turbulence**:
  visual.
- **The phase functions' g**, **the alumina's diameter** (3 µm), **its
  thermal lag and emissivity**: particle optics without a measured size
  distribution for these motors.
- **The SPS extension's temperatures** and its heating and cooling times:
  no source in hand.

## Cost

`PlumeCostTests` (`docs/look/shots/p2-cost.json`; `ORBITSIM_TIMINGS=1`):
plumes on and off on alternate frames, the difference of the medians, at
3024×1964 on the M3 Pro. Measured on 5a0f84f at High (32 steps); the
plan's budget is 1.5 ms on the pad and 0.5 ms in LEO, for the default
physical look.

- Pad 0.84-1.11 ms; ascent (T+30 s) 1.66 ms; max-Q 2.24 ms. The ascent
  and max-Q overrun is accepted: there the plume fills much of the frame,
  and P1's flame is long (105 m at 13 km). Medium (16 steps) is the lever
  R7's tiers have.
- Staging (0.3 s after S-IC/S-II separation: the eight S-IC retros in
  four pairs and the four S-II ullage motors, eight clusters): 2.68 ms.
  It was 38 ms with each proxy as wide as P1's jet boundary; the proxies
  now hold what can show, and solid motors' clusters march at half the
  steps. The retros burn 0.64 s. The first frame of the burn builds the
  looks (3 ms of CPU), kept after.
- LEO, physical: 0.01-0.03 ms by day (the J-2s and the SPS culled by the
  exposure, the SPS bell's glow drawn), the same in forward scatter; the
  SPS at night in eclipse 0.42 ms (glow-only, marched at a quarter of the
  steps, its proxy held to the glow).
- Readable plumes at High: 1.2-1.7 ms in LEO when large (opt-in). They
  are marched, so that they lie in R6's volumes layer with C2's clouds and
  keep their form seen end on; R7's tiers may bring back impostors at Low,
  where every cluster is drawn as one (0.05-0.10 ms in LEO).
- CPU: P2's planning and lighting take 0.02-0.10 ms a frame with its
  caches warm; 1.5 ms on the first frame at the pad and 3 ms at staging
  (every look and its visible extents built).

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
- The tower jettison motor's plume is one member on its thrust axis, not
  two at its canted scarfed nozzles: the drawn nozzles are a placeholder
  not linked to the thruster (VG3's open item, exhaust datasheet §7.5).
- The plume does not yet turn into the relative wind (angle of attack,
  crosswinds, the pitch program) or hand over to P4's trail at rest in
  the air: the follow-up PR after this one.
- Small impostors still draw before R6's composite (C2's clouds lie over
  them); the large ones are marched.
