// Exhaust plumes (track P2 owns this module): the ray march of the
// clusters' proxies into R6's volumes layer, the impostors of small plumes
// and the SPS extension's glow. The field is PlumeLook's PlumeMember.sample
// (OrbitScene), line by line, plus the turbulence; radiance is linear light
// times FrameUniforms.exposure.x (R1), held below 6e4 (R6).
let plumeShaderSource = #"""
// ------------------------------------------------------------------ plumes ---

struct PlumeFrame {
    float4 wienK;       // rgb: the blackbody's c0 per channel (exp(c0 + c1/T + c2/T²) cd/m²), w: march steps
    float4 wienA;       // rgb: c1 (K), w: the turbulence clock (s)
    float4 sun;         // xyz: unit to the Sun (world), w: 1 with the clouds' layer bound
    float4 sunLight;    // rgb: the Sun's lux at the plumes, w: 1 to take R4's shadow
    float4 ambient;     // rgb: the mean radiance where R3's probe is not drawn (cd/m², not pre-exposed)
    float4 params;      // x: frame index, y: 1 with aerial perspective, z: a half-res texel's angle (rad)
    float4 wienC;       // rgb: c2 (K²)
};

struct PlumeCluster {
    float4 origin;      // xyz: camera-relative, on the exits' plane, w: rings
    float4 axis;        // xyz: unit, w: first member
    float4 u;           // xyz: unit across, w: members
    float4 v;           // xyz: unit across, w: the vessel's sunlit share
    float4 rings[4];    // (x, r) pairs along the axis
    float4 light;       // xyz: the cluster light's centre, w: its length
    float4 lightAxis;   // xyz: its axis, w: its radius
    float4 lightColor;  // rgb: its intensity (cd)
    float4 reserved[4];
};

struct PlumeMember {
    float4 exit;        // xyz camera-relative, w: exit radius
    float4 axis;        // xyz unit, w: length
    float4 shape;       // growth, shape length, far spread, core length
    float4 simons;      // vacuum blend, exponent, limiting angle, source offset
    float4 gas;         // extinction, albedo, core temperature, expansion cooling
    float4 flame;       // temperature, start, ambient temperature, afterburning
    float4 sheath;      // extinction, thickness, length, soot burn-out
    float4 sheathLight; // rgb: the film's blackbody, w: the radius' offset (merged)
    float4 particles;   // extinction, albedo, temperature, cooling length
    float4 particles2;  // angle, source offset, onset, phase g
    float4 structure;   // cell length, cells, strength, upstream
    float4 base;        // rgb: the base's blackbody, w: extinction
    float4 disk;        // distance, radius, extinction, the air's confinement
    float4 diskLight;   // rgb: the disk's blackbody, w: the density's scale (merged)
    float4 noise;       // eddy size, phase (tiles), depth, tile (m)
    float4 glow;        // rgb (cd/m²), w: length
    float4 extent;      // x: tan of the 1 % Simons angle (0 none), y: the particles', z: flame length (m), w: flame spread
};

// How far out the eddies may carry the boundary, over R (PlumeMember.turbulentReach).
constant float PLUME_TURBULENT_REACH = 1.15;

constant int PLUME_RINGS = 8;
constant int PLUME_SIDES = 24;

inline float plume_smoothstep(float a, float b, float x) {
    float t = clamp((x - a) / (b - a), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

inline float2 plume_ringDevice(const device PlumeCluster &c, int i) {
    float4 r = c.rings[i / 2];
    return (i & 1) == 0 ? r.xy : r.zw;
}

// A corner of the proxy's polygon: ring `ring` at side `side`.
inline float3 plume_proxyPoint(const device PlumeCluster &c, int ring, int side, float widen) {
    float2 xr = plume_ringDevice(c, ring);
    float phi = 2.0 * M_PI_F * float(side) / float(PLUME_SIDES);
    return c.origin.xyz + c.axis.xyz * xr.x + (c.u.xyz * cos(phi) + c.v.xyz * sin(phi)) * (xr.y * widen);
}

// A full radiator's luminance in linear Rec. 709 (cd/m²), PlumeLook.blackbody:
// per channel exp(c0 + c1/T + c2/T²).
inline float3 plume_blackbody(float t, constant PlumeFrame &pf) {
    if (t < 300.0) { return float3(0.0); }
    float u = 1.0 / t;
    return exp(pf.wienK.rgb + (pf.wienA.rgb + pf.wienC.rgb * u) * u);
}

// Henyey-Greenstein, normalised over the sphere.
inline float plume_phase(float cosTheta, float g) {
    float d = 1.0 + g * g - 2.0 * g * cosTheta;
    return (1.0 - g * g) / (4.0 * M_PI_F * d * sqrt(d));
}

// Interleaved gradient noise (Jimenez 2014), turned each frame.
inline float plume_jitter(float2 p, float frame) {
    p += 5.588238 * fmod(frame, 64.0);
    return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715))));
}

// ------------------------------------------------------------ the proxy ---
// A solid of revolution about the cluster's axis, its polygon of
// PLUME_SIDES circumscribed about each ring, every edge's sides then both
// caps, counter-clockwise seen from outside; edges past the last ring
// collapse to a point.

