> Planning document for the M1.5 close-out, milestone M1.6 (graphics overhaul) and M2 (Apollo 8), written on 2026-10-20 by a design study (six design reports checked by a planner) and accepted by Franz on 2026-10-21 with all recommended defaults (US keyboard). Track briefs refer to it. Where code has moved on, the code wins.

# Plan: close M1.5, overhaul the graphics (M1.6), fly Apollo 8 (M2), then build the LM

This plan merges the six design reports and checks them against main at 6a1851b. The checks used `git`, `grep` and `gh pr view`, and the session read the code itself; nothing was built or changed. Days are focused session-days (d). Defaults are in **bold**.

## Report checks (what this plan changes)

**Confirmed against main (6a1851b)**
- **Tests:** there are 339 OrbitCore and 26 OrbitInstruments test functions (365), in 48 core test files. Package.swift has no app target or render test target.
- **Debris and time warp:**
  - `isPassive` requires dynamic pressure under 1 Pa (StepControl.swift:28-31). Any debris still in the air therefore forces 0.02 s steps on every vessel.
  - Once separated, the spent S-IC and S-II, the SM and the SLA panels match no `AerodynamicModel` (AS506Data.swift:1101-1130), so they have drag only, with no moments. The spent S-IVB's own model is drag along the wind. The audit's relaxed step for debris is therefore safe.
  - PR #35 records 753-787× while the panels re-enter.
- **Unfinished M1.5 checks:**
  - No M1.5 PR records a Linux run.
  - PRs #33, #35 and #36 were merged without review.
  - Their images link to screenshot branches that no longer exist on origin. The local branches `m15-integration-screenshots` and `m15-mfd-screenshots` still exist.
  - The worktree `.claude/worktrees/m15-csm-staging-9c75e0` is stale.
  - There are 22 local `dev/*` branches.
- **Renderer:**
  - One MSL string is compiled into one library (Renderer.swift:94-96). The drawable is bgra8Unorm_srgb, with MTKView-owned 4× MSAA and reversed-Z.
  - The renderer holds `weak var model: AppModel` and runs `model.tick` inside `draw` (:21, :237).
  - Scenarios.swift and Camera.swift import only Foundation and OrbitCore, so they can move to a target that builds on Linux.
- **Shapes:**
  - VisualShape has three kinds, and its vertex is position and normal only (VisualShape.swift:8-19, 42-46).
  - ApolloShapes.swift is 532 lines, and the whole look is ten colour constants (:225-228).
- **Guidance seams:**
  - The IU's time bases end at T5 (SaturnIU.swift:88-89).
  - CMEntryProgram.swift:23-24 and ApolloSCS.swift:27 leave constant-g guidance to M2, and P40 and the CMC to M3.
- **Hardware:** the owner's Mac is an Apple M3 Pro (18-core GPU, Metal 4) with 36 GB and a 3024×1964 display. Its only planet texture is `earth.jpg`: Blue Marble Next Generation (BMNG), July 2004, 5400×2700, with SOURCES.txt.
- **README:** line 40 already gives `swift run -c release OrbitSim`. Its Xcode instruction ("press Run") still runs Debug, which is about 10× slower per step, so A5 is still needed.

**Conflicts between the reports, and how this plan resolves them**
1. **Four foundation tracks** (renderer-core R0, earth-moon P0, plumes B, vehicle-look V0b) become one Mac track, **F0**, which owns every shared renderer file.
   - V0b's per-part mesh cache and vessel pass move to R2.
   - The vessel-gallery environment variable is dropped in favour of `orbitsnap` shot specs.
2. **Vertex layout** (48 bytes packed, or 64 bytes as float4s): **64 bytes, four float4s**, declared once in F0's ShaderCommon:
   - position and AO;
   - normal and the packed material, paint and decal ids;
   - tangent and sign;
   - station u (m), azimuth v (rad), local radius r (m) and profile arc s (m).
   At about 250k vertices this is about 15 MB. Packing is an R7 option only if memory demands it.
3. **VisualShape.swift** was claimed by both vehicle-look V0a and renderer-core R2. Track **K0** is its only editor; R2 consumes it.
4. **Material schema** was duplicated (OrbitCore/Vessel/Appearance and OrbitScene/Look/Materials). There is one table, `OrbitScene/Appearance/SurfaceMaterial` (VM2); the BRDF maths stay in `OrbitScene/Look` (R2).
5. **Event plumbing.** Renderer-core derives transitions by diffing frames, while plumes needs a core journal.
   - At 100× a frame covers about 1.7 s, and the S-IC retros burn for 0.64 s. At 1000× a frame covers about 16 s. Diffing loses both the event and its epoch.
   - **The core EffectJournal (K0) is the source of events**, and SceneExtractor drains it. Diffing remains only as a fallback for vessels appearing or disappearing.
6. **Depth resolve filter** in reversed-Z (`.min` or `.max`): **`.max`, the nearest sample**, so clouds and transparents never draw over a vessel's edge samples. F0 adds a golden of a vessel edge against cloud to check it.
7. **Graphics inside M2** (Apollo 8 report) or **a separate graphics milestone** (audit): a **separate M1.6**, which matches the owner's order. Moon rendering moves to M2: only Apollo 8's lunar orbit uses it, and its photo match (Earthrise) needs M2's scenarios built from the reconstructed trajectory.
8. **The Sun's luminance:** 1.6e9 cd/m² (earth-moon) is a ground-level value; 1.9e9 (renderer-core) is E⊙/Ω⊙ above the atmosphere. R1 pins the second in a test, and A2's transmittance yields the first.
9. **Where pure-Swift visual code lives** (a new CLAUDE.md rule):
   - **OrbitCore** keeps what the simulation reads or physics tests use: VisualShape geometry, ApolloVariant and attachments, the EffectJournal, exhaust and plume physics, atmosphere optics, and the cube-sphere tile format.
   - **The new OrbitScene target** takes what only the renderer reads: photometry, BRDF, shadow fitting, AO, paint and decals, the flag and font, the cloud field, LOD selection, lunar photometry, scene extraction and snapshot specs.
   - Editing a paint table then never recompiles OrbitCore.

**Under-scoped in the reports**
- **The launch pad.** No report covers the Mobile Launcher (ML), the Launch Umbilical Tower (LUT), the swing arms, the hold-down arms or the flame trench. Yet the pad effects need anchors, the shadows need casters, and the tower dominates every launch photograph. This plan adds track **LC** (4-6 d, mostly Linux geometry).
- **The ocean.** Earth-moon left near-surface waves optional, but the black sea at splashdown is M1.5's most visible defect, and the splash crown and dye need a water surface. They are **in E2 by default** (+1.75 d).
- **The test gate.** The suite takes 1,111 s in Debug, run serially. About 35 parallel sessions will each pay that at merge, so the close-out's fast gate (CO1) lands before anything else.
- **Golden churn.** Many tracks change the same scene goldens, so §4 sets a policy for them.
- **GPU contention.** Mac sessions running at the same time disturb each other's timings (project memory). `orbitsnap` images are deterministic, and performance runs and harness flights take a lock file.
- **Save/load.** A 147-hour mission needs it, but the Apollo 8 report covers it only with scenarios that start each leg. Those **leg scenarios** are M2's answer; save/load stays under Engine and tooling.

