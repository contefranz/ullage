import json
import numpy as np
from PIL import Image

PANEL_VALUES = {
    # value of each horizontal gridline, top to bottom (as derived from printed labels)
    'p1_20': [0, -20, -40, -60, -80],     # "0" and "-40" labels honoured, bottom label "-60" treated as misprint
    'p1_15': [0, -15, -30, -45, -60],     # "0" and "-60" honoured, "-40" treated as misprint
    'p2': [1.2, 0.8, 0.4, 0.0, -0.4, -0.8],
    'p3': [0.2, 0.0, -0.2, -0.4, -0.6, -0.8, -1.0],
    'p4': [0.4, 0.2, 0.0, -0.2, -0.4],
}

def load(img, calib):
    im = np.array(Image.open(img).convert('L'))
    return im < 128, json.load(open(calib))

class Panel:
    def __init__(self, cal, values):
        self.h = cal['h']; self.v = cal['v']; self.values = values
    def hy(self, i, x):
        L = self.h[i]; return L['a'] + L['b']*x
    def vx(self, k, y):
        L = self.v[k]; return L['c'] + L['d']*y
    def t_of(self, x, y):
        xs = [self.vx(k, y) for k in range(18)]
        # piecewise linear between neighbouring gridlines; extrapolate at ends
        for k in range(17):
            if x <= xs[k+1] or k == 16:
                return 10*k + 10*(x - xs[k])/(xs[k+1]-xs[k])
    def x_of(self, t, y):
        k = min(int(t // 10), 16)
        x0 = self.vx(k, y); x1 = self.vx(k+1, y)
        return x0 + (x1-x0)*(t-10*k)/10
    def val_of(self, x, y):
        ys = [self.hy(i, x) for i in range(len(self.h))]
        n = len(ys)
        for i in range(n-1):
            if y <= ys[i+1] or i == n-2:
                return self.values[i] + (self.values[i+1]-self.values[i])*(y-ys[i])/(ys[i+1]-ys[i])
    def y_of(self, val, x):
        ys = [self.hy(i, x) for i in range(len(self.h))]
        vals = self.values
        for i in range(len(ys)-1):
            lo, hi = sorted((vals[i], vals[i+1]))
            if lo <= val <= hi or i == len(ys)-2:
                return ys[i] + (ys[i+1]-ys[i])*(val-vals[i])/(vals[i+1]-vals[i])

def remove_grid(dark, panel, xr, yr, hthick=3, vthick=3):
    """Return a copy of the panel region with pure-gridline pixels cleared.
    A gridline pixel is cleared only if the dark run across the line at that position
    is no longer than the line thickness + 2 (so curves crossing/hugging lines survive)."""
    x0, x1 = xr; y0, y1 = yr
    sub = dark[y0:y1, x0:x1].copy()
    Hs, Ws = sub.shape
    nh = len(panel.h)
    for i in range(nh):
        th = 7 if i in (0, nh-1) else hthick+1
        for xx in range(Ws):
            yc = panel.hy(i, x0+xx) - y0
            a = int(round(yc)) - th; b = int(round(yc)) + th + 1
            a = max(a, 0); b = min(b, Hs)
            col = sub[a:b, xx]
            idx = np.where(col)[0]
            if len(idx) == 0: continue
            # run containing the line centre
            c = int(round(yc)) - a
            # find run around c
            if c < 0 or c >= len(col) or not col[c]:
                # pick nearest dark
                c = idx[np.argmin(np.abs(idx - c))]
            lo = c
            while lo-1 >= 0 and col[lo-1]: lo -= 1
            hi = c
            while hi+1 < len(col) and col[hi+1]: hi += 1
            # extend beyond window to measure full run
            ga, gb = a+lo, a+hi
            while ga-1 >= 0 and sub[ga-1, xx]: ga -= 1
            while gb+1 < Hs and sub[gb+1, xx]: gb += 1
            if gb - ga + 1 <= (2*th if i in (0, nh-1) else hthick + 3):
                sub[ga:gb+1, xx] = False
    for k in range(18):
        th = 7 if k in (0, 17) else vthick+1
        for yy in range(Hs):
            xc = panel.vx(k, y0+yy) - x0
            a = max(int(round(xc)) - th, 0); b = min(int(round(xc)) + th + 1, Ws)
            if a >= b: continue
            row = sub[yy, a:b]
            idx = np.where(row)[0]
            if len(idx) == 0: continue
            c = int(round(xc)) - a
            if c < 0 or c >= len(row) or not row[c]:
                c = idx[np.argmin(np.abs(idx - c))]
            lo = c
            while lo-1 >= 0 and row[lo-1]: lo -= 1
            hi = c
            while hi+1 < len(row) and row[hi+1]: hi += 1
            ga, gb = a+lo, a+hi
            while ga-1 >= 0 and sub[yy, ga-1]: ga -= 1
            while gb+1 < Ws and sub[yy, gb+1]: gb += 1
            if gb - ga + 1 <= (2*th if k in (0, 17) else vthick + 3):
                sub[yy, ga:gb+1] = False
    return sub

def label(sub):
    """Connected components (8-connectivity) via column runs + union-find. Returns label image and sizes."""
    Hs, Ws = sub.shape
    parent = []
    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]; a = parent[a]
        return a
    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb: parent[rb] = ra
    runs_prev = []
    allruns = []
    for x in range(Ws):
        col = sub[:, x]
        d = np.diff(np.concatenate([[0], col.astype(np.int8), [0]]))
        starts = np.where(d == 1)[0]; ends = np.where(d == -1)[0] - 1
        runs = []
        for s, e in zip(starts, ends):
            rid = len(parent); parent.append(rid)
            runs.append((s, e, rid)); allruns.append((x, s, e, rid))
            for (ps, pe, pid) in runs_prev:
                if ps <= e+1 and pe >= s-1: union(rid, pid)
        runs_prev = runs
    lab = np.zeros(sub.shape, np.int32)
    sizes = {}
    for (x, s, e, rid) in allruns:
        r = find(rid) + 1
        lab[s:e+1, x] = r
        sizes[r] = sizes.get(r, 0) + (e - s + 1)
    return lab, sizes