struct PlumeProxyOut {
    float4 position [[position]];
    uint cluster [[flat]];
};

vertex PlumeProxyOut plume_proxy_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                        const device PlumeCluster *clusters [[buffer(1)]],
                                        constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]]) {
    const device PlumeCluster &c = clusters[iid];
    int rings = int(c.origin.w);
    float widen = 1.0 / cos(M_PI_F / float(PLUME_SIDES));
    int sideVerts = (PLUME_RINGS - 1) * PLUME_SIDES * 6;
    float3 p;
    int v = int(vid);
    float3 o = c.origin.xyz, a = c.axis.xyz;
    if (v < sideVerts) {
        int quad = v / 6, corner = v % 6;
        int edge = quad / PLUME_SIDES, side = quad % PLUME_SIDES;
        if (edge >= rings - 1) {
            p = o;
        } else {
            // (A, B, C), (A, C, D): A ring k at φi, B ring k at φi+1, C ring k+1 at φi+1, D ring k+1 at φi.
            int ringOf[6] = {0, 0, 1, 0, 1, 1};
            int sideOf[6] = {0, 1, 1, 0, 1, 0};
            p = plume_proxyPoint(c, edge + ringOf[corner], side + sideOf[corner], widen);
        }
    } else {
        int k = v - sideVerts;
        int cap = k / (PLUME_SIDES * 3), tri = (k % (PLUME_SIDES * 3)) / 3, corner = k % 3;
        int ring = cap == 0 ? 0 : max(rings - 1, 0);
        float2 xr = plume_ringDevice(c, ring);
        if (corner == 0) {
            p = o + a * xr.x;
        } else {
            // Start cap: (centre, φi+1, φi); end cap: (centre, φi, φi+1).
            bool next = (cap == 0) == (corner == 1);
            p = plume_proxyPoint(c, ring, tri + (next ? 1 : 0), widen);
        }
    }
    PlumeProxyOut out;
    out.position = frame.viewProjection * float4(p, 1.0);
    out.cluster = iid;
    return out;
}

// The interval of t over which o + t d lies inside the cone r <= a + b x
// on its nappe a + b x >= 0 (x along the axis), in the axis' frame: x(t) =
// ox + t dx, the perpendicular part o + t d. Empty as (1, 0).
inline float2 plume_coneInterval(float ox, float dx, float3 op, float3 dp, float a, float b) {
    const float big = 1e30;
    float k = a + b * ox, kd = b * dx;
    float A = kd * kd - dot(dp, dp), B = 2.0 * (kd * k - dot(op, dp)), C = k * k - dot(op, op);
    // The nappe: a + b x(t) >= 0.
    float2 nappe = float2(-big, big);
    if (abs(kd) > 1e-12) {
        float th = -k / kd;
        nappe = kd > 0.0 ? float2(th, big) : float2(-big, th);
    } else if (k < 0.0) {
        return float2(1.0, 0.0);
    }
    float2 inside;
    if (abs(A) < 1e-12) {
        if (abs(B) < 1e-12) {
            inside = C >= 0.0 ? float2(-big, big) : float2(1.0, 0.0);
        } else {
            float t = -C / B;
            inside = B > 0.0 ? float2(t, big) : float2(-big, t);
        }
    } else {
        float disc = B * B - 4.0 * A * C;
        if (A < 0.0) {
            if (disc < 0.0) { return float2(1.0, 0.0); }
            float q = sqrt(disc);
            float t0 = (-B + q) / (2.0 * A), t1 = (-B - q) / (2.0 * A);
            inside = float2(min(t0, t1), max(t0, t1));
        } else {
            if (disc <= 0.0) {
                inside = float2(-big, big);
            } else {
                float q = sqrt(disc);
                float t0 = (-B - q) / (2.0 * A), t1 = (-B + q) / (2.0 * A);
                // Two pieces, one on each nappe: the nappe picks one.
                inside = nappe.x > -big ? float2(t1, big) : float2(-big, t0);
            }
        }
    }
    return float2(max(inside.x, nappe.x), min(inside.y, nappe.y));
}

// ------------------------------------------------------------- the field ---
// One member's absorption, scattering, emission (cd/m³) and the scattering
// weighted by its phase's g, at camera-relative p; PlumeMember.sample.

struct PlumeSample {
    float absorption;
    float scattering;
    float3 emission;
    float g;            // scattering-weighted asymmetry
};

inline void plume_add(thread PlumeSample &s, float sigma0, float albedo, float3 light, float scale) {
    float sigma = sigma0 * scale;
    if (sigma <= 0.0) { return; }
    float a = sigma * (1.0 - albedo);
    s.absorption += a;
    s.scattering += sigma * albedo;
    s.emission += a * light;
}

