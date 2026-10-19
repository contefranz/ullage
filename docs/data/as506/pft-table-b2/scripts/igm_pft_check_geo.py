# Cross-check transcribed PFT Table B-II (PACSS13 nav frame) against Table B-III (geographic polar)
# using the frame definitions of PFT Appendix A and Section 2. Pure computation on the transcribed numbers.
import math
SP='/tmp/claude-0/-home-user-ullage/1c835ba6-4d0a-5d42-96bb-a9ff7c081ab9/scratchpad'
def load(fn,n):
    d={}
    for line in open(SP+'/igm/data/'+fn):
        if line.startswith('#') or not line.strip(): continue
        f=line.split(); d[round(float(f[0]),3)]=[float(x) for x in f[1:n+1]]
    return d
b2=load('pft_b2.txt',9); b3=load('pft_b3.txt',11)
a=6378166.0; finv=298.3; f=1/finv; e2=2*f-f*f          # Fischer 1960 (PFT Sec. 2)
phi0=math.radians(28.608422); lam0=math.radians(-80.604133); h0=59.4
A=math.radians(72.058); w=7.2921158e-5; tgrr=-16.968
def unit(v): n=math.sqrt(sum(x*x for x in v)); return [x/n for x in v]
def cross(p,q): return [p[1]*q[2]-p[2]*q[1], p[2]*q[0]-p[0]*q[2], p[0]*q[1]-p[1]*q[0]]
def dot(p,q): return sum(x*y for x,y in zip(p,q))
U=[math.cos(phi0)*math.cos(lam0), math.cos(phi0)*math.sin(lam0), math.sin(phi0)]
E=[-math.sin(lam0), math.cos(lam0), 0.0]
N=[-math.sin(phi0)*math.cos(lam0), -math.sin(phi0)*math.sin(lam0), math.cos(phi0)]
Xh=U; Zh=[math.sin(A)*e+math.cos(A)*n for e,n in zip(E,N)]; Yh=cross(Zh,Xh)
def nav2ecef0(v): return [v[0]*Xh[i]+v[1]*Yh[i]+v[2]*Zh[i] for i in range(3)]
def rotz(v,th): c,s=math.cos(th),math.sin(th); return [c*v[0]-s*v[1], s*v[0]+c*v[1], v[2]]
def geodetic(r):
    x,y,z=r; p=math.hypot(x,y); lat=math.atan2(z,p*(1-e2))
    for _ in range(10):
        Nn=a/math.sqrt(1-e2*math.sin(lat)**2); h=p/math.cos(lat)-Nn
        lat=math.atan2(z,p*(1-e2*Nn/(Nn+h)))
    return lat,h
def vincenty(lat1,lon1,lat2,lon2):
    b=a*(1-f); L=lon2-lon1; U1=math.atan((1-f)*math.tan(lat1)); U2=math.atan((1-f)*math.tan(lat2)); lam=L
    for _ in range(200):
        sl,cl=math.sin(lam),math.cos(lam)
        ss=math.sqrt((math.cos(U2)*sl)**2+(math.cos(U1)*math.sin(U2)-math.sin(U1)*math.cos(U2)*cl)**2)
        cs=math.sin(U1)*math.sin(U2)+math.cos(U1)*math.cos(U2)*cl; sg=math.atan2(ss,cs)
        sa=math.cos(U1)*math.cos(U2)*sl/ss; c2a=1-sa*sa; c2m=cs-2*math.sin(U1)*math.sin(U2)/c2a
        C=f/16*c2a*(4+f*(4-3*c2a)); lp=lam
        lam=L+(1-C)*f*sa*(sg+C*ss*(c2m+C*cs*(-1+2*c2m*c2m)))
        if abs(lam-lp)<1e-13: break
    u2=c2a*(a*a-b*b)/(b*b); Aa=1+u2/16384*(4096+u2*(-768+u2*(320-175*u2))); Bb=u2/1024*(256+u2*(-128+u2*(74-47*u2)))
    ds=Bb*ss*(c2m+Bb/4*(cs*(-1+2*c2m*c2m)-Bb/6*c2m*(-3+4*ss*ss)*(-3+4*c2m*c2m)))
    return b*Aa*(sg-ds)
