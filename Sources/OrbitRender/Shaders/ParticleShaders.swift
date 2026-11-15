// GPU particles (track P3 owns this module): the emit, simulate and compact
// kernels, the three render classes (additive streaks at full resolution,
// smoke through R6's OIT layer, chunks in the opaque pass), the volume
// noise, and the self-test's golden kernels. The physics mirrors OrbitCore's
// ParticlePhysics and ParticleKinematics, and the sampling OrbitScene's
// EmitSampler, line for line; ParticleSystem.swift and EffectAnchors.swift
// hold the Swift mirrors of the structs. Radiance is linear light (cd/m²)
// times FrameUniforms.exposure.x, held below 6e4 (R1's rule).
let particleShaderSource = #"""
// ---------------------------------------------------------- particles ---

struct Particle {
    float4 positionRadius;   // xyz: relative to its anchor (m, anchor axes), w: radius (m)
    float4 velocityAge;      // xyz: relative to its anchor (m/s), w: age (s)
    packed_float3 state;     // x: lifetime (s), y: temperature (K), z: spawn radius (m)
    uint packed;             // bits 0-5 material, 6-13 anchor, 14-15 frames shown past its lifetime, 16-31 look seed
};

struct ParticleMaterial {
    float4 albedo;           // rgb, w: render class (0 streak, 1 smoke, 2 chunk)
    float4 emission;         // rgb: cd/m², w: the temperature it is given at (K; 0: fixed)
    float4 look;             // x: optical depth at spawn, y: HG g, z: fade in, w: fade out (lifetime fractions)
    float4 motion;           // x: density (kg/m³; 0 gas parcel), y: Cd, z: buoyancy, w: entrainment α
    float4 thermal;          // x: spread rate (m/s), y: cooling time (s; < 0 none), z: 1 sublimates, w: flags (1 flash, 2 killed at ground)
    float4 shape;            // x: streak time (s), y: chunk shape (0 plate, 1 tetrahedron), z: chunk aspect, w: spin (rad/s)
};

struct ParticleAnchor {
    float4 origin;           // xyz: camera-relative (m), w: 1 live, 2 live and lit by the Sun above any air (the studio)
    float4 toWorld0;         // anchor axes to world, columns; w: 1 when it falls freely (at `gravity`)
    float4 toWorld1;
    float4 toWorld2;
    float4 up;               // xyz: unit (anchor axes), w: the origin's altitude (m)
    float4 east;             // xyz: unit, w: the ground's altitude (m)
    float4 north;            // xyz: unit, w: the body's radius (m)
    float4 gravity;          // xyz: the body's gravity at the origin (m/s², anchor axes), w: air profile (-1: vacuum)
    float4 air;              // xyz: the air's velocity at the origin less the wind (m/s), w: sunlit fraction
    float4 rotation;         // xyz: the body's rotation (rad/s; free fall only), w: ice's temperature in vacuum (K)
};

struct ParticleRequest {
    float4 origin;           // xyz: the source now (anchor axes, m), w: shape (0 point, 1 ball, 2 sphere, 3 disc, 4 ring, 5 band, 6 line)
    float4 axis;             // xyz: unit, w: shape's first parameter (m)
    float4 shape;            // x: shape's second parameter (m), y: 1 radial, z: spread (rad), w: temperature (K; 0 the air's)
    float4 speed;            // xy: speed range (m/s), zw: radius range (m)
    float4 velocity;         // xyz: added (m/s), w: lifetime's lower bound (s)
    float4 sourceVelocity;   // xyz, w: lifetime's upper bound (s)
    float4 sourceAcceleration; // xyz, w: ages' lower bound (s)
    float4 ages;             // x: ages' upper bound (s), y: count
    uint4 ids;               // x: material, y: anchor, z: seed, w: its first particle's index among the frame's
};

struct ParticleFrame {
    float4 time;             // x: dt (s), y: turbulence time (s), z: 1 holds flashes, w: 1 advances
    uint4 counts;            // x: capacity, y: particles to emit, z: requests, w: the current alive list (0 or 1)
    uint4 limits;            // x: chunks drawn at most, y: substeps at most, z: anchors
    float4 view;             // x: 1 culls against the frame's view (FrameUniforms), y: pixels per radian at the effect
                             // targets, z: the smoke's overdraw budget (effect texels), w: the effect targets' texels
    float4 noise;            // xyz: the volume noise's drift on the turbulence clock (tiles, EffectTimeRules.noiseDrift)
};

#define PARTICLE_COUNTER_FREE 0
#define PARTICLE_COUNTER_ALIVE 1      // + list
#define PARTICLE_COUNTER_DRAW 3       // + render class
#define PARTICLE_COUNTER_EMITTED 6
#define PARTICLE_COUNTER_DROPPED 7
#define PARTICLE_COUNTER_SMOKE_AREA 8  // the drawn puffs' area at the effect targets, in 256 texels
#define PARTICLE_COUNTER_SMOKE_KEEP 9  // the share of puffs drawn, × 2^24 (the overdraw budget's thinning)
#define PARTICLE_COUNTERS 10
#define PARTICLE_KEEP_ONE 16777216.0
#define PARTICLE_CLASS_STREAK 0
#define PARTICLE_CLASS_SMOKE 1
#define PARTICLE_CLASS_CHUNK 2
#define PARTICLE_FLAG_FLASH 1u
#define PARTICLE_FLAG_GROUND 2u
#define PARTICLE_NO_DRAG 1e30
#define PARTICLE_AIR_LEVELS 64
#define PARTICLE_AIR_TOP 100000.0
#define PARTICLE_VACUUM_TEMPERATURE 3.0
#define PARTICLE_FLASH_HOLD_FRAMES 3u
#define PARTICLE_ADIABATIC 0.2857             // R / cp of dry air
#define PARTICLE_EXPANSION 0.4                // γ - 1 of a cloud spreading into vacuum
#define PARTICLE_STREAK_MIN_PIXELS 3.0        // a streak's least width

inline uint particle_materialIndex(uint p) { return p & 63u; }
inline uint particle_anchorIndex(uint p) { return (p >> 6) & 255u; }
inline uint particle_shown(uint p) { return (p >> 14) & 3u; }
inline uint particle_lookSeed(uint p) { return p >> 16; }
inline uint particle_pack(uint m, uint a, uint shown, uint seed) {
    return (m & 63u) | ((a & 255u) << 6) | ((min(shown, 3u) & 3u) << 14) | ((seed & 0xffffu) << 16);
}

// ------------------------------------------------------------ physics ---
// ParticlePhysics and ParticleKinematics in Float.

struct ParticleAir {
    float density;           // kg/m³
    float temperature;       // K
    float pressure;          // Pa
    float3 velocity;         // m/s, anchor axes
};

struct ParticleState {
    float3 position;
    float3 velocity;
    float radius;
    float temperature;
};

inline ParticleAir particle_vacuum() {
    ParticleAir a;
    a.density = 0.0;
    a.temperature = PARTICLE_VACUUM_TEMPERATURE;
    a.pressure = 0.0;
    a.velocity = float3(0.0);
    return a;
}

// (1 - e^-s)/s and (s - 1 + e^-s)/s², by their series where s is small.
inline float2 particle_phi(float s) {
    if (s < 0.05) {
        float one = 1.0 - s * (0.5 - s * (1.0 / 6.0 - s * (1.0 / 24.0 - s / 120.0)));
        float two = 0.5 - s * (1.0 / 6.0 - s * (1.0 / 24.0 - s * (1.0 / 120.0 - s / 720.0)));
        return float2(one, two);
    }
    float one = (1.0 - exp(-s)) / s;
    return float2(one, (1.0 - one) / s);
}

// P1's exact linear-drag step (ParticleKinematics.step); tau PARTICLE_NO_DRAG is ballistic.
inline void particle_step(thread float3 &x, thread float3 &v, float3 air, float3 g, float tau, float dt) {
    float s = dt / max(tau, 1e-9);
    float2 p = particle_phi(s);
    float decay = exp(-s);
    float3 slip = v - air;
    float3 nv = air + slip * decay + g * (dt * p.x);
    x = x + air * dt + slip * (dt * p.x) + g * (dt * dt * p.y);
    v = nv;
}