// The turbulence at camera-relative p: two octaves of the volume noise in a
// cluster's frame (its first member's eddies), moving downstream, about 0
// on average and ±0.3 or so. One lookup a sample for all the members.
inline float plume_noise(const device PlumeMember &m, float3 p, texture3d<float> noise, sampler ns) {
    float3 d = p - m.exit.xyz;
    float x = max(dot(d, m.axis.xyz), 0.0);
    float re = m.exit.w;
    float R = re + m.shape.x * (1.0 - exp(-x / max(m.shape.y, 1e-6))) + m.shape.z * max(0.0, x - m.shape.w);
    float grow = pow(max(R / re, 1.0), 0.7);
    float3 nc = (d / (m.noise.w * grow)) - m.axis.xyz * m.noise.y;
    float n1 = noise.sample(ns, nc).r, n2 = noise.sample(ns, nc * 2.0 + 0.37).g;
    return 2.0 * (0.65 * n1 + 0.35 * n2) - 1.0;
}

inline void plume_member(thread PlumeSample &s, const device PlumeMember &m, float3 p, constant PlumeFrame &pf,
                         float nv, thread float &sunDepth, float3 sunDir) {
    float3 d = p - m.exit.xyz;
    float x = dot(d, m.axis.xyz);
    float upstream = m.structure.w, length_ = m.axis.w;
    if (x < -upstream || x > length_) { return; }
    float3 radial = d - m.axis.xyz * x;
    float r = length(radial);
    float re = m.exit.w, de = 2.0 * re;
    float xp = max(x, 0.0);
    float R = max(re + m.sheathLight.w + m.shape.x * (1.0 - exp(-xp / max(m.shape.y, 1e-6)))
                  + m.shape.z * max(0.0, xp - m.shape.w) + m.extent.w * max(0.0, xp - m.flame.y), 0.2 * re);
    float k = m.diskLight.w;
    // The early reject: PlumeMember.extent.
    float e = x < 0.0 ? 1.6 * re : 1.55 * PLUME_TURBULENT_REACH * R;
    if (x >= 0.0) {
        if (m.extent.x > 0.0) { e = max(e, (x + m.simons.w) * m.extent.x); }
        if (m.extent.y > 0.0) { e = max(e, (x + m.particles2.y) * m.extent.y); }
        if (m.disk.z > 0.0 && abs(x - m.disk.x) < m.disk.y + de) { e = max(e, 1.1 * m.disk.y); }
    }
    if (r > e) { return; }

    // The turbulence's depth here (the noise is the sample's), faded out
    // where its eddies are under a few texels across.
    float eddy = m.noise.x * pow(max(R / re, 1.0), 0.7);
    float footprint = length(p) * pf.params.z;
    float depth = m.noise.z * plume_smoothstep(0.0, 4.0 * de, xp) * plume_smoothstep(1.5, 4.0, eddy / max(footprint, 1e-6));
    float turb = max(1.0 + depth * 3.0 * nv, 0.05);
    float hot = 1.0 + depth * 0.15 * nv;                            // hot and cool pockets

    float g0 = s.scattering;
    float before = s.absorption + s.scattering;
    // The base's recirculation, upstream of the exit too.
    if (m.base.w > 0.0 && x < 0.4 * de) {
        float mb = (1.0 - plume_smoothstep(0.6, 1.0, r / (1.6 * re))) * plume_smoothstep(-upstream, -0.5 * upstream, x)
            * (1.0 - plume_smoothstep(0.0, 0.4 * de, x));
        plume_add(s, m.base.w * mb * turb, 0.0, m.base.rgb, k);
    }
    if (x >= 0.0) {
        // The boundary ragged by the eddies, outwards no further than the
        // proxy and the reject hold.
        float q = r / R * max(1.0 - depth * 0.5 * nv, 1.0 / PLUME_TURBULENT_REACH);
        float w = clamp(0.06 + 0.45 * x / (x + 6.0 * de), 0.06, 0.5);
        float pc = 1.0 - plume_smoothstep(1.0 - w, 1.0 + w, q);
        float v = m.simons.x;
        float confine = 1.0, profile = pc, dilution = (re / R) * (re / R);
        if (v > 0.0) {
            // The free expansion's field (Simons), cut at the boundary as
            // much as the air confines it.
            float theta = atan2(r, x + m.simons.w);
            float lim = m.simons.z;
            confine = 1.0 - m.disk.w * plume_smoothstep(1.0, 1.5, q);
            float pv = theta < lim ? pow(max(cos(0.5 * M_PI_F * theta / lim), 0.0), m.simons.y) * confine : 0.0;
            profile = mix(pc, pv, v);
            float d2 = (x + m.simons.w) * (x + m.simons.w) + r * r;
            dilution = dilution * (1.0 - v) + m.simons.w * m.simons.w / max(d2, 1e-9) * v;
        }
        float fade = 1.0 - plume_smoothstep(0.7 * length_, length_, x);
        float rho = profile * dilution * fade;
        float mixing = x > m.shape.w ? m.shape.w / x : 1.0;
        float cells = 1.0;
        if (m.structure.x > 0.0 && x < m.structure.y * m.structure.x) {
            cells += m.structure.z * cos(2.0 * M_PI_F * x / m.structure.x) * exp(-x / max(m.structure.y * m.structure.x, 1e-6));
        }
        // The gas: the core, and the afterburning flame in the mixing layer.
        if (m.gas.x > 0.0) {
            float ta = m.flame.z;
            float tCore = ta + (m.gas.z - ta) * mixing * pow(max(dilution, 1e-12), m.gas.w);
            float t = tCore * cells;
            if (m.flame.x > 0.0 && m.flame.w > 0.0) {
                float fx = plume_smoothstep(m.flame.y - 0.25 * de, m.flame.y + 0.25 * de, x);
                float qf = 0.85 * max(0.0, 1.0 - x / max(m.shape.w, de));
                float fr = plume_smoothstep(qf - 0.15, qf + 0.05, q);
                float hold = x > m.extent.z ? m.extent.z / x : 1.0;
                float tFlame = ta + (m.flame.x - ta) * hold;
                t += (max(t, tFlame) - t) * m.flame.w * fx * fr;
            }
            float burnt = 1.0;
            if (m.sheath.w > 0.0) { burnt -= 0.75 * m.flame.w * plume_smoothstep(m.sheath.w, 1.5 * m.sheath.w, x); }
            plume_add(s, m.gas.x * rho * cells * burnt * turb, m.gas.y, plume_blackbody(t * hot, pf), k);
        }
        // The film.
        if (m.sheath.x > 0.0 && x < m.sheath.z + 0.5 * de) {
            float t = m.sheath.y;
            float band = plume_smoothstep(1.0 - t - 0.06, 1.0 - t + 0.04, q) * (1.0 - plume_smoothstep(1.0 + 0.4 * t, 1.0 + t, q));
            float along = 1.0 - plume_smoothstep(m.sheath.z - 0.3 * de, m.sheath.z + 0.3 * de, x);
            plume_add(s, m.sheath.x * band * along * min(1.0, dilution) * fade * turb, m.gas.y, m.sheathLight.rgb, k);
        }
        // Particles: alumina, or condensate.
        if (m.particles.x > 0.0 && x > 0.5 * m.particles2.z) {
            float pp = pc, dil = (re / R) * (re / R);
            if (v > 0.0) {
                float tp = atan2(r, x + m.particles2.y);
                float pa = m.particles2.x;
                float ppv = tp < pa ? pow(max(cos(0.5 * M_PI_F * tp / pa), 0.0), 2.0) * confine : 0.0;
                pp = mix(pc, ppv, v);
                float dp2 = (x + m.particles2.y) * (x + m.particles2.y) + r * r;
                dil = dil * (1.0 - v) + m.particles2.y * m.particles2.y / max(dp2, 1e-9) * v;
            }
            float on = m.particles2.z > 0.0 ? plume_smoothstep(0.5 * m.particles2.z, m.particles2.z, x) : 1.0;
            float temp = m.particles.z > 0.0 ? m.particles.z * pow(1.0 + 3.0 * x / m.particles.w, -1.0 / 3.0) : 0.0;
            // Hot alumina absorbs (and so glows) more than its white smoke.
            float albedo = mix(m.particles.y, 0.5, plume_smoothstep(1400.0, 2000.0, temp));
            plume_add(s, m.particles.x * pp * dil * on * fade * turb, albedo, plume_blackbody(temp * hot, pf), k);
        }
        // The Mach disk.
        if (m.disk.z > 0.0) {
            float dx = (x - m.disk.x) / (0.25 * m.disk.y + 0.05 * de);
            float md = exp(-dx * dx) * (1.0 - plume_smoothstep(0.8, 1.1, r / max(m.disk.y, 1e-6)));
            plume_add(s, m.disk.z * md, 0.0, m.diskLight.rgb, k);
        }
        // The glow, emission only.
        if (m.glow.w > 0.0) {
            float along = pow(max(1.0 - x / m.glow.w, 0.0), 1.6) * plume_smoothstep(0.0, 0.03 * m.glow.w, x);
            s.emission += m.glow.rgb * (along * (1.0 - plume_smoothstep(0.7, 1.0, q)) / (2.0 * R) * k);
        }
        // Self-shadowing towards the Sun: this member's extinction here over
        // the chord to its edge along the Sun, a uniform column's.
        float added = s.absorption + s.scattering - before;
        if (added > 0.0) {
            float3 lp = sunDir - m.axis.xyz * dot(sunDir, m.axis.xyz);
            float sa = length(lp);
            float c = r > 1e-6 && sa > 1e-6 ? dot(radial / r, lp / sa) : 0.0;
            float qq = min(q, 1.0);
            float chord = R * (sqrt(max(1.0 - qq * qq * (1.0 - c * c), 0.0)) - qq * c) / max(sa, 0.15);
            sunDepth += 0.7 * added * chord;
        }
    }
    s.g += (s.scattering - g0) * m.particles2.w;
}

