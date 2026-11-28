# The launch on the pad (M1.6 launch sequence)

How LC-39A and P4's launch effects follow the live terminal count, and how
the ground cloud is sized from its physics. The count itself, the hold-down
and the launch window are the core's (`docs/AS506-datasheet.md` §18). Grades
as in the datasheets: H high, M medium, L low.

## The pad runs on the count

- The pad scenarios (`as506-pad`, `apollo8-pad`, the Earth-orbit return,
  Apollo 13, the engine-out) open running in a hold of the count at T−35 s,
  the F-1s off. Space resumes it (`Simulation.stage`); the pilot decides
  when to launch. Apollo 7's deorbit opens running too. No scenario opens
  paused.
- `Scenario.firstMotion` keeps the stack placed at first motion with the
  F-1s at full thrust (`as506-first-motion`, `apollo8-first-motion`, not in
  the app's list): the other tracks' tests and shot specs that drew the
  firing stack at first motion use them, unchanged. Their count is
  released at the historic 0.30 s (`VesselLibrary.releasedCount`) and drives
  nothing.
- The scene carries the count (`RenderScene.launch`, a
  `TerminalCount.Record`) and LC-39A's countdown on it
  (`RenderScene.Site.countdown`, `LC39A.Countdown(_:at:)`): the arms'
  timings of the historic launch nearest the planned range zero, with the
  count's own range zero (while it holds, range time stands at the hold),
  release, first motion and liftoff switches. The vessel and shadow passes
  place the moving elements on it.

**What was broken.** The site's moving elements were placed on a historic
countdown, the launch nearest the epoch (`LaunchCountdown.nearest`), and the
scenarios opened paused at first motion. So the preflight arms (1 and 2)
and the hold-down links were only ever seen already retracted or released,
and any launch off the historic second would have moved them at the
historic times: a count held or resumed late would have shown arms 1 and 2
swinging, the hold-down links releasing and the in-flight arms and tail
service masts retracting while the stack still stood, or long after. The
app's frames themselves did place the elements each frame (flown in the app
on main and on this branch, scratch harness): nothing else was wrong with
the drawing. Now the elements move on the count: arm 1 from its T−30 s
command, arm 2 from T−16.2 s, the hold-down links at the release, the
in-flight arms and the masts at the liftoff switches the count finds (0.20
s after the release, the controlled release's rise, against the 0.16 s
estimated before). The count finds them, and first motion, at the end of the
step that crossed them, so a frame's record holds what its last step did;
until it has, the countdown has them infinitely far, never at the historic
estimate (which is earlier: an umbilical burst there would come twice).

