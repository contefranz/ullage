import sys
from PIL import Image
src, out = sys.argv[1], sys.argv[2]
y0, y1, x0, x1 = map(int, sys.argv[3:7])
s = int(sys.argv[7]) if len(sys.argv) > 7 else 3
im = Image.open(src).convert('L').crop((x0, y0, x1, y1))
im = im.resize((im.width*s, im.height*s), Image.NEAREST)
im.save(out)
