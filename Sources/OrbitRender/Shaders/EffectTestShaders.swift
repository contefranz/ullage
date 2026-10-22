// R6's test emitters (track R6 owns this module): stand-ins drawn through
// the effect slots as C2's clouds, P2's plumes and P3's smoke and sparks
// will be. A slab for the clouds layer, a ray-marched cone for the volumes,
// soft sprites through the OIT pair, additive sparks at full resolution, and
// an opaque column and black backdrop in P1. Radiance is in today's
// display-relative scale (1: a white surface facing the Sun), times
// params.x (EffectTestEmitters.radianceScale).
let effectTestShaderSource = #"""
// --------------------------------------------------- effect test emitters ---

struct EffectTestUniforms {
    float4 slabCenter;  // xyz: camera-relative (m), w: extinction (1/m)
    float4 slabEast;    // xyz: unit axis, w: half-extent (m)
    float4 slabNorth;
    float4 slabUp;      // the thin one
    float4 coneApex;    // xyz: camera-relative (m), w: length (m)
    float4 coneAxis;    // xyz: unit, apex to base, w: base radius (m)
    float4 light;       // xyz: unit, camera -> Sun (world), w: the Sun's strength (1 at 1 AU)
    float4 params;      // x: radiance scale (pre-exposure, and R1's E⊙/π on a photometric target), y: slab albedo, z: frame index
};

struct EffectTestOut {
    float4 position [[position]];
};

vertex EffectTestOut effect_test_fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    EffectTestOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// Interleaved gradient noise (Jimenez 2014), turned each frame.
inline float effect_test_noise(float2 p, float frame) {
    p += 5.588238 * fmod(frame, 64.0);
    return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715))));
}

// Henyey-Greenstein, normalised over the sphere.
inline float effect_test_phase(float cosTheta, float g) {
    float d = 1.0 + g * g - 2.0 * g * cosTheta;
    return (1.0 - g * g) / (4.0 * M_PI_F * d * sqrt(d));
}

// Where a ray from p along d leaves a box of half-extents h about the
// origin (box axes); +large if it never does.
inline float effect_test_boxExit(float3 p, float3 d, float3 h) {
    float t = 1e30;
    for (int i = 0; i < 3; i++) {
        if (abs(d[i]) > 1e-9) { t = min(t, ((d[i] > 0.0 ? h[i] : -h[i]) - p[i]) / d[i]); }
    }
    return max(t, 0.0);
}

// ------------------------------------------------------------- the slab ---
// A lit homogeneous box, analytic: transmittance, single scattering of the
// Sun through the slab above the segment's middle (HG, g = 0.6) and a sky
// ambient; its front where it becomes visible (EffectSlots.frontReached).
fragment EffectCloudOut effect_test_slab_fragment(EffectTestOut in [[stage_in]],
                                                  constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                                  constant EffectSlotUniforms &e [[buffer(ORBIT_EFFECT_BUFFER_SLOTS)]],
                                                  constant EffectTestUniforms &u [[buffer(0)]],
                                                  texture2d<float> halfResDepth [[texture(ORBIT_EFFECT_TEXTURE_HALFRES_DEPTH)]]) {
    uint2 texel = uint2(in.position.xy);
    float3 dir = (frame.viewToWorld * float4(orbit_effectViewRay(in.position.xy, e, frame), 0.0)).xyz;
    float3 ex = u.slabEast.xyz, ny = u.slabNorth.xyz, uz = u.slabUp.xyz;
    float3 h = float3(u.slabEast.w, u.slabNorth.w, u.slabUp.w);
    float3 o = -u.slabCenter.xyz;
    float3 ob = float3(dot(o, ex), dot(o, ny), dot(o, uz)), db = float3(dot(dir, ex), dot(dir, ny), dot(dir, uz));
    float enter = 0.0, exit = 1e30;
    for (int i = 0; i < 3; i++) {
        if (abs(db[i]) > 1e-9) {
            float t0 = (-h[i] - ob[i]) / db[i], t1 = (h[i] - ob[i]) / db[i];
            enter = max(enter, min(t0, t1));
            exit = min(exit, max(t0, t1));
        } else if (abs(ob[i]) > h[i]) {
            discard_fragment();
        }
    }
    exit = min(exit, orbit_effectSceneDistance(texel, halfResDepth, frame));
    if (exit <= enter) { discard_fragment(); }
    float len = length(dir), sigma = u.slabCenter.w;
    float transmittance = exp(-sigma * (exit - enter) * len);
    float3 L = u.light.xyz;
    float3 mid = ob + 0.5 * (enter + exit) * db;
    float tauSun = sigma * effect_test_boxExit(mid, float3(dot(L, ex), dot(L, ny), dot(L, uz)), h);
    float sun = M_PI_F * u.light.w * effect_test_phase(dot(dir / len, L), 0.6) * exp(-tauSun);
    float3 radiance = u.params.y * (float3(sun) + float3(0.12, 0.14, 0.18));
    EffectCloudOut out;
    float coverage = 1.0 - transmittance;
    out.color = float4(radiance * coverage * u.params.x, coverage);
    // Where it becomes visible: by coverage, or by radiance (its source
    // times the coverage), whichever first (EffectSlots.homogeneousFront).
    float3 source = radiance * u.params.x;
    float brightest = max(source.r, max(source.g, source.b));
    float visible = brightest > 0.0 ? min(e.front.x, e.front.z / brightest) : e.front.x;
    float front = enter - log(1.0 - visible) / (sigma * len);
    out.front = float4(front <= exit ? orbit_frontCode(front) : ORBIT_EFFECT_NO_FRONT);
    return out;
}

