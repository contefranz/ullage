> Plan for M1.6's second look round, written 2026-11-23 on main f25bb87 from a read-only study (nothing was built or run), approved by Franz on 2026-11-28 with the recommended answers (§5). The minimum round starts on main e424b1f. Costs are the M3 Pro at 3024×1964, High, from `docs/look/*.md`; "est." marks estimates. d = session-days. Paths are under `Sources/` unless they say otherwise. Recommendations are **bold**.

# Look round 2: clouds, plumes, launch smoke and the trail

## 1. What Franz sees and why

**Discrete shapes when zooming in.**
- *Every half-res layer.* R6's composite falls back to one nearest-depth texel whenever the four test depths differ from the pixel's by more than 10 % (`TransparentCompositeShaders.swift:139`), even for effects wholly in front. The result is 2-px stairs and row stripes over grazing ocean, at the horizon and around the tower (`launch-t+8.png`).
- *Clouds.* After each skip, rays land exactly 25 m outside the layer and step deterministically (`CloudShaders.swift:1273-1304`), which shows as terraces. No noise is finer than 64-128 m, and the detail volume aliases. History is mixed 50/50 with no jitter and switches off above 1.5 px of motion a frame (`CloudFrame.swift:317-321`), so flown frames are always fresh.
- *Plumes.* There is one eddy scale, with trilinear creases. The fluctuation (0.15 + 0.7w)(1 − v) applies in the unmixed core too and perturbs absolute temperature (`PlumeLook.swift:854`), giving ×5-8 luminance blobs.

**Puffy spheres.** Each puff is a disc of optical depth 30-140 × (1 − r²)², opaque out to 73-93 % of its radius. It is lit through a fake sphere normal and textured with 2-D billboard noise (`ParticleShaders.swift:909-921`). There is no self-shadowing (decision 39), so WBOIT shows balls through balls. A thinning cloud drops eddies instead of getting thinner (`LaunchEffects.swift:617-626`). Each layer keeps one front, so the plume cannot emerge from its own cloud. The trench jets are drawn with the same sprites.

**A narrow, detached trail.**
- Puffs are 18 (1 + h/10 km)^0.8 m (`ExhaustTrail.swift:40`, L): 26-36 m against the plume's 46-67 m FWHM (`p2-trail-joint.png`).
- They are laid before the jet stops spreading, so its growth from 15 to 32 m half-width is lost.
- They have no buoyancy and grow at 0.25 m/s. A line thermal reaches about 200 m radius in 30 s (Briggs).
- `.line` places them at random, which makes beads.
- The plume and the puffs fade on different clocks, so the column dips at the joint.

## 2. Approach

Measure first: no whole frame has been timed, and P4's pad cost predates #92. LR0 fixes R6's reconstruction and publishes a pad ledger that every cap must fit. LR2-LR5 replace L and photo-fit constants with the simulation's physics, for the clouds, the plume turbulence, the pad cloud and the trail. Plume, pad cloud and trail share the volumes layer, so the rocket rises out of its own cloud and its plume becomes its trail. LR1's history comes after a review in the app.

## 3. Tracks

**Minimum round** (answers the three complaints): LR0, LR2 PR1-2, LR3 PR1, LR4, LR5 PR1-2; 39-47 d. **Deferred** to the review: LR1, LR2 PR3-5, LR3 PR2, LR5's humidity and soot phases; 22-29 d.

**Pad ledger** (ms). LR0 measured it (`docs/look/frame-ledger.md`, 2026-11-28) on four pad frames: P4's 380 m view at T+0, P2's 62 m ML-base view at T+3 and T+5.5 s, and P4's 480 m view at T+8 s. plan.md's budget is re-baselined to it (decision 54). The caps are the ledger's medians.

