// LR5's exhaust trail (track P4 owns this module): the S-IC's trail as
// Gaussian media (`TrailColumn`'s nodes, merged far off: `TrailChain.lod`),
// drawn into R6's volumes layer at half resolution. Each medium is an
// instanced 3σ box, back faces only (the camera inside too); its fragment
// shades the chord the box cuts from the ray in closed form, through the
// header's segments (GaussianMediumCommon: one source each at its shading
// depth), lit by the Sun through the trail's own line (the Sun's chord
// across the column through the point, analytic), C2's cloud shadow and
// the ambient (R3's SH9, or the stand-in), with C2's two-stream; A2's air
// in front of it. The Swift side is Passes/TrailPass.swift.
let trailShaderSource = #"""
// ---------------------------------------------------------------- trail ---

struct TrailFrame {
    float4 sun;       // xyz: unit to the Sun (world), w: 1 lit
    float4 sunLight;  // rgb: the Sun's lux at the trail (A2's at the camera), w: 1 with C2's cloud shadow
    float4 ambient;   // rgb: the ambient where R3's probe is not drawn (cd/m2, not pre-exposed)
    float4 params;    // x: 1 with aerial perspective, z: the line's sigma along for its shadows (m)
};

struct TrailBoxOut {
    float4 position [[position]];
    uint item [[flat]];
};

// A unit cube's 36 corners, two triangles a face, counter-clockwise seen
// from outside.
constant float3 trail_cube[36] = {
    float3(-1, -1,  1), float3( 1, -1,  1), float3( 1,  1,  1), float3(-1, -1,  1), float3( 1,  1,  1), float3(-1,  1,  1),
    float3( 1, -1, -1), float3(-1, -1, -1), float3(-1,  1, -1), float3( 1, -1, -1), float3(-1,  1, -1), float3( 1,  1, -1),
    float3(-1, -1, -1), float3(-1, -1,  1), float3(-1,  1,  1), float3(-1, -1, -1), float3(-1,  1,  1), float3(-1,  1, -1),
    float3( 1, -1,  1), float3( 1, -1, -1), float3( 1,  1, -1), float3( 1, -1,  1), float3( 1,  1, -1), float3( 1,  1,  1),
    float3(-1,  1,  1), float3( 1,  1,  1), float3( 1,  1, -1), float3(-1,  1,  1), float3( 1,  1, -1), float3(-1,  1, -1),
    float3(-1, -1, -1), float3( 1, -1, -1), float3( 1, -1,  1), float3(-1, -1, -1), float3( 1, -1,  1), float3(-1, -1,  1),
};

vertex TrailBoxOut trail_box_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                    const device GaussianMedium *media [[buffer(1)]],
                                    constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]]) {
    GaussianMedium g = media[iid];
    float3 c = trail_cube[vid] * ORBIT_GAUSSIAN_EXTENT;
    float3 p = g.centre.xyz + g.axisU.xyz * (c.x * g.axisU.w) + g.axisV.xyz * (c.y * g.axisV.w)
        + g.axisW.xyz * (c.z * g.axisW.w);
    TrailBoxOut o;
    o.position = frame.viewProjection * float4(p, 1.0);
    o.item = iid;
    return o;
}

// The trail's line through a medium, for its shadows: as long as the
// line (sigma along params.z), its peak the line's at its centre
// (`linePeak`, C / (2 pi sigma_v sigma_w): TrailChain.Drawn.linePeak), so
// that a chord across it is the column's depth there, its neighbours' too.
inline GaussianMedium trail_line(GaussianMedium g, float linePeak, constant TrailFrame &tf) {
    GaussianMedium l = g;
    l.centre.w = linePeak;
    l.axisU.w = max(tf.params.z, g.axisU.w);
    return l;
}

