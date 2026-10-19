"""Overlay A / B / adjudicated readings at 15 and 20 s on a zoomed 400 dpi crop.

usage: python3 -I overlay.py rot400.png out.png
"""
import sys
import numpy as np
from PIL import Image, ImageDraw

img = Image.open(sys.argv[1]).convert('RGB')
X0, Y0, X1, Y1 = 960, 845, 1110, 895
Z = 8
crop = img.crop((X0, Y0, X1, Y1)).resize(((X1 - X0) * Z, (Y1 - Y0) * Z), Image.NEAREST)
d = ImageDraw.Draw(crop)
# (x, border centre, scale deg/px) from measure.py at threshold 128
pts = {15: (996.7, 863.60, 0.1595), 20: (1060.7, 864.03, 0.1590)}
vals = {15: {'A': -0.4, 'B': -1.3, 'adj': -0.69}, 20: {'A': -1.1, 'B': -1.8, 'adj': -1.40}}
col = {'A': (0, 160, 255), 'B': (255, 0, 0), 'adj': (0, 190, 0), 'zero': (255, 160, 0)}
for t, (x, bc, sc) in pts.items():
    def Y(yy):
        return (yy - Y0 + 0.5) * Z
    xx = (x - X0 + 0.5) * Z
    d.line([(xx - 60, Y(bc)), (xx + 60, Y(bc))], fill=col['zero'], width=2)
    for k, off in [('A', -40), ('B', 0), ('adj', 40)]:
        y = bc - vals[t][k] / sc
        d.line([(xx + off - 18, Y(y)), (xx + off + 18, Y(y))], fill=col[k], width=3)
    d.line([(xx, 0), (xx, 12)], fill=(255, 0, 255), width=2)
crop.save(sys.argv[2])
print(crop.size)