// ------------------------------------------------------------- the march ---
// The fragment intersects its ray with the cluster's proxy (the slab
// between its end rings and each edge's cone), clamps it at the scene and
// marches it in the frame's steps, jittered, with Hillaire's energy-
// conserving step, stopping once the transmittance is under 2 %. The
// members are lit by their own glow, the Sun (single scattering, HG, R4's
// shadow, C2's cloud shadow, the Sun's chord through the plume), the
// ambient (A2's sky in air, the earthshine in vacuum; R3's SH9 later) and
// the cluster's own light on its smoke. C2's clouds dim what lies within
// and behind them; A2's air between the camera and the plume dims it and
// adds its own light.

// The ambient light scattered towards the eye along view ray v by a medium
// of Henyey-Greenstein asymmetry g (cd/m², not pre-exposed): R3's probe's
// SH9 when it is drawn (lighting.probe.w), else the mean radiance about the
// plumes, isotropic (A2's sky in air, the earthshine stand-in in vacuum;
// PlumeSystem.prepare).
inline float3 plume_sh9InScatter(constant LightingUniforms &lighting, float3 v, float g, constant PlumeFrame &pf) {
    return lighting.probe.w > 0.5 ? orbit_sh9InScatter(lighting, v, g) : pf.ambient.rgb;
}

