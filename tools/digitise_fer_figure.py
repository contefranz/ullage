#!/usr/bin/env python3
"""Trace the solid ("measured" / "reconstructed") curve of one gridded panel
of a scanned figure, such as those of the AS-506 Flight Evaluation Report.

Usage:
    pdftoppm -f 159 -l 159 -r 300 -gray lvfea-AS506-Apollo11.pdf page
    python3 tools/digitise_fer_figure.py page-159.pgm --rotate 90 \
        --box 596,2220,1075,1570 --rows 1.2,-0.8,6 --cols 0,170,18 \
        --from 0.5 --to 161.6 --seed 0 --step 0.2 > trace.csv

The panel box (pixels, after the rotation) must contain the panel's frame
and nothing else of the page. The frame and grid lines calibrate the axes:
--rows gives the values of the top and bottom horizontal lines and how many
lines there are (frame included), --cols the times of the first and last
vertical lines and their count. The panel's skew is measured from the grid
and removed; between grid lines both axes are linear, so that the scans'
uneven line spacing (2-3 px) does not shift the trace.

The curve is traced as the cheapest left-to-right path (dynamic programming
over the pixel columns): a column on ink costs nothing, one on the ink of a
short fragment (a dash of the dashed "predicted" curve) costs --csmall, one
inside a horizontal grid band, where the grid removal took the ink, --cband
(--cbandink where ink touches the band's edge: the curve runs along or across
the line there), one off any ink --cgap, and every pixel of vertical travel --alpha; within an
ink run, a small cost (at most --inruncap) keeps the path at the run's centre. A solid
line is continuous, so it beats a row of dashes even where it swings further.
Vertical grid bands are free. The value at a column is the centre of the ink
run the path passes through, or the grid line's value where the path runs
under a horizontal line; columns without either are interpolated, and the
output flags samples that fall in such a gap longer than 0.5 s.

Where the automatic choice fails (the solid line hidden under a grid line
with the dashed one beside it), --ignore drops the ink in a box given in the
figure's coordinates; the output's header records every option used. Write
--overlay to check the trace by eye (trace in red, ink kept in grey).
Only numpy is needed; the page images come from poppler's pdftoppm.
"""
import argparse
import sys

import numpy as np


def load_pgm(path):
    with open(path, "rb") as f:
        data = f.read()
    fields, i = [], 0
    while len(fields) < 4:
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while data[i:i + 1] != b"\n":
                i += 1
            continue
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        fields.append(data[i:j])
        i = j
    if fields[0] != b"P5" or int(fields[3]) != 255:
        raise ValueError("expected an 8-bit binary PGM (pdftoppm -gray)")
    w, h = int(fields[1]), int(fields[2])
    return np.frombuffer(data[i + 1:i + 1 + w * h], np.uint8).reshape(h, w)


def skew_angle(ink, box):
    """Rotation (rad) that makes the panel's horizontal lines level: the one
    that sharpens the row profile most."""
    x0, x1, y0, y1 = box
    ys, xs = np.nonzero(ink[y0:y1, x0:x1])
    best = (-1.0, 0.0)
    for a in np.radians(np.arange(-1.5, 1.5001, 0.01)):
        v = ys * np.cos(a) - xs * np.sin(a)
        prof = np.bincount(np.round(v - v.min()).astype(int)).astype(float)
        s = float((prof ** 2).sum())
        if s > best[0]:
            best = (s, a)
    return best[1]


def resample(ink, box, a):
    """The box, rotated by a about its top-left corner (nearest neighbour)."""
    x0, x1, y0, y1 = box
    v, u = np.mgrid[0:y1 - y0, 0:x1 - x0].astype(float)
    x = u * np.cos(a) - v * np.sin(a)
    y = u * np.sin(a) + v * np.cos(a)
    xi = np.clip(np.round(x).astype(int) + x0, 0, ink.shape[1] - 1)
    yi = np.clip(np.round(y).astype(int) + y0, 0, ink.shape[0] - 1)
    return ink[yi, xi]


