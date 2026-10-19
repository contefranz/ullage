# AS-506 raw flight data: PFT Table B-II/B-III and FER Figure 11-1

These are transcriptions and digitisations made for the M1 ascent work (datasheet §9–§14). They are the raw data behind the S-IC residual diagnostics (§14, E1–E3) and the IGM flight tests (§10). Nothing in the build reads them. They are kept so the next items, mainly the AS-506 pitch-program fit that replaces `pitchScale`, don't have to read the documents again.

**Sources:**
- **PFT:** Boeing D5-15560-6, *Apollo/Saturn V Postflight Trajectory – AS-506* (6 Oct 1969; NTRS 19920075301).
- **FER:** MSFC MPR-SAT-FE-69-9, *Saturn V Launch Vehicle Flight Evaluation Report AS-506*.

"PDF page" means the page index in those scans.

**How the data were read:**
- Every number was read from rendered or native 300 dpi page images, not from the OCR text layer.
- Units are as printed, and nothing is converted.
- Time is range time in seconds from range zero, 1969-07-16 13:32:00 UTC.

## `pft-table-b2/`: PFT Table B-II (and B-III after S-IC OECO)

Table B-II, "Launch vehicle navigation positions, velocities, and accelerations – ascent phase":

- **Frame:** PACSS 13, the LVDC navigation frame. It is inertial and Earth-centred, fixed at guidance reference release, with X up through the launch site and Z downrange on the 72.058° flight azimuth.
- **Columns:** `t XS YS ZS (km) DXS DYS DZS (m/s) DDXS DDYS DDZS (m/s²)`.
- **Sampling:** rows are printed every 1 s to 162 s and every 2 s after that, plus event rows with 3-decimal times.

| file | content | rows | checks |
|---|---|---|---|
| `b2-sic-all-rows.txt` | **every** printed B-II row from −1.0 to 162.0 s (1 s, plus the event rows 0.300 first motion, 0.600 start of TB1, 135.200 CECO, 161.630 OECO); PDF pages 104–108 | 169 | the neighbour set for the finite-difference checks; the last field is the PDF page |
| `b2-sic-checked.txt` | the subset used for the S-IC diagnostics: every 5 s from 10 to 160 s, the event rows, 1.0 and 161.0 s | 36 | each value read twice (400 dpi render, then native 300 dpi); velocity and acceleration checked against central differences of the neighbouring printed rows, within the bounds set by print rounding (header lists the two rows marginally over the bound, re-read and confirmed) |
| `b2-sic-checked.json` | the same 36 rows with the per-row check record (`fd_check`) and the frame note | 36 | as above |
| `b2-b3-oeco-to-insertion.csv` | B-II **and** B-III (geographic: altitude, space- and Earth-fixed speed, flight-path angle, heading, range, latitude, longitude) from S-IC OECO, 161.63 s, to parking-orbit insertion, 709.33 s, plus derived columns (flight-path angle and heading recomputed, crossrange, non-gravitational acceleration, thrust-acceleration pitch/yaw `chiY_thrust_deg`/`chiZ_thrust_deg`), with PDF pages and grades | 92 | B-III recomputed from B-II with the PFT's frame definitions agrees on all 92 rows (radius ≤ 0.8 m, angles ≤ 0.006°, speeds ≤ 0.09 m/s); B-II passes a trapezoid kinematic check; reviewed by a verifier (its notes are in the `note` column) |
| `b2-b3-oeco-to-insertion.md` | the documentation of that transcription: the PFT's tables and figures, the frames, the checks and the insertion conditions recomputed | — | — |
| `b2-oeco-to-insertion-raw.txt`, `b3-oeco-to-insertion-raw.txt` | the raw B-II and B-III rows behind the CSV | 92 each | — |
| `scripts/` | the scripts that cropped, read and checked the S-IC pages (`fdcheck*.py`, `final.py`, …) and checked the OECO–insertion rows (`igm_*.py`) | — | — |

Not transcribed:
- B-II rows from 162 s to insertion, except at the CSV's sampled times (every 10 s, every 2 s around staging, S-II CECO and the final seconds, plus all event rows).
- Table B-I (Earth-fixed launch-site frame).
- B-III before 161.63 s.

The PFT has no attitude, mass or guidance data. Attitude comes from the FER, below.

## `fer-fig11-1/`: FER Figure 11-1, "Pitch Plane Dynamics During S-IC Burn"

PDF page 159 (printed page 11-3). The figure has four panels against range time:
1. pitch attitude;
2. pitch attitude error;
3. pitch rate;
4. average pitch engine deflection.

All four use the solid MEASURED stroke; the dashed simulated curve is not used.

