import sys, json
# usage: final.py all_rows.txt existing.txt out_table.txt out.json
allf, exf, outt, outj = sys.argv[1:5]
rows = []
for s in open(allf):
    s = s.strip()
    if not s or s.startswith('#'): continue
    f = s.split()
    rows.append(dict(ts=f[0], t=float(f[0]), raw=f[1:10], x=[float(v)*1000 for v in f[1:4]],
                     v=[float(v) for v in f[4:7]], a=[float(v) for v in f[7:10]], page=int(f[10]),
                     flag=' '.join(f[11:])))
rows.sort(key=lambda r: r['t'])
byt = {round(r['t'], 3): r for r in rows}
idx = {round(r['t'], 3): i for i, r in enumerate(rows)}
DX, DV, DA = 0.5, 0.05, 0.005
EV = {0.3: 'first motion', 135.2: 'CECO', 161.63: 'OECO'}

def lag_w(ts, te):
    # weights of the derivative at te of the quadratic through points ts
    t0, t1, t2 = ts
    w0 = ((te-t1)+(te-t2))/((t0-t1)*(t0-t2))
    w1 = ((te-t0)+(te-t2))/((t1-t0)*(t1-t2))
    w2 = ((te-t0)+(te-t1))/((t2-t0)*(t2-t1))
    return [w0, w1, w2]

def stencil_check(times, te, correct=True):
    rs = [byt[round(t, 3)] for t in times]
    w = lag_w(times, te)
    W = sum(abs(x) for x in w)
    r = byt[round(te, 3)]
    # truncation of a 3-point derivative: f'''/6 * prod(te - ti) * sum(1/(te-ti)) for ti != te ... use generic estimate
    # estimate f''' for x (=da/dt) and for v (=a'') from the printed accelerations on the same stencil
    wa = lag_w(times, te)
    jerk = sum(wa[j]*rs[j]['a'][k] for j in range(3) for k in [0])  # placeholder overwritten below
    vres, ares = [], []
    for k in range(3):
        fd_v = sum(w[j]*rs[j]['x'][k] for j in range(3))
        fd_a = sum(w[j]*rs[j]['v'][k] for j in range(3))
        jerk = sum(w[j]*rs[j]['a'][k] for j in range(3))
        # second derivative of a on the stencil (constant for a quadratic)
        t0, t1, t2 = times
        app = 2*((rs[2]['a'][k]-rs[1]['a'][k])/(t2-t1) - (rs[1]['a'][k]-rs[0]['a'][k])/(t1-t0))/(t2-t0)
        # error term of derivative of quadratic interpolant at te: f'''/6 * d/dt[(t-t0)(t-t1)(t-t2)] at te
        dpsi = (te-t1)*(te-t2) + (te-t0)*(te-t2) + (te-t0)*(te-t1)
        cv = jerk/6*dpsi if correct else 0.0
        ca = app/6*dpsi if correct else 0.0
        vres.append(r['v'][k] - (fd_v - cv))
        ares.append(r['a'][k] - (fd_a - ca))
    vtol = W*DX + DV + 0.02
    atol = W*DV + DA + 0.005
    return [round(x, 3) for x in vres], [round(x, 3) for x in ares], round(vtol, 3), round(atol, 3)

def grade(res, tol, marg):
    m = max(abs(x) for x in res)
    return 'pass' if m <= tol else ('marginal' if m <= tol + marg else 'fail')

def interval(t0, t1):
    q, r = byt[round(t0, 3)], byt[round(t1, 3)]
    h = t1 - t0
    ix = [(r['x'][k]-q['x'][k]) - (h*(q['v'][k]+r['v'][k])/2 + h*h*(q['a'][k]-r['a'][k])/12) for k in range(3)]
    iv = [(r['v'][k]-q['v'][k]) - h*(q['a'][k]+r['a'][k])/2 for k in range(3)]
    ixt = 2*DX + h*DV + 0.02
    ivt = 2*DV + h*DA + 0.01
    return [round(x, 2) for x in ix], [round(x, 3) for x in iv], round(ixt, 2), round(ivt, 3)

