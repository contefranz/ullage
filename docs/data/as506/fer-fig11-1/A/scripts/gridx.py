# Curve crossings of vertical gridlines: rows where the horizontal dark run through the gridline
# is wider than the bare gridline. Usage: gridx.py natr.png calib.json panel vkey dp.json k1 k2 ...
import sys, json
import numpy as np
sys.path.insert(0, sys.argv[0].rsplit('/', 1)[0])
from common import *
dark, cal = load(sys.argv[1], sys.argv[2])
P = Panel(cal[sys.argv[3]], PANEL_VALUES[sys.argv[4]])
pts = json.load(open(sys.argv[5]))
good = [p for p in pts if p['y'] is not None and p['flag'] in ('cB', 'cS')]
tt = np.array([p['t'] for p in good]); vv = np.array([p['v'] for p in good])
nh = len(P.h)
for ks in sys.argv[6:]:
    k = int(ks)
    ya = int(P.hy(0, P.vx(k, 1000))) + 4; yb = int(P.hy(nh-1, P.vx(k, 1000))) - 4
    widths = []
    for y in range(ya, yb):
        xc = int(round(P.vx(k, y)))
        if not dark[y, xc]:
            # find nearest dark within 2
            cand = [xc+d for d in (-1, 1, -2, 2) if dark[y, xc+d]]
            if not cand: widths.append((y, 0, xc, xc)); continue
            xc = cand[0]
        a = xc
        while dark[y, a-1] and xc - a < 40: a -= 1
        b = xc
        while dark[y, b+1] and b - xc < 40: b += 1
        widths.append((y, b - a + 1, a, b))
    w = np.array([x[1] for x in widths])
    base = np.median(w)
    mask = w >= base + 3
    # skip horizontal gridline rows (+-3)
    for i in range(nh):
        yc = P.hy(i, P.vx(k, 1000))
        for j, (y, *_r) in enumerate(widths):
            if abs(y - yc) <= 3: mask[j] = mask[j] and False
    groups = []
    for j, m in enumerate(mask):
        if m:
            if groups and widths[j][0] - groups[-1][-1] <= 4: groups[-1].append(widths[j][0])
            else: groups.append([widths[j][0]])
    T = 10*k
    # neighbours from trace (outside +-0.6 s)
    lm = (tt < T - 0.6) & (tt > T - 1.6); rm = (tt > T + 0.6) & (tt < T + 1.6)
    left = vv[lm].mean() if lm.any() else float('nan'); right = vv[rm].mean() if rm.any() else float('nan')
    out = []
    for g in groups:
        yc = 0.5*(g[0] + g[-1]); xc = P.vx(k, yc)
        out.append(f'{g[0]}-{g[-1]} v{P.val_of(xc, yc):+.3f}')
    print(f't={T}: base width {base:.0f}px; trace mean left(-1.6..-0.6s) {left:+.3f} right {right:+.3f}; crossings: ' + '; '.join(out))