inline float particle_tau(device const ParticleMaterial &m, float r, float t, ParticleAir a, float speed) {
    if (a.density <= 0.0 || speed <= 0.0 || m.motion.y <= 0.0) { return PARTICLE_NO_DRAG; }
    float ratio = m.motion.x > 0.0 ? m.motion.x / a.density : a.temperature / max(t, 1.0);
    return 8.0 * ratio * r / (3.0 * m.motion.y * speed);
}

inline float particle_terminalTime(device const ParticleMaterial &m, float r, float t, ParticleAir a, float g) {
    if (a.density <= 0.0 || g <= 0.0 || m.motion.y <= 0.0) { return PARTICLE_NO_DRAG; }
    float ratio = m.motion.x > 0.0 ? m.motion.x / a.density : a.temperature / max(t, 1.0);
    return sqrt(8.0 * ratio * r / (3.0 * m.motion.y * g));
}

inline float3 particle_effectiveGravity(device const ParticleMaterial &m, float t, ParticleAir a, float3 g) {
    if (a.density <= 0.0 || m.motion.z == 0.0) { return g; }
    float rho = m.motion.x > 0.0 ? m.motion.x : a.density * a.temperature / max(t, 1.0);
    return g * (1.0 - m.motion.z * a.density / max(rho, 1e-12));
}

// Murphy and Koop's vapour pressure over ice (Pa) and Hertz-Knudsen with
// diffusion in series, solved exactly over the step (ParticlePhysics.sublimatedRadius).
inline float particle_sublimatedRadius(float r, float dt, float ts, ParticleAir a) {
    if (r <= 0.0) { return 0.0; }
    const float r0 = 461.5233;              // R / M of water, J/(kg K)
    float pv = exp(9.550426 - 5723.265 / ts + 3.53068 * log(ts) - 0.00728332 * ts);
    float excess = pv / (r0 * ts);
    float k = sqrt(r0 * ts / (2.0 * M_PI_F));
    float invD = a.pressure > 0.0 ? a.pressure / (2.11e-5 * pow(max(a.temperature, 1.0) / 273.15, 1.94) * 101325.0) : 0.0;
    float invK = 1.0 / k;
    float f = r * invK + 0.5 * r * r * invD - excess * dt / 917.0;
    if (f <= 0.0) { return 0.0; }
    return 2.0 * f / (invK + sqrt(invK * invK + 2.0 * f * invD));
}

// ParticlePhysics.grown: entrainment and spreading; the gas mixed as an ideal
// gas at the air's pressure (r³ (1 - Ta/T) kept), or cooled adiabatically
// spreading into vacuum; then relaxed to the air's temperature.
inline float2 particle_grown(ParticleState s, device const ParticleMaterial &m, ParticleAir a, float h, float path) {
    bool vacuum = a.density <= 0.0;
    float radius = s.radius + (vacuum ? 0.0 : m.motion.w * path) + m.thermal.x * h;
    float ambient = vacuum ? PARTICLE_VACUUM_TEMPERATURE : a.temperature;
    float t = s.temperature;
    if (radius > s.radius && s.radius > 0.0 && t > 0.0) {
        float q = s.radius / radius, q3 = q * q * q;
        t = vacuum ? t * pow(q3, PARTICLE_EXPANSION) : ambient / (1.0 - q3 * (1.0 - ambient / t));
    }
    if (m.thermal.y >= 0.0) { t = ambient + (t - ambient) * (m.thermal.y > 0.0 ? exp(-h / m.thermal.y) : 0.0); }
    return float2(radius, t);
}

// ParticlePhysics.airMotion: the air's velocity at time t from the frame's
// epoch, and its acceleration (-the frame's), zero in vacuum.
inline void particle_airMotion(ParticleAir a, float3 frameAcceleration, float t, thread float3 &u, thread float3 &c) {
    if (a.density <= 0.0) {
        u = float3(0.0);
        c = float3(0.0);
        return;
    }
    u = a.velocity - frameAcceleration * t;
    c = -frameAcceleration;
}

// ParticlePhysics.slipGravity.
inline float3 particle_slipGravity(device const ParticleMaterial &m, float t, ParticleAir a, float3 g,
                                   float3 frameAcceleration) {
    return a.density <= 0.0 ? g - frameAcceleration : particle_effectiveGravity(m, t, a, g);
}

inline float particle_shortest(ParticleState s, device const ParticleMaterial &m, float3 g, float3 frameAcceleration,
                               ParticleAir a, float t) {
    float3 u, c;
    particle_airMotion(a, frameAcceleration, t, u, c);
    float gs = length(particle_slipGravity(m, s.temperature, a, g, frameAcceleration));
    float tau = particle_tau(m, s.radius, s.temperature, a, length(s.velocity - u));
    return min(tau, particle_terminalTime(m, s.radius, s.temperature, a, gs));
}

// ParticlePhysics.schedule: x = first piece, y = ratio, z = count.
inline float3 particle_schedule(float dt, float shortest, int most) {
    if (!(shortest < PARTICLE_NO_DRAG * 0.5) || shortest <= 0.0 || dt <= 2.0 * shortest) { return float3(dt, 1.0, 1.0); }
    float x = dt / shortest, n = float(most);
    if (x <= 2.0 * n) {
        float count = ceil(x / 2.0);
        return float3(dt / count, 1.0, count);
    }
    float s2 = pow(2.0, n) - 1.0;
    if (s2 <= x) { return float3(dt / s2, 2.0, n); }
    float lo = 1.0, hi = 2.0;
    for (int k = 0; k < 40; k++) {
        float mid = 0.5 * (lo + hi);
        if ((pow(mid, n) - 1.0) / (mid - 1.0) < x) { lo = mid; } else { hi = mid; }
    }
    float q = 0.5 * (lo + hi);
    return float3(dt / ((pow(q, n) - 1.0) / (q - 1.0)), q, n);
}

// ParticlePhysics.slipStep: the exact linear step of the slip through air
// moving at u0 and accelerating at c.
inline void particle_slipStep(thread float3 &x, thread float3 &v, thread float3 &slip, thread float3 &slipVelocity,
                              float3 u0, float3 c, float3 g, float tau, float h) {
    float3 wx = float3(0.0), wv = v - u0;
    particle_step(wx, wv, float3(0.0), g, tau, h);
    x = x + u0 * h + c * (0.5 * h * h) + wx;
    v = u0 + c * h + wv;
    slip = wx;
    slipVelocity = wv;
}

// ParticlePhysics.substep, starting at time t from the frame's epoch.
inline ParticleState particle_substep(ParticleState s, device const ParticleMaterial &m, float3 gravity,
                                      float3 frameAcceleration, float iceVacuum, ParticleAir a, float h, float t) {
    float3 u0, c;
    particle_airMotion(a, frameAcceleration, t, u0, c);
    float start = length(s.velocity - u0);
    float3 g0 = particle_slipGravity(m, s.temperature, a, gravity, frameAcceleration);
    float tau0 = particle_tau(m, s.radius, s.temperature, a, start);
    float3 px = s.position, pv = s.velocity, pSlip, pSlipV;
    particle_slipStep(px, pv, pSlip, pSlipV, u0, c, g0, tau0, h);
    float2 guess = particle_grown(s, m, a, h, length(pSlip));
    float radius = 0.5 * (s.radius + guess.x), temperature = 0.5 * (s.temperature + guess.y);
    float3 g = particle_slipGravity(m, temperature, a, gravity, frameAcceleration);
    float tau = particle_tau(m, radius, temperature, a, 0.5 * (start + length(pSlipV)));
    float3 x = s.position, v = s.velocity, slip, slipV;
    particle_slipStep(x, v, slip, slipV, u0, c, g, tau, h);
    float2 after = particle_grown(s, m, a, h, length(slip));
    ParticleState next;
    next.position = x;
    next.velocity = v;
    next.radius = after.x;
    next.temperature = after.y;
    if (m.thermal.z > 0.0) {
        next.radius = particle_sublimatedRadius(next.radius, h, a.density <= 0.0 ? iceVacuum : a.temperature, a);
    }
    return next;
}

