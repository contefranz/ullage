import sys, json
# usage: fdcheck.py all_rows.txt [out.json]
rows = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line or line.startswith('#'): continue
    f = line.split()
    rows.append(dict(ts=f[0], t=float(f[0]), x=[float(v) for v in f[1:4]],
                     v=[float(v) for v in f[4:7]], a=[float(v) for v in f[7:10]], page=int(f[10])))
rows.sort(key=lambda r: r['t'])
byt = {round(r['t'], 3): r for r in rows}
VT, AT, IX, IV = 0.65, 0.06, 1.2, 0.08   # tolerances: m/s, m/s^2, m, m/s

def deriv(fm, f0, fp, hm, hp):
    # 3-point derivative at the middle point, unequal spacing
    return (-hp/(hm*(hm+hp)))*fm + ((hp-hm)/(hm*hp))*f0 + (hm/(hp*(hm+hp)))*fp

out = []
for i, r in enumerate(rows):
    t = r['t']
    res = dict(t=r['ts'])
    # neighbours: 1-s grid when available, else nearest printed rows
    m = byt.get(round(t-1, 3)); p = byt.get(round(t+1, 3))
    kind = '1s'
    if m is None or p is None or abs(t-round(t)) > 1e-9:
        m = rows[i-1] if i > 0 else None
        p = rows[i+1] if i+1 < len(rows) else None
        kind = 'adjacent'
    if m is not None and p is not None:
        hm, hp = t-m['t'], p['t']-t
        vfd = [1000*deriv(m['x'][k], r['x'][k], p['x'][k], hm, hp) for k in range(3)]
        afd = [deriv(m['v'][k], r['v'][k], p['v'][k], hm, hp) for k in range(3)]
        res['nb'] = f"{kind}:{m['ts']},{p['ts']}"
        res['dv'] = [round(r['v'][k]-vfd[k], 3) for k in range(3)]
        res['da'] = [round(r['a'][k]-afd[k], 3) for k in range(3)]
        # tolerance scales with spacing for non-1s neighbours
        vt = VT if kind == '1s' else 1.0/(hm+hp) + 0.15
        at = AT if kind == '1s' else 0.1/(hm+hp) + 0.01
        res['v_ok'] = all(abs(d) <= vt for d in res['dv'])
        res['a_ok'] = all(abs(d) <= at for d in res['da'])
        res['vt'], res['at'] = round(vt, 3), round(at, 3)
    # interval (Hermite) checks to the previous printed row
    if i > 0:
        q = rows[i-1]; h = t - q['t']
        dx = [1000*(r['x'][k]-q['x'][k]) - (h*(q['v'][k]+r['v'][k])/2 + h*h*(q['a'][k]-r['a'][k])/12) for k in range(3)]
        dv = [(r['v'][k]-q['v'][k]) - h*(q['a'][k]+r['a'][k])/2 for k in range(3)]
        res['int_prev'] = q['ts']
        res['ix'] = [round(d, 2) for d in dx]
        res['iv'] = [round(d, 3) for d in dv]
    out.append(res)

for res in out:
    flag = ''
    if 'v_ok' in res and not res['v_ok']: flag += ' VFAIL'
    if 'a_ok' in res and not res['a_ok']: flag += ' AFAIL'
    if 'ix' in res and any(abs(d) > IX for d in res['ix']): flag += ' IXFLAG'
    if 'iv' in res and any(abs(d) > IV for d in res['iv']): flag += ' IVFLAG'
    print(f"{res['t']:>8} {res.get('nb',''):>22} dv={res.get('dv')} da={res.get('da')} ix={res.get('ix')} iv={res.get('iv')}{flag}")
if len(sys.argv) > 2:
    json.dump(out, open(sys.argv[2], 'w'), indent=1)
