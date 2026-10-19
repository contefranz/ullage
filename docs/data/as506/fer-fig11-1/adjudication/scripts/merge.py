"""Merge digitisations A and B of FER Fig. 11-1 with the adjudicated values.

usage: python3 -I merge.py A.json B.json out.json
"""
import sys, json

A = json.load(open(sys.argv[1]))
B = json.load(open(sys.argv[2]))
FIELDS = ['attitude_deg', 'command_deg', 'error_deg', 'rate_deg_s', 'engine_deg']
DIGITS = {'attitude_deg': 2, 'command_deg': 2, 'error_deg': 3, 'rate_deg_s': 3, 'engine_deg': 3}

ADJ = {
    (15, 'attitude_deg'): dict(
        A=-0.4, B=-1.3, final=-0.7, unc=0.2,
        reading='400 dpi render: stroke centre 4.3 px below the top-border centreline at 0.1595 deg/px = -0.69 '
                '(threshold 80/128/176: -0.63/-0.69/-0.77); native 300 ppi scan: 3.4 px at 0.2124 deg/px = -0.71',
        verdict='A closer (0.3 deg high); B 0.6 deg low'),
    (20, 'attitude_deg'): dict(
        A=-1.1, B=-1.8, final=-1.4, unc=0.2,
        reading='400 dpi render: 8.8 px at 0.1590 deg/px = -1.40 (thresholds: -1.33/-1.40/-1.48; including the '
                'columns next to the 20 s gridline -1.44); native 300 ppi scan: -1.40 (-1.45 with the near-gridline columns)',
        verdict='neither; A 0.3 deg high, B 0.4 deg low'),
}

samples = []
for a, b in zip(A['samples'], B['samples']):
    assert float(a['t']) == float(b['t'])
    t = float(a['t'])
    s = {'t': t}
    flags = []
    for f in FIELDS:
        va, vb = a.get(f), b.get(f)
        key = (int(t), f) if t.is_integer() else None
        if key in ADJ:
            s[f] = ADJ[key]['final']
            flags.append('%s adjudicated (A %s, B %s)' % (f, va, vb))
        elif va is None and vb is None:
            s[f] = None
        elif va is None or vb is None:
            s[f] = va if vb is None else vb
            flags.append('%s from one digitiser only' % f)
        else:
            s[f] = round((va + vb) / 2.0, DIGITS[f])
    if b.get('flags'):
        flags.append('B: ' + b['flags'])
    if flags:
        s['flags'] = '; '.join(flags)
    samples.append(s)

out = {
    'source': 'Saturn V Launch Vehicle Flight Evaluation Report AS-506 (MPR-SAT-FE-69-9), Figure 11-1 '
              '"Pitch Plane Dynamics During S-IC Burn", PDF page %s (printed page 11-3)' % A['pdf_page'],
    'pdf_page': A['pdf_page'],
    'units': 't: s (range time); attitude_deg, command_deg, error_deg, engine_deg: deg; rate_deg_s: deg/s '
             '(as printed; nothing converted)',
    'curve': 'flight = solid MEASURED stroke in every panel; command_deg null (actual and commanded attitude '
             'are one stroke in panel 1)',
    'panel1_axis': 'Printed labels 0 (top border), -40 (middle line), -60 (bottom border) are inconsistent; '
                   'read as 0..-80 deg at 20 deg/div, as both digitisers did (their reasons in fig111-A.json / '
                   'fig111-B.json axis_reading_for_panel1). All attitude values are conditional on this reading.',
    'merge_rule': 'mean of A and B for every field except the two disagreements, which were re-digitised; '
                  'attitude means rounded to 0.01 deg, other means to 0.001',
    'adjudication': [dict(t=k[0], field=k[1], **v) for k, v in ADJ.items()],
    'adjudication_method': (
        'PDF page 159 rendered at 400 dpi with pdftoppm (gray), rotated 90 deg. Gridlines fitted locally over '
        '0-45 s: vertical 10/20/30 s lines (x = a + b*y, rms 0.3-0.45 px), the top border from its top edge '
        '(the stroke lies below it; rms 0.56 px) plus its bare thickness (8 px, measured at 22-38 s where the '
        'stroke has separated), the -20 deg line from its centre (rms 0.38 px); 125.4 px per 20 deg. The global '
        'top-border fits of A and B differ from this local one by <1 px, so calibration is not the cause. '
        'At 15-21 s the stroke overlaps the border, so its centre was taken as its bottom edge minus half the '
        'stroke width (8.0 px at 400 dpi, 5.95 px native, measured where it first separates at 22-26 s), '
        'averaged by a local linear fit over +-15 px. Repeated on the native 300 ppi CCITT scan with its own '
        'fits. Check of the method: the same reading before pitch-over (5-12 s) gives -0.25..-0.45 deg, '
        'matching the panel-2 error there (-0.2..-0.3 deg). Cross-check: integrating B\'s panel-3 pitch-rate '
        'trace gives 15->25 s -1.87 and 20->30 s -2.52 deg; anchored on the clean 25 and 30 s readings '
        '(A/B/adjudicator -2.3..-2.6, -4.0..-4.1) that implies about -0.6 at 15 s and -1.5 at 20 s.'),
    'why_A_B_differed': (
        'B: its gridline-erase step removed the border rows, and with them the upper part of the stroke '
        'merged into the border; its DP then sampled the 3-4 px sliver left below (samples_dp.json: '
        'thick 3 at 15 s, 4 at 20 s, against a 6 px stroke at 300 dpi), so the sample sits 1.5-3 px '
        '(0.35-0.65 deg) below the stroke centre. At 20 s the 1-bit scan also has eroded columns either side '
        'of the gridline where only the lower 4-5 px of the stroke survive, which a sliver centre also reads low. '
        'A: its DP trace follows the border run itself from 13.6 to 21.2 s (flag rB, y = border centre, '
        'about -0.15 deg), and its panel-1 sampler uses only separated curve runs, so it had no traced data at '
        '15 and 20 s; the values are hand entries in its final.py without a recorded method and sit about '
        '0.3 deg too shallow (towards the border). Neither mis-fitted a gridline and neither followed the '
        'simulated curve (panel 1 has none).'),
    'accuracy_deg': 'Adjudicated points +-0.2 deg (stroke-width assumption +-1 px, threshold +-0.07 deg, '
                    'border-centre fit +-0.5 px). Other samples: see accuracy_deg in fig111-A.json and fig111-B.json.',
    'extremes': 'Panel-2 extremes are not merged here; see error_extremes in fig111-A.json and panel2_extremes in fig111-B.json.',
    'work_dir': '/tmp/claude-0/-home-user-ullage/1c835ba6-4d0a-5d42-96bb-a9ff7c081ab9/scratchpad/data2/fig111-adj',
    'samples': samples,
}
json.dump(out, open(sys.argv[3], 'w'), indent=1)
print(len(samples), 'samples written')
for s in samples[:4]:
    print(s)
