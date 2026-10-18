"""Integrate the digitisers' panel-3 pitch-rate traces (cross-check only).

usage: python3 -I integ.py B_p3_dp.json A_dp_p3.json
"""
import sys, json
import numpy as np


def load_B(p):
    d = json.load(open(p))
    t = np.array([r[5] for r in d], float); v = np.array([r[6] for r in d], float)
    return t, v


def load_A(p):
    d = json.load(open(p))
    d = [r for r in d if r.get('v') is not None and r.get('t') is not None]
    t = np.array([r['t'] for r in d], float); v = np.array([r['v'] for r in d], float)
    return t, v


for name, (t, v) in [('B', load_B(sys.argv[1])), ('A', load_A(sys.argv[2]))]:
    o = np.argsort(t); t = t[o]; v = v[o]
    tg = np.arange(0.5, 40.0, 0.01)
    vg = np.interp(tg, t, v)
    cum = np.concatenate([[0], np.cumsum(0.5 * (vg[1:] + vg[:-1]) * 0.01)])
    at = lambda T: float(np.interp(T, tg, cum))
    print(name, 'trace t range %.2f..%.2f' % (t.min(), t.max()))
    for T in [13.2, 15, 20, 25, 30, 35]:
        print('  integral 0.5->%5.1f s: %7.3f deg ; from 13.2 s: %7.3f' % (T, at(T), at(T) - at(13.2)))
    print('  delta 15->25: %.3f   20->30: %.3f   15->30: %.3f   20->25: %.3f   15->20: %.3f' % (
        at(25) - at(15), at(30) - at(20), at(30) - at(15), at(25) - at(20), at(20) - at(15)))
    print('  mean rate 0.5-13.2 s: %.3f deg/s' % (np.mean(vg[(tg < 13.2)])))
