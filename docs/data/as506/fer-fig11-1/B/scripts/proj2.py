import sys
import numpy as np
from PIL import Image
im = np.array(Image.open(sys.argv[1]).convert('L'))
b = im < 128
y0, y1, x0, x1 = map(int, sys.argv[2:6])
frac = float(sys.argv[6])
sub = b[y0:y1, x0:x1]
rows = sub.sum(1); cols = sub.sum(0)
print('rows (frac of width %d):' % (x1-x0))
for i, v in enumerate(rows):
    if v > frac*(x1-x0): print(y0+i, v)
print('cols (frac of height %d):' % (y1-y0))
for i, v in enumerate(cols):
    if v > frac*(y1-y0): print(x0+i, v)
