#!/usr/bin/env python3
"""Turn pixel positions on a photograph of the Saturn V or the CSM into
vehicle station and azimuth, from a few reference points.

Usage:
    python3 -I tools/digitise_photo.py docs/data/markings/digitised/S68-55424.json
    python3 -I tools/digitise_photo.py --selftest

The input is a registration file (JSON, format below) that records, in the
pixel coordinates of one named copy of the photo (x right, y down), the
reference points and the points to measure. The tool fits a pinhole camera
to the references, then intersects the ray through each point with the
vehicle's surface (a solid of revolution given by "profile").

The camera has seven parameters: its distance from the vehicle's axis, its
height (as a station), the azimuth it views from, the pan, tilt and roll of
its optical axis, and the focal length in pixels; the principal point is the
middle of the image. The references constrain them:
  - "limbs": the left and right silhouette edges at a few heights, each
    against the cylinder of the profile's radius there (cylindrical parts
    only: a cone's silhouette is not a generator);
  - "stations": points on a joint or edge of known station, anywhere along
    its visible arc (with "az" as well, a point of known station and
    azimuth);
  - "azimuths": points on a line of known azimuth, such as a stripe boundary
    on a Position line (with "sta" as well, a point known in both).
A camera whose distance the photo cannot show (a long lens far away) is held
near "distance_m" (default 300 m), which then hardly matters; "fix_distance"
holds it there. The residuals of the references, in pixels and as station
and azimuth, are printed: they grade the registration.

Conventions (docs/data/markings/README.md): stations in inches, Saturn V
vehicle stations ("STA") or Apollo spacecraft stations ("Xa", STA = Xa +
2756.56); azimuth in degrees from Position I towards Position II,
anticlockwise seen from the nose, so Position II is 90, III 180 and IV 270.
Seen from outside with the nose up, azimuth grows to the right.

Registration file:
    {"photo": "S68-55424", "vehicle": "AS-503", "copy": "...", "image": [w, h],
     "frame": "STA", "profile": [[sta, radius_in], ...],
     "distance_m": 400, "fix_distance": false,
     "limbs": [{"sta": 1300, "left": [x, y], "right": [x, y]}, ...],
     "stations": [{"sta": 1760, "at": [x, y], "what": "..."}, ...],
     "azimuths": [{"az": 180, "at": [x, y], "what": "..."}, ...],
     "points": [{"name": "...", "at": [x, y], "what": "..."}, ...]}

The spreads printed with each point are the change that moving the point by
--sigma pixels (default 1) in any direction makes. Only the standard
library is needed.
"""
import argparse
import json
import math
import sys

