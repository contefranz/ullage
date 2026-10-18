# High-zoom crop around time t with the time-line drawn (red, dotted) and run centers marked (blue ticks with index)
import sys
import numpy as np
from PIL import Image, ImageDraw
sys.path.insert(0, sys.argv[3])
from common import load, PanelMap
im, g = load(sys.argv[1], sys.argv[2]); B = im < 128
name, t, wdir = sys.argv[4], float(sys.argv[5]), sys.argv[6]
halfw = int(sys.argv[7]) if len(sys.argv) > 7 else 40
S = int(sys.argv[8]) if len(sys.argv) > 8 else 6
y0a = int(sys.argv[9]) if len(sys.argv) > 9 else None
y1a = int(sys.argv[10]) if len(sys.argv) > 10 else None
m = PanelMap(g, name, -20.0 if name == 'p1' else None)
y0, y1 = int(m.hy(0, 1400)) - 4, int(m.hy(len(m.h) - 1, 1400)) + 4
if y0a: y0, y1 = y0a, y1a
xc = int(m.x_at(t, 0.5 * (y0 + y1)))
xa, xb = xc - halfw, xc + halfw
crop = Image.fromarray(im[y0:y1, xa:xb]).convert('RGB').resize(((xb - xa) * S, (y1 - y0) * S), Image.NEAREST)
d = ImageDraw.Draw(crop)
col = []
for y in range(y0, y1):
    x = m.x_at(t, y)
    col.append(B[y, int(round(x))])
    if y % 2 == 0:
        d.point([((x - xa + 0.5) * S, (y - y0 + 0.5) * S)], fill=(255, 0, 0))
col = np.array(col); idx = np.nonzero(col)[0]
k = 0
if len(idx):
    for r in np.split(idx, np.where(np.diff(idx) > 1)[0] + 1):
        a, b = y0 + r[0], y0 + r[-1]; c = (a + b) / 2; x = m.x_at(t, c)
        v = m.value(x, c)
        X, Y = (x - xa + 0.5) * S, (c - y0 + 0.5) * S
        d.line([(X + 6, Y), (X + 20, Y)], fill=(0, 0, 255), width=2)
        d.text((X + 22, Y - 6), '%d' % k, fill=(0, 0, 255))
        print('run %d [%d-%d] c=%.1f v=%.4f' % (k, a, b, c, v))
        k += 1
# y ticks every 10 px
for y in range(y0 - y0 % 10 + 10, y1, 10):
    d.line([(0, (y - y0) * S), (8, (y - y0) * S)], fill=(0, 160, 0), width=1)
crop.save('%s/tl_%s_%05.1f.png' % (wdir, name, t))
print('saved tl_%s_%05.1f.png' % (name, t), 'crop origin', xa, y0, 'scale', S)
