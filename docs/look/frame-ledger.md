# The frame ledger (M1.6 look round 2, LR0)

What whole frames cost on the GPU, as the app draws them, and each effect's
share. Look round 2's caps are sized from it (`docs/m16/look-round-2.md` §3),
and `docs/m16/plan.md`'s per-pass budget (decision 54, amended 2026-11-28) is
re-baselined to it. Measured on 2026-11-28 on main e424b1f, which has the
same code as b48990b.

## How it is measured

`FrameLedgerCostTests` (`ORBITSIM_TIMINGS=1`, GPU lock held) on the M3 Pro
at 3024×1964 (point scale 2):
- every default pass, with the app's default settings (High; the weather
  "auto", with the gitignored `*.oscloud` fields present);
- the Earth drawn from PlanetPass's `earth.jpg` (Application
  Support/OrbitSim/Textures). E1's tile store (OrbitSim/Tiles) is not
  installed on this Mac, so the planet takes E1's fallback, as the app does
  here; on a Mac with tiles "others" may cost more. The run's first line
  reports all three inputs;
- three frames in flight, as in the app.

AS-506's launch (`as506-first-motion`) gives six frames:

| Frame | Instant | Camera |
|---|---|---|
| pad-t+0 | T+0.3 s, first motion | 380 m east, 2° up, fov 50° (P4's pad view) |
| pad-base-t+3 | T+3 s | 62 m from the vehicle, yaw 149°, 2° down, fov 62° (P2's ML-base view) |
| pad-base-t+5.5 | T+5.5 s | the same, following the vehicle |
| t+8 | T+8 s | 480 m east, 4° up, fov 50° (P4's liftoff view) |
| max-q | T+80 s | a 300 m chase, 35° down |
| staging | 0.3 s after S-IC/S-II separation | 80 m, 17° up (the retros and ullage motors) |

Each frame is measured two ways:
- **Held:** the frame's instant, with the effects' clocks running at 1/60 s a
  frame. The plumes, particles and clouds' wind are live; the vehicle and
  camera are still, so C2 reprojects.
  - The shares are measured in blocks of 10 frames, the first 4 after each
    switch dropped, eight rounds with the order rotated. Each is the
    difference of medians with one subsystem off: C2's clouds, P2's plumes,
    P3/P4's particles.
  - "Others" is the frame with all three off, which also stops R6's slots.
  - "Slots" adds a tiny test emitter to "others", which wakes R6's slots
    alone.
- **Flown:** the simulation stepped 1/60 s a frame from the instant for 2.5
  s, the camera following, the first 0.5 s dropped.

**The frame time is the period, not the command buffer's span.** With
frames in flight, consecutive command buffers overlap on the GPU, so each
buffer's `gpuEndTime − gpuStartTime` reads up to twice the real cost. The
pad at T+3 read a 17-21 ms span against an 11 ms frame. The ledger takes:
- the period with frames in flight: one frame's end to the next's within
  a block, the rate a GPU-bound app gets;
- as a cross-check, each frame waited for (`ORBITSIM_LEDGER_WAIT=1`), where
  the span is the frame's own.

The two agree within about 0.8 ms on every frame. A pass's own cost is a
difference of medians; the split profiler gives only a breakdown.

## The ledger

Milliseconds. Each range covers three runs in flight (period) and two
waited (span).

| Frame | Whole frame | C2 clouds | R6 slots | P2 plumes | P3/P4 particles | Others | Room under 13.0 |
|---|---|---|---|---|---|---|---|
| pad-t+0 | 6.8-7.5 | 2.3-2.6 | 0.9-1.0 | 0.0 (none yet) | 0.3-0.7 | 3.0-3.5 | 5.5-6.2 |
| pad-base-t+3 | 9.4-11.1 | 2.2-2.9 | 0.9-1.0 | 1.4-2.1 | 0.6-1.7 | 3.6-4.8 | 1.9-3.6 |
| **pad-base-t+5.5** | **15.6-16.5** | 2.2-2.7 | 0.9 | **6.8-7.2** | 1.6-2.1 | 3.3-4.4 | **−2.6 to −3.5** |
| t+8 | 9.0-9.6 | 2.4-2.7 | 0.9 | 1.1-1.3 | 0.5-1.2 | 2.9-3.2 | 3.4-4.0 |
| max-q | 8.7-9.5 | 1.5-1.7 | 0.8 | 3.8-3.9 | 0.2-0.6 | 2.4-2.7 | 3.5-4.3 |
| staging | 11.2-12.3 | 1.3-2.1 | 0.9-1.0 | 5.7-6.5 | ~0 | 2.6-3.2 | 0.7-1.8 |

- The shares overlap a little: the three effects together with R6's slots
  are within 0.3 ms of the frame minus "others".
- "Others" is everything else: R3's probe, R4's shadows, A2's LUTs and
  composite, the planet and E1's tiles, the vessels and pad (R2), stars,
  R1's post, the overlay. The split profiler (which overstates passes of
  several encoders) puts about 0.9-2.3 ms of it in the probe, 0.7-1.1 in the
  shadows, 2.2-3.8 in the vessels and pad, and 1.05 in post.

**Flown** (period with frames in flight; the waited span's median, 90th
percentile and largest):

| From | Median | 90th | Waited: median / 90th / largest |
|---|---|---|---|
| pad-t+0, to T+2.8 s | 7.2-7.5 | 7.9-8.3 | 7.3-7.4 / 8.1-8.2 / 8.5 |
| pad-base-t+3, to T+5.5 s | 10.1-10.4 | 16.1-17.2 | 10.3-10.6 / 16.6-17.3 / 19.7-20.5 |
| pad-base-t+5.5, to T+8 s | 11.3-11.6 | 12.5 | 11.9 / 12.9 / 14.3 |
| t+8, to T+10.5 s | 9.2-9.4 | 10.1-10.3 | 9.3-9.4 / 10.0-10.6 / 10.9-12.0 |
| max-q, to T+82.5 s | 8.8-8.9 | 9.7-9.8 | 8.8-8.9 / 9.5 / 10.5-10.7 |
| staging, to +2.8 s | 5.7-5.8 | 6.2-6.7 | 6.0-6.3 / 6.8-7.0 / 8.4 |

The staging flight passes the retros' 0.64 s within its first 0.5 s, so the
flown frames are after them.

**Held or flown.** The ledger table quotes held frames: one instant, steady.
The app flies, and its dropped frames are the flown rows' 90th percentile
and largest. At the ML base from T+3 s those reach 16-17 ms and 19.7-20.5
ms, because the flight crosses the step below. Size a cap for 60 fps by the
flown 90th percentile, and a per-pass share by the held frames.

**The ML base from T+4.9 s.** At P2's 62 m base camera the frame steps from
about 10 ms to 16-19 ms at T+4.9 s. It decays to about 12 ms by T+9 s
(`ORBITSIM_LEDGER_SERIES=1` prints each frame).
- The step is the plume march: with the plumes off the same flight holds
  7.4 ms throughout. With the clouds or the particles off the step remains.
- This is the one pad frame over 13.0 ms, by 2.6-3.5 ms. It is P2's
  (`look-round-2.md` §6: plumes over their 2.1 ms line, R7 to cut them). LR3 PR1's
  core skip and R7's Medium plumes (16 steps) are the levers.

**P4's launch effects** (`LaunchEffectsCostTests`, 200 rounds, the particles
on and off frame by frame, P4's views without clouds or air):

| Phase | P4, slots for its smoke alone | P4's own (slots running anyway) |
|---|---|---|
| pad, T+0.3 to 7.5 s | 1.11 | 0.42 |
| liftoff view, T+0.3 to 7.5 s | 1.09 | 0.50 |
| liftoff view, T+4 to 11.2 s | 1.96 | 1.18 |
| liftoff view, T+8 to 15.2 s | 1.93 | 1.09 |
| liftoff view, T+15 to 22.2 s | 1.36 | 0.69 |
| liftoff view, T+30 to 37.2 s | 0.87 | 0.06 |

In the app's frames C2's clouds always wake R6's slots, so P4's own column
is the one that counts. Its 1.1-1.2 ms at T+4-15 s is over plan.md's old
1.0 ms particle line (P3's synthetic 1.16 ms was the only figure). R6's
slots cost a fixed 0.8-1.0 ms whenever anything draws through them.

## What it means for the round's caps

- **The pad holds 13.0 ms** at the 380 m and 480 m views (room 3.4-6.2 ms)
  and at the ML base until T+4.9 s (room 1.9-3.6 ms).
  - LR4 High's +0.8-1.4 ms (est.) fits at the 380 m and 480 m views.
  - At the ML base it fits before T+4.9 s, but only within the run-to-run
    spread.
  - From T+4.9 to about T+7 s at the base the frame is already over,
    because of the plumes. Per decision 2, LR4 defaults to Medium there
    until LR3/R7 bring the plumes down.
- **LR5's trail** (≤ 0.05 ms on the pad) fits everywhere.
- **LR0's reconstruction** (+0.05-0.1 ms est.) is measured against this
  ledger in its own PR.
- **Run-to-run spread:**
  - the whole frame varies by 0.4-0.9 ms between runs;
  - the particles' share is the least steady (0.6-1.7 ms at the ML base),
    because the held frames keep emitting;
  - a cap within 0.5 ms of the room is within the noise.