// ------------------------------------------------------------ anchors ---

// A particle's altitude (AnchorFrame.altitude(of:)).
inline float particle_altitude(device const ParticleAnchor &an, float3 p) {
    float along = dot(p, an.up.xyz);
    float3 across = p - an.up.xyz * along;
    return an.up.w + along + dot(across, across) / (2.0 * max(an.north.w, 1.0));
}

inline float particle_logLinear(float a, float b, float w) {
    return a > 1e-30 && b > 1e-30 ? exp(mix(log(a), log(b), w)) : mix(a, b, w);
}

// Where a free-fall anchor was at time t (s from the frame's epoch,
// negative before it), from where it is then: v t + ½ g t², its velocity
// v = ω × r − air (AnchorFrame.environment's frameVelocity); zero for the others.
inline float3 particle_frameDisplacement(device const ParticleAnchor &an, float t) {
    if (an.toWorld0.w < 0.5) { return float3(0.0); }
    float3 v = cross(an.rotation.xyz, an.up.xyz * an.north.w) - an.air.xyz;
    return v * t + 0.5 * an.gravity.xyz * t * t;
}

// The air a particle at p met at time t (s from the frame's epoch):
// AnchorFrame.air(at:) where the particle then was, p plus the anchor's
// displacement since, so a parcel in a climbing or falling anchor reads the
// profile at its own altitude. The velocity is the epoch's; airMotion
// carries it back to t.
inline ParticleAir particle_air(device const ParticleAnchor &an, device const float4 *profiles, float3 p0, float t) {
    ParticleAir o = particle_vacuum();
    int profile = int(an.gravity.w);
    if (profile < 0) { return o; }
    float3 p = p0 + particle_frameDisplacement(an, t);
    float h = max(particle_altitude(an, p), 0.0);
    if (h >= PARTICLE_AIR_TOP) { return o; }
    float u = sqrt(h / PARTICLE_AIR_TOP) * float(PARTICLE_AIR_LEVELS - 1);
    int i = min(int(u), PARTICLE_AIR_LEVELS - 2);
    float x0 = float(i) / float(PARTICLE_AIR_LEVELS - 1), x1 = float(i + 1) / float(PARTICLE_AIR_LEVELS - 1);
    float h0 = PARTICLE_AIR_TOP * x0 * x0, h1 = PARTICLE_AIR_TOP * x1 * x1;
    float w = clamp((h - h0) / (h1 - h0), 0.0, 1.0);
    device const float4 *levels = profiles + profile * PARTICLE_AIR_LEVELS * 2;
    float4 a0 = levels[i * 2], a1 = levels[i * 2 + 2], w0 = levels[i * 2 + 1], w1 = levels[i * 2 + 3];
    o.density = particle_logLinear(a0.x, a1.x, w);
    o.temperature = mix(a0.y, a1.y, w);
    o.pressure = particle_logLinear(a0.z, a1.z, w);
    if (o.density <= 0.0) { return particle_vacuum(); }
    float2 wind = mix(w0.xy, w1.xy, w);
    o.velocity = an.air.xyz + cross(an.rotation.xyz, p) + an.east.xyz * wind.x + an.north.xyz * wind.y;
    return o;
}

// ParticlePhysics.advance, the air looked up in the anchor's profile at each
// piece's start, and a gas parcel cooled or warmed adiabatically with the
// air's pressure between pieces.
inline ParticleState particle_advance(ParticleState s, device const ParticleMaterial &m, device const ParticleAnchor &an,
                                      device const float4 *profiles, float dt, int most) {
    if (dt <= 0.0) { return s; }
    float3 frameAcceleration = an.toWorld0.w > 0.5 ? an.gravity.xyz : float3(0.0);
    ParticleAir a = particle_air(an, profiles, s.position, -dt);
    float3 plan = particle_schedule(dt, particle_shortest(s, m, an.gravity.xyz, frameAcceleration, a, -dt), most);
    int count = int(plan.z);
    float elapsed = 0.0, h = plan.x;
    for (int k = 0; k < count; k++) {
        if (s.radius <= 0.0) { break; }
        float step = k == count - 1 ? dt - elapsed : h;
        s = particle_substep(s, m, an.gravity.xyz, frameAcceleration, an.rotation.w, a, step, elapsed - dt);
        elapsed += step;
        h *= plan.y;
        ParticleAir next = particle_air(an, profiles, s.position, elapsed - dt);
        if (m.motion.x <= 0.0 && a.density > 0.0 && next.density > 0.0 && a.pressure > 0.0 && next.pressure > 0.0) {
            s.temperature *= pow(next.pressure / a.pressure, PARTICLE_ADIABATIC);
        }
        a = next;
    }
    return s;
}

// FlashHold.isAlive.
inline bool particle_isAlive(float age, float lifetime, uint shown, bool flash, bool holds) {
    return age < lifetime || (flash && holds && shown < PARTICLE_FLASH_HOLD_FRAMES);
}

// ----------------------------------------------------------- sampling ---
// EmitSampler and ParticleRandom.

inline uint particle_pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

inline float particle_uniform(thread uint &state) {
    state = particle_pcg(state);
    return float(state >> 8) / 16777216.0;
}

inline void particle_basis(float3 axis, thread float3 &u, thread float3 &v) {
    float3 helper = abs(axis.z) < 0.9 ? float3(0, 0, 1) : float3(1, 0, 0);
    u = normalize(cross(helper, axis));
    v = cross(axis, u);
}

inline float3 particle_cone(float3 axis, float spread, float u1, float u2) {
    float3 u, v;
    particle_basis(axis, u, v);
    float c = 1.0 - u1 * (1.0 - cos(clamp(spread, 0.0, M_PI_F)));
    float s = sqrt(max(0.0, 1.0 - c * c)), phi = 2.0 * M_PI_F * u2;
    return (u * cos(phi) + v * sin(phi)) * s + axis * c;
}

struct ParticleSpawn {
    float3 position;
    float3 velocity;
    float radius;
    float lifetime;
    float age;
    uint seed;
};

inline ParticleSpawn particle_sample(device const ParticleRequest &r, uint i) {
    uint state = particle_pcg(r.ids.z ^ particle_pcg(i + 0x9E3779B9u));
    uint own = state;
    float x[10];
    for (int k = 0; k < 10; k++) { x[k] = particle_uniform(state); }
    float3 axis = length(r.axis.xyz) > 0.0 ? normalize(r.axis.xyz) : float3(0, 0, 1);
    float3 u, v;
    particle_basis(axis, u, v);
    int kind = int(r.origin.w);
    float a = r.axis.w, b = r.shape.x;
    float phi = 2.0 * M_PI_F * x[1];
    float3 around = u * cos(phi) + v * sin(phi);
    float3 offset = float3(0.0), outward = axis;
    if (kind == 1 || kind == 2) {
        float z = 2.0 * x[0] - 1.0, s = sqrt(max(0.0, 1.0 - z * z)), psi = 2.0 * M_PI_F * x[2];
        float3 d = (u * cos(psi) + v * sin(psi)) * s + axis * z;
        offset = d * (kind == 1 ? a * pow(x[3], 1.0 / 3.0) : a);
        outward = d;
    } else if (kind == 3) {
        offset = around * (a * sqrt(x[0]));
        outward = around;
    } else if (kind == 4) {
        float inner = max(0.0, a - 0.5 * b), outer = a + 0.5 * b;
        offset = around * sqrt(inner * inner + x[0] * (outer * outer - inner * inner));
        outward = around;
    } else if (kind == 5) {
        offset = around * a + axis * ((x[0] - 0.5) * b);
        outward = around;
    } else if (kind == 6) {
        offset = axis * (a * x[0]);
        outward = around;
    } else {
        float z = 2.0 * x[0] - 1.0, s = sqrt(max(0.0, 1.0 - z * z)), psi = 2.0 * M_PI_F * x[2];
        outward = (u * cos(psi) + v * sin(psi)) * s + axis * z;
    }
    float3 heading = particle_cone(r.shape.y > 0.5 ? outward : axis, r.shape.z, x[4], x[5]);
    float speed = r.speed.x + x[6] * (r.speed.y - r.speed.x);
    float n = max(r.ages.y, 1.0);
    ParticleSpawn o;
    o.age = r.sourceAcceleration.w + (float(i) + x[7]) / n * (r.ages.x - r.sourceAcceleration.w);
    o.radius = r.speed.z + x[8] * (r.speed.w - r.speed.z);
    o.lifetime = r.velocity.w + x[9] * (r.sourceVelocity.w - r.velocity.w);
    float3 source = r.origin.xyz - r.sourceVelocity.xyz * o.age + r.sourceAcceleration.xyz * (0.5 * o.age * o.age);
    float3 sourceVelocity = r.sourceVelocity.xyz - r.sourceAcceleration.xyz * o.age;
    o.position = source + offset;
    o.velocity = sourceVelocity + r.velocity.xyz + heading * speed;
    o.seed = own;
    return o;
}