// ------------------------------------------------------------- the cone ---
// The back faces of the cone's proxy (circumscribed, so every texel whose
// ray meets the cone is covered); the fragment intersects the ray with the
// cone, clamps the exit at the scene, and marches 24 jittered steps of an
// emissive, slightly absorbing medium, hot at the apex with a few shock
// cells, cooling along the axis. Energy-conserving steps (Hillaire 2015). Its
// front is the first step where it becomes visible (orbit_frontReached).
struct EffectTestConeOut {
    float4 position [[position]];
};

vertex EffectTestConeOut effect_test_cone_vertex(uint vid [[vertex_id]],
                                                 const device float4 *verts [[buffer(1)]],
                                                 constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]]) {
    EffectTestConeOut o;
    o.position = frame.viewProjection * verts[vid];
    return o;
}

fragment EffectVolumeOut effect_test_cone_fragment(EffectTestConeOut in [[stage_in]],
                                                   constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                                   constant EffectSlotUniforms &e [[buffer(ORBIT_EFFECT_BUFFER_SLOTS)]],
                                                   constant EffectTestUniforms &u [[buffer(0)]],
                                                   texture2d<float> halfResDepth [[texture(ORBIT_EFFECT_TEXTURE_HALFRES_DEPTH)]]) {
    uint2 texel = uint2(in.position.xy);
    float3 dir = (frame.viewToWorld * float4(orbit_effectViewRay(in.position.xy, e, frame), 0.0)).xyz;
    float3 apex = u.coneApex.xyz, axis = u.coneAxis.xyz;
    float length_ = u.coneApex.w, radius = u.coneAxis.w;
    float k = radius / length_, c2 = 1.0 / (1.0 + k * k);
    // x(s) = cv + s dv along the axis; inside where x^2 - c2 |v|^2 >= 0 and 0 <= x <= length.
    float3 co = -apex;
    float dv = dot(dir, axis), cv = dot(co, axis);
    float A = dv * dv - c2 * dot(dir, dir), B = 2.0 * (dv * cv - c2 * dot(dir, co)), C = cv * cv - c2 * dot(co, co);
    float lo = 0.0, hi = 1e30;
    if (abs(dv) > 1e-9) {
        float s0 = -cv / dv, s1 = (length_ - cv) / dv;
        lo = max(lo, min(s0, s1));
        hi = min(hi, max(s0, s1));
    } else if (cv < 0.0 || cv > length_) {
        discard_fragment();
    }
    if (hi <= lo) { discard_fragment(); }
    float cut[4] = {lo, hi, hi, hi};
    int n = 1;
    float disc = B * B - 4.0 * A * C;
    if (abs(A) > 1e-9 && disc > 0.0) {
        float q = sqrt(disc), r0 = (-B - q) / (2.0 * A), r1 = (-B + q) / (2.0 * A);
        float a0 = min(r0, r1), a1 = max(r0, r1);
        if (a0 > lo && a0 < hi) { cut[n++] = a0; }
        if (a1 > lo && a1 < hi) { cut[n++] = a1; }
    } else if (abs(A) <= 1e-9 && abs(B) > 1e-9) {
        float r = -C / B;
        if (r > lo && r < hi) { cut[n++] = r; }
    }
    cut[n++] = hi;
    float enter = -1.0, exit = -1.0;
    for (int i = 0; i + 1 < n; i++) {
        float m = 0.5 * (cut[i] + cut[i + 1]);
        if (A * m * m + B * m + C >= 0.0 && cv + m * dv >= 0.0) {
            if (enter < 0.0) { enter = cut[i]; }
            exit = cut[i + 1];
        }
    }
    if (enter < 0.0) { discard_fragment(); }
    exit = min(exit, orbit_effectSceneDistance(texel, halfResDepth, frame));
    if (exit <= enter) { discard_fragment(); }

    const int steps = 24;
    float len = length(dir), ds = (exit - enter) / float(steps);
    float jitter = effect_test_noise(in.position.xy, u.params.z);
    float transmittance = 1.0, front = ORBIT_EFFECT_NO_FRONT;
    float3 radiance = float3(0.0);
    for (int i = 0; i < steps; i++) {
        float s = enter + (float(i) + jitter) * ds;
        float3 v = s * dir - apex;
        float x = dot(v, axis);
        float xi = clamp(x / length_, 0.0, 1.0);
        float r = length(v - x * axis), rx = max(x * k, 1e-3);
        float density = exp(-3.0 * (r / rx) * (r / rx)) * pow(1.0 - xi, 1.5) * (1.0 - exp(-xi * 40.0));
        // Shock cells near the exit, fading downstream.
        float cells = 1.0 + 0.6 * cos(2.0 * M_PI_F * xi / 0.09) * exp(-5.0 * xi);
        float3 emission = mix(float3(1.0, 0.9, 0.7) * 9.0, float3(1.0, 0.42, 0.1) * 2.0, sqrt(xi)) * cells;
        float sigma = density * 0.5 / radius;
        float3 j = density * emission / radius;
        float dtau = sigma * ds * len;
        float stepT = exp(-dtau);
        radiance += transmittance * (sigma > 1e-6 ? j / sigma * (1.0 - stepT) : j * ds * len);
        transmittance *= stepT;
        if (front >= ORBIT_EFFECT_NO_FRONT && orbit_frontReached(1.0 - transmittance, radiance * u.params.x, e)) {
            front = orbit_frontCode(s);
        }
        if (transmittance < 0.01) { break; }
    }
    EffectVolumeOut out;
    out.color = float4(radiance * u.params.x, 1.0 - transmittance);
    out.front = float4(front);
    return out;
}

