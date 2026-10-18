import sys
import numpy as np
from PIL import Image

img = np.array(Image.open(sys.argv[1]).convert('L'))
dark = img < 128
# panel 1 rough region at 400 dpi rotated: x 780..2980, y 840..1380
y0, y1, x0, x1 = 840, 1400, 780, 3000
sub = dark[y0:y1, x0:x1]
rows = sub.sum(axis=1)
cols = sub.sum(axis=0)
print('rows with >800 dark px (horizontal lines):')
for i, v in enumerate(rows):
    if v > 800:
        print(y0 + i, v)
print('cols with >250 dark px (vertical lines):')
for i, v in enumerate(cols):
    if v > 250:
        print(x0 + i, v)
