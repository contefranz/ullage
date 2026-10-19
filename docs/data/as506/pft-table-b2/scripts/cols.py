import sys
from PIL import Image
import numpy as np
im = np.array(Image.open(sys.argv[1]).convert('L'))
y0, y1 = int(sys.argv[2]), int(sys.argv[3])
dark = im[y0:y1] < 128
prof = dark.sum(axis=0)
on = prof > 2
x = 0; W = len(on); out = []
while x < W:
    if on[x]:
        x0 = x
        while x < W and (on[x] or (x+1 < W and on[x+1]) or (x+40 < W and on[x:x+40].any())): x += 1
        out.append((x0, x))
    else: x += 1
print(out)
