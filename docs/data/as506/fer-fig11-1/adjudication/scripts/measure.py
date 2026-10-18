"""Re-digitise panel-1 attitude near 15 and 20 s on the 400 dpi rotated render.

usage: python3 -I measure.py rot400.png grid1.json out.json
"""
import sys, json
import numpy as np
from PIL import Image

img = np.array(Image.open(sys.argv[1]).convert('L'))
THR = int(sys.argv[4]) if len(sys.argv) > 4 else 128
dark = img < THR
grid = json.load(open(sys.argv[2]))
V = {int(k): v for k, v in grid['vertical'].items()}


def vx(t, y):
    f = V[t]
    return f['a'] + f['b'] * y


def runs(col, y0):
    a = col.astype(np.int8)
    d = np.diff(np.concatenate([[0], a, [0]]))
    s = np.where(d == 1)[0]; e = np.where(d == -1)[0]
    return [(y0 + i, y0 + j - 1) for i, j in zip(s, e)]


def robust_fit(u, v, k=2.5, it=8, deg=1):
    u = np.asarray(u, float); v = np.asarray(v, float)
    m = np.ones(len(u), bool)
    for _ in range(it):
        p = np.polyfit(u[m], v[m], deg)
        r = v - np.polyval(p, u)
        s = np.std(r[m])
        m2 = np.abs(r) < max(k * s, 0.6)
        if (m2 == m).all():
            break
        m = m2
    return p, float(np.std(r[m])), int(m.sum())


def near_vertical(x, y=900, tol=9):
    return any(abs(x - vx(t, y)) < tol for t in V)


res = {}
# ---------------- top border, columns 0..45 s
cols = [x for x in range(812, 1440) if not near_vertical(x)]
top, bot_attached, sep = {}, {}, {}
for x in cols:
    rr = runs(dark[840:960, x], 840)
    # band = run that covers rows 862..866 region (border)
    band = [r for r in rr if r[0] <= 866 and r[1] >= 861]
    if not band:
        continue
    b = band[0]
    top[x] = b[0]; bot_attached[x] = b[1]
    below = [r for r in rr if r[0] > b[1] and r[0] - b[1] <= 40]
    if below:
        sep[x] = below[0]

xt = np.array(sorted(top)); yt = np.array([top[x] for x in xt], float)
p_top, rms_top, n_top = robust_fit(xt, yt)
p_top2, rms_top2, _ = robust_fit(xt, yt, deg=2)
print('top edge linear fit 0-45 s: y = %.3f + %.5f x  rms %.2f n %d/%d' % (p_top[1], p_top[0], rms_top, n_top, len(xt)))
print('top edge quad fit coeffs', p_top2, 'rms %.2f' % rms_top2)

# bare-border thickness from columns where a separate curve run exists and gap >= 2
bare = [x for x in sep if sep[x][0] - bot_attached[x] >= 3]
thick = np.array([bot_attached[x] - top[x] + 1 for x in bare], float)
print('bare border columns: %d, x %d..%d; thickness (incl) mean %.2f median %.1f sd %.2f' % (
    len(bare), min(bare), max(bare), thick.mean(), np.median(thick), thick.std()))
xb = np.array(sorted(bare)); yb = np.array([bot_attached[x] for x in xb], float)
p_bot, rms_bot, n_bot = robust_fit(xb, yb)
print('bare bottom edge fit: y = %.3f + %.5f x rms %.2f n %d' % (p_bot[1], p_bot[0], rms_bot, n_bot))
# also thickness for x in 1440..1700 (40-70 s), clearly bare
th2 = []
for x in range(1445, 1700):
    if near_vertical(x):
        continue
    rr = runs(dark[850:890, x], 850)
    band = [r for r in rr if r[0] <= 870 and r[1] >= 864]
    if band:
        th2.append(band[0][1] - band[0][0] + 1)
th2 = np.array(th2, float)
print('bare border 40-70 s thickness mean %.2f median %.1f sd %.2f n %d' % (th2.mean(), np.median(th2), th2.std(), len(th2)))

T_B = float(np.median(thick))


def border_centre(x):
    # continuous coordinates: top edge pixel s -> boundary s-0.5 ; centre = s-0.5+T/2
    return np.polyval(p_top, x) - 0.5 + T_B / 2.0


# ---------------- line 2 (-20 deg), local fit 0..55 s
cols2 = [x for x in range(812, 1500) if not near_vertical(x, 990)]
u2, v2 = [], []
for x in cols2:
    rr = runs(dark[960:1020, x], 960)
    c = [r for r in rr if r[1] - r[0] + 1 <= 10 and abs((r[0] + r[1]) / 2 - (982 + 0.0105 * (x - 807))) < 8]
    if c:
        u2.append(x); v2.append((c[0][0] + c[0][1]) / 2.0)
