import sys, json
import numpy as np
g = json.load(open(sys.argv[1]))
for p in ['p1', 'p2', 'p3', 'p4']:
    h = g[p]['h']; v = g[p]['v']
    ymid = 0.5 * ((h[0]['a'] + h[0]['b'] * 1400) + (h[-1]['a'] + h[-1]['b'] * 1400))
    hy = ['%.1f' % (l['a'] + l['b'] * 1400) for l in h]
    hs = ['%.4f' % l['b'] for l in h]; hr = max(l['rms'] for l in h)
    vx = [l['a'] + l['b'] * ymid for l in v]
    vs = [l['b'] for l in v]; vr = sorted(l['rms'] for l in v)
    t = np.arange(len(vx)) * 10.0; c = np.polyfit(t, vx, 1); res = np.array(vx) - np.polyval(c, t)
    print('%s: H lines y@x=1400 %s; slopes dy/dx %s; max rms %.2f px' % (p, hy, hs, hr))
    print('    V lines x@y=%.0f: %s' % (ymid, ' '.join('%.1f' % x for x in vx)))
    print('    V slopes dx/dy %.4f..%.4f (median %.4f); rms median %.2f max %.2f px; px per 10 s %.2f; dev from uniform spacing max %.1f px' % (min(vs), max(vs), np.median(vs), np.median(vr), max(vr), c[0] * 10, abs(res).max()))
