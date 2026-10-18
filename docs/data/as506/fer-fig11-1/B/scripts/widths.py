import sys
import numpy as np
sys.path.insert(0, sys.argv[3])
from common import load, PanelMap
from clean import runs_containing
im, g = load(sys.argv[1], sys.argv[2]); B = im < 128
for name in ['p1', 'p2', 'p3', 'p4']:
    m = PanelMap(g, name)
    wv = []; wh = []
    y0, y1 = int(m.hy(0, 1400)) + 8, int(m.hy(len(m.h) - 1, 1400)) - 8
    for i in range(1, len(m.v) - 1):
        for y in range(y0, y1):
            for a, b in runs_containing(B[y, :], m.vx(i, y), 3):
                wv.append(b - a + 1)
    for j in range(1, len(m.h) - 1):
        for x in range(int(m.vx(0, 1300)) + 8, int(m.vx(len(m.v) - 1, 1300)) - 8):
            for a, b in runs_containing(B[:, x], m.hy(j, x), 3):
                wh.append(b - a + 1)
    print(name, 'vertical widths hist', np.bincount(wv)[:16], ' horizontal widths hist', np.bincount(wh)[:16])
