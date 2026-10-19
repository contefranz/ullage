# Mid-zoom verification windows: raw image + DP centerline dots + sample markers.
import sys, json
import numpy as np
from PIL import Image, ImageDraw
sys.path.insert(0, sys.argv[3])
from common import load, PanelMap
img, grid, sdir, wdir, name = sys.argv[1:6]
samples_file = sys.argv[6]
tw0, tw1, step = float(sys.argv[7]), float(sys.argv[8]), float(sys.argv[9])
S = int(sys.argv[10]) if len(sys.argv) > 10 else 3
im, g = load(img, grid)
m = PanelMap(g, name, -20.0 if name == 'p1' else None)
rows = json.load(open('%s/%s_dp.json' % (wdir, name)))
samp = json.load(open(samples_file))[name]
t = tw0
while t < tw1:
    ta, tb = t - 1.5, t + step + 1.5
    xa = int(m.x_at(max(ta, 0), 1300)) ; xb = int(m.x_at(min(tb, 170), 1300))
    pr = [r for r in rows if xa <= r[0] <= xb]
    ys = [r[1] for r in pr]
    ya = int(max(min(ys) - 70, m.hy(0, xa) - 8)); yb = int(min(max(ys) + 70, m.hy(len(m.h) - 1, xa) + 8))
    crop = Image.fromarray(im[ya:yb, xa:xb]).convert('RGB').resize(((xb - xa) * S, (yb - ya) * S), Image.NEAREST)
    d = ImageDraw.Draw(crop)
    for r in pr[::2]:
        cx, cy = (r[0] - xa + 0.5) * S, (r[1] - ya + 0.5) * S
        d.ellipse([cx - 1, cy - 1, cx + 1, cy + 1], fill=(0, 200, 0))
    for s in samp:
        if ta <= s['t'] <= tb:
            cx, cy = (s['x'] - xa + 0.5) * S, (s['y'] - ya + 0.5) * S
            d.ellipse([cx - 9, cy - 9, cx + 9, cy + 9], outline=(255, 0, 0), width=2)
            d.text((cx + 10, cy - 22), '%g' % s['t'], fill=(255, 0, 0))
    crop.save('%s/win_%s_%03d.png' % (wdir, name, int(t)))
    print('win_%s_%03d.png' % (name, int(t)), crop.size)
    t += step
