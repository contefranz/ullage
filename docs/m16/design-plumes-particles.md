# M1.6/M2 design: Plumes and particles

> Planning document for the M1.5 close-out, milestone M1.6 (graphics overhaul) and M2 (Apollo 8), written on 2026-10-20 by a design study (six design reports checked by a planner) and accepted by Franz on 2026-10-21 with all recommended defaults (US keyboard). Track briefs refer to it. Where code has moved on, the code wins.


This is a design report. Where it conflicts with plan.md, the plan wins: the planner checked and corrected the reports.


## Current state

RENDERER (Mac only)
- There is one forward pass, drawn straight into the MTKView drawable: bgra8Unorm_srgb, 4x MSAA, depth32Float with reversed-Z (Renderer.swift:62-90 and 230-467).
- It has no HDR target, no off-screen or half-resolution buffers, no resolved depth texture that a shader could sample, no compute passes and no post-processing.
- The plume pipeline blends purely additively (Renderer.swift:110-115 and 129). Bright plumes therefore clip at 8 bits, and nothing can absorb light: no soot, smoke, steam or dark core can occlude what is behind it.

PLUMES TODAY
- Plumes.swift (135 lines) draws one additive camera-facing cone strip per delivering thruster, plus a disc over the exit for the end-on view (Plumes.append, :82-129).
- The style is guessed from the feed's tank names (:42-56): kerosene, hydrogen, solid or hypergolic.
- A fixed look table (:58-70) mixes sea-level and vacuum intensity, length and half-angle by sqrt(p/p0) (:86-90).
- Plumes have a visibility floor of 0.3 (:40; owner decision 19 in M1.5).
- Jets without a nozzle shape get a nominal exit radius of 0.0095 times the cube root of the thrust (:74-77).
- Renderer.appendPlumes (:578-600) anchors plumes on the linked nozzle exits (VesselMesh.nozzles, Meshes.swift:26-41 and 51-76). Intensity is thrust(ambientPressure:) over thrustVacuum.
- The shader (Shaders.swift:265-307) is an analytic falloff with a hot line and the kerosene dark core.
- A distant vessel becomes a tinted point (Renderer.swift:604-611).
- Plumes are drawn after the opaque pass with depth read-only (:430-438), and they do not light anything.

WHAT IS MISSING
- There are no particles at all: no smoke, steam, ice, debris, sparks or spray.
- There is no event plumbing to the renderer. Simulation.events holds text log lines only (Simulation.swift:3-7 and 28); stageAll logs a string (SimulationStaging.swift:15-31).
- The renderer sees only the state at frame end. At 100x a frame covers about 1.7 s of simulation time (warpSteps at AppModel.swift:82, a 40 ms step budget at :86). The S-IC retros' 0.64 s burn can begin and end inside one frame and never be drawn.

CORE DATA ALREADY AVAILABLE
- Thrusters: Thruster.isDelivering, thrust(ambientPressure:), massFlow, thrustDirection, isSolid and transients (Components.swift:285-600).
- Engine ratings: EngineRating carries the vacuum thrust, Isp at sea level and in vacuum, and the implied exit area (:111-170). It has no chamber pressure, area ratio, exhaust gamma or composition, so the exit pressure cannot be derived today.
- Solid motors (AS506Data.swift:763-849):
  - S-IC retros: 8 x 387 kN for 0.64 s, 7.5° cant.
  - S-II ullage motors: 4 x 23,000 lbf for 3.75 s.
  - S-II retros: 4 x 34,810 lbf for 1.52 s.
  - S-IVB ullage motors: 2 x 3,390 lbf for 3.87 s.
  - Tower-jettison motor (TJM): 31,660 lbf for 1.16 s, thrust tilted 3.784°.
- Nozzles and events (AS506Data.swift): F-1 exit area 10.10 m² (:618); J-2 throat and area ratio 27.5 (:667-669); event times (:90-91, 249-290). Interstage jettison is at 192.3 s, LES jettison at 197.9 s, T3 + 0.7 s and T4 + 0.8 s are the separations, and the ullage cases go at T4 + 12.8 s.
- Spacecraft engines, from the AOH readings (docs/data/apollo-spacecraft/readings/AOH/reader-A/aoh.txt):
  - SPS: area ratio 62.5, exit 98.4 in inside diameter, oxidizer lead (:8).
  - SM RCS: area ratio 40, exit 5.6 in (:15).
  - CM RCS: area ratio 9, exit 2.13 in (:17).
- Air: the launch-day sounding gives p, T, ρ and winds (Atmosphere.swift:27-97). It has no humidity.
- Frost: FER Table 20-1 frost is already booked (AS506-datasheet.md:1191 and :2453). The S-IC carries 635 kg at release and 340 kg at CECO; the S-II sheds 204 kg and the S-IVB 90 kg by CECO.
- Apollo 7 blackout, actual: entered at 259:54:58 and left at 259:59:46 (tools/data/a07_mr_table_2_1.csv).
- Entry and recovery state: Vessel.heatFlux (Vessel.swift:134), the ELS epochs (EarthLandingSystem.swift:41-44), Parachute.deployedAt (Parachute.swift:62) and the splashdown log (Simulation.swift:313).

PRECEDENTS TO FOLLOW
- The heat-shield glow is lagged in simulation time and reset on time jumps (Renderer.swift:543-554).
- The navball has its own runtime-compiled shader string and library (NavballShaders.swift, NavballRenderer.swift:76).
- Per-frame vertex data goes through the FrameArena ring buffers (:748-780).
- Smoothed GPU time is kept in FrameTimes (:783-792).
- The app is an executable target with no test target (Package.swift).

## Design

