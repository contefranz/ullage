# Assemble final samples: DP-trace values, with documented manual overrides at points checked by hand.
import sys, json
import numpy as np
wdir, outp = sys.argv[1], sys.argv[2]
dp = json.load(open(wdir + '/samples_dp.json'))
OVR = {  # (panel, t): (value, note)
    ('p1', 90): (-41.6, 'DP run merged with arrow head; interpolated from +-0.4 s columns'),
    ('p2', 110): (-0.125, 'steep crossing on 110 s gridline; read by hand at 8x'),
    ('p2', 120): (0.59, 'steep stroke runs along the 120 s gridline; centreline crossing read by hand at 8x'),
    ('p2', 130): (-0.222, 'steep crossing on 130 s gridline; read by hand at 8x'),
    ('p2', 140): (-0.05, 'measured/simulated strokes merge at 140 s gridline; read by hand'),
    ('p3', 55): (-0.74, 'two strokes form a small loop at the local minimum; loop centre'),
    ('p3', 60): (-0.694, 'DP followed the simulated stroke; measured stroke read by hand'),
    ('p3', 70): (-0.80, 'measured stroke is the near-vertical rising branch of the -0.97 spike, along the 70 s gridline; +-0.1'),
    ('p3', 80): (-0.62, 'measured stroke rises along the 80 s gridline from -0.67 to -0.57; midpoint, +-0.05'),
    ('p3', 110): (-0.534, 'steep crossing on 110 s gridline; read by hand at 8x'),
    ('p3', 140): (-0.245, 'steep crossing on 140 s gridline; read by hand at 8x'),
    ('p4', 20): (-0.061, 'steep stroke along 20 s gridline; centreline crossing from row runs'),
    ('p4', 90): (0.19, 'steep stroke along 90 s gridline; read by hand at 8x'),
    ('p4', 120): (0.015, 'steep stroke along 120 s gridline; read by hand at 8x'),
}
LOWCONF = {('p1', 15): 'curve merges with the top border', ('p3', 15): 'steep', ('p3', 65): 'steep flank of 63 s spike',
           ('p3', 75): 'steep flank', ('p3', 85): 'bottom of narrow V', ('p2', 65): 'steep flank near 65.3 s peak',
           ('p2', 115): 'steep', ('p2', 125): 'steep', ('p2', 135): 'steep', ('p4', 115): 'steep', ('p4', 15): 'steep'}
key = {'p1': 'attitude_deg', 'p2': 'error_deg', 'p3': 'rate_deg_s', 'p4': 'engine_deg'}
rnd = {'p1': 1, 'p2': 3, 'p3': 3, 'p4': 3}
samples = []
notes = []
for k in range(30):
    t = 15 + 5 * k
    s = {'t': float(t), 'attitude_deg': None, 'command_deg': None, 'error_deg': None, 'rate_deg_s': None, 'engine_deg': None}
    for p in ['p1', 'p2', 'p3', 'p4']:
        r = dp[p][k]; assert r['t'] == t
        v = r['v']
        if (p, t) in OVR:
            v, n = OVR[(p, t)]
            notes.append('%s t=%d: %s (DP trace gave %.3f)' % (p, t, n, r['v']))
        s[key[p]] = round(float(v), rnd[p])
    samples.append(s)
json.dump({'samples': samples, 'override_notes': notes, 'lowconf': {'%s@%d' % k: v for k, v in LOWCONF.items()}}, open(outp, 'w'), indent=1)
for s in samples:
    print('%5.0f  att %7.1f  err %7.3f  rate %7.3f  eng %7.3f' % (s['t'], s['attitude_deg'], s['error_deg'], s['rate_deg_s'], s['engine_deg']))