| Pass | plan.md | Measured on the pad | After the round |
|---|---|---|---|
| Clouds (C2) | 2.7 | 2.2-2.9 | ≤ 2.5 |
| Effect slots and composite (R6) | 1.0 | 0.9-1.0 | ≤ 1.1 (LR0 +0.05-0.1) |
| Plumes | 2.1 | 0-2.1; 6.8-7.2 at the ML base, T+4.9-7 s | ≤ 1.8 at the ML base at T+3 s, ≤ 6.8 at T+5.5 s, ≤ 1.2 at T+8 s |
| Particles, smoke, trail | 1.7 | 0.3-1.7; 1.6-2.1 at the ML base, T+5.5 s (P4's own 0.06-1.18) | ≤ 1.4 at T+3 s, ≤ 2.1 at T+5.5 s, ≤ 0.6 at T+8 s |
| Others | 4.7 | 2.9-4.8 | unchanged |
| Headroom (LR4 High) | 0.8 | | where it fits |
| Whole frame | 13.0 | 6.8-11.1; 15.6-16.5 at the ML base, T+4.9-7 s | ≤ 13.0 |

On the pad the round adds:
- LR0: +0.1.
- LR5: +0.05.
- LR4 Medium: about 0, net of the sprites it retires.
- LR4 High: +0.8-1.4 (est.). It defaults on at the pad only where the measured frame has that much room.

### LR0 Reconstruction and cost baseline (shared)
- **First (0.5 d):** time whole frames (pad, T+8, max-Q, staging) and P4's share, with `LaunchEffectsCostTests` plus a new whole-frame report.
- **Composite:** bilinear where every texel's effect ended nearer than both scene depths. Otherwise the weights are renormalised over the matching texels (Kopf et al. 2007), and the nearest texel is used only when none match.
- **Writers.** Each layer switches when its writer lands:
  - the volumes write a back code into `fronts.a` (`PlumeShaders`, `EffectTestShaders`);
  - C2's slot copy and the sprites write clip flags (`CloudShaders`, `ParticleShaders`, announced to P3).
- Blue-noise jitter keyed on the frame index, and a settle mode in `SnapshotRenderer`.
- **Owns** `SceneRenderer.defaultPasses`, `ShaderLibrary`, `RenderTargets` and `QualitySettings`. Other tracks add one announced line each.

| Half-res attachment | Format | B/px |
|---|---|---|
| 0-3: clouds, volumes, OIT, revealage | rgba16F ×3, r16F | 26 |
| 4: fronts, back code in a (LR0) | rgba16F | 8 |
| 5: clip flags (LR0) | rg8Unorm | 2 |
| 6: vessel-class volumes (LR1) | rgba16F | 8 |
| 7: air-class depth (LR1) | rg16F | 4 |

  That is 48 B/px against 34 today, and Metal's limit of 8 attachments.
- **Files:** `OrbitRender/Passes/{HalfResTransparent,TransparentComposite}.swift`, the output lines of the shaders above, `OrbitRender/Snapshot/SnapshotRenderer.swift`, `OrbitScene/Look/EffectSlots.swift`.
- **Effort** 3.5-4.5 d. **GPU** est. +0.05-0.1 ms, capped by measurement. **Memory** +3 MB.
- **Tests:**
  - exactly bilinear in front of a ramp whose depth changes 30 % a row;
  - GPU against the Swift mirror;
  - hard golden `r6-edge-horizon`;
  - r6 and c2 edge pixels re-blessed within their tolerances.
- **Fixes** the stairs and stripes on every layer.

### LR1 Air-fixed volume history (shared; deferred)
- The volumes split into two classes: vessel-fixed (P2) and air-fixed (pad cloud, trail). Radiance adds and transmittance multiplies, so per-pipeline blend factors keep the two classes apart exactly.
- Only the air class keeps history:
  - reprojected body-fixed, in Double, at its opacity-weighted depth (wind drift is under 0.2 m a frame);
  - Catmull-Rom sampling;
  - a YCoCg variance clip;
  - depth rejection.
- This gives LR4 a jitter that rotates each frame, and a checkerboarded Medium.
- **Files:** new `OrbitRender/{Passes/VolumeResolvePass,Shaders/VolumeResolveShaders}.swift`, `OrbitScene/Look/VolumeReprojection.swift`.
- **After** LR4. **Effort** 3-4 d. **GPU** ≤ 0.3 ms. **Memory** +48 MB.
- **Test:** a flown T+2 to T+10 s from the pad cameras. The cloud next to the plume shows no streaks along the vessel's motion and no added variance.

### LR2 Clouds up close (C2 follow-up)
- **PR1:**
  - jitter carried through the skips;
  - weather interpolated along rays;
  - Halton sub-texel rays;
  - blend max(1/16, 1/(n + 1));
  - Catmull-Rom history;
  - per-texel rejection on the stored mean depth, in place of the 1.5 px gate;
  - unmarched checkerboard texels clamped to the YCoCg variance box of their four marched neighbours;
  - then 32 clear-air steps.
- **PR2:** a 64³ detail volume with one octave per channel. Finer octaves appear only where the pixel footprint resolves them, and each fades to its mean. An edge of perimeter dimension 1.35 (Lovejoy 1982) replaces erosion 0.35.
- **Deferred:** the adiabatic medium (PR3); orbit cover and a shadow cascade (PR4, which touches A2's `AtmosphereUniforms`); tile bombing (PR5).
- **Files:** `OrbitRender/{Shaders/CloudShaders,Passes/CloudPass,Clouds/CloudNoise}.swift`; `OrbitScene/Clouds/`, with new `CloudSpectrum` and `CloudTemporal`.
- **After** LR0. **Effort** PR1-2 8-10 d; all five PRs 20.5-27 d. **Memory** +2 MB.
- **GPU:**
  - pad: no rise. PR2's fine octaves stay off at the pad unless the step cut pays for them;
  - ascent: −1.0 to −1.5 ms.
- **Tests:**
  - finest noise cell ≥ 4 texels (fails today);
  - edge dimension 1.35 ± 0.1;
  - no altitude lattice;
  - within 2 % of a 256-jitter reference;
  - flown chase: ≥ 90 % of frames reprojected, and the edge spread after 60 frames at 30°/s within 10 % of a fresh frame;
  - cover within 0.03 of the committed `CloudClimatology`. The ERA5 check skips when the gitignored `*.oscloud` files are absent;
  - hard goldens `c2-cumulus-*` on a look-dev weather sample, after 32 settle frames.
- **Fixes** the terraces, the smooth blobs and the dead band.

### LR3 Plume turbulence (P2 follow-up)
- **PR1, `JetFluctuations.swift`:**
  - no fluctuation, and no noise call, in the potential core or in ballooned interiors;
  - the measured shear-layer and axis rms (Dowling & Dimotakis 1990, still to be transcribed);
  - temperature perturbed on its excess over ambient;
  - an intermittent edge (Wygnanski & Fiedler 1969) that keeps today's mean field;
  - billowing boundaries on ballooned plumes.

  PR1 also lands `TurbulenceSpectrum.swift` (amplitudes 2^(−k/3), lifetimes τ0·2^(−2k/3), footprint cut-off), and moves P2's far-field smoke onto LR5's scattering function. The 32 steps stay.
- **PR2, deferred:** detail octaves from two or three baked, tileable RG16F 128³ volumes, rotated per octave and evaluated only in the edge band. A spike first times one octave at max-Q (est. 0.05-0.1 ms). Octave counts: 1-2 on the pad, 2-3 in a max-Q chase, 6 at a 32× zoom; High caps at 3.
- **Files:** `OrbitRender/{Shaders/PlumeShaders,Passes/PlumePass,Plumes}.swift`; `OrbitScene/Look/{PlumeTurbulence,PlumeLook,PlumeClusters}.swift`, `OrbitScene/Settings/PlumeSettings.swift`.
- **After** LR5's header and PR1. **Effort** 4-5 d per PR. **GPU** High ≤ today everywhere (the core skip pays for the edge); Ultra +0.3 ms.
- **Tests:**
  - core rms < 1e-3;
  - mean column within 2 %;
  - luminance within 3 % over a 1-32× zoom;
  - structure-function slope 2/3 ± 0.1 (PR2);
  - hard goldens `p2-f1-shear-closeup`, `p2-f1-zoom-farfield` and `p2-f1-edge`.
- **Fixes** the core mottling, the flat edges and the smooth S-IC burnout capsule; PR2 fixes the same-size blobs and the creases.

### LR4 Launch cloud medium (P4 follow-up)
- **Materials:**
  - pad exhaust, ground cloud and start smoke become the medium;
  - deluge steam, which is never emitted, is deleted;
  - flash, cold vapour and every sprite at Low get sprite v2;
  - the trail goes to LR5.
- **A0, sprite v2** (2.5-3 d, first; in P3's `ParticleShaders.swift`, announced):
  - optical depth from the cloud's mass;
  - the closed-form line integral of a Gaussian, with no sphere normal;
  - world-space 3-D noise along the view ray;
  - soft depth intersection;
  - plume lights.
- **`GroundCloudField`:** at most 12 similarity primitives (ring thermals, Fischer jets, P2's wall jet, stems, start smoke). They carry GroundCloud's exhaust, water, soot and heat. Condensate comes from saturation adjustment with entrained air at TM X-64796's 29.4 °C and 73 % RH, replacing "all condensed" (L).
- **`LaunchTurbulence`:** integral scale about 0.45 R, lifetime R/w, and `TurbulenceSpectrum` octaves down to the pixel footprint. Boundaries are displaced as level sets with gains 2^(−k(3 − D)), D = 7/3. The fallback is Kim et al. 2008's sub-grid synthesis, written from the paper because its code is GPL.
- **`LaunchCloudPass`:**
  - A 128×128×64 grid (8-16 m) and a 64×64×32 light volume (Sun, sky, two F-1 lights) cover the far part.
  - Within 300 m of the camera the march evaluates the primitives directly, so no voxel ever shows.
  - The camera may be inside the cloud.
  - The plume merges as a second slab, and the trail's Gaussians join through `GaussianMediumCommon`.
  - Medium (quarter resolution, 32 steps) lands with High.
- **Files:** new `OrbitScene/Effects/Launch/{GroundCloudField,LaunchTurbulence,LaunchCloudOptics}.swift`, `OrbitScene/Effects/EffectMedium.swift`, `OrbitRender/{Passes/LaunchCloudPass,Shaders/LaunchCloudShaders}.swift`; `OrbitScene/Effects/Launch/{GroundCloud,LaunchEffects,LaunchMaterials,PadExhaust}.swift`.
- **After** LR0, LR3 PR1 and LR5's header. **Effort** 14-16 d, half of it on Linux. **GPU** per the ledger; ≤ 0.4 ms at T+30 s. **Memory** 12 MB.
- **Tests:**
  - mass and heat within 1 %;
  - continuous with P2's wall jet within 1 %;
  - the two-stream equals C2's at albedo 1;
  - a rebuilt field is bit-identical;
  - a flown T−5 to T+60 s shows 5× less change from frame to frame than today;
  - hard goldens `p4-cloud-*` with shape metrics, and `p4-cloud-zoom` held to LR3's zoom and slope tests.
- **Fixes** every puffy sphere on the pad, the floating balls, the flat lighting and the plume that looks pasted on.

### LR5 Exhaust trail column (P2/P4 seam)
- **Header PR (0.5 d, first):** `OrbitScene/Effects/GaussianMedium.swift` and `OrbitRender/Shaders/GaussianMediumCommon.swift`, with one smoke scattering function (phase, C2's two-stream, SH9). LR3 and LR4 include it, so a broken header disables three passes; `ShaderCompileTests` catch that.
- **PR1 (2-2.5 d, CPU only):**
  - the hand-over carries the width, column depth and soot of P2's projected far field, and λ = ṁ/V_air;
  - the two fades sum to 1;
  - stratified puffs in the meantime.
- **PR2:** `TrailColumn` nodes every 25 m, closed form in age:
  - coflow growth to rest, re-derived in OrbitScene and tested against the read-only `JetPath.path`;
  - a stratified bent-over line thermal;
  - K = κw*z(1 − z/z_i)² below the mixed-layer top (Troen & Mahrt 1986), Konopka/Schumann 2012 above;
  - extinction from mass.

  `TrailPass` draws instanced 3σ boxes back to front through R6's volume-item merge. Each box is a closed-form line integral (Condor et al. 2025) with an analytic Sun shadow. A stride of at least 0.25 × distance gives about 25 boxes per end-on ray (est.); a prototype of the end-on view sets the cap. The puffs are retired.
- **Files:** new `OrbitScene/Effects/Launch/{TrailColumn,TrailChain,TrailHead}.swift`, `OrbitRender/{Passes/TrailPass,Shaders/TrailShaders}.swift`; `OrbitScene/Effects/Launch/{ExhaustTrail,LaunchMaterials}.swift`, `OrbitScene/Look/{PlumeAirflow,PlumeLook}.swift`; later, humidity in `OrbitScene/Effects/AirProfile.swift`.
- **After** LR0. **Effort** 9.5-11 d, plus 2.5-3 d deferred. **GPU** ≤ 0.05 ms on the pad; ≤ +0.15 ms net in a chase. **Memory** ≤ 2 MB.
- **Tests:**
  - the line thermal within 1-3 % of Briggs;
  - Konopka against 1,000 small steps, to 1e-6;
  - head width and fades at T+3, 8, 15, 30, 60 and 120 s, including inside LR4's box;
  - unchanged up to 1000× warp;
  - hard goldens `p4-trail-tube` (beads < 2 %) and `p4-trail-joint-studio` (width jump < 10 %, ΔE < 3);
  - `p4-trail-chase` width ratio ≥ 0.85 (0.43 today).
- **Fixes** the narrow, beaded, detached trail.

## 4. Order and parallelism

Approved 2026-11-28; the M2 flight-controls increment (#100-#102) is merged (main e424b1f).
- **Do not touch:**
  - OrbitCore, including `AS506Data.swift` (which #101-#102 edit), `JetPath.swift`, `IceSublimation.swift`, Guidance, ApolloSCS, `Simulation.swift` and TerminalCount;
  - OrbitInstruments;
  - `Sources/OrbitSim`, until #100-#102 merge.

  So §17 cannot move.
- **Wave 1 (started 2026-11-28, local sessions):** LR0 on the Mac, measurements first; LR5's header PR, then LR5 PR1; LR3 PR1; LR4's Linux half (the field, turbulence and optics, no pass yet). GPU-heavy runs stay sparing until LR0 lands.
- **Wave 2,** after LR0 merges: LR2 PR1-2, LR3 PR1, LR4, LR5 PR2.
- **Mac:** at most three sessions, counting the coordinator's gates. Cost runs take the GPU lock, never nested.
- **Merge order:** LR0 → LR5 header → LR5 PR1 → LR3 PR1 (`PlumeLook`) → LR4 A0 → LR5 PR2 (`LaunchEffects`) → LR4 pass. LR2 can merge any time after LR0.
- **Gating:**
  - before merging the second of two PRs that share files, run a cold `scripts/test.sh` on main plus both;
  - re-bless scene goldens once per wave;
  - run `scripts/test.sh full` when the round closes;
  - announce P2, P3 and R6 contract changes first.
- **In the app,** after each wave: fly the scripted harness on Franz's cameras and send him the frames. The cameras: a cumulus zoom from the pad, a plume zoom at max-Q, T−6 to T+20 s at the ML base, and the T+30-90 s chase.
- **Calendar:** the minimum round takes about 3 weeks in three parallel sessions, the full round about 5 (est.). M1.6's close, and M2 (Apollo 8) after it, move by as much.

## 5. Owner decisions

1. **Scope:** the minimum round (39-47 d) and then M2, or the full round (61-76 d)? **Minimum round**; the rest after the review.
2. **Budget:** re-baseline plan.md's per-pass table (decision 54) to the ledger and hold 13 ms a frame? Or keep the table and leave new High knobs off at the pad until R7? **Re-baseline**, with LR4 at Medium on the pad when there is no room.
3. **Decision 39** for the pad cloud and trail: media or sprites? **Media**; sprite v2 for the flash, the vapour and Low.
4. **Soot yield** at the exit. P2's afterburning survival sets how it varies with altitude. The albedo of a condensed column on 10 µm droplets (est.):
   - 0.93 (white) at P2's implied 0.07 %;
   - 0.66-0.72 at P4's 0.5 %;
   - 0.30-0.35 (dark brown-grey) at 3-5 %, Maloney et al. 2022's stratospheric upper bound.

   **Choose from LR5 PR1's three predicted renders**; P2's value until then.
5. **Launch photo fit:** physics or refit? `LaunchMaterials` is fitted to S69-39961 and S68-56050: the albedos, the 4e4 cd/m² glow, the fill and eddy factors, and the trail bands. The physics greys the sooty lobes and dims the trench glow 20-30×; the orange then comes from F-1 light on the cloud. **Physics**; if photos disagree, question the L inputs, not the fit.
6. **Humidity profile:** TM X-64796 gives only the surface (`tools/data/tmx64796_table1_saturn.csv`). **FER-506's atmospheric data or IGRA v2 station 74794 (16 July 1969), whichever has dew points; otherwise the surface value with a stated lapse rate.**
7. **Goldens with history:** settle mode, or grainy first frames? **Settle mode.**
8. **Plume look:** no mottling in the core, an intermittent edge out to about 1.3 R, and the mean flame held within 2 %. The Burke-Schumann flame sheet: now or later? **Accept the look; flame sheet later.**
9. **"Jet streams":** the trench jets (LR4), the trail (LR5), or both?

### Decisions taken (Franz, 2026-11-28: "Yes, as recommended")

1. Scope: the minimum round, then M2. The deferred tracks wait for the review in the app.
2. Budget: plan.md's per-pass table (decision 54) is re-baselined to LR0's measured ledger, holding 13.0 ms a frame on the pad; LR4 runs at Medium on the pad when the measured frame has no room.
3. Decision 39 is amended: the pad cloud and the trail are media; sprite v2 for the flash, the cold vapour and the Low tier.
4. Soot yield: chosen from LR5 PR1's three predicted renders; P2's value until then.
5. Launch photo fit: physics. If photos disagree, question the L inputs, not the fit.
6. Humidity: FER-506's atmospheric data or IGRA v2 station 74794 (16 July 1969), whichever has dew points; otherwise the surface value with a stated lapse rate.
7. Goldens with history: settle mode.
8. Plume look: accepted as described; the Burke-Schumann flame sheet later.
9. "Jet streams": both the trench jets (LR4) and the trail (LR5), which the minimum round covers.

## 6. Risks and later

- Plumes stay over plan.md's re-baselined 2.1 ms pad line: 3.2-3.4× at the ML base from T+4.9 to about T+7 s (6.8-7.2 ms), and 1.8-3.1× at max-Q and staging (3.8-6.5 ms). R7 must cut them.
- No plume history this round. Its ceiling exp(−Δt/T_E) is 0.19 at T_E = 10 ms and 60 fps, and near 0 in the near field, so it cannot pay for fewer steps. In the far field it would lower the turbulence contrast.
- About 40 pad shots vary from run to run. Emission-index slots (1-2 d) come later.
- Memory: +19 MB for the minimum round and +105 MB for the full round, on top of R7's queued 285 MB.
- Flagged L inputs: soot yield 0.5 %, 10 µm droplets, radiant fraction 0.25, w* and z_i.
- Photo fits kept: P2's kerosene soot depth (8 × index) and condensate (3, 0.8), fitted to S68-56050 and S69-39957. The trail inherits them until decision 4. No new fit is added.
- Later: MetalFX (plan.md:66), ERA5 water paths, a re-march of the nozzle edges, R7 tiers.

Sources: Schneider & Vos 2015 (https://advances.realtimerendering.com/s2015/), Wolfe et al. 2022 (https://research.nvidia.com/publication/2022-07_spatiotemporal-blue-noise-masks), Kim et al. 2008 (https://www.cs.cornell.edu/~tedkim/wturb), Maloney et al. 2022 (https://repository.library.noaa.gov/view/noaa/53971), TM X-64796 (https://ntrs.nasa.gov/citations/19740005199), IGRA v2 (https://www.ncei.noaa.gov/products/weather-balloon/integrated-global-radiosonde-archive).