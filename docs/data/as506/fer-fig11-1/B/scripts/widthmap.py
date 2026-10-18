# per-pixel stroke width estimate: min over 4 directions (h, v, 2 diagonals) of the run length through the pixel
import sys
import numpy as np
from PIL import Image
L = np.load(sys.argv[1]); box = np.load(sys.argv[2]); out = sys.argv[3]
xL, xR, yT, yB = [int(v) for v in box]
F = (L[yT:yB + 1, xL:xR + 1] > 0)
H, W = F.shape
def runlen_axis(F, axis):
    # length of run containing each pixel along axis
    R = np.zeros(F.shape, np.int32)
    A = F if axis == 1 else F.T
    RR = np.zeros(A.shape, np.int32)
    for i in range(A.shape[0]):
        row = A[i]
        idx = np.nonzero(row)[0]
        if len(idx) == 0: continue
        for r in np.split(idx, np.where(np.diff(idx) > 1)[0] + 1):
            RR[i, r] = len(r)
    return RR if axis == 1 else RR.T
def runlen_diag(F, anti):
    G = F[:, ::-1] if anti else F
    H, W = G.shape
    RR = np.zeros(G.shape, np.int32)
    for d in range(-H + 1, W):
        ii = np.arange(max(0, -d), min(H, W - d)); jj = ii + d
        row = G[ii, jj]
        idx = np.nonzero(row)[0]
        if len(idx) == 0: continue
        for r in np.split(idx, np.where(np.diff(idx) > 1)[0] + 1):
            RR[ii[r], jj[r]] = len(r)
    RR = RR * 1.4142
    return RR[:, ::-1] if anti else RR
w = np.minimum.reduce([runlen_axis(F, 1), runlen_axis(F, 0), runlen_diag(F, False), runlen_diag(F, True)]).astype(float)
w[~F] = 0
np.save(out + '_w.npy', w)
rgb = np.full((H, W, 3), 255, np.uint8)
rgb[(w > 0) & (w <= 4.3)] = (230, 0, 0)
rgb[(w > 4.3) & (w <= 5.7)] = (255, 160, 0)
rgb[w > 5.7] = (0, 0, 0)
Image.fromarray(rgb).save(out + '_w.png')
vals = w[w > 0]
print('width hist (rounded):', np.bincount(np.round(vals).astype(int))[:15])
