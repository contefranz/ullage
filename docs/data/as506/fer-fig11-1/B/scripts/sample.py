# Sample DP traces every 5 s and build verification contact sheets.
import sys, json
import numpy as np
from PIL import Image, ImageDraw
sys.path.insert(0, sys.argv[3])
from common import load, PanelMap
img, grid, sdir, wdir = sys.argv[1:5]
p1_step = float(sys.argv[5])
im, g = load(img, grid)
times = [15 + 5 * k for k in range(30)]
res = {}
for name in ['p1', 'p2', 'p3', 'p4']:
    m = PanelMap(g, name, p1_step if name == 'p1' else None)
    rows = json.load(open('%s/%s_dp.json' % (wdir, name)))
    xs = np.array([r[0] for r in rows]); cs = np.array([r[1] for r in rows])
    th = np.array([r[3] - r[2] + 1 for r in rows]); il = np.array([r[4] for r in rows])
    out = []
    tiles = []
    for t in times:
        # column of time t at the trace: iterate x so that m.time(x, c(x)) = t
        x = m.x_at(t, float(np.interp(m.x_at(t, 1300), xs, cs)))
        for _ in range(3):
            c = float(np.interp(x, xs, cs)); x = m.x_at(t, c)
        c = float(np.interp(x, xs, cs))
        v = m.value(x, c)
        # nearest traced columns either side
        il_ = np.searchsorted(xs, x)
        gapL = x - xs[max(il_ - 1, 0)]; gapR = xs[min(il_, len(xs) - 1)] - x
        k = int(np.argmin(np.abs(xs - x)))
        out.append({'t': t, 'x': round(x, 1), 'y': round(c, 1), 'v': round(v, 4), 'gap': round(float(gapL + gapR), 1), 'thick': int(th[k]), 'long': bool(il[k])})
        # tile
        X, Y = int(round(x)), int(round(c))
        h = 45
        crop = im[Y - h:Y + h, X - h:X + h]
        tile = Image.fromarray(crop).convert('RGB').resize((4 * 2 * h, 4 * 2 * h), Image.NEAREST)
        d = ImageDraw.Draw(tile)
        cx, cy = 4 * (x - (X - h)), 4 * (c - (Y - h))
        d.line([(cx, cy - 40), (cx, cy - 12)], fill=(255, 0, 0), width=2)
        d.line([(cx, cy + 12), (cx, cy + 40)], fill=(255, 0, 0), width=2)
        d.line([(cx - 40, cy), (cx - 12, cy)], fill=(255, 0, 0), width=2)
        d.line([(cx + 12, cy), (cx + 40, cy)], fill=(255, 0, 0), width=2)
        d.text((4, 4), '%s t=%d v=%.3f' % (name, t, v), fill=(0, 0, 255))
        tiles.append(tile)
    res[name] = out
    # contact sheets of 10 tiles (5x2)
    for s in range(3):
        sheet = Image.new('RGB', (5 * 360, 2 * 360), 'white')
        for i, tile in enumerate(tiles[10 * s:10 * s + 10]):
            sheet.paste(tile, ((i % 5) * 360, (i // 5) * 360))
        sheet.save('%s/sheet_%s_%d.png' % (wdir, name, s))
json.dump(res, open('%s/samples_dp.json' % wdir, 'w'), indent=1)
for name in res:
    print(name)
    for r in res[name]:
        print('  t %5.1f  v %8.4f  x %7.1f y %7.1f  gap %5.1f thick %2d long %s' % (r['t'], r['v'], r['x'], r['y'], r['gap'], r['thick'], r['long']))