p_l2, rms_l2, n_l2 = robust_fit(u2, v2)
print('line2 (-20) centre fit: y = %.3f + %.5f x rms %.2f n %d/%d' % (p_l2[1], p_l2[0], rms_l2, n_l2, len(u2)))
# also line 2 thickness
w2 = []
for x in cols2:
    rr = runs(dark[960:1020, x], 960)
    c = [r for r in rr if abs((r[0] + r[1]) / 2 - np.polyval(p_l2, x)) < 3]
    if c:
        w2.append(c[0][1] - c[0][0] + 1)
print('line2 thickness mean %.2f median %.1f' % (np.mean(w2), np.median(w2)))

# ---------------- curve centre per column
# curve thickness from separate runs, slope-corrected using local trend
xs_sep = np.array(sorted(x for x in sep if sep[x][0] - bot_attached[x] >= 2))
cc_sep = np.array([(sep[x][0] + sep[x][1]) / 2.0 for x in xs_sep])
hh_sep = np.array([sep[x][1] - sep[x][0] + 1 for x in xs_sep], float)
pc = np.polyfit(xs_sep, cc_sep, 2)
slope = np.polyval(np.polyder(pc), xs_sep)
hperp = hh_sep * np.cos(np.arctan(slope))
print('separate curve runs: x %d..%d n %d; vertical h mean %.2f; perpendicular h mean %.2f median %.1f sd %.2f' % (
    xs_sep.min(), xs_sep.max(), len(xs_sep), hh_sep.mean(), hperp.mean(), np.median(hperp), hperp.std()))
# near the merge point (first 120 columns of separation) where slope is small
early = xs_sep < xs_sep.min() + 120
print('  early separated (x<%d): perpendicular h mean %.2f n %d' % (xs_sep.min() + 120, hperp[early].mean(), early.sum()))
H_C = float(np.mean(hperp[early]))

curve = {}
for x in cols:
    if x not in top:
        continue
    if x in sep and sep[x][0] - bot_attached[x] >= 2:
        curve[x] = ((sep[x][0] + sep[x][1]) / 2.0, 'sep')
    else:
        # merged: curve bottom edge = band bottom
        curve[x] = (bot_attached[x] + 0.5 - H_C / 2.0, 'merged')

res['params'] = dict(top_fit=list(p_top), border_thickness=T_B, line2_fit=list(p_l2),
                     curve_h=H_C, bottom_fit=list(p_bot))


def value_at(x, yc):
    y1 = border_centre(x); y2 = np.polyval(p_l2, x)
    return -20.0 * (yc - y1) / (y2 - y1)


def time_at(x, y):
    ts = sorted(V)
    for i in range(len(ts) - 1):
        xa, xb = vx(ts[i], y), vx(ts[i + 1], y)
        if xa <= x <= xb:
            return ts[i] + 10.0 * (x - xa) / (xb - xa)
    return None


print('\nper-column (every 4 px) x, t, border centre, band bottom, curve centre, kind, value')
rows = []
for x in sorted(curve):
    yc, kind = curve[x]
    t = time_at(x, yc)
    v = value_at(x, yc)
    rows.append((x, t, yc, kind, v))
    if x % 4 == 0 and x < 1340:
        print('%d t=%.2f bc=%.2f top=%d bandbot=%d yc=%.2f %s v=%.2f' % (
            x, t, border_centre(x), top[x], bot_attached[x], yc, kind, v))

# samples at 15, 20, 25, 30 s: local linear fit of yc over +-15 px around the time-line x
print('\nsamples:')
out = {}
for T in [10, 12.5, 15, 17.5, 20, 22.5, 25, 30, 35, 40]:
    # find x where time = T at curve's y (iterate)
    yg = 870.0
    for _ in range(5):
        tl = int(T // 10) * 10
        if T == tl:
            xT = vx(tl, yg)
        else:
            xa, xb = vx(tl, yg), vx(tl + 10, yg)
            xT = xa + (T - tl) / 10.0 * (xb - xa)
        sel = [(x, yc) for (x, t, yc, kind, v) in rows if abs(x - xT) <= 15]
        if len(sel) < 5:
            break
        px = np.polyfit([s[0] for s in sel], [s[1] for s in sel], 1)
        yg = np.polyval(px, xT)
    kinds = set(kind for (x, t, yc, kind, v) in rows if abs(x - xT) <= 15)
    val = value_at(xT, yg)
    sc = 20.0 / (np.polyval(p_l2, xT) - border_centre(xT))
    print('T=%5.1f s  x=%.1f  curve yc=%.2f  border centre=%.2f  offset=%.2f px  scale %.4f deg/px  value=%.2f deg  (%s, n=%d)' % (
        T, xT, yg, border_centre(xT), yg - border_centre(xT), sc, val, ','.join(sorted(kinds)), len(sel)))
    out[str(T)] = dict(x=xT, yc=yg, border_centre=border_centre(xT), value=val, kinds=sorted(kinds))
res['samples'] = out
res['rows'] = [(int(x), t, yc, kind, v) for (x, t, yc, kind, v) in rows]
json.dump(res, open(sys.argv[3], 'w'), indent=1)