// ------------------------------------------------------------ kernels ---

kernel void particle_reset(device uint *freeList [[buffer(5)]],
                           device atomic_uint *counters [[buffer(1)]],
                           constant ParticleFrame &pf [[buffer(2)]],
                           uint id [[thread_position_in_grid]]) {
    uint capacity = pf.counts.x;
    if (id < capacity) { freeList[id] = capacity - 1u - id; }
    if (id == 0) {
        for (uint k = 0; k < PARTICLE_COUNTERS; k++) {
            atomic_store_explicit(&counters[k], k == PARTICLE_COUNTER_FREE ? capacity : 0u, memory_order_relaxed);
        }
    }
}

kernel void particle_begin(device atomic_uint *counters [[buffer(1)]],
                           constant ParticleFrame &pf [[buffer(2)]],
                           uint id [[thread_position_in_grid]]) {
    if (id != 0) { return; }
    uint next = 1u - pf.counts.w;
    atomic_store_explicit(&counters[PARTICLE_COUNTER_ALIVE + next], 0u, memory_order_relaxed);
    for (uint c = 0; c < 3; c++) { atomic_store_explicit(&counters[PARTICLE_COUNTER_DRAW + c], 0u, memory_order_relaxed); }
    atomic_store_explicit(&counters[PARTICLE_COUNTER_EMITTED], 0u, memory_order_relaxed);
    atomic_store_explicit(&counters[PARTICLE_COUNTER_DROPPED], 0u, memory_order_relaxed);
    atomic_store_explicit(&counters[PARTICLE_COUNTER_SMOKE_AREA], 0u, memory_order_relaxed);
}

inline float particle_phase(float cosTheta, float g);
inline float3 particle_emission(device const ParticleMaterial &m, float temperature);
inline float particle_fade(device const ParticleMaterial &m, float age, float lifetime);

// Whether a live particle is drawn this frame (it is simulated either way):
// in the view, a streak's length and all; a streak bright enough to see at
// this exposure (its glint taken with the Sun above any air, an upper
// bound). `area` is a smoke puff's at the effect targets, texels.
inline bool particle_drawn(float3 p, float3 v, float radius, float temperature, float age, float lifetime,
                           device const ParticleMaterial &m, device const ParticleAnchor &an,
                           constant ParticleFrame &pf, constant FrameUniforms &frame, thread float &area) {
    area = 0.0;
    if (pf.view.x < 0.5) { return true; }
    float3x3 toWorld = float3x3(an.toWorld0.xyz, an.toWorld1.xyz, an.toWorld2.xyz);
    float3 world = an.origin.xyz + toWorld * p;
    uint c = min(uint(m.albedo.w), 2u);
    float speed = length(v);
    float reach = radius + (c == PARTICLE_CLASS_STREAK ? speed * m.shape.x : 0.0);
    float3 q = (frame.view * float4(world, 0.0)).xyz;
    float depth = -q.z;
    if (depth < -reach) { return false; }
    float ty = frame.camera.y, tx = ty * frame.camera.z;
    if (abs(q.x) - reach * sqrt(1.0 + tx * tx) > depth * tx) { return false; }
    if (abs(q.y) - reach * sqrt(1.0 + ty * ty) > depth * ty) { return false; }
    if (c == PARTICLE_CLASS_STREAK) {
        float d = max(depth, frame.camera.x);
        float width = max(2.0 * radius, PARTICLE_STREAK_MIN_PIXELS * d * 2.0 * ty * frame.viewport.w), h = 0.5 * width;
        // The trail across the line of sight, as the streak draws it.
        float3 ray = normalize(world), trail = (toWorld * v) * m.shape.x;
        float len = length(trail - ray * dot(trail, ray));
        float coverage = M_PI_F * radius * radius / (16.0 / 15.0 * h * len + M_PI_F / 3.0 * h * h);
        float shown = age < lifetime ? age : 0.5 * lifetime;
        float3 glint = m.albedo.rgb * frame.sunIlluminance.rgb
            * particle_phase(dot(frame.sunDirection.xyz, normalize(world)), m.look.y);
        float3 light = (particle_emission(m, temperature) + glint) * particle_fade(m, shown, lifetime);
        // Its brightest, pre-exposed, against a tenth of an 8-bit step.
        if (max(light.r, max(light.g, light.b)) * coverage * frame.exposure.x < 4e-4) { return false; }
    }
    if (c == PARTICLE_CLASS_SMOKE) {
        float rp = radius / max(depth, radius) * pf.view.y;
        area = min(M_PI_F * rp * rp, pf.view.w);
    }
    return true;
}

// Appends a live particle to the next alive list and, drawn, to its class's
// draw list, a puff's area to the smoke's sum.
inline void particle_append(uint index, uint renderClass, bool drawn, float area, device uint *aliveOut,
                            device uint *drawLists, device atomic_uint *counters, constant ParticleFrame &pf) {
    uint next = 1u - pf.counts.w;
    uint k = atomic_fetch_add_explicit(&counters[PARTICLE_COUNTER_ALIVE + next], 1u, memory_order_relaxed);
    aliveOut[k] = index;
    if (!drawn) { return; }
    uint c = min(renderClass, 2u);
    uint d = atomic_fetch_add_explicit(&counters[PARTICLE_COUNTER_DRAW + c], 1u, memory_order_relaxed);
    uint most = c == PARTICLE_CLASS_CHUNK ? pf.limits.x : pf.counts.x;
    if (d < most) { drawLists[c * pf.counts.x + d] = index; }
    if (area > 0.0) {
        atomic_fetch_add_explicit(&counters[PARTICLE_COUNTER_SMOKE_AREA], uint(ceil(area / 256.0)), memory_order_relaxed);
    }
}

inline bool particle_dead(ParticleState s, float age, float lifetime, uint shown, device const ParticleMaterial &m,
                          device const ParticleAnchor &an, constant ParticleFrame &pf) {
    uint flags = uint(m.thermal.w);
    if (an.origin.w < 0.5 || s.radius <= 0.0) { return true; }
    if (orbit_isNotFinite(s.position) || orbit_isNotFinite(s.velocity) || orbit_isNotFinite(s.radius)) { return true; }
    if (!particle_isAlive(age, lifetime, shown, (flags & PARTICLE_FLAG_FLASH) != 0u, pf.time.z > 0.5)) { return true; }
    return (flags & PARTICLE_FLAG_GROUND) != 0u && particle_altitude(an, s.position) < an.east.w;
}