PRINCIPLES
- What can be derived from engine data is derived from it, and none of it feeds back into the physics.
- The physically derived plume structure lives in OrbitCore as pure functions with Linux tests: nozzle flow, plume regime, shock and Mach-disk positions, boundary angles, vacuum density, frost schedule, sublimation, particle kinematics, the plasma window and the event journal.
- Only the look (colour, noise, intensities after calibration) lives in the app.
- Every effect is either state-driven (a continuous function of the vessel's state each frame) or event-driven (spawned from a journalled event with its exact epoch and state). This is what makes effects survive time warp.

A. CORE: EXHAUST PHYSICS (track X1, Linux)

A1. ExhaustSpec, in new Sources/OrbitCore/Effects/ExhaustSpec.swift:
- family: keroseneLOX, hydrogenLOX, hypergolic, solidAluminized, solidOther, coldGas;
- chamber pressure pc at the rated flow (Pa, nozzle stagnation);
- area ratio ε, exit radius and nozzle lip half-angle;
- exit γ and molar mass, chamber and exit temperatures;
- the fuel-rich mole fraction (CO + H2) that drives afterburning, and a soot index;
- the Al2O3 mass fraction;
- an optional turbine-exhaust film (mass fraction, injection area ratio, temperature);
- source and grade strings in the datasheet's H/M/L style.

A2. ApolloExhaust.swift: `ExhaustLibrary.spec(for: Thruster, in: VesselPart) -> ExhaustSpec?`, keyed by part and thruster name the way dressSaturnV is. It covers "S-IC engine n", "S-II engine n", "S-IVB engine", "<set> motor n", "Tower jettison motor", "SPS", "SM RCS xx", the CM RCS jets and "APS n …". Keying by name means Components.swift and AS506Data.swift are not touched.
- Values, to be confirmed by transcription and a CEA run:
  - F-1: ε 16 (regeneratively cooled to 10:1, turbine-exhaust-cooled extension 10:1 to 16:1); pc about 982 psia nozzle stagnation (the 1,125 psia often quoted is at the injector end); MR 2.27; turbine film about 3 % of the flow at about 900 K (L).
  - J-2: ε 27.5 (in the repo); pc 763 psia (M).
  - SPS: ε 62.5, exit 98.4 in (AOH, H); pc about 100 psia (M).
  - SM RCS R-4D: ε 40, exit 5.6 in (H). CM RCS: ε 9, exit 2.13 in (H).
  - TJM: from TN D-6295, already in hand.
  - TE-M-424, TE-M-29 and TX-280 chamber pressure, ε and composition: L until sourced.
- Exhaust γ, molar mass and species come from NASA CEA, run outside the repo by a tools/make_exhaust_table.py driver. Only the input decks and the numbers are committed, in tools/data/cea_apollo_exhaust.csv.

A3. NozzleFlow.swift:
- the isentropic A/A*(M), p/p0(M) and T/T0(M), with the supersonic and subsonic inverses solved by safeguarded Newton;
- the Prandtl–Meyer function ν(M), its inverse, and ν_max = (π/2)(sqrt((γ+1)/(γ−1)) − 1).

A4. PlumeModel.swift: `PlumeModel.state(spec, flowFraction: massFlow/ratedFlow, ambient: AtmosphereState) -> PlumeState`.
- The exit state:
  - pc = pc_rated × flow fraction, because a choked throat makes pc proportional to ṁ. This way the start and shutdown transients shrink the plume.
  - Me comes from ε, pe = pc·(p/p0)(Me), and n = pe/pa, where pa is v.atmosphere.pressure (the launch day's sounding).
- The regime:
  - separated when pe/pa < (1.88 Me − 1)^−0.64 (Schmucker);
  - overexpanded and attached when n < 1;
  - underexpanded continuum when n > 1;
  - transitional or free-molecular by Knudsen number, λ_ambient / D_e, with the visible shock structure fading out.
- The initial boundary angle is δ0 = ν(Mb) − ν(Me) + θ_lip, where Mb comes from expanding pe isentropically to pa. The vacuum limit is θ_lim = ν_max − ν(Me) + θ_lip.
- The fully expanded jet's Mach number Mj and diameter Dj come from mass conservation.
- The shock-cell length is Ls = 1.306·Dj·sqrt(Mj² − 1) (Pack; Tam and Tanna), with N decaying cells, for n between 0.3 and 5.
- The Mach disk, for n > about 2, sits at x_M = 0.69·De·Me·sqrt(γn) (Lewis and Carlson 1964). In the sonic limit this is cross-checked against Ashkenas–Sherman, x_M = 0.67·D*·sqrt(p0/pa). Its radius is empirical and visual-grade.
- In vacuum and the far field, the density follows Simons: ρ = A_p ρ*(r*/r)² cos^{2/(γ−1)}(πθ/2θ_lim), with A_p set by mass conservation.
- Afterburning A = fuel-rich fraction × ambient O2 availability. It fades out above about 40–45 km; the shape is L, calibrated to photographs.
- The model also returns a potential-core length and a "luminous length" for the visual calibration.

Checked numbers (γ 1.22–1.25, before the CEA run):
- F-1: Me about 3.7, pe about 43 kPa.
  - At sea level n is about 0.42: overexpanded but attached, since the Schmucker separation limit is about 0.32.
  - pe equals pa near 6.7 km on US76, about T+50 s.
  - At 30 km, n is about 36, δ0 about 45° and the Mach disk about 60 m downstream.
  - At S-IC cutoff (about 67 km), n is about 6,000 and δ0 about 77°: the plume balloons wider than the vehicle, as the footage shows.
- J-2: pe about 16.5 kPa. At S-II ignition (about 7 Pa ambient) n is about 2,400 and δ0 about 64°. The Mach disk would sit about 300 m downstream in rarefied gas, so in flight the J-2 shows no Mach disk. It forms only at low altitude.
- SPS: pe about 0.7 kPa, θ_lim about 100°. It is always in the vacuum regime in use.
- SM RCS: pe about 1.2 kPa. CM RCS: pe about 8.7 kPa.

A5. Engine-type looks, which the renderer parameterises from PlumeState and the family:
- Kerosene (F-1):
  - an opaque soot continuum glowing at about 1,900–2,300 K, plus sodium yellow;
  - a dark fuel-rich sheath (the turbine-exhaust film) over the first 0.5–1.5 exit diameters, which ignites in air into the afterburning flame and stays dark or brown in near-vacuum;
  - the five plumes merging into one envelope as δ0 grows;
  - base recirculation glow at high n.
- Hydrogen (J-2):
  - weak visible emission: a faint blue-violet near the exit, and a brighter Mach disk only where one forms;
  - in flight, a wide translucent plume made visible mostly by sunlight scattered from water condensing far downstream.
- Hypergolic (SPS, RCS, APS):
  - nearly invisible in vacuum, apart from the near-exit glow;
  - NO2-tinted puffs and droplets on oxidizer lead and lag at start and stop;
  - the radiation-cooled SPS nozzle extension glowing dull red through a thermal lag in simulation time, like the heat shield: the physical "engine running" cue.
- Solids: an incandescent Al2O3 core (white-yellow) with white smoke that keeps expanding.

B. RENDERER FOUNDATION THIS AREA NEEDS
Owned by the overhaul's renderer-foundation track if there is one; otherwise by P0 here, at +2–3 d.
- An HDR scene colour target (RGBA16Float, MSAA) with exposure and tone mapping.
- The MSAA depth resolved to a single-sample texture (depthResolveFilter), plus a half-resolution min/max depth.
- A half-resolution volume target (RGBA16F premultiplied, with radiance in rgb and 1 − transmittance in a), and for smoke the weighted-blended OIT accumulation pair (RGBA16F and R16F).
- A depth-aware (nearest-depth) upsample and composite before tone mapping.
- A light list buffer (`SceneLights`, up to 8 point lights) that the material track's mesh shader reads.
- A `VolumePass` registration hook on the renderer with an explicit order: opaque → clouds → plumes and smoke (volume target) → composite → additive sparks (full resolution) → lines and sprites → tone map.

Interim path, so X2 can land before the foundation:
- Draw the plume proxies at full resolution, premultiplied, into today's pass.
- Apply a per-plume Reinhard curve so they don't clip, and end each ray at the proxy's far side instead of reading depth.

Compositing with the clouds track: per pixel, compare the plume's front depth with the cloud's front depth and composite in that order. The Saturn V can then rise through a cloud deck.

C. VOLUMETRIC PLUMES (track X2, Mac)
- Clusters: each vessel's delivering thrusters are grouped by family into clusters (the 5 F-1s, 8 retros, 4 ullage motors, the J-2s, the SPS), with up to 8 members each.
- Proxy: each cluster draws one convex proxy, a capped cone around all members' boundary profiles out to the luminous length, back faces only, so it still works with the camera inside.
- Marching:
  - The fragment shader intersects the view ray with the proxy analytically, clamps the end against the half-resolution depth, and marches N steps.
  - N is 16 at Medium, 32 at High and 48 at Ultra; Low uses impostors.
  - Each march starts at a jittered offset (interleaved gradient noise, rotated per frame) and stops early once transmittance falls below 0.01.
- The density field at each sample: each member is evaluated in its own (x, r) coordinates with an early radial reject:
  - a smooth supersonic core;
  - a turbulent mixing layer near r_b(x), shaped by noise;
  - cos(2πx/Ls) cells and a Gaussian Mach-disk sheet;
  - Simons far-field density;
  - soot extinction for kerosene;
  - single scattering of sunlight with a Henyey–Greenstein phase (soot albedo 0.2, condensate 0.95);
  - Hillaire's energy-conserving step integration.
- Data path: a `PlumeCluster` uniform made only of float4 values, about 8 per member. It is written with the FrameArena from PlumeState. The exit position, axis and exit radius come from the existing nozzle map (Meshes.swift).
- Noise: a tileable 128³ RG8 3D value/gradient noise texture generated at load with a fixed seed (procedural, so MIT by construction). It is sampled in 2–3 octaves and advected along the axis at a visual eddy speed (15–40 m/s scaled by the exit radius, frozen turbulence) on the turbulence clock (see E).
- LOD by projected size:
  - under 6 px: today's tinted far point;
  - 6 to 48 px: today's strip impostor, reshaped by PlumeState, premultiplied;
  - 48 px or more: ray-marched.
  - RCS jets stay impostors plus particle puffs unless the camera is within about 20 m.
- Plume lights: one point light per cluster, at about 1.5 exit diameters, carrying the cluster's integrated emission. These light the S-IC base, the S-II interstage when the retros fire, and the pad steam from below.
- Shaders live in a new PlumeShaders.swift with their own library. The plume_* functions in Shaders.swift are deleted.

D. GPU PARTICLES (track X3, Mac)
- Anchors keep everything camera-relative:
  - an anchor is `.bodyFixed(body, origin)` or `.freeFall(reference, r, v)`, stored in double on the CPU;
  - free-fall anchors are propagated with two-body + J2 each frame, then turned into camera-relative float offsets;
  - particles store float position and velocity relative to their anchor;
  - gravity is −g·up in a body-fixed anchor and zero in a free-fall one;
  - air velocity relative to the anchor is the wind(alt) plus Earth's rotation minus the anchor's velocity;
  - ρ, T, p and wind come from a 64-entry altitude table uploaded each frame from sim.atmosphere(of:).
- Buffers and kernels:
  - a particle is 48–64 B: position and size, velocity and age, lifetime, temperature, seed, material and anchor;
  - free and alive lists use atomic counters, and indirect draw arguments are kept per material class;
  - kernels: emit (from CPU EmitRequests: count, anchor, shape (point, disc, ring, cone, surface band), velocity distribution, size, material, initial age), simulate, and compact.
- Integrator: exact for linear drag. With v_inf = v_air + g·τ:
  - v(t+Δ) = v_inf + (v − v_inf)·e^{−Δ/τ}
  - x(t+Δ) = x + v_inf·Δ + (v − v_inf)·τ·(1 − e^{−Δ/τ})
  - τ = m/(½·ρ·Cd·A·|v_rel|) is re-linearised each frame for quadratic drag, and infinite in vacuum (ballistic).
  - It is stable for any Δ, so warp needs no substeps.
  - The same functions are in core (ParticleKinematics.swift) for the Linux tests and as golden vectors for the GPU self-test.
- Other physics:
  - buoyancy ∝ ((Tp − Ta)/Ta)·g with thermal relaxation;
  - growth by entrainment (α about 0.1, Morton–Taylor–Turner), with opacity following mass conservation (τ_optical ∝ m/r²);
  - ice sublimation by Hertz–Knudsen with the Murphy and Koop vapour pressure, at the air temperature in air and a radiative-equilibrium temperature in vacuum (sunlit or in eclipse);
  - incandescent particles cooling by radiation;
  - particles killed at the ground or water plane.
- Three render classes:
  1. Glow, sparks and flashes: additive at full resolution, as velocity-stretched quads (streak = screen velocity × 1/60 s). Order-independent.
  2. Smoke, steam, spray and frost clouds: lit soft billboards at half resolution with weighted-blended OIT (McGuire and Bavoil), soft depth fade, procedural puff normals, and lighting from the sun × Eclipse.sunlitFraction at the anchor, a Henyey–Greenstein phase (g 0.7 ice and water, 0.4 smoke), sky ambient and the plume lights. Being order-independent, golden frames stay reproducible despite the atomic append order.
  3. Chunks (ice slabs, cork, pyro debris, char): at most 2k instanced low-poly plates or tetrahedra in the opaque pass, tumbling and lit like vessels.
- Files: Effects/ParticleSystem.swift, ParticleShaders.swift (own library), EffectAnchors.swift, VolumeNoise.swift, EffectDirector.swift.
- Effect files define emitters only, through a material table, so the effect tracks never edit shaders.

E. TIME WARP, PAUSE, DETERMINISM
- Core EffectJournal (Sources/OrbitCore/Effects/EffectJournal.swift) is a bounded ring of structured EffectEvent records:
  - kinds: liftoff, separation(event, parts), ignition and cutoff (thruster), chute deploy, splashdown(speed), breakup;
  - fields: epoch, vessel ID, reference body, position and velocity relative to the body, and axis.
- Hooks: stageAll records the separations; the end of Simulation.step records ignition and cutoff edges from a side table keyed by ObjectIdentifier, accurate to one step (0.02 s powered); the splashdown and landed transitions are recorded where they are logged. The ELS and parachute epochs are read directly.
- Two clocks:
  - simulation time drives particle physics, ages, shedding and trails, so 10x is consistently 10x faster;
  - a turbulence clock, real dt × min(warp, 4), drives the noise, so flames do not strobe at 1,000x;
  - pause freezes both.
- EffectDirector:
  - drains the journal each frame and spawns bursts with initial age = t_frame − t_event, through the exact integrator;
  - drops bursts older than their lifetime;
  - integrates continuous emitters as rate × Δt_sim, but only over the last lifetime of the frame interval, with stratified spawn times (no bunching, and the cost is bounded);
  - suspends continuous emitters at 1,000x and above, except the trail.
- Short luminous events (retros, pyros, J-2 start) can be held on screen for at least 3 real frames when warp is above 10x (owner option).
- All systems reset on a scenario change or a time jump (dt below 0 or above 600 s), as the thermal lag does.
- The random number generator is a PCG hash of (event ID, index, seed). In snapshot mode the visual dt is fixed.

F. EFFECT CATALOGUE

Launch (track X4):
1. Pad exhaust and deluge cloud.
   - Body-fixed at LC-39A, emitted from the flame-trench exits on the LC-39 plan (L).
   - Rate ∝ thrust × impingement (De/h)², faded out by about 100–200 m of climb.
   - Deluge 28,000 gpm (SA-501 caption).
   - 2–6k buoyant puffs of 5–40 m, drifted by the sounding's surface wind, living 60–300 s of simulation time, lit from below by the plume lights.
2. Ice and frost shedding (FrostShedding.swift, from FER Table 20-1).
   - Mass rates per stage band: S-IC 635 → 340 kg by CECO; S-II 204 kg; S-IVB 90 kg. A burst at first motion, then an exponential decay whose shape is L.
   - 80 % fine flakes (1–5 mm, drag-dominated, sublimating) and 20 % slabs (2–30 cm, tumbling chunk meshes).
   - Above about 40 km the survivors become sunlit "fireflies".
3. Cold vapour streaming down the S-IC LOX tank and from the swing-arm umbilicals for about 10 s after first motion (positions L).
4. Exhaust trail.
   - A CPU polyline in the Earth-fixed frame, a point every 25 m while the S-IC fires below about 40 km. Each point carries a width from r_b and a soot or condensate density.
   - Advected by the sounding winds at its altitude, so AS-506's measured shear twists it, and diffusing over minutes.
   - Drawn as a ray-marched or lit tube ribbon.
5. Optional: transonic condensation collars at Mach 0.85–1.15 (around T+66 s), at the LES/BPC, CM/SLA, S-IVB flare and interstage shoulders. They form where the Prandtl–Meyer expansion temperature falls below the dew point, which needs humidity data.

Staging and spacecraft (track X5):
6. CECO (134.6 s) and OECO cutoff edges: the plume collapses over the 0.66 s F-1 tail-off with a short flare, leaving a fuel-rich soot puff.
7. S-IC/S-II separation:
   - eight retro plumes, volumetric solids, firing forward and 7.5° outward and enveloping the interstage;
   - Al2O3 and combustion smoke shells expanding ballistically at about 7 Pa;
   - a pyro flash ring at STA 1564 with chips;
   - from T3 + 0.5 s, the four S-II ullage plumes with smoke;
   - the J-2 start flash at T3 + 2.4 s, then the mainstage ramp.
8. Interstage ring at 192.3 s: a linear-shaped-charge flash ring at STA 1760 with chips. Optionally, the ring glows where it crosses the J-2 plumes.
9. LES jettison at 197.9 s: the TJM's two scarfed nozzles with the resultant 3.784° off axis, a smoke trail, and flashes at the frangible nuts.
10. S-II/S-IVB separation at T4:
   - the four TE-M-29 retros;
   - the two TX-280 ullage plumes from T4 + 0.7 s;
   - the J-2 start;
   - the two ullage cases jettisoned at 561.0 s, with a puff each.
11. SLA panels (event 6): flashes along the pyro seams, plus 200–600 cork and debris "fireflies" at 0.1–2 m/s glinting in sunlight.
12. SPS: an NO2-tinted puff with droplet sparkle at ignition and cutoff (0.2–1 s), the nozzle-extension glow, and the faint Simons plume.
13. RCS (SM, CM, S-IVB APS): one Simons-shaped puff impostor per pulse, plus a few droplets.
14. S-IVB LOX dump and vents: a sunlit ice-crystal cloud. This is Apollo 8's slingshot and needs M2's S-IVB state.

Entry and recovery (track X6, with a core part):
15. CM plasma.
   - A shock-layer shell ahead of the heat shield. The standoff is Billig's, or 0.78 × the density ratio × R. The shell is a ray-marched volume in a new EntryShaders.swift.
   - A luminous wake 5–40 CM diameters long, growing with V.
   - Intensity from EntryPlasma.luminosity(ρ, V, Rn), with Tauber–Sutton's functional form and a visual normalisation.
   - The on and off threshold is calibrated to the Apollo 7 blackout window.
   - Colours: an orange-white core with sodium yellow, and a violet halo at onset (L). They are judged against S69-15592.
16. Ablation sparks:
   - rate ∝ (q − q_onset), from Vessel.heatFlux;
   - high ballistic coefficient;
   - incandescent at the radiative-equilibrium temperature from glowColor's law, cooling radiatively;
   - drawn as class-1 streaks.
17. SM breakup: once the SM vessel's q or heating crosses a threshold (about 75–80 km), its mesh fades out and burning fragments with dispersed β spawn. This is visual only; S69-15592 shows the SM debris.
18. ELS:
   - an apex-cover puff (event 30);
   - two drogue-mortar puffs and three pilot-mortar puffs, read from the ELS epochs;
   - reefing-cutter pops;
   - optionally, the CM RCS propellant dump and purge after the mains, with timing L (S71-42217).
19. Splashdown: on the journal record, a crown and spray (droplets at 1–2 × the impact speed, at 30–70°) plus mist. The foam ring and the green fluorescein dye are decals in the ocean track's shader.

G. CORE FILES
All new, in Sources/OrbitCore/Effects/:
- NozzleFlow, ExhaustSpec, ApolloExhaust, PlumeModel;
- EffectJournal;
- FrostShedding, IceSublimation;
- ParticleKinematics;
- EntryPlasma;
- Condensation (optional).
The only edits to existing core files are in Simulation.swift and SimulationStaging.swift, in the prep PR.

## Phasing

P0. Seams (0.75–1 d; core part on Linux, hook on the Mac). Lands first.
- Core: EffectJournal and its hooks in Simulation.step, stageAll and splashdown; the ExhaustSpec type and the empty ExhaustLibrary seam.
- App: the VolumePass and SceneLights hook, if the renderer-foundation track has not already provided it.
- Agree the PlumeState and EmitRequest interfaces and the file ownership.

Three tracks then run in parallel, owning disjoint files:
- X1. Core exhaust physics and data (Linux/cloud, 3–4.5 d):
  - NozzleFlow, PlumeModel and ApolloExhaust;
  - the CEA tables, plus an exhaust datasheet in the AS506-datasheet style;
  - FrostShedding, IceSublimation and ParticleKinematics;
  - their tests.
- X2. Volumetric plumes (Mac, 5–8 d):
  - PlumeShaders.swift, the Plumes.swift rewrite and PlumeLights;
  - starts on a stub PlumeState that reproduces today's look table, and swaps to X1's model when it lands;
  - takes the interim LDR path until the foundation's HDR and half-resolution targets exist.
- X3. GPU particle core (Mac, 4–6 d):
  - ParticleSystem, ParticleShaders, EffectAnchors, VolumeNoise, EffectDirector and the self-test;
  - freezes the emitter and material-table API by about its second day.

After the X3 API freeze, three more tracks run in parallel, each with its own emitter files:
- X4. Launch effects: LaunchEffects.swift and ExhaustTrail.swift (4–6 d; +1.5 d for the collar).
- X5. Staging and spacecraft: StagingEffects.swift and SpacecraftEffects.swift (3.5–5 d). Item 14, the S-IVB dump, waits for M2's S-IVB state.
- X6. Entry and recovery (3–5 d):
  - EntryEffects.swift and EntryShaders.swift (Mac);
  - plus the core EntryPlasma and its Apollo 7 window test (about 0.75 d, Linux, can start right after P0).
  - The splash decals and dye depend on the ocean track.

X7. Integration (Mac, 2–3 d, last): golden frames against references, the warp matrix, the performance matrix, the quality defaults, and the README, ROADMAP and help text.

External dependencies:
- The renderer-foundation track: HDR, the resolved and half-resolution depth, the volume target, the upsample, SceneLights and the pass order.
- The materials track: its mesh shader consumes SceneLights and the SPS emissive extension tag.
- The clouds track: the depth-ordered composite.
- The ocean track: splash foam and dye decals.
- The pad track: LC-39A trench and deck geometry. Until it lands, the pad effects anchor to the geodetic pad.

Mac sessions can write code in parallel, but they must take turns for harness screenshots and performance runs. Two flights at once disturb each other's frame timing (project memory).

## Data and sources

- In repo: AS506Data.swift:618 (F-1 exit area 10.10 m², FER Fig 5-3), :667-669 (J-2 throat 14.7 in and area ratio 27.5, SP-8120), :763-849 (retro, ullage and TJM motors: MSFC-MAN-506, AS-501 FER Table 12-2, TN D-6295), :90-91 and :249-290 (FER Table 2-2 event times)
- In repo: docs/AS506-datasheet.md:1191, 2453 (FER Table 20-1 frost and purge gas: S-IC 635 kg at release, 340 kg at CECO; S-II 204 kg, S-IVB 90 kg by CECO)
- In repo: docs/data/apollo-spacecraft/readings/AOH/reader-A/aoh.txt:8, 15, 17 (SPS area ratio 62.5, exit 98.4 in, oxidizer lead; SM RCS 40:1, 5.6 in; CM RCS 9:1, 2.13 in)
- In repo: tools/data/a07_mr_table_2_1.csv (Apollo 7 Mission Report Table 2-1: EI 259:53:27, blackout 259:54:58 to 259:59:46 actual); tools/data/msc03466_sm_jettison.csv (SM after jettison, for the SM breakup)
- AS-506 Flight Evaluation Report MPR-SAT-FE-69-9: https://ibiblio.org/apollo/Documents/lvfea-AS506-Apollo11.pdf (Table 20-1 frost; its vehicle thermal environment section on S-IC base heating and plume backflow, section number to confirm)
- F-1 thrust chamber: tubes to 10:1, turbine-exhaust-cooled extension 10:1 to 16:1: https://enginehistory.org/Rockets/RPE08.11/RPE08.12.shtml ; chamber pressure 70 bar / 982 psia: https://en.wikipedia.org/wiki/Rocketdyne_F-1 , https://engineering.purdue.edu/AAE/research/propulsion/Info/rockets/liquids/f1 (Rocketdyne F-1 manuals R-3896-x to locate)
- NASA CEA (Gordon and McBride, NASA RP-1311): https://ntrs.nasa.gov/citations/19950013764 ; open-source re-implementation https://github.com/nasa/cea (Apache-2.0 per listings; confirm)
- NACA Report 1135, Equations, Tables and Charts for Compressible Flow (1953): https://ntrs.nasa.gov/citations/19930091059
- Simons, G. A., Effect of nozzle boundary layers on rocket exhaust plumes, AIAA J. 10(11), 1972; applied in NASA TM-88852 (Zana et al. 1987): https://ntrs.nasa.gov/citations/19870004995
- Lewis, C. H. and Carlson, D. J., Normal shock location in underexpanded gas and gas-particle jets, AIAA J. 2(4):776, 1964; Ashkenas and Sherman 1966 (Rarefied Gas Dynamics IV) for x_M = 0.67 D* sqrt(p0/pa)
- Pack, D. C., Quart. J. Mech. Appl. Math. 3:173, 1950; Tam, C. K. W. and Tanna, H. K., J. Sound Vib. 81(3), 1982 (shock-cell spacing)
- Schmucker 1973 separation criterion, reviewed in Stark, R., Flow separation in rocket nozzles - an overview, AIAA 2013-3840 (DLR)
- Billig, F. S., Shock-wave shapes around spherical- and cylindrical-nosed bodies, J. Spacecraft Rockets 4(6), 1967 (0.143 exp(3.24/M²) as quoted in https://arxiv.org/pdf/2604.00953)
- Tauber, M. E. and Sutton, K., Stagnation-point radiative heating relations for Earth and Mars entries, J. Spacecraft Rockets 28(1), 1991
- Murphy, D. M. and Koop, T., Q. J. R. Meteorol. Soc. 131:1539, 2005 (ice vapour pressure); Morton, Taylor and Turner, Proc. R. Soc. A 234:1, 1956 (entrainment)
- GSFC 1969 report on Apollo 6, 7 and 8 entry blackout (aircraft NASA 427 and USNS Watertown): https://ntrs.nasa.gov/api/citations/19690026881/downloads/19690026881.pdf
- SA-501 flame deflector and trench cooling water, 28,000 gpm (MSFC image 6760617): https://www.nasa.gov/image-detail/amf-6760617/
- Reference images (NASA, public domain): Apollo 8 liftoff S68-56050 https://www.nasa.gov/image-detail/amf-s68-56050 and KSC-68PC-327; Apollo 11 liftoff from the tower camera S69-39961; SA-506 liftoff MSFC 6901001 https://www.nasa.gov/image-detail/amf-6901001 ; Apollo 11 Camera E-8 16 mm 500 fps launch-tower film (KSC); Apollo 6 S-II camera interstage still 68-HC-191 (Commons File:Ap6-68-HC-191.jpg) and the Apollo 4 and 6 camera capsule films; Apollo 7 S-IVB with SLA panels open AS07-03-1545; Apollo 8 S-IVB after separation with 'fireflies' AS08-16-2582, -2583, -2584; Apollo 8 entry from the ALOTS KC-135 at 40,000 ft, CM with SM debris, S69-15592; Apollo 15 descent on two mains S71-42217; Apollo 15-17 LM ascent TV (hypergolic plume invisibility); Apollo 17 night launch (staging seen from the ground)
- Rendering techniques: Cantlay, High-Speed, Off-Screen Particles, GPU Gems 3 ch. 23 https://developer.nvidia.com/gpugems/gpugems3/part-iv-image-effects/chapter-23-high-speed-screen-particles ; Hillaire, Physically Based and Unified Volumetric Rendering in Frostbite (SIGGRAPH 2015) https://www.ea.com/frostbite/news/physically-based-unified-volumetric-rendering-in-frostbite ; McGuire and Bavoil, Weighted Blended OIT, JCGT 2(2) 2013 https://jcgt.org/published/0002/02/09/ ; Jimenez, interleaved gradient noise (CoD:AW 2014) https://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare ; Bridson et al., Curl-Noise 2007 https://www.cs.ubc.ca/~rbridson/docs/bridson-siggraph2007-curlnoise.pdf

## Licensing

The whole area stays MIT by construction: all code is original, written from the equations in the cited papers, and every texture (3D noise, puff normals) is generated procedurally at load with fixed seeds.

- NASA data and photographs are US Government works and public domain. They are credited in the datasheet and docs and used as references only; no photo is bundled.
- Commercial transfers of public-domain footage (for example Spacecraft Films) are not copied. Reference stills are taken from NASA, NARA or the NASA Image and Video Library.
- NASA CEA (github.com/nasa/cea, listed as Apache-2.0; confirm the LICENSE file) runs as an external tool. Only its input decks and the generated numbers are committed, which carry no licence burden.
- Not used: RocketCEA and Combustion Toolbox (GPL, check before any use), NASSP (GPL), Orbiter's D3D9Client shaders (LGPL), and KSP or its mods' assets and configurations (Waterfall, RealPlume, Smokescreen, as values, textures or code).
- Orbiter's MIT core needs nothing here; if anything were ported, its notice would be kept.
- GPU Gems 3, Frostbite, the WBOIT paper and the curl-noise paper are used for their techniques only; their sample listings are not copied.
- Simplex noise is not needed (gradient or value noise is used; its patent has in any case expired).

## Performance

Budget at 60 fps: 16.7 ms per frame. GPU allowance for this whole area, worst case close to the pad on a base M1 (8-core GPU) at 2560×1600, with the volume pass at half resolution (1280×800):

| Preset | GPU allowance | Typical ascent and orbit views |
|---|---|---|
| Medium | ≤ 1.5 ms | 0.3–0.8 ms |
| High | ≤ 2.5 ms | 0.3–0.8 ms |

Worst-case breakdown at High:
- Plume ray-march, 32 steps, up to 8 members, early radial reject: 1.0–1.5 ms. About 0.5 Mpx are covered; at sea level most samples hit only 1–2 members.
- Particle simulation, 128k particles: under 0.1 ms.
- Smoke OIT at half resolution: 0.4–0.8 ms. This is bound by overdraw, so the pad puffs are capped at 4k and get size LOD.
- Additive sparks and flashes at full resolution: under 0.15 ms.
- Upsample and composite: 0.1–0.2 ms.
- Chunks: under 0.1 ms.

CPU cost is under 0.3 ms per frame: PlumeModel for up to 40 thrusters (Me is cached per spec), draining the journal, emit requests, upkeep of up to 4k trail points, and anchor propagation. The cost is independent of warp. All of it runs after sim.advance, so the 40 ms step budget (AppModel.swift:86) is untouched.

Measurement: per-pass GPU timestamps with MTLCounterSampleBuffer at stage boundaries, shown in the debug HUD next to FrameTimes. Release and Debug on the owner's Mac.

Time warp:
- GPU cost does not grow with warp. Bursts are bounded by their lifetimes; continuous emitters only emit over the last lifetime of each frame interval, and stop at 1,000x and above (except the trail). Particle caps always hold.
- At 100x (1.7 s of simulation per frame), each staging burst is still spawned at its correct age from the journal.
- The turbulence clock (real dt × min(warp, 4)) stops noise strobing.
- Pause freezes everything.

Quality presets:
- Off: today's impostors.
- Low: impostors reshaped by PlumeState; 8k particles; additive only, no smoke OIT.
- Medium: the default on base M1 and M2. Half-resolution march at 16 steps; 32k particles.
- High: the default on Pro, Max and M3 or later. 32 steps; 128k particles.
- Ultra: full-resolution march at 48 steps; 256k particles; smoke self-shadowing if built.

Auto-downgrade: if this area's GPU time exceeds its budget for 2 s, the volume target drops from 50 % to 35 % resolution, then one preset down.

Shader compile: the plume, particle and entry libraries are compiled asynchronously with makeLibrary(source:completionHandler:). Until they are ready, the old impostors are drawn, so startup does not stall.

## Verification

LINUX (swift test). Every new test is analytic and quick, under about 5 s in total, apart from one entry flight kept under 30 s; no new ascent flights are added to the 15–18 min suite.
- NozzleFlowTests, against NACA Report 1135 for γ = 1.4:
  - M = 2: A/A* 1.6875, p/p0 0.1278, ν 26.38°;
  - M = 3: A/A* 4.2346, p/p0 0.02722, ν 49.76°;
  - ν_max 130.45°;
  - the inverses round-trip.
- PlumeModelTests:
  - the F-1 at sea level is overexpanded and attached by Schmucker (n about 0.42 against about 0.32);
  - its pe = pa crossing on the AS-506 sounding falls between 5 and 8 km;
  - δ0 increases monotonically with altitude;
  - Lewis–Carlson and Ashkenas–Sherman agree within 15 % in the sonic limit;
  - the Simons mass flux over a hemisphere equals ṁ within 1 %;
  - the SPS and RCS are in the vacuum regime above 60 km;
  - pc follows ṁ through the S-IVB start transient.
- ApolloExhaustTests:
  - every AS-506, CSM and CM thruster has a spec, which guards against renames as VisualShapeTests does;
  - the exit radii match the dressed nozzles and the sources: F-1 1.793 m from 10.10 m², J-2 0.979 m, SPS 98.4 in ID, SM RCS 5.6 in, CM RCS 2.13 in;
  - the area ratios match the AOH and SP-8120;
  - pe from (pc, ε, γ) agrees within 15 % with pe implied by the EngineRating, (F_vac − ṁ·v_e)/A_e with CEA's v_e.
- EffectJournalTests:
  - staging the test vehicle at warp 1 and at 100 records the same event epochs, to within one step;
  - ignition and cutoff edges are recorded;
  - the journal stays bounded;
  - the splashdown record's speed equals the log's.
- FrostSheddingTests: the integrals match FER Table 20-1 within 1 %: S-IC 295 kg from release to CECO, S-II 204 kg, S-IVB 90 kg.
- IceSublimationTests: Murphy and Koop gives 611.657 Pa at 273.16 K, 76.0 Pa at 250 K, 0.1627 Pa at 200 K and 6.11e-6 Pa at 150 K.
- ParticleKinematicsTests:
  - the exact integrator matches fine-step RK4 within 1e-6;
  - one step of 10 s equals 1,000 steps of 0.01 s (linear drag);
  - the terminal velocity is sqrt(2mg/(ρ·Cd·A)).
- EntryPlasmaTests:
  - Billig's sphere relation, 0.143·exp(3.24/M²);
  - on Apollo 7's entry from EI (reusing E1's path), the luminosity proxy is above its single calibrated threshold from within 30 s of 259:54:58 to within 30 s of 259:59:46 (Apollo 7 Mission Report Table 2-1, tools/data/a07_mr_table_2_1.csv).

MAC
- Build and launch:
  - xcodebuild build test, run by the session itself as the project memory says;
  - launch with MTL_SHADER_VALIDATION=1;
  - `OrbitSim --selftest effects` compiles the plume, particle and entry libraries, runs the compute kernels on ParticleKinematics' golden vectors, and exits non-zero on a mismatch;
  - the extracted shader strings are checked with xcrun metal -Wall.
- Golden frames from the snapshot mode or flight harness (Release, fixed seed, fixed dt; regression tolerance about 2/255 RMSE), each paired with its reference:
  - AS-506 at T+0.5 s: pad steam, ice, F-1 plumes and the S-IC base lit by them. References: S69-39961, the Camera E-8 film, S68-56050 (Apollo 8).
  - T+30 s: trail and frost.
  - T+66 s: Mach 1, and the collar if built.
  - T+120 s: a plume wider than the vehicle.
  - CECO at 134.6 s.
  - OECO at 161.6 s.
  - 162.3 s: retros and ullage motors around the interstage. Reference: Apollo 6 still 68-HC-191 and the Apollo 4 and 6 camera films.
  - 164 s: the J-2 start.
  - 192.3 s: the interstage ring.
  - 197.9 s: LES jettison.
  - 549–552 s: S-II retros, S-IVB ullage motors and J-2.
  - 561 s: the ullage cases.
  - The SLA panels and fireflies in sunlight. References: AS07-03-1545, AS08-16-2582 to -2584.
  - SPS ignition, and the nozzle glow after a 10 s burn.
  - CM/SM separation, the SM breakup and peak heating seen from behind and ahead. Reference: S69-15592.
  - The drogue mortar puffs and the mains. Reference: S71-42217.
  - The splashdown crown.
- The owner reviews a contact sheet of the frames side by side with their references. That review is the acceptance step; reference images stay out of the repo.
- Warp matrix: the ascent at 1x, 10x, 100x and 1000x.
  - Every staging burst is spawned (EffectDirector log).
  - Particle counts stay within the caps.
  - No NaNs.
  - Pause freezes everything; a scenario reload clears it.
  - GPU per-pass times stay within the presets' budgets.

## Files touched

- /Users/grossetti/sw/ullage/Sources/OrbitCore/Effects/NozzleFlow.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Effects/ExhaustSpec.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Effects/ApolloExhaust.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Effects/PlumeModel.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Effects/EffectJournal.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Effects/FrostShedding.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Effects/IceSublimation.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Effects/ParticleKinematics.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Effects/EntryPlasma.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Effects/Condensation.swift (new, optional)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Simulation/Simulation.swift (P0 only: journal property, edge detection after step, splashdown/landed records)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Simulation/SimulationStaging.swift (P0 only: separation records in stageAll)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/NozzleFlowTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/PlumeModelTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/ApolloExhaustTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/EffectJournalTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/FrostSheddingTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/IceSublimationTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/ParticleKinematicsTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/EntryPlasmaTests.swift (new)
- /Users/grossetti/sw/ullage/tools/make_exhaust_table.py (new; drives an external nasa/cea build, nothing vendored)
- /Users/grossetti/sw/ullage/tools/cea/*.inp (new CEA input decks)
- /Users/grossetti/sw/ullage/tools/data/cea_apollo_exhaust.csv (new)
- /Users/grossetti/sw/ullage/docs/exhaust-datasheet.md (new, X1: sourced and graded engine exhaust values)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Plumes.swift (rewrite: clusters, PlumeState packing, LOD)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/PlumeShaders.swift (new, own library)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/PlumeLights.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Effects/ParticleSystem.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Effects/ParticleShaders.swift (new, own library)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Effects/EffectAnchors.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Effects/VolumeNoise.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Effects/EffectDirector.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Effects/EffectsSelfTest.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Effects/LaunchEffects.swift (new, X4)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Effects/ExhaustTrail.swift (new, X4)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Effects/StagingEffects.swift (new, X5)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Effects/SpacecraftEffects.swift (new, X5)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Effects/EntryEffects.swift (new, X6)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Effects/EntryShaders.swift (new, X6, own library)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Renderer.swift (a few lines: register the volume and effect passes, drop appendPlumes and pass 6, feed SceneLights; coordinate with the foundation track)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Shaders.swift (X2: delete plume_vertex and plume_fragment; the mesh-shader light term belongs to the materials track)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/AppModel.swift and /Users/grossetti/sw/ullage/Sources/OrbitSim/Views.swift (quality preset setting and menu; small, UI owner)
- /Users/grossetti/sw/ullage/README.md, /Users/grossetti/sw/ullage/docs/ROADMAP.md (X7 close-out)

## Options (owner decisions)

1. Plume visibility in vacuum.
   - Default: physical. J-2, SPS and RCS plumes are faint, the J-2 shows no Mach disk in flight, and the cue that an engine is running is the glow of the SPS's radiation-cooled nozzle extension plus the near-exit glow.
   - A "readable plumes" setting restores M1.5's 0.3 floor (decision 19).
   - Alternative: keep the floor as the default.
2. Short events at time warp.
   - Default: above 10x, the flashes of the retros, pyros and J-2 start are held on screen for at least 3 real frames, so staging is visible.
   - Alternative: strictly simulation time; at 100x the 0.64 s retro burn is then often missed.
3. Where the plume physics lives.
   - Default: OrbitCore (pure functions with Linux tests, so cloud sessions can build them).
   - Alternative: app only, which keeps the M1.5 rule but leaves the plume physics untested.
4. Quality preset.
   - Default: chosen automatically by GPU (Medium on base M1 and M2, High on Pro, Max and M3 or later), with auto-downgrade, and selectable in a Graphics menu.
5. Smoke compositing.
   - Default: weighted-blended OIT at half resolution. It is order-independent and keeps golden frames reproducible.
   - Alternative: sorted alpha, which is more exact but costs more and is non-deterministic.
6. Smoke self-shadowing (Fourier opacity maps).
   - Default: deferred, at +2–3 d. Puff normals and plume underlighting are used instead.
7. Pad effects before an LC-39A model exists.
   - Default: anchor them to the geodetic pad, with the trench exits taken from the LC-39 plan (L), and refine when the pad lands.
8. Extras.
   - Default in: the exhaust trail driven by the sounding winds (+0, part of X4), the SM breakup (+0.5 d) and the CM RCS dump (+0.5 d, timing L).
   - Default deferred: the transonic condensation collar (+1.5 d), until launch-day humidity is found; the dye patch, which goes with the ocean track; the S-IVB LOX dump, which goes to M2 with TLI.
9. A holddown and ignition scenario from T−8.9 s, with the 1-2-2 start pattern.
   - Default: yes, if the Saturn track takes the core part (+1.5 d core, +1 d effects). It is what shows the start clouds and deluge.
   - The F-1 TEA-TEB green start flash is optional and off until it is confirmed on the E-8 film.
10. Ice slabs.
   - Default: tumbling instanced meshes.
   - Alternative: sprites only.
11. CEA data.
   - Default: run nasa/cea outside the repo and commit the input decks and generated numbers with source notes; never vendor CEA, RocketCEA or Combustion Toolbox.

## Effort

Focused session-days:

| Track | Where | Days | What drives the range |
|---|---|---|---|
| P0 Seams | core on Linux, hook on Mac | 0.75–1 | +2–3 d if the renderer-foundation track does not provide HDR, the resolved and half-resolution depth, the volume target and the upsample |
| X1 Core exhaust physics and data | Linux | 3–4.5 | Transcribing pc, ε and lip angles; building and running nasa/cea; checking Simons and Lewis–Carlson against the original papers; unknowns for the solid motors |
| X2 Volumetric plumes | Mac | 5–8 | Art iterations against reference footage; performance tuning on base M1; whether the interim LDR path is needed |
| X3 GPU particle core | Mac | 4–6 | WBOIT and depth-aware upsample shared with the foundation or built here; the self-test harness |
| X4 Launch effects | Mac | 4–6 | Pad geometry; the trail ribbon; tuning the steam look. The collar adds 1.5 d |
| X5 Staging and spacecraft | Mac | 3.5–5 | The number of distinct events and debris tuning |
| X6 Entry and recovery | Mac, with 0.75 d of core on Linux | 3–5 | Plasma colour and wake calibration against S69-15592; Apollo 7 window fitting. The RCS dump and dye add 1 d |
| X7 Integration | Mac | 2–3 | Owner review loops; the warp and performance matrices |

Totals:
- Whole area: about 25–38.5 d.
- Core set without the collar, RCS dump, dye or S-IVB dump: about 22–33 d.
- With three sessions in parallel after P0 and screenshots taken in turn on the Mac: about 10–14 working days of calendar time.
- The holddown and ignition option adds 2.5 d.

## Risks

- The foundation dependency. Without HDR, a resolved depth and half-resolution targets, plumes clip at 8 bits and smoke cannot absorb light. Mitigation: X2's interim full-resolution premultiplied path, and P0 builds the minimum if the foundation slips (+2–3 d).
- Hot core files. The journal hooks touch Simulation.swift and SimulationStaging.swift, so they land in P0 only. ExhaustLibrary keys on names, so renaming a part or thruster silently drops its plume; ApolloExhaustTests guards this.
- Data gaps (graded L):
  - which F-1 pc the model should use (injector end about 1,125 psia, or nozzle stagnation about 982 psia);
  - the nozzle lip angles;
  - the turbine-film fraction and temperature;
  - the solid motors' pc, ε and Al content;
  - the LC-39 trench geometry;
  - launch-day humidity, needed for the collar;
  - the CM RCS dump timing.
  The plume structure is only as good as these values; the visual calibration hides this but must not be presented as measured.
- Approximations. The correlations (Lewis–Carlson, Pack, Simons, Billig, Tauber–Sutton) are engineering approximations used outside their calibrated ranges, such as clustered engines and plumes with external flow. Tests check consistency, not imagery.
- Performance on base M1 at Retina resolution: the pad close-up is the worst case, bound by overdraw. Mitigation: the caps, LOD, half-resolution rendering and the auto-downgrade.
- Shaders. Longer runtime-compiled shader strings slow startup. Mitigation: separate libraries compiled asynchronously, with an impostor fallback until they are ready.
- Precision. Particles must stay relative to their anchors. A missed rebase shows up as jitter at 7.8 km/s or as drift at warp.
- Time warp. Very short events can still be missed between frames if the journal edge detection is bypassed. The persistence option is a stylisation, not physics.
- Determinism. Golden frames need order-independent blending, seeded random numbers and a fixed visual dt; GPU float differences between chips can still require per-machine baselines.
- Test-suite time. Any test that flies the ascent adds minutes to the 15–18 min suite. Keep the new tests analytic, and reuse E1's entry path for the plasma window.
- Shared Mac. Parallel Mac sessions contend for the GPU and the screen during harness runs, so performance numbers taken at the same time are invalid.
- Taste loops. Matching footage is subjective, and owner review cycles dominate X2, X4 and X6.
- Scope creep into neighbouring tracks: pad geometry, the ocean decals, the material light term and the cloud composite order all need agreed interfaces before work starts.
