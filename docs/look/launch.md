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

## The trail (`ExhaustTrail`)

The S-IC's exhaust left in the air below 40 km, carrying on P2's far field
where the plume hands it over (look round 2, LR5 PR1; PR2's `TrailColumn`
replaces the puffs).

- **The column handed over** (`PlumeAirflow.Column`, `trailHandover`): the
  cluster's merged far field at the hand-over, as P2's march has it there
  (beyond 1.15 of its merge), unfaded and without its turbulence, projected
  side-on: τ through the axis, the cross-section C = ∫ τ dy, its soot's and
  its scattering's shares, P2's g; and λ = ṁ/V_air, the F-1s' flow over
  the airspeed (at least 1 m/s). Held to a march across P2's own field
  within 3 % (`ExhaustTrailTests`).
- **The puffs** carry it on: a line of P3's puffs, each (1 − ρ²/R²)² in
  depth, has the column (16/15)(R/s) τ0 (1 − y²/R²)^(5/2); its radius is the
  column's C/((5π/16) τ), its spacing s = (16/15) R τ0/τ at most half a
  radius, τ0 the deepest of a palette's rows (0.1 to 3.2 by factors of two)
  that allows it; its albedo is laid between the palette's two columns
  either side of the column's (0.2 to 0.95). A line's half-maximum width is
  within 10 % of the field's.
- **Stratified:** one lattice of strata, `spacing` long, runs along the
  path from piece to piece; each puff starts in its own stratum where the
  path was at its age (a source velocity along the chord), at rest in the
  air. No step from a puff to the next exceeds 2.6 strata (random places
  along a line, as before, left gaps of five to eight).
- **The fade:** P3's puffs fade in linearly with age, P2's plume out by a
  smoothstep over the window x ± w. The puffs are laid at x − 0.79 w and
  fade in over 1.58 w at the airspeed, the minimax ramp: the two sum to
  one within 3.08 % (3.5 % with the share's 0.5 % steps), the lifetime one
  value (480 s) so that the share is a clock, at most 20 s at the pad.
- **A rebuild** models the column at each piece's height, airspeed and
  flow (`ExhaustTrail.modelColumn`: the F-1s as the scene gives them,
  along their axes in the air there), in 250 m bins: within 5 % of the
  frames' along the flight. A frame at warp does the same away from the
  vehicle.
- **Along AS-506's flight** the column goes from depth 1.9 and 36 m wide
  (T+3 s) through 1.2 and 56 m (T+60 s) to 0.37 and 219 m (T+120 s); its
  albedo is 0.58 (P2's soot at 0.25 and its condensate at 0.8) until the
  afterburning fades.
- **What P2's column does not hold:** it keeps its cross-section from the
  exit to the hand-over (σ ∝ (r_e/r)²), while the exhaust slows from the
  jet's 2.6 km/s to the air, so λ grows by u_j/V_air: about 10 at T+60 s.
  Its soot then implies 0.008 % of the exhaust at T+60 s (at 7.5 m²/g),
  where at its exit it is 0.39 %, 0.096 % past the afterburning (the
  study's "P2's implied 0.07 %" estimated this). PR2's extinction from
  mass takes λ.

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

## Shots

`docs/look/shots/launch.json` (scene goldens, report only): the live count at
T−10, T−5, T−0, T+3, T+8 and T+15 s, resumed at once (T−0 at Apollo 11's
range zero), clouds off.