// ---------------------------------------------------------- the sprites ---
// Camera-facing soft discs through the OIT pair, depth-tested at half
// resolution, fading into the scene over half their radius, lit by the Sun
// on a puffed normal.
struct EffectTestSprite {
    float4 centerRadius;  // xyz: camera-relative (m), w: radius (m)
    float4 colorAlpha;    // rgb: linear colour, w: peak opacity
};

struct EffectTestSpriteOut {
    float4 position [[position]];
    float2 corner;
    float viewDepth;
    float radius;
    float4 color;
};

vertex EffectTestSpriteOut effect_test_sprite_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                                     const device EffectTestSprite *sprites [[buffer(1)]],
                                                     constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]]) {
    float2 corners[6] = {float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1)};
    EffectTestSprite s = sprites[iid];
    float2 c = corners[vid];
    float3 centre = (frame.view * float4(s.centerRadius.xyz, 0.0)).xyz;
    float3 p = centre + float3(c * s.centerRadius.w, 0.0);
    EffectTestSpriteOut o;
    o.position = frame.projection * float4(p, 1.0);
    o.corner = c;
    o.viewDepth = -p.z;
    o.radius = s.centerRadius.w;
    o.color = s.colorAlpha;
    return o;
}

fragment EffectOITOut effect_test_sprite_fragment(EffectTestSpriteOut in [[stage_in]],
                                                  constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                                  constant EffectSlotUniforms &e [[buffer(ORBIT_EFFECT_BUFFER_SLOTS)]],
                                                  constant EffectTestUniforms &u [[buffer(0)]],
                                                  texture2d<float> halfResDepth [[texture(ORBIT_EFFECT_TEXTURE_HALFRES_DEPTH)]]) {
    float r2 = dot(in.corner, in.corner);
    if (r2 > 1.0) { discard_fragment(); }
    float scene = orbit_effectSceneDistance(uint2(in.position.xy), halfResDepth, frame);
    float fade = clamp((scene - in.viewDepth) / (0.5 * in.radius), 0.0, 1.0);
    float alpha = in.color.a * exp(-3.0 * r2) * fade;
    float3 n = (frame.viewToWorld * float4(in.corner, sqrt(max(1.0 - r2, 0.0)), 0.0)).xyz;
    float lit = 0.3 + 0.7 * u.light.w * clamp(dot(n, u.light.xyz) * 0.5 + 0.5, 0.0, 1.0);
    float3 c = in.color.rgb * lit * u.params.x;
    return orbit_oitOutput(float4(c * alpha, alpha), in.viewDepth, e);
}

