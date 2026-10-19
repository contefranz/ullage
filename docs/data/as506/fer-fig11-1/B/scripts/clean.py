# Remove gridlines from a panel and label connected components of what remains.
import sys
import numpy as np
from PIL import Image
sys.path.insert(0, sys.argv[3])
from common import load, PanelMap

def runs_containing(arr, c, search):
    lo = max(0, int(round(c)) - search); hi = min(len(arr), int(round(c)) + search + 1)
    idx = np.nonzero(arr[lo:hi])[0]
    if len(idx) == 0: return []
    rs = np.split(idx, np.where(np.diff(idx) > 1)[0] + 1)
    out = []
    for r in rs:
        a, b = lo + r[0], lo + r[-1]
        # extend run beyond the search window
        while a - 1 >= 0 and arr[a - 1]: a -= 1
        while b + 1 < len(arr) and arr[b + 1]: b += 1
        out.append((a, b))
    return out

def clean_panel(B, m, maxw_int=6, maxw_border=11):
    C = B.copy()
    nh, nv = len(m.h), len(m.v)
    xL = int(min(m.vx(0, m.hy(0, 600)), m.vx(0, m.hy(nh - 1, 600)))) - 8
    xR = int(max(m.vx(nv - 1, m.hy(0, 2200)), m.vx(nv - 1, m.hy(nh - 1, 2200)))) + 8
    yT = int(min(m.hy(0, xL), m.hy(0, xR))) - 8
    yB = int(max(m.hy(nh - 1, xL), m.hy(nh - 1, xR))) + 8
    for j in range(nh):
        border = j in (0, nh - 1)
        maxw = maxw_border if border else maxw_int
        for x in range(xL, xR + 1):
            yc = m.hy(j, x)
            for a, b in runs_containing(B[:, x], yc, 4 if border else 3):
                if b - a + 1 <= maxw and abs((a + b) / 2 - yc) <= (4 if border else 3):
                    C[a:b + 1, x] = False
    for i in range(nv):
        border = i in (0, nv - 1)
        maxw = maxw_border if border else maxw_int
        for y in range(yT, yB + 1):
            xc = m.vx(i, y)
            for a, b in runs_containing(B[y, :], xc, 4 if border else 3):
                if b - a + 1 <= maxw and abs((a + b) / 2 - xc) <= (4 if border else 3):
                    C[y, a:b + 1] = False
    return C, (xL, xR, yT, yB)

def label(C, box):
    xL, xR, yT, yB = box
    sub = C[yT:yB + 1, xL:xR + 1]
    H, W = sub.shape
    lab = np.zeros((H, W), dtype=np.int32)
    parent = [0]
    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]; a = parent[a]
        return a
    nxt = 1
    ys, xs = np.nonzero(sub)
    order = np.lexsort((xs, ys))
    for k in order:
        y, x = ys[k], xs[k]
        nb = []
        for dy, dx in ((-1, -1), (-1, 0), (-1, 1), (0, -1)):
            yy, xx = y + dy, x + dx
            if 0 <= yy < H and 0 <= xx < W and lab[yy, xx]:
                nb.append(lab[yy, xx])
        if not nb:
            parent.append(nxt); lab[y, x] = nxt; nxt += 1
        else:
            r = min(find(n) for n in nb)
            lab[y, x] = r
            for n in nb:
                rn = find(n)
                if rn != r: parent[rn] = r
    for k in range(1, nxt): parent[k] = find(k)
    par = np.array(parent)
    lab = par[lab]
    full = np.zeros(C.shape, dtype=np.int32)
    full[yT:yB + 1, xL:xR + 1] = lab
    return full

if __name__ == '__main__':
    im, g = load(sys.argv[1], sys.argv[2])
    B = im < 128
    name = sys.argv[4]
    m = PanelMap(g, name)
    C, box = clean_panel(B, m)
    L = label(C, box)
    np.save(sys.argv[5] + '/%s_lab.npy' % name, L)
    np.save(sys.argv[5] + '/%s_box.npy' % name, np.array(box))
    # component stats
    ids, counts = np.unique(L[L > 0], return_counts=True)
    stats = {}
    for i, c in zip(ids, counts):
        ys, xs = np.nonzero(L == i) if c > 300 else np.nonzero(L == i)
    # visual: cleaned panel image, long comps black, short comps red
    xL, xR, yT, yB = box
    sub = L[yT:yB + 1, xL:xR + 1]
    rgb = np.full(sub.shape + (3,), 255, np.uint8)
    # bbox extents
    ext = {}
    for i in ids:
        yy, xx = np.nonzero(sub == i)
        ext[i] = max(yy.max() - yy.min(), xx.max() - xx.min()) + 1
    longmask = np.isin(sub, [i for i in ids if ext[i] >= 40])
    shortmask = (sub > 0) & ~longmask
    rgb[longmask] = (0, 0, 0)
    rgb[shortmask] = (220, 0, 0)
    gridmask = B[yT:yB + 1, xL:xR + 1] & (sub == 0)
    rgb[gridmask] = (170, 200, 255)
    Image.fromarray(rgb).save(sys.argv[5] + '/%s_clean.png' % name)
    np.save(sys.argv[5] + '/%s_ext.npy' % name, np.array([[i, ext[i]] for i in ids]))
    print(name, 'box', box, 'components', len(ids), 'long', sum(1 for i in ids if ext[i] >= 40))
