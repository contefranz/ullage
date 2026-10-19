# find horizontal lines within a y-range, measured in many narrow x windows
import sys
import numpy as np
from PIL import Image
im = np.array(Image.open(sys.argv[1]).convert('L'))
dark = im < 128
xa, xb, ya, yb = map(int, sys.argv[2:6])
win = 60
thr = 0.6
for x0 in range(xa, xb - win, 95):
    sub = dark[ya:yb, x0:x0+win]
    s = sub.mean(axis=1)
    idx = np.where(s > thr)[0]
    runs = []
    for i in idx:
        if runs and i - runs[-1][-1] <= 1: runs[-1].append(i)
        else: runs.append([i])
    cs = []
    for r in runs:
        w = s[r]; c = (np.array(r)*w).sum()/w.sum()
        cs.append(f'{ya+c:.1f}({len(r)})')
    print(x0+win//2, ' '.join(cs))