def peaks(profile, threshold=0.3):
    """Weighted centres of the runs of a projection profile above threshold."""
    out, i, n = [], 0, len(profile)
    while i < n:
        if profile[i] > threshold:
            j = i
            while j < n and profile[j] > threshold:
                j += 1
            seg = profile[i:j]
            out.append(i + float((seg * np.arange(j - i)).sum() / seg.sum()))
            i = j
        else:
            i += 1
    return out


def grid(profile, count, what):
    """The count lines of a regular grid whose first and last are the frame:
    each detected where a profile peak lies within 6 px of the lattice."""
    found = peaks(profile)
    if len(found) < 2:
        sys.exit(f"no {what} grid found")
    first, last = found[0], found[-1]
    lines = []
    for k in range(count):
        want = first + k * (last - first) / (count - 1)
        near = min(found, key=lambda c: abs(c - want))
        lines.append(near if abs(near - want) < 6 else want)
        if abs(near - want) >= 6:
            print(f"# {what} line {k} not detected; lattice position used", file=sys.stderr)
    return lines


def remove_bands(img, rows, cols, half=3):
    img = img.copy()
    for r in rows:
        img[max(int(round(r)) - half, 0):int(round(r)) + half + 1] = False
    for c in cols:
        img[:, max(int(round(c)) - half, 0):int(round(c)) + half + 1] = False
    return img


def label(img):
    """8-connected components, by runs and union-find."""
    h, w = img.shape
    parent = [0]

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    labels = np.zeros((h, w), np.int64)
    prev = []
    for y in range(h):
        edges = np.flatnonzero(np.diff(np.concatenate(([0], img[y].astype(np.int8), [0]))))
        runs = []
        for k in range(0, len(edges), 2):
            a, b = edges[k], edges[k + 1]
            lab = len(parent)
            parent.append(lab)
            for pa, pb, pl in prev:
                if pa <= b and pb >= a:
                    ra, rb = find(lab), find(pl)
                    if ra != rb:
                        parent[max(ra, rb)] = min(ra, rb)
            runs.append((a, b, lab))
            labels[y, a:b] = lab
        prev = runs
    roots = np.array([find(i) for i in range(len(parent))])
    return roots[labels]


