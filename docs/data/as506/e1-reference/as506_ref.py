# E1 reference data for AS-506's S-IC (python3 -I; numpy).
# 1. chi_thr from PFT Table B-II (all 1-s rows): B-II acceleration minus J2 gravity, in PACSS 13
#    (method of next/residuals/scripts/sic_thrustdir.py: geodetic 28.608422 N, -80.604133 E, az 72.058;
#    mu 3.986032e14, J2 1.0823e-3, Re 6378165).
# 2. FER Fig 11-1 panel 2 error: final adjudicated 5-s samples and a 5-s boxcar of digitiser A's dense trace.
# 3. Reconstructed command chi_cmd = chi_thr - error, smoothed over about 5 s, and a least-squares fit of
#    GE504's four quartic segments (35/80/115 s from T1, arrest 159.37 s from T1) with C0 joins.
# Writes out/as506_ref.json and out/fit.json.
import json, math, sys
import numpy as np

SP = '/tmp/claude-0/-home-user-ullage/1c835ba6-4d0a-5d42-96bb-a9ff7c081ab9/scratchpad'
OUT = SP + '/diag/e1/out'
phi0 = math.radians(28.608422); lam0 = math.radians(-80.604133); A = math.radians(72.058)
mu = 3.986032e14; J2 = 1.0823e-3; Re = 6378165.0
U = np.array([math.cos(phi0)*math.cos(lam0), math.cos(phi0)*math.sin(lam0), math.sin(phi0)])
E = np.array([-math.sin(lam0), math.cos(lam0), 0.0])
N = np.array([-math.sin(phi0)*math.cos(lam0), -math.sin(phi0)*math.sin(lam0), math.cos(phi0)])
Xh = U; Zh = math.sin(A)*E + math.cos(A)*N; Yh = np.cross(Zh, Xh)
M = np.vstack([Xh, Yh, Zh])            # rows: nav axes in Earth-fixed-at-reference coordinates
def grav_nav(rn):
    r = M.T @ rn; x, y, z = r; R = np.linalg.norm(r); k = 1.5*J2*(Re/R)**2; s = 5*z*z/(R*R); c = -mu/R**3
    g = np.array([c*x*(1 + k*(1 - s)), c*y*(1 + k*(1 - s)), c*z*(1 + k*(3 - s))])
    return M @ g

rows = []
for line in open(SP + '/data2/pft-b2/pft_b2_sic_all_rows.txt'):
    if line.startswith('#') or not line.strip(): continue
    f = line.split(); t = float(f[0]); vals = [float(x) for x in f[1:10]]
    rows.append((t, np.array(vals[0:3])*1000, np.array(vals[3:6]), np.array(vals[6:9])))
ref = {}
for t, r, v, a in rows:
    g = grav_nav(r); ang = a - g; m = np.linalg.norm(ang); u = ang/m
    R = np.linalg.norm(r); V = np.linalg.norm(v)
    ref[t] = dict(t=t, r=R, v=V, fpa=math.degrees(math.asin(np.dot(r, v)/(R*V))),
                  chiY=math.degrees(math.atan2(-u[2], u[0])), chiZ=math.degrees(math.asin(u[1])), ang=m,
                  pos=list(r), vel=list(v))
ints = [t for t in sorted(ref) if abs(t - round(t)) < 1e-9]

# 5-s centred boxcar of chi_thr over the integer rows (+-2 s).
def box(t, key, half=2):
    # Not past 161 s: the 162 s row is after OECO (161.63 s), the thrust decaying.
    vals = [ref[float(s)][key] for s in range(int(t) - half, int(t) + half + 1) if float(s) in ref and s <= 161]
    return sum(vals)/len(vals)
chi_s = {t: box(t, 'chiY') for t in ints if 2 <= t <= 160}
chiZ_s = {t: box(t, 'chiZ') for t in ints if 2 <= t <= 160}

