import sys
from PIL import Image
import numpy as np
im = np.array(Image.open(sys.argv[1]).convert('L'))
dark = im < 128
# restrict to the table body columns (x 300..4300)
prof = dark[:, 300:4300].sum(axis=1)
on = prof > 40
bands = []
y = 0
H = len(on)
while y < H:
    if on[y]:
        y0 = y
        while y < H and on[y]: y += 1
        bands.append((y0, y, int(prof[y0:y].sum())))
    else:
        y += 1
for b in bands:
    if b[1]-b[0] >= 8:
        print(b)