fragment EffectVolumeOut plume_march_fragment(PlumeProxyOut in [[stage_in]],
                                              constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                              constant EffectSlotUniforms &e [[buffer(ORBIT_EFFECT_BUFFER_SLOTS)]],
                                              constant AtmosphereUniforms &air [[buffer(ORBIT_BUFFER_ATMOSPHERE)]],
                                              constant LightingUniforms &lighting [[buffer(ORBIT_BUFFER_LIGHTING)]],
                                              constant PlumeFrame &pf [[buffer(0)]],
                                              const device PlumeCluster *clusters [[buffer(1)]],
                                              const device PlumeMember *members [[buffer(2)]],
                                              texture3d<float> noise [[texture(0)]],
                                              texture2d<float> cloudLayer [[texture(1)]],
                                              texture2d<float> cloudDepth [[texture(2)]],
                                              texture2d<float> halfResDepth [[texture(ORBIT_EFFECT_TEXTURE_HALFRES_DEPTH)]],
                                              depth2d_array<float> shadowAtlas [[texture(ORBIT_TEXTURE_SHADOW_ATLAS)]],
                                              texture2d<float> cloudShadow [[texture(ORBIT_TEXTURE_CLOUD_SHADOW)]],
                                              texture3d<float> froxels [[texture(ORBIT_TEXTURE_AERIAL_PERSPECTIVE)]],
                                              sampler ns [[sampler(0)]],
                                              sampler linear [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]],
                                              sampler shadowCompare [[sampler(ORBIT_SAMPLER_SHADOW_COMPARE)]]) {
    uint2 texel = uint2(in.position.xy);
    const device PlumeCluster &c = clusters[in.cluster];
    float3 dir = (frame.viewToWorld * float4(orbit_effectViewRay(in.position.xy, e, frame), 0.0)).xyz;
    // The ray in the cluster's frame (the camera at the world's origin).
    float3 a = c.axis.xyz;
    float3 o = -c.origin.xyz;
    float ox = dot(o, a), dx = dot(dir, a);
    float3 op = o - a * ox, dp = dir - a * dx;
    int rings = int(c.origin.w);
    float2 first = plume_ringDevice(c, 0), last = plume_ringDevice(c, max(rings - 1, 0));
    float enter = frame.camera.x, exit = orbit_effectSceneDistance(texel, halfResDepth, frame);
    if (abs(dx) > 1e-9) {
        float t0 = (first.x - ox) / dx, t1 = (last.x - ox) / dx;
        enter = max(enter, min(t0, t1));
        exit = min(exit, max(t0, t1));
    } else if (ox < first.x || ox > last.x) {
        discard_fragment();
    }
    for (int k = 0; k + 1 < rings; k++) {
        float2 p0 = plume_ringDevice(c, k), p1 = plume_ringDevice(c, k + 1);
        float b = (p1.y - p0.y) / max(p1.x - p0.x, 1e-6);
        float2 span = plume_coneInterval(ox, dx, op, dp, p0.y - b * p0.x, b);
        enter = max(enter, span.x);
        exit = min(exit, span.y);
    }
    if (exit <= enter) { discard_fragment(); }

    int steps = max(int(pf.wienK.w), 1);
    float len = length(dir);
    float3 view = dir / len;
    // Half the steps in the near field (x up to c.reserved[0].x), where the
    // structure and the brightest light are, half beyond, in ray order.
    float nearX = c.reserved[0].x;
    float2 seg0 = float2(enter, exit), seg1 = float2(exit, exit);
    int n0 = steps;
    if (abs(dx) > 1e-9) {
        float tNear = (nearX - ox) / dx;
        if (tNear > enter && tNear < exit) {
            seg0 = float2(enter, tNear);
            seg1 = float2(tNear, exit);
            n0 = steps / 2;
        }
    }
    // A single member seen across (more than 30° off its axis): its steps
    // equiangular about its axis (Kulla and Fajardo 2012), as dense as
    // 1 / (h² + distance²) along the ray, h the ray's closest approach or
    // half the member's dense radius there, so a small dense core (a
    // retro's alumina) is not stepped over.
    int first_ = int(c.axis.w), count = int(c.u.w);
    bool equiangular = false;
    float t0 = 0.0, hk = 1.0, phiA = 0.0, dphi = 0.0;
    if (count == 1) {
        const device PlumeMember &m0 = members[first_];
        float3 ma = m0.axis.xyz, w0 = -m0.exit.xyz;
        float3 dpm = dir - ma * dot(dir, ma), opm = w0 - ma * dot(w0, ma);
        float k2 = dot(dpm, dpm), k = sqrt(k2);
        if (k > 0.5 * len) {
            t0 = -dot(opm, dpm) / k2;
            float rho0 = length(opm + dpm * t0);
            float re0 = m0.exit.w;
            float x0 = max(dot(dir * t0 - m0.exit.xyz, ma), 0.0);
            float dense = re0 + m0.shape.x * (1.0 - exp(-x0 / max(m0.shape.y, 1e-6))) + m0.shape.z * max(0.0, x0 - m0.shape.w);
            if (m0.simons.x > 0.02) {
                float half_ = 2.0 * m0.simons.z / M_PI_F * acos(pow(0.5, 1.0 / max(m0.simons.y, 1e-3)));
                float cone = (x0 + m0.simons.w) * tan(min(half_, 1.4));
                if (m0.particles.x > 0.0) { cone = max(cone, (x0 + m0.particles2.y) * tan(min(m0.particles2.x, 1.4))); }
                dense = min(dense, cone);
            }
            float h = max(rho0, 0.5 * max(dense, re0));
            if ((exit - enter) * k > 4.0 * h) {
                equiangular = true;
                hk = h / k;
                phiA = atan((enter - t0) / hk);
                dphi = (atan((exit - t0) / hk) - phiA) / float(steps);
            }
        }
    }
    float jitter = plume_jitter(in.position.xy, pf.params.x);
    float3 sunDir = pf.sun.xyz;
    float3 sunLux = pf.sunLight.rgb * c.v.w;
    // R4's shadow at four points along the march, and C2's at its middle.
    float shadows[4] = {1.0, 1.0, 1.0, 1.0};
    if (pf.sunLight.w > 0.5) {
        for (int i = 0; i < 4; i++) {
            float3 p = dir * (enter + (float(i) + 0.5) * 0.25 * (exit - enter));
            shadows[i] = orbit_sunShadow(p, sunDir, lighting, shadowAtlas, shadowCompare);
        }
    }
    sunLux *= orbit_cloudSunTransmittance(dir * (0.5 * (enter + exit)), air, cloudShadow, linear);
    // C2's clouds at this texel: their opacity and where they begin.
    float cloudAlpha = 0.0, cloudEntry = 1e30, cloudBack = 1e30, cloudFront = 1e30;
    if (pf.sun.w > 0.5) {
        float2 uv = in.position.xy * e.target.zw;
        cloudAlpha = clamp(cloudLayer.sample(linear, uv).a, 0.0, 0.9999);
        // The depth codes are not filtered across the no-depth code (60):
        // the nearest of the four, as C2's slot reads them.
        float4 fronts = cloudDepth.gather(linear, uv, int2(0), component::x);
        float4 means = cloudDepth.gather(linear, uv, int2(0), component::y);
        float4 entries = cloudDepth.gather(linear, uv, int2(0), component::z);
        float4 z = float4(min(min(fronts.x, fronts.y), min(fronts.z, fronts.w)),
                          min(min(means.x, means.y), min(means.z, means.w)),
                          min(min(entries.x, entries.y), min(entries.z, entries.w)), 0.0);
        if (cloudAlpha > 1e-4 && z.z < 59.5) {
            cloudFront = exp2(z.x);
            cloudEntry = exp2(min(z.z, z.x));
            float mean = exp2(z.y);
            cloudBack = cloudEntry + 2.0 * max(mean - cloudEntry, 0.0);
        }
    }

    float mergeX = c.reserved[0].y;
    float3 lightCentre = c.light.xyz, lightAxis = c.lightAxis.xyz;
    float lightLength = c.light.w, lightRadius = c.lightAxis.w;
    float3 lightColor = c.lightColor.rgb;
    float transmittance = 1.0, front = ORBIT_EFFECT_NO_FRONT;
    float3 radiance = float3(0.0);
    // Through the clouds: the same, dimmed by them within and beyond.
    float transmittanceC = 1.0, frontC = ORBIT_EFFECT_NO_FRONT;
    float3 radianceC = float3(0.0);
    float meanDepth = 0.0, meanWeight = 0.0;
    float exposure = frame.exposure.x;
    for (int i = 0; i < steps; i++) {
        float s, ds;
        if (equiangular) {
            float phi = phiA + (float(i) + jitter) * dphi;
            float cp = cos(phi);
            s = t0 + hk * tan(phi);
            ds = hk * dphi / (cp * cp);
        } else {
            bool second = i >= n0;
            float2 seg = second ? seg1 : seg0;
            ds = (seg.y - seg.x) / float(second ? steps - n0 : n0);
            s = seg.x + (float(second ? i - n0 : i) + jitter) * ds;
        }
        float3 p = dir * s;
        PlumeSample x = {0.0, 0.0, float3(0.0), 0.0};
        float sunDepth = 0.0;
        float nv = members[first_].noise.z > 0.0 ? plume_noise(members[first_], p, noise, ns) : 0.0;
        // The members, and beyond mergeX the merged far field in their
        // place, blended over 15 % of that distance.
        float wm = mergeX > 0.0 ? plume_smoothstep(mergeX, 1.15 * mergeX, dot(p - c.origin.xyz, a)) : 0.0;
        if (wm < 1.0) {
            for (int k = 0; k < count; k++) {
                plume_member(x, members[first_ + k], p, pf, nv, sunDepth, sunDir);
            }
        }
        if (wm > 0.0) {
            PlumeSample y = {0.0, 0.0, float3(0.0), 0.0};
            float sunY = 0.0;
            plume_member(y, members[first_ + count], p, pf, nv, sunY, sunDir);
            x.absorption = mix(x.absorption, y.absorption, wm);
            x.scattering = mix(x.scattering, y.scattering, wm);
            x.emission = mix(x.emission, y.emission, wm);
            x.g = mix(x.g, y.g, wm);
            sunDepth = mix(sunDepth, sunY, wm);
        }
        float sigma = x.absorption + x.scattering;
        if (sigma <= 0.0 && max(x.emission.r, max(x.emission.g, x.emission.b)) <= 0.0) { continue; }
        float3 source = x.emission;
        if (x.scattering > 0.0) {
            float g = x.g / x.scattering;
            float3 ambient = plume_sh9InScatter(lighting, view, g, pf);
            float shadow = shadows[clamp(int(4.0 * (s - enter) / max(exit - enter, 1e-6)), 0, 3)];
            source += x.scattering * sunLux * (shadow * plume_phase(dot(view, sunDir), g) * exp(-sunDepth));
            // The cluster's own light on its smoke outside its luminous
            // column, isotropic: a line source's falloff, I / (d² + d L / 2
            // + R²), as 2I/(dL) near a long one and I/d² far off.
            float3 rel = p - lightCentre;
            float along = clamp(dot(rel, lightAxis), -0.5 * lightLength, 0.5 * lightLength);
            float d = length(rel - lightAxis * along);
            float irradiance = plume_smoothstep(lightRadius, 2.0 * lightRadius, d)
                / (d * d + 0.5 * d * lightLength + lightRadius * lightRadius);
            source += x.scattering * (ambient + lightColor * (irradiance / (4.0 * M_PI_F)));
        }
        float dtau = sigma * ds * len;
        float stepT = exp(-dtau);
        float3 added = sigma > 1e-7 ? source / sigma * (1.0 - stepT) : source * ds * len;
        float3 stepLight = transmittance * added;
        radiance += stepLight;
        // The clouds' transmittance to here.
        float tc = s < cloudEntry ? 1.0
            : pow(1.0 - cloudAlpha, clamp((s - cloudEntry) / max(cloudBack - cloudEntry, 1e-3), 0.0, 1.0));
        radianceC += transmittanceC * tc * added;
        float lum = dot(stepLight, float3(0.2126, 0.7152, 0.0722));
        meanDepth += lum * s;
        meanWeight += lum;
        transmittance *= stepT;
        transmittanceC *= mix(1.0, stepT, tc);
        if (front >= ORBIT_EFFECT_NO_FRONT && orbit_frontReached(1.0 - transmittance, radiance * exposure, e)) {
            front = orbit_frontCode(s);
        }
        if (frontC >= ORBIT_EFFECT_NO_FRONT && orbit_frontReached(1.0 - transmittanceC, radianceC * exposure, e)) {
            frontC = orbit_frontCode(s);
        }
        if (transmittance < 0.02) { break; }
    }
    // In front of the clouds the composite lays the plume over them, so it
    // carries their dimming itself; behind their front they lie over it.
    bool overClouds = front < orbit_frontCode(cloudFront);
    float3 color = overClouds ? radianceC : radiance;
    float coverage = overClouds ? 1.0 - transmittanceC : 1.0 - transmittance;
    float frontOut = overClouds ? frontC : front;
    if (coverage <= 1e-5 && max(color.r, max(color.g, color.b)) <= 0.0) { discard_fragment(); }
    // A2's air in front of the plume.
    if (pf.params.y > 0.5) {
        float depthMean = meanWeight > 0.0 ? meanDepth / meanWeight : 0.5 * (enter + exit);
        float4 haze = atmo_aerialPerspective(froxels, linear, in.position.xy * e.target.zw, depthMean * len, air);
        color = color * haze.a + haze.rgb * coverage;
    }
    color *= exposure;
    if (orbit_isNotFinite(color) || orbit_isNotFinite(coverage)) { color = float3(0.0); coverage = 0.0; }
    EffectVolumeOut out;
    out.color = float4(orbit_effectRadiance(max(color, float3(0.0))), clamp(coverage, 0.0, 1.0));
    out.front = float4(frontOut);
    return out;
}

