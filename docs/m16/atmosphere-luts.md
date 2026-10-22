# Atmosphere optics and LUTs (M1.6 track A1)

What track A2 (and the vessel lighting in R2) takes from OrbitCore's
`OpticalAtmosphere` (Sources/OrbitCore/Bodies/AtmosphereOptics.swift) and
`AtmosphereLUT` (AtmosphereLUT.swift). The doc comments there are the
reference; this page is the contract to mirror in MSL, with the accuracy
the tests pin (Tests/OrbitCoreTests/AtmosphereOpticsTests.swift and
AtmosphereLUTTests.swift).

## The model

- **Wavelengths:** 680, 550 and 440 nm in R, G and B (`Spectrum3`).
- **Sphere:** the ground at the figure's equatorial radius R = 6,378,137 m
  (WGS 84), the top 100 km above it. March in figure coordinates (the axis
  stretched by a/b), as `sunTransmittance` does, so the ellipsoid is the
  sphere.
- **Rayleigh:** Bodhaine et al. 1999 eq. 29 on the number density of the
  simulation's own atmosphere (US-1976, or the launch-day sounding when the
  scenario has one). Phase: 3/(16π(1+2γ)) ((1+3γ) + (1−γ)cos²θ), γ = ρn/(2−ρn),
  ρn = 0.0279.
- **Aerosol:** exponential, H = 1.2 km, AOD(550) = 0.1, Ångström 1.3,
  single-scattering albedo 0.9, Cornette-Shanks with g = 0.8. A scenario
  parameter (`OpticalAtmosphere.Aerosol`).
- **Ozone:** a tent from 10 to 40 km, 300 DU, Serdyuchenko 233 K.
- **cos θ** in both phase functions is the cosine between the view ray
  (outward from the eye) and the direction to the Sun.
- **Units:** everything is per unit solar irradiance. Multiply radiances and
  irradiances by the Sun's illuminance above the air (`Photometry`).

## Tables

All tables are RGBA Float32, row-major from v = 0 (texel (i, j) at
`4 * (j * width + i)`), so `Table.texels` uploads as an `rgba32Float`
texture. Sample them with a linear filter and clamp-to-edge. Parameters map
to [0, 1] and then to texel centres:

```
u = 0.5 / size + x * (1 - 1 / size)          // textureCoordinate(unit:size:)
```

| Table | Size | u | v | RGB |
|---|---|---|---|---|
| `transmittance` | 256×64 | x_μ (below) | x_r = ρ/H | transmittance to the top along μ |
| `multipleScattering` | 32×32 | μs·0.5 + 0.5 | √((r − R)/(Rtop − R)) | Ψ_ms (1/sr) |
| `irradiance` | 64×16 | μs·0.5 + 0.5 | √((r − R)/(Rtop − R)) | sky irradiance on a horizontal surface facing up |
| `profile` | 1024×1 | h/100 km | — | air density / ground's, e^(−h/1.2 km), ozone / peak (A = 0) |

Transmittance (Bruneton 2017): H = √(Rtop² − R²), ρ = √(r² − R²),
d = −rμ + √(r²(μ² − 1) + Rtop²), d_min = Rtop − r, d_max = ρ + H,
x_μ = (d − d_min)/(d_max − d_min). Rays into the ground read the horizon
column; the Sun's transmittance is 0 there.

The Sun's transmittance in the scattering integrals fades over its disc as
it sets behind the planet (`transmittanceToSun`): with sin h = R/r and
cos h = −√(1 − sin²h), multiply by smoothstep(−sin h·α, sin h·α, μs − cos h),
α = 0.00465 rad.

The multiple-scattering and irradiance rows use √ of the height fraction
(Hillaire's are linear), which puts half the rows below 25 km. The
`profile` times `AtmosphereLUT.coefficients` gives the medium for a march:

```
rayleighScattering = coefficients.rayleighScatteringAtGround * profile.r
aerosolExtinction  = coefficients.aerosolExtinctionAtGround  * profile.g
aerosolScattering  = coefficients.aerosolScatteringAtGround  * profile.g
ozoneAbsorption    = coefficients.ozoneAbsorptionAtPeak      * profile.b
```

These fill ShaderCommon's `AtmosphereUniforms` (rayleighScattering,
mieScattering, mieExtinction with w = g, ozoneAbsorption with w = peak
altitude, ozoneLayer.x = half-width); the `w` scale heights are the
equivalent exponentials for an analytic fallback (air: 8,454 m).

## The sky

`AtmosphereLUT.skyRadiance(radius:cosZenith:cosSun:cosView:)` is the CPU
reference of what A2 draws: along the view ray, the Sun's light scattered
with the Rayleigh and aerosol phase functions times `transmittanceToSun`,
plus σs·Ψ_ms, each step's attenuation integrated exactly, and the ground's
Lambertian light where the ray meets it.

Departures from Hillaire 2020, each measured in the tests:
- **The Sun's first scattering in Ψ_ms uses the true phase functions** (his
  reference code's `MieRayPhase`), then isotropic. With the forward aerosol
  this closes the energy balance within 0.4 %; isotropic overshoots by
  1-2 %.
- **384 directions** (16 μ per hemisphere × 12 azimuths) instead of 64: with
  the Sun low, the aerosol's forward peak needs them (8 azimuths leave Ψ 6 %
  short).

## For vessels

`OpticalAtmosphere.sunTransmittance(position:sunDir:pole:)`: the Sun's
transmittance at a point (m from the Earth's centre) toward a unit vector,
in body-fixed axes or any frame with the Earth's `pole`. 0 where the
ellipsoid hides the Sun's centre; multiply by `Eclipse`'s sunlit fraction
and the Sun's illuminance. The pad's 7° Sun at 07:51 EST is transmitted
as (0.37, 0.18, 0.052): seven times redder than blue.

## Accuracy and cost

| Check | Result |
|---|---|
| Rayleigh τ (US-1976) vs Bodhaine Table 3 | +0.05 % at 680, 550 and 440 nm |
| Air mass at 80° vs Kasten-Young 5.59 | 5.565 |
| Launch-day sounding | τ +0.92 % |
| Quadrature vs a 200,000-step trapezoid | within 1e-4, zenith to limb |
| Transmittance table, at texel centres / between them | Float precision / τ within 1 % (worst 0.53 %) |
| Energy closure, conservative air, black ground, zenith Sun | within 0.4 % (single scattering alone loses 6-9 % of the blue) |
| Ψ_ms and irradiance tables vs finer quadrature | within 2 % and 1.5 % |
| Zenith-Sun irradiance vs brute force | total within 0.1 %, sky within 1 % on the ground |
| Noon Sun at sea level | 1.54e9 cd/m² |

Build: 0.7 s in Release on four cloud cores, rows in parallel; build it on
a background queue at launch, or cache it.
