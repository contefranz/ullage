import json
import numpy as np
from PIL import Image

PANELS = {
    # value at top border line, value per division (going down)
    'p1': {'top': 0.0, 'step': -20.0},   # printed 0 / -40 / -60 ; see notes (used 0..-80)
    'p2': {'top': 1.2, 'step': -0.4},
    'p3': {'top': 0.2, 'step': -0.2},
    'p4': {'top': 0.4, 'step': -0.2},
}

def load(img, grid):
    im = np.array(Image.open(img).convert('L'))
    g = json.load(open(grid))
    return im, g

class PanelMap:
    def __init__(self, g, name, p1_step=None):
        self.h = [(l['a'], l['b']) for l in g[name]['h']]
        self.v = [(l['a'], l['b']) for l in g[name]['v']]
        self.top = PANELS[name]['top']
        self.step = PANELS[name]['step'] if p1_step is None else p1_step
    def hy(self, j, x):
        a, b = self.h[j]; return a + b * x
    def vx(self, i, y):
        a, b = self.v[i]; return a + b * y
    def time(self, x, y):
        xs = np.array([self.vx(i, y) for i in range(len(self.v))])
        i = int(np.clip(np.searchsorted(xs, x) - 1, 0, len(xs) - 2))
        return 10.0 * (i + (x - xs[i]) / (xs[i + 1] - xs[i]))
    def value(self, x, y):
        ys = np.array([self.hy(j, x) for j in range(len(self.h))])
        j = int(np.clip(np.searchsorted(ys, y) - 1, 0, len(ys) - 2))
        return self.top + self.step * (j + (y - ys[j]) / (ys[j + 1] - ys[j]))
    def x_at(self, t, y):
        # x of time t at row y (interpolating between bracketing verticals at that row)
        i = int(np.clip(np.floor(t / 10.0), 0, len(self.v) - 2))
        f = t / 10.0 - i
        return self.vx(i, y) * (1 - f) + self.vx(i + 1, y) * f
    def y_at(self, v, x):
        k = (v - self.top) / self.step
        j = int(np.clip(np.floor(k), 0, len(self.h) - 2))
        f = k - j
        return self.hy(j, x) * (1 - f) + self.hy(j + 1, x) * f
    def ybounds(self, x):
        return self.hy(0, x), self.hy(len(self.h) - 1, x)
