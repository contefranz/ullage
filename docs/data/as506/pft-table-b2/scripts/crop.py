import sys, os
from PIL import Image
import numpy as np
src, outdir, tag = sys.argv[1], sys.argv[2], sys.argv[3]
y0, y1 = int(sys.argv[4]), int(sys.argv[5])
im = np.array(Image.open(src).convert('L'))
left = im[y0:y1, 380:2350]
tcol = im[y0:y1, 380:700]
right = im[y0:y1, 2030:4250]
sep = np.zeros((y1-y0, 12), dtype=np.uint8)
rr = np.hstack([tcol, sep, right])
Image.fromarray(left).save(os.path.join(outdir, f'{tag}_L.png'))
Image.fromarray(rr).save(os.path.join(outdir, f'{tag}_R.png'))