# FER Fig 11-1: final 5-s samples, and digitiser A's dense panel-2 trace.
fig = json.load(open(SP + '/data2/fig111-final.json'))['samples']
err5 = {s['t']: s['error_deg'] for s in fig}
att5 = {s['t']: s['attitude_deg'] for s in fig}
eng5 = {s['t']: s['engine_deg'] for s in fig}
# Dense panel-2 traces of both digitisers (A: dp_p2.json, B: work/p2_dp.json); their 5-s boxcars agree
# within 0.03 deg, and their points match the adjudicated 5-s samples. (A's tr_p2.json follows the 0.8 deg
# gridline at 95-120 s and is not used.)
trA = [(p['t'], p['v']) for p in json.load(open(SP + '/data2/fig111-A/dp_p2.json')) if 't' in p]
trB = [(p[5], p[6]) for p in json.load(open(SP + '/data2/fig111-B/work/p2_dp.json'))]
trs = [(np.array([a for a, _ in tr]), np.array([b for _, b in tr])) for tr in (trA, trB)]
trt, trv = trs[1]
def err_box(t, half=2.5):
    vals = []
    for tt, vv in trs:
        m = (tt >= t - half) & (tt <= t + half)
        if m.sum() > 5: vals.append(float(vv[m].mean()))
    return sum(vals)/len(vals) if vals else float('nan')
def err_lin(t):
    ks = sorted(err5)
    if t <= ks[0]: return err5[ks[0]]
    if t >= ks[-1]: return err5[ks[-1]]
    for a, b in zip(ks, ks[1:]):
        if a <= t <= b: return err5[a] + (err5[b] - err5[a])*(t - a)/(b - a)
def err_dense_at(t, half=0.15):
    m = (trt >= t - half) & (trt <= t + half)
    return float(trv[m].mean()) if m.sum() else float('nan')

# Reconstructed command at integer range seconds 14..160.
cmd = {}
for t in ints:
    if 14 <= t <= 160:
        eb = err_box(t)
        e = eb if not math.isnan(eb) else err_lin(t)
        cmd[t] = dict(t=t, chi_thr=ref[t]['chiY'], chi_thr_s=chi_s[t], err_box=eb, err_lin=err_lin(t),
                      cmd=chi_s[t] - e, cmd_pointlin=ref[t]['chiY'] - err_lin(t))

# Least-squares fit of 4 quartic segments in t_T1 = range - 0.63, C0 joins at 35, 80, 115 s (KKT).
T1 = 0.63; bnd = [35.0, 80.0, 115.0]; arrest = 160.0 - T1
def seg(tt): return sum(1 for b in bnd if tt >= b)
def fit(points, c1=False, start=None):
    nseg, nc = 4, 5
    Arows, b = [], []
    for tt, y, w in points:
        k = seg(tt); row = np.zeros(nseg*nc); row[k*nc:(k+1)*nc] = [w*tt**n for n in range(nc)]
        Arows.append(row); b.append(w*y)
    Am = np.array(Arows); bm = np.array(b)
    C, d = [], []
    for j, tb in enumerate(bnd):
        row = np.zeros(nseg*nc); row[j*nc:(j+1)*nc] = [tb**n for n in range(nc)]
        row[(j+1)*nc:(j+2)*nc] = [-tb**n for n in range(nc)]; C.append(row); d.append(0.0)
        if c1:
            row = np.zeros(nseg*nc); row[j*nc:(j+1)*nc] = [n*tb**(n-1) if n else 0 for n in range(nc)]
            row[(j+1)*nc:(j+2)*nc] = [-(n*tb**(n-1)) if n else 0 for n in range(nc)]; C.append(row); d.append(0.0)
    if start is not None:
        ts, ys = start; row = np.zeros(nseg*nc); row[0:nc] = [ts**n for n in range(nc)]; C.append(row); d.append(ys)
    Cm = np.array(C); dm = np.array(d)
    # Scale columns for conditioning.
    scale = np.array([1/ (150.0**n) for n in range(nc)]*nseg)
    As = Am*scale; Cs = Cm*scale
    K = np.block([[2*As.T@As, Cs.T], [Cs, np.zeros((len(dm), len(dm)))]])
    rhs = np.concatenate([2*As.T@bm, dm])
    sol = np.linalg.solve(K, rhs)[:nseg*nc]*scale
    return [list(sol[k*nc:(k+1)*nc]) for k in range(nseg)]
def evalp(co, tt):
    tt = min(tt, arrest); k = seg(tt); return sum(c*tt**n for n, c in enumerate(co[k]))
def deriv(co, k, tt): return sum(n*c*tt**(n-1) for n, c in enumerate(co[k]) if n)

