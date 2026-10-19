# For given times, draw marker lines on a crop and print the dark runs at x(t) with values.
# Usage: probe.py natr.png calib.json panel vkey out.png x0 y0 x1 y1 scale t1 t2 ...
import sys
import numpy as np
from PIL import Image, ImageDraw
sys.path.insert(0, sys.argv[0].rsplit('/', 1)[0])
from common import *
img, calf, pname, vkey, out = sys.argv[1:6]
x0, y0, x1, y1 = map(int, sys.argv[6:10]); scale = float(sys.argv[10])
times = [float(a) for a in sys.argv[11:]]
import os
OFFS = [int(o) for o in os.environ.get("OFFS", "0").split(",")]
dark, cal = load(img, calf)
P = Panel(cal[pname], PANEL_VALUES[vkey])
ymid = 0.5*(P.hy(0, 1400) + P.hy(len(P.h)-1, 1400))
rgb = np.where(dark[y0:y1, x0:x1, None], 0, 255).repeat(3, 2).astype(np.uint8)
I = Image.fromarray(rgb).resize((int((x1-x0)*scale), int((y1-y0)*scale)), Image.NEAREST)
dr = ImageDraw.Draw(I)
for T in times:
    # x(t) varies slightly with y; draw the line through two y's
    xa = P.x_of(T, y0); xb = P.x_of(T, y1)
    dr.line([((xa-x0+0.5)*scale, 0), ((xb-x0+0.5)*scale, (y1-y0)*scale)], fill=(255, 0, 0), width=1)
    # runs at x(t) evaluated at mid y
    X = int(round(P.x_of(T, ymid)))
    for dx in OFFS:
        col = dark[:, X+dx]
        ya_ = int(min(P.hy(0, X), P.hy(len(P.h)-1, X))) - 5; yb_ = int(max(P.hy(0, X), P.hy(len(P.h)-1, X))) + 6
        d = np.diff(np.concatenate([[0], col[ya_:yb_].astype(np.int8), [0]]))
        ss = np.where(d == 1)[0] + ya_; ee = np.where(d == -1)[0] - 1 + ya_
        desc = []
        for s, e in zip(ss, ee):
            c = 0.5*(s+e); X2 = P.x_of(T, c)
            desc.append(f'{s}-{e} c{c:.1f} v{P.val_of(X2, c):+.3f}')
        print(f"t={T:6.1f} x={X+dx}: " + "; ".join(desc))
I.save(out)
