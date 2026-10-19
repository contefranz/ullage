import sys
from PIL import Image
import numpy as np
img = Image.open(sys.argv[1]).convert('L')
best = None
for a10 in range(-25, 26):
    a = a10/10.0
    r = img.rotate(-a, resample=Image.BILINEAR, fillcolor=255)  # PIL rotate is CCW; -a => clockwise a
    arr = np.array(r)[600:2900, 300:4300] < 128
    prof = arr.sum(axis=1).astype(float)
    score = (np.diff(prof)**2).sum()
    if best is None or score > best[0]: best = (score, a)
    print(a, int(score))
print('best clockwise deg', best[1])