kernel void particle_simulate(device Particle *particles [[buffer(0)]],
                              device const uint *aliveIn [[buffer(3)]],
                              device uint *aliveOut [[buffer(4)]],
                              device uint *freeList [[buffer(5)]],
                              device atomic_uint *counters [[buffer(1)]],
                              device uint *drawLists [[buffer(6)]],
                              constant ParticleFrame &pf [[buffer(2)]],
                              device const ParticleMaterial *materials [[buffer(7)]],
                              device const ParticleAnchor *anchors [[buffer(8)]],
                              device const float4 *profiles [[buffer(9)]],
                              constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                              uint id [[thread_position_in_grid]]) {
    uint count = atomic_load_explicit(&counters[PARTICLE_COUNTER_ALIVE + pf.counts.w], memory_order_relaxed);
    if (id >= count) { return; }
    uint index = aliveIn[id];
    Particle p = particles[index];
    // An anchor past this frame's table is gone: so is its particle.
    if (particle_anchorIndex(p.packed) >= pf.limits.z) {
        uint k = atomic_fetch_add_explicit(&counters[PARTICLE_COUNTER_FREE], 1u, memory_order_relaxed);
        freeList[k] = index;
        return;
    }
    uint mi = particle_materialIndex(p.packed), ai = particle_anchorIndex(p.packed);
    device const ParticleMaterial &m = materials[mi];
    device const ParticleAnchor &an = anchors[ai];
    ParticleState s;
    s.position = p.positionRadius.xyz;
    s.velocity = p.velocityAge.xyz;
    s.radius = p.positionRadius.w;
    s.temperature = p.state.y;
    float dt = pf.time.x, age = p.velocityAge.w, lifetime = p.state.x;
    uint shown = particle_shown(p.packed);
    if (an.origin.w > 0.5 && dt > 0.0) {
        s = particle_advance(s, m, an, profiles, dt, int(pf.limits.y));
        age += dt;
    }
    if (particle_dead(s, age, lifetime, shown, m, an, pf)) {
        uint k = atomic_fetch_add_explicit(&counters[PARTICLE_COUNTER_FREE], 1u, memory_order_relaxed);
        freeList[k] = index;
        return;
    }
    if (age >= lifetime && pf.time.w > 0.5) { shown += 1u; }
    p.positionRadius = float4(s.position, s.radius);
    p.velocityAge = float4(s.velocity, age);
    p.state.y = s.temperature;
    p.packed = particle_pack(mi, ai, shown, particle_lookSeed(p.packed));
    particles[index] = p;
    float area;
    bool drawn = particle_drawn(s.position, s.velocity, s.radius, s.temperature, age, lifetime, m, an, pf, frame, area);
    particle_append(index, uint(m.albedo.w), drawn, area, aliveOut, drawLists, counters, pf);
}

kernel void particle_emit(device Particle *particles [[buffer(0)]],
                          device atomic_uint *counters [[buffer(1)]],
                          constant ParticleFrame &pf [[buffer(2)]],
                          device uint *aliveOut [[buffer(4)]],
                          device const uint *freeList [[buffer(5)]],
                          device uint *drawLists [[buffer(6)]],
                          device const ParticleMaterial *materials [[buffer(7)]],
                          device const ParticleAnchor *anchors [[buffer(8)]],
                          device const float4 *profiles [[buffer(9)]],
                          device const ParticleRequest *requests [[buffer(10)]],
                          constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                          uint id [[thread_position_in_grid]]) {
    if (id >= pf.counts.y || pf.counts.z == 0u) { return; }
    // The request this particle belongs to: the last whose first index is at most id.
    uint lo = 0, hi = pf.counts.z;
    while (hi - lo > 1u) {
        uint mid = (lo + hi) / 2u;
        if (requests[mid].ids.w <= id) { lo = mid; } else { hi = mid; }
    }
    device const ParticleRequest &r = requests[lo];
    uint i = id - r.ids.w;
    if (float(i) >= r.ages.y) { return; }
    if (r.ids.y >= pf.limits.z) { return; }
    uint mi = r.ids.x, ai = r.ids.y;
    device const ParticleMaterial &m = materials[mi];
    device const ParticleAnchor &an = anchors[ai];
    if (an.origin.w < 0.5) { return; }
    ParticleSpawn sp = particle_sample(r, i);
    uint flags = uint(m.thermal.w);
    bool flash = (flags & PARTICLE_FLAG_FLASH) != 0u, holds = pf.time.z > 0.5;
    // EffectTimeRules.spawns.
    if (!(sp.age < sp.lifetime || (flash && holds && sp.age < sp.lifetime + max(pf.time.x, 0.0)))) { return; }
    ParticleState s;
    s.position = sp.position;
    s.velocity = sp.velocity;
    s.radius = sp.radius;
    s.temperature = r.shape.w > 0.0 ? r.shape.w : particle_air(an, profiles, sp.position, -sp.age).temperature;
    s = particle_advance(s, m, an, profiles, sp.age, int(pf.limits.y));
    uint shown = sp.age >= sp.lifetime ? 1u : 0u;
    if (s.radius <= 0.0 || orbit_isNotFinite(s.position) || orbit_isNotFinite(s.velocity)) { return; }
    if ((flags & PARTICLE_FLAG_GROUND) != 0u && particle_altitude(an, s.position) < an.east.w) { return; }
    uint old = atomic_fetch_sub_explicit(&counters[PARTICLE_COUNTER_FREE], 1u, memory_order_relaxed);
    if (old == 0u || old > pf.counts.x) {
        atomic_fetch_add_explicit(&counters[PARTICLE_COUNTER_FREE], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&counters[PARTICLE_COUNTER_DROPPED], 1u, memory_order_relaxed);
        return;
    }
    uint index = freeList[old - 1u];
    Particle p;
    p.positionRadius = float4(s.position, s.radius);
    p.velocityAge = float4(s.velocity, sp.age);
    p.state = packed_float3(sp.lifetime, s.temperature, sp.radius);
    p.packed = particle_pack(mi, ai, shown, sp.seed >> 16);
    particles[index] = p;
    atomic_fetch_add_explicit(&counters[PARTICLE_COUNTER_EMITTED], 1u, memory_order_relaxed);
    float area;
    bool drawn = particle_drawn(s.position, s.velocity, s.radius, s.temperature, sp.age, sp.lifetime, m, an, pf, frame,
                                area);
    particle_append(index, uint(m.albedo.w), drawn, area, aliveOut, drawLists, counters, pf);
}

// The next frame's simulate dispatch and this frame's draws.
kernel void particle_compact(device atomic_uint *counters [[buffer(1)]],
                             constant ParticleFrame &pf [[buffer(2)]],
                             device uint *args [[buffer(11)]],
                             uint id [[thread_position_in_grid]]) {
    if (id != 0) { return; }
    uint next = 1u - pf.counts.w;
    uint alive = atomic_load_explicit(&counters[PARTICLE_COUNTER_ALIVE + next], memory_order_relaxed);
    args[0] = max((alive + 63u) / 64u, 1u);
    args[1] = 1u;
    args[2] = 1u;
    args[3] = 0u;
    // Streaks and smoke are 4-vertex triangle strips; chunks 36-vertex triangles.
    uint vertices[3] = {4u, 4u, 36u};
    for (uint c = 0; c < 3; c++) {
        uint drawn = atomic_load_explicit(&counters[PARTICLE_COUNTER_DRAW + c], memory_order_relaxed);
        uint most = c == PARTICLE_CLASS_CHUNK ? pf.limits.x : pf.counts.x;
        args[4 + 4 * c] = vertices[c];
        args[5 + 4 * c] = min(drawn, most);
        args[6 + 4 * c] = 0u;
        args[7 + 4 * c] = 0u;
    }
    // The smoke's overdraw budget: past it, a seeded share of the puffs is
    // drawn, each with its optical depth divided by that share, so the
    // transmittance through the cloud is kept (in expectation).
    float area = float(atomic_load_explicit(&counters[PARTICLE_COUNTER_SMOKE_AREA], memory_order_relaxed)) * 256.0;
    float keep = area > pf.view.z && pf.view.z > 0.0 ? pf.view.z / area : 1.0;
    atomic_store_explicit(&counters[PARTICLE_COUNTER_SMOKE_KEEP], uint(keep * PARTICLE_KEEP_ONE), memory_order_relaxed);
}

// --------------------------------------------------------------- looks ---

struct ParticleView {
    float3 world;            // camera-relative (m)
    float3 velocity;         // world axes, relative to the anchor (m/s)
    float radius;
    float age;               // its look's (FlashHold.displayAge)
    float lifetime;
    float temperature;
    float spawnRadius;
    uint material;
    uint anchor;
    uint seed;
};

