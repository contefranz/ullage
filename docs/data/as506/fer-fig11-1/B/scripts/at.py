import sys, json
import numpy as np
wdir, name = sys.argv[1], sys.argv[2]
rows = json.load(open('%s/%s_dp.json' % (wdir, name)))
t = np.array([r[5] for r in rows]); v = np.array([r[6] for r in rows]); x = np.array([r[0] for r in rows])
for q in [float(a) for a in sys.argv[3].split(',')]:
    i = int(np.argmin(np.abs(t - q)))
    print('%s t=%.2f -> v=%.3f  (nearest col x=%d t=%.2f)' % (name, q, float(np.interp(q, t, v)), x[i], t[i]))
