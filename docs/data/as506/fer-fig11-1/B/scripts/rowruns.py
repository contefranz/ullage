import sys
import numpy as np
from PIL import Image
B = np.array(Image.open(sys.argv[1]).convert('L')) < 128
x0, x1, y0, y1 = map(int, sys.argv[2:6])
for y in range(y0, y1):
    row = B[y, x0:x1]
    idx = np.nonzero(row)[0]
    s = ''
    if len(idx):
        for r in np.split(idx, np.where(np.diff(idx) > 1)[0] + 1):
            s += ' [%d-%d]' % (x0 + r[0], x0 + r[-1])
    print(y, s)
