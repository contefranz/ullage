# Verifier: apply verifier corrections to igm/pft-trajectory.csv in place (reads the pre-verifier backup).
import csv, math, importlib.util, io, contextlib
SP='/tmp/claude-0/-home-user-ullage/1c835ba6-4d0a-5d42-96bb-a9ff7c081ab9/scratchpad'
src=SP+'/igm/pft-trajectory.csv.pre-verifier'; dst=SP+'/igm/pft-trajectory.csv'
spec=importlib.util.spec_from_file_location('c',SP+'/igm/scripts/pftver_check.py')
c=importlib.util.module_from_spec(spec)
import sys; sys.argv=['x',src]
with contextlib.redirect_stdout(io.StringIO()): spec.loader.exec_module(c)
rows=list(csv.reader(open(src,newline=''))); hdr=rows[0]; ix={k:i for i,k in enumerate(hdr)}
def derived(r):
    d=dict(zip(hdr,r)); t,rn,vn,an=c.state(d)
    r0=c.mv(c.M,rn); v0=c.mv(c.M,vn); th=c.w*(t-c.tg)
    re=c.rz(r0,-th); vi=c.rz(v0,-th); ve=[p-q for p,q in zip(vi,c.cr([0,0,c.w],re))]
    R=c.nrm(re); up=[x/R for x in re]; east=[-re[1]/math.hypot(re[0],re[1]), re[0]/math.hypot(re[0],re[1]),0]; north=c.cr(up,east)
    fp=math.degrees(math.asin(c.dot(vi,up)/c.nrm(vi))); hd=math.degrees(math.atan2(c.dot(vi,east),c.dot(vi,north)))%360
    g=c.mtv(c.M,c.grav(r0)); a=[p-q for p,q in zip(an,g)]; m=c.nrm(a); u=[x/m for x in a]
    pad=[(c.a/math.sqrt(1-c.e2*math.sin(c.p0)**2))*k for k in (math.cos(c.p0)*math.cos(c.l0), math.cos(c.p0)*math.sin(c.l0), (1-c.e2)*math.sin(c.p0))]
    YE=c.dot([p-q for p,q in zip(re,pad)],c.Y)/1e3; DYE=c.dot(ve,c.Y)
    return {'fpa_calc_deg':f'{fp:.3f}','head_calc_deg':f'{hd:.3f}','crossrange_ye_km':f'{YE:.2f}','crossrange_dye_mps':f'{DYE:.1f}',
            'a_nongrav_mps2':f'{m:.2f}','chiY_thrust_deg':f'{math.degrees(math.atan2(-u[2],u[0])):.2f}','chiZ_thrust_deg':f'{math.degrees(math.asin(u[1])):.2f}'}
def addnote(r,s):
    n=r[ix['note']]; r[ix['note']]=(n+' | ' if n else '')+'VERIFIER: '+s
for r in rows[1:]:
    t=float(r[0])
    if t==684.0:
        assert r[ix['zs_km']]=='2784.595'
        old={k:r[ix[k]] for k in ('fpa_calc_deg','head_calc_deg','crossrange_ye_km','crossrange_dye_mps','a_nongrav_mps2','chiY_thrust_deg','chiZ_thrust_deg')}
        r[ix['zs_km']]='2784.585'
        new=derived(r); changed=[f'{k} {old[k]}->{new[k]}' for k in new if new[k]!=old[k]]
        for k,v in new.items(): r[ix[k]]=v
        r[ix['grade_printed']]='H'
        r[ix['note']]=('VERIFIER: ZS corrected 2784.595 -> 2784.585 km. The second-decimal glyph on PDF 115 is a damaged 8 (same partial print as 696 s ZS, which reads 2869.275 but is 2868.275); '
                       'Table C-II (PDF 179) prints ZS = 1503.556 n mi = 2784.586 km. With 2784.585 the row fits B-III GC DIST/ALT (-0.2 m/-1.5 m) and the 682/686 kinematics (0.2 m). Not a PFT print error.'
                       +(' Derived columns recomputed: '+'; '.join(changed) if changed else ' Derived columns unchanged at printed precision.'))
        print('684 derived changes:',changed)
    elif t==660.0:
        r[ix['grade_printed']]='H'
        addnote(r,'Table C-III (PDF 190) prints LONG -56.4083 cleanly; upgraded M -> H.')
    elif t==460.62:
        addnote(r,'position AND velocity of the event row match a cubic-Hermite interpolation of the 460.0/462.0 rows at t = 460.601 s (2 m miss; velocity offset = a*(-0.019 s)), i.e. the event state is about 0.019 s earlier than its 460.62 label (inferred). For a 460.62 s state interpolate 460.0/462.0.')
    elif t==709.33:
        addnote(r,'offset from the 708.0 row propagated is -70.0 m radial, +6.3 m along-track, -4.6 m cross-track (velocity -0.23/+0.05/+0.05 m/s in XS/YS/ZS); B-II/C-II both print it.')
    elif t==210.0:
        addnote(r,'2-s rows (PDF 109) put the onset between 204 and 206 s (chiY_thr -69.2 at 204 s, -68.1 at 206, -63.5 at 210, plateau -61.0 to -61.4 at 214-220 s); FER Table 10-4: IGM phase 1 start 204.07 s.')
    elif t==670.0:
        addnote(r,'2-s rows (PDF 114-115): nose-down step of about 2.6 deg in chiY_thr between 666 and 672 s (-110.9 -> -113.4); FER Table 10-4: terminal guidance begins 665.15 s (not chi freeze).')
    elif t==692.0:
        addnote(r,'FER Table 10-4: chi freeze 691.64-699.26 s; the near-constant chiY_thr from 672 s comes from terminal guidance, not from the freeze.')
w=csv.writer(open(dst,'w',newline='')); w.writerows(rows)
print('written',len(rows)-1,'rows')
