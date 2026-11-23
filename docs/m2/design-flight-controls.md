# M2: flight controls after launch, and the MFD computer

Status: **accepted by Franz on 2026-11-21**, with every recommended answer in §10 and editable LOI targets (§6). Fold it into the `docs/m2/plan.md` pass before M2 starts.

How it was made: four independent designs (Apollo-authentic-lite, an Orbiter-style planner, a mission sequencer and pilot ergonomics) were scored by two judges and then merged into this one. §8 lists what came from each.

Values marked [repo] are AS-503/Apollo 8 numbers taken from this repository. The other numbers in the mockups are illustrative. Items marked [verify] wait for D8's reading of the sources.

## 1. The design

THE DESIGN: GROUND, IU AND COMPUTER

The work after launch is split three ways, as Apollo split it. Each layer gets its own MFD or keys.

1. The ground is TRANSFER (key X, label TRN), reworked as an RTCC desk.
   - N8's planners solve every burn from the live state on a background queue.
   - Each burn is shown as a PAD, with predictions with and without it (NOW against AFTER).
   - One SET hands the burn over. It uplinks the load into the computer's P30, sets the EMS counter to ΔVC and puts the blue marker on the navball.
   - On the TLI page, SET sends GE504's seven-parameter target update to the IU instead.
   - The desk has no contact behind the Moon. It freezes at LOS and learns the result at AOS + 2 min.

2. The IU flies TLI, as option 7 and T8 already have it. The crew gets three things:
   - the XLUNAR INJECT/SAFE switch (Option+X, TB6c);
   - the choice between the first and second opportunity;
   - a TLI PAD and a live prediction, from a 3-DOF replay of the IU's own IGM.

3. The onboard computer is a CMC-lite.
   - It lives in OrbitCore and is hosted by ApolloSCS, behind a GuidanceComputer seam.
   - It shows on a new CMC MFD (key C) as a DSKY with English prompts.
   - Its programs are P00, P15 (TLI monitor), P30 (External ΔV), P40 (SPS), P41 (RCS), P47 (thrust monitor) and P61/P62 (entry setup). P63-P67 are E8's equations.
   - P40 runs this sequence:
     - It slews to the burn attitude, roll included, under G&N AUTO.
     - It counts Average-G from TIG-30 s, so the ullage counts.
     - At TIG-5 s it asks V99, "enable ignition?". Return answers it.
     - It lights the SPS at TIG and steers on VG.
     - It cuts off at the predicted tail-off.
     - It shows the N85 residuals, each with the RCS key that nulls it.
   - Z with the EMS counter remains the SCS way to fly any burn. Z always means THRUST ON at once, and is never modal.

Around the three layers:
- one flight key map kept as a data table and tested on Linux, which also generates the help;
- a warp governor in the core, with hard stops at TB6, ignition and TIG, and soft stops (LOS, AOS, SOI) reached with the backslash key;
- FDAI error needles and a HUD burn box, readable with both MFDs closed;
- a few fixes from the code map: the IU owns the J-2 after T5, Y and ORBIT share one target, the dead band gets a switch, and PTC gets a key.

WHY THIS BASE
The judges split. Judge 1 chose apollo-lite for its realism and its M3 seam. Judge 2 chose orbiter-planner for usability and the smallest change to decision 49.

I build on apollo-lite's architecture for two reasons:
- It is the only proposal where the computer is a real core module that owns the loaded burn and TIG, and that an M3 AGC can replace through one seam.
- Franz asked for a computer.

Judge 2's objections are answered in the controls, not by removing the computer:
- Z is never modal. V99 is answered by Return, so a tired pilot cannot light early by obeying a prompt.
- Return enters digits when some are keyed and means PRO otherwise. That removes the PRO/ENT trap.
- One SET replaces UPL plus EMS. P30 needs two Returns, not four, and NXT picks P40 or P41 for the load.
- An SPS burn costs about eight key presses plus the trim taps, against apollo-lite's thirteen.

From orbiter-planner, the TLI page in four states with the IGM replay, NOW/AFTER, and results stamped with the epoch of their input state. From sequencer, the live NEXT timeline, the corridor rule for cancelling an MCC, the FINAL PAD freeze, re-planning after a missed burn, and Apollo 7 as the first proof. From pilot-ergonomics, the controls layer.

PHYSICS-DRIVEN
Nothing is canned.
- TB6P comes from the IU's own restart-preparation test, run on the propagated orbit with its LH2 venting.
- GO FOR TLI checks the S-IVB's ΔV margin from the propellant actually left, so an S-II engine-out shows.
- Every MCC is an outcome of the sim's own dispersions: the IGM cutoff, the SPS tail-off, the 0.5° dead band, the CG trim, a late PRO and the pilot's trim. An MCC is cancelled only when the trajectory is inside the corridor, not on ΔV alone, because 0.34 m/s moves pericynthion about 131 n mi.
- LOI-1 and TEI are flown on onboard data behind the Moon. An early AOS means no LOI.

DECISIONS
- Decision 48 is kept, and the meaning of SET is now defined.
- Decision 49, and M1.5's decision 9 ("automatic P40 waits for M3"), are amended. This is the one real owner call.
  - The new rule: under G&N the computer lights the SPS at TIG after the crew's Return at V99, and cuts off on VG.
  - Z with the EMS cutoff stays the SCS mode for every burn.
  - This takes option 6 in a reduced form: VG steering, which for External ΔV equals an inertial hold when nothing is off. It costs about 1 d, not 1.5 d.
- Option 7 is kept. Decision 45's precedent is extended: CMC-lite is the no-AGC mode and M3's test oracle.

To be candid: under time warp it is the warp governor, not the computer, that removes the timing error. The amendment buys authenticity, and the computer Franz asked for. If he keeps decision 49, everything else stands: P40 shows a countdown, "THRUST ON AT TIG: Z", and the EMS counter cuts off. That saves about 1 d.

COST
- About +12 d (range 10-14.5) on the roughly 45 d M2 flight estimate.
- A cut list removes about 2.6 d without breaking the loop.
- The first increment flies Apollo 7's deorbit through DEORBIT SET, P30 and P40 on M1.5 hardware, before any T8 or N8 code lands.

## 2. TLI on Apollo 8, from the left seat

TLI on Apollo 8, from the left seat. The scenario is "Apollo 8: pad to splashdown" or "Apollo 8 in parking orbit". Times marked [repo] are AS-503's, from docs/m16/design-apollo8-physics.md. Other readings are illustrative.

1. Insertion, 0:11:35 GET (694.98 s [repo]).
   - The IU logs the S-IVB cutoff, T5, then "orbital guidance: local horizontal". The stack holds local horizontal, heads down, and the HUD autopilot column shows HOLD IU.
   - The strip shows NEXT TB6 -2:29:24. That is the IU's own prediction from its restart-preparation test.
   - The CMC sits in P00 on the CM's standby SCS.
   - Z and X on the stack are refused with a log line: "J-2 restart is the IU's". This closes today's relight loophole.

2. Set up the displays.
   - Left Shift+Tab, then Shift+X: TRANSFER opens on TLI, because the vessel carries an IU with out-of-orbit targeting.
   - Right Shift+Tab, then Shift+C: the CMC.

3. Insertion check.
   - Right Shift+O (V82) shows HAPO, HPER and TFF about the Earth, about 100 n mi circular.
   - Return goes back to P00.

4. Read the TLI PAD on TRANSFER.
   - TB6P 2:40:59.5, TIG 2:50:37.1 (TB6+577.6), BT 5:18, VI at cutoff 35,505 ft/s [repo].
   - The ignition attitude as navball angles, and SEP ATT "TB7 inertial hold".
   - The pericynthion and free-return EI γ predicted at the IGM cutoff (IU replay plus DOP853), and the S-IVB's ΔV margin from its actual propellant.
   - The page re-solves every 10 s. The LH2 venting raises apogee by about 6.4 n mi before reignition [repo], and TB6P moves with it.

