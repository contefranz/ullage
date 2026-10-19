import sys
import numpy as np
from PIL import Image
im = np.array(Image.open(sys.argv[1]).convert('L'))
dark = im < 128
print('shape', dark.shape, 'dark frac', dark.mean())
axis = sys.argv[2]
x0, y0, x1, y1 = map(int, sys.argv[3:7])
thr = float(sys.argv[7])
sub = dark[y0:y1, x0:x1]
if axis == 'rows':
    s = sub.mean(axis=1); off = y0
else:
    s = sub.mean(axis=0); off = x0
idx = np.where(s > thr)[0]
# group runs
runs = []
for i in idx:
    if runs and i - runs[-1][-1] <= 1:
        runs[-1].append(i)
    else:
        runs.append([i])
for r in runs:
    w = s[r]
    c = (np.array(r) * w).sum() / w.sum()
    print(f'{off+r[0]}-{off+r[-1]} center {off+c:.1f} peak {w.max():.2f}')
