# Track the solid (measured) curve column by column from a seed, following connectivity.
import sys, json
import numpy as np
from PIL import Image
sys.path.insert(0, sys.argv[3])
from common import load, PanelMap

img, grid, sdir, name, wdir = sys.argv[1:6]
seed_t, seed_v = float(sys.argv[6]), float(sys.argv[7])
t_end = float(sys.argv[8]) if len(sys.argv) > 8 else 162.0
p1_step = float(sys.argv[9]) if len(sys.argv) > 9 else None
LONG = int(sys.argv[10]) if len(sys.argv) > 10 else 40
im, g = load(img, grid)
m = PanelMap(g, name, p1_step)
L = np.load('%s/%s_lab.npy' % (wdir, name))
ext = dict((int(a), int(b)) for a, b in np.load('%s/%s_ext.npy' % (wdir, name)))
xL, xR, yT, yB = np.load('%s/%s_box.npy' % (wdir, name))
longids = set(i for i, e in ext.items() if e >= LONG)
F_long = np.isin(L, list(longids))
F_all = L > 0
SW = 8  # nominal solid stroke width, px

def runs(col, lo, hi):
    idx = np.nonzero(col[lo:hi])[0]
    if len(idx) == 0: return []
    rs = np.split(idx, np.where(np.diff(idx) > 1)[0] + 1)
    return [(lo + r[0], lo + r[-1]) for r in rs]

ymid = int(0.5 * (m.hy(0, 1400) + m.hy(len(m.h) - 1, 1400)))
def col_x(t):
    return m.x_at(t, ymid)

x_seed = int(round(col_x(seed_t)))
y_seed = m.y_at(seed_v, x_seed)
x_end = int(round(col_x(t_end)))
x_start = int(round(col_x(0.0))) + 3

def bounds(x):
    a, b = m.ybounds(x); return int(a) - 6, int(b) + 7

def pick(x, prev, slope, F, gap=0):
    lo, hi = bounds(x)
    rs = runs(F[:, x], lo, hi)
    pred = prev[0] + slope  # predicted center
    best = None
    for a, b in rs:
        # connectivity: overlap with previous run (with margin)
        pa, pb = prev[1], prev[2]
        if b < pa - 4 or a > pb + 4:
            # allow also near prediction (gaps)
            if min(abs(a - pred), abs(b - pred)) > 10 + 1.0 * gap * (1 + abs(slope)) and not (a <= pred <= b):
                continue
        d = 0 if a <= pred <= b else min(abs(a - pred), abs(b - pred))
        if best is None or d < best[0]: best = (d, a, b)
    if best is None: return None
    _, a, b = best
    # thick run with a shallow curve: probably merged with a dash or crossing the other curve
    flag = ''
    if b - a + 1 > SW + 4 and abs(slope) < 1.5:
        # pick SW-wide window nearest prediction
        c = min(max(pred, a + SW / 2), b - SW / 2)
        flag = 'M'
        return (c, int(c - SW / 2), int(c + SW / 2), flag)
    return ((a + b) / 2.0, a, b, flag)

def go(direction):
    out = {}
    lo, hi = bounds(x_seed)
    rs = runs(F_long[:, x_seed], lo, hi)
    a, b = min(rs, key=lambda r: abs((r[0] + r[1]) / 2 - y_seed))
    prev = ((a + b) / 2.0, a, b)
    hist = [prev[0]]
    out[x_seed] = (prev[0], a, b, 'S')
    x = x_seed
    gap = 0
    while True:
        x += direction
        if x > x_end or x < x_start: break
        k = min(len(hist), 6)
        slope = (hist[-1] - hist[-k]) / max(k - 1, 1) if k > 1 else 0.0
        r = pick(x, prev, slope, F_long, gap)
        if r is None and gap < 3:
            r = pick(x, prev, slope, F_all, gap)
            if r is not None: r = (r[0], r[1], r[2], r[3] + 's')
        if r is None:
            gap += 1
            c = prev[0] + slope
            prev = (c, int(c - 3), int(c + 3))
            hist.append(c)
            if gap > 12: hist[-1] = hist[-2]  # stop extrapolating; widen search instead
            out[x] = (c, prev[1], prev[2], 'G')
            if gap > 40: print('lost at x', x); break
            continue
        gap = 0
        prev = (r[0], r[1], r[2])
        hist.append(r[0])
        out[x] = r
    return out

tr = go(+1); tr.update(go(-1))
xs = sorted(tr)
rows = []
for x in xs:
    c, a, b, f = tr[x]
    t = m.time(x, c); v = m.value(x, c)
    rows.append([int(x), float(c), int(a), int(b), f, float(t), float(v)])
json.dump(rows, open('%s/%s_trace.json' % (wdir, name), 'w'))
# overlay image
rgb = np.stack([im] * 3, -1).copy()
for x, c, a, b, f, t, v in rows:
    col = (0, 200, 0) if f in ('', 'S') else ((255, 0, 255) if 'M' in f else ((255, 140, 0) if 's' in f else (0, 120, 255)))
    yy = int(round(c))
    rgb[yy - 1:yy + 2, x] = col
Image.fromarray(rgb[yT:yB + 1, xL:xR + 1]).save('%s/%s_overlay.png' % (wdir, name))
print('traced', len(rows), 'cols; flags:', {f: sum(1 for r in rows if r[4] == f) for f in set(r[4] for r in rows)})