fragment EffectVolumeOut trail_box_fragment(TrailBoxOut in [[stage_in]],
                                            constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                            constant EffectSlotUniforms &e [[buffer(ORBIT_EFFECT_BUFFER_SLOTS)]],
                                            constant AtmosphereUniforms &air [[buffer(ORBIT_BUFFER_ATMOSPHERE)]],
                                            constant LightingUniforms &lighting [[buffer(ORBIT_BUFFER_LIGHTING)]],
                                            constant TrailFrame &tf [[buffer(0)]],
                                            const device GaussianMedium *media [[buffer(1)]],
                                            const device float *linePeaks [[buffer(2)]],
                                            texture2d<float> halfResDepth [[texture(ORBIT_EFFECT_TEXTURE_HALFRES_DEPTH)]],
                                            texture2d<float> cloudShadow [[texture(ORBIT_TEXTURE_CLOUD_SHADOW)]],
                                            texture3d<float> froxels [[texture(ORBIT_TEXTURE_AERIAL_PERSPECTIVE)]],
                                            sampler linear [[sampler(ORBIT_SAMPLER_LINEAR_CLAMP)]]) {
    uint2 texel = uint2(in.position.xy);
    GaussianMedium g = media[in.item];
    // The view ray: a point s along `view` is s metres deep; t along the
    // unit d is t / len deep.
    float3 view = (frame.viewToWorld * float4(orbit_effectViewRay(in.position.xy, e, frame), 0.0)).xyz;
    float len = length(view);
    float3 d = view / len;
    float2 box = orbit_gaussianBox(g, float3(0.0), d);
    float scene = orbit_effectSceneDistance(texel, halfResDepth, frame);
    float sceneT = scene >= ORBIT_EFFECT_SKY_DISTANCE ? 1e30 : scene * len;
    float t0 = max(box.x, 0.0), far = box.y;
    bool cut = sceneT < far;
    float t1 = min(far, sceneT);
    EffectVolumeOut out;
    if (t1 <= t0) {
        // Hidden by the scene: drawn, so that a texel beside it whose scene
        // lies behind does not take its emptiness.
        out.color = float4(0.0);
        out.front = float4(ORBIT_EFFECT_NO_FRONT, ORBIT_EFFECT_NO_FRONT, ORBIT_EFFECT_NO_FRONT, orbit_backCode(0.0, true));
        return out;
    }
    GaussianRay r = orbit_gaussianRay(g, d * t0, d);
    float span = t1 - t0, depth = orbit_gaussianDepth(r, 0.0, span);
    // A chord too faint to show (its corners' 2e-3 of the smoke's own
    // light), unless the scene cuts it.
    if (depth < 2e-3 && !cut) { discard_fragment(); }

    // The light, the same over the box: the Sun (with C2's cloud shadow at
    // the chord's middle) and the ambient by the smoke's phase.
    float3 sun = tf.sun.xyz, sunLux = tf.sun.w > 0.5 ? tf.sunLight.rgb : float3(0.0);
    if (tf.sunLight.w > 0.5 && tf.sun.w > 0.5) {
        sunLux *= orbit_cloudSunTransmittance(d * (0.5 * (t0 + t1)), air, cloudShadow, linear);
    }
    float3 albedo = g.optics.rgb;
    float asymmetry = g.optics.w;
    SmokeAmbient amb = orbit_smokeAmbient(lighting, d, asymmetry, tf.ambient.rgb);
    GaussianMedium line = trail_line(g, linePeaks[in.item], tf);
    float exposure = frame.exposure.x;

    // The segments by their depths from the entry (the header's boundaries),
    // each shaded at its source's depth: one inverse each for its far end
    // and its source, the depths themselves known.
    int n = orbit_gaussianSegments(depth);
    float transmittance = 1.0, front = ORBIT_EFFECT_NO_FRONT, lastVisible = 0.0, weighted = 0.0, weights = 0.0;
    float3 radiance = float3(0.0);
    float a = 0.0, depthA = 0.0;
    for (int k = 1; k <= n; k++) {
        float depthB = orbit_gaussianSegmentBoundary(k, n, depth);
        float b = k == n ? span : clamp(orbit_gaussianTimeAtDepth(r, 0.0, depthB), a, span);
        float dtau = max(depthB - depthA, 0.0);
        float ts = clamp(orbit_gaussianTimeAtDepth(r, 0.0, depthA + orbit_gaussianShadingDepth(dtau)), a, b);
        float3 p = d * (t0 + ts);
        // The Sun's chord through the line at p, and its depth from p.
        GaussianRay sr = orbit_gaussianRay(line, p, sun);
        SmokeLight l;
        l.sun = sunLux;
        l.ambient = amb.inScatter;
        l.ambientUp = amb.up;
        l.ambientDown = amb.down;
        l.cosView = dot(d, sun);
        l.cosAxis = dot(d, amb.axis);
        l.sunChord = orbit_gaussianTotal(sr);
        l.sunDepth = orbit_gaussianDepth(sr, 0.0, sr.centre + 10.0 * sr.width + abs(sr.centre));
        float2 column = orbit_gaussianAmbientColumn(line, p, amb.axis);
        l.ambientDepth = column.x;
        l.ambientChord = column.y;
        float3 j = orbit_smokeSource(albedo, asymmetry, l);
        float4 lit = orbit_gaussianLight(j, dtau);
        float3 added = transmittance * lit.rgb;
        float covered = transmittance * lit.a;
        if (covered >= 1.0 / 4096.0 || max(added.r, max(added.g, added.b)) * exposure >= e.front.z / 16.0) {
            lastVisible = (t0 + b) / len;
        }
        radiance += added;
        weighted += covered * (t0 + ts);
        weights += covered;
        transmittance *= 1.0 - lit.a;
        if (front >= ORBIT_EFFECT_NO_FRONT && orbit_frontReached(1.0 - transmittance, radiance * exposure, e)) {
            front = orbit_frontCode((t0 + ts) / len);
        }
        a = b;
        depthA = depthB;
    }
    if (transmittance < 0.01) { cut = false; }
    float coverage = 1.0 - transmittance;
    // A2's air in front of it.
    if (tf.params.x > 0.5 && weights > 0.0) {
        float4 haze = atmo_aerialPerspective(froxels, linear, in.position.xy * e.target.zw, weighted / weights, air);
        radiance = radiance * haze.a + haze.rgb * coverage;
    }
    float3 color = radiance * exposure;
    if (orbit_isNotFinite(color) || orbit_isNotFinite(coverage)) {
        color = float3(0.0);
        coverage = 0.0;
    }
    out.color = float4(orbit_effectRadiance(max(color, float3(0.0))), clamp(coverage, 0.0, 1.0));
    out.front = float4(front, front, front, orbit_backCode(lastVisible, cut));
    return out;
}
"""#

extension ShaderModule {
    /// LR5's exhaust trail (TrailPass).
    public static let trail = ShaderModule(name: "Trail",
                                           headers: [.effectSlots, .atmosphereCommon, .shadowCommon, .cloudShadow,
                                                     .sphericalHarmonics, .gaussianMedium],
                                           source: trailShaderSource)
}
