import sys
from PIL import Image
import numpy as np
src, out, ang = sys.argv[1], sys.argv[2], float(sys.argv[3])
im = Image.open(src).convert('L')
r = im.rotate(-ang, resample=Image.BICUBIC, fillcolor=255)
r.save(out)
a = np.array(r) < 128
prof = a[:, 225:3225].sum(axis=1)
on = prof > 30
y = 0; H = len(on); bands = []
while y < H:
    if on[y]:
        y0 = y
        while y < H and on[y]: y += 1
        if y - y0 >= 6: bands.append((y0, y))
    else: y += 1
print(bands)
