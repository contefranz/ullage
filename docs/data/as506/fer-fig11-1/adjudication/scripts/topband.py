"""Per-column dark runs around panel 1's top border (400 dpi rotated render).

usage: python3 -I topband.py rot400.png x_from x_to step
prints x and all dark runs (start,end_incl) between y=835 and y=935
"""
import sys
import numpy as np
from PIL import Image

img = np.array(Image.open(sys.argv[1]).convert('L'))
dark = img < 128
xa, xb, st = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
Y0, Y1 = 835, 935
for x in range(xa, xb, st):
    col = dark[Y0:Y1, x].astype(np.int8)
    d = np.diff(np.concatenate([[0], col, [0]]))
    s = np.where(d == 1)[0]; e = np.where(d == -1)[0]
    print(x, ' '.join('%d-%d' % (Y0 + a, Y0 + b - 1) for a, b in zip(s, e)))
