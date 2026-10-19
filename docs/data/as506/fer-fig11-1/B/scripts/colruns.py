# list dark runs along the slanted time-line of t (raw image), with values
import sys
import numpy as np
sys.path.insert(0, sys.argv[3])
from common import load, PanelMap
im, g = load(sys.argv[1], sys.argv[2]); B = im < 128
name = sys.argv[4]
m = PanelMap(g, name, -20.0 if name == 'p1' else None)
for t in [float(a) for a in sys.argv[5].split(',')]:
    y0, y1 = int(m.hy(0, 1400)) + 3, int(m.hy(len(m.h) - 1, 1400)) - 3
    col = []
    for y in range(y0, y1):
        x = m.x_at(t, y); col.append(B[y, int(round(x))])
    col = np.array(col)
    idx = np.nonzero(col)[0]
    out = []
    if len(idx):
        for r in np.split(idx, np.where(np.diff(idx) > 1)[0] + 1):
            a, b = y0 + r[0], y0 + r[-1]; c = (a + b) / 2
            x = m.x_at(t, c)
            out.append('[%d-%d] %.3f' % (a, b, m.value(x, c)))
    print('t=%6.2f x~%.1f: ' % (t, m.x_at(t, 0.5 * (y0 + y1))) + '  '.join(out))