targets = [0.3, 0.6, 1.0] + [float(t) for t in range(10, 161, 5)] + [135.2, 161.0]
targets = sorted(set(round(t, 3) for t in targets))
ALT = {  # event-aware alternative stencils (do not cross the acceleration discontinuity)
    1.0: [((0.6, 1.0, 2.0), 'adjacent post-release 0.600,1.0,2.0 (no truncation correction)', False), ((1.0, 2.0, 3.0), 'forward 1,2,3', True)],
    135.0: [((133.0, 134.0, 135.0), 'backward 133,134,135', True)],
    135.2: [((134.0, 135.0, 135.2), 'backward 134,135,135.200 (endpoint)', True)],
    161.0: [((159.0, 160.0, 161.0), 'backward 159,160,161', True), ((160.0, 161.0, 161.63), 'pre-OECO 160,161,161.630', True)],
}
out_rows, report = [], []
for t in targets:
    r = byt[t]; i = idx[t]
    m1, p1 = byt.get(round(t-1, 3)), byt.get(round(t+1, 3))
    if abs(t-round(t)) < 1e-9 and m1 and p1:
        st = (t-1, t, t+1); sname = f"1-s central {rows[idx[round(t-1,3)]]['ts']}/{rows[idx[round(t+1,3)]]['ts']}"
    else:
        st = (rows[i-1]['t'], t, rows[i+1]['t']); sname = f"adjacent printed rows {rows[i-1]['ts']}/{rows[i+1]['ts']} (non-uniform)"
    crosses = [n for te, n in EV.items() if st[0] < te + 1e-9 and st[2] > te + 1e-9 and not abs(st[2]-te) < 1e-9 and not (abs(t-te) < 1e-9 and n == 'first motion' and False)]
    vres, ares, vt, at = stencil_check(st, t, correct=not crosses)
    vg, ag = grade(vres, vt, 0.5), grade(ares, at, 0.05)
    parts = [f"{sname}: v-res(X,Y,Z)={vres} m/s tol {vt} -> {vg.upper()}; a-res={ares} m/s2 tol {at} -> {ag.upper()}"]
    if crosses:
        parts.append(f"[stencil straddles {', '.join(crosses)}: acceleration discontinuity, central difference not valid there]")
    alts = []
    for ts, nm, cor in ALT.get(t, []):
        v2, a2, vt2, at2 = stencil_check(ts, t, correct=cor)
        g1, g2 = grade(v2, vt2, 0.5), grade(a2, at2, 0.05)
        alts.append(dict(stencil=nm, vres=v2, vtol=vt2, vgrade=g1, ares=a2, atol=at2, agrade=g2))
        parts.append(f"alt {nm}: v-res={v2} tol {vt2} -> {g1.upper()}; a-res={a2} tol {at2} -> {g2.upper()}")
    ints = []
    for (a_, b_) in [(rows[i-1]['t'], t), (t, rows[i+1]['t'])] if 0 < i < len(rows)-1 else []:
        ix, iv, ixt, ivt = interval(a_, b_)
        cr = [n for te, n in EV.items() if a_ < te + 1e-9 and b_ > te + 1e-9 and not abs(b_-te) < 1e-9]
        gi = 'pass' if max(map(abs, ix)) <= ixt else ('marginal' if max(map(abs, ix)) <= ixt + 1.0 else 'fail')
        gv = 'pass' if max(map(abs, iv)) <= ivt else ('marginal' if max(map(abs, iv)) <= ivt + 0.1 else 'fail')
        ints.append(dict(interval=f"{byt[round(a_,3)]['ts']}->{byt[round(b_,3)]['ts']}", dx_res=ix, dx_tol=ixt, dx_grade=gi, dv_res=iv, dv_tol=ivt, dv_grade=gv, crosses=cr))
        parts.append(f"interval {byt[round(a_,3)]['ts']}->{byt[round(b_,3)]['ts']}: dx-res={ix} m tol {ixt} {gi.upper()}, dv-res={iv} m/s tol {ivt} {gv.upper()}" + (f" [contains {','.join(cr)} transient]" if cr else ''))
    report.append(dict(t=r['ts'], stencil=sname, vres=vres, vtol=vt, vgrade=vg, ares=ares, atol=at, agrade=ag, crosses=crosses, alternatives=alts, intervals=ints))
    out_rows.append((r, ' | '.join(parts)))

# existing file comparison
ex = []
for s in open(exf):
    s = s.strip()
    if not s or s.startswith('#'): continue
    ex.append(s.split())
cols = ['XS', 'YS', 'ZS', 'DXS', 'DYS', 'DZS', 'DDXS', 'DDYS', 'DDZS']
dis = []
for f in ex:
    r = byt[round(float(f[0]), 3)]
    for k, c in enumerate(cols):
        if float(f[1+k]) != float(r['raw'][k]):
            dis.append(f"t={f[0]} {c}: existing {f[1+k]} vs re-read {r['raw'][k]}")
print('DISAGREEMENTS:', dis)
json.dump(dict(report=report, disagreements=dis), open(outj + '.checks.json', 'w'), indent=1)
json.dump([dict(t=r['t'], ts=r['ts'], raw=r['raw'], page=r['page'], check=c) for r, c in out_rows], open(outj + '.rows.json', 'w'), indent=1)
for r, c in out_rows:
    print(r['ts'], '::', c)
