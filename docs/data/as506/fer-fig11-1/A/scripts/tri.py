import sys
import numpy as np
sys.path.insert(0, sys.argv[0].rsplit('/', 1)[0])
from common import *
dark, cal = load(sys.argv[1], sys.argv[2])
P = Panel(cal['p4'], PANEL_VALUES['p4'])
# find triangles: rows 2520..2575; for each row, list wide-ish dark runs (top edges) and
# for a set of rows compute left/right edges of each triangle outline
sub = dark[2515:2580, 590:2215]
# column profile of dark fraction in rows 2525-2570
prof = sub[10:55].sum(axis=0)
# triangles occupy contiguous x spans with profile > 0 excluding gridlines (which have ~all rows dark)
for y in range(2524, 2542, 2):
    row = dark[y, 590:2215]
    d = np.diff(np.concatenate([[0], row.astype(np.int8), [0]]))
    s = np.where(d == 1)[0] + 590; e = np.where(d == -1)[0] - 1 + 590
    wide = [(a, b) for a, b in zip(s, e) if b - a >= 25]
    print(y, wide)