def trace(ink_big, ink_small, rows, cols, x_a, x_b, y_seed, p):
    h = ink_big.shape[0]
    yy = np.arange(h, dtype=float)
    band = np.zeros(h, bool)
    for r in rows:
        band[max(int(round(r)) - 3, 0):int(round(r)) + 4] = True
    vband = np.zeros(ink_big.shape[1], bool)
    for c in cols:
        vband[max(int(round(c)) - 3, 0):int(round(c)) + 4] = True
    inf = 1e18
    cost = np.abs(yy - y_seed) * p.alpha
    back = []
    for x in range(x_a, x_b + 1):
        em = np.zeros(h)
        if not vband[x]:
            em[:] = p.cgap
            em[band] = p.cband
            # A band whose edge the ink touches in this column hides the curve:
            # the curve runs along or across the grid line there.
            near = ink_big[:, x] | ink_small[:, x]
            for r in rows:
                lo, hi = int(round(r)) - 3, int(round(r)) + 4
                if near[max(lo - 2, 0):max(lo, 0)].any() or near[hi:hi + 2].any():
                    em[max(lo, 0):hi] = p.cbandink
            for ink, base in ((ink_small[:, x], p.csmall), (ink_big[:, x], 0.0)):
                e = np.flatnonzero(np.diff(np.concatenate(([0], ink.astype(np.int8), [0]))))
                for k in range(0, len(e), 2):
                    lo, hi = e[k], e[k + 1]
                    c = (lo + hi - 1) / 2.0
                    off = np.minimum(p.inrun * np.abs(yy[lo:hi] - c), p.inruncap)
                    em[lo:hi] = np.minimum(em[lo:hi], base + off)
        best = np.full(h, inf)
        arg = np.zeros(h, np.int64)
        for d in range(-p.maxjump, p.maxjump + 1):
            shifted = np.full(h, inf)
            if d > 0:
                shifted[d:] = cost[:h - d]
            elif d < 0:
                shifted[:d] = cost[-d:]
            else:
                shifted[:] = cost
            cand = shifted + p.alpha * abs(d)
            m = cand < best
            best[m] = cand[m]
            arg[m] = np.arange(h)[m] - d
        cost = best + em
        back.append(arg)
    y = int(np.argmin(cost))
    path = [y]
    for arg in reversed(back[1:]):
        y = int(arg[y])
        path.append(y)
    path.reverse()
    ink_any = ink_big | ink_small
    centres = []
    for x, y in zip(range(x_a, x_b + 1), path):
        col = ink_any[:, x]
        if vband[x]:
            centres.append(None)
            continue
        if not col[y]:
            # Under a horizontal grid line the curve's ink is gone: it lies on
            # the line, so take the line's position.
            near = min(rows, key=lambda r: abs(r - y))
            centres.append(float(near) if band[y] and abs(near - y) <= 3.5 else None)
            continue
        lo = hi = y
        while lo > 0 and col[lo - 1]:
            lo -= 1
        while hi < h - 1 and col[hi + 1]:
            hi += 1
        centres.append((lo + hi) / 2.0)
    return centres


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("pgm")
    ap.add_argument("--rotate", type=int, default=0, choices=(0, 90, 180, 270), help="clockwise, to make the panel upright")
    ap.add_argument("--box", required=True, help="x0,x1,y0,y1 of the panel, frame included")
    ap.add_argument("--rows", required=True, help="top value, bottom value, number of horizontal lines")
    ap.add_argument("--cols", required=True, help="first time, last time, number of vertical lines")
    ap.add_argument("--offset", type=float, default=0.0, help="added to the figure's time on output")
    ap.add_argument("--from", dest="t_from", type=float, required=True, help="figure time to start the trace")
    ap.add_argument("--to", dest="t_to", type=float, required=True, help="figure time to end it")
    ap.add_argument("--seed", type=float, required=True, help="the curve's value at --from")
    ap.add_argument("--step", type=float, default=0.5, help="output step (s)")
    ap.add_argument("--minarea", type=int, default=180, help="ink pixels of a component that counts as the solid line")
    ap.add_argument("--minfragment", type=int, default=60, help="smaller components are ignored")
    ap.add_argument("--alpha", type=float, default=0.05)
    ap.add_argument("--cgap", type=float, default=1.0)
    ap.add_argument("--csmall", type=float, default=0.9)
    ap.add_argument("--cband", type=float, default=0.8)
    ap.add_argument("--cbandink", type=float, default=0.3, help="a band column whose edge the ink touches")
    ap.add_argument("--inrun", type=float, default=0.05)
    ap.add_argument("--inruncap", type=float, default=0.25)
    ap.add_argument("--maxjump", type=int, default=40)
    ap.add_argument("--ignore", action="append", default=[], metavar="T0:T1:V0:V1",
                    help="drop the ink in this box (figure time and value) before tracing; repeatable")
    ap.add_argument("--source", help="provenance printed at the head of the output (\\n separates lines)")
    ap.add_argument("--overlay", help="write the panel with the trace in red (PPM)")
    p = ap.parse_args()

    img = load_pgm(p.pgm)
    img = np.rot90(img, k=-(p.rotate // 90))
    ink = img < 128
    box = tuple(int(s) for s in p.box.split(","))
    ang = skew_angle(ink, box)
    sub = resample(ink, box, ang)
    v_top, v_bottom, n_rows = p.rows.split(",")
    t_first, t_last, n_cols = p.cols.split(",")
    rows = grid(sub.mean(1), int(n_rows), "horizontal")
    cols = grid(sub.mean(0), int(n_cols), "vertical")
    values = np.linspace(float(v_top), float(v_bottom), int(n_rows))
    t_first, t_last = float(t_first), float(t_last)

    def value(y):
        return float(np.interp(y, rows, values))

    def y_of(v):
        return float(np.interp(v, values[::-1], rows[::-1]))

    # Time is piecewise linear between the grid's vertical lines: the scans'
    # lines are unevenly spaced (by up to 2-3 px), as are the values' rows.
    times = np.linspace(t_first, t_last, int(n_cols))

    def t_of(x):
        return float(np.interp(x, cols, times))

    def x_of(t):
        return float(np.interp(t, times, cols))

    clean = remove_bands(sub, rows, cols)
    # Operator boxes (figure time and value) whose ink is not the curve, e.g.
    # the dashed curve where the solid one hides under a grid line.
    for box_spec in p.ignore:
        t0, t1, v0, v1 = (float(s) for s in box_spec.split(":"))
        xa, xb = sorted((int(round(x_of(t0))), int(round(x_of(t1)))))
        ya, yb = sorted((int(round(y_of(v0))), int(round(y_of(v1)))))
        clean[max(ya, 0):yb + 1, max(xa, 0):xb + 1] = False
    lab = label(clean)
    size = np.bincount(lab[clean], minlength=lab.max() + 1)
    big = (size >= p.minarea)[lab] & clean
    small = (size >= p.minfragment)[lab] & clean & ~big
    x_a, x_b = int(np.ceil(x_of(p.t_from))), int(np.floor(x_of(p.t_to)))
    centres = trace(big, small, rows, cols, x_a, x_b, y_of(p.seed), p)

    xs = np.array([x for x, c in zip(range(x_a, x_b + 1), centres) if c is not None], float)
    vs = np.array([value(c) for c in centres if c is not None])
    for line in (p.source or "").split("\\n"):
        if line:
            print(f"# {line}")
    print(f"# digitised with tools/digitise_fer_figure.py from {p.pgm.rsplit('/', 1)[-1]}, rotated {p.rotate} deg, "
          f"panel {p.box}; skew {np.degrees(ang):+.3f} deg removed")
    print(f"# trace options: --from {p.t_from:g} --to {p.t_to:g} --seed {p.seed:g} --step {p.step:g} --offset {p.offset:g} "
          f"--minarea {p.minarea} --minfragment {p.minfragment} --maxjump {p.maxjump} --cband {p.cband:g} "
          f"--cbandink {p.cbandink:g} --csmall {p.csmall:g}" + "".join(f" --ignore {b}" for b in p.ignore))
    print(f"# grid: rows {p.rows} at y {', '.join('%.1f' % r for r in rows)}; cols {p.cols} at x {cols[0]:.1f} .. {cols[-1]:.1f}")
    print(f"# scale {abs(values[0] - values[-1]) / abs(rows[-1] - rows[0]):.5f} per px, "
          f"{(t_last - t_first) / (cols[-1] - cols[0]):.4f} s per px; traced {len(xs)} of {x_b - x_a + 1} columns")
    print("time,value,gap")
    t = p.t_from
    while t <= p.t_to + 1e-9:
        x = x_of(t)
        v = float(np.interp(x, xs, vs))
        k = np.searchsorted(xs, x)
        gap = 0
        if 0 < k < len(xs) and t_of(xs[k]) - t_of(xs[k - 1]) > 0.5 and xs[k] != x:
            gap = 1
        print(f"{t + p.offset:.2f},{v:.4f},{gap}")
        t = round(t + p.step, 9)

    if p.overlay:
        rgb = np.where(sub[..., None], 0, 255).astype(np.uint8).repeat(3, 2)
        rgb[big | small] = (160, 160, 160)
        for x, c in zip(range(x_a, x_b + 1), centres):
            if c is not None:
                rgb[int(round(c)), x] = (255, 0, 0)
        with open(p.overlay, "wb") as f:
            f.write(b"P6\n%d %d\n255\n" % (rgb.shape[1], rgb.shape[0]))
            f.write(rgb.tobytes())


if __name__ == "__main__":
    main()
