# Usage: comps.py natr.png calib.json panel valuesKey outprefix
import sys, json
import numpy as np
from PIL import Image
sys.path.insert(0, sys.argv[0].rsplit('/', 1)[0])
from common import *
img, calf, pname, vkey, outp = sys.argv[1:6]
dark, cal = load(img, calf)
P = Panel(cal[pname], PANEL_VALUES[vkey])
ys = [P.hy(i, 600) for i in range(len(P.h))] + [P.hy(i, 2230) for i in range(len(P.h))]
y0 = int(min(ys)) - 12; y1 = int(max(ys)) + 12
x0 = int(min(P.vx(0, y0), P.vx(0, y1))) - 12; x1 = int(max(P.vx(17, y0), P.vx(17, y1))) + 12
sub = remove_grid(dark, P, (x0, x1), (y0, y1))
lab, sizes = label(sub)
np.save(outp + '_sub.npy', sub); np.save(outp + '_lab.npy', lab)
json.dump({'x0': x0, 'y0': y0, 'x1': x1, 'y1': y1, 'sizes': {str(k): int(v) for k, v in sizes.items()}}, open(outp + '_meta.json', 'w'))
big = sorted(sizes.items(), key=lambda kv: -kv[1])[:15]
print('origin', x0, y0, 'n comps', len(sizes)); print('largest', big)
rgb = np.full(sub.shape + (3,), 255, np.uint8)
gray = dark[y0:y1, x0:x1] & ~sub
rgb[gray] = (200, 200, 200)
thr = int(sys.argv[6]) if len(sys.argv) > 6 else 400
for r, s in sizes.items():
    m = lab == r
    rgb[m] = (220, 0, 0) if s >= thr else (0, 0, 255)
Image.fromarray(rgb).save(outp + '_comps.png')