// --------------------------------------------------------- the impostors ---
// Camera-facing strips along each member: the light and opacity seen
// through its axis at each station (PlumeLook's march on the CPU), plus the
// ambient's in-scatter times the station's response to it (as the march
// lights it), fading across; premultiplied over the scene, hazed by A2's
// air.

struct PlumeVertex {
    float4 position;   // camera-relative world position, w = 1
    float4 color;      // rgb: radiance through the axis (cd/m²), a: opacity
    float4 shape;      // x: across (-1...1), y: along (0 exit ... 1 tail), z: ambient response, w: phase g
};

struct PlumeImpostorOut {
    float4 position [[position]];
    float3 world;
    float4 color;
    float4 shape;
};

vertex PlumeImpostorOut plume_impostor_vertex(uint vid [[vertex_id]],
                                              const device PlumeVertex *verts [[buffer(0)]],
                                              constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]]) {
    PlumeVertex v = verts[vid];
    PlumeImpostorOut o;
    o.position = frame.viewProjection * v.position;
    o.world = v.position.xyz;
    o.color = v.color;
    o.shape = v.shape;
    return o;
}

fragment float4 plume_impostor_fragment(PlumeImpostorOut in [[stage_in]],
                                        constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                        constant AtmosphereUniforms &air [[buffer(ORBIT_BUFFER_ATMOSPHERE)]],
                                        constant LightingUniforms &lighting [[buffer(ORBIT_BUFFER_LIGHTING)]],
                                        constant PlumeFrame &pf [[buffer(0)]],
                                        texture3d<float> froxels [[texture(ORBIT_TEXTURE_AERIAL_PERSPECTIVE)]],
                                        sampler linear [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]]) {
    float x2 = in.shape.x * in.shape.x;
    float across = pow(max(1.0 - x2, 0.0), 1.5);
    float alpha = clamp(in.color.a * across, 0.0, 1.0);
    float3 ambient = plume_sh9InScatter(lighting, normalize(in.world), in.shape.w, pf);
    float3 c = (in.color.rgb + in.shape.z * ambient) * across;
    if (pf.params.y > 0.5) {
        float4 haze = atmo_aerialPerspective(froxels, linear, in.position.xy * frame.viewport.zw, length(in.world), air);
        c = c * haze.a + haze.rgb * alpha;
    }
    c *= frame.exposure.x;
    if (orbit_isNotFinite(c)) { c = float3(0.0); alpha = 0.0; }
    return float4(min(max(c, float3(0.0)), float3(6.0e4)), alpha);
}

