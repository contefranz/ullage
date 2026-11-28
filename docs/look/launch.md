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

## The ground cloud (`GroundCloud`)

The F-1s' exhaust and the pad's water, the flame deflector's two jets out of
the trench, the deck's wall jet once the plume outgrows the ML's opening,
and the buoyant cloud each feeds:

| item | value | source | grade |
|---|---|---|---|
| exhaust heat | 11.7 MJ/kg: c_p (T_c − T_a) at 3,616 K (c_p from the exit's γ 1.233 and 23.04 g/mol) and the afterburning of its CO (34.6 %) and H2 (10.3 %) | CEA row F-1 | H (the run) |
| radiated by the sooty flames | 25 % | a kerosene pool fire's 20-35 % | L |
| water | the trench-side nozzles' 8,000 gpm while the exhaust reaches the trench; the deck's 29 nozzles' 50,000 gpm for 30 s from liftoff, then 20,000, in the deck's share; boiled as far as the heat goes. Apollo 16's report gives 8,000 into the trench and 20,000 onto the ML, pad and trench, 28,000 in all (TM X-2935, p. 18), and SA-501's caption 28,000 "to cool the flame deflector and trench": P4 had 28,000 in the trench and 50,000 on the deck, counting the 20,000 twice | AS-506's press kit (NASA 69-83K, pp. 167-168) | H |
| buoyancy flux at full thrust | about 3.1 × 10⁶ m⁴/s³ (g Q / (ρ c_p T)) | derived | — |
| deflector | each face 46° (12 m over 11.5 m); an inviscid jet keeps sin θ cos θ, half its momentum, on each side | LC39A datasheet §8 (MOON) | L |
| jets | round momentum jets from the deflector: u = 7.0 √(M/ρ)/x, b = 0.107 x, Q = 0.25 √(M/ρ) x; at the exits (68.6 m) about 270 m/s and 7.3 m in half-width, the trench's own size | Fischer et al. 1979, Table 9.1 | H (the law) |
| jet front | half the centreline speed (a starting jet) | Turner 1962 | M |
| runout | 3 jet lengths l_M = (M/ρ)^¾ / F^½ (about 280 m beyond the exits) before buoyancy lifts the jet | a wall jet's lift-off | L |
| deck | the plume striking the deck turned radial with all its momentum | a jet on a plate, inviscid | M |
| the split (look round 2) | P2's per-jet geometry, one model with P2's wall jet: each F-1 jet's cross-section where its axis meets the deck, P1's R(h), against the ML opening's square; the rest goes down the opening. At T+8 s (65 m of climb) a third meets the deck | `PlumeImpingement`, P1 | M |
| the reach (look round 2) | the jets' penetration as a fountain: z_m = 2.46 M^¾ F^−½ with the physical fluxes, M = thrust/ρ, F = g (ρ − ρe)/ρ ṁ/ρe at the exits; all of the exhaust reaches the pad below z_m, none from the fountain's initial height 1.5 z_m, smoothly between. About 760 m at the rated flow (Seban et al.'s 2.35 for heated air jets aimed down: 727 m). It replaces P4's fade of half at 45 m of climb (L) | Turner 1966, J. Fluid Mech. 26, 779; Seban, Behnia and Abreu 1978 | H (the law) |
| clouds | Morton-Taylor-Turner thermals, α 0.25, fed at their jets' ends with the jets' volume and buoyancy, on the launch day's sounding (its stability N² and winds) | MTT 1956 | M |

Plausibility, not a fit (`GroundCloudTests`):
- the jets 250 m beyond the exits by T+5 s, and the clouds past the tower
  within seconds;
- at 15 s the cloud is 954 m across (Apollo 16: 750 m);
- at 30 s it is 1.09 km across (Apollo 10 and 16: 1.2-1.3 km), its top at
  0.74 km (Apollo 16's south lobe: 0.5 km);
- the south trench cloud's top is at 1.18 km at 60 s, 1.76 km at 120 s and
  2.14 km at 180 s (Apollo 16's south plume: 0.8, 1.65 and 2.2 km); the
  deck's cloud is higher, 1.34 km at 60 s and 2.75 km at 180 s.

Sources: TM X-2935 Figs. 3 and 4; Apollo 10's plume in CR-61326 (Dumbauld
et al.'s handbook) Fig. E-9.

Apollo 16's cloud stabilised with its centre line at about 2.2 km by
T+2.5 min, under a subsidence inversion at about 2 km (TM X-2910). The
model's, volume-weighted, is 1.73 km then, 21 % lower, and still rising at
6 m/s, slowing; AS-506's sounding has no such inversion. That is another
vehicle (AS-511) and another day (16 April 1972). By T+240 s the clouds
hold 390 t of exhaust: 155 t from the trench, 236 t from the deck. Nothing
in the model was adjusted to these.

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

## The launch cloud's medium (look round 2, LR4)

Look round 2 makes the pad's cloud a medium (`docs/m16/look-round-2.md` §3,
decision 3): the trench jets, the deck's wall jet, the clouds and the start
smoke are marched, not drawn as puffs. This first part is the scene's side,
pure Swift in OrbitScene. The pass that marches it, and sprite v2 for the
flash, the cold vapour and Low, come after LR0's reconstruction. Until then
P4's sprites still draw the cloud.

**What the clouds carry** (`GroundCloud`, extended). Each lobe also counts
the soot it carries (`LaunchCloudOptics.sootYield`), the air it entrained
with that air's vapour, and its last step's feed. The F-1s' start smoke,
the gas generators' 2.9 % at 887 K from each start command to its
ignition, feeds three small thermals of its own: half up through the ML's
opening, a quarter out of each exit (P4's split, L). All three are
integrated apart, so P4's sprites still see the lobes they did. Once the
trench's jets run, the field draws all three inside the trench's clouds:
the exits' smoke through which the jets run, and the chimney's, round the
vehicle over the opening, taken in by the jets down it, half to each. No
start smoke lingers round the vehicle.

Every jet's front runs at half its jet's speed (a starting jet, Turner
1962): the trench's at the round jet's, and the deck's, since round 2, at
its own wall layer's, the speed the field's wall jet carries its fluid at.
The water takes all the heat it can, or all the water boils, branched
explicitly, so no rounding residue is left as heat.

**The field** (`GroundCloudField`). It is built from GroundCloud's state
alone, so a rebuilt field is the frames' to the bit. It holds at most 12
similarity primitives, each with a closed-form shape whose integral is one:

| primitive | law | source | grade |
|---|---|---|---|
| trench jets | round momentum jets from the deflector: the concentration's e-folding radius λ 0.107 x, λ = 1.19; mass per unit length (1 + λ²) x / (7.0 √M) per kg/s; along the ground at the exits' mid-depth, mirrored in the grade | Fischer et al. 1979, Table 9.1 | H (the law) |
| deck wall jet | P2's continued from where P2's ends (`WallJetHandover`), or from the jets' footprint if that is beyond: its half-thickness there, growing 0.087 a metre, P2's top-hat profile across it; the speed that keeps all its momentum in that layer. It carries P2's own flux of exhaust where P2's ends, within 1 % (the members' flow times their deck shares, one model with PadExhaust) | Poreh, Tsuei and Cermak 1967; P2 | M |
| clouds | ring thermals: a Gaussian torus about the cloud's vertical axis (ring 0.35 R, core 0.5 R, stretched 1.2 upward), mirrored in the deck's level, which GroundCloud rests them on | the look of Scorer's thermals | L |
| stems | pure plumes from each trench jet's end up into its cloud, top-hat α 0.117; faded in over the cloud's lift-off (half its radius) and as the jet's buoyancy flux rises past 5 % of a trench jet's at full thrust (L) | MTT 1956, List 1982 | M |
| start smoke | its three thermals, as the clouds, until the trench's jets run; then inside the trench's clouds | — | L |

A lobe's exhaust, water, smoke, soot and heat are shared between its jet
and stem and its cloud. The jet and stem get what flows in them at the
feed's steady flow: the flow over the speed that carries it, out to the
front. The fronts run at half their jets' speeds, so that is less than the
jet has carried, and the head keeps the rest. Only while a flow rises
faster than its jet fills is it more, and then the jet takes what the lobe
has. The share is one factor for everything they carry, so their mixture
is the feed's and the flow is continuous from jet to stem.

The deck's wall jet, as far as P2 draws it, is P2's (`inPlume`). So the
field's totals are the clouds' to rounding, and integrated over space they
are within 1 % (`GroundCloudFieldTests`). The exhaust's own water is part
of its mass; the vapour budget adds what its hydrogen makes burning.

**Condensate.** It is not carried. At each point, the mixture of what the
primitives bring there with the air (the cloud's own entrained air, blended
to the ambient air at its edge) is saturation-adjusted: c_p (T − T*) =
L(T) q_c (`MoistAir.adjust`). Saturation over water is Wagner and Pruss's
(IAPWS-95 within 0.01 %, H), Murphy and Koop's below the triple point. This
replaces P4's "all of the water condensed" (L).

**Humidity** (`LaunchHumidity`, decision 6).
- At the surface, TM X-64796's observation for AS-506 (Table 1, seq. 145):
  29.4 °C and 73 % at 10.203 N/cm². That gives 18.8 g/kg and a dew point of
  24.0 °C (M). Lifted, this air saturates at 0.65 km. That matches the
  launch's 1/10 cumulus, whose base FER-506's Appendix A gives at 0.7 km.
- Aloft, July's means at Cape Canaveral: the 1983 Range Reference
  Atmosphere for station 74794, 1957-1979, its 12-18Z window (Apollo 11's
  13:32 UT is inside it), Tables II-7 and III-7. The relative humidity of
  its means is 72.4 % at 1 km, 65.1 % at 2 km and 57.5 % at 3 km. The 5 km
  vapour pressure's digit is blurred in the scan, so 5 km is left out.
- Between those, the humidity is linear in height.

This is a climatology, not the day's profile. Fetching IGRA v2 station
74794's sounding for 16 July 1969 is a data decision for Franz. FER-506
gives dew points at the surface only.

**The look: grey near the pad, condensing aloft.** The model boils all of
the deluge's water that the exhaust's heat can boil, and that heat is about
ten times what the water can take. So the mixture is far from saturation:
about 55-100 K above the air at T+10 s, 15-50 K at T+30 s and 7-12 K at
T+60 s.

With July's humidity aloft, the clouds hold no condensate for the first
five minutes; the first appears at a trench cloud's top at about 2.5 km
(`testCondensateIsTheSaturationAdjustments`). They show their soot: at
P2's 0.072 %, an optical depth of about 15 through a trench cloud at
T+5-10 s and a few at T+30 s, a grey smoke.

**The soot, not only the water, bounds the whiteness.** Even with all of the
pad's water condensed on 10 µm droplets (the deluge's 58,000 gpm and the
exhaust's own, 0.62 kg a kilogram of exhaust), a cloud is white (thick-cloud
reflectance about 0.6, single-scattering albedo 0.99) only with at most
0.013 % soot (0.008 % in a trench cloud, which gets only the trench's
8,000 gpm). At P2's 0.072 % it is mid-grey: reflectance about 0.31.

What the sources say of the soot left near the ground:
- Nothing measures it in an RP-1 ground cloud.
- MSFC's own F-1 table (TM X-2935 Table II) lists 0.0575 % particulates at
  the exit, mainly from the turbine exhaust, and keeps them after mixing
  with the air.
- The global models' kerosene engines give 2-2.5 % black carbon at the
  exit (Ross and Sheaffer 2014; the National Academies' CSVEM, 2021; Barker,
  Marais and McDowell 2024). Their afterburning leaves 4 % of it at low
  altitude (CSVEM, Barker: 0.09-0.1 %), or none at sea level (Maloney et
  al. 2022).
- P2's exit value, 0.29 %, is a fit to the flame's opacity. Its 25 %
  survival (`burntSoot`) has no source. P2's exit with CSVEM's 4 % survival
  would be 0.012 %, white with all the water condensed.

The yield stays P2's until decision 4.

The white part is a trench jet from T+20 s. By then the climb has carried
most of the jets onto the deck while the trench's water still runs, so the
little exhaust left there boils it, and its steam condenses.

This is what the S-IC static firings at NASA's Mississippi Test Facility
showed (Forbes, Smith and Farrell 1972, NASA CR-2049), with about four
times LC-39's water:
- the LOX/RP-1 exhaust was "dark gray";
- the white, condensing part was "delineated from the gray non-condensible
  exhaust" and first condensed at about 1,740 m;
- aircraft psychrometers read up to about 125 % in the cloud.

A sensitivity study found the onset unmoved by any listed L input: the
boiled share, the radiant fraction (0.25-0.5), the afterburning (none to
complete), the entrainment (0.15-0.35), the exhaust's own water and the
humidity aloft. It moves only with ten times the water. Decision 5 keeps
the physics. Whether to model the deluge's spray drops, which the film's
white near the pad may be, is Franz's call.

**Turbulence** (`LaunchTurbulence`).
- The eddies and their lifetimes are LR3's `TurbulenceSpectrum`'s: the
  largest cell 0.45 of the flow's size, halving, drawn in full from 4 pixel
  footprints and none below 1.5 (at most 8 octaves at High, 4 at Medium);
  the largest living the size over the flow's speed, no slower than w* =
  1.5 m/s (L), octave k 2^(−2k/3) of that.
- The boundary: a fractal of D = 7/3 (Sreenivasan and Meneveau 1986, H). Its
  level sets are displaced by octaves of gain 2^(−k(3 − D)), the whole
  cascade's rms 0.25 of the flow's size (L).
- The noise: P2's flow noise, in P2's bands of lifetimes, carried in each
  flow's own coordinates. Each octave is averaged over the exposure as P2
  averages it, u/L integral lengths a second. The wall jet's noise is laid
  out in its local eddies every way, round the deck on a circle, out along
  it in ∫dρ/δ.
- The mass is kept. Displacing a convex profile's level sets by a zero-mean
  amount raises its integral on average: a ring thermal's by a third with
  every octave drawn, a jet's by a quarter. So each displaced density is
  divided by that expected gain, tabled by shape against the displacement's
  rms (`GroundCloudField.DisplacementGain`; `EffectMedium.gains` for the
  shader). A drawn thermal then holds its mass within 2 %, close up or far.
- Measured: the structure function's slope is 1.32 against 4/3, and a
  frame's change at T+15 s is 1.3 % of the boundary's rms.

**Optics** (`LaunchCloudOptics`).
- Extinction from mass: droplets of 10 µm (L) at 150 m²/kg; soot absorbing
  7.5 m²/g (fresh black carbon's mass absorption cross-section, Bond and
  Bergstrom 2006, M) at P2's single-scattering albedo, 0.25, so its
  extinction is 10 m²/g.
- The soot yield: P2's implied value until decision 4 picks one. That is its
  soot depth across an F-1 exit over that extinction, 0.29 %, less what its
  flame burns (`burntSoot`, L): 0.072 %. Both parts are L: the depth is a
  fit to the flame's opacity.
- The phase: C2's approximate Mie at 20 µm, blended with soot's
  Henyey-Greenstein at 0.4 (L).
- Multiple scattering: a two-stream with absorption, C2's exactly at albedo
  1.
- Emission: hot soot's blackbody.

`EffectMedium` packs the primitives into Float records for the pass, with
the box the far field's grids cover (at T+8 s, 1,360 × 685 × 541 m: High's
cells are 5-11 m) and the air's humidity by `AirProfile` level.

**Open, for the pass:**
- The condensate's latent heat warms the adjusted mixture but is not fed
  back into GroundCloud's buoyancy.
- Beyond the ML, the wall jet runs on at the deck's level.

The deluge steam material, which nothing emitted, is deleted, and with it
its lifetimes and PadExhaust's steam rates.

## Shots

`docs/look/shots/launch.json` (scene goldens, report only): the live count at
T−10, T−5, T−0, T+3, T+8 and T+15 s, resumed at once (T−0 at Apollo 11's
range zero), clouds off.