pts = [(t - T1, cmd[t]['cmd'], 1.0) for t in sorted(cmd)]
results = {}
for name, kw in [('C0', {}), ('C0+start0', dict(start=(12.6, 0.0))), ('C1', dict(c1=True)),
                 ('C1+start0', dict(c1=True, start=(12.6, 0.0)))]:
    co = fit(pts, **kw)
    res = np.array([evalp(co, tt) - y for tt, y, _ in pts])
    segres = {}
    for k in range(4):
        m = np.array([seg(tt) == k for tt, _, _ in pts]); segres[k] = (float(np.sqrt((res[m]**2).mean())), float(np.abs(res[m]).max()))
    joins = [(tb, sum(c*tb**n for n, c in enumerate(co[j])) - sum(c*tb**n for n, c in enumerate(co[j+1])),
              deriv(co, j, tb) - deriv(co, j+1, tb)) for j, tb in enumerate(bnd)]
    results[name] = dict(coeffs=co, rms=float(np.sqrt((res**2).mean())), max=float(np.abs(res).max()),
                         seg=segres, joins=joins, start=evalp(co, 12.6),
                         maxrate=max(abs(sum(n*c*tt**(n-1) for n, c in enumerate(co[seg(tt)]) if n))
                                     for tt in np.arange(12.6, arrest, 0.1)))
# SA-504 for reference (joins).
S504 = [[3.19840, -0.544236, 0.0351605, -0.00116379, 0.0000113886],
        [-10.9607, 0.946620, -0.0294206, 0.000207717, -0.000000439036],
        [78.7826, -2.83749, 0.0289710, -0.000178363, 0.000000463029],
        [69.9191, -2.007490, 0.0105367, -0.0000233163, 0.0000000136702]]
s504joins = [(tb, sum(c*tb**n for n, c in enumerate(S504[j])) - sum(c*tb**n for n, c in enumerate(S504[j+1])),
              deriv(S504, j, tb) - deriv(S504, j+1, tb)) for j, tb in enumerate(bnd)]

if __name__ == '__main__':
    print('fits (deg): rms, max |res|, per segment (rms, max), joins (value, slope jump), value at T1+12.6, max |rate|')
    for name, r in results.items():
        print(f"{name:10s} rms {r['rms']:.3f} max {r['max']:.3f} seg " +
              ' '.join(f"({a:.3f},{b:.3f})" for a, b in r['seg'].values()) +
              ' joins ' + ' '.join(f"{tb:.0f}:{dv:+.4f}/{ds:+.4f}" for tb, dv, ds in r['joins']) +
              f" start {r['start']:+.3f} maxrate {r['maxrate']:.3f}")
    print('SA-504 joins', ' '.join(f"{tb:.0f}:{dv:+.4f}/{ds:+.4f}" for tb, dv, ds in s504joins))
    print('\n  t  chi_thr  chi_thr_s5  err_final  err_box5  err_dense  cmd(c)  cmd_pointlin  fitC0  fitC1  SA504  x1.025')
    def p504(tt):
        tt = min(tt, arrest); return sum(c*tt**n for n, c in enumerate(S504[seg(tt)]))
    for t in range(15, 161, 5):
        c = cmd[float(t)]
        print(f"{t:4d} {c['chi_thr']:8.2f} {c['chi_thr_s']:8.2f} {err5.get(t, float('nan')):8.3f} {c['err_box']:8.3f}"
              f" {err_dense_at(t):8.3f} {c['cmd']:8.2f} {c['cmd_pointlin']:8.2f} {evalp(results['C0']['coeffs'], t - T1):8.2f}"
              f" {evalp(results['C1']['coeffs'], t - T1):8.2f} {p504(t - T1):8.2f} {1.025*p504(t - T1):8.2f}")
    co = results['C0+start0']['coeffs']
    print('\nSwift coefficients (C0+start0):')
    print('[' + ',\n '.join('[' + ', '.join(repr(float(c)) for c in seg) + ']' for seg in co) + ']')
    json.dump(dict(ref=[ref[t] for t in sorted(ref)], cmd=[cmd[t] for t in sorted(cmd)],
                   err5=err5, att5=att5, eng5=eng5,
                   fits={k: dict(coeffs=v['coeffs'], rms=v['rms'], max=v['max'], joins=v['joins'], start=v['start'])
                         for k, v in results.items()}),
              open(OUT + '/as506_ref.json', 'w'), indent=1)
