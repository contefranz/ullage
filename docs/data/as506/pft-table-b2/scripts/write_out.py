import sys, json
rowsj, checksj, out_table, out_json = sys.argv[1:5]
rows = json.load(open(rowsj))
checks = {c['t']: c for c in json.load(open(checksj))['report']}
dis = json.load(open(checksj))['disagreements']
LABEL = {'0.300': 'FIRST MOTION', '0.600': 'START OF TIME BASE 1', '135.200': 'S-IC CENTER ENGINE CUTOFF (ENGINE SOLENOID)'}
VERDICT = {
 '0.300': 'PASS (event row). Positions consistent with both neighbours (interval dx residuals <=0.70 m, inside the 1.03 m rounding bound); non-uniform central differences inside their rounding bounds. Interval dv residual -0.19 m/s (X, 0.0->0.300) exceeds the 0.11 m/s trapezoid bound only because DDXS jumps at hold-down release (-0.02 -> 0.65 -> 1.71); not a reading error. Digits re-read at native 300 dpi.',
 '0.600': 'PASS (event row, release transient). Non-uniform central differences inside rounding bounds; intervals dx pass; dv interval residuals +0.15/-0.16 m/s (X) straddle this row with opposite sign, consistent with the non-linear DDXS ramp 0.65->1.71->2.08 after release (trapezoid rule invalid). DXS printed "-0.0" re-read at 10x and confirmed.',
 '1.0': 'PASS on the post-release side: forward stencil 1,2,3 and interval 1.0->2.0 pass; the 1-s central DDXS check fails (+0.53) only because the stencil reaches back to 0.0 s, before release (DDXS -0.02 there). Digits re-read at native 300 dpi.',
 '135.0': 'PASS (event-aware). 1-s central stencil 134/136 straddles CECO (thrust decay between 135.2 and 136), so its DDXS/DDZS residuals (+0.80/+1.34) are physical, not misreads; backward stencil 133-134-135 and intervals 134->135, 135->135.200 all pass. Digits re-read at native 300 dpi.',
 '135.200': 'PASS (event-aware). Backward endpoint stencil 134-135-135.200 and interval 135.0->135.200 pass (dx <=0.62 m, dv <=0.06 m/s). Interval 135.200->136.0 and the adjacent-row stencil contain the CECO thrust decay (DDZS 31.82 -> 26.21), so they cannot be used. Digits re-read at native 300 dpi.',
 '161.0': 'PASS on the pre-OECO side: backward stencil 159-160-161 and interval 160->161 pass. The 1-s central stencil reaches 162.0 (after OECO at 161.630) and fails for physical reasons. Note a printed-table seam: interval 161.0->161.630 has dx residuals +2.9 m (X) and +8.8 m (Z), about 3.4 ms of motion, while velocities and accelerations agree; 161.0, 161.630 and 162.0 digits all re-read and confirmed, so this is in the source, not a misread.',
}
def auto(c):
    vg, ag = c['vgrade'], c['agrade']
    ig = [i['dx_grade'] for i in c['intervals']] + [i['dv_grade'] for i in c['intervals']]
    worst = 'pass'
    for g in [vg, ag] + ig:
        if g == 'fail': worst = 'fail'
        elif g == 'marginal' and worst == 'pass': worst = 'marginal'
    return worst.upper()
def fmt(c):
    s = (f"{c['stencil']}: v-res (printed minus FD, {'no truncation correction: stencil crosses ' + ','.join(c['crosses']) if c['crosses'] else 'truncation-corrected'}) X,Y,Z = {c['vres']} m/s (rounding bound {c['vtol']}) {c['vgrade'].upper()}; "
         f"a-res = {c['ares']} m/s2 (bound {c['atol']}) {c['agrade'].upper()}")
    for a in c['alternatives']:
        s += f"; alt {a['stencil']}: v-res {a['vres']} (bound {a['vtol']}) {a['vgrade'].upper()}, a-res {a['ares']} (bound {a['atol']}) {a['agrade'].upper()}"
    for i in c['intervals']:
        s += (f"; interval {i['interval']}: dx-res {i['dx_res']} m (bound {i['dx_tol']}) {i['dx_grade'].upper()}, dv-res {i['dv_res']} m/s (bound {i['dv_tol']}) {i['dv_grade'].upper()}"
              + (f" [contains {','.join(i['crosses'])} transient]" if i['crosses'] else ''))
    return s
