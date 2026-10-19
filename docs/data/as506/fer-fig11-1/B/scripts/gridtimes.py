# For samples on vertical gridlines (t = 20, 30, ... 160): compare DP value at the gridline with linear interpolation
# between DP path points at gridline -dx and +dx (outside the gridline band).
import sys, json
import numpy as np
sys.path.insert(0, sys.argv[3])
from common import load, PanelMap
im, g = load(sys.argv[1], sys.argv[2])
wdir = sys.argv[4]
samp = json.load(open(wdir + '/samples_dp.json'))
for name in ['p1', 'p2', 'p3', 'p4']:
    m = PanelMap(g, name, -20.0 if name == 'p1' else None)
    rows = json.load(open('%s/%s_dp.json' % (wdir, name)))
    xs = np.array([r[0] for r in rows]); cs = np.array([r[1] for r in rows])
    for s in samp[name]:
        if s['t'] % 10: continue
        x = s['x']
        out = []
        for dx in (4, 6):
            xl, xr = int(np.floor(x - dx)), int(np.ceil(x + dx))
            if xl not in xs or xr not in xs: out.append('n/a'); continue
            cl = cs[xs == xl][0]; cr = cs[xs == xr][0]
            c = cl + (cr - cl) * (x - xl) / (xr - xl)
            out.append('%.4f (L %.4f R %.4f)' % (m.value(x, c), m.value(xl, cl), m.value(xr, cr)))
        print('%s t=%3d  dp %.4f   interp4 %s   interp6 %s' % (name, s['t'], s['v'], out[0], out[1]))