| file | content |
|---|---|
| `fig11-1-final.json` | **use this**: the 5 s samples, 15–160 s (30 rows): `attitude_deg`, `error_deg`, `rate_deg_s`, `engine_deg` (`command_deg` is null: commanded and actual attitude are one stroke in panel 1). The mean of two independent digitisations; the two points where they disagreed (attitude at 15 and 20 s) re-digitised and adjudicated (`adjudication`) |
| `fig11-1-A.json`, `fig11-1-B.json` | the two independent digitisations, each with its calibration, accuracy estimate, notes and the panel-2 error extremes |
| `A/dp_p1.json` … `dp_p4.json` | digitiser A's dense centreline traces, one point per pixel column (`t`, `v`, pixel coordinates, flags), with `calib.json` (gridline fits) and `notes.txt` |
| `B/p1_dp.json` … `p4_dp.json`, `grid.json`, `final_samples.json` | digitiser B's dense traces, grid fit and samples |
| `adjudication/` | the 400 dpi re-measurement of the disputed points (`meas*.json` at three thresholds) and its scripts |

Caveats (details in the JSON files):
- **Panel 1's printed axis labels are inconsistent.** They read 0 at the top border, −40 on the middle line and −60 at the bottom border. Both digitisers read the panel as 0 to −80° at 20° per division, so every attitude value depends on that reading.
- **Accuracy (digitiser A's estimates):**
  - attitude ±0.4° (±0.5° at 15–20 s, where the stroke merges with the border; ±0.2° at the two adjudicated points);
  - error ±0.015–0.04°;
  - rate ±0.015°/s (±0.05°/s at 60–90 s);
  - engine deflection ±0.015°;
  - time ±0.1 s.
- **Panel 3 at 60–90 s** is a fast oscillation, so the 5 s samples there are single points on it.
- **Panel 2's plotted peak of 0.90° at 117.7 s** is 0.07° above FER Table 11-2's 0.83° at 117.4 s. This is the plot itself, not a misreading.

## `e1-reference/`: AS-506's thrust direction and reconstructed pitch command (§14.1)

`as506_ref.json`, written by `as506_ref.py` from the two data sets above:

- **`ref`:** for every row of `b2-sic-all-rows.txt` (−1 to 162 s):
  - the radius, speed and flight-path angle;
  - the thrust-acceleration direction `chiY`, `chiZ` (B-II acceleration less J2 gravity, in PACSS 13; launch site 28.608422° N, 80.604133° W geodetic, azimuth 72.058°);
  - the non-gravitational acceleration magnitude `ang`, and the position and velocity.
- **`cmd`:** at 1 s steps, 14–160 s:
  - `chi_thr` and its 5 s smoothing `chi_thr_s`;
  - Fig 11-1's error, as a 5 s boxcar `err_box` and linear in the 5 s samples `err_lin`;
  - the reconstructed command `cmd` = χ_thr − error, smoothed over about 5 s.
- **`err5`, `att5`, `eng5`:** Fig 11-1's 5 s samples, as used.
- **`fits`:** least-squares fits of GE504's four quartic segments (35, 80 and 115 s from T1, arrest at 159.37 s from T1) to `cmd`:
  - joined C0 or C1;
  - with or without the start held at 0;
  - each fit's coefficients, rms, maximum residual and join values.
  - The C0 fit reaches 0.049° rms (0.115° maximum).

The reconstruction assumes that attitude equals χ_thr. FER Table 11-1's 0.12° stacking misalignment biases it (datasheet §14.4, "not established" item 1). AS-506's command at 85–112 s is uncertain to about 0.5° (item 2).

## Paths in the files

The scripts and notes were written in a cloud session, so they refer to absolute paths in its scratchpad (`/tmp/claude-0/…/scratchpad/`). The mapping is:

| scratchpad path | here |
|---|---|
| `data2/pft-b2/pft_b2_sic_all_rows.txt` | `pft-table-b2/b2-sic-all-rows.txt` |
| `data2/pft_b2_sic_v2.txt` | `pft-table-b2/b2-sic-checked.txt` |
| `data2/pft-b2.json` | `pft-table-b2/b2-sic-checked.json` |
| `igm/pft-trajectory.csv`, `.md` | `pft-table-b2/b2-b3-oeco-to-insertion.csv`, `.md` |
| `igm/data/pft_b2.txt`, `pft_b3.txt` | `pft-table-b2/b2-` and `b3-oeco-to-insertion-raw.txt` |
| `data2/fig111-final.json`, `fig111-A.json`, `fig111-B.json` | `fer-fig11-1/fig11-1-final.json`, `-A.json`, `-B.json` |
| `data2/fig111-A/`, `fig111-B/work/`, `fig111-adj/work/` | `fer-fig11-1/A/`, `B/`, `adjudication/` |
| `diag/e1/out/as506_ref.json`, `diag/e1/scripts/as506_ref.py` | `e1-reference/` |

The page images, crops and numpy work files (several hundred MB) and the source PDFs are not included.