EXTRA = {
 '115.0': 'MARGINAL: DDYS a-res +0.063 vs 0.060 bound (0.003 over the bound); DYS 114/115/116 and DDYS re-read at native 300 dpi and confirmed. ',
 '160.0': 'MARGINAL: X v-res -0.61 vs 0.57 bound; XS 159/161 and DXS 160 re-read at native 300 dpi and confirmed. Late-S-IC X velocities sit ~0.26 m/s below the position differences on average (136-161 s), consistent with the filtered/differentiated processing described in the report, not a misread. ',
}
out_rows = []
for r in rows:
    c = checks[r['ts']]
    if r['ts'] in VERDICT:
        txt = VERDICT[r['ts']] + ' DETAILS: ' + fmt(c)
    else:
        v = auto(c)
        txt = (EXTRA.get(r['ts'], '') if v != 'PASS' else '') + (v if r['ts'] not in EXTRA else '') + (' (digits re-read at native 300 dpi). ' if r['ts'] not in EXTRA else '') + 'DETAILS: ' + fmt(c)
    raw = r['raw']
    out_rows.append(dict(t=float(r['ts']), xs_km=float(raw[0]), ys_km=float(raw[1]), zs_km=float(raw[2]),
                         dxs=float(raw[3]), dys=float(raw[4]), dzs=float(raw[5]),
                         ddxs=float(raw[6]), ddys=float(raw[7]), ddzs=float(raw[8]),
                         pdf_page=r['page'], fd_check=txt, _ts=r['ts'], _raw=raw))
# table
hdr = """# PFT D5-15560-6 (AS-506 postflight trajectory) Table B-II "Launch vehicle navigation positions, velocities,
# and accelerations - ascent phase" (PACSS 13 according to the report text), S-IC phase. v2, re-read 2026-10-18.
# Source: PDF pages 104-108 (document pages B-14..B-18), native 300 dpi CCITT page images extracted with
# pdfimages, rotated upright, deskewed (page 108 is ~1.0 deg skewed), cropped and read; every value below
# was read twice (400 dpi render, then native 300 dpi zoom). pdftotext was used only to locate pages.
# Units exactly as printed: TIME SEC, XS YS ZS KM, DXS DYS DZS M/S, DDXS DDYS DDZS M/S SQ.
# Verified: (1) the 18 rows of the previous file (pft_b2_sic.txt) were re-read independently: 161 of 162
#   cells agree; t=30.0 DYS is 126.3 as printed (previous file had 126.4); corrected here.
# (2) added rows: every 5 s 10-160 s, 135.200 (S-IC CENTER ENGINE CUTOFF (ENGINE SOLENOID), printed event row),
#   0.300 (FIRST MOTION = first printed row after range zero), 0.600 (START OF TIME BASE 1) and 1.0 (first
#   regular 1-s row) so either liftoff convention is covered; 161.0 kept from the previous file.
# (3) every row checked: velocity vs 3-point central differences of neighbouring printed positions and
#   acceleration vs central differences of neighbouring printed velocities, 1-s neighbours where printed
#   (rows are printed every 1 s from -16 to 162 s; 83.000 is printed as the MAXIMUM DYNAMIC PRESSURE row), residuals compared with the bound set by print rounding
#   (0.57 m/s, 0.06 m/s2 for 1-s stencils), plus interval checks (Hermite position step, trapezoid velocity step).
#   All target rows with 1-s stencils pass except 160.0 (X velocity 0.04 m/s over the bound) and 115.0 (DDYS 0.003 over), both
#   re-read and confirmed. Event-adjacent rows (0.3, 0.6, 1.0, 135.0, 135.2, 161.0) pass with one-sided stencils
#   that do not cross release/CECO/OECO. Full 1-s neighbour transcription: data2/pft-b2/pft_b2_sic_all_rows.txt.
# Event labels: 0.300 FIRST MOTION; 0.600 START OF TIME BASE 1; 135.200 S-IC CENTER ENGINE CUTOFF (ENGINE SOLENOID).
# t XS YS ZS(km) DXS DYS DZS(m/s) DDXS DDYS DDZS(m/s2)
"""
with open(out_table, 'w') as f:
    f.write(hdr)
    for r in out_rows:
        f.write(' '.join([r['_ts']] + r['_raw']) + '\n')
for r in out_rows:
    del r['_ts']; del r['_raw']
json.dump(out_rows, open(out_json + '.rows_final.json', 'w'), indent=1)
print(len(out_rows), 'rows')