// ----------------------------------------------------------- the sparks ---
// Additive streaks at full resolution, after the composite, tested against
// the scene's depth.
struct EffectTestSpark {
    float4 start;   // xyz: camera-relative (m), w: width (m)
    float4 end;     // xyz
    float4 color;   // rgb: linear colour
};

struct EffectTestSparkOut {
    float4 position [[position]];
    float2 uv;      // x: across (-1...1), y: along (0 start ... 1 end)
    float3 color;
};

vertex EffectTestSparkOut effect_test_spark_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                                   const device EffectTestSpark *sparks [[buffer(1)]],
                                                   constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]]) {
    float2 corners[6] = {float2(-1, 0), float2(1, 0), float2(-1, 1), float2(1, 0), float2(1, 1), float2(-1, 1)};
    EffectTestSpark s = sparks[iid];
    float2 c = corners[vid];
    float3 a = s.start.xyz, b = s.end.xyz;
    float3 side = cross(b - a, 0.5 * (a + b));
    side = length(side) > 0.0 ? normalize(side) * 0.5 * s.start.w : float3(0.0);
    float3 p = mix(a, b, c.y) + c.x * side;
    EffectTestSparkOut o;
    o.position = frame.viewProjection * float4(p, 1.0);
    o.uv = c;
    o.color = s.color.rgb;
    return o;
}

fragment float4 effect_test_spark_fragment(EffectTestSparkOut in [[stage_in]],
                                           constant EffectTestUniforms &u [[buffer(0)]]) {
    float across = 1.0 - abs(in.uv.x);
    float3 c = in.color * 4.0 * across * across * (0.3 + 0.7 * (1.0 - in.uv.y));
    return float4(c * u.params.x, 0.0);
}

// -------------------------------------------------- the opaque stand-ins ---
// P1: a grey column, Lambert-lit by the Sun, and a black backdrop at
// infinity that wipes the opaque scene for look-dev shots.
struct EffectTestColumnVertex {
    float4 position;  // xyz: camera-relative (m)
    float4 normal;    // xyz: unit (world)
};

struct EffectTestColumnOut {
    float4 position [[position]];
    float3 normal;
};

vertex EffectTestColumnOut effect_test_column_vertex(uint vid [[vertex_id]],
                                                     const device EffectTestColumnVertex *verts [[buffer(1)]],
                                                     constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]]) {
    EffectTestColumnOut o;
    o.position = frame.viewProjection * float4(verts[vid].position.xyz, 1.0);
    o.normal = verts[vid].normal.xyz;
    return o;
}

// Linear light times the scale, as every scene pass writes it (the target
// plan weights the samples for its resolve itself).
inline float4 effect_test_opaque(float3 c, constant EffectTestUniforms &u) {
    return float4(c * u.params.x, 1.0);
}

fragment float4 effect_test_column_fragment(EffectTestColumnOut in [[stage_in]],
                                            constant EffectTestUniforms &u [[buffer(0)]]) {
    float lambert = max(dot(normalize(in.normal), u.light.xyz), 0.0) * u.light.w;
    return effect_test_opaque(float3(0.35, 0.34, 0.32) * (0.08 + lambert), u);
}

struct EffectTestBackdropOut {
    float4 color [[color(0)]];
    float depth [[depth(any)]];
};

fragment EffectTestBackdropOut effect_test_backdrop_fragment(EffectTestOut in [[stage_in]]) {
    EffectTestBackdropOut o;
    o.color = float4(0.0, 0.0, 0.0, 1.0);
    o.depth = 0.0;
    return o;
}
"""#

extension ShaderModule {
    public static let effectTest = ShaderModule(name: "EffectTest", headers: [.effectSlots], source: effectTestShaderSource)
}