// ------------------------------------------------------ the nozzle glow ---
// The SPS extension's draws again, emitting as a grey body at the wall's
// temperature (NozzleGlow): highest at the extension's top, falling as
// r^-0.45 along it, lagged in simulation time; added over the vessel pass's
// shading.

struct PlumeGlowDraw {
    float4x4 model;
    float4 pivot;       // xyz: the nozzle's pivot (part frame), w: the extension's top radius (m)
    float4 direction;   // xyz: its axis (part frame), w: heat fraction
};

struct PlumeGlowOut {
    float4 position [[position]];
    float3 world;
    float radius;
    float heat;
    float top;
};

vertex PlumeGlowOut plume_glow_vertex(uint vid [[vertex_id]],
                                      const device VertexV2 *vertices [[buffer(0)]],
                                      constant PlumeGlowDraw &d [[buffer(1)]],
                                      constant FrameUniforms &f [[buffer(ORBIT_BUFFER_FRAME)]]) {
    VertexV2 v = vertices[vid];
    float3 p = (d.model * float4(v.positionAO.xyz, 1.0)).xyz;
    float3 rel = v.positionAO.xyz - d.pivot.xyz;
    float3 radial = rel - d.direction.xyz * dot(rel, d.direction.xyz);
    PlumeGlowOut o;
    o.position = f.viewProjection * float4(p, 1.0);
    o.world = p;
    o.radius = length(radial);
    o.heat = d.direction.w;
    o.top = d.pivot.w;
    return o;
}

