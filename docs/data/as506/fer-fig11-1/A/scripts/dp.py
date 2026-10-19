# Global DP (Viterbi) trace of the continuous solid curve.
# Usage: dp.py natr.png calib.json panel vkey workprefix t_min t_max out.json [bigthr] [smallpen] [gridpen] [anchors]
# anchors: "t:y,t:y" -- optional pixel y constraints (state must lie within 6 px) to resolve ambiguity
import sys, json
import numpy as np
sys.path.insert(0, sys.argv[0].rsplit('/', 1)[0])
from common import *
img, calf, pname, vkey, wp = sys.argv[1:6]
t_min, t_max = float(sys.argv[6]), float(sys.argv[7]); outf = sys.argv[8]
bigthr = int(sys.argv[9]) if len(sys.argv) > 9 else 400
smallpen = float(sys.argv[10]) if len(sys.argv) > 10 else 3.0
gridpen = float(sys.argv[11]) if len(sys.argv) > 11 else 1.5
anchors = []
if len(sys.argv) > 12 and sys.argv[12]:
    for a in sys.argv[12].split(','):
        xa_, ya_ = a.split(':'); anchors.append((float(xa_), float(ya_)))
dark, cal = load(img, calf)
P = Panel(cal[pname], PANEL_VALUES[vkey])
sub = np.load(wp + '_sub.npy'); lab = np.load(wp + '_lab.npy')
meta = json.load(open(wp + '_meta.json')); x0, y0 = meta['x0'], meta['y0']
sizes = {int(k): v for k, v in meta['sizes'].items()}
Hs, Ws = sub.shape
raw = dark[y0:y0+Hs, x0:x0+Ws]
hband = np.zeros_like(sub)
for i in range(len(P.h)):
    for xx in range(Ws):
        yc = int(round(P.hy(i, x0+xx) - y0))
        hband[max(yc-4, 0):yc+5, xx] = True
S = sub | (raw & hband)
ymid = 0.5*(P.hy(0, 1400) + P.hy(len(P.h)-1, 1400))
xa = max(int(round(P.x_of(t_min, ymid) - x0)), 0)
xb = min(int(round(P.x_of(t_max, ymid) - x0)), Ws-1)
import os
SKIP = int(os.environ.get('VSKIP', '5'))
vgrid = [P.vx(k, y0 + Hs/2) - x0 for k in range(18)]
cols = [c for c in range(xa, xb+1) if min(abs(c - g) for g in vgrid) > SKIP]
states = []
for xx in cols:
    col = S[:, xx]
    d = np.diff(np.concatenate([[0], col.astype(np.int8), [0]]))
    ss = np.where(d == 1)[0]; ee = np.where(d == -1)[0] - 1
    st = []
    for s, e in zip(ss, ee):
        labs = set(int(v) for v in lab[s:e+1, xx] if v)
        big = any(sizes.get(l, 0) >= bigthr for l in labs)
        small = (not big) and len(labs) > 0
        pen = 0.0 if big else (smallpen if small else gridpen)
        # anchor constraint
        X = xx + x0
        for (xa_, ya) in anchors:
            if int(round(xa_)) - x0 == xx and not (s - 6 <= ya - y0 <= e + 6):
                pen += 1e6
        # centre from cleaned big pixels if present
        cs = np.where(sub[s:e+1, xx])[0]
        st.append((int(s), int(e), pen, big))
    if not st:
        st = [(-1, -1, 50.0, False)]  # empty column: virtual state
    states.append(st)
# Viterbi
INF = 1e18
cost = [np.array([s[2] for s in states[0]])]
back = [None]
for j in range(1, len(cols)):
    prev = states[j-1]; cur = states[j]
    cprev = cost[-1]
    cc = np.full(len(cur), INF); bb = np.zeros(len(cur), int)
    for k, (s, e, pen, big) in enumerate(cur):
        for i, (ps, pe, ppen, pbig) in enumerate(prev):
            dx = cols[j] - cols[j-1]
            if s < 0 or ps < 0:
                tr = 5.0
            elif dx == 1 and ps <= e + 1 and pe >= s - 1:
                tr = 0.0
            elif dx == 1:
                gap = min(abs(s - pe), abs(ps - e))
                tr = 2.0 + gap
            else:
                # across a skipped vertical gridline band
                tol = 3*dx
                if ps <= e + tol and pe >= s - tol:
                    tr = 0.5
                else:
                    gap = min(abs(s - pe), abs(ps - e)) - tol
                    tr = 2.0 + gap
            v = cprev[i] + tr + pen
            if v < cc[k]: cc[k] = v; bb[k] = i
    cost.append(cc); back.append(bb)
k = int(np.argmin(cost[-1]))
path = [None]*len(cols)
for j in range(len(cols)-1, -1, -1):
    path[j] = k
    if j > 0: k = back[j][k]
res = []
for j, xx in enumerate(cols):
    s, e, pen, big = states[j][path[j]]
    X = xx + x0
    if s < 0:
        res.append({'x': X, 'y': None}); continue
    c = 0.5*(s + e)
    Y = c + y0
    res.append({'x': X, 'y': Y, 'top': s + y0, 'bot': e + y0,
                'flag': 'cB' if big else ('cS' if pen == smallpen else 'rB'),
                't': P.t_of(X, Y), 'v': P.val_of(X, Y)})
json.dump(res, open(outf, 'w'))
from collections import Counter
print('cols', len(cols), Counter(r.get('flag') for r in res), 'total cost', float(cost[-1].min()))
