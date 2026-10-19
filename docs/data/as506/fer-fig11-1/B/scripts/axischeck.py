# Panel-1 axis check: (a) integrate the panel-3 pitch-rate trace; (b) SA-504 polynomial (datasheet 8.4) for reference
import sys, json
import numpy as np
wdir = sys.argv[1]
p1 = json.load(open(wdir + '/p1_dp.json')); p3 = json.load(open(wdir + '/p3_dp.json'))
t1 = np.array([r[5] for r in p1]); v1 = np.array([r[6] for r in p1])  # v1 on 20 deg/div scale (0..-80)
o = np.argsort(t1); t1, v1 = t1[o], v1[o]
t3 = np.array([r[5] for r in p3]); v3 = np.array([r[6] for r in p3])
o = np.argsort(t3); t3, v3 = t3[o], v3[o]
tg = np.arange(0.5, 162.01, 0.05)
r = np.interp(tg, t3, v3)
r[tg < 0.6] = 0
integ = np.concatenate([[0], np.cumsum(0.5 * (r[1:] + r[:-1]) * np.diff(tg))])
F = [(3.19840, -0.544236, 0.0351605, -0.00116379, 0.0000113886),
     (-10.9607, 0.946620, -0.0294206, 0.000207717, -0.000000439036),
     (78.7826, -2.83749, 0.0289710, -0.000178363, 0.000000463029),
     (69.9191, -2.007490, 0.0105367, -0.0000233163, 0.0000000136702)]
def chi(trange, off=0.6):
    t = trange - off
    if t < 12.0: return 0.0
    t = min(t, 159.37)
    k = 0 if t < 35 else 1 if t < 80 else 2 if t < 115 else 3
    return -sum(c * t ** n for n, c in enumerate(F[k]))
print(' t   p1(0..-80)  p1(0..-60)  int(p3 rate)  SA-504 poly(cmd)')
for t in range(20, 165, 10):
    a = float(np.interp(t, t1, v1)); b = a * 0.75
    i = float(np.interp(t, tg, integ))
    print('%3d  %8.2f   %8.2f    %8.2f     %8.2f' % (t, a, b, i, chi(t)))