**A scrub.** An engine lost before T−0 scrubs the launch: nothing more
moves, and the pad's exhaust effects run their windows from the cutoff
instead of first motion, so the clouds stop being integrated and filled 480
s after it (and a reset later rebuilds nothing). The stack stands loaded, so
its LOX tank's fog and the umbilicals' trickle stream on, as in a hold. An
engine lost before its start command never starts: no smoke, no flash from
it; one lost after its command smokes until it stopped. The count records a
loss at the step's start whoever made it, the IU's failures (F+digit, a
script's `fail`) too, which it applies after the count's update
(`TerminalCount.programmed`).

**Left on the rods.** An engine lost after commit does not stop the
release, and the rest may not lift the stack against its weight and the
rods' 3.2 MN (four F-1s do after about 39 s, three after about 140 s, two
after about 340 s; one alone never). While it stands released, the count
records each F-1 that stops burning there at the step's start, as the
journal records its cutoff: lost, run dry, or shut down by the throttle (the
pilot's X, a script's `throttle:0`; `TerminalCount.programmed`, after the
throttles). The record keeps it stopped if the throttle lights it again, as
an F-1 could not restart. The trench and the clouds are fed what burns: the
count's thrust up to the release, the emitters' flow after it (on a rebuilt
history the journal's cutoffs, none from an engine lost by the release), so
a throttle cut leaves only the F-1s' 0.66 s tail-off. The pad's windows stay
open while an F-1 burns on the rods, and run from where the last stopped
once none does, until first motion is found.

## Effects on the core's thrust

- Before first motion each F-1's thrust is the count's (`TerminalCount`):
  the plumes read it through the thrusters (P2's volumes only through
  thruster levels), and P4 through the scene's record
  (`LaunchEffects.Ignition`) up to the release (the emitters' after it, on
  the rods too), which also rebuilds a history the frames did not see. The 1-2-2 start shows: engine 5 lights at T−3.05 s, 1 and 3 at
  −2.75 s, 4 at −2.65 s, 2 at −2.55 s (FER-506 Table 2-2 and Figure 5-2).
- **Start smoke** (`LaunchEffects.startSmoke`): from each engine's start
  command its gas generator's fuel-rich turbine exhaust, 2.9 % of its
  rated flow at 887 K (`ApolloExhaust.f1`'s film, R-3896-1: M), leaves the
  nozzle before the chamber lights. It falls into the trench and leaves it
  hot, half up through the ML's opening around the vehicle (a chimney:
  √(g h ΔT/T)), half out of the trench's exits (the split L). Its soot,
  2 % of the gas (L), at 7.5 m²/g makes it optically thick (about 140
  across a 3 m eddy). Dark kerosene smoke rising round the base from T−6.4
  s.
- **Ignition flash** (`LaunchEffects.ignitionFlashes`): at each engine's
  ignition the TEA-TEB igniter burns with the LOX, its boron green (BO₂'s
  bands about 545 nm), for a fraction of a second: a held flash of 16
  emissive puffs at the nozzle exit, from the count's ignition epochs.
  Above 10× a flash is held into the frame after it ended (P3's rule), so it
  is requested up to a frame's interval past its life. Brightness and
  duration are L.
- The LOX tank's fog and the umbilicals' trickle stream while the count
  holds, as they did on the pad.

## The trail (`ExhaustTrail`, `TrailChain`, `TrailColumn`, `TrailPass`)

The S-IC's exhaust left in the air below 40 km, carrying on P2's far field
where the plume hands it over (look round 2, LR5): a column of Gaussian
nodes, each closed form in its age, drawn as Gaussian media (the smoke
media above) in R6's volumes layer. PR1's puffs are retired.

- **The column handed over** (`PlumeAirflow.Column`, `trailHandover`): the
  cluster's merged far field at the hand-over, as P2's march has it there
  (beyond 1.15 of its merge), unfaded and without its turbulence, projected
  side-on: τ through the axis, the cross-section C = ∫ τ dy, its soot's and
  its scattering's shares, P2's g; and λ = ṁ/V_air, the F-1s' flow over
  the airspeed (at least 1 m/s). Held to a march across P2's own field
  within 3 % (`ExhaustTrailTests`); a Gaussian line with its τ and C is as
  wide at half its depth as the field within 15 % (12 % narrower at T+120
  s, where P2's field is flatter than a Gaussian).
- **The path:** `ExhaustTrail` follows the window's start, x − w along P2's
  axis, between frames as the cubic through both frames' positions and
  velocities, after a reset as the rebuilt climb; `TrailChain` lays the
  nodes along it. So a frame, a rebuild and any warp lay the same nodes at
  the same epochs.
- **The nodes** (`TrailChain.lay`): one every 25 m of the jet at the joint.
  The jet still runs u over the air there (148 m/s over 37 m/s at T+15 s),
  so that is every 25 V/(V + u) m of the path through the air (the ground
  chord less the wind's drift); as the jet slows they close up, as the
  exhaust does. Each carries P2's column over 25 m, the jet's top-hat state
  and its heat (λ times the exhaust's heat less what the flames radiate),
  and the air at its height: N from the sounding's lapse, the wind's shear
  across the path, the mixed layer's top (1 km, w* 1.5 m/s: L, a July
  morning on the coast). Its hand-over is the frame's within 500 m of the
  vehicle's height, else the model's (`ExhaustTrail.modelHead`, in 250 m
  bins): the F-1s as the scene gives them, each at its own flow from
  `LaunchEffects.engineCutoffs` (the journal's cutoffs, and any engine the
  count lost by the release). Nodes are laid above the deck, below 40 km,
  and live 600 s.
- **A node in its age** (`TrailColumn.Node`), closed form:
  - *coflow:* the jet's half-width and drift as it slows to the air,
    re-derived from `JetPath`'s shear-layer entrainment (held to
    `JetPath.path` within 0.002 %);
  - *line thermal:* the bent-over line thermal (Briggs: z³ = 3B(1 −
    cos Nt)/(πβ²N²), β 0.6, held past Nt = π; within 1-2 % of Briggs's
    neutral and stable rises), its buoyancy and stratification across the
    line only, B cos θ and N cos θ for a line climbing at θ (along a uniform
    column buoyancy drives a flow that shows nowhere: standing upright a
    line does not rise along itself);
  - *spread:* below the mixed layer's top K = κw*z(1 − z/z_i)² (Troen and
    Mahrt 1986), above it Schumann's (2012) plume diffusivities in the
    wind's shear (Konopka's sheared covariance, closed form; to 1e-6 of a
    thousand small steps), on top of the coflow's growth and the thermal's
    entrainment;
  - *its fade:* linear in how far it is behind the window's start: U a +
    ½ A a² + its drift, A the airspeed's rate where laid.
- **Drawn** (`TrailChain.anchorMedia`): each node a Gaussian medium, σ 15 m
  along the path (0.6 of the spacing: a line of them smooth to 0.2 %) at
  every age, its cross-section's covariance across, its extinction its
  column times 25 m; with its line's peak, C/(2π σv σw), for the shadows.
  Young nodes in a frame with a live hand-over fade by where their centre
  is in P2's window along P2's axis (exact whatever the vehicle's turning,
  climbing or speeding up does to the window), older ones by their age.
- **The joint:** P2 fades out as the complement of the line the nodes
  draw: a linear ramp over the window seen through their σ along it, R =
  (g(x − a) − g(x − b))/(b − a), g(z) = z Φ(z/σ) + σ φ(z/σ)
  (`PlumeAirflow.trailFade`), to 2.5σ past the window's end (2e-3 σ/2w of
  it left). For that to lie within the plume as built, the hand-over's x is
  at most (built − 2.5σ)/1.15: some 30 m nearer the vehicle from T+3 to
  75 s. Side-on along the axis (`TrailChainTests.testJointsFadesSumToOneSideOn`),
  P2's 1 − R and the trail's realised weight sum to one within 4.9 % at
  T+15 s (a 40 m window), 2.1 % at 30 s, 1.1 % at 60 s and 0.27 % at 120 s:
  what is left is σ² f′ τ′/τ, the nodes widening across a short window. The
  trail's column at the window's middle is 0.87-0.96 of P2's there: P2's
  far field spreads faster than the coflow (see below).
