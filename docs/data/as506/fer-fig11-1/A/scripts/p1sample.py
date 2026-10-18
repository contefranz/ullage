# Panel 1: local robust fit of the curve centreline in pixel space; values under both axis readings.
import sys, json
import numpy as np
sys.path.insert(0, sys.argv[0].rsplit('/', 1)[0])
from common import *
dark, cal = load(sys.argv[1], sys.argv[2])
pts = json.load(open(sys.argv[3]))
P20 = Panel(cal['p1'], PANEL_VALUES['p1_20']); P15 = Panel(cal['p1'], PANEL_VALUES['p1_15'])
good = [p for p in pts if p['y'] is not None and p['flag'] in ('cB','cS') and (p['bot'] - p['top']) <= 10]
X = np.array([p['x'] for p in good], float); Y = np.array([p['y'] for p in good], float)
W = np.array([p['bot'] - p['top'] + 1 for p in good])
print('stroke thickness (run length) median', np.median(W))
times = [float(a) for a in sys.argv[4:]] if len(sys.argv) > 4 else [25 + 5*i for i in range(28)]
for T in times:
    xt = P20.x_of(T, 900)
    m = np.abs(X - xt) < 15
    if m.sum() < 6:
        print(T, 'insufficient'); continue
    xs, ys = X[m], Y[m]
    keep = np.ones(len(xs), bool)
    for _ in range(4):
        c = np.polyfit(xs[keep] - xt, ys[keep], 1)
        r = ys - np.polyval(c, xs - xt)
        s = max(1.4826*np.median(np.abs(r[keep])), 0.5)
        keep = np.abs(r) < 2.5*s
    yc = np.polyval(c, 0)
    # iterate x(t) at this y
    xt2 = P20.x_of(T, yc)
    yc = np.polyval(c, xt2 - xt)
    rms = float(np.sqrt(np.mean(r[keep]**2)))
    print(f't={T:6.1f} x={xt2:7.1f} y={yc:7.2f} n={keep.sum():2d}/{len(xs):2d} rms={rms:.2f}px  v20={P20.val_of(xt2, yc):8.2f}  v15={P15.val_of(xt2, yc):8.2f}')
