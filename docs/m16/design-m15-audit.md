# M1.6/M2 design: M1.5 completeness audit

> Planning document for the M1.5 close-out, milestone M1.6 (graphics overhaul) and M2 (Apollo 8), written on 2026-10-20 by a design study (six design reports checked by a planner) and accepted by Franz on 2026-10-21 with all recommended defaults (US keyboard). Track briefs refer to it. Where code has moved on, the code wins.


This is a design report. Where it conflicts with plan.md, the plan wins: the planner checked and corrected the reports.


## Current state

main is at 6a1851b. M1.5 is marked done in docs/ROADMAP.md:60-103, README.md:6-24 and CLAUDE.md:6-21. Every M1.5 item is ticked and there are no unticked lines. The definition of done (ROADMAP.md:105-132) was mostly met by track I (PR #35):
- The AS-506 pad-to-splashdown flight passed 25/25 checks in the Release app, landing at "splashdown at 9.3 m/s", 25.40 N 74.26 W.
- The Apollo 7 chain (Apollo7DeorbitTests, Apollo7EntryTests, ParachuteTests) is in the suite.
- On the Mac, swift test passes 338 OrbitCore + 26 OrbitInstruments tests, and xcodebuild build/test is green.
- The docs are updated.

**Gaps against the DoD and the plan:**
- **Linux not checked.** DoD 3 says "swift test is green on Linux", but no M1.5 PR records a Linux run. The last recorded Linux run is PR #12, during M1 (152 tests). All 13 M1.5 PRs (#24-#36) report only macOS swift test or xcodebuild.
- **Screenshot review unconfirmed.** DoD 3 says "the owner has reviewed the screenshot set". PRs #33, #35 and #36 were merged with 0 reviews. The review-only orphan branches are gone from origin, but m15-integration-screenshots and m15-mfd-screenshots still exist locally.
- **One performance criterion missed.** The plan (plan.md:538) requires effectiveWarp at 1000x to stay within 10% of M1 in the parking orbit with the panels and the S-IVB present. PR #35 measured 753-787x (22-25% under) while each SLA panel re-enters, about two orbits after separation, and 1000x otherwise.

**Root cause of the warp drop:**
- The global step is the minimum over all vessels: StepControl.swift:15-21, called from Simulation.advance at Simulation.swift:98-115.
- isPassive (StepControl.swift:28-30) requires dynamicPressure < 1 Pa. Any debris in the air therefore forces 0.02 s steps on everyone.
- The SLA panels have drag only: a part dragCoefficient at ApolloCSM.swift:349-359, with no moments.
- M1's spent S-IC and S-II cause the same transient during the ascent.

**Test suite:** 1,111 s, Debug and serial (swift test log of the last integration run, m15-int6-test.log in the scratchpad).
- By class: SaturnIUTests 418 s over 25 tests, EngineOutTests 257 s over 9, AscentResidualTests 104 s over 18, Apollo7EntryTests 69 s over 2.
- The top 10 tests take 613 s (55%) and the top 25 take 892 s (80%). The slowest is testAPSHoldAtTimeWarp at 120 s.
- 47 test files use @testable. A shared NominalFlight fixture already exists (Tests/OrbitCoreTests/NominalFlight.swift:30).
- Package.swift has no test configuration. CLAUDE.md says about 15 min.

**Code comments:** there are no TODO, FIXME, XXX or HACK comments in Sources, Tests, tools or scripts. Data placeholders remain:
- AS506Data.swift:209: cantRampRate 0.2 deg/s, PLACEHOLDER.
- AS506Data.swift:865: sIVBJ2GimbalRate 8 deg/s, PLACEHOLDER.
- AS506Data.swift:1243: apsUllageIsp 290 s, PLACEHOLDER (it matters for the TLI restart).
- CommandModule.swift:222: SE-8 Isp 276 s (L).
- PR #34 notes: the SPS sector angles, tank radius and quad radii are graded L, and the SM RCS 10 deg cant is not modelled.

**Deferred by design (plan.md:60, decision 19; design-graphics.md):** ocean, plasma sheath, S-IC fins and plates (the .plate primitive was designed but never built), night lights, cockpit camera, OverlayPass, HDR/PBR, shadow maps. Also deferred:
- **Autopilot does not follow the navball speed mode:** design-navball-hud.md phase 2; plan.md:52 "Deferred: the green command marker shows the truth".
- **Lumped SPS sump/storage:** plan.md:61.
- **CSM held on the launch vehicle's axis until event 6:** SaturnV.swift:309 and Components.swift:687, 736-748. PR #34 left re-baselining §17 with the CSM's real lateral CG as an owner decision.

**Accepted and known deviations:**
- **Apollo 7 landing bands:** the constant-55 deg backup lands 50-80 n mi long, accepted by Franz on 2026-10-20 (ROADMAP.md:123-129, CM-entry-datasheet.md:202). In the app scenario, which uses the flight-consistent tables and a one-sided bank, the CM lands 140 n mi from 29.8 N 67.0 W (PR #35).
- **Apollo 4 Mach-6 trim:** a known miss (CM-entry-datasheet.md:114).
- **TN D-6725 Apollo 11 trim:** not transcribed (CM-entry-datasheet.md:116).

**What a user flying the AS-506 Earth-orbit return would notice:**
- **Black sea at splashdown:** flagged in PRs #33 and #35. planet_fragment (Shaders.swift:62-143) is Lambert plus a haze approximation, with no specular, ocean, clouds or night side.
- **Grid Earth by default:** the Earth is a 15 deg grid unless the user supplies textures (Renderer.swift:169-190, README "Planet textures"). The design's tools/fetch_textures.sh default was never built.
- **Stars in the daytime sky:** stars are drawn first and never dimmed (Renderer.swift:270-278), and the sky is at most 85% opaque (Shaders.swift:96). Stars therefore show over the pad in daylight.
- **Plain Saturn V:** the S-IC is a plain white cylinder with bells, with no fins or engine fairings (ApolloShapes.swift:293). The whole vehicle uses nine flat vertex colours (ApolloShapes.swift:225-228), with no roll pattern, markings or flag.
- **Crude LM:** the LM is an octagon and two frustums (ApolloShapes.swift:385).
- **No landing target on the map:** MAP marks only LC-39A (MFDModel.swift:52). The planned splash point is mentioned only in scenario text (Scenarios.swift:116).
- **No landing point while planning the deorbit burn:** MAP and ENTRY show a landing point only from the flight program's predictor (MFDMode.swift:179-181). That predictor wakes only after CM/SM separation.
- **Tooling gaps:** no cockpit view, no sound, no save/load.
- **Debug runs are slow:** a Debug run from Xcode is about 10x slower per step than Release (project memory: 0.5 vs 0.05 ms), and the README does not say to use Release.

**Housekeeping:** about 20 local dev/* branches, the local screenshot branches, and a stale worktree at .claude/worktrees/m15-csm-staging-9c75e0 (its branch was merged in #34).

## Design

Ranked list. A = must-fix to call M1.5 complete; B = cheap user-visible gaps (close-out if wanted, otherwise roll); C = roll into the graphical overhaul; D = roll into the Apollo 8 / Saturn V + CSM completion milestone; E = not needed. Effort is in focused session-days (d).

A. MUST-FIX (about 1.5-2.5 d in all)

A1. Run swift test on Linux for main plus the close-out (DoD 3). 0.25 d, plus 0.25-0.5 d of contingency.
- **Gap:** no Linux run is recorded since PR #12.
- **New Linux exposure since then:**
  - the OrbitInstruments target and its 26 tests;
  - Bundle.module for landmask.bin (SurfaceMask.swift:23);
  - string assertions in MFDPagesTests and HUDReadoutsTests (String(format:), "deg" glyphs);
  - the ProcessInfo clock.
- **Already proven on Linux:** String(format: "%@") with Swift strings, which has been in the core since M0 and passed in PRs #9-#12.
- **How:** run it in a cloud session after A4 lands, so it takes minutes rather than about 30-40 min.
- **Done when:** the counts (OrbitCore 338+, OrbitInstruments 26+) are pasted into the PR.

A2. Owner sign-off (DoD 3 and the plan's "Owner's own checks"). 0.05 d plus about 30 min of Franz's time.
- **What Franz confirms:** the screenshot sets (PRs #33 and #35) and the key checks on the US keyboard.
- **Recording:** add the date to ROADMAP's DoD.
- **Cleanup:** delete the local m15-*-screenshots branches.
- **Risk:** this review may add must-fix items.

A3. Debris in the air holds the warp down. 0.75-1 d: core on Linux, plus a Mac Release check.
- **Change in StepControl.swift:**
  - isPassive drops the q < 1 Pa condition. It keeps: not the focus, no program, autopilot, input or throttle, not landed.
  - A passive vessel in the air takes h = min(1 s, 1 rad/omega, 0.02*|v_air|/|a_drag|, 0.1*H/|hdot|).
- **Why this is valid:** debris has drag only, with no aerodynamic moments.
- **Optional:** per-vessel substepping inside step(h) for vessels whose limit is still below the global step.
- **Tests:**
  1. The global step stays at 0.5 s or more while four panels re-enter (extend CSMSeparationTests.testWarpStepsWithThePanelsTumbling).
  2. A panel's impact point with relaxed steps lands within 2 km of a 0.02 s reference.
  3. The §17 residuals are unchanged. Post-T5 coast pins may move in the last digit; re-pin only with evidence.
- **Release harness check:** "Apollo 11 in parking orbit", Space, then 1000x for 3 h of GET. Target: 950x or more in every 10 s window.
- **Side effect:** it also removes M1's S-IC/S-II transient.

A4. Test-suite speed. 0.5 d. Strictly outside the DoD, but do it in the close-out: every overhaul session pays it at each merge gate.
- **Changes:**
  - scripts/test.sh with two modes:
    - fast (default): swift test -c release -Xswiftc -enable-testing --parallel. The flag is needed because @testable fails in release otherwise.
    - full: swift test, Debug and serial.
  - Update CLAUDE.md's Commands and .claude/hooks/session-start.sh to warm the same configuration.
  - Check once that the pins hold under -O by diffing the §17 residual printout between the two configurations.
- **Expected:** about 2-4 min wall time on the Mac, bounded by the 120 s test divided by about 10, plus a longer whole-module compile.
- **Fallback:** if -O ever moves a pin, run --parallel in Debug only, which gives about 4-6 min.

A5. README tells users to run the Release scheme. 0.05 d.

B. CHEAP USER-VISIBLE GAPS (about 1-1.5 d)

B2. Recovery target on MAP and ENTRY. 0.25 d.
- Add a scenario recoveryTarget, for example Apollo 7's 29.8 N 67.0 W, as an MFDSite, plus range to target on ENTRY.
- Files: MFDModel.swift:52, Scenarios.swift, MapMFD.swift, EntryMFD.swift.
- Recommend doing it now.

B3. Landing point for the planned deorbit burn. 0.5-0.75 d.
- Run LandingPointPredictor from DeorbitPlanner's post-burn entry-interface state, at lift up and at 55 deg, and draw both on MAP and DEORBIT.
- Recommend rolling it into Apollo 8's entry targeting (TEI and the landing target), unless Franz wants the Earth-orbit return targetable now.

B1. Stars over the daylit sky. 0.25 d.
- Dim the stars by the sky luminance at the camera.
- Recommend folding it into the overhaul's atmosphere track.

B4. tools/fetch_textures.sh for Blue Marble. 0.25 d.
- Recommend folding it into the overhaul's texture pipeline.

C. ROLL INTO THE GRAPHICAL OVERHAUL (deferred by plan decision 19)
- **C1 Ocean near splashdown** (design-graphics G8c: Schlick Fresnel, a sum of 4-6 waves, sun glint, wave phase from double-precision camera offsets). Use the core's landmask.bin as a GPU water mask. 1.75 d (+0.25 d for foam).
- **C2 S-IC fins, engine fairings and retro fairings,** with the .plate primitive and dimensions from the SA-503/504 Flight Manuals. 1-1.5 d.
- **C3 Paint schemes and markings:** roll patterns, "USA" and "UNITED STATES", the flag, the CM's Mylar, the SM's radiator and aluminium panels. This is the earlier study's procedural material work.
- **C4 Plasma sheath and entry trail** (0.75 d in design) → with volumetric plumes and particles.
- **C5 Clouds and night lights** (0.5 d for night lights) → with volumetric clouds.
- **C6 Cockpit or nose camera** (0.5 d).
- **C7 Staging particles:** frost shedding, retro smoke, interstage, SLA and SM jettison.
- **C8 HDR, tone mapping and shadow maps.**
- **C9 LM visual:** not needed before LM work. Apollo 8 carried LTA-B instead of an LM.

D. ROLL INTO THE APOLLO 8 / SATURN V + CSM COMPLETION MILESTONE
- **D1 The accepted Apollo 7 deviation:** revisit with closed-loop entry guidance, constant-g (the EMS backup) and the CMC's P61-P67. Apollo 8's lunar return needs this anyway.
- **D2 Lunar-return trim calibration:** the Apollo 4 Mach-6 miss, and transcribing TN D-6725.
- **D3 SPS storage/sump series feed:** the LOI and TEI burns move the CG laterally, which drives the TVC trim.
- **D4 The CSM's real lateral CG on the launch vehicle.** 1-1.5 d. Re-baselining §17 moves the parking orbit to 185.54 x 184.86 km (from 185.17 x 185.08) and affects about 15 control tests. Do it with AS-503's own mass data.
- **D5 Replace the placeholders:** apsUllageIsp first (TLI restart), then the S-IVB J-2 gimbal rate, the cant ramp rate, the SE-8 Isp and the L-graded SPS/RCS geometry.
- **D6 Scenario save/load** (2-4 d): needed for a 147-hour mission.
- **D7 S-IVB restart, venting, LOX dump and slingshot** (former M2 items).
- **D8 Autopilot following the speed mode:** keep deferred; Apollo 8 does not need it.

E. NOT NEEDED
- E1 Polar motion, the geoid, the Fischer 1960 datum shift, fixed FCC mixing, S-IVB engine-out reactions.
- E2 The SM RCS 10 deg cant until M3 systems (the effective values along X are right).
- E3 Sound (owner option).
- E4 Flyable aborts (LES Mode I, SPS aborts); today they are logged only (datasheet line 2412). Owner option under "finish the CSM", not an M1.5 item.
- E5 Housekeeping: 20 dev/* branches and a stale worktree, at the owner's discretion (per the project memory, never use gh --delete-branch).
- E6 TODO/FIXME: none found.

**Bottom line:** M1.5 meets its DoD except A1 and A2, and misses one plan acceptance criterion (A3). A close-out of A1-A5 plus B2, about 2-2.75 d of work, makes it fully complete and leaves a fast test gate for the overhaul's parallel sessions.

## Phasing

**Step 0 (Franz, now):** A2 sign-off. Choose the close-out scope (B2 and/or B3) and the D4 timing.

**Close-out tracks.** All files are disjoint, so they can run at once:
- **X1, Mac, branch m15-closeout-tests.** A4 and A5: scripts/test.sh (new), CLAUDE.md, .claude/hooks/session-start.sh, README.md. Land it first, because every later gate uses it. 0.5 d.
- **X2, cloud/Linux, branch m15-linux-check.** A1: run the full suite on main, then again on the close-out tip. It can start immediately with the plain serial command and needs no code unless something fails. 0.25-0.75 d.
- **X3, core on Linux plus a Mac Release check, branch fix-debris-reentry-warp.** A3. Files:
  - Sources/OrbitCore/Simulation/StepControl.swift;
  - Simulation.swift only if substepping is added;
  - Tests/OrbitCoreTests/CSMSeparationTests.swift, or a new DebrisStepTests.swift.

  Independent of X1. 0.75-1 d.
- **X4, Mac, branch m15-recovery-target (optional).** B2, and B3 if chosen. Files:
  - Sources/OrbitSim/MFD/MFDModel.swift, Sources/OrbitSim/Scenarios.swift;
  - Sources/OrbitInstruments/MFDMode.swift, Modes/MapMFD.swift, Modes/EntryMFD.swift, Modes/DeorbitMFD.swift;
  - Tests/OrbitInstrumentsTests/MFDPagesTests.swift;
  - for B3 also Sources/OrbitCore/Navigation/DeorbitPlanner.swift and Tests/OrbitCoreTests/DeorbitPlannerTests.swift.

  0.25 d, or 1 d with B3.

**Finish:** a docs commit adds the sign-off date and a "close-out" note to ROADMAP's M1.5 section.

**Sequencing:** about 1.5-2 calendar days with one Mac and one cloud session. The graphics overhaul can start once X1 is merged: it does not depend on X3 or X4. C-items go to the overhaul plan and D-items to the Apollo 8 plan. Of the D-items, only D4 touches M1's pinned tests, so schedule it as a single re-baseline, not alongside other ascent work.

## Data and sources

- PR #35 (integration) body via `gh pr view 35`: 25/25 flight checks, the performance table (753-787x while SLA panels re-enter), the 'black sea' note
- PR #33 (renderer) body: deferred list (ocean, plasma sheath, S-IC fins/plates, night lights, cockpit camera, HDR/PBR, shadows), MSAA GPU cost 0.25-0.45 ms
- PR #34 (CSM staging) body: centredUntilEvent decision, SPS tail-off reading, L-graded SPS/RCS geometry, SM RCS cant not modelled
- Scratchpad m15-int6-test.log (last integration swift test run, Debug serial): 1,111 s, per-test and per-class timings
- Project memory orbitsim-flight-harness.md: Debug 0.5 ms vs Release 0.05 ms per powered step; harness method
- docs/ROADMAP.md:60-140, docs/m15/plan.md, docs/m15/design-graphics.md, docs/m15/design-navball-hud.md, docs/CM-entry-datasheet.md §2.4, §4.4-4.6, docs/AS506-datasheet.md (not-modelled lists)
- Saturn V Flight Manual SA-503 (for C2 fins/fairings and Apollo 8 data): https://www.nasa.gov/wp-content/uploads/static/history/afj/ap08fj/pdf/sa503-flightmanual.pdf
- Saturn V Flight Manual SA-504: https://www.ibiblio.org/apollo/Documents/Saturn_V_Flight_Manual_SA_504.pdf
- AS-503 postflight trajectory (Apollo 8 milestone): https://www.nasa.gov/wp-content/uploads/static/history/afj/ap08fj/pdf/as503-postflight_traj.pdf
- Saturn V Flight Evaluation Trend Report AS-501 to 508: https://www.ibiblio.org/apollo/Documents/Saturn_V_Flight_Evaluation_Trend_Report_AS-501_thru_508.pdf
- LTA-B on AS-503 (why the LM visual is not needed for Apollo 8): https://space.skyrocket.de/doc_sdat/lta-b.htm
- SwiftPM parallel XCTest and @testable in release (-enable-testing): https://forums.swift.org/t/running-tests-serially-or-in-parallel/72935 and https://forums.swift.org/t/test-discovery-on-linux/26203?page=2
- NASA TN D-6725 (lunar-return trim, D2): https://ntrs.nasa.gov/api/citations/19720013191/downloads/19720013191.pdf
- NASA Visible Earth Blue Marble (B4/overhaul, public domain): https://visibleearth.nasa.gov/collection/1484/blue-marble

## Licensing

The close-out adds no third-party code or assets.
- **NASA documents:** the SA-503/504 Flight Manuals, the AS-503 trajectory and TN D-6725 are US Government works and are used as data, with credit.
- **Imagery:** Blue Marble and Black Marble imagery, if fetched for B4 or the overhaul, is NASA public domain. It should be credited in the README and stay out of the repo (user-side fetch), as the design report recommends.
- **Natural Earth** (landmask.bin, coastlines.bin) is public domain and already credited.
- **Third-party simulators:** nothing from NASSP (GPL), KSP (proprietary) or Orbiter's D3D9Client (LGPL) is involved. Orbiter's MIT core remains a design reference only (PR #32: no file ported, so no THIRD_PARTY_NOTICES.md needed).
- **Swift toolchain flags:** -Xswiftc -enable-testing on the command line has no licensing impact.

## Performance

**Today (Release, 1400x900 at 2x, measured in PR #33/#35):**
- 60 fps at vsync.
- GPU 1.9-2.2 ms per frame with MSAA 4x (1.65-1.8 ms without).
- CPU encode 0.06-0.08 ms.

The frame is bounded by vsync at 1x and by the 40 ms step budget at high warp (Simulation.stepBudget, maxRealInterval 0.1 s), not by drawing.

**Warp:**
- 1000x holds in the parking orbit with the stack, and with the CSM plus four tumbling panels and the S-IVB (passive 1.7 s steps).
- The exception is each panel's re-entry window, at 753-787x and 42-50 fps. A3 restores 1000x there, and in M1's S-IC/S-II debris windows, by taking debris out of the global step minimum.

**Debug builds:** about 10x slower per step, so a user running from Xcode in Debug sees heavy warp limits (A5 documents Release).

**For the overhaul:** about 14 ms of GPU headroom at 1x. At warp, the CPU spends up to 40 ms per frame stepping, so new GPU passes add frame time on top of it.
- **Rule:** keep 1x frame time under 16.7 ms on the base M-series GPU.
- **Option:** lower stepBudget, or move stepping off the main thread, if the GPU cost grows. This is a separate decision for the overhaul plan.

**Quality settings:** the close-out adds none. MSAA stays at 4x.

## Verification

**Linux (cloud):** full swift test green on main and on the close-out tip, with the test counts in the PR (OrbitCore 338+ and OrbitInstruments 26+, plus the new tests).

**Mac:**
- **Test configurations:** scripts/test.sh fast and full must give the same pass set. Diff the §17 residual printout lines (AscentResidualTests.testModelResidualsAgainstThePFT) between the -O and Debug runs, and record both wall times.
- **A3, core:** the global step stays at 0.5 s or more while four panels re-enter, and the relaxed-step impact point lands within 2 km of a 0.02 s reference integration. The §17 pins are unchanged, or re-pinned with a stated cause.
- **A3, Release harness** (memory: tree export, FlightHarness.swift, .req to screencapture). Fly "Apollo 11 in parking orbit", press Space, then run 1000x for 3 h of GET and log effectiveWarp in 10 s windows. Accept 950x or more in every window, against today's 753-787x. Repeat the AS-506 ascent at 100x to show the S-IC/S-II transient is gone.
- **B2/B3:** MFDPagesTests check the target marker and the range to target on ENTRY. A harness shot of DEORBIT and MAP before the burn should show the predicted landing, within the predictor's documented 100 km at entry interface of where the flight then lands.

**Owner:** sign-off on the PR #33/#35 screenshot sets, recorded in ROADMAP.

No new reference photos are needed for the close-out. The overhaul's reference photos (NASA AFJ/ALSJ public-domain imagery of AS-503 and AS-506 on the pad and in flight) belong to the overhaul plan.

## Files touched

- /Users/grossetti/sw/ullage/scripts/test.sh (new)
- /Users/grossetti/sw/ullage/CLAUDE.md
- /Users/grossetti/sw/ullage/.claude/hooks/session-start.sh
- /Users/grossetti/sw/ullage/README.md
- /Users/grossetti/sw/ullage/docs/ROADMAP.md
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Simulation/StepControl.swift
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Simulation/Simulation.swift (only if per-vessel substepping)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/CSMSeparationTests.swift (or new DebrisStepTests.swift)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/MFD/MFDModel.swift (B2)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Scenarios.swift (B2)
- /Users/grossetti/sw/ullage/Sources/OrbitInstruments/MFDMode.swift (B2/B3)
- /Users/grossetti/sw/ullage/Sources/OrbitInstruments/Modes/MapMFD.swift (B2/B3)
- /Users/grossetti/sw/ullage/Sources/OrbitInstruments/Modes/EntryMFD.swift (B2)
- /Users/grossetti/sw/ullage/Sources/OrbitInstruments/Modes/DeorbitMFD.swift (B3)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Navigation/DeorbitPlanner.swift (B3)
- /Users/grossetti/sw/ullage/Tests/OrbitInstrumentsTests/MFDPagesTests.swift (B2/B3)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/DeorbitPlannerTests.swift (B3)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Renderer.swift and Shaders.swift (B1 only if done in the close-out rather than the overhaul)

## Options (owner decisions)

1. **Close-out scope.**
   - **Default:** A1-A5 plus B2 (about 2-2.75 d).
   - **Alternative:** add B3 now (+0.5-0.75 d) so the Earth-orbit return can be targeted at a recovery area.
   - B1 (stars) and B4 (texture fetch) go to the overhaul in either case.
2. **Debris warp fix.**
   - **Default:** drag-limited steps for passive debris in the air.
   - **Alternative:** remove non-focus SLA panels below about 60 km as "burned up" (0.25 d, but it hides the S-IC/S-II impacts).
   - **Alternative:** accept the transient and amend the plan's criterion.
3. **Test gate.**
   - **Default:** release plus --parallel for the merge gate, with the full Debug serial run at milestone close.
   - **Alternative:** --parallel in Debug only (about 4-6 min, with no -O risk).
4. **The CSM's real lateral CG on the launch vehicle (D4).**
   - **Default:** defer to the Apollo 8 milestone and re-baseline once with AS-503 data.
   - **Alternative:** do it now (1-1.5 d; the parking orbit moves to 185.54 x 184.86 km and about 15 control tests are re-pinned).
5. **The Apollo 7 accepted deviation.**
   - **Default:** keep it until closed-loop entry guidance (constant-g and the CMC's P61-P67) arrives in the Apollo 8 milestone.
6. **Milestone naming.**
   - **Default:** close M1.5 after A, then a graphics milestone (for example "M1.6 Graphics overhaul"), then Apollo 8 (the CSM-only lunar profile, today's M2 minus the LM), with LM work after it.
   - This needs Franz's call because CLAUDE.md and the ROADMAP refer to M2 and M3.
7. **Flyable aborts (LES Mode I, SPS aborts).**
   - **Default:** not part of "finish the CSM" now; list them in the Apollo 8 milestone's options.
8. **Housekeeping.**
   - **Default:** Franz deletes the 20 dev/* branches, the local screenshot branches and the stale worktree himself, or allows a session to do it with plain git (never gh --delete-branch).

## Effort

**Must-fix:**
- A1, Linux run: 0.25 d, plus 0.25-0.5 d of contingency.
- A2, sign-off: 0.05 d.
- A3, debris warp: 0.75-1 d.
- A4, test speed: 0.5 d.
- A5, README: 0.05 d.
- Subtotal: 1.6-2.35 d.

**Optional close-out UX:**
- B2: 0.25 d.
- B3: 0.5-0.75 d.
- B1 and B4: 0.25 d each, if done now rather than in the overhaul.

**Total:** a recommended close-out of A plus B2 comes to about 2-2.75 d of work, about 1.5-2 calendar days with one Mac and one cloud session.

**What drives the range:** whether the Linux run exposes a failure (formatted-string assertions in OrbitInstruments are the likeliest), and whether the debris step change moves any §17 or post-T5 pins that then need evidence-based re-pinning.

**Items handed on, sized for the next plans:**
- **Overhaul:** C1 1.75-2 d, C2 1-1.5 d, C4 about 0.75 d. C3, C5, C7 and C8 are sized by the overhaul study.
- **Apollo 8 milestone:** D4 1-1.5 d, D6 2-4 d. D1-D3, D5 and D7 are sized by that plan.

## Risks

- **Linux:** a Linux-only failure would turn A1 from 0.25 d into up to 0.75 d. Running it is the only way to know, since no M1.5 PR ran on Linux.
- **Optimized tests:** in theory -O could change floating-point results and move a last-digit pin. Swift does not enable fast-math, so this is unlikely, but diff the §17 printout once.
- **Parallel tests:** each --parallel worker process may re-fly the shared nominal ascent (NominalFlight.shared is per process). That raises CPU and memory load but not wall time. Watch memory on small cloud VMs.
- **Debris step change:** it enlarges the focus vessel's coast steps wherever debris used to force 0.02 s, for example the S-IVB's post-T5 coast while the S-II falls. Tests pinned on that coast (APS hold at time warp, coast command rate) may shift in the last digit. Re-pin only with a stated cause.
- **Debris accuracy:** relaxed steps change where debris lands. The impact-point test bounds this at 2 km, and nothing downstream uses debris impact points.
- **Owner review:** the review in A2 may surface new must-fix items. Leave room for them.
- **Scope creep:** B3 and D-items pulled into the close-out would delay the overhaul. Keep the close-out to A plus B2 unless Franz decides otherwise.
- **File ownership:** X3 (StepControl/Simulation) and X4 (OrbitInstruments and the app MFD) are disjoint from each other and from the overhaul's Rendering files. The only hot file is CLAUDE.md, which X1 owns. Docs edits go in the final close-out commit.