inline ParticleView particle_view(device const Particle *particles, uint index, device const ParticleAnchor *anchors) {
    Particle p = particles[index];
    ParticleView o;
    o.material = particle_materialIndex(p.packed);
    o.anchor = particle_anchorIndex(p.packed);
    o.seed = particle_lookSeed(p.packed);
    device const ParticleAnchor &an = anchors[o.anchor];
    float3x3 toWorld = float3x3(an.toWorld0.xyz, an.toWorld1.xyz, an.toWorld2.xyz);
    o.world = an.origin.xyz + toWorld * p.positionRadius.xyz;
    o.velocity = toWorld * p.velocityAge.xyz;
    o.radius = p.positionRadius.w;
    o.lifetime = p.state.x;
    o.age = p.velocityAge.w < o.lifetime ? p.velocityAge.w : 0.5 * o.lifetime;
    o.temperature = p.state.y;
    o.spawnRadius = p.state.z;
    return o;
}

// Fading in and out over the material's fractions of the lifetime.
inline float particle_fade(device const ParticleMaterial &m, float age, float lifetime) {
    float t = clamp(age / max(lifetime, 1e-6), 0.0, 1.0);
    float in_ = m.look.z > 0.0 ? clamp(t / m.look.z, 0.0, 1.0) : 1.0;
    float out = m.look.w > 0.0 ? clamp((1.0 - t) / m.look.w, 0.0, 1.0) : 1.0;
    return in_ * out;
}

// Emission following (T / T0)^4.
inline float3 particle_emission(device const ParticleMaterial &m, float temperature) {
    float t = m.emission.w > 0.0 ? max(temperature, 0.0) / m.emission.w : 1.0, t2 = t * t;
    float k = t2 * t2;
    return m.emission.rgb * min(k, 64.0);
}

inline float particle_phase(float cosTheta, float g) {
    float d = 1.0 + g * g - 2.0 * g * cosTheta;
    return (1.0 - g * g) / (4.0 * M_PI_F * d * sqrt(max(d, 1e-6)));
}

// The Sun's lux per channel at an anchor's particles: through the air the
// camera is in (A2), or above any (and always in the studio); times the
// anchor's sunlit fraction.
inline float3 particle_sun(constant FrameUniforms &frame, constant AtmosphereUniforms &atmosphere,
                           device const ParticleAnchor &an) {
    bool above = an.origin.w > 1.5 || atmosphere.radii.w < 0.5;
    float3 sun = above ? frame.sunIlluminance.rgb : atmosphere.sunTransmitted.rgb * atmosphere.sunTransmitted.w;
    return sun * an.air.w;
}

// ------------------------------------------------------------- streaks ---
// Additive, full resolution, after the effect composite: a quad along the
// motion over the material's streak time, at least 3 pixels wide (its
// profile is shaded once a pixel: shaded at pixel centres, a dot 2.5 pixels
// wide keeps its integral only to 13 %, 3 pixels to 3 %), its
// light spread so the particle's flux is kept however thin it is drawn.

struct ParticleStreakOut {
    float4 position [[position]];
    float2 uv;               // x: across (-1...1), y: along (0 tail ... 1 head)
    float cap;               // each round cap's share of the length
    float3 color;            // pre-exposed radiance on the core
};

vertex ParticleStreakOut particle_streak_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                                device const Particle *particles [[buffer(0)]],
                                                device const uint *lists [[buffer(1)]],
                                                device const ParticleAnchor *anchors [[buffer(2)]],
                                                device const ParticleMaterial *materials [[buffer(3)]],
                                                constant ParticleFrame &pf [[buffer(4)]],
                                                constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                                constant AtmosphereUniforms &atmosphere [[buffer(ORBIT_BUFFER_ATMOSPHERE)]]) {
    float2 corners[4] = {float2(-1, 0), float2(1, 0), float2(-1, 1), float2(1, 1)};   // a triangle strip
    ParticleView p = particle_view(particles, lists[PARTICLE_CLASS_STREAK * pf.counts.x + iid], anchors);
    device const ParticleMaterial &m = materials[p.material];
    device const ParticleAnchor &an = anchors[p.anchor];
    ParticleStreakOut o;
    float3 c = (frame.view * float4(p.world, 0.0)).xyz;
    float depth = -c.z;
    if (depth <= frame.camera.x) {
        o.position = float4(2.0, 2.0, 2.0, 1.0);
        o.uv = float2(0.0);
        o.cap = 0.0;
        o.color = float3(0.0);
        return o;
    }
    float pixel = depth * 2.0 * frame.camera.y * frame.viewport.w;
    float width = max(2.0 * p.radius, PARTICLE_STREAK_MIN_PIXELS * pixel);
    // The trail across the line of sight: a streak seen end-on is a round
    // dot, and the flux below is spread over what is drawn, at any angle.
    float3 trail = (frame.view * float4(p.velocity, 0.0)).xyz * m.shape.x;
    float3 ray = normalize(c);
    trail -= ray * dot(trail, ray);
    float len = length(trail);
    float3 along, side;
    if (len > 0.25 * width) {
        along = trail / len;
        float3 across = cross(along, c);
        side = length(across) > 0.0 ? normalize(across) : float3(1.0, 0.0, 0.0);
    } else {
        len = 0.0;
        along = float3(0.0, 1.0, 0.0);
        side = float3(1.0, 0.0, 0.0);
    }
    float total = len + width;
    float2 k = corners[vid];
    float3 tail = c - along * (len + 0.5 * width);
    float3 q = tail + along * (k.y * total) + side * (k.x * 0.5 * width);
    o.position = frame.projection * float4(q, 1.0);
    o.uv = k;
    o.cap = 0.5 * width / total;
    // The particle's flux spread over the capsule: its disc's area over the
    // profile's integral, (1 - d²)² about the core, d in half-widths:
    // (16/15) h L along the length and (π/3) h² for the two caps. The
    // profile falls smoothly to nothing, so shading it once a pixel keeps
    // its integral.
    float h = 0.5 * width;
    float coverage = M_PI_F * p.radius * p.radius / (16.0 / 15.0 * h * len + M_PI_F / 3.0 * h * h);
    float3 view = normalize(p.world);
    float3 glint = m.albedo.rgb * particle_sun(frame, atmosphere, an)
        * particle_phase(dot(frame.sunDirection.xyz, view), m.look.y);
    float3 light = (particle_emission(m, p.temperature) + glint) * particle_fade(m, p.age, p.lifetime);
    o.color = light * coverage * frame.exposure.x;
    return o;
}

fragment float4 particle_streak_fragment(ParticleStreakOut in [[stage_in]]) {
    // The distance from the core in half-widths: across, and into a cap.
    float c = max(in.cap, 1e-4);
    float along = in.uv.y < c ? (c - in.uv.y) / c : (in.uv.y > 1.0 - c ? (in.uv.y - 1.0 + c) / c : 0.0);
    float d2 = in.uv.x * in.uv.x + along * along, q = max(1.0 - d2, 0.0);
    return float4(orbit_effectRadiance(in.color * q * q), 0.0);
}

// --------------------------------------------------------------- smoke ---
// Lit soft billboards through R6's OIT pair at half resolution: optical
// depth falling as (r0/r)² as the puff grows, eroded by the volume noise
// drifting on the turbulence clock, a puffed normal for the Sun's wrap,
// Henyey-Greenstein single scattering, the sky's light, any glow; faded
// softly into the scene and at the near plane.

struct ParticleSmokeOut {
    float4 position [[position]];
    float2 corner;
    float viewDepth;
    float radius;
    float tau;               // optical depth through the centre
    float phase;             // Henyey-Greenstein, towards the camera (1/sr)
    float3 sunLight;         // albedo × the Sun (lux)
    float3 ambient;          // albedo × the sky / π, plus the glow (cd/m²)
    float3 sunView;          // unit, camera -> Sun, view axes
    float3 noiseOrigin;      // the puff's place in the noise
};