INCH = 0.0254


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def dot3(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def norm3(a):
    n = math.sqrt(dot3(a, a))
    return (a[0] / n, a[1] / n, a[2] / n)


def rotate(v, axis, ang):
    """Rodrigues' rotation of v about the unit axis."""
    c, s = math.cos(ang), math.sin(ang)
    k = cross(axis, v)
    d = dot3(axis, v) * (1 - c)
    return tuple(v[i] * c + k[i] * s + axis[i] * d for i in range(3))


def solve(a, b):
    """Gaussian elimination with partial pivoting for a small square system."""
    n = len(b)
    a = [row[:] + [b[i]] for i, row in enumerate(a)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(a[r][c]))
        a[c], a[p] = a[p], a[c]
        for r in range(n):
            if r != c:
                f = a[r][c] / a[c][c]
                a[r] = [x - f * y for x, y in zip(a[r], a[c])]
    return [a[i][n] / a[i][i] for i in range(n)]


class Vehicle:
    """A solid of revolution: radius (in) piecewise linear in station (in)."""

    def __init__(self, profile):
        self.p = [(float(s), float(r)) for s, r in profile]

    def radius(self, sta):
        p = self.p
        if sta <= p[0][0]:
            return p[0][1]
        for (s0, r0), (s1, r1) in zip(p, p[1:]):
            if s0 <= sta <= s1:
                return r0 if s1 == s0 else r0 + (r1 - r0) * (sta - s0) / (s1 - s0)
        return p[-1][1]

    def hit(self, c, d):
        """Nearest intersection of the ray c + l d (l > 0) with the surface."""
        best = None
        for (s0, r0), (s1, r1) in zip(self.p, self.p[1:]):
            if s1 <= s0:
                continue
            k = (r1 - r0) / (s1 - s0)
            # x^2 + y^2 = (r0 + k (z - s0))^2, with z = c_z + l d_z
            e0 = r0 + k * (c[2] - s0)
            a = d[0] ** 2 + d[1] ** 2 - (k * d[2]) ** 2
            b = 2 * (c[0] * d[0] + c[1] * d[1] - e0 * k * d[2])
            cc = c[0] ** 2 + c[1] ** 2 - e0 ** 2
            if abs(a) < 1e-12:
                roots = [-cc / b] if b else []
            else:
                disc = b * b - 4 * a * cc
                if disc < 0:
                    continue
                q = math.sqrt(disc)
                roots = [(-b - q) / (2 * a), (-b + q) / (2 * a)]
            for l in roots:
                z = c[2] + l * d[2]
                if l > 0 and s0 - 1e-6 <= z <= s1 + 1e-6 and r0 + k * (z - s0) >= 0:
                    if best is None or l < best:
                        best = l
        if best is None:
            return None
        x, y, z = (c[i] + best * d[i] for i in range(3))
        return z, math.degrees(math.atan2(y, x)) % 360


class Camera:
    """Parameters q = [ln D, H, az_c, L, pan, roll, ln k]: the camera's
    distance D (in) from the vehicle's axis, its height H (station, in), the
    azimuth it views from (rad), the station L where its optical axis meets
    the vehicle's (before the pan), the pan and roll of the optical axis
    (rad), and the image scale k = f / D (px per inch at the axis). This
    form keeps the parameters apart for a long lens far away, where D and H
    are barely seen. Principal point (cx, cy)."""

    def __init__(self, q, cx, cy):
        self.q, self.cx, self.cy = list(q), cx, cy
        lnd, h, azc, look, pan, roll, lnk = q
        d = math.exp(lnd)
        self.f = math.exp(lnk) * d
        self.tilt = math.atan2(look - h, d)
        self.c = (d * math.cos(azc), d * math.sin(azc), h)
        z = (0.0, 0.0, 1.0)
        fwd = rotate((-math.cos(azc), -math.sin(azc), 0.0), z, pan)
        right = norm3(cross(fwd, z))
        fwd = rotate(fwd, right, self.tilt)
        up = cross(right, fwd)
        right = rotate(right, fwd, roll)
        up = rotate(up, fwd, roll)
        self.fwd, self.right, self.up = fwd, right, up

    def project(self, p):
        v = (p[0] - self.c[0], p[1] - self.c[1], p[2] - self.c[2])
        z = dot3(v, self.fwd)
        if z <= 0:
            return None
        return (self.cx + self.f * dot3(v, self.right) / z, self.cy - self.f * dot3(v, self.up) / z)

    def ray(self, px):
        u, v = (px[0] - self.cx) / self.f, -(px[1] - self.cy) / self.f
        return norm3(tuple(self.fwd[i] + u * self.right[i] + v * self.up[i] for i in range(3)))


def surface_point(sta, az, r):
    a = math.radians(az)
    return (r * math.cos(a), r * math.sin(a), sta)


def line_distance(p, a, b):
    """Signed distance (px) from p to the line through a and b."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    n = math.hypot(dx, dy)
    if n == 0:
        return 1e3
    return ((p[0] - a[0]) * dy - (p[1] - a[1]) * dx) / n


class Registration:
    def __init__(self, reg):
        self.reg = reg
        self.veh = Vehicle(reg["profile"])
        w, h = reg.get("image", (None, None))
        pts = [l["left"] for l in reg["limbs"]] + [l["right"] for l in reg["limbs"]]
        self.cx = w / 2 if w else sum(p[0] for p in pts) / len(pts)
        self.cy = h / 2 if h else sum(p[1] for p in pts) / len(pts)
        self.d0 = (reg.get("distance_m") or 300.0) / INCH
        self.prior = 1e4 if reg.get("fix_distance") else 0.2
        self.cam = Camera(self.initial(), self.cx, self.cy)
        self.fit()

    # A first guess from the orthographic view: axis from the limbs, scale
    # from their spacing, stations along the axis, azimuth from the asin.
    def initial(self):
        reg = self.reg
        mids = [((l["left"][0] + l["right"][0]) / 2, (l["left"][1] + l["right"][1]) / 2) for l in reg["limbs"]]
        widths = [math.hypot(l["right"][0] - l["left"][0], l["right"][1] - l["left"][1]) / 2 for l in reg["limbs"]]
        # The axis: the principal direction of the limb midpoints, pointing
        # towards the reference of higher station.
        mx = sum(p[0] for p in mids) / len(mids)
        my = sum(p[1] for p in mids) / len(mids)
        sxx = sum((p[0] - mx) ** 2 for p in mids)
        syy = sum((p[1] - my) ** 2 for p in mids)
        sxy = sum((p[0] - mx) * (p[1] - my) for p in mids)
        ang = 0.5 * math.atan2(2 * sxy, sxx - syy)
        a = (math.cos(ang), math.sin(ang))
        st = sorted(reg["stations"], key=lambda s: s["sta"])
        lo, hi = st[0], st[-1]

        def along(p):
            return (p[0] - mx) * a[0] + (p[1] - my) * a[1]

        if along(hi["at"]) < along(lo["at"]):
            a = (-a[0], -a[1])
        k = (along(hi["at"]) - along(lo["at"])) / (hi["sta"] - lo["sta"])   # px per inch along the axis
        roll = math.atan2(a[0], -a[1])                   # 0 when the nose points up the image
        sta_c = lo["sta"] + (along((self.cx, self.cy)) - along(lo["at"])) / k
        # offset of the axis from the image centre, across it
        across = (mx - self.cx) * (-a[1]) + (my - self.cy) * a[0]
        pan = -math.atan2(across, k * self.d0)
        az0 = 0.0
        refs = reg.get("azimuths", [])
        if refs:
            g = sum(w / self.veh.radius(l["sta"]) for w, l in zip(widths, reg["limbs"])) / len(widths)
            sx = sy = 0.0
            for r in refs:
                d = (r["at"][0] - mx) * (-a[1]) + (r["at"][1] - my) * a[0]
                th = math.asin(max(-1.0, min(1.0, d / (g * self.veh.radius(r.get("sta", sta_c))))))
                a0 = math.radians(r["az"]) - th
                sx += math.cos(a0)
                sy += math.sin(a0)
            az0 = math.atan2(sy, sx)
        return [math.log(self.d0), sta_c, az0, sta_c, pan, roll, math.log(k)]

    def nearest_on_circle(self, cam, sta, p, az_lo, az_hi):
        """The visible point of the circle at sta nearest to p in the image."""
        r = self.veh.radius(sta)

        def dist(az):
            q = cam.project(surface_point(sta, az, r))
            return math.hypot(q[0] - p[0], q[1] - p[1]) if q else 1e9

        best = min((dist(az), az) for az in frange(az_lo, az_hi, 2.0))[1]
        lo, hi = best - 2.0, best + 2.0
        for _ in range(30):
            m1, m2 = lo + (hi - lo) / 3, hi - (hi - lo) / 3
            if dist(m1) < dist(m2):
                hi = m2
            else:
                lo = m1
        az = (lo + hi) / 2
        q = cam.project(surface_point(sta, az, r))
        return q, az

    def visible(self, cam):
        """Azimuth range (deg) visible from the camera at its height."""
        azc = math.degrees(cam.q[2])
        d = math.exp(cam.q[0])
        r = max(rr for _, rr in self.veh.p)
        half = math.degrees(math.acos(min(1.0, r / d)))
        return azc - half, azc + half

    def residuals(self, q):
        cam = Camera(q, self.cx, self.cy)
        res = []
        d = math.exp(q[0])
        azc = math.degrees(q[2])
        az_lo, az_hi = self.visible(cam)
        for l in self.reg["limbs"]:
            r = self.veh.radius(l["sta"])
            th = math.degrees(math.acos(min(1.0, r / d)))
            for side, az in (("left", azc - th), ("right", azc + th)):
                a = cam.project(surface_point(l["sta"] - 60, az, r))
                b = cam.project(surface_point(l["sta"] + 60, az, r))
                res.append(line_distance(l[side], a, b) if a and b else 1e3)
        for s in self.reg["stations"]:
            if "az" in s:
                pp = cam.project(surface_point(s["sta"], s["az"], self.veh.radius(s["sta"])))
                res += [pp[0] - s["at"][0], pp[1] - s["at"][1]] if pp else [1e3, 1e3]
            else:
                pp, _ = self.nearest_on_circle(cam, s["sta"], s["at"], az_lo, az_hi)
                res.append(math.hypot(pp[0] - s["at"][0], pp[1] - s["at"][1]) if pp else 1e3)
        for z in self.reg.get("azimuths", []):
            # A line of known azimuth must lie on the side facing the camera:
            # its far-side twin projects onto the same image line.
            hidden = 1e3 * max(0.0, 0.1 - math.cos(math.radians(z["az"]) - q[2]))
            if "sta" in z:
                pp = cam.project(surface_point(z["sta"], z["az"], self.veh.radius(z["sta"])))
                res += [pp[0] - z["at"][0] + hidden, pp[1] - z["at"][1]] if pp else [1e3, 1e3]
            else:
                hit = self.veh.hit(cam.c, cam.ray(z["at"]))
                sta = hit[0] if hit else q[1]
                r = self.veh.radius(sta)
                a = cam.project(surface_point(sta - 60, z["az"], r))
                b = cam.project(surface_point(sta + 60, z["az"], r))
                res.append(line_distance(z["at"], a, b) + hidden if a and b else 1e3)
        res.append(self.prior * (q[0] - math.log(self.d0)))
        return res

    def fit(self):
        q = self.cam.q
        steps = [1e-3, 0.5, 1e-4, 0.05, 1e-5, 1e-5, 1e-5]
        r = self.residuals(q)
        cost = sum(x * x for x in r)
        lam = 1e-3
        for _ in range(200):
            jac = []
            for i, h in enumerate(steps):
                qp, qm = q[:], q[:]
                qp[i] += h
                qm[i] -= h
                rp, rm = self.residuals(qp), self.residuals(qm)
                jac.append([(a - b) / (2 * h) for a, b in zip(rp, rm)])
            n = len(q)
            jtj = [[sum(jac[i][k] * jac[j][k] for k in range(len(r))) for j in range(n)] for i in range(n)]
            jtr = [sum(jac[i][k] * r[k] for k in range(len(r))) for i in range(n)]
            improved = False
            for _ in range(10):
                a = [[jtj[i][j] + (lam * jtj[i][i] if i == j else 0.0) for j in range(n)] for i in range(n)]
                try:
                    dq = solve(a, [-x for x in jtr])
                except ZeroDivisionError:
                    lam *= 10
                    continue
                qn = [x + y for x, y in zip(q, dq)]
                try:
                    rn = self.residuals(qn)
                except (ValueError, ZeroDivisionError, OverflowError, TypeError):
                    lam *= 10       # a wild trial step: a degenerate camera
                    continue
                cn = sum(x * x for x in rn)
                if cn < cost:
                    small = cost - cn < 1e-10 * max(cost, 1e-12)
                    q, r, cost = qn, rn, cn
                    lam = max(lam / 10, 1e-12)
                    improved = True
                    break
                lam *= 10
            if not improved or small:
                break
        self.cam = Camera(q, self.cx, self.cy)
        self.rms = math.sqrt(sum(x * x for x in r[:-1]) / max(1, len(r) - 1))

    def locate(self, px):
        return self.veh.hit(self.cam.c, self.cam.ray(px))

    def measure(self, px, sigma):
        hit = self.locate(px)
        if hit is None:
            return None
        sta, az = hit
        ds = da = 0.0
        for dx, dy in ((sigma, 0), (-sigma, 0), (0, sigma), (0, -sigma)):
            h2 = self.locate((px[0] + dx, px[1] + dy))
            if h2:
                ds = max(ds, abs(h2[0] - sta))
                da = max(da, abs((h2[1] - az + 180) % 360 - 180))
        return sta, az, ds, da


def frange(a, b, step):
    x = a
    while x <= b:
        yield x
        x += step


def report(reg, sigma, out=sys.stdout):
    r = Registration(reg)
    frame = reg.get("frame", "STA")
    cam = r.cam
    lnd, h, azc, _, pan, roll, _ = cam.q
    print(f"# {reg['photo']} ({reg.get('vehicle', '')}): {reg.get('copy', '')}", file=out)
    print(f"# camera: {math.exp(lnd) * INCH:.0f} m from the axis at {frame} {h:.0f}, viewing from azimuth "
          f"{math.degrees(azc) % 360:.1f}; tilt {math.degrees(cam.tilt):+.1f}, pan {math.degrees(pan):+.1f}, "
          f"roll {math.degrees(roll):+.1f} deg; f {cam.f:.0f} px; reference rms {r.rms:.2f} px", file=out)
    az_lo, az_hi = r.visible(cam)
    for s in reg["stations"]:
        # The image distance to the fitted circle; and, unless the point sits
        # on the silhouette where a ray grazes the surface, the station its ray hits.
        pp, _ = r.nearest_on_circle(cam, s["sta"], s["at"], az_lo, az_hi)
        px = math.hypot(pp[0] - s["at"][0], pp[1] - s["at"][1])
        hit = r.locate(s["at"])
        sta = f"ray hits {hit[0]:.1f} ({hit[0] - s['sta']:+.1f} in)" if hit else "on the silhouette"
        print(f"#   station {s['sta']:8.2f}: {px:.1f} px from its circle; {sta}  {s.get('what', '')}", file=out)
    for z in reg.get("azimuths", []):
        hit = r.locate(z["at"])
        az = f"{hit[1]:6.1f} ({(hit[1] - z['az'] + 180) % 360 - 180:+.1f} deg)" if hit else "off the vehicle"
        print(f"#   azimuth {z['az']:6.1f} -> {az}  {z.get('what', '')}", file=out)
    print(f"# spreads: the change for a {sigma:g} px shift of the point", file=out)
    print(f"name,x,y,{frame.lower()},sta_spread,az_deg,az_spread", file=out)
    rows = []
    for p in reg.get("points", []):
        m = r.measure(p["at"], sigma)
        if m is None:
            print(f"{p['name']},{p['at'][0]:g},{p['at'][1]:g},,,,", file=out)
            continue
        sta, az, ds, da = m
        print(f"{p['name']},{p['at'][0]:g},{p['at'][1]:g},{sta:.1f},{ds:.1f},{az:.1f},{da:.1f}", file=out)
        rows.append((p["name"], sta, az))
    return r, rows


def selftest():
    """Synthetic views of a 198 in cylinder on an 80 in skirt from near and far
    cameras: the fit must find every point within 1 in and 0.2 deg."""
    profile = [[0, 198], [1500, 198], [1500, 130], [1800, 130]]
    veh = Vehicle(profile)
    cases = [(300.0, 1500.0, 180.0, 0.02, 0.0, 0.0, 1300.0, 6000.0),
             (60.0, 200.0, 37.0, 0.25, 0.02, 0.05, 1500.0, 2500.0),
             (35.0, 1700.0, 300.0, -0.45, -0.03, -0.2, 3000.0, 2000.0),
             (1500.0, -100.0, 90.0, 0.03, 0.0, 0.01, 1500.0, 30000.0)]
    worst = (0.0, 0.0)
    for dist, h, azc, tilt, pan, roll, w, f in cases:
        d = dist / INCH
        q = [math.log(d), h, math.radians(azc), h + d * math.tan(tilt), pan, roll, math.log(f / d)]
        cam = Camera(q, w / 2, w * 0.65)

        def at(sta, az):
            return list(cam.project(surface_point(sta, az, veh.radius(sta))))

        def limb(sta, side):
            th = math.degrees(math.acos(veh.radius(sta) / (dist / INCH)))
            return at(sta, azc + side * th)

        reg = {"photo": "synthetic", "profile": profile, "image": [w, w * 1.3], "distance_m": 300.0,
               "limbs": [{"sta": s, "left": limb(s, -1), "right": limb(s, 1)} for s in (300, 900, 1400, 1700)],
               "stations": [{"sta": s, "at": at(s, azc + da)} for s, da in ((100, 0), (100, 60), (700, -30),
                                                                           (1200, 10), (1500, 50), (1780, -20))],
               "azimuths": [{"az": azc + 40, "at": at(1000, azc + 40)}, {"az": azc - 45, "at": at(400, azc - 45)}],
               "points": []}
        expect = {}
        for s in (150, 600, 1100, 1450, 1650):
            for da in (-60, -25, 0, 30, 65):
                name = f"{s}/{da}"
                reg["points"].append({"name": name, "at": at(s, azc + da)})
                expect[name] = (s, (azc + da) % 360)
        r = Registration(reg)
        for p in reg["points"]:
            hit = r.locate(p["at"])
            s, a = expect[p["name"]]
            if hit is None:
                worst = (math.inf, math.inf)
                continue
            worst = (max(worst[0], abs(hit[0] - s)), max(worst[1], abs((hit[1] - a + 180) % 360 - 180)))
        print(f"  camera {dist:g} m at {h:g}: fitted {math.exp(r.cam.q[0]) * INCH:.1f} m at {r.cam.q[1]:.0f}, "
              f"rms {r.rms:.3f} px")
    print(f"selftest: worst station error {worst[0]:.3f} in, worst azimuth error {worst[1]:.3f} deg")
    ok = worst[0] < 1.0 and worst[1] < 0.2
    print("ok" if ok else "FAIL")
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("registration", nargs="*", help="registration JSON files")
    ap.add_argument("--sigma", type=float, default=1.0, help="pixel uncertainty for the spreads")
    ap.add_argument("--selftest", action="store_true", help="check the fit on synthetic views")
    p = ap.parse_args()
    if p.selftest:
        sys.exit(0 if selftest() else 1)
    if not p.registration:
        ap.error("give a registration file or --selftest")
    for path in p.registration:
        with open(path) as f:
            report(json.load(f), p.sigma)


if __name__ == "__main__":
    main()