wv=[0,0,w]
print('frame check: pad position in nav frame at GRR (expect B-II GRR row 6373.329 17.087 -5.533 km)')
Nn0=a/math.sqrt(1-e2*math.sin(phi0)**2)
r0=[(Nn0+h0)*math.cos(phi0)*math.cos(lam0),(Nn0+h0)*math.cos(phi0)*math.sin(lam0),(Nn0*(1-e2)+h0)*math.sin(phi0)]
print('  computed %.3f %.3f %.3f km' % tuple(dot(r0,ax)/1000 for ax in (Xh,Yh,Zh)))
hdr='t        dGCDIST(m) dLONG(deg) dGCLAT(deg) dVELAZ dVELEL dEFVEL dHEADgc dFPAgc dFPAgd dSFVEL dRANGE(m) dALT(m)'
print(hdr)
worst={}
for t in sorted(b2):
    if t not in b3: print('missing in B-III',t); continue
    XS,YS,ZS,DX,DY,DZ=b2[t][:6]; g=b3[t]
    r=nav2ecef0([XS*1000,YS*1000,ZS*1000]); v=nav2ecef0([DX,DY,DZ])
    th=w*(t-tgrr)
    re=rotz(r,-th); ve=rotz([vi-ci for vi,ci in zip(v,cross(wv,r))],-th); vi=rotz(v,-th)
    R=math.sqrt(dot(re,re)); gclat=math.degrees(math.asin(re[2]/R)); lon=math.degrees(math.atan2(re[1],re[0]))
    lat,h=geodetic(re)
    # local frames
    up_gc=unit(re); up_gd=[math.cos(lat)*math.cos(math.radians(lon)),math.cos(lat)*math.sin(math.radians(lon)),math.sin(lat)]
    def azel(vec,up):
        east=unit(cross([0,0,1],up)); north=cross(up,east)
        el=math.degrees(math.asin(dot(vec,up)/math.sqrt(dot(vec,vec))))
        az=math.degrees(math.atan2(dot(vec,east),dot(vec,north)))%360
        return az,el
    efaz,efel=azel(ve,up_gc)  # PFT VEL-AZ/VEL-EL use the geocentric local horizontal (verified)
    hd_gc,fpa_gc=azel(vi,up_gc); hd_gd,fpa_gd=azel(vi,up_gd)
    latr=math.atan(math.tan(math.asin(re[2]/R))/(1-e2)); rng=vincenty(phi0,lam0,latr,math.radians(lon))  # radial subvehicle point (best match)
    res=[R/1000-g[0], lon-g[1], gclat-g[2], efaz-g[3], efel-g[4], math.sqrt(dot(ve,ve))-g[5], hd_gc-g[6], fpa_gc-g[7], fpa_gd-g[7], math.sqrt(dot(vi,vi))-g[8], rng-g[9], h-g[10]]
    res[0]*=1000
    tol=[3,0.0002,0.0002,0.008,0.008,0.12,0.008,0.008,99,0.12,70,3]
    for i,x in enumerate(res): worst[i]=max(worst.get(i,0),abs(x))
    flag=' <<<' if any(abs(x)>tl for x,tl in zip(res,tol) if tl<99) else ''
    print(f'{t:8.2f} '+' '.join(f'{x:9.4f}' if i in (1,2) else f'{x:8.2f}' for i,x in enumerate(res))+flag)
print('max |resid| per column (GCDIST m, LONG, GCLAT, VELAZ, VELEL, EFVEL, HEADgc, FPAgc, FPAgd, SFVEL, RANGE m, ALT m):'); print(' '.join(f'{worst[i]:.4f}' for i in range(12)))