vertex ParticleSmokeOut particle_smoke_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                              device const Particle *particles [[buffer(0)]],
                                              device const uint *lists [[buffer(1)]],
                                              device const ParticleAnchor *anchors [[buffer(2)]],
                                              device const ParticleMaterial *materials [[buffer(3)]],
                                              constant ParticleFrame &pf [[buffer(4)]],
                                              device const uint *counters [[buffer(5)]],
                                              constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                              constant AtmosphereUniforms &atmosphere [[buffer(ORBIT_BUFFER_ATMOSPHERE)]]) {
    float2 corners[4] = {float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)};  // a triangle strip
    ParticleView p = particle_view(particles, lists[PARTICLE_CLASS_SMOKE * pf.counts.x + iid], anchors);
    // Thinned past the overdraw budget: the puffs whose seed falls beyond the
    // share kept are not drawn, the others are denser.
    float keep = float(counters[PARTICLE_COUNTER_SMOKE_KEEP]) / PARTICLE_KEEP_ONE;
    if (float(p.seed) / 65536.0 >= keep) {
        ParticleSmokeOut none;
        none.position = float4(2.0, 2.0, 2.0, 1.0);
        none.corner = float2(2.0);
        none.viewDepth = 0.0;
        none.radius = 0.0;
        none.tau = 0.0;
        none.phase = 0.0;
        none.sunLight = none.ambient = none.sunView = none.noiseOrigin = float3(0.0);
        return none;
    }
    device const ParticleMaterial &m = materials[p.material];
    device const ParticleAnchor &an = anchors[p.anchor];
    float2 k = corners[vid];
    float3 centre = (frame.view * float4(p.world, 0.0)).xyz;
    float3 q = centre + float3(k * p.radius, 0.0);
    ParticleSmokeOut o;
    o.position = frame.projection * float4(q, 1.0);
    o.corner = k;
    o.viewDepth = -q.z;
    o.radius = p.radius;
    float grown = p.spawnRadius / max(p.radius, 1e-6);
    o.tau = m.look.x * grown * grown * particle_fade(m, p.age, p.lifetime) / max(keep, 1e-6);
    float3 view = normalize(p.world);
    float3 sun = particle_sun(frame, atmosphere, an);
    o.sunLight = m.albedo.rgb * sun;
    o.phase = particle_phase(dot(frame.sunDirection.xyz, view), m.look.y);
    o.ambient = m.albedo.rgb * atmosphere.skyIrradiance.rgb / M_PI_F + particle_emission(m, p.temperature);
    o.sunView = (frame.view * float4(frame.sunDirection.xyz, 0.0)).xyz;
    float s = float(p.seed);
    o.noiseOrigin = float3(fract(s * 0.618034), fract(s * 0.414214), fract(s * 0.732051)) * 4.0;
    return o;
}

fragment EffectOITOut particle_smoke_fragment(ParticleSmokeOut in [[stage_in]],
                                              constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                              constant EffectSlotUniforms &e [[buffer(ORBIT_EFFECT_BUFFER_SLOTS)]],
                                              constant ParticleFrame &pf [[buffer(4)]],
                                              texture2d<float> halfResDepth [[texture(ORBIT_EFFECT_TEXTURE_HALFRES_DEPTH)]],
                                              texture3d<float> noise [[texture(0)]],
                                              sampler noiseSampler [[sampler(0)]]) {
    float r2 = dot(in.corner, in.corner);
    if (r2 > 1.0) { discard_fragment(); }
    float scene = orbit_effectSceneDistance(uint2(in.position.xy), halfResDepth, frame);
    float fade = clamp((scene - in.viewDepth) / (0.5 * in.radius), 0.0, 1.0)
        * clamp((in.viewDepth - frame.camera.x) / max(in.radius, 1e-3), 0.0, 1.0);
    float3 at = in.noiseOrigin + float3(in.corner * 0.45, 0.0) + pf.noise.xyz;
    float2 n = noise.sample(noiseSampler, at).rg;
    float profile = (1.0 - r2) * (1.0 - r2);
    float tau = in.tau * profile * (0.35 + 1.3 * n.x);
    float alpha = (1.0 - exp(-tau)) * fade;
    if (alpha <= 1e-4) { discard_fragment(); }
    float3 normal = float3(in.corner + 0.4 * (n - 0.5), sqrt(max(1.0 - r2, 0.0)));
    normal = normalize(normal);
    float wrap = 0.35 + 0.65 * clamp(dot(normal, in.sunView) * 0.5 + 0.5, 0.0, 1.0);
    // Single scattering where the puff is thin, its forward peak and all; a
    // diffuse wrap where it is thick, as many scatterings make it.
    float thin = exp(-tau);
    float3 c = (in.sunLight * (in.phase * thin + wrap / M_PI_F * (1.0 - thin)) + in.ambient) * frame.exposure.x;
    return orbit_oitOutput(float4(c * alpha, alpha), in.viewDepth, e);
}

// -------------------------------------------------------------- chunks ---
// Opaque in P1: a plate (a thin box) or a tetrahedron, tumbling about its
// own axis at its own rate, lit by the Sun (Lambert) and the sky, plus any glow.

struct ParticleChunkOut {
    float4 position [[position]];
    float3 normal [[flat]];
    float3 color [[flat]];   // albedo, pre-exposed sunlight is applied per pixel
    float3 sun [[flat]];     // the Sun's lux at the chunk, pre-exposed / π
    float3 base [[flat]];    // sky and glow, pre-exposed
};

constant float3 particle_boxCorners[8] = {
    float3(-1, -1, -1), float3(1, -1, -1), float3(1, 1, -1), float3(-1, 1, -1),
    float3(-1, -1, 1), float3(1, -1, 1), float3(1, 1, 1), float3(-1, 1, 1)};
constant uint particle_boxIndices[36] = {
    0, 2, 1, 0, 3, 2,  4, 5, 6, 4, 6, 7,  0, 1, 5, 0, 5, 4,  2, 3, 7, 2, 7, 6,  1, 2, 6, 1, 6, 5,  3, 0, 4, 3, 4, 7};
constant float3 particle_tetraCorners[4] = {
    float3(1, 1, 1), float3(1, -1, -1), float3(-1, 1, -1), float3(-1, -1, 1)};
constant uint particle_tetraIndices[12] = {0, 1, 2, 0, 3, 1, 0, 2, 3, 1, 3, 2};

inline float3 particle_rotate(float3 v, float3 axis, float angle) {
    float c = cos(angle), s = sin(angle);
    return v * c + cross(axis, v) * s + axis * dot(axis, v) * (1.0 - c);
}

vertex ParticleChunkOut particle_chunk_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                              device const Particle *particles [[buffer(0)]],
                                              device const uint *lists [[buffer(1)]],
                                              device const ParticleAnchor *anchors [[buffer(2)]],
                                              device const ParticleMaterial *materials [[buffer(3)]],
                                              constant ParticleFrame &pf [[buffer(4)]],
                                              constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]],
                                              constant AtmosphereUniforms &atmosphere [[buffer(ORBIT_BUFFER_ATMOSPHERE)]]) {
    ParticleView p = particle_view(particles, lists[PARTICLE_CLASS_CHUNK * pf.counts.x + iid], anchors);
    device const ParticleMaterial &m = materials[p.material];
    device const ParticleAnchor &an = anchors[p.anchor];
    ParticleChunkOut o;
    bool tetra = m.shape.y > 0.5;
    float3 a, b, c;
    if (tetra) {
        if (vid >= 12u) {
            o.position = float4(2.0, 2.0, 2.0, 1.0);
            o.normal = float3(0.0);
            o.color = o.sun = o.base = float3(0.0);
            return o;
        }
        uint t = vid / 3u * 3u;
        a = particle_tetraCorners[particle_tetraIndices[t]];
        b = particle_tetraCorners[particle_tetraIndices[t + 1]];
        c = particle_tetraCorners[particle_tetraIndices[t + 2]];
    } else {
        uint t = vid / 3u * 3u;
        a = particle_boxCorners[particle_boxIndices[t]];
        b = particle_boxCorners[particle_boxIndices[t + 1]];
        c = particle_boxCorners[particle_boxIndices[t + 2]];
    }
    float3 scale = tetra ? float3(p.radius * 0.577) : float3(p.radius, p.radius, p.radius * max(m.shape.z, 0.01));
    float3 corner = (tetra ? particle_tetraCorners[particle_tetraIndices[vid]]
                           : particle_boxCorners[particle_boxIndices[vid]]) * scale;
    uint state = particle_pcg(p.seed + 0x5bd1e995u);
    float u1 = particle_uniform(state), u2 = particle_uniform(state), u3 = particle_uniform(state),
          u4 = particle_uniform(state);
    float z = 2.0 * u1 - 1.0, sz = sqrt(max(0.0, 1.0 - z * z)), phi = 2.0 * M_PI_F * u2;
    float3 axis = float3(sz * cos(phi), sz * sin(phi), z);
    float angle = 2.0 * M_PI_F * u3 + m.shape.w * (0.3 + 0.7 * u4) * p.age;
    float3 n = normalize(cross((b - a) * scale, (c - a) * scale));
    o.normal = particle_rotate(n, axis, angle);
    float3 world = p.world + particle_rotate(corner, axis, angle);
    o.position = frame.viewProjection * float4(world, 1.0);
    o.color = m.albedo.rgb;
    o.sun = particle_sun(frame, atmosphere, an) / M_PI_F * frame.exposure.x;
    o.base = (m.albedo.rgb * (atmosphere.skyIrradiance.rgb / M_PI_F) + particle_emission(m, p.temperature))
        * frame.exposure.x + m.albedo.rgb * 0.01;
    return o;
}