**Over-scoped: cut or deferred**
- **Renderer:** EDR, lens looks, the FFT starburst, MetalFX and dynamic resolution are not built in M1.6. The estimate is 8-11.5 ms on the M3 Pro, so the quality tiers and the budget alarm suffice. Renderer-core's look-dev kit (R8) folds into F0b and GI. This saves 2.5-4 d.
- **Earth:** airglow, the CORONA inset and assimilating ESSA imagery are off by default. Moon terrain, horizon maps, the LDEM_256 band and Earthrise move to M2.
- **Effects:** the transonic condensation collar, the S-IVB LOX dump (M2), smoke self-shadowing, and the scenario from T−8.9 s (its core part is in SaturnIU, which M2's T8 owns) are deferred.
- **Vehicles:** AS-501/502 and the Block I CSM are datasheet rows only.
- **TN D-6844**, the earlier study's source for optical properties, does not resolve to such a report. Neighbouring numbers are Apollo Experience Reports: D-6845 (LM instrumentation) and D-6846 (LM descent and ascent mission planning). Drop it and use TN D-6863 (Apollo 9 coatings) and TN D-7564 (thermal protection).

**Sources checked in this pass**
- [nasa/cea](https://github.com/nasa/cea): Apache-2.0.
- [google-research/arco-era5](https://github.com/google-research/arco-era5):
  - the 0.25° analysis-ready store `ar/full_37-1h-0p25deg-chunk-1.zarr-v3` has `low_cloud_cover`, `medium_cloud_cover`, `high_cloud_cover` and `cloud_base_height`;
  - its README says both 1940 and 1979 for the start date, so C1 must read `valid_time_start`.
- ERA5 licence, CC BY 4.0, with the attribution line "contains modified Copernicus Climate Change Service information [year]": [CDS dataset page](https://cds.climate.copernicus.eu/datasets/reanalysis-era5-single-levels), [ECMWF citation guidance](https://confluence.ecmwf.int/x/l-xCDQ).
- TN D-6845 and D-6846: [UNT catalogue](https://mocat.library.unt.edu/catalog/932-12219/citation), [NASA Apollo Experience Reports list](https://www.nasa.gov/wp-content/uploads/static/history/alsj/ApolExpRpts.html).
- Mobile Launcher support geometry: [Balke 1976, NTRS 19760012109](https://ntrs.nasa.gov/api/citations/19760012109/downloads/19760012109.pdf).
- LUT overview (secondary): [apollomaniacs](https://apollomaniacs.com/apollo/mobile_launcher_en.htm).

## M1.5 completion

M1.5 meets its definition of done except two parts of DoD 3: the Linux run and the owner's screenshot review. It also misses one plan criterion: 1000× warp within 10% of M1 while debris re-enters. The close-out takes about 2-2.75 session-days, or 1.5-2 calendar days.

| # | Must-fix | Effort | Done when |
|---|---|---|---|
| A1 | `swift test` on Linux, on main and on the close-out tip | 0.25 d, +0.25-0.5 if anything fails | Counts pasted in the PR (OrbitCore 339+, OrbitInstruments 26+) |
| A2 | Franz reviews the screenshot sets of PRs #33, #35 and #36 and checks the keys on a US keyboard | 0.05 d + about 30 min of Franz's time | Date in ROADMAP's DoD; local screenshot branches deleted |
| A3 | Debris in the air stops holding the warp down | 0.75-1 d | See below |
| A4 | Fast test gate | 0.5 d | Both modes pass the same set of tests; wall times recorded (target ≤ 5 min fast) |
| A5 | README: run the **Release** scheme from Xcode | 0.05 d | — |
| B2 | Recovery target on MAP (Apollo 7's 29.8° N 67.0° W) and range to target on ENTRY | 0.25 d | MFDPagesTests |

**A1 notes.** Run it in a cloud session. The likeliest failures are the `String(format:)` assertions in OrbitInstrumentsTests and the `Bundle.module` lookup for landmask.bin.

**A2 notes.** The PR images now return 404, so review from the local screenshot branches or the session notes folders.

**A3, the change:**
- `isPassive` drops its dynamic-pressure clause.
- A passive vessel in the air takes h = min(1 s, 1 rad/ω, 0.02·|v_air|/|a_drag|, 0.1·H/|ḣ|).

**A3, done when:**
- the global step stays at 0.5 s or more while four panels re-enter;
- a panel lands within 2 km of where a 0.02 s reference run lands it;
- the §17 residuals are bit-identical;
- the Release harness holds 950× or more in every 10 s window over 3 h of GET (today 753-787×).

**A4, the change:**
- `scripts/test.sh fast` runs `swift test -c release -Xswiftc -enable-testing --parallel`; `full` runs Debug, serially.
- CLAUDE.md and the session-start hook warm the fast configuration.
- Diff the §17 residual printout once between the optimised and Debug builds.

**Close-out sessions**
- **CO1** (A4 and A5; Mac; branch `m15-closeout-tests`) merges first, because every later gate uses it.
- **CO2** (A1; cloud; `m15-linux-check`) can start immediately with the plain serial command.
- **CO3** (A3; Linux, plus a Release harness check on the Mac; `fix-debris-reentry-warp`):
  - It touches StepControl.swift and a new DebrisStepTests.swift only.
  - **No per-vessel substepping**, so that Simulation.swift stays free for K0's journal hooks.
- **CO4** (B2; Mac; `m15-recovery-target`).
- A final docs commit records the sign-off date and adds a close-out note to ROADMAP's M1.5 section.

**What rolls forward**

| Item | Goes to |
|---|---|
| Stars over the daylit sky (B1) | R1: photometric stars vanish when exposure is set for daylight |
| Planet-texture fetch script (B4) | E1's `fetch_planet_data.sh` |
| Ocean | E2 |
| S-IC fins and fairings, `.plate` primitive | K0 and VG1 |
| Paint and markings | VM1 |
| Plasma sheath | P6 |
| Clouds and night lights | C2 and E2 |
| Staging particles | P3-P5 |
| HDR, tone mapping and shadows | R1 and R4 |
| Settable camera FOV | F0 |
| Landing point for the planned deorbit burn (B3) | M2's N8, with TEI targeting |
| The Apollo 7 accepted deviation | M2's CMC entry guidance (E8) |
| Apollo 4 Mach-6 trim; transcribing TN D-6725 | M2 (E8) |
| SPS series feed | M2 (C8) |
| The CSM's lateral CG on the launch vehicle | M2: one §17 re-baseline with AS-503 data, in V8 |
| Placeholders: apsUllageIsp first, then the S-IVB J-2 gimbal rate, cant ramp rate, SE-8 Isp, L-graded SPS/RCS geometry | M2 |
| S-IVB restart, venting and LOX dump | M2 |
| Window and cockpit views | M2, with Earthrise |
| LM visuals | M2.5 (Apollo 8 flew LTA-B, not an LM) |
| Not needed | Polar motion, the geoid, the Fischer datum shift, the SM RCS 10° cant (until M3 systems), sound, flyable aborts (option), the autopilot following the speed mode |

## Roadmap

The order is:
1. the M1.5 close-out;
2. **M1.6, the graphics overhaul**;
3. **M2, Apollo 8**;
4. **M2.5, the Lunar Module (Apollo 9-11)**;
5. M3, unchanged (CLAUDE.md's open AGC decision refers to it).

M2's tracks that run only on Linux may overlap M1.6 (owner decision 2).

### M1.6 — Graphics overhaul: the Saturn V and the CSM finished, from the pad to splashdown

**Items**
- **Render foundation:**
  - an `OrbitScene` target (pure Swift, Linux) and an `OrbitRender` target (macOS only);
  - a pass graph;
  - an `orbitsnap` tool for offscreen snapshots;
  - golden images.
- **Renderer:**
  - HDR in photometric units, auto exposure and a Hasselblad photo mode, AgX tone mapping and bloom;
  - physically based materials;
  - image-based lighting (IBL), including earthshine from the rendered Earth;
  - sun shadows from 1 m to 110 m, and baked AO.
- **Vehicle exteriors:**
  - Vehicles: AS-506 and AS-503 (with LTA-B), plus CSM-107, CSM-103 and CSM-101.
  - Geometry:
    - fins, fairings, tunnels, ullage and retro fairings;
    - the F-1 and J-2 in flight configuration;
    - the LES truss and canards, and the boost protective cover (BPC);
    - SM radiators, RCS quads and the high-gain antenna (HGA);
    - CM windows and Kapton.
  - Markings: roll patterns, "UNITED STATES" and "USA", flags.
  - State-driven looks: pad frost and entry char.
- **LC-39A:** the Mobile Launcher, the LUT with its swing arms, the hold-down arms and the flame trench.
- **Earth:**
  - Hillaire's atmosphere, from the ground to space;
  - volumetric clouds from each mission's historical weather (ERA5), in three regimes;
  - BMNG 500 m imagery by month, through a cube-sphere tile store;
  - ocean glint and splashdown waves;
  - 1968 night lights.
- **Plumes and particles:**
  - Exhaust physics (flow regime, boundary angle, shock cells, Mach disk, far field) drives ray-marched plumes for each engine family.
  - GPU particles cover:
    - launch: pad steam, ice shedding, the exhaust trail;
    - staging: cutoffs, retros, ullage motors, separations, LES jettison, the SLA panels;
    - spacecraft: SPS and RCS puffs;
    - entry and recovery: the plasma sheath, ablation sparks, SM breakup, ELS mortars and splashdown.
- **Frame pacing and quality tiers.**

**Definition of done**
1. Every shot in `docs/look/shots/m16-*.json` renders through `orbitsnap` in Release at High, and Franz has signed off the contact sheet, each shot beside its named NASA photograph (see the shot list under Verification and performance).
2. The M1.5 AS-506 pad-to-splashdown flight still passes its 25 checks in the app at High. Every staging burst is spawned at 1×, 10×, 100× and 1000×.
3. Performance:
   - every pass stays within its budget;
   - 60 fps at 1× at native 3024×1964 on the M3 Pro;
   - 1000× in coast within 10% of M1.
4. No regressions:
   - the §17 residuals are bit-identical, and the Apollo 7 chain is green;
   - `swift test` is green on Linux, including the new OrbitScene tests;
   - `xcodebuild build test` is green on the Mac, including OrbitRenderTests (shader compile, look metrics, goldens).
5. Docs are updated:
   - README: the F9, F10 and F12 controls, the planet-data fetch and the credits;
   - ROADMAP;
   - CLAUDE.md: the new targets, `orbitsnap`, `check-shaders.sh` and the placement rule;
   - THIRD_PARTY_NOTICES.md and `docs/look`.

### M2 — Apollo 8: the Saturn V and the CSM to lunar orbit and back

**Flight items** (as in the Apollo 8 report):
- AS-503 with LTA-B and its launch day.
- S-IVB restart and TLI: TB6/TB7 and TLI inhibit, plus parking-orbit venting.
- CSM separation and the S-IVB slingshot.
- The cislunar propagator and RTCC-style planners on a TRANSFER MFD.
- The GRGM900C lunar gravity field.
- CSM-103, with the SPS series feed and passive thermal control (PTC).
- LOI-1 and LOI-2, ten lunar orbits with LOS/AOS, and TEI.
- The CMC's entry guidance (P63-P67), with constant-g as the backup.
- The lunar MAP and the lunar-return ENTRY display.

**Graphics items:**
- The Moon: LOLA terrain on the tile store, LROC albedo, lunar-Lambert photometry, horizon-map shadows and earthshine.
- Window views and the Earthrise photo match.
- The S-IVB LOX dump and vents.
- Lunar-return plasma.

**Definition of done**
1. Apollo 8 is flown from the pad to splashdown with only the HUD and MFDs, landing within a few n mi of 8.13° N 165.02° W.
2. The Apollo 8 reference chain (legs L0-L10) runs in `swift test`.
3. Earthrise at GET 075:48:39 matches AS08-14-2383 in the Earth's phase, the terminator and the lunar horizon.
4. No regressions: §17 and the Apollo 7 chain are green. Apollo 7, flown by the CMC's guidance, lands within about 10 n mi, which retires the accepted deviation.
5. Docs are updated.

### M2.5 — The Lunar Module (Apollo 9-11)
- Transposition, docking and extraction, with docking ports.
- The LM's descent and ascent stages, and their visuals.
- DOI and PDI.
- Rendezvous, with ALIGN, SYNC and DOCKING MFDs.
- Landing-site terrain detail (LDEM at 59 m, sites in MOON_ME), touchdown and landing gear.
- Apollo 9, 10 and 11.

### M3, Engine and tooling
- M3 is unchanged.
- Cockpit and window views move into M2.
- "Real 3-D meshes (glTF/USDZ import)" is removed, since the vehicles are procedural by construction.
- Scenario save/load and sound stay.
- A new item, "simulation thread", gives 60 fps at full warp throughput.

## Tracks

**Placement rule (added to CLAUDE.md).**
- OrbitCore holds what the simulation reads.
- OrbitScene (pure Swift + Foundation, no `simd`, built and tested on Linux) holds what only the renderer reads.
- OrbitRender (macOS) holds Metal code.
- Each pass is a Swift file plus its own shader file, compiled into its own MTLLibrary with ShaderCommon in front, so a broken shader disables one pass, not the renderer.
- Each track owns its own `docs/look/shots/<track>.json` specs and its own look-dev goldens.

### Close-out (M1.5)
CO1-CO4 are described above.

### M1.6 summary

| Track | Branch | Where | Days | Needs |
|---|---|---|---|---|
| F0 Render foundation | m16-render-foundation | Mac | 3.25-4.5 | CO1 |
| K0 Core seams | m16-core-seams | Linux | 1.5-2.25 | CO1 |
| L0 Linux ortho gallery | m16-ortho-gallery | Linux | 0.75-1 | F0-pkg |
| R1 HDR, exposure, post | m16-hdr-exposure | Mac | 3-4 | F0a |
| R2 PBR and vessel pass | m16-pbr-vessel-pass | Mac + Linux | 4.5-6.5 | F0a, K0 |
| R3 IBL probe | m16-ibl-probe | Mac | 2.5-4 | R1, R2 |
| R4 Shadows | m16-shadows | Mac + Linux | 3-5 | F0a |
| R5 AO baker | m16-ao-baker | Linux | 1.5-3 | F0-pkg |
| R6 Effect slots | m16-effect-slots | Mac | 1.5-2.5 | F0a |
| R7 Frame pacing, tiers | m16-frame-pacing | Mac | 1-1.5 | R1 |
| VD1 Saturn V exterior data | m16-saturn-exterior-data | Mac or networked cloud | 2-3 | — |
| VD2 Markings data | m16-markings-data | Mac or networked cloud | 2.5-4 | — |
| VD3 CSM, LES, SLA, LTA-B data | m16-csm-exterior-data | Mac or networked cloud | 1.5-2.5 | — |
| VG1 S-IC, interstage, F-1 | m16-sic-geometry | Linux | 2.5-4 | K0 |
| VG2 S-II, S-IVB, IU, J-2 | m16-sii-sivb-geometry | Linux | 2-3 | K0 |
| VG3 SLA, LTA-B, SM, CM, LES | m16-csm-les-geometry | Linux | 3-4.5 | K0 |
| VM1 Paint, markings, frost, char | m16-paint-markings | Linux, then Mac | 3-4.5 | K0; R2 for the app half |
| VM2 Materials and relief | m16-materials | Mac | 3-5 | R2 (R3 for final tuning) |
| LC LC-39A set | m16-lc39a-pad | Linux + Mac check | 4-6 | K0; R2 to draw |
| A1 Atmosphere optics | m16-atmosphere-core | Linux | 2-3.5 | CO1 |
| A2 Atmosphere rendering | m16-atmosphere | Mac | 4-7 | F0a, A1 |
| Q Cube sphere and quadtree | m16-planet-quadtree | Linux | 1-2 | F0-pkg |
| E1 Earth tile store and tools | m16-planet-tiles | Mac | 4.5-8 | F0a, Q |
| E2 Earth surface and ocean | m16-earth-surface | Mac | 4.5-7.5 | E1, A2 |
| C1 Cloud field and data | m16-cloud-field | Linux + 0.5 d Mac | 2-4 | F0-pkg |
| C2 Volumetric clouds | m16-clouds | Mac | 7-14 | F0a, C1 (adopts A2 mid-way) |
| SG Surface geometry | m16-surface-geometry | Linux | 0.5-1 | CO1 |
| P1 Exhaust physics | m16-exhaust-physics | Linux | 3-4.5 | K0 |
| P2 Volumetric plumes | m16-volumetric-plumes | Mac | 5-8 | F0a (R1, R6 for tuning) |
| P3 GPU particle core | m16-particles | Mac | 4-6 | F0a, R6 |
| P4 Launch effects | m16-launch-effects | Mac | 4-6 | P3's API; LC anchors |
| P5 Staging and spacecraft effects | m16-staging-effects | Mac | 3-4.5 | P3's API |
| P6 Entry and recovery effects | m16-entry-effects | Mac + 0.75 d Linux | 3-5 | P3's API |
| GI Integration | m16-integration | Mac | 3-5 | all |

### M1.6 briefs

**F0: render foundation.** Mac, 3.25-4.5 d, in three PRs.
- **F0-pkg** (merges by about day 1):
  - Package.swift gains OrbitScene and OrbitSceneTests.
  - It also gains, macOS only, OrbitRender, OrbitRenderTests, `orbitsnap` and an empty PlanetTiles tool target.
  - Nobody else edits Package.swift during M1.6.
- **F0a** must render images identical to main:
  - **Moves:**
    - `Rendering/*` moves into OrbitRender;
    - Camera.swift moves into OrbitScene, with a settable `fovY` and Hasselblad 80 mm and 250 mm presets;
    - Scenarios.swift moves into OrbitScene.
  - **Renderer split:**
    - `SceneRenderer` can render offscreen and reads a value-type `RenderScene`;
    - `ViewRenderer` is the MTKView delegate and calls `model.tick`.
  - **Pass graph:** a `RenderPass` protocol and a `FrameGraph`. Every slot is a stub:
    - P0 prepare, with a compute pre-pass and history targets;
    - P1 opaque;
    - P2 composite;
    - P3 transparent;
    - P4 post;
    - P5 overlay.
  - **Shaders:** Shaders.swift becomes per-module libraries. ShaderCommon reserves the binding table, the LightingUniforms and AtmosphereContext fields, and vertex v2. Stub shader files are handed to their tracks: Planet → E2, Atmosphere → A2, Cloud → C2, Plume → P2, Particle → P3, Entry → P6, Vessel → R2, Post and Star → R1, Shadow → R4, Probe → R3.
  - **Scene data:** RenderScene and SceneExtractor carry sites, emitters, canopies, and transitions drained from K0's journal.
  - **Settings:** `RenderSettings` has one stub sub-struct per track, defined in that track's own file.
- **F0b:**
  - `orbitsnap`:
    - input: a spec JSON;
    - an advance script that calls the same OrbitCore entry points AppModel uses (`met:s`, `ev:<IU log text>`, stage, throttle, autopilot, warp);
    - outputs: PNG, PFM, AOVs, JSON timings, and a `contact.jpg` that a session can Read.
  - A GPU profiler.
  - F9 (debug views), F10 (per-pass timings) and F12 (snapshot).
  - `scripts/check-shaders.sh`.
  - About 8 baseline goldens of today's look.
- **Exit:** goldens identical to main; `xcodebuild build test` green.

**K0: core seams.** Linux, 1.5-2.25 d.
- **VisualShape** gains:
  - surface coordinates (u, v, r, s) and tangents;
  - an indexed `mesh()`;
  - a material key;
  - the kinds prism, plate, torus and box.
- **ApolloShapes.swift** becomes a dispatcher plus `ApolloShapes+{SIC, SII, SIVB, SLA, SM, CM, LES}.swift`, with their ShapeData extensions moved verbatim.
- **ApolloVariant** goes on VesselPart: AS-501/502/503/506; CSM-101/103/107; no payload, LTA-B or LM.
  - Alongside it, `attachments`: retro port, ullage exit, vent, separation plane, frost zone.
  - This is the only seam in Components.swift.
  - The variant is set by one line each in SaturnV.swift and ApolloCSM.swift.
- **The EffectJournal** is a bounded ring of records: liftoff, separation, ignition and cutoff edges per thruster, chute deployment, splashdown and breakup, each with its epoch and state. It is hooked into `Simulation.step`, `stageAll` and the splashdown path.
- **The `ExhaustSpec` type**, with an empty `ExhaustLibrary`.
- **Tests:**
  - the Position I-IV convention against the APS modules;
  - tessellation invariants;
  - journal epochs identical at 1× and 100×;
  - §17 bit-identical.

**L0: Linux ortho gallery.** Linux, 0.75-1 d. It goes in `Tests/OrbitSceneTests/Support`.
- A software rasteriser draws flat-lit orthographic views: Positions I-IV, top, bottom and crops.
- A stored-deflate PNG writer saves them.
- `ORBITSIM_ORTHO_DIR=… swift test --filter OrthoGallery` writes PNGs that cloud sessions open with Read.
- Silhouette helpers (maximum radius against station) serve the VG tests.
- Paint appears once VM1's evaluator lands.

**R1: HDR, units, exposure and post.** Mac, 3-4 d. Owns:
- `Passes/Post/*`, PostShaders and StarShaders;
- `OrbitScene/Look/{Photometry, Exposure, ToneCurves}`;
- THIRD_PARTY_NOTICES.md.

What it builds:
- **Targets:** its own memoryless 4× MSAA rgba16Float targets, with a resolve on Karis-encoded colour; the MTKView drops to sampleCount 1.
- **Units:**
  - pre-exposure;
  - E⊙ pinned from Darula et al. 2005;
  - the Sun's colour from a 5772 K blackbody through the Wyman-Sloan-Shirley colour-matching fits;
  - stars from V magnitude, which retires B1;
  - blackbody glow, replacing Tanner Helland's fit.
- **Exposure:** a histogram auto exposure, plus the manual photo mode.
- **Tone mapping:** AgX (constants ported from three.js, MIT), with PBR Neutral selectable, baked into a 33³ LUT from ToneCurves.
- **Post:** a bloom pyramid, the Sun's visibility, and blue-noise dither.
- **Transition:** a legacy scale keeps the planets readable until A2 and E2 land.

**R2: physically based shading and the vessel pass.** Mac, plus half a day on Linux; 4.5-6.5 d. Owns:
- Shaders/LightingCommon and VesselShaders;
- Passes/VesselPass;
- VesselGeometry: a per-part indexed GPU mesh cache, so separations rebuild draw lists, not geometry;
- `OrbitScene/Look/{BRDF, MipBuilder}`.

What it builds:
- **BRDF:** Lambert diffuse; GGX with height-correlated Smith visibility and Schlick Fresnel; Fdez-Agüera multiscatter from a DFG LUT baked in Swift.
- **Anti-aliasing:**
  - Tokuyoshi-Kaplanyan specular AA;
  - Toksvig roughness mips;
  - phone-wire AA for the LES truss, risers and antennas.
- **Lights:** the Sun's disc as an area light; up to 8 plume lights.
- **Contracts:** the `SurfaceSample` contract for VM1 and VM2; site meshes from LC drawn by the same pass.
- **Replaces** vesselLight's heuristics: earthshine moves to R3, sky light to A2.

**R3: IBL probe.** Mac, 2.5-4 d. Owns EnvironmentProbePass, ProbeShaders and `OrbitScene/Look/SphericalHarmonics`.
- **Each frame:** a 128² radiance cube at the camera target, drawn through the planet's and atmosphere's probe entry points.
- **Derived maps:**
  - GGX-prefiltered mips;
  - a brute-force 16² irradiance cube;
  - SH9 for plumes and particles.
- The Sun is excluded; it is the analytic light.
- A night floor is set relative to the exposure.

**R4: shadows.** Mac, plus maths on Linux; 3-5 d. Owns ShadowPass, ShadowShaders/ShadowCommon and `OrbitScene/Look/ShadowFitting`.
- **Maps:**
  - one orthographic 4096² map per vessel cluster, with a 2R footprint, anchored on the structure origin, snapped to texels, matrices in Double;
  - a detail map around the camera target.
- **Filtering:** PCSS with the Sun's 0.53° disc; casters drawn two-sided.
- **Ground:** the ground-receiver patch is handed to E2's PlanetShaders.

**R5: AO baker.** Linux, 1.5-3 d. Owns `OrbitScene/Look/{AmbientOcclusion, BVH}`.
- 32 cosine-weighted rays per vertex, to 3 m.
- Facets are subdivided to at most 0.5 m.
- Baking uses `concurrentPerform`, in the background per mesh signature, with a fade-in.
- Tested against Howell's coaxial-disc view factor.
- R2 exposes the hook.

**R6: effect slots.** Mac, 1.5-2.5 d. Owns Passes/HalfResTransparent and TransparentComposite.
- Half-resolution min/max depth.
- A premultiplied half-resolution volume target and the weighted-blended OIT (WBOIT) pair.
- A depth-aware upsample.
- Composite order: opaque → clouds → plumes and smoke → composite → additive sparks.
- Clouds and plumes are ordered by front depth.

**R7: frame pacing and quality tiers.** Mac, 1-1.5 d. Owns the step budget in AppModel.swift, the Graphics menu in OrbitSimApp.swift, and `OrbitScene/QualityTiers`.
- **Smooth mode:** step budget = max(4 ms, 16.7 − EMA(other CPU) − 1.5 ms).
- **Throughput mode:** today's 40 ms budget.
- **Tiers:** Low, Medium, High and Ultra, chosen by GPU.
- A late drawable.
- Dynamic resolution and MetalFX are built only if a pass set exceeds 13 ms.

**VD1, VD2, VD3: exterior data.** Mac or a cloud session with network access, no GPU; 2-3, 2.5-4 and 1.5-2.5 d; they start on day 0.
- **`docs/SaturnV-CSM-exterior-datasheet.md`:**
  - VD1, the Saturn V:
    - fins on the diagonals; fairings with paired retro ports; scoops; the heat shield; tunnels;
    - corrugation and stringer counts; APS and ullage fairings; the IU;
    - the F-1 and J-2 in flight configuration.
  - VD3, the spacecraft:
    - CM windows, hatch, RCS ports and Kapton strips;
    - SM radiators, HGA, scimitar antennas and the SPS nozzle bands;
    - the LES truss, canards and skirt, and the BPC;
    - LTA-B.
- **`docs/data/markings/*.csv`** (VD2):
  - one row per region, decal or probe point, each with a NASA photo ID, an azimuth reference and a grade;
  - built with `tools/digitise_photo.py` and `photo_index.csv`;
  - rows for AS-503, AS-506 and CSM-101/103/107 first, AS-501/502 last.
- **Sources:** MSFC-MAN-503/504, the Apollo 8 press kit, the CSM News Reference (facts only), the PDS CSM description, TM X-1243, TN D-6863 and TN D-7564.
- Photos stay outside the repo.

**VG1: S-IC, S-IC/S-II interstage and F-1.** Linux, 2.5-4 d. Owns ApolloShapes+SIC.swift and SICExteriorTests.
- **S-IC:**
  - four fins (plates), and four fairings carrying eight TE-M-424 retro ports, with their scoops;
  - the base heat shield and engine curtains, hold-down fittings, two tunnels, LOX vent fairings.
- **F-1:** the turbine-exhaust-cooled extension, the manifold torus and the insulated shroud.
- **Interstage:** the ullage fairings, with the inner face in zinc-chromate primer.
- It starts on today's data and refines from VD1.

**VG2: S-II, S-II/S-IVB interstage, S-IVB, IU and J-2.** Linux, 2-3 d. Owns ApolloShapes+SII.swift, +SIVB.swift and UpperStagesExteriorTests.
- **S-II:** thrust cone, heat shield, systems tunnel.
- **S-II/S-IVB interstage:** four retro fairings.
- **S-IVB:** faired APS modules at Positions I and III; two jettisonable TX-280 ullage fairings; forward-skirt antennas.
- **IU:** ring details.

**VG3: spacecraft.** Linux, 3-4.5 d. Owns ApolloShapes+{SLA, SM, CM, LES}.swift and CSMExteriorTests.
- **SLA:** panel seams and hinge line.
- **LTA-B:** a boilerplate matched to AS08-16-2582..2584.
- **SM:**
  - radiators;
  - true RCS housings;
  - scimitar antennas;
  - the HGA, stowed and deployed, on CSM-103 and CSM-107 only.
- **CM:**
  - windows;
  - the hatch outline;
  - RCS ports;
  - the docking ring, with the probe on CSM-107 only.
- **LES:**
  - the truss with cross-bracing;
  - the skirt, motors, canards and Q-ball nose;
  - the BPC's cut-outs.
- **Other:** the variant switches. The LM-5 stand-in keeps its geometry until M2.5.

**VM1: paint, markings, frost and char.** Linux first, then Mac after R2; 3-4.5 d. Owns:
- `OrbitScene/Appearance/{Paint, Decal, StrokeFont, USFlag, Markings+SaturnV, Markings+CSM, Frost, Char}`;
- Shaders/VesselPaintShaders and DecalAtlas.swift;
- their tests.

What it builds:
- **Paint regions** from VD2's tables, every row graded.
- **Lettering:** stroke glyphs for "UNITED STATES" and "USA", baked at load into an SDF atlas from the same Swift function the tests use.
- **The flag,** from Executive Order 10834.
- **Frost coverage,** from FER Table 20-1's frost masses.
- **Char,** from `Vessel.heatLoad`, normalised by Apollo 7's entry.
- **`orbitsnap --verify`** compares GPU paint with the Swift evaluator at probe points.

**VM2: materials and relief.** Mac, 3-5 d. Owns `OrbitScene/Appearance/{SurfaceMaterial, SurfaceDetail}`, Shaders/VesselMaterialShaders and DetailMaps.swift.
- **The material table:** albedo from the measured solar absorptance α where sourced; metals' F0 from Rakić's n,k.
- **Analytic relief, band-limited by fwidth:** corrugation, stringers, panel lines, rivets, J-2 tubes and radiator fins.
- **Maps generated at load:** Kapton crinkle, F-1 insulation batts, cork, ablator and soot.

**LC: the LC-39A set.** Linux geometry plus a Mac check; 4-6 d. Owns `OrbitScene/Site/LC39A.swift` and LC39ATests.
- **Representation:** a body-fixed site, not a Vessel, so StepControl is untouched.
- **Geometry:**
  - the ML base;
  - the LUT, as prisms with lattice relief rather than individual beams;
  - nine swing arms, retracting on the T−0 timeline;
  - the hammerhead crane, tail service masts and four hold-down arms;
  - the hardstand, and the flame trench, whose exits are attachments for P4.
- **Data:** MSFC-MAN-503's launch-facility material and Balke 1976 (NTRS 19760012109), graded like the datasheets.

**A1: atmosphere optics.** Linux, 2-3.5 d. Owns `OrbitCore/Bodies/{AtmosphereOptics, AtmosphereLUT}` and their tests.
- **Scattering:**
  - Rayleigh (Bodhaine 1999), on the core's own US-1976 or launch-day number density;
  - aerosol and ozone.
- **LUTs:** transmittance, multiple scattering and ground irradiance.
- **For vessels:** `sunTransmittance(position:sunDir:)`.

**A2: atmosphere rendering.** Mac, 4-7 d. Owns Passes/AtmospherePass, Shaders/AtmosphereShaders and the P2 composite.
- **Inside the atmosphere:** a sky-view LUT and aerial-perspective froxels.
- **From space:** a limb ray march in the planet shader's figure coordinates, with the Earth's shadow in the atmosphere.
- **The Sun:** limb-darkened and transmitted.
- **Shared through AtmosphereContext:** sky irradiance and sun colour for vessels and clouds.
- A probe entry point for R3.

**Q: cube sphere and quadtree.** Linux, 1-2 d.
- `OrbitCore/Bodies/{CubeSphere, PlanetTileFormat}`: the heights stay readable for M2.5's landing.
- `OrbitScene/Planet/PlanetQuadtree`: CDLOD selection, horizon culling, a tile budget, and a motion bias that coarsens LOD under warp.

**E1: Earth tile store and tools.** Mac, 4.5-8 d. Owns OrbitRender/Planet/PlanetTileCache, the `earth` subcommand of tools/PlanetTiles, and `tools/fetch_planet_data.sh` (owner-run, writes SOURCES.txt with sha256).
- **Data:**
  - BMNG 500 m for July and December; October is optional.
  - Natural Earth water, with the 1960s Aral Sea and Lake Chad.
  - ETOPO 2022 relief normals.
  - A Landsat 15 m inset of the Cape, with the Shuttle Landing Facility painted out.
- **Runtime:** an atlas with an indirection texture, background IO, and prefetch along the predicted track.

**E2: Earth surface and ocean.** Mac, 4.5-7.5 d. Owns Passes/PlanetPass, Shaders/PlanetShaders, Planet/EarthLayers and `tools/make_night_lights.py`.
- **Land:** monthly albedo with a procedural detail octave, plus relief.
- **Ocean:**
  - Cox-Munk sun glint, filtered by the pixel footprint;
  - near-surface waves at splashdown (M1.5's design G8c: Schlick Fresnel, 4-6 Gerstner waves, wave phase from double-precision offsets);
  - foam and dye hooks for P6.
- **Night:** the 1968 night-light estimate, in physical units.
- **Shadows on the ground:** clouds from C2, vessels from R4.

**C1: cloud field and data.** Linux, plus 0.5 d on the Mac to fetch; 2-4 d. Owns `OrbitScene/Earth/{CloudField, CloudClimatology}`, `tools/make_clouds_era5.py` and `tools/data/tmx64796_table1_saturn.csv`.
- **Format:** OSCLOUD1, with low, mid and high cover, cloud-base height and layer winds. Hourly for the Earth-orbit phase, 3-hourly after; Apollo 7, in Earth orbit throughout, is hourly on launch day and the last day (decision 29).
- **First job:** read `valid_time_start` in ARCO-ERA5's 0.25° store. If it starts after 1968, fall back to the Copernicus CDS with the owner's own account.
- **Pad truth:** NASA TM X-64796, Table 1, always blended in near the pad around launch (decision 29).
- **Physics:** extinction from liquid water content and effective radius; checked against the two-stream slab reflectance.

**C2: volumetric clouds.** Mac, 7-14 d. Owns Passes/CloudPass, Shaders/CloudShaders and Clouds/CloudNoise.
- **Noise:** generated Perlin-Worley, Worley and curl noise, anchored to a body-fixed noise origin computed in Double.
- **Three regimes:**
  - near field: volumetric at quarter resolution, with checkerboard reprojection;
  - orbit: a slab march;
  - far: a surface layer, from a slab-BRDF LUT generated by the volumetric march. Its optical depth comes from C1's layer model, or from ERA5's cloud water paths if C2 adds them to OSCLOUD1 (decision 29).
- **Cirrus** is a fibrous 2D layer.
- **Outputs for others:**
  - a cloud shadow map;
  - transmittance and front depth for plumes and particles.
- **Under warp:** reprojection turns off at 10× or more, or under fast camera motion.
- **Build order:** far, then orbit, then near, so the near field is the part that can be cut.

**SG: surface geometry.** Linux, 0.5-1 d.
- `OrbitCore/Bodies/SurfaceGeometry`: the subsolar, sub-observer and specular points.
- Tests pinned with DE421:
  - the Sun's elevation at LC-39A for both launches (about 7° for Apollo 8 at 12:51:00 UTC);
  - the Sun below the horizon at Apollo 8's splashdown.
- The Earthrise geometry tests go to M2.

**P1: exhaust physics.** Linux, 3-4.5 d. Owns:
- `OrbitCore/Effects/{NozzleFlow, ApolloExhaust, PlumeModel, FrostShedding, IceSublimation, ParticleKinematics}`;
- `tools/make_exhaust_table.py` and `tools/cea/*.inp` (nasa/cea runs outside the repo);
- `tools/data/cea_apollo_exhaust.csv`;
- `docs/exhaust-datasheet.md`.

The physics:
- **Exit state:** chamber pressure follows the flow, so start and shutdown transients shrink the plume.
- **Flow regime:** Schmucker's separation criterion.
- **Plume structure:**
  - the boundary angle by Prandtl-Meyer;
  - shock cells (Pack; Tam and Tanna);
  - the Mach disk (Lewis-Carlson, cross-checked with Ashkenas-Sherman);
  - Simons' far field;
  - afterburning fading out with altitude.
- **Particles:** an exact integrator for linear drag.

**P2: volumetric plumes.** Mac, 5-8 d. Owns OrbitRender/Plumes.swift (a rewrite), Shaders/PlumeShaders and PlumeLights.swift.
- **Method:** thrusters clustered by family; a convex proxy per cluster; a 16/32/48-step ray march with jitter and early exit.
- **Looks by engine family:**
  - kerosene: soot, plus the dark turbine-exhaust sheath;
  - hydrogen: faint, with a Mach disk only where one forms;
  - hypergolics: nearly invisible, with the SPS extension glowing;
  - solids: aluminium-oxide cores.
- **LOD:** today's impostors and points for small plumes.
- **Lighting:** plume lights for R2.
- **Visibility:** physical in vacuum, with a "readable plumes" toggle.
- It starts on a stub `PlumeState` that reproduces today's look table.

**P3: GPU particle core.** Mac, 4-6 d; its API is frozen by its second day. Owns `OrbitRender/Effects/{ParticleSystem, EffectAnchors, VolumeNoise, EffectDirector, EffectsSelfTest}` and Shaders/ParticleShaders.
- **Precision:** body-fixed and free-fall anchors, kept in Double.
- **Simulation:**
  - atomic free and alive lists;
  - the exact drag integrator, checked against P1's golden vectors;
  - buoyancy, entrainment and sublimation.
- **Three render classes:** additive streaks, WBOIT smoke, instanced chunks.
- **Time:**
  - journal bursts spawn at their true age;
  - continuous emitters emit only over the last lifetime of each frame interval;
  - turbulence clock = real dt × min(warp, 4);
  - flashes are held for at least 3 frames above 10×.
- **Check:** `OrbitSim --selftest effects`.

**P4: launch effects.** Mac, 4-6 d. Owns Effects/{LaunchEffects, ExhaustTrail}.
- The pad exhaust and deluge cloud, pre-aged at scenario start for the 8.9 s of ignition.
- Ice and frost shedding on P1's FER schedule.
- Vapour from the LOX tank and the umbilicals.
- The exhaust-trail ribbon below 40 km, advected by the launch-day winds.

**P5: staging and spacecraft effects.** Mac, 3-4.5 d. Owns Effects/{StagingEffects, SpacecraftEffects}.
- **S-IC:** CECO/OECO tail-off, the retros and the S-II ullage motors, the pyro ring at STA 1564.
- **S-II:** the J-2 start, the interstage ring at STA 1760, the LES jettison, the S-II retros, the S-IVB ullage motors, and the ullage cases jettisoned.
- **Spacecraft:** the SLA pyro seams and cork "fireflies", SPS NO2 puffs, RCS pulses.

**P6: entry and recovery.** Mac, plus 0.75 d on Linux; 3-5 d. Owns Effects/EntryEffects, Shaders/EntryShaders and `OrbitCore/Effects/EntryPlasma`.
- **Plasma:** the shock-layer shell (Billig standoff) and the wake. Their onset and end are calibrated to Apollo 7's blackout, 259:54:58 to 259:59:46.
- **Entry debris:** ablation sparks from the heat flux; the SM's breakup (visual only).
- **ELS:** apex-cover and mortar puffs from the ELS epochs; reefing-cutter pops.
- **Splashdown:** the crown and mist; foam and dye through E2's hook.

**GI: integration.** Mac, 3-5 d. Owns README, ROADMAP, CLAUDE.md, `docs/look/*`, `docs/m16/*`, the help in Views.swift, and the merged shot list.
- It re-blesses the scene goldens at checkpoints.
- It runs the warp and performance matrices, sets the quality defaults, and flies the M1.5 DoD flight in the harness.
- It runs the owner's review rounds and the fix list.

### M2 tracks (refined in a `docs/m2/plan.md` pass before M2 starts)

| Track | Branch | Where | Days | Brief |
|---|---|---|---|---|
| S8 Seams | m2-seams | Linux | 1-1.5 | `CelestialBody.field` and `gravity(at:orientation:)` (Earth bit-identical); TimeBase t6/t7 and `RestartPlan`; `Mission.apollo8`; `MFDModeID.transfer` stub; ApolloFrames (B1969.0); naming contract ("LTA-B", "S-IVB LOX dump", "S-IVB LH2 vent") |
| D8 Data | m2-apollo8-data | Mac or network | 3-5 | Two readers on page images: Mission Report and Supplements 1-2, PFT-503 (D5-15794), FER-503, GE504's out-of-orbit sections, R-577 §5.6, TN D-6725. GRGM900C downloaded to the scratchpad only |
| V8 AS-503 | m2-as503-vehicle | Linux | 3.5-6 | AS503Data deltas, AS503FlightProgram, pad and parking-orbit builders, launch-day atmosphere, LTA-B mass; the one CSM lateral-CG re-baseline of §17 |
| T8 TLI | m2-tli | Linux | 5-8 | OutOfOrbitTargeting; out-of-orbit IGM; SIVBRestart (TB6, 6a/6b/6c); TB7; venting polynomials; slingshot fits; AS-506 TLI first. Optional holddown from T−8.9 s |
| G8 Lunar field | m2-lunar-gravity | Linux | 2.5-4 | GravityField; SphericalHarmonicField (Holmes-Featherstone); `moongrav.bin` to degree 100; adaptive degree; reference CSV from numpy |
| N8 Navigation | m2-cislunar-nav | Linux | 5-8 | CislunarPropagator (DOP853/RKF7(8)), B-plane targeting, FiniteBurn, LOI and TEI planners, LunarVisibility; B3 rides here |
| C8 CSM-103 | m2-csm103 | Linux | 3-4.5 | Mass rows; SPS as flown; four-tank series feed; SCS burn-plan hold, ullage hint, PTC |
| E8 CMC entry | m2-cmc-entry | Linux | 5.5-9 | P63-P67 from R-577 §5.6 (Colossus I); constant-g backup; key 9 modes; radiative heating; Apollo 7 flown by the CMC |
| M8 MFDs | m2-lunar-mfds | Mac | 4.5-7 | TRANSFER, lunar MAP, the SOI flag on ORBIT, lunar-return ENTRY, the HUD strip; planners off the main thread |
| MR1 Moon core | m2-moon-core | Linux + Mac tools | 2.5-5 | `OrbitScene/Moon/{LunarPhotometry, HorizonMap}`; the PlanetTiles `moon` subcommand (LDEM_128 global, LDEM_256 ±20°, WAC Hapke colour); Apollo8GeometryTests |
| MR2 Moon terrain | m2-moon-terrain | Mac | 4-7 | CDLOD with geomorphing on E1's cache; lunar-Lambert; horizon-map shadows; earthshine; far fallback to today's ray-traced sphere |
| AV8 Apollo 8 visuals | m2-apollo8-visuals | Mac | 2-3.5 | Window cameras; Earthrise and whole-Earth matches; LOX dump and vent particles; lunar-return plasma recalibration; night splashdown |
| I8 Integration | m2-integration | Mac | 3-5 | Apollo8ChainTests fixtures; scenarios (pad, parking orbit, before LOI-1, before TEI, CM at EI, Apollo 11 to TLI); harness; docs |

## Dependencies and merge order

**Waves, counted in working days from the start of the close-out**
- **Day 0:**
  - CO1 merges first; then CO2, CO3 and CO4.
  - Franz signs off (A2).
  - VD1-3 start, and so does D8 if M2 overlaps.
- **Days 1-5:**
  - F0-pkg merges by about day 1.5. F0a by about day 4, then F0b.
  - K0 merges by about day 3.
  - After F0-pkg, the Linux tracks start: L0, A1, Q, C1, SG, R5, and P1 (it merges after K0).
- **After F0a and K0 (checkpoint CP1):**
  - Mac: R1, R2, R4, R6.
  - Linux: VG1-3, VM1's core half, LC.
- **Next:**
  - R3 (after R1 and R2); VM1's app half and VM2 (after R2);
  - A2 (after A1); E1 (after Q); C2 (after C1, adopting A2's LUTs mid-way);
  - P2; P3 (after R6).
- **Then:** E2 (after E1 and A2); P4, P5 and P6 (after P3's API freeze; P4 uses LC's anchors or the geodetic pad); R7 (after R1).
- **Last:** GI.

**Merge order**
1. CO1, then CO3, CO4 and CO2's record, then the close-out docs.
2. F0-pkg.
3. K0 and F0a, which are disjoint.
4. F0b.
5. Linux core tracks as ready: L0, A1, Q, C1, SG, R5, P1.
6. R1 and R6.
7. R2, then VM1, VG1-3 and LC.
8. R4, R3, A2, E1, P2, P3, C2 (far and orbit regimes).
9. VM2, E2, P5, P4, P6.
10. C2's near field, R7.
11. GI.

**Critical path for M1.6:** CO1 (0.5) → F0-pkg (0.5) → F0a (2-2.5) → C2 (7-14) → GI (3-5), about 13-22.5 working days. Near-critical chains:
- F0a → R2 → VM2 → GI: 12-17 days.
- F0a → R6 → P3 → P4 → GI: 13-19 days.

**Hot files**

| File | Owner in M1.6 | Later |
|---|---|---|
| Package.swift | F0 (F0-pkg) only | M2's G8 adds the `moongrav.bin` resource line |
| Renderer.swift, Shaders.swift, RenderTypes.swift | F0 splits or deletes them | — |
| ShaderCommon, FrameUniforms, binding table | F0. Change requests are tiny PRs to F0's owner, merged first | — |
| VisualShape.swift, ApolloShapes.swift (dispatcher) | K0. VG1-3 own the element files | — |
| Components.swift | K0 (one seam) | M2's C8 (feed chain), after K0 |
| Simulation.swift, SimulationStaging.swift | K0 (journal). CO3 must not touch them | — |
| StepControl.swift | CO3 | M2's C8 (optional vacuum step) |
| SaturnV.swift, ApolloCSM.swift | K0 (variant line) | M2's V8 and C8 |
| AppModel.swift, Views.swift, OrbitSimApp.swift, Input.swift | F0, then R7 (pacing and Graphics menu), then GI (help) | M2's I8 (keys) |
| Scenarios.swift (moved to OrbitScene) | F0 moves it; GI | M2's I8 |
| README, ROADMAP, CLAUDE.md | Close-out docs, then GI | — |
| THIRD_PARTY_NOTICES.md | R1 creates it; GI finalises | — |

**Rules**
- **Merging** (as in M1.5): test the combined branches in a scratch detached worktree before merging. Merge with plain `gh pr merge N --merge`, never `--delete-branch`. Check that main's tree equals the tested tree.
- **Goldens:**
  - Each track's look-dev goldens are hard tests: material spheres, one plume on black, one cloud slab, one vehicle orthographic view.
  - Scene goldens, which many tracks change, are report-only between checkpoints. Their diffs go into the PR's contact sheet, and GI re-blesses them at each checkpoint.
  - Every Mac PR attaches an `orbitsnap` contact sheet.
- **GPU lock:** performance runs and harness flights take `~/Library/Application Support/OrbitSim/gpu.lock`. `orbitsnap` image runs do not need it, since their output is deterministic.
- **Linux test budget:** new Linux tests add under 60 s to the suite. Any test that flies reuses a shared fixture: P6 reuses the Apollo 7 entry flight.

## Owner decisions

Defaults are in **bold**; "accept defaults" settles all of them.

**Roadmap and process**
1. **Milestones: M1.5 close-out → M1.6 graphics overhaul → M2 Apollo 8, including the Moon → M2.5 LM (Apollo 9-11) → M3 unchanged.**
   - Alternative: graphics inside M2.
   - Alternative: the LM as M3, which means renumbering the AGC decision.
2. **Overlap: M2's Linux-only tracks (S8, D8, G8, N8, C8, E8) start in cloud sessions after CP1 and merge when green. M2's Mac tracks, V8 and T8 wait for CP4.**
   - Alternative: strictly sequential, about 2-3 more weeks to the LM.
3. **Close-out scope: A1-A5 plus B2. B3 rides with M2's N8.**
4. **Debris: drag-limited steps for passive debris in the air.**
   - Alternative: delete panels below 60 km.
   - Alternative: amend the criterion.
5. **Test gate: the fast release-parallel run at merge; the full Debug serial run at milestone close.**
6. **Sessions: 4 Mac + 3 cloud for M1.6.**
7. **Housekeeping: Franz deletes the `dev/*` branches, the local screenshot branches and the stale worktree, or lets a session do it with plain git.**
8. **Programme scope: no Saturn IB launch for Apollo 7, and no Apollo 4/6 Block I CSM. AS-501/502 are markings rows only.**
   - Alternative: Apollo 4/6 visuals (+4-6 d).
   - Alternative: the Saturn IB (+15-25 d, its own milestone).

**Vehicle look**

9. **Vehicles: AS-506 with CSM-107 and the LM-5 stand-in, AS-503 with CSM-103 and LTA-B, plus CSM-101.**
10. **Quality target: photo-match grade at three distances (pad wide shots, staging chase at 10-30 m, CSM close-up at 2-10 m):**
    - **features of 5 cm or more as geometry, smaller ones as relief or decals; about 250-400k triangles;**
    - **dimensions graded H/M/L;**
    - **marking boundaries within ±0.25 m in station and ±3° in azimuth of the digitised photos;**
    - **Franz judges the contact sheets.**
11. **Textures: procedural shading, with decals and maps baked at load from Swift. No photo-derived textures. No NASA insignia (14 CFR §1221). Hand-coded glyphs. The flag from EO 10834.**
12. **Disputed markings: follow 1968-69 colour photos as graded in VD2; Franz rules on the L rows at CP2.**
13. **Kapton and metals: final tuning waits for R3's IBL.**
14. **Pad frost and post-entry char: both.**
15. **LTA-B: a simple boilerplate.**
16. **HGA: deploys at CSM separation; canards stay stowed.**
17. **Pad: a mid-fidelity LC-39A set.**
    - Alternative: a bare pad slab, saving 3-4 d.
18. **Reference photos: one approved download of about 40-60 NASA photos into `~/Library/Application Support/OrbitSim/LookRefs`, never committed.**

**Renderer**

19. **Code layout: OrbitScene + OrbitRender + `orbitsnap`, plus the placement rule.**
    - Alternative: keep everything in OrbitSim, which means no Linux tests of the look maths and no offscreen tool.
20. **Goldens: 640×400 PNGs per GPU family in git (about 5 MB).**
21. **Tone mapper: AgX, with PBR Neutral selectable.**
22. **Exposure: an auto-exposing physical camera plus a manual Hasselblad photo mode; a night floor relative to exposure; no exposure hold during warp.**
23. **EDR and lens looks: not built in M1.6.**
24. **Frame pacing: Smooth (60 fps), with Throughput selectable.**
    - In Smooth, powered-flight warp is about 30% lower; coast warp is unchanged.
    - A simulation thread comes later (3-5 d).
25. **Shadows: two-level PCSS with the Sun's disc.**
26. **AO: baked per vertex in Swift.**
27. **Deployment target: stays macOS 14.**

**Earth**

28. **Atmosphere: Hillaire 2020, with its LUTs built in OrbitCore on the simulation's own atmosphere.**
    - Alternative: Bruneton 2017.
29. **Cloud data: ERA5 for each mission's dates (CC BY 4.0, owner-run fetch, not committed), plus procedural detail and the pad sky from TM X-64796. A zonal climatology is bundled as the fallback.**
    - Settled by Franz at C1's review (PR #50):
      - **The bundled climatology is ERA5-derived:** the small zonal table in `CloudClimatology.swift` is committed with its CC BY attribution line, and README credits it. Only the mission fields stay uncommitted.
      - **Apollo 7's field is hourly on launch day and on the last day, and 3-hourly between** (110 snapshots, 514 MB). Hourly throughout would be 262 snapshots and 1.2 GB.
      - **The pad override is always blended in** near the pad around launch, not only where it disagrees with ERA5. A threshold would make the sky jump where ERA5 crosses it.
      - **Cloud water paths are deferred to C2:** ERA5's total column liquid and ice water can be added then as extra OSCLOUD1 planes, which the format already allows.
30. **Cloud fidelity: all three regimes, with the near field built last.**
    - Lean: orbit and far regimes plus a 2D sky from the pad, saving 3-4 d.
31. **Earth imagery: BMNG 500 m for July and December, through the tile store, plus a Landsat Cape inset with the Shuttle Landing Facility painted out.**
    - Alternative: a single 16k texture, saving 5 d now but requiring rework in M2.
32. **Night lights in 1968: a modelled 1968 estimate.**
    - **Black Marble 2016, scaled per region by the GHSL 1975/2015 built-up ratio, with the gas flares active in 1968 kept.**
    - **Labelled "estimate" in Help.**
    - **Visible only when exposure adapts to the night side.**
    - No measured 1968 map exists: digital DMSP data start in 1992.
    - Alternatives: none at all; or modern Black Marble labelled anachronistic.
33. **Historic hydrography: the 1960s Aral Sea and Lake Chad.**
34. **Ocean: glint from orbit plus waves near splashdown.**
35. **Extras (airglow, ESSA assimilation, CORONA inset): none.**

**Plumes and particles**

36. **Plume fidelity: ray-marched once on screen at 48 px or more, for the F-1, J-2, solids and SPS, with structure from PlumeModel. The RCS uses impostor puffs. Physical visibility in vacuum, with a "readable plumes" toggle.**
37. **Plume physics in OrbitCore/Effects, tested on Linux.**
38. **Flashes held for at least 3 real frames above 10×.**
39. **Smoke: WBOIT at half resolution; no self-shadowing.**
40. **Ice slabs: instanced tumbling meshes.**
41. **Extras in: the exhaust trail, the SM breakup and the CM RCS dump. Deferred: the condensation collar, the S-IVB LOX dump (M2) and the T−8.9 s holddown (M2's T8).**
42. **CEA: nasa/cea (Apache-2.0) runs outside the repo; only the input decks and the numbers are committed.**
43. **Quality presets: chosen automatically by GPU (High on the M3 Pro), in a Graphics menu, with auto-downgrade after 2 s over budget.**

**Apollo 8 (M2)**

44. **AS-503: an event-level variant, checked with bands against FER-503 and PFT-503.**
    - Alternative: a full §17-style residual closure (+6-10 d).
45. **Entry guidance: the CMC's P63-P67 equations in Swift (R-577 §5.6, Colossus I) as the default, with 4 g constant-g as the EMS backup. They remain the no-AGC mode and a test oracle if M3 emulates the AGC.**
    - Alternative: constant-g only, saving 5 d. It lands 50-100 n mi off and keeps the Apollo 7 deviation open.
46. **Lunar field: GRGM900C to degree 100, adaptive by altitude.**
47. **Moon data: LOLA LDEM_128 globally plus LDEM_256 within ±20°, with Hapke-normalised WAC colour. Never the morphologic mosaic.**
48. **Burn planning: RTCC-like planners on TRANSFER with SET.**
49. **SPS ignition: the pilot presses Z, the EMS counter cuts off, and the SCS holds the planned attitude.**
50. **S-IVB slingshot: modelled.**
51. **The CSM's lateral CG: one §17 re-baseline, in V8.**
52. **Save/load: leg scenarios only.**
53. **Data: downloads to the scratchpad only; the transcriptions and the truncated `moongrav.bin` are committed.**

**Performance**

54. **Targets:**
    - **60 fps at 1× at 3024×1964, High, on the M3 Pro, with every pass within its budget;**
    - **1000× in coast within 10% of M1;**
    - **200× or more in powered flight, Release, Smooth;**
    - **the base M1 is estimated only: there is no such hardware to gate on.**

**Data and licences**

| Source | Licence | Use and storage |
|---|---|---|
| NASA reports, photographs and the Apollo 8 Mission Report | Public domain (US Government) | Data and references, credited. Photos stay outside the repo |
| BMNG, Black Marble, ETOPO 2022, Landsat, Natural Earth, LOLA/LROC | Public domain | Fetched by the user into Application Support, with SOURCES.txt and sha256 |
| ERA5 (ARCO-ERA5, or the CDS) and JRC GHSL | CC BY 4.0. Attribution line: "Contains modified Copernicus Climate Change Service information [year]" | Fetched by the user; credited in README and Help; derived files not committed |
| GRGM900C (PDS) | No restriction | The truncated binary (about 82 KB) is committed in M2 |
| three.js AgX | MIT | Notice in THIRD_PARTY_NOTICES |
| Khronos PBR Neutral, Filament | Apache-2.0 | Reimplemented from the formula, credited |
| Hillaire, Bruneton | MIT, BSD-3 | References; notice kept if any code is ported |
| nasa/cea | Apache-2.0 | External tool only |
| refractiveindex.info | CC0 | Metal n,k values, crediting Rakić |

**Do not use:**
- NASSP (GPL);
- Virtual AGC's own software (GPL); the AGC listings may be read as a specification only;
- KSP's Scatterer (GPL-3), Orbiter's D3D9Client (LGPL), KSP assets and mods;
- Shadertoy code (CC BY-NC-SA by default), the MERL BRDF database (non-commercial), RocketCEA;
- model-kit decal sheets, David Weeks's drawings, the Saturn V News Reference's figures (facts only);
- Sentinel-2 cloudless (non-commercial parts), GSHHG (LGPL);
- SLDEM2015 until its Kaguya terms are checked.

## Verification and performance

**Linux (`swift test`; new tests under 60 s in total)**
- **K0:**
  - closed shapes watertight, wound counter-clockwise, tangents orthonormal;
  - the Position I-IV convention;
  - journal epochs identical at 1× and 100×;
  - §17 bit-identical.
- **VG1-3:**
  - overall height 363 ft;
  - the LES 33 ft long and 4 ft across at the base;
  - the SLA 28 ft, 260 to 154 in;
  - the HGA dish 79 cm, on CSM-103 and CSM-107 only;
  - the Q-ball 13.37 × 13.3 in;
  - fin span about 63 ft (secondary source until VD1 sources it);
  - 8 S-IC retro ports;
  - S-II ullage fairings: 4 on AS-503/506, 8 on AS-501/502;
  - APS modules at Positions I and III;
  - tunnel counts of 2, 1 and 1;
  - silhouettes through L0.
- **VM1:**
  - the paint probes from the CSV files;
  - SA-500F-only features absent;
  - the EO 10834 proportions;
  - glyph coverage of "UNITED STATES" and "USA";
  - frost integrals equal to FER Table 20-1 within 1%.
- **R1-R5:**
  - blackbody luminance 6.0e5 cd/m² at 2041.4 K (the 1948 candela definition);
  - CIE illuminant A chromaticity at 2856 K within 0.002;
  - "sunny 16": EV ≈ 15;
  - AgX and Neutral at transcribed points, and monotonic;
  - white furnace ≥ 0.98;
  - aluminium F0 of 0.91-0.92;
  - irradiance at 185 km against Howell's factor within 3%;
  - shadow footprints contain the cluster, and whole-texel moves leave the map unchanged;
  - AO against the coaxial-disc factor.
- **A1:**
  - Rayleigh optical depth 0.0971, 0.243 and 0.0410 at 550, 440 and 680 nm, within 1.5% (Bodhaine 1999);
  - 300 DU of ozone;
  - air mass 5.59 at 80° (Kasten-Young) within 3%;
  - the Sun visible from 10 km at −3.0° elevation but not at −3.5°.
- **C1:**
  - extinction 0.075 /m at 0.5 g/m³ and 10 µm;
  - slab reflectance R(τ = 10, g = 0.85) = 0.43;
  - AS-503 reads 4/10 cirrus.
- **Q:** each visible tile covered exactly once; horizon culling; the motion bias.
- **SG:** both launch-day Sun elevations; the Sun below the horizon at Apollo 8's splashdown.
- **P1:**
  - NACA 1135 at γ = 1.4: M = 2 gives 1.6875, 0.1278 and 26.38°; M = 3 gives 4.2346, 0.02722 and 49.76°; ν_max is 130.45°;
  - the F-1 attached at sea level by Schmucker's criterion;
  - pe = pa between 5 and 8 km on the AS-506 sounding;
  - Simons' mass flux equal to ṁ within 1%;
  - a spec for every thruster, with exit radii matching the dressed nozzles;
  - Murphy-Koop vapour pressures;
  - the exact integrator against RK4.
- **P6:** Billig's standoff; Apollo 7's blackout reproduced within 30 s at each end.

**Mac**
- **OrbitRenderTests** (1-2 min, inside the Mac `swift test`):
  - every module compiles cleanly under `-Wall` (`check-shaders.sh`);
  - pipelines validate under the Metal validation layers;
  - look metrics on PFM output, with the tolerance for each:

    | Metric | Tolerance |
    |---|---|
    | Sun plate | ±1% |
    | Furnace | ±2%, or ±3% for rough metal |
    | Earthshine through the probe | ±5% |
    | Shadow edge | ±1 texel |
    | Penumbra | ±20% |
    | Exposure convergence | ±0.1 EV within 5 s |
    | Bloom energy | ±1% |
    | NaN containment | an injected NaN does not spread |
    | Star energy ratio, magnitude 1 to 6 | 100 ± 3% |
    | HDR resolve | no ringing |

  - look-dev goldens pass with mean linear error under 0.5% and p99.5 ΔE76 under 3.
- **Other checks:**
  - `orbitsnap --verify` for the paint probes;
  - `OrbitSim --selftest effects`;
  - `xcodebuild build test`.
- **Harness flights:**
  - the warp matrix at 1×, 10×, 100× and 1000×: every burst spawned, particle caps held, no NaNs, pause freezes, reload clears;
  - the M1.5 DoD flight;
  - a per-pass performance report.

**Shot list for M1.6** (orbitsnap specs; NASA references kept outside the repo)

| # | Scene | Reference |
|---|---|---|
| 1 | AS-503 on LC-39A, 21 Dec 1968, 12:51:00 UTC, 4/10 cirrus | S68-56050, S68-56002, S68-56310 |
| 2 | AS-506 on LC-39A, 16 Jul 1969, 13:32 UTC | S69-39961, MSFC 6901001 |
| 3 | T+0.5 s: steam, deluge, ice, F-1 plumes | S69-39961, the KSC E-8 film |
| 4-5 | T+60 s against sky and clouds; T+120 s, plume wider than the vehicle | AS-506 tracking frames, picked in VD2 |
| 6 | 162.3 s: S-IC retros and S-II ullage motors | Apollo 6 68-HC-191 |
| 7 | 192.3 s interstage jettison; 197.9 s LES jettison | Apollo 4/6 camera-capsule films |
| 8 | 549-561 s: S-II/S-IVB separation, ullage cases | Qualitative |
| 9 | Orbit at noon over the ocean: glint, earthshine, Kapton | Apollo 9 CSM frames, picked in VD3 |
| 10 | Terminator: limb layers, pink cloud tops, an 8-10 s penumbra | Apollo 7 and 9 terminator frames |
| 11 | Orbital night: 1968 lights against modern lights | The documented estimate |
| 12 | CSM separation with panels and fireflies; LTA-B posed | AS07-03-1545; AS08-16-2582..2584 |
| 13 | SPS burn and nozzle-extension glow | Qualitative |
| 14 | Entry: sheath, wake, SM breakup | S69-15592 (ID to confirm) |
| 15 | Drogues and mains | S71-42217 |
| 16 | Splashdown crown, CM floating on waves, char | Recovery photos, picked in VD3 |
| 17 | Orthographic Positions I-IV of AS-503/506 and CSM-101/103/107 | VD2's digitised photos |
| 18 | Look-dev scenes: colour checker, furnace, roughness spheres, shadow cubes, star field at EV 0, Sun plate | Published values |
| 19 | Modern-date Earth against DSCOVR EPIC, with ERA5 for that hour | The EPIC image |

M2 adds:
- Earthrise: AS08-14-2383 at GET 075:48:39, 250 mm, f/11, 1/250 s;
- the whole Earth: AS08-16-2593;
- lunar terminator frames, compared with LROC WAC;
- the night entry, with bank against MR Fig. 6.9-10.

**GPU budget** (M3 Pro, 3024×1964, High; measured per pass by the profiler, and the GPU lock is held when measuring)

| Pass (owner) | Pad, inside cloud (worst) | LEO |
|---|---|---|
| Probe and IBL (R3) | 0.3 ms | 0.3 ms |
| Shadows (R4) | 0.5 ms | 0.4 ms |
| Atmosphere LUTs, froxels, limb (A2) | 0.3 ms | 1.0 ms |
| Clouds (C2) | 3.0 ms | 2.0 ms |
| Opaque: planet, vessels, pad, stars (E2, R2, LC) | 2.0 ms | 1.5 ms |
| Composite (A2) | 0.4 ms | 0.4 ms |
| Plumes (P2) | 1.5 ms | 0.5 ms |
| Particles and smoke (P3) | 1.0 ms | 0.3 ms |
| Post (R1) | 1.1 ms | 1.1 ms |
| Overlay (F0) | 0.1 ms | 0.1 ms |
| **Total** | **≈ 10.2 ms** | **≈ 7.6 ms** |

- **Alarm:** above 13 ms, auto-downgrade, and build dynamic resolution only if it is still needed.
- **CPU per frame:**
  - stepping: about 10 ms in Smooth;
  - extraction ≤ 0.5 ms;
  - encoding ≤ 1.5 ms;
  - effects ≤ 0.3 ms;
  - quadtree ≤ 0.5 ms.
- **GPU memory at High, ≤ 1.5 GB:**
  - tile atlases 256-512 MB;
  - shadows about 50 MB;
  - HDR, depth and bloom about 90 MB;
  - meshes 15-20 MB;
  - decals and detail maps 20-70 MB;
  - particles 8 MB.
  - Memoryless MSAA frees the roughly 190 MB that MTKView's stored MSAA uses today.
- **Startup:**
  - shader modules compile asynchronously, with impostors as the fallback;
  - atmosphere LUTs under 0.2 s;
  - the mesh cache 50-100 ms in Release;
  - the AO bake runs in the background;
  - first frame within 2 s in Release.

**Time warp**
- Physics effects run on simulation time: particle ages, frost, char, glow, the trail.
- The turbulence clock is real dt × min(warp, 4).
- Journal bursts spawn at their true age.
- Continuous emitters stop at 1000× and above, except the trail.
- Cloud reprojection turns off at 10× or more.
- The tile LOD is biased by ground speed, and prefetch follows the predicted track.
- The probe and shadow maps are redrawn every frame.
- Pause freezes everything.
- After the A3 fix, coast at 1000× holds within 10% of M1.

## Effort and checkpoints

| Block | Session-days | Calendar |
|---|---|---|
| M1.5 close-out | 2-2.75 | 1.5-2 days |
| M1.6 foundation (F0, K0, L0) | 5.5-7.75 | — |
| M1.6 renderer (R1-R7) | 17-26.5 | — |
| M1.6 vehicles and pad (VD, VG, VM, LC) | 23.5-36.5 | — |
| M1.6 Earth (A1, A2, Q, E1, E2, C1, C2, SG) | 25.5-47 | — |
| M1.6 plumes and particles (P1-P6) | 22-34 | — |
| M1.6 integration (GI) | 3-5 | — |
| **M1.6 total** | **96.5-157 (about 125)** | **5-7 weeks** with 4 Mac and 3 cloud sessions |
| **M2 total** (flight 36-56; Moon and Apollo 8 visuals 8.5-15.5) | **44.5-73.5 (about 57)** | 3-4 weeks; 2-2.5 weeks after M1.6 with the overlap |
| **To the LM** | **≈ 143-233** | **about 9-12 weeks** |

**Mac capacity.** About two-thirds of M1.6, roughly 84 of 125 days, needs the Mac's GPU. With 4 Mac sessions that is about 21 working days, which matches the critical path. Five or six Mac sessions would gain little, because builds and GPU measurements contend.

**What drives the range:**
- the Mac build-and-snapshot loop, and Franz's review latency;
- keeping C2's three regimes continuous;
- evidence for the markings (Apollo 8 colour photos are scarce, and secondary sources conflict);
- F0's refactor risk;
- data logistics: the ERA5 start date and access, BMNG's size;
- the stability of goldens;
- art iterations on P2 and P4.

**Checkpoints** (working days from the start of the close-out)
- **CP0 (day 2): close-out.**
  - M1.5 closed in ROADMAP, with the Linux counts and the sign-off date.
  - The fast test gate is live.
- **CP1 (about day 6): foundation.**
  - F0 and K0 merged; goldens identical to main.
  - Every session can render a shot and Read it.
  - This gates the second wave, and M2's overlap tracks may start.
- **CP2 (about days 15-18): light and paint.**
  - Merged: R1, R2, R4, R3 (first pass), VG1-3, VM1, A2 (first pass), LC geometry.
  - AS-503 at 12:51 UTC and AS-506 at 13:32 UTC are rendered on LC-39A and compared with shots 1-2 and 17.
  - Franz decides the tone mapper, the exposure and the L-graded markings rows. This is the most important review.
- **CP3 (about days 25-28): weather and fire.**
  - Merged: C2's far and orbit regimes, E1, E2, P2, P3, P5, VM2.
  - Shots 4-10 and 12.
- **CP4 (about days 32-38): M1.6 closes.**
  - Merged: C2's near field, P4, P6, R7, GI.
  - The full shot set, the warp and performance matrices, the M1.5 DoD flight, the docs.
- **M2 checkpoints:**
  - CP5: TLI, chain legs L0-L3;
  - CP6: lunar orbit, legs L4-L7, plus the Moon and Earthrise;
  - CP7: entry and close.

**If time runs short, cut from M1.6 in this order** (savings in session-days):
1. Near-field volumetric clouds → a 2D sky from the pad (−3-4).
2. The LC set → a pad slab and trench (−3-4).
3. The AO baker (−1.5-3).
4. The Landsat Cape inset (−1).
5. The 1968 night lights (−1).
6. The shadow detail map (−1).
7. The SM breakup and the CM RCS dump (−1).
8. AS-501/502 markings rows and historic lakes (−1).
9. The tile store → a single 16k texture (−5 in M1.6; the store moves to M2 for the Moon).

Only cut 1 touches one of Franz's four named asks (paint and textures, volumetric clouds, volumetric plumes, staging particles), and only in part.
