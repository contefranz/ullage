import sys
import numpy as np
from PIL import Image
im = np.array(Image.open(sys.argv[1]).convert('L'))
b = im < 128
print('shape', b.shape)
rows = b.sum(1); cols = b.sum(0)
thr_r = float(sys.argv[2]) if len(sys.argv) > 2 else 600
thr_c = float(sys.argv[3]) if len(sys.argv) > 3 else 400
print('rows with many dark px:')
for i, v in enumerate(rows):
    if v > thr_r: print(i, v)
print('cols with many dark px:')
for i, v in enumerate(cols):
    if v > thr_c: print(i, v)
