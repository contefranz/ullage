# Dynamic-programming trace of the solid (continuous) curve across a cleaned panel.
# Candidates per column = runs of remaining (non-grid) pixels. Path cost:
#   alpha per skipped column + beta * vertical gap between consecutive runs
#   + gamma per column spent on a short component (dash) + delta * excess thickness
import sys, json
import numpy as np
from PIL import Image
sys.path.insert(0, sys.argv[3])
from common import load, PanelMap

img, grid, sdir, name, wdir = sys.argv[1:6]
t0, t1 = float(sys.argv[6]), float(sys.argv[7])
p1_step = float(sys.argv[8]) if len(sys.argv) > 8 and sys.argv[8] != '-' else None
LONG = 40
alpha, beta, gamma, K = 3.0, 1.0, 2.0, 40
im, g = load(img, grid)
m = PanelMap(g, name, p1_step)
L = np.load('%s/%s_lab.npy' % (wdir, name))
ext = dict((int(a), int(b)) for a, b in np.load('%s/%s_ext.npy' % (wdir, name)))
xL, xR, yT, yB = [int(v) for v in np.load('%s/%s_box.npy' % (wdir, name))]
ymid = 0.5 * (m.hy(0, 1400) + m.hy(len(m.h) - 1, 1400))
xa = int(round(m.x_at(t0, ymid))); xb = int(round(m.x_at(t1, ymid)))
excl = json.loads(sys.argv[9]) if len(sys.argv) > 9 else []  # list of [x0,x1,y0,y1] boxes to ignore (text)

cands = {}
for x in range(xa, xb + 1):
    lo, hi = int(m.hy(0, x)) - 6, int(m.hy(len(m.h) - 1, x)) + 7
    col = L[lo:hi, x]
    idx = np.nonzero(col)[0]
    cs = []
    if len(idx):
        rs = np.split(idx, np.where(np.diff(idx) > 1)[0] + 1)
        for r in rs:
            a, b = lo + r[0], lo + r[-1]
            if any(e[0] <= x <= e[1] and e[2] <= (a + b) / 2 <= e[3] for e in excl): continue
            ids = set(col[r].tolist())
            islong = any(ext.get(i, 0) >= LONG for i in ids)
            cs.append((a, b, islong))
    cands[x] = cs

# DP
INF = 1e18
cost = {}; back = {}
xs = list(range(xa, xb + 1))
for x in xs:
    cost[x] = []; back[x] = []
    for k, (a, b, il) in enumerate(cands[x]):
        node = 0.0 if il else gamma
        best = alpha * (x - xa); bp = None
        for dx in range(1, K + 1):
            xp = x - dx
            if xp < xa: break
            for kp, (ap, bp_, ilp) in enumerate(cands[xp]):
                d = max(0, a - bp_, ap - b)
                c = cost[xp][kp] + alpha * (dx - 1) + beta * d
                if c < best: best = c; bp = (xp, kp)
        cost[x].append(best + node); back[x].append(bp)
# end
best = INF; end = None
for x in xs:
    for k in range(len(cands[x])):
        c = cost[x][k] + alpha * (xb - x)
        if c < best: best = c; end = (x, k)
path = []
cur = end
while cur is not None:
    x, k = cur
    a, b, il = cands[x][k]
    path.append((x, a, b, il))
    cur = back[x][k]
path.reverse()
rows = []
for x, a, b, il in path:
    c = (a + b) / 2.0
    rows.append([int(x), float(c), int(a), int(b), bool(il), float(m.time(x, c)), float(m.value(x, c))])
json.dump(rows, open('%s/%s_dp.json' % (wdir, name), 'w'))
rgb = np.stack([im] * 3, -1).copy()
for x, c, a, b, il, t, v in rows:
    rgb[a:b + 1, x] = (0, 190, 0) if il else (255, 120, 0)
    if b - a + 1 > 12: rgb[a:b + 1, x] = (255, 0, 255)
Image.fromarray(rgb[yT:yB + 1, xL:xR + 1]).save('%s/%s_dpov.png' % (wdir, name))
thick = sum(1 for r in rows if r[3] - r[2] + 1 > 12)
print(name, 'path cols', len(rows), 'of', len(xs), 'short-comp cols', sum(1 for r in rows if not r[4]), 'thick cols', thick, 'cost %.1f' % best)
