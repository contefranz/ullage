# Per-panel gridline tracking and fitting.
# Usage: python3 -I calib.py natr.png out.json
import sys, json
import numpy as np
from PIL import Image
im = np.array(Image.open(sys.argv[1]).convert('L'))
dark = im < 128
H, W = dark.shape

# approximate geometry (from projections): panel -> list of horizontal line approx y at x~645 and x~2165, values
panels = {
  'p1': {'h': [(647.4, 661.0), (740.5, 763.5), (833.9, 856.1), (924.0, 946.9), (1018.5, 1035.9)],
         'yr': (647, 1036)},
  'p2': {'h': [(1086.0, 1099.5), (1177.5, 1190.0), (1270.0, 1282.0), (1363.4, 1375.5), (1454.4, 1465.5), (1548.0, 1559.0)],
         'yr': (1086, 1559)},
  'p3': {'h': [(1608.5, 1618.5), (1702.9, 1712.5), (1794.1, 1802.9), (1887.0, 1895.0), (1977.0, 1985.5), (2070.0, 2078.0), (2162.5, 2169.9)],
         'yr': (1608, 2170)},
  'p4': {'h': [(2207.5, 2214.5), (2300.6, 2307.1), (2394.0, 2400.5), (2485.0, 2491.0), (2578.6, 2584.5)],
         'yr': (2207, 2585)},
}
# vertical lines approx x at top of p1 (y~830): 605.5 + k*94.9, at p4 (y~2370) 593.9 + k*94.3
def vx_approx(k, y):
    xa = 605.5 + k*(2219.0-605.5)/17; ya = 830
    xb = 593.9 + k*(2201.9-593.9)/17; yb = 2370
    return xa + (xb-xa)*(y-ya)/(yb-ya)

def robust_fit(u, v):
    u = np.asarray(u, float); v = np.asarray(v, float)
    keep = np.ones(len(u), bool)
    for _ in range(5):
        A = np.vstack([np.ones(keep.sum()), u[keep]]).T
        c, *_ = np.linalg.lstsq(A, v[keep], rcond=None)
        r = v - (c[0] + c[1]*u)
        s = max(1.4826*np.median(np.abs(r[keep])), 0.3)
        newkeep = np.abs(r) < 3*s
        if (newkeep == keep).all(): break
        keep = newkeep
    r = v - (c[0] + c[1]*u)
    return c.tolist(), float(np.sqrt(np.mean(r[keep]**2))), int(keep.sum()), int(len(u))

def track_h(y_left, y_right, xL, xR, maxw):
    us, vs = [], []
    for x0 in range(int(xL)+12, int(xR)-12, 6):
        yp = y_left + (y_right - y_left)*(x0 - 645)/(2165-645)
        a = int(yp) - 10; b = int(yp) + 11
        col = dark[a:b, x0-3:x0+3].mean(axis=1)
        idx = np.where(col > 0.5)[0]
        if len(idx) == 0: continue
        # contiguous run nearest to centre
        runs = []
        for i in idx:
            if runs and i - runs[-1][-1] <= 1: runs[-1].append(i)
            else: runs.append([i])
        best = min(runs, key=lambda r: abs(np.mean(r) - 10))
        if len(best) > maxw: continue
        if len(runs) > 1: continue
        w = col[best]
        us.append(x0); vs.append(a + (np.array(best)*w).sum()/w.sum())
    return us, vs

def track_v(x_approx_fn, ya, yb, maxw):
    us, vs = [], []
    for y0 in range(int(ya)+12, int(yb)-12, 6):
        xp = x_approx_fn(y0)
        a = int(xp) - 10; b = int(xp) + 11
        row = dark[y0-3:y0+3, a:b].mean(axis=0)
        idx = np.where(row > 0.5)[0]
        if len(idx) == 0: continue
        runs = []
        for i in idx:
            if runs and i - runs[-1][-1] <= 1: runs[-1].append(i)
            else: runs.append([i])
        best = min(runs, key=lambda r: abs(np.mean(r) - 10))
        if len(best) > maxw or len(runs) > 1: continue
        w = row[best]
        us.append(y0); vs.append(a + (np.array(best)*w).sum()/w.sum())
    return us, vs

out = {}
for name, p in panels.items():
    res = {'h': [], 'v': []}
    ya, yb = p['yr']
    for i, (yl, yr) in enumerate(p['h']):
        maxw = 8 if i in (0, len(p['h'])-1) else 5
        us, vs = track_h(yl, yr, 600, 2215, maxw)
        c, rms, n, ntot = robust_fit(us, vs)
        res['h'].append({'a': c[0], 'b': c[1], 'rms': rms, 'n': n, 'ntot': ntot})
        print(name, 'h', i, f'y = {c[0]:.2f} + {c[1]:.5f} x  rms {rms:.2f} n {n}/{ntot}')
    for k in range(18):
        maxw = 8 if k in (0, 17) else 5
        us, vs = track_v(lambda y: vx_approx(k, y), ya, yb, maxw)
        if len(us) < 5:
            print(name, 'v', k, 'insufficient', len(us)); res['v'].append(None); continue
        c, rms, n, ntot = robust_fit(us, vs)
        res['v'].append({'c': c[0], 'd': c[1], 'rms': rms, 'n': n, 'ntot': ntot})
        print(name, 'v', k, f'x = {c[0]:.2f} + {c[1]:.5f} y  rms {rms:.2f} n {n}/{ntot}  x@mid {c[0]+c[1]*(ya+yb)/2:.1f}')
    out[name] = res
json.dump(out, open(sys.argv[2], 'w'), indent=1)
