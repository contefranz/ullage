"""Fit panel-1 gridlines locally on the 400 dpi rotated render.

usage: python3 -I grid.py rot400.png out.json
"""
import sys, json
import numpy as np
from PIL import Image

img = np.array(Image.open(sys.argv[1]).convert('L'))
dark = img < 128
H, W = dark.shape

VX = {0: 807, 10: 931, 20: 1059, 30: 1183, 40: 1309, 50: 1435, 60: 1561,
      70: 1688, 80: 1815}


def runs_1d(a):
    """return list of (start, end_exclusive) of True runs"""
    a = a.astype(np.int8)
    d = np.diff(np.concatenate([[0], a, [0]]))
    s = np.where(d == 1)[0]
    e = np.where(d == -1)[0]
    return list(zip(s, e))


def robust_fit(u, v, k=2.5, it=6):
    u = np.asarray(u, float); v = np.asarray(v, float)
    m = np.ones(len(u), bool)
    for _ in range(it):
        p = np.polyfit(u[m], v[m], 1)
        r = v - np.polyval(p, u)
        s = np.std(r[m])
        m2 = np.abs(r) < max(k * s, 0.5)
        if (m2 == m).all():
            break
        m = m2
    return p, float(np.std(r[m])), int(m.sum()), len(u)


out = {}
# --- vertical lines: x = a + b*y, rows inside panel 1, avoid horizontals
vfits = {}
for t, xc in VX.items():
    us, vs = [], []
    for y in range(880, 1340):
        seg = dark[y, xc - 10: xc + 11]
        rr = runs_1d(seg)
        best = None
        for s, e in rr:
            w = e - s
            c = xc - 10 + (s + e - 1) / 2.0
            if w <= 8 and abs(c - xc) <= 7:
                if best is None or abs(c - xc) < abs(best - xc):
                    best = c
        if best is not None:
            us.append(y); vs.append(best)
    p, rms, n, ntot = robust_fit(us, vs)
    vfits[t] = dict(b=p[0], a=p[1], rms=rms, n=n, ntot=ntot)
    print('V %3d s: x = %.2f + %.5f*y  rms %.2f  n %d/%d  x@y=870 %.1f' % (
        t, p[1], p[0], rms, n, ntot, p[1] + p[0] * 870))
out['vertical'] = vfits


def hfit(ypred, xs, halfwin=9, maxw=9, edge=None):
    """centroid (or edge) of a thin dark run near ypred(x) for columns xs"""
    us, vs = [], []
    for x in xs:
        yp = ypred(x)
        lo = int(round(yp - halfwin)); hi = int(round(yp + halfwin)) + 1
        seg = dark[lo:hi, x]
        best = None
        for s, e in runs_1d(seg):
            w = e - s
            if w > maxw:
                continue
            if edge == 'top':
                c = lo + s
            elif edge == 'bot':
                c = lo + e - 1
            else:
                c = lo + (s + e - 1) / 2.0
            if abs(lo + (s + e - 1) / 2.0 - yp) <= halfwin - 2:
                if best is None or abs(c - yp) < abs(best - yp):
                    best = c
        if best is not None:
            us.append(x); vs.append(best)
    return us, vs


def not_near_vertical(x):
    for t, f in vfits.items():
        if abs(x - (f['a'] + f['b'] * 900)) < 12:
            return False
    # also beyond 80 s we have no fits; use spacing
    return True


# top border: the curve sits on it before ~20 s, so fit using 40..160 s columns
xs_bare = [x for x in range(1320, 2940) if not_near_vertical(x) and all(
    abs(x - (807 + 126.2 * k)) > 12 for k in range(18))]
xs_left = [x for x in range(812, 1300) if not_near_vertical(x)]

# top border nominal: around y 865-872 with slope ~0.01
pred = lambda x: 866 + 0.0135 * (x - 807)
for name, rng in [('bare_40_170', xs_bare), ('left_0_40', xs_left)]:
    for edge in [None, 'top', 'bot']:
        us, vs = hfit(pred, rng, halfwin=10, maxw=14, edge=edge)
        p, rms, n, ntot = robust_fit(us, vs)
        print('TOP %-12s %-4s y = %.2f + %.5f*(x)  rms %.2f n %d/%d  y@807 %.2f y@1059 %.2f' % (
            name, edge, p[1], p[0], rms, n, ntot, np.polyval(p, 807), np.polyval(p, 1059)))
        out['top_%s_%s' % (name, edge)] = dict(b=p[0], a=p[1], rms=rms, n=n)

json.dump(out, open(sys.argv[2], 'w'), indent=1)
