# AS-506 as flown: transcribed data

The data that the ascent-residual tests judge the model against (datasheet
§14). `Sources/OrbitCore/Vessel/AS506PostflightData.swift` holds copies of
these values, and `AscentResidualTests.testFixturesAreToolsData` checks that
the two agree. Each file's header names its source table or figure, the page
and the source's units.

`docs/data/as506/` holds the earlier transcription and digitisations behind
datasheet §14, made by PR 12's cloud session and committed separately (commit
397d6ab, branch `m1-pft-raw`): Table B-II's rows to 162 s, 92 rows of B-II
and B-III after it, and Figure 11-1's four panels digitised twice. The files
here are a fresh, complete reading; that earlier one served as an independent
check of them (below and `AscentResidualTests.testAgainstPR12Readings`).

## Sources

| key | document | copy read | sha256 |
|---|---|---|---|
| PFT | Boeing D5-15560-6, *Apollo/Saturn V Postflight Trajectory - AS-506* | https://www.ibiblio.org/apollo/Documents/19920075301.pdf | `9784575549a26ca6367f377df09d5dcee22713dfaefc9b6378e4888ef6d518f1` |
| FER | MPR-SAT-FE-69-9, *Saturn V Launch Vehicle Flight Evaluation Report AS-506, Apollo 11 Mission* | https://www.ibiblio.org/apollo/Documents/lvfea-AS506-Apollo11.pdf | `84b23ee1f3e8e76db20e4e6c1a5bc8b83cd9bc09950c43c43330bce753c3a9c7` |
| OT-507 | Boeing D5-15551(I)-7, *Saturn V AS-507 "G" Mission Launch Vehicle Operational Flight Trajectory - September Launch Month* | https://www.ibiblio.org/apollo/Documents/19700072469.pdf | `11bf5a3c368638e8d40901024f32b6ad6e507b9a2e8bf4558b8464d4ad581809` |

All three are scans: their text layers are OCR and not to be trusted for the
tables. Every value here was read from the page images, which
`pdfimages`/`pdftoppm` (poppler) extract at the scans' 300 dpi.

## Files

| file | content | how it was read and checked |
|---|---|---|
| `pft506_table_b2.csv` | PFT Table B-II (PDF pp. 104-115): every row, PACSS 13 position, velocity and acceleration, -16.968 to 709.33 s | Deskewed crops read by two independent readers: they differed in 13 of the 4,176 cells, 4 of them in a digit. Every row checked against its neighbours (position against the velocities, velocity against the accelerations). PR 12's reading agrees in 2,347 of the 2,349 cells it shares; the other two are faded digits it read as printed and the kinematics settled here. The `note` column records the cells settled that way, and the event rows that the printed table itself puts off the trajectory. |
| `fer506_table_4_2.csv` | FER Table 4-2 (p. 58): actual and nominal cutoff events, metric rows | Page image; a second reader, cell by cell: no discrepancy |
| `fer506_table_10_1.csv` | FER Table 10-1 (p. 147): platform velocities, guidance / postflight / operational | Page image, its ft/s columns as a check; second reader: no discrepancy |
| `fer506_table_10_2.csv` | FER Table 10-2 (p. 148): PACSS 13 states, guidance / postflight / operational | Page image at 300 dpi, its ft columns as a check; second reader: no discrepancy |
| `fer506_fig11_1_pitch_error.csv` | FER Figure 11-1 (p. 159) panel 2: measured pitch attitude error, every 0.2 s, 0.6-161.6 s | `digitise_fer_figure.py`. Against PR 12's two dense digitisations (A, B): 0.017/0.019° rms point by point, 0.009° rms and at most 0.03° on 5 s means from 15 to 160 s; a visual reader as well (below) |
| `fer506_fig5_3_sic_thrust.csv` | FER Figure 5-3 (p. 74): S-IC stage thrust (reconstructed), every 0.5 s | `digitise_fer_figure.py`; a visual reader at 84 times: 0.043 MN rms (0.13 %) off the CECO step, but 0.2-0.3 MN on the short hook after 160.5 s |
| `fer506_fig6_3_sii_thrust.csv`, `fer506_fig6_3_sii_emr.csv` | FER Figure 6-3 (p. 86): S-II stage thrust and mixture ratio (reconstructed), every 0.5 s, 486-548 s | `digitise_fer_figure.py`; a visual reader at 31 times: within 0.02 MN and 0.007 off the EMR step |
| `as507_ot_tilt_polynomial.csv` | OT-507 Table 4-I (pp. 255-258): AS-507's S-IC tilt polynomial, a proxy for AS-506's | Page images |

Each figure file's header gives the exact `digitise_fer_figure.py` command
(panel box, grid, trace options, and for Figure 5-3 the box of dashed curve
dropped by hand where the solid line hides under the 40 MN grid line), the
scale per pixel and the gaps where the trace was interpolated. The traces
were also checked by eye on the tool's `--overlay` images.

## Reproducing

```sh
# page images (300 dpi, grey) for the figures
pdftoppm -f 159 -l 159 -r 300 -gray lvfea-AS506-Apollo11.pdf fer   # Figure 11-1
pdftoppm -f 74 -l 74 -r 300 -gray lvfea-AS506-Apollo11.pdf fer     # Figure 5-3
pdftoppm -f 86 -l 86 -r 300 -gray lvfea-AS506-Apollo11.pdf fer     # Figure 6-3
python3 tools/digitise_fer_figure.py fer-159.pgm --rotate 90 --box 596,2220,1075,1570 \
    --rows 1.2,-0.8,6 --cols 0,170,18 --from 0.6 --to 161.6 --seed 0 --step 0.2 --overlay check.ppm

# AS-506's sensed velocity by stage (datasheet §14.2)
python3 tools/pft_sensed_velocity.py
# AS-506's pitch command fitted in GE504's form (datasheet §14.5 item 1)
python3 tools/fit_as506_pitch.py
```

`pft_sensed_velocity.py` reproduces §14.2: the vector sums 3,303.57, 4,583.74
and 880.79 m/s, the pad phase's 169.088 m/s, and the integral of |a_ng|,
9,132.67 m/s, on the rows §14 had (PR 12's transcription: every row to 162 s,
then mostly 10 s apart). On every row of the table that integral is 9,132.83
m/s: shorter intervals follow the thrust's turn more closely.