fragment float4 particle_chunk_fragment(ParticleChunkOut in [[stage_in]],
                                        constant FrameUniforms &frame [[buffer(ORBIT_BUFFER_FRAME)]]) {
    // One-sided, as the vessels and R6's column: a face turned from the Sun
    // gets only the sky and any glow.
    float lambert = max(dot(normalize(in.normal), frame.sunDirection.xyz), 0.0);
    return float4(orbit_effectRadiance(in.color * in.sun * lambert + in.base), 1.0);
}

// --------------------------------------------------------------- noise ---
// VolumeNoise: a tileable 128³ field of gradient noise, three octaves (16,
// 8 and 4 texels a cell), two decorrelated channels, made at load with a
// fixed seed. OrbitScene's VolumeNoiseField computes the same texels.

constant float3 particle_gradients[12] = {
    float3(1, 1, 0), float3(-1, 1, 0), float3(1, -1, 0), float3(-1, -1, 0),
    float3(1, 0, 1), float3(-1, 0, 1), float3(1, 0, -1), float3(-1, 0, -1),
    float3(0, 1, 1), float3(0, -1, 1), float3(0, 1, -1), float3(0, -1, -1)};

inline float particle_gradientNoise(float3 p, int period, uint seed) {
    int3 i = int3(floor(p));
    float3 f = p - float3(i);
    float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float v[8];
    for (int k = 0; k < 8; k++) {
        int3 o = int3(k & 1, (k >> 1) & 1, (k >> 2) & 1);
        int3 c = ((i + o) % period + period) % period;
        uint h = particle_pcg(uint(c.x + period * (c.y + period * c.z)) ^ seed);
        v[k] = dot(particle_gradients[h % 12u], f - float3(o));
    }
    float x00 = mix(v[0], v[1], u.x), x10 = mix(v[2], v[3], u.x), x01 = mix(v[4], v[5], u.x), x11 = mix(v[6], v[7], u.x);
    return mix(mix(x00, x10, u.y), mix(x01, x11, u.y), u.z);
}

inline float particle_noiseValue(uint3 t, uint channel) {
    float3 p = float3(t) + 0.5;
    uint seed = 0x2545F491u + channel * 0x9E3779B9u;
    float n = 0.6 * particle_gradientNoise(p / 16.0, 8, seed) + 0.3 * particle_gradientNoise(p / 8.0, 16, seed + 1u)
        + 0.1 * particle_gradientNoise(p / 4.0, 32, seed + 2u);
    return clamp(0.5 + 0.8 * n, 0.0, 1.0);
}

kernel void particle_noise(texture3d<float, access::write> out [[texture(0)]],
                           uint3 id [[thread_position_in_grid]]) {
    if (id.x >= out.get_width() || id.y >= out.get_height() || id.z >= out.get_depth()) { return; }
    out.write(float4(particle_noiseValue(id, 0u), particle_noiseValue(id, 1u), 0.0, 1.0), id);
}

// ---------------------------------------------------------- self-test ---

struct ParticleGoldenStep {
    float4 position;         // xyz
    float4 velocity;         // xyz
    float4 air;              // xyz: the air's velocity
    float4 gravity;          // xyz
    float4 params;           // x: relaxation time (PARTICLE_NO_DRAG: none), y: dt
};

kernel void particle_golden_step(device const ParticleGoldenStep *cases [[buffer(0)]],
                                 device float4 *out [[buffer(1)]],
                                 constant uint &count [[buffer(2)]],
                                 uint id [[thread_position_in_grid]]) {
    if (id >= count) { return; }
    ParticleGoldenStep c = cases[id];
    float3 x = c.position.xyz, v = c.velocity.xyz;
    particle_step(x, v, c.air.xyz, c.gravity.xyz, c.params.x, c.params.y);
    out[2 * id] = float4(x, 0.0);
    out[2 * id + 1] = float4(v, 0.0);
}

struct ParticleGoldenAdvance {
    float4 positionRadius;   // xyz, w: radius
    float4 velocityTemperature; // xyz, w: temperature
    float4 air;              // x: density, y: temperature, z: pressure
    float4 airVelocity;      // xyz: at the end of the advance
    float4 gravity;          // xyz, w: ice's temperature in vacuum
    float4 frameAcceleration; // xyz
    float4 params;           // x: dt, y: substeps at most
};

kernel void particle_golden_advance(device const ParticleGoldenAdvance *cases [[buffer(0)]],
                                    device const ParticleMaterial *materials [[buffer(1)]],
                                    device float4 *out [[buffer(2)]],
                                    constant uint &count [[buffer(3)]],
                                    uint id [[thread_position_in_grid]]) {
    if (id >= count) { return; }
    ParticleGoldenAdvance c = cases[id];
    device const ParticleMaterial &m = materials[id];
    ParticleAir a;
    a.density = c.air.x;
    a.temperature = c.air.y;
    a.pressure = c.air.z;
    a.velocity = c.airVelocity.xyz;
    if (a.density <= 0.0) { a = particle_vacuum(); }
    ParticleState s;
    s.position = c.positionRadius.xyz;
    s.radius = c.positionRadius.w;
    s.velocity = c.velocityTemperature.xyz;
    s.temperature = c.velocityTemperature.w;
    float dt = c.params.x;
    float3 fa = c.frameAcceleration.xyz;
    float3 plan = particle_schedule(dt, particle_shortest(s, m, c.gravity.xyz, fa, a, -dt), int(c.params.y));
    int pieces = int(plan.z);
    float elapsed = 0.0, h = plan.x;
    for (int k = 0; k < pieces; k++) {
        if (s.radius <= 0.0) { break; }
        float step = k == pieces - 1 ? dt - elapsed : h;
        s = particle_substep(s, m, c.gravity.xyz, fa, c.gravity.w, a, step, elapsed - dt);
        elapsed += step;
        h *= plan.y;
    }
    out[2 * id] = float4(s.position, s.radius);
    out[2 * id + 1] = float4(s.velocity, s.temperature);
}

// The struct sizes, for the Swift mirrors' test.
kernel void particle_sizes(device uint *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    if (id != 0) { return; }
    out[0] = sizeof(Particle);
    out[1] = sizeof(ParticleMaterial);
    out[2] = sizeof(ParticleAnchor);
    out[3] = sizeof(ParticleRequest);
    out[4] = sizeof(ParticleFrame);
    out[5] = sizeof(ParticleGoldenStep);
    out[6] = sizeof(ParticleGoldenAdvance);
}
"""#

extension ShaderModule {
    public static let particle = ShaderModule(name: "Particle", headers: [.effectSlots], source: particleShaderSource)
}
