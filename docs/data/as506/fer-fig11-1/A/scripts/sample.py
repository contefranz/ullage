# Sample a traced path at given times. Usage: sample.py track.json [extrema_prom]
import sys, json
import numpy as np
pts = json.load(open(sys.argv[1]))
prom = float(sys.argv[2]) if len(sys.argv) > 2 else 0
good = [p for p in pts if p['y'] is not None and p['flag'] in ('cB', 'cS')]
t = np.array([p['t'] for p in good]); v = np.array([p['v'] for p in good])
o = np.argsort(t); t = t[o]; v = v[o]
times = [15 + 5*i for i in range(30)]
print(' t    value   gap_s  flagnote')
for T in times:
    if T < t[0] or T > t[-1]:
        print(f'{T:5.1f}  out of range'); continue
    j = np.searchsorted(t, T)
    lo = t[j-1] if j > 0 else t[0]; hi = t[j] if j < len(t) else t[-1]
    gap = hi - lo
    val = np.interp(T, t, v)
    # local spread +/-0.25 s
    m = (t > T-0.25) & (t < T+0.25)
    spread = (v[m].max() - v[m].min()) if m.any() else float('nan')
    print(f'{T:5.1f}  {val:7.3f}  {gap:5.2f}  spread{spread:6.3f}')
if prom > 0:
    # extrema on lightly smoothed curve (5-col running mean)
    k = 5
    vs = np.convolve(v, np.ones(k)/k, mode='same')
    ext = []
    for i in range(k, len(vs)-k):
        w = vs[max(0, i-12):i+13]
        if vs[i] == w.max() or vs[i] == w.min():
            ext.append(i)
    # filter by prominence relative to neighbouring extrema
    print('local extrema (t, value, max/min), prominence >=', prom)
    kept = []
    for i in ext:
        typ = 'max' if vs[i] == vs[max(0, i-12):i+13].max() else 'min'
        if kept and kept[-1][2] == typ:
            if (typ == 'max' and vs[i] > vs[kept[-1][0]]) or (typ == 'min' and vs[i] < vs[kept[-1][0]]):
                kept[-1] = (i, vs[i], typ)
            continue
        kept.append((i, vs[i], typ))
    # prominence filter iterative
    changed = True
    while changed:
        changed = False
        for n in range(1, len(kept)-1):
            a, b, c = kept[n-1], kept[n], kept[n+1]
            if abs(b[1]-a[1]) < prom or abs(b[1]-c[1]) < prom:
                # drop b and merge neighbours of same type
                pass
        # simple: report all with their neighbour deltas
    for n, (i, val, typ) in enumerate(kept):
        dl = abs(val - kept[n-1][1]) if n > 0 else 9; dr = abs(val - kept[n+1][1]) if n < len(kept)-1 else 9
        if min(dl, dr) >= prom:
            print(f'  {typ} t={t[i]:6.2f} v={v[i]:7.3f} (smoothed {val:7.3f})')
