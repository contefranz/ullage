# print binned median positions of a horizontal line along x (to see curvature / contamination)
import sys
import numpy as np
from PIL import Image
B = np.array(Image.open(sys.argv[1]).convert('L')) < 128
y0 = float(sys.argv[2]); slope = float(sys.argv[3]); x0, x1 = int(sys.argv[4]), int(sys.argv[5]); half = int(sys.argv[6])
pts = []
for x in range(x0, x1):
    yc = y0 + slope * (x - 1400)
    lo = int(yc) - half; seg = B[lo:lo + 2 * half + 1, x]
    idx = np.nonzero(seg)[0]
    if len(idx) == 0: continue
    runs = np.split(idx, np.where(np.diff(idx) > 1)[0] + 1)
    best = max(runs, key=len)
    if 2 <= len(best) <= 12:
        pts.append((x, lo + best.mean(), len(best)))
pts = np.array(pts)
for b in range(x0, x1, 80):
    s = pts[(pts[:, 0] >= b) & (pts[:, 0] < b + 80)]
    if len(s): print('x %4d-%4d  n %3d  med y %8.2f  (minus line %.2f) width %.1f' % (b, b + 80, len(s), np.median(s[:, 1]), np.median(s[:, 1]) - (y0 + slope * (b + 40 - 1400)), np.median(s[:, 2])))