fragment float4 plume_glow_fragment(PlumeGlowOut in [[stage_in]],
                                    constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                    constant AtmosphereUniforms &air [[buffer(ORBIT_BUFFER_ATMOSPHERE)]],
                                    constant PlumeFrame &pf [[buffer(0)]],
                                    texture3d<float> froxels [[texture(ORBIT_TEXTURE_AERIAL_PERSPECTIVE)]],
                                    sampler linear [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]]) {
    // NozzleGlow.temperature: 1,480 K at the top, r^-0.45 down the bell, a
    // radiating wall's T^4 moving with the heat.
    float steady = 1480.0 * pow(max(in.radius, in.top) / max(in.top, 1e-4), -0.45);
    float a4 = 300.0 * 300.0 * 300.0 * 300.0;
    float t = pow(a4 + max(in.heat, 0.0) * (steady * steady * steady * steady - a4), 0.25);
    float3 c = 0.8 * plume_blackbody(t, pf);
    if (pf.params.y > 0.5) {
        float4 haze = atmo_aerialPerspective(froxels, linear, in.position.xy * frame.viewport.zw, length(in.world), air);
        c *= haze.a;
    }
    c *= frame.exposure.x;
    if (orbit_isNotFinite(c)) { c = float3(0.0); }
    return float4(min(max(c, float3(0.0)), float3(6.0e4)), 0.0);
}
"""#

extension ShaderModule {
    public static let plume = ShaderModule(name: "Plume",
                                           headers: [.effectSlots, .atmosphereCommon, .shadowCommon, .cloudShadow,
                                                     .sphericalHarmonics],
                                           source: plumeShaderSource)
}
