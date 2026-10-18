import sys
import numpy as np
sys.path.insert(0, sys.argv[3])
from common import load, PanelMap
im, g = load(sys.argv[1], sys.argv[2])
for name in ['p1', 'p2', 'p3', 'p4']:
    m = PanelMap(g, name)
    ymid = 0.5 * (m.hy(0, 1400) + m.hy(len(m.h) - 1, 1400))
    xs = np.array([m.vx(i, ymid) for i in range(len(m.v))])
    t = np.arange(len(xs)) * 10.0
    c = np.polyfit(t, xs, 1); r = xs - np.polyval(c, t)
    print(name, 'V spacing px/10s %.3f, residuals of linear fit:' % (c[0] * 10 if False else c[0]*10), np.round(r, 2), 'max %.2f' % abs(r).max())
    for xq in (700, 1400, 2100):
        ys = np.array([m.hy(j, xq) for j in range(len(m.h))])
        k = np.arange(len(ys)); c2 = np.polyfit(k, ys, 1); r2 = ys - np.polyval(c2, k)
        print('   H at x=%d: px/div %.3f resid' % (xq, c2[0]), np.round(r2, 2))
    print('   slopes h:', [round(b, 5) for a, b in m.h], ' v:', [round(b, 5) for a, b in m.v])
