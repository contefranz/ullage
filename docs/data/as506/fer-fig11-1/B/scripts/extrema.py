import sys, json
import numpy as np
wdir, name = sys.argv[1], sys.argv[2]
prom = float(sys.argv[3])
rows = json.load(open('%s/%s_dp.json' % (wdir, name)))
x = np.array([r[0] for r in rows]); t = np.array([r[5] for r in rows]); v = np.array([r[6] for r in rows])
th = np.array([r[3] - r[2] + 1 for r in rows])
# resample on uniform x
xs = np.arange(x.min(), x.max() + 1)
vv = np.interp(xs, x, v); tt = np.interp(xs, x, t); thh = np.interp(xs, x, th)
k = 3
vs = np.convolve(np.pad(vv, k, mode='edge'), np.ones(2 * k + 1) / (2 * k + 1), mode='valid')
# find extrema with prominence (simple: alternating hysteresis)
ext = []
mode = None; cand_i = 0
for i in range(1, len(vs)):
    if mode is None:
        if vs[i] - vs[cand_i] > prom: mode = 'up'; cand_i = i
        elif vs[cand_i] - vs[i] > prom: mode = 'down'; cand_i = i
        else:
            continue
    elif mode == 'up':
        if vs[i] > vs[cand_i]: cand_i = i
        elif vs[cand_i] - vs[i] > prom:
            ext.append(('max', cand_i)); mode = 'down'; cand_i = i
    else:
        if vs[i] < vs[cand_i]: cand_i = i
        elif vs[i] - vs[cand_i] > prom:
            ext.append(('min', cand_i)); mode = 'up'; cand_i = i
ext.append((('max' if mode == 'up' else 'min'), cand_i))
for kind, i in ext:
    # refine on raw within +-6 cols
    lo, hi = max(i - 6, 0), min(i + 7, len(vv))
    j = lo + (np.argmax(vv[lo:hi]) if kind == 'max' else np.argmin(vv[lo:hi]))
    print('%s  t=%7.2f  v=%7.3f  (smoothed %7.3f)  x=%d thick=%.0f' % (kind, tt[j], vv[j], vs[i], xs[j], thh[j]))
