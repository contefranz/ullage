"""Dump dark runs per column. usage: colruns.py img x_from x_to step y_from y_to [thr]"""
import sys
import numpy as np
from PIL import Image

img = np.array(Image.open(sys.argv[1]).convert('L'))
xa, xb, st, Y0, Y1 = (int(v) for v in sys.argv[2:7])
thr = int(sys.argv[7]) if len(sys.argv) > 7 else 128
dark = img < thr
for x in range(xa, xb, st):
    col = dark[Y0:Y1, x].astype(np.int8)
    d = np.diff(np.concatenate([[0], col, [0]]))
    s = np.where(d == 1)[0]; e = np.where(d == -1)[0]
    print(x, ' '.join('%d-%d' % (Y0 + a, Y0 + b - 1) for a, b in zip(s, e)))
