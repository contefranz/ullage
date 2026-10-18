# Fit every gridline (horizontal and vertical) of each panel as a straight line.
import sys, json
import numpy as np
from PIL import Image
im = np.array(Image.open(sys.argv[1]).convert('L'))
B = im < 128
H, W = B.shape

def centroid_runs(profile, lo, hi):
    # return centroid of dark pixels in profile[lo:hi] that form the longest contiguous run
    seg = profile[lo:hi]
    idx = np.nonzero(seg)[0]
    if len(idx) == 0: return None, 0
    # split into runs
    runs = np.split(idx, np.where(np.diff(idx) > 1)[0] + 1)
    best = max(runs, key=len)
    return lo + best.mean(), len(best)

def fit_hline(y_guess, x_list, half=12, maxw=9):
    pts = []
    for x in x_list:
        c, n = centroid_runs(B[:, x], int(y_guess) - half, int(y_guess) + half + 1)
        if c is not None and 2 <= n <= maxw:
            pts.append((x, c))
    pts = np.array(pts)
    if len(pts) < 5: return np.array([np.nan, np.nan]), np.nan, len(pts)
    for it in range(3):
        A = np.vstack([np.ones(len(pts)), pts[:, 0]]).T
        coef, *_ = np.linalg.lstsq(A, pts[:, 1], rcond=None)
        r = pts[:, 1] - A @ coef
        s = np.std(r)
        keep = np.abs(r) < max(2.5 * s, 0.8)
        if keep.all(): break
        pts = pts[keep]
    return coef, np.std(r[keep]) if len(r) else 0, len(pts)

def fit_vline(x_guess, y_list, half=12, maxw=9):
    pts = []
    for y in y_list:
        c, n = centroid_runs(B[y, :], int(x_guess) - half, int(x_guess) + half + 1)
        if c is not None and 2 <= n <= maxw:
            pts.append((y, c))
    pts = np.array(pts)
    if len(pts) < 5: return np.array([np.nan, np.nan]), np.nan, len(pts)
    for it in range(3):
        A = np.vstack([np.ones(len(pts)), pts[:, 0]]).T
        coef, *_ = np.linalg.lstsq(A, pts[:, 1], rcond=None)
        r = pts[:, 1] - A @ coef
        s = np.std(r)
        keep = np.abs(r) < max(2.5 * s, 0.8)
        if keep.all(): break
        pts = pts[keep]
    return coef, np.std(r[keep]) if len(r) else 0, len(pts)

cfg = json.loads(sys.argv[2])
out = {}
for name, p in cfg.items():
    ys = p['hlines']; xs = p['vlines']
    # sample x positions between vertical gridlines (avoid +-12 px of verticals)
    xsamp = [x for x in range(int(xs[0]) + 15, int(xs[-1]) - 15, 3) if min(abs(x - v) for v in xs) > 12]
    ysamp = [y for y in range(int(ys[0]) + 15, int(ys[-1]) - 15, 2) if min(abs(y - h) for h in ys) > 12]
    hl = []
    for y in ys:
        coef, s, n = fit_hline(y, xsamp, maxw=14 if y in (ys[0], ys[-1]) else 9)
        hl.append({'a': coef[0], 'b': coef[1], 'rms': s, 'n': n})
    vl = []
    for x in xs:
        coef, s, n = fit_vline(x, ysamp, maxw=14 if x in (xs[0], xs[-1]) else 9)
        vl.append({'a': coef[0], 'b': coef[1], 'rms': s, 'n': n})
    out[name] = {'h': hl, 'v': vl}
    print(name)
    for y, l in zip(ys, hl):
        print('  H guess %6.1f: y = %8.2f + %+.5f x  (y@x=1400: %7.2f) rms %.2f n %d' % (y, l['a'], l['b'], l['a'] + l['b'] * 1400, l['rms'], l['n']))
    for x, l in zip(xs, vl):
        print('  V guess %6.1f: x = %8.2f + %+.5f y  rms %.2f n %d' % (x, l['a'], l['b'], l['rms'], l['n']))
json.dump(out, open(sys.argv[3], 'w'), indent=1)
