# Track the solid (measured) curve column by column.
# Usage: track.py natr.png calib.json panel vkey workprefix t_start y_start t_min t_max out.json [smallcost] [bigthr]
import sys, json
import numpy as np
from PIL import Image
sys.path.insert(0, sys.argv[0].rsplit('/', 1)[0])
from common import *
img, calf, pname, vkey, wp = sys.argv[1:6]
t_start, y_start, t_min, t_max = map(float, sys.argv[6:10])
outf = sys.argv[10]
smallcost = float(sys.argv[11]) if len(sys.argv) > 11 else 6.0
bigthr = int(sys.argv[12]) if len(sys.argv) > 12 else 400
dark, cal = load(img, calf)
P = Panel(cal[pname], PANEL_VALUES[vkey])
sub = np.load(wp + '_sub.npy'); lab = np.load(wp + '_lab.npy')
meta = json.load(open(wp + '_meta.json')); x0, y0 = meta['x0'], meta['y0']
sizes = {int(k): v for k, v in meta['sizes'].items()}
Hs, Ws = sub.shape

def runs_of(colmask):
    d = np.diff(np.concatenate([[0], colmask.astype(np.int8), [0]]))
    s = np.where(d == 1)[0]; e = np.where(d == -1)[0] - 1
    return list(zip(s, e))

def candidates(xx):
    out = []
    for s, e in runs_of(sub[:, xx]):
        r = lab[s, xx]; big = sizes.get(int(r), 0) >= bigthr
        out.append((s, e, big, 'c'))
    return out

def candidates_raw(xx):
    # fallback: original dark pixels (includes gridlines)
    return [(s, e, True, 'r') for s, e in runs_of(dark[y0:y0+Hs, x0+xx])]

def trace(xstart, ystart, direction, xend):
    pts = {}
    hist = [(xstart, ystart)]
    xx = xstart
    while (xx <= xend) if direction > 0 else (xx >= xend):
        # prediction
        if len(hist) >= 6:
            (xa, ya), (xb, yb) = hist[-6], hist[-1]
            slope = (yb - ya)/(xb - xa)
            slope = max(-12, min(12, slope))
            pred = yb + slope*(xx - xb)
        else:
            pred = hist[-1][1]
        best = None
        for (s, e, big, src) in candidates(xx):
            c = 0.5*(s + e)
            # distance from prediction to the run (0 if inside)
            dist = 0 if s <= pred <= e else min(abs(s - pred), abs(e - pred))
            cost = dist + (0 if big else smallcost)
            if best is None or cost < best[0]: best = (cost, s, e, big, src)
        if best is None or best[0] > 14:
            # try raw (maybe removed by grid cleaning)
            for (s, e, big, src) in candidates_raw(xx):
                dist = 0 if s <= pred <= e else min(abs(s - pred), abs(e - pred))
                cost = dist + 3
                if best is None or cost < best[0]: best = (cost, s, e, big, src)
        if best is None or best[0] > 25:
            pts[xx] = None
            hist.append((xx, pred))
        else:
            cost, s, e, big, src = best
            # if the run is very tall relative to stroke (steep section), keep the centre
            c = 0.5*(s + e)
            # limit centre to be near prediction for long runs (curve merged with other line)
            if e - s > 14 and len(hist) >= 6 and abs(c - pred) > 8:
                c = min(max(pred, s + 3), e - 3)
                flag = 'clip'
            else:
                flag = src + ('B' if big else 'S')
            pts[xx] = (float(c), int(s), int(e), flag)
            hist.append((xx, c))
        xx += direction
    return pts

ys_mid = y_start
xs_start = P.x_of(t_start, y_start) - x0
xs_start = int(round(xs_start))
ys = y_start - y0
xmin = int(round(P.x_of(t_min, y_start) - x0)); xmax = int(round(P.x_of(t_max, y_start) - x0))
xmin = max(xmin, 0); xmax = min(xmax, Ws-1)
fw = trace(xs_start, ys, +1, xmax)
bw = trace(xs_start, ys, -1, xmin)
allp = {**bw, **fw}
res = []
for xx in sorted(allp):
    p = allp[xx]
    if p is None:
        res.append({'x': xx + x0, 'y': None}); continue
    c, s, e, flag = p
    X = xx + x0; Y = c + y0
    res.append({'x': X, 'y': Y, 'top': s + y0, 'bot': e + y0, 'flag': flag,
                't': P.t_of(X, Y), 'v': P.val_of(X, Y)})
json.dump(res, open(outf, 'w'))
nnone = sum(1 for r in res if r['y'] is None)
print('points', len(res), 'missing', nnone, 'flags', {f: sum(1 for r in res if r.get('flag') == f) for f in set(r.get('flag') for r in res)})
