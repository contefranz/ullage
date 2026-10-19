# Print Markdown tables from the CSV (for the report)
import csv
SP='/tmp/claude-0/-home-user-ullage/1c835ba6-4d0a-5d42-96bb-a9ff7c081ab9/scratchpad'
rows=list(csv.DictReader(open(SP+'/igm/pft-trajectory.csv')))
print('| t (s) | event | ALT (m) | SF VEL (m/s) | FLT-PATH (deg) | HEAD (deg) | RANGE (m) | GC DIST (km) | GC LAT (deg N) | LONG (deg E) | EF VEL (m/s) | VEL-AZ | VEL-EL |')
print('|---|---|---|---|---|---|---|---|---|---|---|---|---|')
for r in rows:
    print('| '+' | '.join([r['t_s'],r['event'],r['alt_m'],r['sf_vel_mps'],r['flt_path_deg'],r['head_deg'],r['range_m'],r['gc_dist_km'],r['gc_lat_deg_n'],r['long_deg_e'],r['ef_vel_mps'],r['vel_az_deg'],r['vel_el_deg']])+' |')
print()
print('| t (s) | XS (km) | YS (km) | ZS (km) | DXS (m/s) | DYS (m/s) | DZS (m/s) | DDXS | DDYS | DDZS (m/s²) | FPA calc (deg) | HEAD calc (deg) | a_ng (m/s²) | chiY_thr (deg) | chiZ_thr (deg) |')
print('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|')
for r in rows:
    print('| '+' | '.join([r['t_s'],r['xs_km'],r['ys_km'],r['zs_km'],r['dxs_mps'],r['dys_mps'],r['dzs_mps'],r['ddxs_mps2'],r['ddys_mps2'],r['ddzs_mps2'],r['fpa_calc_deg'],r['head_calc_deg'],r['a_nongrav_mps2'],r['chiY_thrust_deg'] or '–',r['chiZ_thrust_deg'] or '–'])+' |')
