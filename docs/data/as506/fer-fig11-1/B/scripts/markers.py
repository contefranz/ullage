# event-marker triangles in panel 4: find apex (lowest point) x and convert to time
import sys
import numpy as np
sys.path.insert(0, sys.argv[3])
from common import load, PanelMap
im, g = load(sys.argv[1], sys.argv[2]); B = im < 128
m = PanelMap(g, 'p4')
L = np.load(sys.argv[4])
ids = np.unique(L[2520:2590, 590:2210]); ids = ids[ids > 0]
for i in ids:
    ys, xs = np.nonzero(L == i)
    w, h = xs.max() - xs.min() + 1, ys.max() - ys.min() + 1
    if w < 30 or h < 25: continue
    yb = ys.max(); xb = xs[ys == yb].mean()
    # apex: lowest rows centroid
    sel = ys >= yb - 2
    xa = xs[sel].mean()
    print('comp %d bbox x %d-%d y %d-%d  apex x=%.1f y=%d  t=%.2f' % (i, xs.min(), xs.max(), ys.min(), ys.max(), xa, yb, m.time(xa, yb)))
