# overlay traced path on original. Usage: overlay.py natr.png track.json out.png x0 y0 x1 y1 scale
import sys, json
import numpy as np
from PIL import Image, ImageDraw
img, tr, out = sys.argv[1:4]
x0, y0, x1, y1 = map(int, sys.argv[4:8]); scale = float(sys.argv[8])
im = np.array(Image.open(img).convert('L'))[y0:y1, x0:x1]
rgb = np.stack([im]*3, -1).astype(np.uint8)
rgb = np.where(rgb < 128, 150, 255).astype(np.uint8)
I = Image.fromarray(rgb).resize((int((x1-x0)*scale), int((y1-y0)*scale)), Image.NEAREST)
dr = ImageDraw.Draw(I)
pts = json.load(open(tr))
prev = None
for p in pts:
    if p['y'] is None or not (x0 <= p['x'] < x1):
        prev = None; continue
    X = (p['x'] - x0 + 0.5)*scale; Y = (p['y'] - y0 + 0.5)*scale
    col = (255, 0, 0) if p['flag'] == 'cB' else ((255, 140, 0) if p['flag'] == 'rB' else (0, 160, 0) if p['flag'] == 'cS' else (200, 0, 200))
    if prev is not None:
        dr.line([prev, (X, Y)], fill=col, width=2)
    prev = (X, Y)
for p in []:
    if p['y'] is None: continue
    if not (x0 <= p['x'] < x1): continue
    X = (p['x'] - x0 + 0.5)*scale; Y = (p['y'] - y0 + 0.5)*scale
    col = (255, 0, 0) if p['flag'] in ('cB',) else ((255, 140, 0) if p['flag'] == 'rB' else (0, 160, 0) if p['flag'] == 'cS' else (200, 0, 200))
    dr.point((X, Y), fill=col)
    dr.point((X, Y+1), fill=col)
I.save(out)
