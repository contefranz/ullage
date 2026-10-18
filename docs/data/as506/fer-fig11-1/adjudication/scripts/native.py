"""Cross-check on the native 300 ppi 1-bit scan (rotated): curve centre near 15/20 s.

All fits local and done here. usage: python3 -I native.py nat_rot.png
"""
import sys
import numpy as np
from PIL import Image

img = np.array(Image.open(sys.argv[1]).convert('L'))
dark = img < 128


def runs(col, y0):
    a = col.astype(np.int8)
    d = np.diff(np.concatenate([[0], a, [0]]))
    s = np.where(d == 1)[0]; e = np.where(d == -1)[0]
    return [(y0 + i, y0 + j - 1) for i, j in zip(s, e)]


def rfit(u, v, k=2.5):
    u = np.asarray(u, float); v = np.asarray(v, float); m = np.ones(len(u), bool)
    for _ in range(8):
        p = np.polyfit(u[m], v[m], 1); r = v - np.polyval(p, u)
        s = np.std(r[m]); m2 = np.abs(r) < max(k * s, 0.6)
        if (m2 == m).all():
            break
        m = m2
    return p, float(np.std(r[m]))


# vertical lines 0..40 s near x 606, 700, 796, 889, 983
VX0 = {0: 606, 10: 700, 20: 796, 30: 889, 40: 983}
V = {}
for t, xc in VX0.items():
    us, vs = [], []
    for y in range(660, 1000):
        rr = runs(dark[y, xc - 8:xc + 9], 0)
        c = [((a + b) / 2.0 + xc - 8) for a, b in rr if b - a + 1 <= 6 and abs((a + b) / 2.0 + xc - 8 - xc) <= 5]
        if c:
            us.append(y); vs.append(c[0])
    p, s = rfit(us, vs); V[t] = p
    print('V%d: x = %.2f + %.5f y rms %.2f (x@650 %.2f)' % (t, p[1], p[0], s, np.polyval(p, 650)))


def nearV(x, y=660, tol=7):
    return any(abs(x - np.polyval(p, y)) < tol for p in V.values())


cols = [x for x in range(609, 1075) if not nearV(x)]
top, bot, sep = {}, {}, {}
for x in cols:
    rr = runs(dark[630:720, x], 630)
    b = [r for r in rr if r[0] <= 650 and r[1] >= 646]
    if not b:
        continue
    top[x], bot[x] = b[0]
    below = [r for r in rr if r[0] > b[0][1] and r[0] - b[0][1] <= 30]
    if below:
        sep[x] = below[0]
xt = sorted(top)
pt, st = rfit(xt, [top[x] for x in xt])
bare = [x for x in sep if sep[x][0] - bot[x] >= 2]
TB = float(np.median([bot[x] - top[x] + 1 for x in bare]))
xs = np.array(sorted(bare)); cs = np.array([(sep[x][0] + sep[x][1]) / 2.0 for x in xs])
hs = np.array([sep[x][1] - sep[x][0] + 1 for x in xs], float)
pc = np.polyfit(xs, cs, 2); sl = np.polyval(np.polyder(pc), xs)
hp = hs * np.cos(np.arctan(sl))
early = xs < xs.min() + 90
HC = float(hp[early].mean())
print('top edge fit y = %.2f + %.5f x rms %.2f; border thickness %.1f; curve h (early sep, perp) %.2f (all %.2f)' % (
    pt[1], pt[0], st, TB, HC, hp.mean()))
# line 2
u2, v2 = [], []
for x in [x for x in range(609, 1040) if not nearV(x, 740)]:
    rr = runs(dark[720:760, x], 720)
    c = [r for r in rr if r[1] - r[0] + 1 <= 7 and abs((r[0] + r[1]) / 2 - (736.5 + 0.0105 * (x - 605))) < 6]
    if c:
        u2.append(x); v2.append((c[0][0] + c[0][1]) / 2.0)
p2, s2 = rfit(u2, v2)
print('line2 y = %.2f + %.5f x rms %.2f n %d' % (p2[1], p2[0], s2, len(u2)))

bc = lambda x: np.polyval(pt, x) - 0.5 + TB / 2.0
yc = {}
for x in top:
    if x in sep and sep[x][0] - bot[x] >= 2:
        yc[x] = (sep[x][0] + sep[x][1]) / 2.0
    else:
        yc[x] = bot[x] + 0.5 - HC / 2.0


def xt_of(T, y):
    tl = int(T // 10) * 10
    xa = np.polyval(V[tl], y)
    if T == tl:
        return xa
    return xa + (T - tl) / 10.0 * (np.polyval(V[tl + 10], y) - xa)


for T in [10, 12.5, 15, 17.5, 20, 22.5, 25, 30, 35]:
    y = 650.0
    for _ in range(4):
        x0 = xt_of(T, y)
        sel = [(x, yc[x]) for x in yc if abs(x - x0) <= 11]
        p = np.polyfit([a for a, b in sel], [b for a, b in sel], 1)
        y = np.polyval(p, x0)
    v = -20.0 * (y - bc(x0)) / (np.polyval(p2, x0) - bc(x0))
    print('T=%5.1f x=%.1f yc=%.2f border=%.2f offset=%.2f px value=%.2f deg (n=%d)' % (T, x0, y, bc(x0), y - bc(x0), v, len(sel)))
