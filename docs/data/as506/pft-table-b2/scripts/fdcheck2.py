import sys, json
# usage: fdcheck2.py all_rows.txt out.json
# Rows: t XS YS ZS(km) DXS DYS DZS(m/s) DDXS DDYS DDZS(m/s2) page [flag]
rows = []
for line in open(sys.argv[1]):
    s = line.strip()
    if not s or s.startswith('#'): continue
    f = s.split()
    rows.append(dict(ts=f[0], t=float(f[0]), x=[float(v)*1000 for v in f[1:4]],
                     v=[float(v) for v in f[4:7]], a=[float(v) for v in f[7:10]], page=int(f[10])))
rows.sort(key=lambda r: r['t'])
byt = {round(r['t'], 3): r for r in rows}
EVENTS = {'first motion': 0.300, 'CECO': 135.200, 'OECO': 161.630}
# acceleration is discontinuous just after these (release / thrust decay)
def straddles(t0, t1):
    out = []
    for name, te in EVENTS.items():
        if t0 < te + 1e-9 and t1 > te + 1e-9 and not (abs(t1 - te) < 1e-9):
            # interval (t0, t1] contains the post-event decay when te in [t0, t1)
            out.append(name)
    return out
DX, DV, DA = 0.5, 0.05, 0.005    # half unit of last printed digit (m, m/s, m/s2)
AX = ['X', 'Y', 'Z']
def d3(fm, f0, fp, hm, hp):
    return (-hp/(hm*(hm+hp)))*fm + ((hp-hm)/(hm*hp))*f0 + (hm/(hp*(hm+hp)))*fp
def wsum(hm, hp):
    return abs(hp/(hm*(hm+hp))) + abs((hp-hm)/(hm*hp)) + abs(hm/(hp*(hm+hp)))

res_all = []
for i, r in enumerate(rows):
    t = r['t']; R = dict(t=r['ts'], page=r['page'])
    m = byt.get(round(t-1, 3)); p = byt.get(round(t+1, 3))
    if abs(t - round(t)) < 1e-9 and m and p:
        kind = '1s'
    else:
        m = rows[i-1] if i > 0 else None; p = rows[i+1] if i+1 < len(rows) else None; kind = 'adj'
    if m and p:
        hm, hp = t - m['t'], p['t'] - t
        W = wsum(hm, hp)
        crosses = straddles(m['t'], p['t'])
        vres, ares = [], []
        for k in range(3):
            fd_v = d3(m['x'][k], r['x'][k], p['x'][k], hm, hp)
            fd_a = d3(m['v'][k], r['v'][k], p['v'][k], hm, hp)
            # leading truncation term of the 3-point derivative: (hm*hp/6) f''' ; f''' estimated from printed values
            jerk = d3(m['a'][k], r['a'][k], p['a'][k], hm, hp)           # d a/dt  (= x''')
            app = 2*((p['a'][k]-r['a'][k])/hp - (r['a'][k]-m['a'][k])/hm)/(hm+hp)  # a'' (= v''')
            vres.append(r['v'][k] - (fd_v - hm*hp/6*jerk))
            ares.append(r['a'][k] - (fd_a - hm*hp/6*app))
        vtol = W*DX + DV + 0.02
        atol = W*DV + DA + 0.005
        R.update(stencil=f"{kind} {m['ts']},{p['ts']}", vres=[round(x, 3) for x in vres], ares=[round(x, 3) for x in ares],
                 vtol=round(vtol, 3), atol=round(atol, 3), crosses=crosses)
        def grade(res, tol, unit_marg):
            mx = max(abs(x) for x in res)
            if mx <= tol: return 'pass'
            if mx <= tol + unit_marg: return 'marginal'
            return 'fail'
        R['vgrade'] = grade(vres, vtol, 0.5)   # marginal band: +0.5 m/s
        R['agrade'] = grade(ares, atol, 0.05)  # marginal band: +0.05 m/s2
    # interval checks to previous row (Hermite: dx = h(v0+v1)/2 + h^2(a0-a1)/12 ; dv = h(a0+a1)/2)
    if i > 0:
        q = rows[i-1]; h = t - q['t']
        ix = [(r['x'][k]-q['x'][k]) - (h*(q['v'][k]+r['v'][k])/2 + h*h*(q['a'][k]-r['a'][k])/12) for k in range(3)]
        iv = [(r['v'][k]-q['v'][k]) - h*(q['a'][k]+r['a'][k])/2 for k in range(3)]
        R.update(iprev=q['ts'], ix=[round(x, 2) for x in ix], iv=[round(x, 3) for x in iv],
                 ixtol=round(2*DX + h*DV + 0.02, 2), ivtol=round(2*DV + h*DA + 0.01, 3),
                 icross=straddles(q['t'], t))
    res_all.append(R)
json.dump(res_all, open(sys.argv[2], 'w'), indent=1)
for R in res_all:
    if 'vres' not in R: continue
    tag = ''
    if R['vgrade'] != 'pass' or R['agrade'] != 'pass': tag = f" <-- v:{R['vgrade']} a:{R['agrade']}"
    if R['crosses']: tag += f" [stencil crosses {','.join(R['crosses'])}]"
    print(f"{R['t']:>8} {R['stencil']:>18} vres={R['vres']} (tol {R['vtol']}) ares={R['ares']} (tol {R['atol']}){tag}")
