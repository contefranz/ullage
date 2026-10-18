# Integrate the panel-3 rate trace and compare with panel-1 attitude differences under both axis readings.
import sys, json
import numpy as np
pts = json.load(open(sys.argv[1]))
good = [p for p in pts if p['y'] is not None and p['flag'] in ('cB', 'cS')]
t = np.array([p['t'] for p in good]); v = np.array([p['v'] for p in good])
o = np.argsort(t); t = t[o]; v = v[o]
def integ(a, b):
    tt = np.linspace(a, b, 2001); vv = np.interp(tt, t, v)
    return np.trapezoid(vv, tt) if hasattr(np, 'trapezoid') else np.trapz(vv, tt)
att20 = {25: -2.58, 40: -8.35, 60: -20.79, 80: -35.56, 100: -47.55, 120: -56.69, 140: -64.07, 160: -68.97}
ratio = 15/20
keys = sorted(att20)
for a, b in zip(keys[:-1], keys[1:]):
    I = integ(a, b); d20 = att20[b] - att20[a]
    print(f'{a:3d}-{b:3d} s: integral of rate {I:7.2f} deg;  attitude change, 0..-80 reading {d20:7.2f};  0..-60 reading {d20*ratio:7.2f}')
I = integ(25, 160); d20 = att20[160] - att20[25]
print(f'25-160 s: integral {I:.2f};  0..-80 reading {d20:.2f};  0..-60 reading {d20*ratio:.2f}')
