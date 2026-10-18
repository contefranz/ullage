# print dark runs in columns x (list) between y range
import sys
import numpy as np
from PIL import Image
im = np.array(Image.open(sys.argv[1]).convert('L')); dark = im < 128
ya, yb = int(sys.argv[2]), int(sys.argv[3])
for xs in sys.argv[4:]:
    x = int(xs)
    col = dark[ya:yb, x]
    runs = []; start = None
    for i, v in enumerate(col):
        if v and start is None: start = i
        if not v and start is not None: runs.append((ya+start, ya+i-1)); start = None
    if start is not None: runs.append((ya+start, yb-1))
    print(x, ' '.join(f'{a}-{b}({b-a+1})' for a, b in runs))
