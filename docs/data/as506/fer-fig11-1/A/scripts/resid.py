import sys, json
import numpy as np
cal = json.load(open(sys.argv[1]))
for name, p in cal.items():
    hs = p['h']; vs = p['v']
    ymid = np.mean([h['a'] + h['b']*1400 for h in hs])
    xv = np.array([v['c'] + v['d']*ymid for v in vs]); k = np.arange(len(xv))
    cx = np.polyfit(k, xv, 1); rx = xv - np.polyval(cx, k)
    yh = np.array([h['a'] + h['b']*1400 for h in hs]); i = np.arange(len(yh))
    cy = np.polyfit(i, yh, 1); ry = yh - np.polyval(cy, i)
    hb = np.array([h['b'] for h in hs]); vd = np.array([v['d'] for v in vs])
    print(f"{name}: vertical lines: {cx[0]:.2f} px/10 s, max|resid| {np.abs(rx).max():.2f} px, rms {np.sqrt(np.mean(rx**2)):.2f} px; "
          f"horizontal: {cy[0]:.2f} px/div, resid {np.round(ry,2).tolist()}; "
          f"h-line slopes {hb.min():.4f}..{hb.max():.4f} ({np.degrees(np.arctan(hb.mean())):.2f} deg), v-line slopes {vd.min():.4f}..{vd.max():.4f} ({np.degrees(np.arctan(-vd.mean())):.2f} deg); "
          f"per-line fit rms h {max(h['rms'] for h in hs):.2f} v {max(v['rms'] for v in vs):.2f} px")