- **Level of detail** (`TrailChain.lod`): runs of nodes, a power of two
  aligned on their serials, are drawn as one Gaussian (their extinction,
  centre, cross covariance with their centres' scatter, albedo and
  asymmetry by extinction and scattering), split in halves until even the
  most demanding member allows the run: no longer than 0.25 of its distance
  (a ray down the trail crosses four runs a doubling of the distance, at
  most 40 in all from 100 m to 30 km) and, seen across the view, no longer
  than two of the trail's widths (side-on, nothing is merged that shows),
  at most 256 nodes. A run's σ along is 0.6 of the span allowed at its
  centre, which changes smoothly where the runs double (a σ doubling from
  one run to the next bumps the line ±16 %): side-on the merged line is the
  nodes' within 0.6 %.
- **`TrailPass`** (`TrailEffect`, TrailShaders): each medium an instanced
  3σ box, back faces only, its chord shaded in closed form through the
  header's segments, each segment's source at its shading depth (one
  inverse each for its end and its source); lit by the Sun through the
  trail's line at the point (the column's own chord, its neighbours'
  included), C2's cloud shadow and the ambient (R3's SH9, or the stand-in);
  A2's air in front. The media come far to near; two effects draw them
  about P2's march, those beyond the joint before it and the rest after
  (R6's volumes layer composites over, so its effects must be ordered).
  Back codes for LR0's reconstruction. The media come from the effects'
  director, which runs with the particles: at their Off tier there is no
  trail.
- **Rebuilds and warp:** the nodes at T+75 s from frames at 2 Hz, from
  1000× warp's frames and rebuilt agree in count within 3 % and in
  extinction per 2 km of height within 8 %; after an engine out the
  rebuild lays the frames' extinction per kilometre within 6 %, and an F-1
  lost before the release leaves the model's column 0.80 of five engines'.
- **Along AS-506's flight** the column goes from depth 1.9 and 36 m wide
  (T+3 s) through 1.2 and 56 m (T+60 s) to 0.37 and 219 m (T+120 s); its
  albedo is 0.58 (P2's soot at 0.25 and its condensate at 0.8) until the
  afterburning fades.
- **Looks** (`TrailLookTests`): in `p4-trail-chase` the line nowhere
  narrows below 0.963 of its widest before (the puffs narrowed to 0.43 of
  the plume); `p4-trail-tube` (a studio tube) has no beads (0.5 % about its
  smooth trend); `p4-trail-joint-studio` (P2's F-1 cluster at 6 km and the
  chain it hands over to, `TrailStudio`) changes width by at most 6 % a
  station through the joint.
- **What P2's column does not hold:** it keeps its cross-section from the
  exit to the hand-over (σ ∝ (r_e/r)²), while the exhaust slows from the
  jet's 2.6 km/s to the air, so λ grows by u_j/V_air: about 10 at T+60 s.
  Its soot then implies 0.008 % of the exhaust at T+60 s (at 7.5 m²/g),
  where at its exit it is 0.39 %, 0.096 % past the afterburning. The
  trail keeps continuity with P2's column; extinction from mass (λ for P2
  and the trail together) is a follow-up.

## The ground cloud (`GroundCloud`)

The F-1s' exhaust and the pad's water, the flame deflector's two jets out of
the trench, the deck's wall jet once the plume outgrows the ML's opening,
and the buoyant cloud each feeds:

| item | value | source | grade |
|---|---|---|---|
| exhaust heat | 11.7 MJ/kg: c_p (T_c − T_a) at 3,616 K (c_p from the exit's γ 1.233 and 23.04 g/mol) and the afterburning of its CO (34.6 %) and H2 (10.3 %) | CEA row F-1 | H (the run) |
| radiated by the sooty flames | 25 % | a kerosene pool fire's 20-35 % | L |
| water | the trench's 28,000 gpm while the exhaust reaches it; the deck's 50,000 then 20,000 gpm in the deck's share; boiled as far as the heat goes | P4's (LC39A datasheet §12, A11PK) | M |
| buoyancy flux at full thrust | about 3.1 × 10⁶ m⁴/s³ (g Q / (ρ c_p T)) | derived | — |
| deflector | each face 46° (12 m over 11.5 m); an inviscid jet keeps sin θ cos θ, half its momentum, on each side | LC39A datasheet §8 (MOON) | L |
| jets | round momentum jets from the deflector: u = 7.0 √(M/ρ)/x, b = 0.107 x, Q = 0.25 √(M/ρ) x; at the exits (68.6 m) about 270 m/s and 7.3 m in half-width, the trench's own size | Fischer et al. 1979, Table 9.1 | H (the law) |
| jet front | half the centreline speed (a starting jet) | Turner 1962 | M |
| runout | 3 jet lengths l_M = (M/ρ)^¾ / F^½ (about 280 m beyond the exits) before buoyancy lifts the jet | a wall jet's lift-off | L |
| deck | the plume striking the deck turned radial with all its momentum | a jet on a plate, inviscid | M |
| clouds | Morton-Taylor-Turner thermals, α 0.25, fed at their jets' ends with the jets' volume and buoyancy, on the launch day's sounding (its stability N² and winds) | MTT 1956 | M |

Plausibility, not a fit (`GroundCloudTests`): the jets 250 m beyond the exits
by T+5 s; the clouds past the tower within seconds; at 15 s the cloud
960 m across (Apollo 16: 750 m), at 30 s 1.07 km (Apollo 10 and 16: 1.2-1.3
km) with its top at 0.68 km (Apollo 16's south lobe: 0.5 km), at 60 s
1.06 km (1 km), at 180 s 1.95 km (2.1 km, stabilising near 2 km)
(TM X-2935 Figs. 3 and 4; CR-61326 Fig. E-9). Nothing in the model was
adjusted to them.

**Filling them.** P3's particles are parcels that entrain and drag on their
own; a crowd of small ones would rise as small thermals, far slower than
the one cloud they make. So the particles are eddies riding the flows'
similarity solutions (`LaunchMaterials.eddy`): an eddy of a share s of the
flow's radius grows by s α per metre through the air and drags with
C_d = (8/3) s α, which makes P3's drag, (3 C_d / 8)(ρ_a/ρ_p) u²/r, the
flow's own deceleration (u ∝ 1/x for a jet or a thermal at the air's
density; a hot, light one faster, as a light jet's near field is).

- The jets' eddies (`p4 pad exhaust`) are born at the exits with the jet's
  speed, 0.7 of its half-width, and the temperature its heat gives the
  volume it carries (the trench's and the deck's alike: the heat their
  clouds get, once their water has boiled); as many as fill 30 % of that
  volume (L, the look's density). Their optical depth is the exhaust's soot
  and water across an eddy at full thrust, about 130.
- The clouds' eddies (`p4 ground cloud`) are born inside the thermals,
  a fifth of their radius, with the cloud's rise and the wind and its
  growth, living 20-32 s; as many as keep 3 × its volume covered (L) while
  the water and soot it carries (the exhaust's 0.34 kg of water a kilogram,
  the boiled deluge, 0.5 % soot: L) hide what is behind, fewer after. A
  stem of eddies rises from each jet's end into its cloud while it is fed.
  Their albedo is their water's and soot's, 0.72.
- The clouds' eddies are born moving with their lobe: placed back along its
  motion by their ages (`sourceVelocity`), nothing added on.
- A rebuilt history (a snapshot, a reset) integrates the clouds from the
  first start command on the same 0.05 s grid and fills each slice from the
  lobe as it was then (`GroundCloud.state(at:)`, its 0.5 s samples): its
  centre carried on to now along its motion then, its radius, eddies and
  rise; so frames and rebuilds agree (`LaunchSequenceSceneTests`: the eddies'
  mean size within 10 %).
- A rebuilt climb off the pad is `LiftoffRise`'s, with the live count's
  controlled release in closed form over its stroke (the first-motion stands
  have none): what it puts the live climb behind the stands' is the core's
  within 5 % (0.7, 1.9 and 4.0 m at 2, 5 and 10 s after first motion).

Seeds: every request takes a fresh seed from its key and the producer's
running serial (`LaunchEffects.nextSeed`, `ParticleRandom`), and the
continuous emitters' counts carry their fractions, so neither the emission
nor the noise repeats; the eddies' ages are stratified within each slice,
their positions and radii drawn per particle.

## Smoke media (`GaussianMedium`, `SmokeScattering`)

Look round 2's shared smoke (track LR5's header): the trail (LR5), the
launch cloud (LR4) and the plumes' far field (LR3) take their primitives
and their light from it. `OrbitScene/Effects/GaussianMedium.swift` is the
reference; the shader header `GaussianMediumCommon` (`.gaussianMedium`,
after `.sphericalHarmonics`) mirrors it line for line.

- **The primitive** is a 3-D Gaussian of extinction, σ0 = κ M / ((2π)^1.5
  σu σv σw) from its mass, cut off at its 3σ box (99.19 % of the mass).
  Along a ray it is a 1-D Gaussian, so its optical depth over any segment is
  closed form, erf by Abramowitz and Stegun 7.1.26 (|ε| ≤ 1.5e-7; MSL has
  no erf), and so is its inverse (Giles's erfinv, two Newton steps).
- **Its light:** a chord is shaded in segments 0.25 deep from its entry,
  at most 16; past depth 3.75 the first 12 stay 0.25 deep and the last 4
  split the rest evenly (`segments`, `segmentBoundary`, the boundaries by
  `time(atDepth:)`), since light from behind leaves every depth about
  alike. Each segment has one source (Condor et al. 2025) at the depth
  midway between the ones exact for light falling as e^(−τ) from its entry
  (front-lit) and rising as e^(τ) (back-lit); below depth 0.05 their
  mean's series. Against the quadrature of ∫ J σ e^(−τ) dt at line depths
  2 to 100, condensed and sooty:
  - front-lit within 0.5 %;
  - side-lit within 2 % for rays through the centre. A ray 1σ to 1.5σ off
    the centre away from the Sun crosses the shadowed half, where J
    changes within a segment faster than one source follows: up to 9 %
    bright condensed, up to 35 % dark sooty (where it is under a tenth of
    the brightest source), under 3.5 % of the brightest source's either
    way. Any layout of 16 gives the same; J at the boundaries,
    interpolated log-linearly, is worse (5-7 % dark through the centre);
  - back-lit within 1.5 % (condensed at any depth, sooty to depth 6).
    Thicker sooty smoke lit from behind sends only T e^(−T) of its source's
    light, from every depth alike, which the last segments cannot hold:
    its error is under 5e-4 of the brightest source's.

  (One source at the σ-weighted mean was off by 35 % to 2.4× at depth 5.)
- **The source function J** (per unit extinction) has one g for every part
  and C2's two-stream for all the light scattered many times:
  - *the Sun:* its beam enters the chord towards it face-on; the streams
    there, seen in the eye's direction as C2 sees its own, with the direct
    beam's share swapped for its single scattering (Henyey-Greenstein,
    through the optical depth to the Sun);
  - *the ambient:* R3's SH9 as two fluxes along its dominant axis (E/π
    facing each way), each entering the chord along the axis from its own
    side, so a sky lights a column from above and the ground from below as
    C2's `skyDiffuse` lights its decks; the unscattered light the streams
    show, each side's flux times ½ (1 ± cos) of the view on the axis, is
    swapped for SH9's in-scatter by the same phase (Funk and Hecke), shared
    between the sides in that proportion and carried through from each.
    The column along the axis is the primitive's own, scaled by its aspect
    there, min σ over its σ along the axis, where under 1 (`ambientColumn`):
    an elongated body along the axis (the trail climbing) takes its
    skylight through its sides (on its centre line, the chord across it),
    and the scale depends on the body's shape alone, not on the point or
    on which of equal axes is labelled first.
  - At ω = 1 the streams are C2's exactly; an isotropic ambient gives
    J = L at any depth; a thick column's skylit base and top are C2's seen
    from any angle (to 1e-12 where the in-scatter is C2's own blend; 0.571
    and 0.429 at τ 10 and g 0.85, 0.308 and 0.692 at 30, seen straight up
    and down); a thin smoke scatters the Sun and the sky with its phase, as
    P2's does.
- **Absorption** in the streams takes Elsasser's diffusivity 5/3 (the mean
  slant of a diffuse field), the scattering C2's unit one (so ω = 1 stays
  C2's): Meador and Weaver's two-stream of a beam with γ1 = D(1 − ω) + ω b,
  γ2 = ω b, γ3 = b, b = (1 − g)/2, in closed form, its resonance at k = 1
  (ω 0.49 for g 0.35) cancelled analytically. Against a Monte Carlo slab
  lit face-on, its diffuse transmission is within 5 % for P2's kerosene
  smoke (ω 0.58, g 0.35; unit diffusivity was 18 % to 150 % over) and
  26 % for a condensed column (ω 0.93) at τ 1 to 5; its reflectance stays
  up to 41 % high, C2's backscatter being too large for a beam entering
  face-on.
- **Checks** (`GaussianMediumTests`, `GaussianMediumRenderTests`): the depth
  and its inverse against Simpson's rule, the mass back from the depths over
  a plane of rays (2 g of soot at 7.5 m²/g), the box; the streams against
  C2's at ω = 1, their own equations (through the series' switch and the
  resonance), R + T + A = 1, the deep reflectance, the Monte Carlo; the
  ambient's isotropic, thin and thick limits; the chord's segments against
  quadrature; the GPU against the Swift to Float's reach.
  `ShaderModule.gaussianMediumCheck` is in `ShaderModule.all`, so a broken
  header fails the compile tests before it disables the passes that include
  it.

## Shots

`docs/look/shots/launch.json` (scene goldens, report only): the live count at
T−10, T−5, T−0, T+3, T+8 and T+15 s, resumed at once (T−0 at Apollo 11's
range zero), clouds off.