5. Optional, before TB6: the ground's retarget.
   - Shift+G until TGT reads HPC, then Shift+] or Shift+[ to change the pericynthion target. Wait for CALC.
   - SET (Shift+S) sends the seven-parameter update. The log reads "IU target update accepted", and the page reads "IU TARGETS RTCC 2:21:40".
   - Shift+C goes back to the prestored set.
   - TGT on OPP, then Shift+], picks opportunity 2 the same way.
   - SET is dim, reading "UPDATE NOT NEEDED", when the prestored targets are within tolerance. It is refused once TB6 has started ([verify] GE504's window).

6. About 2:27, GO FOR TLI.
   - When the checks pass, the page reads "RTCC: GO FOR TLI" and the log "MCC: GO for TLI". The checks: a positive S-IVB margin, a free return in the corridor, no failure flagged, and XLUNAR at INJECT.
   - No key is needed, because the switch already sits at INJECT. An engine-out on the ascent (F then a digit) shows as "NO-GO: S-IVB DV".

7. Load P15 on the CMC.
   - Right Shift+V (PRG), right Shift+1, right Shift+5, then Return.
   - P15 copies the TLI PAD as it stands and counts down to TB6P.

8. Warp to TB6.
   - The backslash key (warp to the next stop) climbs to 100x, steps down as the stop nears, and stops at 1x at TB6-60 s. That takes about 10 s of real time.
   - The log reads "IU: TB6 in 60 s".

9. TB6, 2:40:59.5 [repo].
   - The IU logs "TB6 restart preparation".
   - TRANSFER and P15 show the sequence as T8's SIVBRestart reports it:
     - O2H2 burner on at about TB6+41 s [verify];
     - LH2 and LOX repressurisation;
     - chilldown;
     - the XLUNAR window counting down.
   - The warp is capped at 10x. From now on Space (CSM/LV SEP) needs two presses within 2 s, because it would be an abort separation.

10. The crew's one TLI decision.
    - To fly: do nothing.
    - To inhibit: Option+X while the window is open.
      - The IU logs "TLI inhibit (TB6c)", safes the S-IVB and returns to local horizontal.
      - TRANSFER re-solves opportunity 2 about one revolution later on the orbit as it now is, and NEXT moves every row that depends on TLI.
      - Option+X again sets INJECT for opportunity 2.
    - After the window closes, Option+X logs "XLUNAR SAFE too late".
    - A second inhibit through opportunity 2 means no TLI. NEXT then offers the Earth-orbit alternate on DEORBIT, which is Apollo 11's no-go path.

11. Ignition-100 s.
    - The backslash key runs on to the IU's stop at 1x.
    - From here to cutoff the RCS keys no longer take the attitude from the IU (logged).
    - The APS ullage comes on about 77 s before ignition (AS-506's figure; [verify] AS-503's). P15 reads ULLAGE ON.
    - The navball's command marker shows the IU's ignition attitude, to compare with the PAD.

12. Reignition, 2:50:37.1 [repo].
    - LV ENG lights from the start command until thrust is OK ([verify] the timing).
    - The IGM steers: pitch and yaw on the J-2, roll on the APS.
    - P15 counts TFI up and TFC down from the IGM's own T-go, and shows VI climbing toward the PAD's 35,505 on a bar, with H, HDOT, γ and the attitude error.
    - TRANSFER shows "IF CUTOFF NOW" and "AT IGM CUTOFF": the pericynthion and EI γ, refreshed every real second.
    - The log shows the EMR shift from 4.5 to 5.0.
    - The warp may go to 10x.

13. The crew does not steer.
    - X is refused ("TLI is the IU's"; [verify] the crew's real S-IVB cutoff authority in D8).
    - The only abort is Space twice, an abort separation.

14. Velocity cutoff, 2:55:55.5 [repo], after about 318 s. TB7 starts.
    - P15 DSP CUTOFF shows VI at cutoff against the PAD, with the difference, and BT.
    - TRANSFER compares actual and target at cutoff+10 s: 346.73 km, 10,822.05 m/s, γ 7.897°, i 30.636°, e 0.97553 [repo].
    - It also gives the MCC-1 preview, solved from the state actually reached. That shows the IU's real dispersion, not a canned value.

15. TB7.
    - The IU turns to the separation attitude and holds it inertially.
    - The backslash key reaches the soft stop "SEP ATT HELD".
    - Return on P15 goes to P00.

16. About 3:20:59, CSM/LV separation: Space, one press in TB7.
    - The SLA panels go, the LTA-B stays on the S-IVB, and the SCS fires 3 s of +X.
    - The CMC becomes the CSM's computer and opens P47, which counts the body ΔV.
    - Y becomes the S-IVB.

Key count: TLI itself needs no key, because XLUNAR stays at INJECT. A by-the-book TLI takes about 10 presses: the MFD setup, V82, P15 and the warp-to keys. The retarget is optional.

## 3. MFD pages

CONVENTIONS
- The grid is the real one: 40x24 (MFDPage). The body uses columns 4-35. Button labels sit in columns 0-2 and 37-39 on rows 4, 7, 10, 13, 16 and 19.
- A lower-case label is dim: that button does nothing now.
- On the CMC page, '*' means the verb and noun flash: the computer waits for the crew. A lit lamp is shown in brackets, for example [UPLK].
- Numbers are illustrative except AS-503/Apollo 8 values from the repo (TB6 2:40:59.5, IGN 2:50:37.1 = TB6+577.6, cutoff 2:55:55.5, VI 35,505 ft/s, LOI-1 246.9 s into 168.5 x 60.0 n mi).
- These were rendered and width-checked by render.py into pages.txt.

TRANSFER buttons (the same on every page; they keep DEORBIT's keys):
- Left: PG< Shift+, / PG> Shift+. / T- Shift+- / T+ Shift+= / STP Shift+I / CLC Shift+R.
- Right: TGT Shift+G / V- Shift+[ / V+ Shift+] / MOD Shift+M / SET Shift+S / CLR Shift+C.
- Pages, in order: NEXT, TLI, MCC, LOI, TEI, ENT. MOD switches between text and the Earth-Moon plot.

CMC buttons (the same in every program, like a DSKY):
- Left: PRG Shift+V (V37) / DSP Shift+D / V82 Shift+O / KRL Shift+K / + Shift+= / - Shift+-.
- Right: PRO Shift+P / ENT Shift+Return / CLR Shift+Delete / RST Shift+R / NXT Shift+N (selects P40 or P41 for the load) / the sixth slot is free.
- Shift+0-9 key digits.
- Unshifted Return anywhere is ENTR if digits are keyed, otherwise PRO.

1. TRANSFER TLI, parking orbit before TB6 (the ground's TLI computer)
```
+----------------------------------------+
|TRANSFER TLI  OPP 1        GET 002:26:40|
|                                        |
|    IU TARGETS PRESTORED  XLUNAR INJ    |
|    TLI PAD (RTCC 002:26:37)            |
|PG< TB6P  002:40:59.5     -14:19     TGT|
|    TIG   002:50:37.1  TB6+577.6        |
|    BT    05:18      VI 35505 FT/S      |
|PG> IGN ATT HDG 107 PIT +03 RLL 180   V-|
|    SEP ATT TB7 INERTIAL HOLD (IU)      |
|                                        |
|t-            NOW (PREDICTED CO)      V+|
|    PERICYN   60.4 NM  069:10:39        |
|    FREE RTN  EI GAM -6.48   YES        |
|t+  S-IVB DV  MARGIN +744 FT/S       MOD|
|                                        |
|    TGT HPC 60.0 NM   SOLN 60.4         |
|stp UPDATE NOT NEEDED (<2 NM)        set|
|                                        |
|    RTCC: GO FOR TLI                    |
|CLC OPP 2 TB6 004:09:4x (IF SAFE)    CLR|
|                                        |
|    CALC 3 S AGO   STATE 002:26:37      |
|    PRED: IU IGM REPLAY + DOP853        |
|                                        |
+----------------------------------------+
```
- T-, T+ and STP are dim because the IU owns the timing.
- TGT cycles OPP, HPC and the free-return EI γ.
- SET is the seven-parameter uplink to the IU. It is lit only when the update moves the pericynthion by more than 2 n mi, and only before TB6.
- Other states of the page:
  - in TB6, the IU's sequence lines and the XLUNAR window;
  - in burn 2, "IF CUTOFF NOW" and "AT IGM CUTOFF", with the pericynthion and EI γ refreshed every second;
  - after cutoff, actual against target at cutoff+10 s, and the MCC-1 preview.

2. CMC P15 TLI MONITOR during S-IVB burn 2 (the onboard TLI monitor)
```
+----------------------------------------+
|CMC  P15 TLI MONITOR       GET 002:53:21|
|                                        |
|    PROG 15   VERB 16   NOUN 95         |
|    THE IU FLIES TLI: MONITOR           |
|PRG R1 TFI      +02:44.0             PRO|
|    R2 TFC      -02:34.4                |
|    R3 VI        30040 FT/S             |
|DSP PAD VI CO 35505   [####....] 45% ENT|
|    H 108.3 NM  HDOT +212  GAM +1.9     |
|    ATT ERR 0.3 DEG TO IU CMD           |
|V82 J-2 THRUST OK   EMR 5.0          CLR|
|    IU IGM TGO 2:34  CO 002:55:55       |
|                                        |
|KRL IF CO NOW (CONIC) HA  9850 NM    RST|
|    LV ENG .  LV RATE .  LV GUID .      |
|    XLUNAR INJECT  WINDOW CLOSED        |
| +  X REFUSED  ABORT: SPACE TWICE    NXT|
|                                        |
|    DSP: TB6 / BURN / CUTOFF            |
| -                                      |
|    UPLK .   PROG .   OPR .   KREL .    |
|    KEY  __                             |
|    IU STEERS - HANDS OFF               |
|                                        |
+----------------------------------------+
```
- P15's noun (N95) and its TIG handling are [verify] in R-577.
- The "IF CO NOW" line is the CMC's own conic. The propagated pericynthion belongs to the ground and is on TRANSFER.

3. CMC P30 after SET, at the N42 check (the computer page; the uplink landed here)
```
+----------------------------------------+
|CMC  P30 EXTERNAL DV       GET 003:53:02|
|                                        |
|    PROG 30   VERB 06   NOUN 42  *      |
|    CHECK THE CMC'S PREDICTION          |
|PRG LOAD MCC-1 SPS/G&N  RTCC UPLINK  PRO|
|    TIG 011:00:00.0   TTG 07:06:58      |
|    N81 DVX +23.9 DVY -2.1 DVZ +5.8     |
|DSP DVT 24.7  BT 2.6 S  DVC 21.9     ENT|
|    R1 HAPO    9999.9 NM  (OVFL)        |
|    R2 HPER    +101.2 NM  EARTH         |
|V82 R3 DVT       +24.7 FT/S          CLR|
|                                        |
|    PROPAGATED (PLANNER QUEUE)          |
|KRL PERICYN  60.3 NM  069:10:41      RST|
|    EI GAM -6.49     RTCC DIFF 0.3      |
|    ATT HDG 041 PIT +31 RLL 000 LV      |
| +  ULLAGE +X 2 JETS 15 S (U)        NXT|
|                                        |
|    RETURN: ACCEPT, BACK TO P00         |
| -  PRG 00: ABANDON THE LOAD            |
|    [UPLK]   PROG .   OPR .   KREL .    |
|    KEY  __                             |
|    N42 CHECK: RETURN TO ACCEPT         |
|                                        |
+----------------------------------------+
```
- P30 has two steps. The first shows the load, N33 and N81 together, and the crew can re-key any register. The second is this N42 check.
- An uplink drops the CMC into the first step. Hand-keying a PAD (PRG 30) starts there too, with R1-R3 keyed by Shift+digits and Return.
- ΔVC is ΔVT less the predicted SPS tail-off.

4. CMC P40 at TIG-5 s, V99 (the burn page: the crew's go-ahead)
```
+----------------------------------------+
|CMC  P40 SPS  MCC-1  AVG G GET 010:59:55|
|                                        |
|    PROG 40   VERB 99   NOUN 40  *      |
|    ENABLE ENGINE IGNITION?             |
|PRG R1 TFI       -00:05              PRO|
|    R2 VG         +24.5 FT/S            |
|    R3 DVM         +0.2 FT/S            |
|DSP                                  ENT|
|    ULLAGE +X ON (U)  PAD 2J 15 S       |
|    ATT G&N AUTO   ERR 0.2 DEG          |
|V82 EMS DVC 21.9 (MONITOR)           CLR|
|    GIMBAL TEST OK  TRIM P+0.9 Y-0.4    |
|                                        |
|KRL RETURN: IGNITE AT TIG            RST|
|    NO RETURN: NO IGNITION              |
|    Z: SPS ON NOW (SCS, EMS CUTS)       |
| +  X: DV THRUST OFF                 NXT|
|                                        |
|    WARP 1X CAP TIG-30 TO TIG+5         |
| -                                      |
|    UPLK .   PROG .   OPR .   KREL .    |
|    KEY  __                             |
|    V99 ENABLE IGNITION? RETURN         |
|                                        |
+----------------------------------------+
```
- The P40 sequence before this:
  - V50N18 "PLEASE PERFORM AUTO MANEUVER": Return or G, and the CMC slews, roll included, at 0.5°/s;
  - V06N18 when the attitude is reached;
  - an automatic, logged gimbal test;
  - V06N40 counting down;
  - a blank from TIG-35 s to TIG-30 s, then AVG G.
- VG has already dropped by the ullage that Average-G counted.

5. CMC P40 in the burn, LOI-1 behind the Moon
```
+----------------------------------------+
|CMC  P40 SPS  LOI-1  LOS   GET 069:10:15|
|                                        |
|    PROG 40   VERB 06   NOUN 40         |
|    SPS ON (CMC)  STEERING ON VG        |
|PRG R1 TFC       -02:12              PRO|
|    R2 VG      +1667.4 FT/S             |
|    R3 DVM     +1330.2 FT/S             |
|DSP                                  ENT|
|    STEER ERR 0.2  GMBL P+0.6 Y-0.3     |
|    HOLD CMC   RATES 0.1 DEG/S          |
|V82 EMS DVC 1663.6 COUNTING          CLR|
|                                        |
|    AFTER CUTOFF (CMC CONIC)            |
|KRL HA 168.6  HP 60.0 NM  MOON       RST|
|                                        |
|    NO CONTACT  AOS 069:33:5x           |
| +  X: CUT OFF NOW (DV THRUST)       NXT|
|                                        |
|    WARP 10X MAX  CUTOFF TO THE STEP    |
| -                                      |
|    UPLK .   PROG .   OPR .   KREL .    |
|    KEY  __                             |
|                                        |
|                                        |
+----------------------------------------+
```

6. CMC P40 after cutoff, V16N85 residual trim
```
+----------------------------------------+
|CMC  P40 SPS  LOI-1  LOS   GET 069:12:40|
|                                        |
|    PROG 40   VERB 16   NOUN 85  *      |
|    NULL THE RESIDUALS ON THE RCS       |
|PRG R1 VGX    +0.8 FT/S     KEY U    PRO|
|    R2 VGY    -0.3 FT/S     KEY J       |
|    R3 VGZ    +0.4 FT/S     KEY K       |
|DSP                                  ENT|
|    CUTOFF 069:12:27.3  CMC (VG)        |
|    BT 04:06.9   DVM 2997.2             |
|V82 EMS -3.8 (TAIL-OFF COUNTED)      CLR|
|    LATE IGN +0.0 S                     |
|                                        |
|KRL TAP THE KEY SHOWN; CTRL = FINE   RST|
|    ALL BELOW 0.2 FT/S: RETURN          |
|                                        |
| +  THEN N44 HA HP TFF, THEN P00     NXT|
|                                        |
|                                        |
| -                                      |
|    UPLK .   PROG .   OPR .   KREL .    |
|    KEY  __                             |
|    N85 TRIM, THEN RETURN               |
|                                        |
+----------------------------------------+
```
- Body axes: +x forward, +y right, +z down. The keys are U/O for x, L/J for y and K/I for z.
- P41 has the same page with no SPS lines: at TIG it opens on N85, and the crew thrusts until VG is nulled.

7. TRANSFER MCC, after TLI (the ground's burn page; same 12 buttons on every page)
```
+----------------------------------------+
|TRANSFER MCC-1  RTCC       GET 003:41:06|
|                                        |
|    MCC-1  SPS/G&N   FREE RETURN        |
|    TIG 011:00:00.0   TTG 07:18:54      |
|PG< N81 DVX +23.9 DVY -2.1 DVZ +5.8  TGT|
|    DVT 24.7  BT 2.6 S   DVC 21.9       |
|    ATT HDG 041 PIT +31 RLL 000 LV      |
|PG> ULLAGE +X 2 JETS 15 S             V-|
|                                        |
|               NOW        AFTER         |
|T-  PERICYN  178.4 NM    60.0 NM      V+|
|    PC TIME  069:12:02  069:10:39       |
|    EI GAM    -5.21      -6.50          |
|T+  CORRIDOR  OUT        IN          MOD|
|                                        |
|    BURN REQUIRED (OUT OF CORRIDOR)     |
|STP PAD FINAL AT 010:00  (LIVE NOW)  SET|
|    LOADED  ---     CMC P00 ACCEPT      |
|                                        |
|CLC SET: UPLINK P30 + EMS + MARKER   CLR|
|                                        |
|    CALC 2 S AGO   STATE 003:41:04      |
|    PRED: DOP853 + FINITE BURN          |
|                                        |
+----------------------------------------+
```
- TGT cycles the slot (MCC-1 to MCC-7, or FREE), the target type (free-return pericynthion plus EI γ, B-plane, EI γ plus landing longitude, SEP for an evasive burn) and the target value.
- After a load, a DIFF line shows the live solution against the frozen load. After the FINAL PAD time, changes show as "SOLN MOVED x FT/S", and SET again acts as the PAD update.
- Inside the corridor with a small ΔV, the page reads "MCC-n NOT REQUIRED".
- LOI and TEI use the same layout, with LOS/AOS lines (AOS with and without the burn). Their SET's uplink is refused during LOS with "NO CONTACT".

8. TRANSFER NEXT, the live timeline (sequencer graft; no sequencer engine)
```
+----------------------------------------+
|TRANSFER NEXT  APOLLO 8   GET 002:27:00 |
|                                        |
|      GET        EVENT          T-      |
|    + 000:11:35  INSERTION    DONE      |
|PG< + 002:27:00  GO FOR TLI   LOGGED tgt|
|    ~ 002:40:59  TB6 OPP 1   -13:59     |
|    ~ 002:50:37  TLI IGN     -23:37     |
|PG> ~ 002:55:55  TLI CUTOFF  -28:55   V-|
|    = 003:20:59  CSM/LV SEP   CREW      |
|    = 011:00:00  MCC-1  SPS   PLAN      |
|t-  ~ 055:38:4x  MOON SOI             V+|
|    = 061:00:00  MCC-2 SLOT   PLAN      |
|    ~ 068:58:3x  LOS                    |
|t+  = 069:08:20  LOI-1  SPS   PLAN   mod|
|    = 089:19:17  TEI REV 10   PLAN      |
|    = 146:46:13  EI                     |
|stp                                  set|
|    ALT  OPP 2 TB6 004:09:4x            |
|    ALT  EARTH ORBIT (DEORBIT)          |
|CLC                                  clr|
|    \ WARPS TO: TB6-1:00 (HARD)         |
|    + DONE ~ LIVE = PLAN x NOT REQ      |
|    ! MISSED * WAITS FOR THE CREW       |
|                                        |
+----------------------------------------+
```
- The rows come from the same sources the warp governor reads: the IU's tliStatus, the CMC's load, N8's plans, LunarVisibility and E8. The nominal flight-plan rows come from the scenario.
- V- and V+ scroll the list.

HUD burn box (OrbitSim's InstrumentCluster, beside the navball; drawn from BurnCue data). It shows while a load exists, so the burn can be flown with both MFDs closed:
```
+-------------------------------+
| P40 LOI-1   TIG 069:08:20.4   |
| TFI -00:05  V99 IGN? RETURN   |
| VG 2997.4  DVM 0.2 EMS 2993.8 |
| BT 04:06.9  ERR 0.2  G&N AUTO |
| LOS 068:58:31  AOS 069:33:5x  |
+-------------------------------+
```
- FDAI error needles for roll, pitch and yaw are drawn on the navball from Navball.attitudeError, which is computed today and drawn nowhere. They are ±5° full scale and show whenever a hold has a command.
- The vehicle panel's program line repeats any flashing prompt in amber, for example "CMC P40 V99 ENABLE IGNITION? Return".

## 4. Keys

Checked on main ca1b875:
- AppModel.handleKeys binds H M P . , / C V [ ] F9 F10 B F12, then Space 9 Z X T F 1-8 0.
- InstrumentModel.handle binds N, Y, F2, ` and §. RCSKeyControl binds W S A D Q E and I K J L U O.
- G, R, ; ' \ and Tab are unbound unshifted.
- Return and Delete are not PhysicalKeys (PhysicalKey.swift:94-95).
- KeyboardState.keyDown routes only Shift away from the flight keys, so Option+X today reaches the flight controls as plain X and cuts the throttle.
- ApolloSCS.wideDeadband has no caller.

NEW, UNSHIFTED (flight)
- Return (new PhysicalKey .returnKey, 0x24; keypad Enter 0x4C maps to it): ENTR to the focus vessel's computer when digits are keyed, otherwise PRO when the computer flashes. Otherwise it does nothing.
  - It answers V50N18 (and selects G&N AUTO), V99 (the computer lights at TIG), the P30 checks, N85 done, N44, the P61 checks and P15's exit.
  - It never stages.
  - The keying buffer lives in the computer, so it works with the CMC MFD off screen. The HUD repeats the prompt.
  - Conflict check: unbound. F-capture: F then Return cancels the capture and then acts, as any key does. [Mac check] No SwiftUI default button may take Return before GameView.keyDown.
- G: G&N AUTO, "fly the computer's attitude".
  - On the stack it is the IU's command, the same as 8 there.
  - On the CSM it is the CMC's: the P40/P41 slew and hold, the PTC set-up attitude, the P62 entry attitude. It is written to attitudeCommand under the existing .attitudeHold, so there is no new autopilot case.
  - On the CM it selects the CMC entry mode.
  - With no computer attitude it is refused with a log line.
  - HUD autopilot column: a new row "G&N G".
  - Conflict check: unbound. F then G cancels the capture and then acts, which is harmless. Cmd+G goes to the menu.
- \ (kVK_ANSI_Backslash 0x2A): warp to the next stop, hard or soft.
  - The governor climbs and steps down so that the next stop stays at least 4 s of real time ahead, and stops at 1x.
  - Pressed again at a stop, it goes on to the following one. , or / cancels it.
  - It is refused in powered flight.
  - Conflict check: unbound. On Franz's Italian ISO keyboard physical 0x2A is the key left of Return. Keys are read as codes, so the help names the key by position.

NEW, OPTION LAYER (panel switches)
How the layer works:
- KeyboardState gets an Option queue. Option+key goes there, is never held and never reaches takePressed.
- Bound chords are always consumed and refused with a log line where they do not apply. Option+X can therefore never act as X.
- Unbound Option+key passes through as the plain key, so a held Option never blocks the RCS or X.
- Shift wins over Option: Shift+Option+key goes to the MFD.

The chords:
- Option+X: XLUNAR INJECT/SAFE (TB6c), a toggle.
  - It is honoured inside the IU's TB6 window ([verify] in GE504 and MSFC-MAN-503). Outside it the log reads "too late" or "no TB6".
  - On a vessel without an IU it is refused ("no S-IVB"), never cut.
  - It shows on the vehicle panel and on P15.
- Option+D: the SCS dead band, narrow 0.5° or wide 5°. It is the first caller of ApolloSCS.wideDeadband.
- Option+R: PTC on or off, on the CSM with the SM aboard.
  - If +X is more than 5° from perpendicular to the Sun line, the CMC first flies to the PTC attitude under G&N AUTO.
  - Then the wide band, and a roll at 0.3°/s (C8's 0.1-0.3).
  - It is refused within 10 min of a loaded TIG and while the SPS burns. Pressed again, it captures the attitude, as 8 does.
- Option+U: UP TLM, ACCEPT or BLOCK, ACCEPT by default. In BLOCK, SET's uplink is refused (cut list).

macOS: Option's dead keys (E, U, I, N, `) matter only in text fields, and the game reads key codes. [Mac check] Each chord still reaches keyDown on the Italian keyboard. Fallbacks if any fails: ; for XLUNAR, ' for PTC, and the CMC page for the dead band.

CHANGED
- Z: always SCS THRUST ON at once, as today. It is never modal.
  - In P40 before TIG it makes the burn an SCS burn: the EMS counter cuts it off, and the CMC monitors (N40), then N85.
  - On the stack after T5 it is refused ("J-2 restart is the IU's"), through FlightProgram.allowsPilotThrottle and the IU re-asserting its throttle. This closes the inferred relight loophole.
  - After an EMS cutoff with no reload, it needs a second Z within 2 s ("SPS ON WITHOUT ΔV COUNTER"). This fixes the counter quirk: cutoffDone stays set until loadDeltaV.
- X: the ΔV THRUST switches.
  - It cuts the SPS. In a CMC burn the CMC goes on to N85.
  - On the stack during TLI it is refused ("TLI is the IU's; Space twice to abort"), until D8 verifies a crew S-IVB cutoff.
- Space: during TB6 and the TLI burn, CSM/LV SEP needs two presses within 2 s (an abort separation), using the CM/SM guard. In TB7 it is one press, as today.
- RCS rotation keys on the stack: from ignition-100 s to cutoff they do not take the attitude from the IU (logged). The takeover in orbit, handed back with 8, is unchanged.
- RCS keys on the CSM in a CMC hold or burn: they take the attitude (SCS takeover, logged), as today with the IU. The CMC keeps VG accounting and cutoff. G hands the attitude back.
- 8: on the CSM, the SCS hold of the captured attitude. It clears G&N AUTO, so the CMC stops writing attitudeCommand. On the stack it still hands back to the IU.
- Y: one target, shared with ORBIT's TGT and NT. At CSM/LV SEP the S-IVB becomes the target if none is set.
- 1-7 (optional, cut list): hold the roll in LVLH captured at selection instead of only damping it. It goes in only if Apollo 7's CM RCS pin stays within the -O margin.
- H: the help is generated from FlightKeyMap and adds the F9, F10 and F12 lines it lacks today.

MFD KEYS (with Shift)
- SEL page:
  - Shift+X for TRANSFER (as S8 plans) and Shift+C for the CMC, beside O, S, M, D and E. All are distinct and none is a SEL, MNU or PWR key (F1, Tab, `, §, Esc).
  - Fix: selectPage writes every mode on row buttonRow(i % 6) at column 4, so a seventh mode overwrites ORB. Modes 7-12 go beside the right buttons.
- TRANSFER, on every page:
  - left: , PG< / . PG> / - T- / = T+ / I STP / R CLC;
  - right: G TGT / [ V- / ] V+ / M MOD / S SET / C CLR.
  - All twelve are distinct. - = I G [ ] S C are DEORBIT's T- T+ STP TGT V- V+ SET CLR, so muscle memory carries over.
  - No typed entry on TRANSFER: values are nudged by STP steps.
- CMC:
  - left: V PRG (V37) / D DSP / O V82 / K KRL / = + / - -;
  - right: P PRO / Return ENT / Delete CLR (new PhysicalKey .delete, 0x33) / R RST / N NXT;
  - Shift+0-9 key digits.
  - No CMC button uses a digit, so digits always type. ENT with nothing keyed is OPR ERR, and a keyed value is never dropped silently.
- DEORBIT: no new key. SET now loads the core plan: an uplink to CMC P30 when in P00 with UP TLM ACCEPT, plus the EMS counter (ΔVC) and the marker. CLR clears all three.
- ORBIT: TGT and NT write the shared target.

DELIBERATELY NOT USED
- Ctrl+arrows and Ctrl+Space (Mission Control, input source).
- Cmd chords, which stay with the menu.
- The F-row for flight functions (media keys without fn; F3, F4 and F11 are system keys).
- Plain R, kept free because it sits between E (roll) and T (kill rotation).
- Plain ; and ', kept as fallbacks.
- Unshifted Delete.

TESTS
FlightKeyMap (OrbitInstruments, Linux) is the single table that AppModel dispatches through. Its tests check for no duplicate chord, no macOS-reserved chord, a help line for every command, and an Option queue that never feeds takePressed.

## 5. The rest of the flight: separation, MCC, LOI, TEI, entry

GENERAL ATTITUDE AND BURN CONTROL (every phase)
- Attitude modes:
  - 0: free (pulses only);
  - T: rate damping;
  - 8: SCS hold, captured;
  - G: G&N AUTO, the computer's attitude (IU, CMC or CMC entry);
  - 1-7: pointing, with an optional LVLH roll hold;
  - Option+R: PTC;
  - Option+D: dead band.
- One loaded burn lives in the core (the CMC's load). ActiveManeuver, the navball marker, the HUD burn box and the strip all read it. MFDVesselData.maneuver goes away.
- Every burn follows the same loop:
  - TRANSFER or DEORBIT SET;
  - P30's two Returns;
  - NXT;
  - Return at V50N18;
  - the hard stop at TIG-2 min;
  - U for the PAD's ullage;
  - Return at V99;
  - the cutoff;
  - N85 taps;
  - Return.
- The SCS way is always available: point (G, or by hand then 8), Z at TIG, and the EMS counter cuts off.
- Warp:
  - hard stops: TB6-60 s, ignition-100 s, TIG-2 min, a 1x cap from TIG-30 s to TIG+5 s, EI-10 min;
  - soft stops (LOS, AOS, SOI, pericynthion, separation attitude) are honoured only by the backslash key.
- Only the focus vessel's events stop the warp. The S-IVB's slingshot never does.

CSM SEPARATION AND THE S-IVB (Apollo 8 had no TD&E)
- Space in TB7 separates: the SLA panels go, the LTA-B stays on the S-IVB, and the SCS fires 3 s of +X.
- The CMC wakes on the CSM in P47 (V16N83, body ΔV since separation). Y targets the S-IVB, so P47 and the strip show range and range rate.
- The turnaround is flown by hand (hold S), with 8 to hold.
- Evasive burns ([verify] about 3:40, and about 7.7 ft/s near 4:45):
  - either by hand under P47;
  - or the TRANSFER MCC page with target type SEP: the closest approach with and without the burn, the S-IVB propagated with T8's TB7 vent, LOX-dump and APS schedule. Then SET, NXT (P41), Return to slew, and at TIG the N85 keys to null VG.
- The slingshot is the IU's alone (LH2 vent, LOX dump, two APS burns). It is logged, and visible by switching focus with [ or ].
- Option+R starts PTC afterwards.

MIDCOURSE CORRECTIONS
- The MCC page solves slots MCC-1 to MCC-7 at the scenario's flight-plan TIGs ([verify] in D8), or a FREE TIG.
- Targets: the free-return pericynthion altitude and time plus EI γ, the B-plane, or, on the transearth leg, EI γ with the landing longitude.
- Engine: the SPS (P40) above 5 ft/s and the RCS (P41) below. This is a scenario setting. MCC-2's 1.4 ft/s [verify] and MCC-5's -4.8 ft/s go on the RCS.
- NOT REQUIRED needs both a predicted pericynthion altitude and time, and EI γ, inside the corridor, and a small ΔV. That reproduces the cancelled MCC-3 and MCC-4 without the 0.34 m/s ≈ 131 n mi trap.
- NOW against AFTER makes skipping an informed choice.
- The FINAL PAD freezes at the flight-plan PAD time, with SOLN MOVED and 1 s hysteresis on the warp stops.
- A burn not lit by TIG+10 s is marked MISSED and re-planned at the next slot.
- Apollo 8's MCC-1 under-burn is not scripted. Whatever residual the sim leaves shows on N85 and grows the next MCC.

LOI-1 AND LOI-2
- After the Moon SOI crossing the desk opens on LOI. LOI-1 (LunarOrbitPlanner, 60 x 170 n mi, TIG centred on the burn, behind the Moon) shows LOS, and AOS with and without the burn.
- GO FOR LOI requires:
  - the CMC's load within 0.5 ft/s of the live solution;
  - the EMS set;
  - SPS propellant for LOI-1 + LOI-2 + TEI with reserve, from the tanks actually left;
  - TIG after LOS.
- SET must happen before LOS. At LOS the desk freezes ("NO TRACKING"), and SET's uplink and CLC go dim.
- The CMC flies P40 alone: 246.9 s into 168.5 x 60.0 n mi [repo].
- At AOS + 2 min the desk reacquires and shows the orbit achieved. With no burn, AOS comes early, at the flyby's real time: "AOS EARLY: NO LOI". An LOI no-go keeps the free return as the live alternate.
- LOI-2 (9.6 s, 134.8 ft/s, 60.7 x 59.7 n mi [repo]) uses the same page and flow.
- The ten revolutions:
  - V82 gives HAPO and HPER about the Moon;
  - ORBIT shows the drift under GRGM900C;
  - NEXT lists each LOS and AOS (soft stops, the backslash key to skip);
  - the lunar MAP's LOS/AOS shading is M8's.

TEI
- The TEI page: the end of rev 10 (about 89:19:17), EI γ -6.50° and the landing longitude, with the TEI for later revs kept as block-data alternates.
- The ullage cue "+X 15 S, STORAGE EMPTY" comes from C8's tank state [repo: 15 s].
- SET before LOS. P40 behind the Moon, 203.7 s [repo]. AOS confirms the transearth trajectory.
- If TEI is missed or no-go, the desk re-plans TEI at rev 11.
- MCC-5 (104:00, -4.8 ft/s [repo]) is an MCC page flown with P41.

ENTRY
- The ENT page (cut list) computes the lunar-return Entry PAD by propagating to EI and running E8's guidance forward: GMAX, V400K, γ400K, RTGO, VIO, RET to 0.05 g, latitude and longitude, lift up or down, DO and the blackout times. Its SET loads P61's target.
- P61 (PRG 61, Return): N61 target, then N60 (GMAX, VPRED, γEI against the PAD), then N63 (RTGO, VIO, TFE). The EMS scroll on the ENTRY MFD starts from VIO.
- P62: V50N25 "CM/SM SEP" asks for Space twice (the existing 2 s guard). CMEntryProgram takes the CM, and G or Return flies the entry attitude.
- EI-10 min is a hard stop.
- P63, P64 and P67 are E8's equations (Apollo 8 skipped P65 and P66 [repo]). The CMC page shows the phase, and the ENTRY MFD shows the roll commanded against actual.
- Key 9 cycles the backups (constant-g at DO, manual, bank hold, rolling).
- Below 1,000 ft/s the ELS takes over, with Space as its backup below 40,000 ft (existing).

EARTH-ORBIT MISSIONS (no regression)
- DEORBIT's SET goes through the same core load. Apollo 7 and the Apollo 11 no-go can fly the deorbit through P40, or through Z and the EMS counter exactly as today.
- The Apollo 11 no-go scenario starts with XLUNAR SAFE preset.

## 6. LOI targets the pilot chooses

Franz's addition (2026-11-21): the LOI targets are editable, so the pilot chooses the lunar orbit. Apollo 8's numbers are only the defaults.

**The LOI page.** TRANSFER's LOI page has the same layout and buttons as MCC (TGT, V−, V+, SET, CLR). TGT cycles these targets:

| Target | Default (Apollo 8) | Meaning |
|---|---|---|
| LOI-1 apolune | 168.5 n mi | apolune of the orbit LOI-1 leaves |
| LOI-1 perilune | 60.0 n mi | perilune of the orbit LOI-1 leaves |
| LOI-2 | circular at 60 n mi (60.7 × 59.7 achieved) | apolune and perilune after LOI-2; CIRC sets both |
| Plane | the arrival plane (no plane change) | inclination to the lunar equator and ascending node; or a ground-track point (latitude and longitude to pass over on a given rev), for M2.5's landing sites |
| TIG | centred on the burn about pericynthion | an offset in seconds; the planner re-optimises the burn for it |
| NONE | — | no LOI: the free return stays the live alternate |

The planner and its checks:
- N8's LunarOrbitPlanner solves LOI-1 and LOI-2 from the live hyperbolic state for whatever targets are set. It shows the ΔV, BT, TIG and attitude as a PAD, with the orbit with and without the burn.
- Every change re-solves the burn, the AOS with and without the burn, and the predicted perilune after 10 revs in GRGM900C. The mascons lower the perilune, so a low orbit shows its decay.
- A target is refused, with the reason on the page, when:
  - the perilune would fall below the terrain plus a safety margin (LOLA heights under the track);
  - the SPS propellant left would not cover LOI-1, LOI-2 and TEI with the reserve;
  - the plane change costs more than the propellant allows;
  - the orbit would not be bound.
- A TIG that is not behind the Moon is allowed but flagged "IN CONTACT (NOT AS FLOWN)".
- The MCC page's B-plane target sets the arrival geometry that LOI inherits. Choosing a plane at MCC is cheaper than choosing it at LOI, and the page shows both costs.
- SET uplinks the load into the CMC's P30, as for every burn, and is refused during LOS. A PAD keyed by hand into P30 needs no ground.

**Tests (Linux):**
- The defaults reproduce LOI-1's 168.5 × 60.0 ± 1.5 n mi and LOI-2's 60.7 × 59.7 n mi.
- A custom target, such as 100 × 60 n mi with an 80 n mi circular LOI-2, or a 20° inclination, is reached within the same bands through P30 and P40.
- Each refusal reason fires on a constructed case.

**Effort:** +0.5 d in N8 (the planner's targets and checks) and +0.25 d in M8 (the page).

## 7. What is faithful, what is simplified

THE REAL SPLIT, AND HOW IT MAPS

The ground (RTCC, run by FIDO, RETRO, GUIDO and BOOSTER, with CAPCOM voicing PADs) maps to TRANSFER.
- Real: MSFN tracking fed the IBM 360/75s. They computed every manoeuvre, abort PAD and entry target, read them up by voice for the crew to copy, and uplinked them (CMC P27 with P00 and UP TLM ACCEPT; the IU through its command system).
- Kept:
  - the ground plans and the crew executes;
  - the PAD fields (TIG, N81 LVLH ΔV, ΔVT, BT, ΔVC, attitude, ullage, HA/HP, predictions);
  - no contact behind the Moon;
  - MCCs cancelled by the corridor;
  - the FINAL PAD, and later PAD updates.
- Simplified:
  - planning reads the simulated truth through PlanningState, with no MSFN error;
  - it takes seconds, not minutes;
  - there is no voice or read-back: SET is the crew's copy of the PAD, the EMS thumbwheel setting and the uplink in one press;
  - GO/NO-GO comes from physics checks, not a flight director's poll;
  - DEORBIT's planner burns retrograde only, with no radial term (Franz, 2026-11-23). It cannot reproduce a historical burn that was not retrograde: Apollo 7's SPS-8, as its Mission Report states imply it, pointed 57° below retrograde (N81 −210.6, +3.3, +283.8 ft/s), and DEORBIT's best PAD for its entry angle (−2.05° at 259:39:20) reaches entry interface 150 s later and 91 ft/s slower than the flight did. Historical burns are flown from a PAD keyed by hand into P30 (`ApolloCSM.apollo7SPS8Load` is SPS-8's), which lands within the flight's entry pins.

The launch vehicle (LVDC/IU) is T8's SaturnIU.
- Real: prestored out-of-orbit targeting for both opportunities (GE504 Table 4-VI). TB6 started by its own restart-preparation test, the TB6a/b/c alternates, the out-of-orbit IGM to a velocity cutoff, TB7 safing and the slingshot.
- Faithful: all of the above. TB6P is the IU's own test run on the vented orbit. The crew cannot steer TLI. XLUNAR SAFE recycles to the next opportunity.
- Simplified:
  - the seven-parameter update is offered as a crew-visible ground action ([verify] whether AS-503 received any);
  - the desk's prediction is a 3-DOF replay of IterativeGuidance, tested against the full 6-DOF flight;
  - LV ENG and LV RATE come from the IU's state ([verify] the timing); LV GUID is not modelled;
  - the XLUNAR window is [verify].

The CMC (Colossus 237) maps to CMC-lite.
- Faithful:
  - the program numbers and their order;
  - P15 as a monitor with no control of the IU;
  - P30's load, then the computer's own N42 check;
  - P40's V50N18 slew with roll, the gimbal test, V06N40, the blank and Average-G from TIG-30 s;
  - V99 at TIG-5 s, where no PRO means no ignition and a late PRO lights late;
  - computer ignition at TIG and the cutoff;
  - V16N85 nulled on the THC (the translation keys), then N44;
  - P41 and P47/N83;
  - P61's N60/N63 comparison with the EMS setup, P62's CM/SM separation and attitude, and P63/P64/P67.
- Steering: VG steering, VG ← VG - sensed ΔV with the thrust along VG, and the steering frozen in the last seconds ([verify] Colossus's threshold). This is External ΔV's own logic, and cross-product steering gives an almost inertial thrust. With no errors it is the inertial hold N8's FiniteBurn assumes. With dead-band or trim errors it corrects them.
- Simplified:
  - only V37 (PRG), V82, KEY REL, PRO, ENTR, CLR and RSET;
  - the nouns are fixed per step, everything is decimal, registers are labelled, and prompts are in English with the verb and noun dim beside them;
  - one key (Return) is ENTR or PRO by context;
  - two P30 steps instead of four, with N45's marks and middle gimbal angle dropped;
  - the DAP is the existing phase-plane law and SPS TVC gains;
  - V48's weights and trims come from the sim (the SCS's CG trim);
  - the gimbal test is automatic;
  - Return at V50N18 also selects CMC AUTO, which in reality was a panel switch.
- Attitudes are navball HDG/PIT/RLL at TIG in LVLH, not IMU gimbal angles against a REFSMMAT. There is no IMU, P52, P23 or P22 until M3, and no navigation error.

The SCS and EMS map to Z, X, 8, Option+D and Option+R.
- Faithful: THRUST ON with the EMS ΔV counter cutoff, as the crew's backup mode; ΔVC = ΔVT less the tail-off; the ΔV THRUST switches as the crew's hard stop; the dead band; PTC at 0.1-0.3°/s [repo].
- [verify]: whether the real EMS could cut off a G&N burn. Here it counts as a monitor only. Whether Apollo 8 set up PTC through the SCS or the DAP.

The crew maps to the keys.
- Kept as their acts:
  - the TLI decision inside its window;
  - loading the PAD and checking the computer's prediction;
  - the consent to slew;
  - the ullage on U;
  - the consent to ignite (V99);
  - the authority to cut off (X);
  - the residual trim;
  - separation and hand-flown evasive burns;
  - PTC and the dead band;
  - loading LOI and TEI before LOS;
  - the entry setup and backups.
- Automated or hidden: all RTCC work, all IU sequencing, the DAP data, the gimbal test, IMU alignment and the entry steering.

NO 1968 COUNTERPART
- the warp governor and its stops;
- the NEXT timeline's glyphs;
- the English tutor line;
- the HUD burn box;
- the "IF CUTOFF NOW" line (in reality BOOSTER's console).
They only read real event times and never move them.

COPIED AS IT WAS
The order of the crew's acts, and what each one commits:
- the PAD and its check;
- the single TLI decision and its window;
- no steering of TLI;
- no PRO, no ignition;
- the cutoff authority;
- the residual trim;
- burns behind the Moon on onboard data;
- the early AOS that means no LOI.

TO VERIFY IN D8 BEFORE ANYTHING IS PINNED
- the XLUNAR window and LV ENG timing;
- P15's nouns and TIG handling, and the entry nouns (N64, N74, N66, N67);
- any AS-503 IU uplink, and the crew's S-IVB cutoff authority;
- EMS cutoff in G&N burns, and the end-of-burn steering threshold;
- the MCC slots and thresholds, the evasive burns and the CM/SM separation time;
- Apollo 8's TLI PAD form, and Saturn takeover in Colossus 237 (kept out of M2 either way).

LICENSING
Nothing is taken from NASSP (GPL: no RTCC, LVDC or CMC code is read) or from Virtual AGC's software. R-577/GSOP and the AGC listings serve as specification only. TransX is not ported: the desk is an original design.

## 8. The other designs, and what was taken from them

apollo-lite (RTCC desk + CMC-lite; Judge 1's winner)
- It is the base.
- Taken:
  - the three-layer split and the GuidanceComputer seam with DSKYDisplay and DSKYKey;
  - P30/P40/P41/P47/P15/P61/P62 with V99, computer ignition at TIG and cutoff on VG;
  - Z and the EMS as the SCS mode;
  - TRANSFER's fixed 12 buttons on DEORBIT's keys;
  - DIFF against the frozen load, the LOS freeze and "AOS EARLY: NO LOI";
  - the S-IVB margin NO-GO, TB6P from the IU's test, and the re-solve triggers;
  - the never-held Option queue, the HUD repeating the prompt, and N85 rows naming the key;
  - the UP TLM handshake and the M3/AGCAdapter path.
- Changed:
  - UPL and EMS merged into one SET;
  - P30 cut to two Returns;
  - Return made ENTR or PRO by context, closing its own PRO/ENT trap;
  - PRG moved to Shift+V;
  - the flat 3 ft/s NOT REQUIRED replaced by a corridor test;
  - the SEP and ENT pages and the retarget made cut items;
  - P37 left to M3.

orbiter-planner (PLAN, SET, FLY; Judge 2's winner)
- Its usability case shaped the controls: one SET, few presses, Z never ambiguous, one burn page per state.
- Grafted:
  - the four-state TLI page;
  - TLIPredictor, a replay of IterativeGuidance tested against the full sim (1 m/s, 1 s), with "IF CUTOFF NOW" and "AT IGM CUTOFF";
  - NOW/AFTER columns and the rotating-frame plot under MOD;
  - PlanningState copies and results stamped with their input epoch, never applied stale;
  - the 1x cap from TIG-30 s to TIG+5 s;
  - the burn report against the plan;
  - the selectPage right-column fix;
  - a cut order that never breaks the loop.
- Not taken: the modal armed-Z gate (V99 is on Return), the EMS as primary cutoff for G&N burns, ULL AUTO and WRP, a new .maneuver autopilot case (.attitudeHold already does it), PTC on plain R, per-page TRANSFER keys, and the modal Shift+-/= entry line.

sequencer (FLIGHT PLAN mission sequencer)
- Grafted:
  - the live NEXT timeline with its glyphs and alternates, as a TRANSFER page fed by existing sources, with no engine;
  - the corridor-based NOT REQUIRED rule;
  - the FINAL PAD freeze with SOLN MOVED and 1 s hysteresis;
  - MISSED with a re-plan;
  - alternates as live re-plans (OPP 2, the Earth-orbit alternate, free return, TEI rev 11);
  - the rule that decisions and irreversible acts always need a key, and that an unanswered GO defaults to what the hardware would do;
  - Apollo 7 flown first through the new loop;
  - the test that an empty stop list leaves stepping unchanged.
- Not taken: the SimulationAgent and FlightPlan engine, the MAN/AST/AUT levels, one G answering every prompt, a third place to load burns, and ' as the warp key.

pilot-ergonomics (GNC + TRANSFER, one key layer)
- Grafted:
  - the FlightKeyMap data table with generated help and chord tests;
  - G as G&N AUTO across the IU, CMC and CM;
  - FDAI needles and the HUD burn box;
  - the WarpGovernor's hard and soft stops, its 4 s rule and the backslash key;
  - the IU owning the J-2 (allowsPilotThrottle);
  - the RCS lockout from ignition-100 s, and Space twice as the abort separation in TB6 and TLI;
  - the Z guard after a counter cutoff;
  - the shared Y/ORBIT target and SET refused during LOS;
  - Option chords only for configuration switches, with other Option+key presses passing through;
  - ManeuverPlan moved into S8;
  - the optional LVLH roll hold for 1-7.
- Not taken: "IGN? PRESS Z" with an immediate light (the early-ignition trap), ΔVC without the tail-off, Shift+digits as program buttons, Option+X meaning X off the stack, and P15 outside the computer seam.

## 9. Implementation (M2 tracks, effort)

All paths are under /Users/grossetti/sw/ullage. "Linux" means OrbitCore, OrbitScene or OrbitInstruments, testable in the cloud. Each item stays inside the track that already owns its files. This design should be folded into the docs/m2/plan.md pass, along with a note striking docs/m15/design-orbiter-mfds.md:211 ("TransX's planning structure for TLI").

S8, SEAMS (Linux, +1.0 d; lands first, with no behaviour change)
- Sources/OrbitCore/Guidance/GuidanceComputer.swift (new):
  - the GuidanceComputer protocol: display, press(DSKYKey), uplink(load) -> UplinkResult, update(vessel, sim, now), timeToNextEvent, warpEvents;
  - the value types DSKYDisplay (prog, verb, noun, flash, three labelled registers, lamps, English prompt, reason, keying buffer) and DSKYKey.
- Sources/OrbitCore/Guidance/ManeuverPlan.swift (new, moved from N8 so C8 and M8 can start in parallel): name, engine (SPS or RCS), centred TIG, ΔV in LVLH and ICRF, BT, attitude quaternion with heads up or down, ΔVC, ullage, predictions with and without the burn, input-state epoch, source.
- Sources/OrbitCore/Simulation/WarpEvent.swift (new), plus Simulation.advance (Simulation.swift:104-123):
  - WarpEvent {at, .stop(maxWarp) or .cap(maxWarp, until), hard, reason};
  - the governor: the approach rule, `remaining` clamped so no step crosses a stop, the warp only ever lowered, a log line once.
- FlightProgram.swift: warpEvents(after:) defaulting to [], and allowsPilotThrottle(of:) defaulting to true.
- PhysicalKey.swift: .returnKey (0x24, with keypad Enter 0x4C) and .delete (0x33).
- MFDMode.swift: .transfer (X, TRN) and .cmc (C, CMC) stubs.
- MFDController.selectPage: modes 7-12 beside the right buttons.
- Tests:
  - WarpGovernorTests: a stop at 1e5x is not overrun and the warp is 1x there; an empty event list leaves the §17 printouts and the Apollo 7 pins unchanged;
  - OrbitInstrumentsTests: the seven-mode select page and the new key codes.

C8, CMC-LITE AND SCS (Linux, +3.0 d, range 2.5-4; owns ApolloSCS.swift, Autopilot.swift and Guidance/CMC/*)
- Guidance/CMC/CMCLite.swift (new):
  - P00, P15 (a view over TLIControlling), P30 (two steps), P40, P41, P47, P61/P62 fronts, and P63-P67 as views;
  - keying (Return is ENTR with digits, PRO without; ENTR with nothing keyed is OPR ERR);
  - lamps and PROG reasons;
  - the uplink handshake (P00, ACCEPT and a contact flag);
  - NXT.
- Guidance/CMC/ExternalDeltaVSteering.swift (new):
  - Average-G from TIG-30 s, using the sensed ΔV as countDeltaV computes it;
  - the attitude along VG with the load's roll, written to attitudeCommand under .attitudeHold and rate-limited at 0.5°/s, with no new autopilot case;
  - the steering frozen near the end;
  - the logged gimbal test;
  - V99 at TIG-5 s, and ignition at TIG through timeToNextEvent;
  - the cutoff when VG along X reaches the tail-off ΔV from EngineTransients.shutdown (spsTailoffDelay 0.54 s), predicted to the step;
  - N85 in body axes with the key per axis, P41 nulling by hand, the P47 accumulator and the burn report.
- ApolloSCS:
  - `public let computer = CMCLite()`, run first in update();
  - a gnAuto flag: G sets it, 8 or RCS input clears it;
  - the warp events merged (cap 100x from TIG-60 min, cap 10x from TIG-10 min, a stop at TIG-2 min, cap 1x from TIG-30 s to TIG+5 s, cap 10x in the burn);
  - the EMS counting every burn but cutting off only Z-lit ones;
  - the wideDeadband switch, PTC (already in C8), and the Z guard after a counter cutoff.
- Vessel.guidanceComputer: reaches the CM's standbyProgram on the stack, where P00, P15, P30 and V82 need no stepping.
- Optional: the LVLH roll hold for 1-7 in Autopilot.swift.
- Tests:
  - CMCLiteTests: PRG 40 with no load lights PROG; an uplink outside P00 is refused; ENTR with nothing keyed is OPR ERR; Return with digits enters them; no Return at V99 means no ignition; a late Return lights late by the delay; Z in P40 makes an SCS burn that the EMS cuts off.
  - ExternalDeltaVTests:
    - LOI-1 from MR Table 5-II's state through P40: 246.9 ± 2 s and 168.5 x 60.0 ± 1.5 n mi (L5's bands);
    - Apollo 7's SPS deorbit through DEORBIT SET and P40, within Apollo7DeorbitTests' bands;
    - MCC-5 through P41 with scripted taps, VG below 0.2 ft/s;
    - residuals no larger than the tail-off uncertainty.
- Decision 49: the V99, ignition and VG-cutoff part is about 1.0 d of the 3.0 and exists only if 49 is amended. Without the amendment P40 cues "Z AT TIG" and the EMS cuts off.

T8, IU CREW INTERFACE (Linux, +1.5 d; owns SaturnIU.swift, IterativeGuidance.swift and OutOfOrbitTargeting.swift; rides T8's TLI PR)
- Guidance/TLIControlling.swift (new):
  - xlunar and setXlunar;
  - the opportunity;
  - uplink(SevenParameterUpdate), accepted only before TB6;
  - tliStatus: phase, TB6 for each opportunity, the SIVBRestart timeline lines, the inhibit-window epochs, IGM T-go, VGO and terminal targets, and the lamps.
- SaturnIU:
  - TB6c inside the window, then a recycle to the next opportunity;
  - warp events (a stop at TB6-60 s, cap 10x in TB6, a stop at ignition-100 s, cap 10x until cutoff+30 s);
  - allowsPilotThrottle false after T5, with the IU re-asserting its throttle;
  - the RCS takeover refused from ignition-100 s to cutoff;
  - Space guarded during TB6 and TLI;
  - X refused during TLI.
- Guidance/TLIPredictor.swift (new): a 3-DOF replay of the out-of-orbit IGM. It coasts with the vent schedule to the restart-preparation test (TB6P), runs the restart timeline, then the burn in 1 s steps with the live tanks and EMR schedule. It returns the cutoff state and T-go in a few ms.
- Tests (TLIControlTests):
  - SAFE in the window gives TB6c, no ignition, and OPP 2's TB6 about one period later;
  - SAFE after the J-2 start is refused;
  - Z in parking orbit does not relight the J-2;
  - an uplinked update moves the cutoff as the targeting predicts;
  - TLIPredictor from the L2 state matches the full sim within 1 m/s and 1 s;
  - TB6P lands within 1 s of 9,659.54 s (L1's band).

N8, PLANNERS (Linux, +1.75 d; owns Navigation/*; rides N8's API PR around day 7)
- ManeuverPlan's PAD fields filled: ΔVC, the ullage cue from C8's tank state, navball attitude at TIG, the prediction without the burn, the engine choice at 5 ft/s.
- Navigation/PlanningState.swift: value copies made on the main actor, so planners never touch Vessel or Simulation.
- Navigation/GroundTracking.swift: the LOS freeze until AOS + 2 min through LunarVisibility, and the contact flag for uplinks.
- Navigation/Corridor.swift: the NOT REQUIRED rule (pericynthion altitude and time and EI γ inside tolerances, plus a ΔV threshold).
- Navigation/TLIPrediction.swift: TLIPredictor, then CislunarPropagator, giving the pericynthion, the free-return EI γ and the S-IVB margin.
- Navigation/TLITargeter.swift (cut list): a corrector on C3, θN and α_D to HPC and EI γ, giving a SevenParameterUpdate.
- An adapter from DeorbitPlanner.Plan to ManeuverPlan.
- Tests: the LOI-1 PAD gives 168.5 x 60.0 ± 1.5 n mi; the corridor cancels an in-corridor MCC and keeps an out-of-corridor one of the same ΔV; the frozen state is used from LOS to AOS; TLITargeter converges from L1.

E8, ENTRY (Linux, +0.5 d)
- CMEntryProgram: load(target:lift:) for P61; its phase and nouns; the N60/N63 predictions; the P62 prompt driving the Space guard; the entry attitude for G; the EI-10 min stop.
- Tests: P61's target reaches the guidance; P62 followed by two Space presses separates.

M8, PAGES (+2.75 d over the planned 4.5-7; the pages are Linux, the queue and refresh are Mac)
- Modes/CMCMFD.swift: renders DSKYDisplay.
- Modes/TransferMFD.swift plus per-page files:
  - NEXT, TLI in four states, MCC with the SEP type, LOI, TEI, and ENT (cut list);
  - the GO checks, the LOS freeze, DIFF, FINAL and SOLN MOVED, MISSED and the alternates;
  - MOD between text and the plot.
- PADFormat.swift.
- PlannerQueue.swift: Dispatch, keyed and coalescing, results stamped with their epoch.
- ActiveManeuver.swift built from the core load, with MFDVesselData.maneuver removed and DeorbitMFD's SET routed to the core.
- A shared TargetSelection, and BurnCue.swift.
- Mac: MFDModel runs PlannerQueue on a serial .utility queue and posts the results to main; the CMC page refreshes at 10 Hz during P40 and P41.
- Tests: every page as a display list at each step, the dim buttons by state, PlannerQueue's staleness, and the per-mode keys.

I8/R, INTEGRATION (+1.5 d)
- Linux:
  - OrbitInstruments/FlightKeyMap.swift and its tests;
  - KeyboardState's Option queue;
  - scenarios in OrbitScene/Scenarios.swift: the Apollo 8 legs start with the matching CMC state; "before LOI-1" starts with P30 loaded and the EMS set; Apollo 11's no-go presets XLUNAR SAFE.
- Mac:
  - AppModel dispatching through the map (Return, G, the backslash key, the Option queue, the Z, X and Space checks through the programs);
  - InstrumentCluster: the FDAI needles, the burn box, the G&N and PTC rows, the XLUNAR and LV ENG lamps, the warp-stop line;
  - the program line repeating the prompt, and HelpView generated from the map;
  - harness flights: TLI with SAFE and a recycle; MCC-1 through P40; LOI-1 behind the Moon to AOS.

PR ORDER
1. S8 seams.
2. C8a, the CMC core.
3. M8a, the CMC page and DEORBIT routing, with I8a, the keys. This is the first proof: Apollo 7's deorbit flown through P30/P40 on M1.5 hardware.
4. T8, the crew interface and TLIPredictor, with T8's TLI PR.
5. N8, the PAD fields, with its API PR.
6. M8b, the TRANSFER desk.
7. C8b (P15, P61/P62, PTC) and E8's hooks.
8. I8b: scenarios, help and harness flights.

Combined branches are tested before each merge, as in M1.5. There is one owner per shared file: Simulation.swift S8, ApolloSCS and Autopilot C8, SaturnIU T8, AppModel I8.

EFFORT
- About +12.0 d (range 10-14.5) on the roughly 45 d M2 flight estimate: S8 1.0, C8 3.0, T8 1.5, N8 1.75, E8 0.5, M8 2.75, I8 1.5.
- C8, T8 and N8 run in parallel in the cloud. The critical path grows by about 2 d, through M8's TRANSFER.
- Cut order, without breaking the loop (about 2.6 d, to a floor of about 9.4 d):
  1. the seven-parameter retarget (0.85);
  2. the ENT PAD page (0.4);
  3. the NEXT page, keeping the HUD's NEXT (0.4);
  4. the SEP evasive type (0.25);
  5. the FDAI needles (0.25);
  6. the 1-7 roll hold (0.25);
  7. the UP TLM switch (0.1);
  8. the DSKY blank and gimbal-test flavour (0.1).
- Keeping decision 49 unamended saves another 1.0 d.

DECISION 48: kept. SET is now defined: uplink, EMS and marker, or the seven-parameter update to the IU on the TLI page.
DECISION 49: amended as owner decision 1. Option 6 is taken as VG steering (about 1 d). Option 7 is kept. Decision 45's precedent covers CMC-lite as the no-AGC mode and test oracle.

M3
- An AGCAdapter implements GuidanceComputer:
  - PRG becomes V37E nnE;
  - the display words come back as DSKYDisplay;
  - the CDU and PIPA feeds come from the vessel;
  - SET emits real P27 uplinks.
- The CMC MFD and M3's DSKY panel render the same DSKYDisplay, and the Option chords become panel switches.
- M2.5's LGC-lite reuses the same seam and desk.

Added by §6: +0.75 d (N8 +0.5, M8 +0.25).

## 10. Decisions

- 1. Decision 49 and M1.5's decision 9. Under G&N (P40), should the crew's Return at V99 let the computer light the SPS at TIG, steer on VG and cut off, with Z and the EMS counter cutoff kept as the SCS mode for every burn? Recommended: yes, amend. It is the computer you asked for, and it is how P40 was flown. Note that the warp governor alone already removes the timing error under warp. If you keep 49, P40 still slews, counts and trims, shows "THRUST ON AT TIG: Z" with a countdown, and the EMS counter cuts off. That saves about 1 d. **Decided 2026-11-21: as recommended.**
- 2. Is CMC-lite accepted as the no-AGC mode, and as M3's test oracle if M3 emulates the AGC, on decision 45's precedent? Recommended: yes. The GuidanceComputer seam lets an AGC adapter take its place, and M2.5's LGC-lite reuses the same seam. **Decided 2026-11-21: as recommended.**
- 3. An Option layer for panel switches: Option+X XLUNAR, Option+D dead band, Option+R PTC, Option+U UP TLM. It has its own queue, which is never held, and an unbound Option+key passes through as the plain key. Recommended: yes, after a Mac check that each chord reaches GameView.keyDown on your Italian keyboard. Fallbacks: ; for XLUNAR and ' for PTC. **Decided 2026-11-21: as recommended.**
- 4. Return (and keypad Enter) as the focus vessel's computer key from anywhere: ENTR when digits are keyed, PRO otherwise. Recommended: yes. One key removes the PRO/ENT trap, and the HUD repeats every flashing prompt. **Decided 2026-11-21: as recommended.**
- 5. Units: Apollo units (ft/s, n mi, GET) on TRANSFER and the CMC with no toggle, and SI everywhere else. Recommended: yes, because the pages are PADs. **Decided 2026-11-21: as recommended.**
- 6. Warp stops. Hard stops always on: TB6-60 s, ignition-100 s, TIG-2 min, a 1x cap from TIG-30 s to TIG+5 s, EI-10 min. Soft stops (LOS, AOS, SOI, pericynthion) only through the backslash key. Recommended: yes, with a setting that turns off every hard stop except the 1x cap around TIG. **Decided 2026-11-21: as recommended.**
- 7. The GE504 seven-parameter IU retarget (SET on the TLI page) in M2, about +0.85 d. Recommended: in, as the ground's answer to an off-nominal ascent, and first in the cut order. Whether AS-503 received any update is [verify]. **Decided 2026-11-21: as recommended.**
- 8. X during TLI. Recommended: refused, with Space twice as the abort separation, until D8 shows whether the crew could cut off the S-IVB. If they could, X becomes that cutoff. **Decided 2026-11-21: as recommended.**
- 9. The EMS counter during a CMC burn. Recommended: monitor only, with no cutoff, so there is one cutoff authority per burn: the computer for burns it lit, the EMS for Z. Verify in the CSM-103 AOH during D8. **Decided 2026-11-21: as recommended.**
- 10. ΔVC (ΔVT less the predicted SPS tail-off) as the EMS setting everywhere, DEORBIT included. Recommended: yes. It removes today's tail-off overburn. Apollo 7's pins are re-checked in C8 and updated with a note if they move toward the plan. **Decided 2026-11-21: as recommended.**
- 11. Pointing modes 1-7 holding roll in LVLH instead of only damping it. Recommended: yes but late and optional. Leave roll free if it moves Apollo 7's CM RCS pin beyond the -O margin. G&N AUTO already gives burns their roll. **Decided 2026-11-21: as recommended.**
- 12. Navigation in M2. Recommended: exact. The planners and the CMC read the true state through PlanningState copies. MSFN tracking error, IMU drift, P52, P23 and P37 wait for M3. **Decided 2026-11-21: as recommended.**
- 13. TransX. Recommended: not ported, with docs/m15/design-orbiter-mfds.md:211 amended to match the Apollo 8 report's "do not port". The desk is an original design. Nothing comes from NASSP or Virtual AGC's software, and the AGC listings are read as specification only. **Decided 2026-11-21: as recommended.**
- 14. LOI targets editable by the pilot (§6). **Decided 2026-11-21 (Franz's addition).**
