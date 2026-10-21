# M1.6/M2 design: Earth and Moon

> Planning document for the M1.5 close-out, milestone M1.6 (graphics overhaul) and M2 (Apollo 8), written on 2026-10-20 by a design study (six design reports checked by a planner) and accepted by Franz on 2026-10-21 with all recommended defaults (US keyboard). Track briefs refer to it. Where code has moved on, the code wins.


This is a design report. Where it conflicts with plan.md, the plan wins: the planner checked and corrected the reports.


## Current state

Renderer (Sources/OrbitSim/Rendering, about 1,900 lines; main at 6a1851b):
- Renderer.swift:70-75 sets up the MTKView: bgra8Unorm_srgb (LDR, no tone map, no exposure), depth32Float reversed-Z, MSAA 4x, 60 fps. One render encoder per frame, with no compute pre-pass and no offscreen targets (Renderer.swift:243-466).
- Renderer.swift:169-194 loadTextures: optional equirectangular `earth`/`moon` .jpg/.png/.tif (8192x4096 or smaller) from ~/Library/Application Support/OrbitSim/Textures, loaded with MTKTextureLoader (sRGB, mipmapped). The owner's machine has only earth.jpg: BMNG base map, July 2004, 5400x2700 (8 km/px), with a SOURCES.txt provenance note (sha256). There is no Moon texture, so the Moon draws as a grey sphere with the 15° grid.
- Renderer.swift:280-329 draws bodies farthest first; a body under 1.5 px becomes a point. One PlanetUniforms per body: the camera origin in figure coordinates computed in double on the CPU (the |o|²−a² trick), and an ambient of 0.015. Renderer.swift:674-691 BodyStyle gives the Earth a sky colour (0.30, 0.55, 1.0) and a "visual" scale height of 9,000 m; the Moon is a grey 0.35.
- Shaders.swift:62-142 planet_fragment ray-traces the WGS-84 ellipsoid in figure coordinates (z stretched by a/b) and writes per-pixel depth.
  - Missed rays (:85-101): the sky is exp(−h_closest/H) times a day smoothstep, premultiplied at most 85% opaque (stars show through the day sky).
  - Hits: Lambert plus ambient (:129-130), then a haze mix of up to 0.85 (:131-136). The Sun is a body drawn ×4 (:112-113).
  - Missing: specular/ocean, clouds, night side, terrain relief, aerial perspective on vessels, physical units.
  - Shaders.swift:51-60 samples the equirect maps seam-free (Tarini's method).
- Renderer.swift:479-527 vesselLight uses heuristics: skylight 0.25·sqrt(ρ/ρ0) with a sunset smoothstep; earthshine albedo 0.30 with a fixed colour (0.78, 0.88, 1.0); the Moon 0.12. The Sun's colour never changes: no atmospheric transmittance, so the Saturn V on the pad is lit white even at a 7° Sun.
- Stars (Renderer.swift:196-210, 270-278) are drawn first with noDepth, with brightness from magnitude.
- The navball has its own shader library (HUD/NavballShaders.swift), the precedent for per-subsystem shader strings.

Core data the overhaul can build on (OrbitCore, Linux-tested):
- Earth: the WGS-84 figure (Ellipsoid.swift) and IAU 2006/2000B orientation on UT1 (EarthOrientation.swift).
- Atmospheres: the US Standard Atmosphere 1976 to 1,000 km with a `state(altitude:)` API (Atmosphere.swift:12-21, :114-) and the launch-day SoundingAtmosphere (:33-).
- Eclipse.swift: the conical shadow model, with no refraction or atmospheric dimming.
- SurfaceMask.swift: a 0.25° Natural Earth land mask, used by physics only.
- Moon: a 1,737.4 km sphere oriented by the DE421 libration rotated PA→ME (CelestialBody.swift MoonFrames.paToME). That is the MOON_ME frame in which LOLA and LROC products are published, so maps can be used without re-registration.
- DE421 covers 1960-2030 and UT1 from 1962, so 21-27 December 1968 is in range.

M1.5 status in this area:
- M1.5 is complete per docs/ROADMAP.md.
- Deferred, not done: the ocean near splashdown (G8c in docs/m15/design-graphics.md:116-123), night lights, stars hidden in the day sky (plan.md:498 decision 19: "Planet textures stay user-supplied").
- Out of scope then: precomputed scattering (design-graphics.md:136), HDR/tone mapping, volumetric clouds and lunar terrain LOD (:138).
- docs/ROADMAP.md:147 lists "Lunar terrain: LOLA elevation with a quadtree LOD" under M2. This design pulls it forward for Apollo 8's lunar orbit.
- There is no Apollo 8 scenario. Scenarios.swift:188-194 has a 110 km capsule lunar orbit on 20 July 1969, usable as a development scene.
- No tools/fetch script exists for planet data.

## Design

PRINCIPLES
- One physically based, HDR, exposure-driven pipeline for the planets, so the same code is right at the pad (Apollo 8 launched at 07:51 EST with the Sun about 7° up), in the 100 n mi parking orbit, in translunar coast and in lunar orbit.
- Physics and data (optics, cloud fields, tile addressing, LOD selection, photometry, horizon maps, Apollo 8 geometry) live in OrbitCore: pure Swift + Foundation, no simd, tested on Linux. The app holds only the GPU side.
- Large data is never committed. Owner-run tools/ scripts fetch and convert it into ~/Library/Application Support/OrbitSim/ with a SOURCES.txt (URL, date, size, sha256), as today's earth.jpg does. Only small public-domain derived products are bundled.
- Everything is reimplemented from papers, which keeps the code MIT. The reference code read is Hillaire (MIT) and Bruneton (BSD-3); if any of it is ported, keep its notice in THIRD_PARTY_NOTICES.

1. SHARED PREREQUISITE P0: frame graph and HDR (owned by whichever track owns Renderer.swift; it must land first)
This area needs:
(a) HDR scene colour:
- rgba16Float, pre-exposed: shaders multiply radiance by the previous frame's exposure before writing, because half-float tops out at 65,504 and the Sun's disc is about 1.6e9 cd/m².
- Memoryless 4x MSAA attachments resolved on store, plus a resolved depth texture (depthResolveFilter .max for reversed-Z).
(b) A compute pre-pass slot each frame (sky-view LUT, aerial-perspective froxels, cloud weather assembly, the exposure histogram).
(c) Offscreen half- and quarter-resolution targets, with history textures for temporal passes.
(d) A tone-map and exposure pass to the drawable, with the HUD sprites after it in LDR. Tone curve: Khronos PBR Neutral or AgX, decided by the HDR track.
(e) Shaders.swift split into per-subsystem MSL strings concatenated by a ShaderLibrary.swift, with a shared header. P0 creates PlanetShaders, AtmosphereShaders, CloudShaders and MoonShaders as files with stub functions and their call sites, so the A, E, C and M tracks edit disjoint files.
(f) FrameContext carries an AtmosphereContext (LUT textures, the froxel texture, a cloud-shadow texture, uniforms), which the vessel mesh shaders can sample for aerial perspective and cloud shadowing.
(g) Rule: each new pass keeps its Swift mirror structs (float4-only layout) in its own file. RenderTypes.swift and Renderer.swift are touched only by P0.
Stars become physical (magnitude to radiance), so the daylit sky and exposure hide them, which the old 85% hack approximated.

2. ATMOSPHERE (A1 core on Linux, A2 rendering on the Mac)
Method: Hillaire 2020, "A Scalable and Production Ready Sky and Atmosphere Rendering Technique" (EGSR; MIT reference code sebh/UnrealEngineSkyAtmosphere).
- It handles ground, orbit and deep-space views and the Earth's shadow inside the atmosphere.
- Multiple scattering is a cheap LUT.
- Nothing is precomputed per atmosphere state except two small LUTs.
- It reuses the same transmittance function for clouds, vessels and the Sun.
- Bruneton 2017 (BSD-3) is the alternative: options §1.

A1, OrbitCore/Bodies/AtmosphereOptics.swift: `OpticalAtmosphere`.
- Wavelengths: three, 680/550/440 nm.
- Rayleigh:
  - Cross sections from Bodhaine et al. 1999 eq. 29 (σ(550) = 4.5105e-27 cm²).
  - Number density from the core's own `Atmosphere.state(altitude:).density / (M_air/N_A)`. The sky therefore sits on the same US-1976 or launch-day sounding the physics flies; the sounding fades to US-1976 above 56 km.
- Aerosol (Mie):
  - Exponential with scale height 1.2 km and AOD(550) of 0.1 by default, a scenario parameter.
  - Ångström α 1.3, single-scattering albedo 0.9, Cornette-Shanks phase with g 0.8.
- Ozone: a tent profile peaking at 25 km, normalised to a 300 DU column, with Serdyuchenko/Gorshelev cross sections at the three wavelengths.
- Functions: extinction(h), opticalDepth(from h, cosZenith), transmittance, and sunTransmittance(position, sunDir) for vessels.
- Atmosphere top: 100 km for optics (the 1976 density above contributes under 1e-6 of τ).

A1, OrbitCore/Bodies/AtmosphereLUT.swift builds, in Double, then Float arrays:
- the transmittance LUT (256x64, Hillaire's (r, μ) parameterisation);
- the multiple-scattering LUT (32x32, 64 directions × 20 steps);
- the ground irradiance LUT (64x16) for vessel sky light and the cloud ambient.
Cost: under 0.2 s in Release, built at launch on a background queue or cached. The parameterisation functions (uv↔r,μ) are written once in Swift and mirrored in MSL; a test pins the round trip.

A2, the GPU side (Rendering/Planet/AtmospherePass.swift + AtmosphereShaders.swift):
(1) Inside the atmosphere (camera below 100 km): a per-frame sky-view LUT (192x108, latitude-biased) for the sky, and aerial-perspective froxels (32x32x32 over 0-200 km) for the surface, the clouds' far fade and vessels.
(2) Above the atmosphere: a per-pixel ray march (16-32 samples, transmittance plus multi-scattering LUT, a planet-shadow test toward the Sun at each sample), only on pixels whose ray meets the 100 km shell, so its cost scales with the limb's screen area. This gives the layered orange-blue limb and the twilight wedge from orbit.
(3) The ellipsoid: the Earth is 21 km flatter at the poles than its equatorial radius, which matters against a 100 km atmosphere at the limb.
- March in the figure coordinates the planet shader already uses (z stretched by a/b), so the shells become ellipsoidal. The altitude error is about 0.34% of height.
- The phase angle is taken from world-space directions.
(4) The Sun's disc: limb-darkened, multiplied by its transmittance along the view ray (reddened at the horizon; refraction flattening ignored). Glare and bloom belong to the HDR track.
(5) Lighting the Earth's surface: sun irradiance × transmittance to the ground point, plus sky irradiance from the irradiance LUT, then aerial perspective (transmittance and in-scatter along the camera ray, read from the froxels inside the atmosphere or marched from space).
(6) For vessels:
- the Sun's colour and strength = sunTransmittance at the vessel, times Eclipse's sunlit fraction. This replaces the white Sun and the `skylight` heuristic in Renderer.vesselLight.
- sky ambient from the irradiance LUT;
- aerial perspective from the froxels.
The vessel-lighting owner wires these in. Results: the warm, low-sun light on the Saturn V at 07:51 EST, and the reddening and dimming of the CSM through orbital sunset before Eclipse's geometric shadow.
(7) Optional (0.5 d): green-line airglow (557.7 nm) as a thin emissive Gaussian layer at 95 km in the march, visible on the night limb from orbit.

3. PLANET TILE STORE (E1): shared by the Earth's imagery and the Moon's terrain
- Addressing: a cube-sphere quadtree (6 faces, with an equal-area tangent warp, max distortion about 1.4x).
  - OrbitCore/Bodies/CubeSphere.swift: face/uv/direction maps and TileKey(face, level, x, y).
  - OrbitCore/Bodies/PlanetQuadtree.swift: CDLOD-style selection in double precision. Distance ranges are set by a texel-to-pixel threshold, with frustum and horizon culling (the horizon test includes the layer's max height: Moon +10.8/−9.1 km). There are a tile budget and a motion-aware LOD bias: the ground speed in pixels per frame pushes LOD coarser under time warp, so streaming never chases 7.8 km/s × 1000.
  - All of this is Linux-tested.
- Format: OrbitCore/Bodies/PlanetTileFormat.swift ("OSTILES1": an index table plus payloads, memory-mappable, pure Foundation), one file per layer.
  - Colour payloads are JPEG/HEIC, decoded by ImageIO in the app.
  - Data payloads (heights, horizons) are raw int16/uint8, so OrbitCore can sample heights on Linux for M2's landing later (no LZFSE: it is not in swift-corelibs-foundation).
  - Tiles are 256² or 512² texels with a 4-texel border for bilinear and anisotropic filtering.
- Builder: a macOS-only Swift command-line target (tools/PlanetTiles, ImageIO + Accelerate) for Blue Marble, LOLA and LROC rasters. Its projection and quadtree maths are the core files above. ERA5 stays in Python (xarray/zarr), next to the existing tools/*.py, with the same provenance docstrings.
- App: Rendering/Planet/PlanetTileCache.swift.
  - A 2D-array texture atlas per layer (e.g., 256-512 slots) and a per-face indirection texture with mips, giving the finest resident ancestor (slot, level).
  - Loading on a background queue: MTLIOCommandQueue for raw tiles (macOS 13+), ImageIO for JPEG.
  - Tiles are prefetched along the predicted camera path, and LRU-evicted.
- The ray-traced Earth samples it per pixel (lon/lat → face/uv → indirection → atlas, LOD from the ray footprint). The Moon's mesh binds tile slots per instance.

4. EARTH SURFACE (E2, in PlanetPass.swift + PlanetShaders.swift)
- Albedo: the Blue Marble Next Generation 500 m monthly base map ("world" variant: no baked topography or bathymetry shading, because relief is lit dynamically).
  - Month by scenario date: December 2004 for Apollo 8, October for Apollo 7, July for Apollo 11.
  - 8 source tiles of 21600² per month go into a cube-sphere pyramid of about 0.9 GB per month in JPEG.
  - A procedural detail octave (by land type) breaks up magnification below 500 m. At the 185 km nadir with a 50° FOV a pixel is about 90 m.
- Historic hydrography, from Natural Earth's public-domain historic-lakes layer, painted into the albedo and the water mask in the tool:
  - the 1960s Aral Sea and Lake Chad, the two anachronisms visible from orbit at this resolution;
  - Rondônia's 2004 deforestation is noted, not fixed.
- Water mask: Natural Earth 10m land minus lakes, plus the historic lakes, rasterised to about 1 km, as tile alpha.
- Relief: normals from ETOPO 2022 (NOAA, public domain, 30"), so the Andes and Himalaya shade at the terminator.
- Ocean, two parts:
  - Diffuse: the BMNG water colour (shallow banks such as the Bahamas included).
  - Specular: Fresnel with n = 1.33 plus a Cox-Munk glint, with slope variance σ² = 0.003 + 5.12e-3·U and U = 6 m/s by default (ERA5 10 m wind where loaded). The glint is filtered by pixel footprint: the slope variance grows with distance, so the glint spot is right from translunar distance and does not alias.
  - The near-surface waves at splashdown stay the M1.5 G8c design, as an option.
- Night lights:
  - Is a 1968 map possible? No measured one exists. DMSP's low-light sensor flew from about 1970 on film, and the digital archive starts in 1992; VIIRS (Black Marble) is 2012+. Using Black Marble as-is is anachronistic (China, India and the Gulf states are far brighter now).
  - Default: a modelled "1968 estimate" from tools/make_night_lights.py. Black Marble 2016 grey (3 km; NASA) or VNP46A4 calibrated radiance (Earthdata login) is masked and scaled by the ratio of JRC GHSL built-up area 1975/2015 (CC BY 4.0). A per-region 1968 intensity factor is documented as an L-grade assumption, and gas-flare regions active in 1968 are kept.
  - Rendered as emitted radiance in physical units on the night side. With exposure, lights are invisible in any daylit-exposed frame (consistent with Earthrise, 1/250 s f/11) and appear only when the camera adapts on the night side.
- Cloud shadows: the surface asks CloudShaders for transmittance along the sun ray at the layer heights.
- Cape inset (coordinate with the pad-area report): a 15-30 m regional tile set around LC-39.
  - Landsat 8/9 pan-sharpened: public domain, but modern; it shows the 1970s Shuttle Landing Facility runway.
  - Or USGS CORONA KH-4B (1967-72, public domain, panchromatic): period-correct, but needs orthorectification and colourisation.
  - Default: Landsat with the SLF painted out; CORONA as an option.

5. CLOUDS (C1 data and core on Linux, C2 rendering on the Mac)
Data, OrbitCore/Bodies/CloudField.swift: format "OSCLOUD1" (start epoch, step, a 0.25° grid of 1440x721, uint8 planes for low, mid and high cover, cloud-base height, and optional u/v winds per layer).
- Historical, default: ERA5 hourly for each mission's dates, from Google's public ARCO-ERA5 Zarr (gs://gcp-public-data-arco-era5, 1940 onwards) via tools/make_clouds_era5.py. Variables: low/medium/high cloud cover, cloud-base height, 10 m wind, 850/500/250 hPa winds. About 3 MB per hour.
  - Apollo 8: 1968-12-21T12Z to 12-27T18Z.
  - Apollo 7: October 1968.
  - Apollo 11: July 1969.
  - ERA5 in 1968 is pre-satellite-radiance, so synoptic placement is good and fine structure is not.
  - From lunar distance with a 250 mm lens the Earth spans about 300 px, about 40 km/px, so 0.25° is already at photo resolution there.
- Fallback with no download: OrbitCore/Bodies/CloudClimatology.swift, zonal-mean cover by month from a small table (ITCZ, subtropical clear belts, storm tracks), driving procedural weather.
- Pad truth: the scenario's observed sky from NASA TM X-64796 (Johnson 1973) Table 1, transcribed to tools/data/tmx64796_table1_saturn.csv:
  - AS-503 (Apollo 8), 21 Dec 68, 0751 EST, pad 39A: "4/10 cirrus", 15.0 °C, RH 58%, wind 5.7 m/s from 348°.
  - SA-205 (Apollo 7): "3/10 cumulonimbus".
  - AS-506 (Apollo 11): "1/10 cumulus, 2/10 altocumulus, 9/10 cirrostratus".
  - The scenario blends a local override (about 50 km radius) into the ERA5 field when the two disagree.
- Layer model:
  - low (cumulus/stratocumulus): base from ERA5 cloud-base height, else 1 km; top +1-2 km; cumulonimbus to 12 km where low and high are both high and convective;
  - mid (altostratus/altocumulus): 3-6 km;
  - high (cirrus/cirrostratus): 8-12 km, as a thin layer with a fibrous anisotropic texture.
  - Extinction from physics: β = 3·LWC/(2ρ_w r_eff), about 0.05-0.1 /m for cumulus with LWC 0.3-0.5 g/m³ and r_eff 10 µm; cirrus 1e-4-1e-3 /m. Tested in core.
- Procedural detail (CloudNoise.swift, generated at launch by compute, own code after Schneider 2015):
  - 3D Perlin-Worley at 128³ and Worley detail at 32³, plus 2D curl noise.
  - Coverage remap: density = remap(noise, 1 − cover, 1).
  - Large-scale shapes come from domain-warped fBm in body-fixed coordinates: streets, cells and frontal bands keyed by layer type.
  - Noise is anchored to the body-fixed frame. The CPU passes the camera's body-fixed position modulo the noise period in double, as G8c did for the ocean phase, so nothing shimmers at Earth-radius float precision.
- Time: blend between hourly snapshots, while the procedural detail is advected by the layer wind, so motion is continuous at any warp.

Rendering, three regimes with matched transitions:
(1) Near (camera below about 20 km, or within or under a layer): full volumetric march (Schneider/Hillaire 2016) to 200-300 km.
- Resolution: quarter-res (1512x982 on the M3 Pro's 3024x1964), checkerboard 1/4 updates per frame with reprojection, then a depth-aware upsample.
- Lighting:
  - sun transmittance from the atmosphere LUT at each sample's altitude, so clouds stay lit from below after ground sunset: geometrically to −3.2° solar elevation at 10 km, −1.4° at 2 km;
  - 4-6 light-march samples plus multiple-scattering octaves (Wrenninge 2013);
  - a dual-lobe HG phase, or Jendersie & d'Eon's 2023 approximate Mie;
  - ambient from the irradiance LUT.
- Clouds get aerial perspective from the froxels. Cirrus is a 2D layer, as in Schneider.
(2) Orbit (20 km to about 5,000 km): march only the slab where the ray meets the 0.5-13 km shell.
- Steps adapt to the chord (about 10 km at nadir, up to about 800 km at the limb), with noise LOD by distance and the Earth's-shadow test, so the terminator gives pink tops and dark bases. Half or quarter resolution.
(3) Far (above about 5,000 km, and lunar distance): clouds become a surface layer in PlanetShaders.
- Optical depth τ(lat, lon) from the field, with the reflectance read from a slab-BRDF LUT (τ, μ0, μ, Δφ).
- That LUT is generated at startup by running the regime-2 volumetric march on a flat slab. The far field therefore matches the near field by construction, and is checked against the two-stream reflectance R = (1−g)τ/(2 + (1−g)τ).

Shadows: a cloud transmittance map in sun space around the camera (512² over about 100 km), used by the surface, the vessels (the Saturn V under the 4/10 cirrus) and the plumes. Far away, an analytic shifted lookup of the coverage map.

Integration:
- C2 outputs the cloud transmittance and front depth, so plumes and particles (other areas) are attenuated where clouds lie in front of them.
- Temporal reprojection is disabled, falling back to fresh quarter-res frames with more steps, when the warp is at least 10x or when the cloud motion in screen space exceeds 1.5 px per frame (fast camera orbit).

6. MOON (M1 data and core, M2 rendering)
Data, through tools/PlanetTiles:
- Heights: LOLA LDEM_128 global (237 m/px; one 2.1 GB download), plus LDEM_256 (118 m) cut to Apollo 8's band of ±20° latitude.
  - Apollo 8's orbit was about 12° inclined (to confirm in the Mission Report) at 59.7 x 60.7 n mi.
  - Four 2.1 GB downloads, retained as about 1.9 GB int16.
  - Option: GLD100 (LROC WAC stereo, 100 m) or SLDEM2015 for the equatorial band. LOLA's track gaps at low latitude stripe at low sun; SLDEM's Kaguya-derived licence must be checked first.
- Normals are derived per tile.
- Horizon maps: 16 azimuths × 8-bit elevation angle per texel, searched multi-resolution to about 150 km (OrbitCore/Bodies/HorizonMap.swift holds the algorithm, tested on Linux).
- Albedo:
  - Chroma from the LROC WAC Hapke-normalised 3-band colour (NASA SVS CGI Moon Kit, up to about 76 ppd, about 400 m).
  - Absolute level calibrated to WAC 643 nm normal albedo.
  - Never the WAC "morphologic" mosaic: it is built from moderately high-incidence images and has shadows baked in.
- All of it is in MOON_ME, the core's lunar body frame.

Photometry, OrbitCore/Bodies/LunarPhotometry.swift: McEwen 1991 lunar-Lambert, with L(phase) and an opposition-surge term (Hapke parameters after Sato et al. 2014 as an option). Without it the Moon looks like plaster, because its full disc is not limb-darkened.

Rendering, MoonTerrainPass.swift + MoonShaders.swift: CDLOD on the cube sphere.
- Geometry: 33x33 grid instances per selected tile, with geomorphing between levels; heights from atlas slots; tile origins camera-relative in double on the CPU, as vessel meshes are; real silhouettes that MSAA antialiases.
- Lighting:
  - shading: lunar-Lambert;
  - shadows: horizon maps (penumbra from the 0.53° solar disc), which give the long terminator shadows of Apollo 8's lunar morning at the landing sites;
  - earthshine: a second light from the Earth's direction, with the Earth's phase and albedo. The core function moves out of Renderer.vesselLight so the Moon and vessels share it.
- Far fallback: beyond about 20,000 km the existing ray-traced sphere stays, with albedo and a normal map from LDEM_16/64.
- Optional: procedural sub-100 m craters (a power-law size-frequency distribution) hashed per tile.
- The core's tile reader gives M2's LM landing the same heights later (one terrain for rendering and physics).

7. APOLLO 8 DATE/TIME GEOMETRY THE VISUALS MUST REPRODUCE
Figures are from a low-precision check, to be pinned with DE421 in the core tests.
- Launch, 21 Dec 1968 12:51:00 UTC (07:51 EST): the Sun about 7° up in the ESE at LC-39A, 4/10 cirrus. Warm low-angle light and long shadows: the transmittance path matters.
- TLI coast, GET 002:50:37 onwards: the Earth seen nearly full (about 0.95 lit). AS08-16-2593 at about GET 004:36 (to confirm) from about 30,000 km.
- LOI-1 at 09:59:20 UTC on 24 Dec:
  - The Moon was about 5 days old (elongation about 64-67°).
  - The sunrise terminator lay near 20-30°E (Tranquillitatis at lunar morning) and moved about 0.5°/h.
  - The Earth seen from the Moon was gibbous, about 0.69 lit.
- Earthrise, per the Apollo Flight Journal: AS08-13-2329 at GET 075:47:44, AS08-14-2383 at 075:48:39 (16:39:39 UTC), AS08-14-2384 at 075:49:09; 250 mm lens at f/11, 1/250 s; window 4; foreground across Pasteur.
  - The subsolar point was near 23.4°S 70°W (South America at noon, near the left limb).
  - The terminator crossed western and central Africa at about 20°E.
  - Antarctica was lit.
- Splashdown, 27 Dec 1968 15:51:42 UTC near 8.1°N 165.0°W: about 04:50 local solar time, before dawn, so the night ocean and the entry glow matter.

8. EXPOSURE AND PHOTO-MATCH CAMERA (with the HDR and validation tracks)
- Auto exposure (EV100 adaptation with clamps).
- A manual "photo" mode with shutter, aperture, ISO and lens focal length on the 55 mm Hasselblad frame: 80 mm gives a 37.9° FOV, 250 mm gives 12.6°.
- Camera.swift needs a settable fovY. The snapshot mode (env-driven scenario, epoch, camera pose, FOV, exposure, output) is shared with the vessel-graphics validation.

## Phasing

Branch names are descriptive (no claude/...). The P0 prep lands first, then up to 4 Mac and 3 cloud sessions run in parallel on disjoint files.

Phase 0, start together:
- P0 `gfx-hdr-frame-graph` (Mac, about 2 d). Shared with the vessel-PBR and plume reports; owned by whichever plan makes it the renderer-core track.
  - Contents: HDR pre-exposed target, memoryless MSAA and depth resolve, a compute pre-pass, offscreen and history targets, tone map, the Shaders.swift split into ShaderLibrary.swift plus per-subsystem files with stub functions and call sites (PlanetShaders, AtmosphereShaders, CloudShaders, MoonShaders), FrameContext/AtmosphereContext, a settable camera FOV, and the macOS-only PlanetTiles tool target in Package.swift.
  - It is the only track touching Renderer.swift, RenderTypes.swift, Shaders.swift and Package.swift.
- A1 `gfx-atmosphere-core` (Linux, 2.5 d): AtmosphereOptics.swift, AtmosphereLUT.swift and their tests.
- C1 `gfx-cloud-field` (Linux for core and tests, about 2 d; plus about 0.5 d on the Mac to run make_clouds_era5.py with network access): CloudField.swift, CloudClimatology.swift, tools/make_clouds_era5.py, the TM X-64796 Table 1 CSV and tests.
- Q `gfx-planet-quadtree-core` (Linux, 1.5 d): CubeSphere.swift, PlanetQuadtree.swift, PlanetTileFormat.swift and tests.
- M1-core `gfx-moon-core` (Linux, 1.5 d): LunarPhotometry.swift, HorizonMap.swift and tests.
- V-geo `gfx-apollo8-geometry-tests` (Linux, 1 d): SurfaceGeometry.swift (subsolar, sub-observer and specular points) and Apollo8GeometryTests.swift.

Phase 1, after P0:
- A2 `gfx-atmosphere` (Mac, about 5 d; needs A1): AtmospherePass.swift and AtmosphereShaders.swift; hands the vessel-light hook to the vessel-lighting owner.
- E1 `gfx-planet-tiles` (Mac, about 3.5 d plus 2 d of tools; needs Q): PlanetTileCache.swift, tools/PlanetTiles (BMNG, Natural Earth water and historic lakes, ETOPO relief). It publishes the cache API on day 1 as a stub so M2 can start.
- M2 `gfx-moon-terrain` (Mac, about 5 d, plus about 2 d of LOLA/LROC/horizon tooling in tools/PlanetTiles moon subcommands; needs Q and M1-core, and E1's cache API).
- C2 `gfx-clouds` (Mac, about 10 d; needs P0 and C1). It starts with noise, the march and the regimes on placeholder lighting, and adopts A2's LUTs mid-way.

Phase 2:
- E2 `gfx-earth-surface` (Mac, about 4 d; needs E1 and A2): PlanetPass.swift and PlanetShaders.swift (glint, night lights, relief, monthly albedo, detail), tools/make_night_lights.py. It calls C2's cloud_shadow, stubbed until C2 lands.

Phase 3:
- V `gfx-earth-moon-validation` (Mac, about 2 d after the others): snapshot photo-match scenes, golden images, the performance pass, docs. The Apollo 8 visual-check scenario entries go to whoever owns Scenarios.swift (the mission or integration session) as a small PR.

Critical path: P0 (2) → A2 (5) running alongside C2 (10, the longest) → V (2). About 14-16 calendar days with 4 Mac sessions; with fewer Mac sessions it stretches toward the sum of the Mac tracks.
Lean cut (options §3, §5, §9): skip the near-field volumetric clouds and the LDEM_256 band, and use a 16k single Earth texture instead of the tile store for the Earth (the Moon still needs the store). About 26-30 d of work.

File ownership:
- A: AtmospherePass/AtmosphereShaders.
- E: PlanetPass/PlanetShaders/PlanetTileCache/EarthLayers.
- C: CloudPass/CloudShaders/CloudNoise.
- M: MoonTerrainPass/MoonShaders.
- Core files are each owned by the track that creates them.
- tools/PlanetTiles has subcommand files per track: earth (E1), moon (M2), lights (E2).

Dependencies on other areas:
- The HDR, exposure and bloom track (P0).
- The vessel-lighting/PBR track adopts sunTransmittance, the irradiance LUT, aerial perspective and the cloud shadow map.
- The plume and particle tracks read the cloud transmittance and front depth for attenuation.
- The pad-area report decides the Cape inset (Landsat versus CORONA).
- The Apollo 8 mission tracks own the scenarios (TLI, lunar orbit, TEI, night splashdown).

## Data and sources

- Hillaire 2020, A Scalable and Production Ready Sky and Atmosphere Rendering Technique (EGSR); reference code MIT: https://github.com/sebh/UnrealEngineSkyAtmosphere (licence checked via GitHub API: MIT)
- Bruneton & Neyret 2008, Precomputed Atmospheric Scattering; 2017 implementation BSD-3-Clause: https://github.com/ebruneton/precomputed_atmospheric_scattering (licence checked via GitHub API)
- Bodhaine, Wood, Dutton & Slusser 1999, On Rayleigh Optical Depth Calculations, J. Atmos. Oceanic Technol. 16:1854-1861. Table 3: τ_R(sea level, 45°N) = 0.24261 at 440 nm, 0.097069 at 550 nm, 0.040963 at 680 nm; σ(550) = 4.5105e-27 cm². Read from the page images: https://reef.atmos.colostate.edu/~odell/at721/resources/rayleighOpticalDepth.pdf
- Kasten & Young 1989, Revised optical air mass tables and approximation formula, Applied Optics 28:4735 (air mass 5.59 at 80°, 10.3 at 85°)
- Serdyuchenko et al. 2014 / Gorshelev et al. 2014 ozone absorption cross sections (IUP Bremen), for the ozone column
- Schneider & Vos 2015, The Real-time Volumetric Cloudscapes of Horizon Zero Dawn (SIGGRAPH Advances): https://www.advances.realtimerendering.com/s2015/The%20Real-time%20Volumetric%20Cloudscapes%20of%20Horizon%20-%20Zero%20Dawn%20-%20ARTR.pdf ; Nubis Cubed 2023: https://advances.realtimerendering.com/s2023/Nubis%20Cubed%20(Advances%202023).pdf
- Hillaire 2016, Physically Based Sky, Atmosphere and Cloud Rendering in Frostbite (SIGGRAPH PBS course); Högfeldt 2016 Chalmers thesis, Convincing Cloud Rendering: https://publications.lib.chalmers.se/records/fulltext/241770/241770.pdf ; Michelic et al. 2019 I3D poster, Real-time rendering of procedural planets at arbitrary altitudes: https://www.cg.tuwien.ac.at/research/publications/2019/kerbl_2019_planet_poster/
- Wrenninge, Kulla & Lundqvist 2013, Oz: The Great and Volumetric (multiple-scattering octaves); Jendersie & d'Eon 2023, An Approximate Mie Scattering Function for Fog and Cloud Rendering (SIGGRAPH Talks)
- Cox & Munk 1954, Measurement of the roughness of the sea surface from photographs of the sun's glitter, JOSA 44:838 (σ² = 0.003 + 5.12e-3 U)
- Strugar 2009, Continuous Distance-Dependent Level of Detail for Rendering Heightmaps (CDLOD), JGT
- ERA5 hourly single levels, 1940-present, 0.25°, CC-BY licence (Hersbach et al. 2020, QJRMS): https://cds.climate.copernicus.eu/datasets/reanalysis-era5-single-levels ; ARCO-ERA5 public Zarr (code Apache-2.0, data CC BY 4.0): https://github.com/google-research/arco-era5 (gs://gcp-public-data-arco-era5/co/single-level-reanalysis.zarr)
- NOAA-CIRES-DOE 20th Century Reanalysis V3 (US Government work, public-domain fallback; total cloud cover availability to confirm): https://psl.noaa.gov/data/20thC_Rean/
- ESSA-3/5/7/9 AVCS imagery Dec 1966-Nov 1972 scanned from film, navigated, about 10 km polar stereographic NetCDF, CC0 (NSIDC/NOAA, DOI 10.7265/N5PN93TV): https://catalog.data.gov/dataset/noaa-polar-orbiting-satellite-poes-global-visible-and-infrared-band-data-from-essa-1966-19 (the actual clouds of 21-27 Dec 1968, for validation or optional assimilation)
- NASA TM X-64796 (D. L. Johnson, 5 Dec 1973), Summary of Atmospheric Data Observations for 155 Flights of MSFC/ABMA Related Aerospace Vehicles. Table 1 (page images p. 8-9) gives the launch-time sky: AS-503 4/10 cirrus, SA-205 3/10 cumulonimbus, AS-506 1/10 cumulus, 2/10 altocumulus, 9/10 cirrostratus: https://ntrs.nasa.gov/api/citations/19740005199/downloads/19740005199.pdf
- NASA Blue Marble Next Generation, 500 m (15 arc-second) monthly 2004, 8 tiles per month: https://science.nasa.gov/earth/earth-observatory/blue-marble-next-generation/base-map ; readme: https://neo.gsfc.nasa.gov/archive/bluemarble/bmng/readme.pdf
- NASA Blue Marble 2002 (MODIS cloud composite; static weather of 2001): https://earthobservatory.nasa.gov/features/BlueMarble/BlueMarble_2002.php
- NASA Black Marble 2016 (VIIRS night lights; 0.1°, 3 km and 500 m): https://science.nasa.gov/earth/earth-observatory/earth-at-night/maps ; VNP46A4 annual radiance via NASA LAADS (Earthdata login)
- Night-light history (no digital data before 1992; DMSP low-light film from about 1970): https://eogdata.mines.edu/products/dmsp
- JRC GHSL GHS-BUILT-S R2023A, epochs 1975-2030, CC BY 4.0 (Pesaresi & Politis 2023, DOI 10.2905/9F06F36F-4B11-47EC-ABB0-4F8B7B1D72EA): https://registry.opendata.aws/ghs-built-s/
- Natural Earth 1:10m land, lakes and historic lakes, public domain: https://www.naturalearthdata.com (repo https://github.com/nvkelso/natural-earth-vector)
- NOAA ETOPO 2022 Global Relief Model, public domain: https://www.ncei.noaa.gov/products/etopo-global-relief-model
- USGS EarthExplorer: Landsat 8/9 and declassified CORONA KH-4B (1967-72), public domain: https://earthexplorer.usgs.gov
- LRO LOLA gridded LDEM products (LDEM_4 … LDEM_1024; 128 ppd = 237 m, 256 ppd = 118 m, 512 ppd = 59 m): https://ode.rsl.wustl.edu/moon/pagehelp/Content/Missions_Instruments/LRO/LOLA/GDR/GDRDEM.htm ; PDS: https://pds-geosciences.wustl.edu/missions/lro/lola.htm
- LROC WAC global mosaics (morphologic 100 m, and normalised products): https://wms.lroc.asu.edu/lroc/view_rdr/WAC_GLOBAL ; NASA SVS CGI Moon Kit 4720 (Hapke-normalised WAC colour, LOLA displacement at 4/16/64 ppd): https://svs.gsfc.nasa.gov/4720
- Optional lunar DTMs: GLD100 (Scholten et al. 2012, JGR, WAC stereo 100 m); SLDEM2015 (Barker et al. 2016, Icarus, LOLA + SELENE TC; licence of the Kaguya-derived part to verify)
- Lunar photometry: McEwen 1991, Photometric functions for photoclinometry and other applications, Icarus 92; Sato et al. 2014, Resolved Hapke parameter maps of the Moon, JGR Planets; Kieffer & Stone 2005 (ROLO), AJ 129; Lane & Irvine 1973 lunar phase curve, AJ 78; full-Moon V = −12.74 (NSSDC Moon fact sheet)
- Apollo Flight Journal, Apollo 8 Day 4 Lunar Orbit 4 (Earthrise frame times 075:47:44, 075:48:39, 075:49:09; orbit 60.4 x 61.7 n mi; 250 mm at f/11; window 4; Pasteur foreground): https://apollojournals.org/afj/ap08fj/16day4_orbit4.html
- NASA SVS 4129 Earthrise reconstruction with LRO data (Ernie Wright, 2013): https://svs.gsfc.nasa.gov/4129 ; https://www.planetary.org/articles/20131219-nasa-re-creates-the-apollo-8-earthrise-using-lro-data
- AS08-16-2593 (whole Earth from about 30,000 km, GET about 004:36, to confirm): https://commons.wikimedia.org/wiki/File:As08-16-2593.jpg ; Gateway to Astronaut Photography of Earth (frame metadata): https://eol.jsc.nasa.gov
- Apollo 8 Mission Report MSC-PA-R-69-1 (LOI-2 orbit 59.7 x 60.7 n mi, 10 revolutions, the lunar-orbit inclination to confirm): https://www.nasa.gov/wp-content/uploads/static/history/afj/ap08fj/pdf/a08-postlaunch-rep.pdf
- DSCOVR EPIC full-disc natural-colour images (NASA, public domain; modern-date check of atmosphere and clouds against ERA5 of the same day): https://epic.gsfc.nasa.gov

## Licensing

- Code: everything is written in-repo from the papers, so it is MIT by construction.
  - Hillaire's sample is MIT and Bruneton's is BSD-3 (both checked via the GitHub API). If any code is ported, keep the copyright notice in a THIRD_PARTY_NOTICES file and in the file header.
  - Do not use KSP's Scatterer (GPL-3, checked: its licence text says GNU GPL v3), KSP EVE/volumetric-cloud mods (GPL or proprietary), Orbiter's D3D9Client shaders (LGPL), NASSP (GPL), SpaceEngine assets, or GSHHG shorelines (LGPL).
  - Google's arco-era5 code is Apache-2.0. We only read its public bucket and copy none of its code.
- Data:
  - Public domain or no US copyright: NASA (BMNG, Blue Marble 2002, Black Marble, LRO LOLA/LROC, SVS CGI Moon Kit, Apollo photographs, EPIC), NOAA (ETOPO 2022, 20CRv3), USGS (Landsat, CORONA), Natural Earth, and the ESSA imagery (CC0). Credit them anyway: NASA asks for credit lines such as "NASA Earth Observatory / Reto Stöckli" and "NASA/GSFC/Arizona State University".
  - CC BY 4.0, attribution required, not CC0: ERA5 ("Contains modified Copernicus Climate Change Service information [year]") and JRC GHSL.
- Recommendation: keep all large data out of git, fetched by owner-run tools/fetch_* scripts into Application Support with SOURCES.txt manifests, and list attributions in README "Data sources" and an in-app credits/help line. Committing even small CC-BY derived products is an owner decision (options §2).
- To verify before any use: SLDEM2015 (it contains SELENE/Kaguya TC data under JAXA terms). Sentinel-2 cloudless mosaics are partly CC BY-NC-SA: avoid them.
- Logins:
  - ARCO-ERA5 and the Blue Marble/Black Marble images need none.
  - The Copernicus CDS API and NASA LAADS (VNP46A4) need the owner's own accounts. The owner runs those fetches; sessions must not handle credentials.

## Performance

Target: 60 fps (16.7 ms) on the owner's M3 Pro (18-core GPU) at native Retina 3024x1964 with 4x MSAA. The GPU budget for this area is about 6-7 ms worst case (the pad, inside clouds), about 5 ms in LEO and about 3 ms in lunar orbit, which leaves room for vessels, plumes and particles. Measure the baseline first with FrameTimes (Renderer.swift:782-792) in the flight harness, in Release.

Per-pass estimates (to be measured; they drive the presets):
- Transmittance, multiple-scattering and irradiance LUTs: CPU in OrbitCore once at launch (under 0.2 s Release); 0 per frame.
- Sky-view LUT 192x108 plus aerial-perspective froxels 32³: about 0.1-0.2 ms.
- Earth surface (ray-trace, 2-3 dependent tile fetches, LUT lookups, glint, night lights, cloud shadow): about 1.0-1.5 ms full-res.
- Space-view atmosphere march (only limb pixels, 16-32 samples): up to about 1 ms in LEO, negligible from deep space.
- Clouds:
  - near volumetric at quarter-res with 1/4 checkerboard updates (about 0.37 M rays per frame, up to 128 steps with early-out, 4-6 light samples): about 2-3 ms;
  - orbit slab march: about 1.5-2 ms;
  - far surface-layer clouds: about 0.2 ms;
  - upsample and composite: about 0.3 ms;
  - noise volumes generated once at launch: about 10 ms.
- Moon CDLOD (about 200-400k triangles), lunar-Lambert and horizon-map shadows: about 1-1.5 ms; the far fallback is the existing ray-traced sphere.
- Tone map and exposure (histogram or mip reduction): 0.3-0.5 ms (HDR track).
- Memory:
  - MSAA attachments memoryless (TBDR), resolved on store.
  - Tile atlases about 256-512 MB (Earth albedo, Moon height, normals, horizon, albedo), LRU.
  - ERA5 about 3 MB per loaded hour (two to three resident).
- CPU per frame on the main thread: quadtree selection for the Earth's virtual texture and the Moon's mesh, about 0.2-0.5 ms in double. Decoding and IO run off-thread (ImageIO, MTLIOCommandQueue).

Time warp:
- The simulation's 40 ms step budget (memory: 22 fps at any warp) makes high-warp frames CPU-bound. GPU work overlaps through three frames in flight, so these passes do not reduce the warp achieved as long as GPU time stays under the frame interval.
- Warp-specific rules:
  (a) Cloud temporal reprojection is off at 10x or more, or above 1.5 px per frame of cloud motion: fresh quarter-res frames with more steps.
  (b) Tile LOD gets a motion bias from ground speed in px per frame, and prefetch follows the predicted ground track, so streaming never chases 500 m tiles at 7.8 km/s × 1000.
  (c) ERA5 snapshots are prefetched ahead of sim time; at 10,000x a new hour arrives every 0.36 s, which is trivial at 3 MB.
  (d) The procedural cloud detail advects with the layer wind, so motion stays smooth.

Quality presets (a settings enum, persisted per viewer):
- Low (M1 8-core at 1080p): clouds 2D or far-mode only, atmosphere half-res march, 256-slot atlas, Moon pixel error 4 px.
- Medium: orbit and far cloud regimes, quarter-res near clouds without detail noise.
- High (default on M3 Pro): all regimes, quarter-res plus reprojection, 4 light samples.
- Ultra: half-res clouds, 6 light samples, 512 slots, Moon error 1 px.
- Debug builds compile the same MSL at runtime; startup shader compile grows with the source, so consider an MTLBinaryArchive cache if it exceeds about 1 s.

## Verification

Linux tests (Tests/OrbitCoreTests, fast: reduced LUT sizes in tests so the 15-18 min suite barely grows):

AtmosphereOpticsTests:
- Rayleigh optical depth from the US-1976 number density with Bodhaine's cross sections: 0.0971 at 550 nm, 0.243 at 440 nm, 0.0410 at 680 nm, within 1.5% (Bodhaine 1999 Table 3; the effective column height is about 8.43 km).
- The ozone column integrates to 300 DU.
- The relative optical air mass at zenith angle 80° is about 5.59 (Kasten & Young 1989; within 3%, no refraction).
- Transmittance is monotonic, and redder at the horizon (T_680/T_440 rises with air mass).
- The Sun is still visible at 10 km for elevation −3.0° and not at −3.5° (dip acos(R/(R+h)) = 3.2°).
- The launch-day sounding changes τ by under 1%.

AtmosphereLUTTests:
- The uv↔(r, μ) round trip.
- Multiple-scattering factors in (0, 1).
- Irradiance at the zenith Sun within 2% of the transmittance times cos plus diffuse from a brute-force reference integration.

CloudFieldTests:
- Format round trip, hourly interpolation, longitude wrap.
- The climatology fallback is bounded.
- β from LWC and r_eff (0.075 /m at 0.5 g/m³, 10 µm).
- The two-stream slab reflectance reference: R(τ = 10, g = 0.85) = 0.43.
- The TM X-64796 CSV parses, and AS-503 reads 4/10 cirrus.

CubeSphereTests / PlanetQuadtreeTests:
- Direction↔face/uv round trip and the warp's distortion bound.
- Selection covers the visible cap exactly once with no gaps.
- Horizon culling is correct with max relief.
- The tile count stays within budget; the motion bias lowers the LOD under warp.

PlanetTileFormatTests: a synthetic file round trip, and int16 height sampling with borders.

HorizonMapTests: horizon angles for a synthetic cone or crater against the analytic value, and shadow length at a given Sun elevation.

LunarPhotometryTests:
- The disc-integrated phase curve against Lane & Irvine / ROLO within about 0.2 mag at 10-120°.
- Full Moon at mean distance V ≈ −12.74, using a 1° albedo fixture derived from LROC (small, public domain).

SurfaceGeometryTests: the specular point on the ellipsoid against a brute-force search.

Apollo8GeometryTests (DE421 + IAU 2006 + MOON_ME):
- At 1968-12-24 16:39:39 UTC (AS08-14-2383): Earth lit fraction from the Moon about 0.69; subsolar longitude about −70° and latitude −23.4°; the sub-Moon point near the Gulf of Guinea; the terminator crossing Africa near 20°E. The AFJ describes South America at noon near the left limb, western Africa at sunset, Antarctica at the bottom.
- At LOI-1 (09:59:20 UTC): the lunar sunrise terminator near 20-30°E.
- At launch (12:51:00 UTC): Sun elevation at LC-39A about 7°.
- At splashdown (15:51:42 UTC, 8.1°N 165.0°W): the Sun below the horizon.
- Pin the exact values once computed, as M1 did.

Mac golden images and screenshots (shared snapshot mode: env-driven scenario, epoch, camera pose, FOV, exposure; Release; per-machine goldens with loose SSIM tolerances; the owner reviews the set):
1. Apollo 8 pad at 12:51:00 UTC looking ESE: about 7° Sun, a warm Saturn V, 4/10 cirrus. Compare with KSC launch photos of AS-503.
2. S-IC staging altitude looking down: cumulus, cloud shadows, glint.
3. Parking orbit across the terminator: the limb's layered colours, cloud tops pink and bases dark, cloud undersides lit after ground sunset, airglow if taken.
4. Orbital night with 1968 lights (adapted exposure) against modern lights.
5. TLI coast at GET about 004:36 with the 80 mm FOV (37.9°) against AS08-16-2593: phase, sub-point and large cloud systems from the 1968 ERA5 field.
6. Lunar orbit near the terminator: long horizon-map shadows against Apollo 8 lunar frames and LROC WAC images at similar incidence.
7. Earthrise photo-match at GET 075:48:39 with the 250 mm FOV (12.6°) and 1/250 s f/11: Earth phase and terminator exact; the lunar horizon silhouette over Pasteur against AS08-14-2383 and SVS 4129; Atlantic/Africa clouds compared qualitatively.
8. The full Moon from Earth orbit: photometric flatness, no limb darkening.
9. A modern-date check: render the Earth at a DSCOVR EPIC image time with ERA5 clouds for that hour, side by side. This validates atmosphere, cloud and glint colour and brightness where both truths exist; then trust 1968.
10. Optionally, compare the 1968 ERA5 cloud field with ESSA-7 imagery for 21-24 Dec 1968.

Other Mac checks:
- Performance: GPU time per pass (MTLCounterSampleBuffer or FrameTimes) at 1x and 1000x, against the baseline. Warp achieved must be unchanged.
- MTL_DEBUG_LAYER and MTL_SHADER_VALIDATION runs (memory note), and `xcrun metal -Wall` on the extracted shader strings.
- `xcodebuild build test` green.

## Files touched

- /Users/grossetti/sw/ullage/Sources/OrbitCore/Bodies/AtmosphereOptics.swift (new, A1)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Bodies/AtmosphereLUT.swift (new, A1)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Bodies/CloudField.swift (new, C1)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Bodies/CloudClimatology.swift (new, C1)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Bodies/CubeSphere.swift (new, Q)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Bodies/PlanetQuadtree.swift (new, Q)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Bodies/PlanetTileFormat.swift (new, Q)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Bodies/HorizonMap.swift (new, M1-core)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Bodies/LunarPhotometry.swift (new, M1-core)
- /Users/grossetti/sw/ullage/Sources/OrbitCore/Bodies/SurfaceGeometry.swift (new, V-geo: subsolar/sub-observer/specular points; earthshine helper moved from Renderer.vesselLight)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/AtmosphereOpticsTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/AtmosphereLUTTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/CloudFieldTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/CubeSphereTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/PlanetQuadtreeTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/PlanetTileFormatTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/HorizonMapTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/LunarPhotometryTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/SurfaceGeometryTests.swift (new)
- /Users/grossetti/sw/ullage/Tests/OrbitCoreTests/Apollo8GeometryTests.swift (new)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Renderer.swift (P0 only: frame graph, HDR, compute pre-pass, pass registration; vesselLight hook handed to the vessel-lighting owner)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/RenderTypes.swift (P0 only)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Shaders.swift (P0 only: split into the files below)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/ShaderLibrary.swift (new, P0)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/FrameGraph.swift (new, P0: FrameContext, AtmosphereContext, targets)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Planet/PlanetPass.swift (new, E2; stub from P0)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Planet/PlanetShaders.swift (new, E2; stub from P0)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Planet/AtmospherePass.swift (new, A2)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Planet/AtmosphereShaders.swift (new, A2; stub from P0)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Planet/PlanetTileCache.swift (new, E1)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Planet/EarthLayers.swift (new, E2: month selection, lights, water, relief)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Clouds/CloudPass.swift (new, C2)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Clouds/CloudShaders.swift (new, C2; stub from P0)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Clouds/CloudNoise.swift (new, C2)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Moon/MoonTerrainPass.swift (new, M2)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Moon/MoonShaders.swift (new, M2; stub from P0)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Rendering/Camera.swift (P0: settable fovY for photo-match)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/Scenarios.swift (Apollo 8 visual-check scenarios; via the mission/integration owner)
- /Users/grossetti/sw/ullage/Sources/OrbitSim/AppModel.swift (snapshot-mode hook only, shared validation track)
- /Users/grossetti/sw/ullage/Package.swift (P0: macOS-only PlanetTiles tool target)
- /Users/grossetti/sw/ullage/tools/PlanetTiles/ (new Swift CLI: earth, moon and lights subcommands owned by E1, M2 and E2)
- /Users/grossetti/sw/ullage/tools/make_clouds_era5.py (new, C1)
- /Users/grossetti/sw/ullage/tools/make_night_lights.py (new, E2)
- /Users/grossetti/sw/ullage/tools/fetch_planet_data.sh (new: owner-run downloads with SOURCES.txt and sha256)
- /Users/grossetti/sw/ullage/tools/data/tmx64796_table1_saturn.csv (new, C1: launch-time sky observations)
- /Users/grossetti/sw/ullage/README.md (data sources, planet data section, controls for exposure/photo mode)
- /Users/grossetti/sw/ullage/docs/ROADMAP.md (move 'Lunar terrain: LOLA ... quadtree LOD' forward; graphics milestone items)
- /Users/grossetti/sw/ullage/THIRD_PARTY_NOTICES (new, only if code is ported from Hillaire MIT or Bruneton BSD-3)

## Options (owner decisions)

1. Atmosphere method.
   - Default: Hillaire 2020, with the LUTs computed and tested in OrbitCore. It suits ground, orbit and deep space, has an MIT reference, and its transmittance is reused for clouds, vessels and the Sun.
   - Alternative: Bruneton 2017 (BSD-3). Constant per-pixel cost from a 4D precompute, but artefacts near the horizon and no cloud shadows inside the atmosphere.
2. Cloud data.
   - Default: historical ERA5 hourly cloud layers for each mission's dates (CC BY 4.0, user-fetched from public ARCO-ERA5, credited, not committed) plus procedural detail, with the pad sky from TM X-64796.
   - Alternatives: 20CRv3 (public domain, coarser; cloud field to confirm); procedural climatology only (no download; always the fallback); the static Blue Marble 2002 cloud texture (public domain, but 2001's weather).
3. Cloud rendering scope.
   - Default: all three regimes (near-field volumetric from the pad, orbit slab, far layer).
   - Lean: orbit and far only, with a 2D sky layer from the pad. Saves about 3-4 d.
4. ESSA-7 1968 imagery (CC0).
   - Default: use it as a validation reference only.
   - Option: assimilate it into the 21-27 Dec 1968 cloud masks (+3-5 d).
5. Earth imagery.
   - Default: BMNG 500 m, with the month matching the scenario, through the shared tile store.
   - Alternative: a single 16384x8192 equirect (about 1.2 km/px, 0.5 d), keeping the tile store for the Moon only.
6. Night lights.
   - Default: the modelled "1968 estimate" (Black Marble masked by GHSL 1975 built-up area, scaled by region, flares kept; labelled as an estimate).
   - Alternatives: none; modern Black Marble 2016, labelled anachronistic.
7. Historic hydrography.
   - Default: paint in the 1960s Aral Sea and Lake Chad from Natural Earth historic lakes.
   - Alternative: leave the 2004 state.
8. Cape inset (with the pad-area report).
   - Default: Landsat 8/9 at 15 m with the 1970s Shuttle Landing Facility painted out.
   - Alternatives: CORONA 1967-72 (period-correct, greyscale, +1.5 d); none.
9. Moon heights.
   - Default: LOLA LDEM_128 global plus LDEM_256 in Apollo 8's ±20° band (about 10 GB downloaded, about 3 GB kept).
   - Alternatives: LDEM_64 only (lean); GLD100 or SLDEM2015 for the band (fewer LOLA track-gap stripes; SLDEM needs a licence check).
10. Moon albedo.
   - Default: Hapke-normalised WAC colour (CGI Moon Kit), calibrated to the 643 nm normal albedo.
   - Never the morphologic mosaic.
   - Option: de-shade the residual topography with LOLA in the tool (+0.5 d).
11. Data distribution.
   - Default: everything large is user-fetched into Application Support with SOURCES.txt; bundle only tiny public-domain fallbacks (LDEM_4 at about 2 MB, a zonal cloud climatology table).
   - Alternative: Git LFS.
12. Exposure.
   - Default: physical auto-exposure (EV100 adaptation), plus a manual Hasselblad photo mode for photo matches.
   - Alternative: fixed artistic exposure.
13. Extras, each optional:
   - EDR output on the XDR display: 1 d;
   - airglow: 0.5 d;
   - near-surface ocean waves (M1.5's G8c): 1.75 d;
   - procedural small lunar craters: 1.5-2 d;
   - earthshine from the rendered Earth's actual albedo: 1 d.
   - Default: airglow only.

## Effort

Focused session-days, with what drives each range:
- P0 frame graph and HDR seam: 2 (1.5-3). Shared with the other graphics areas. Drives the range: MSAA/HDR resolve and depth resolve, pre-exposure, the shader split without regressions.
- A1 atmosphere optics and LUTs, core: 2.5 (2-3.5). Drives the range: parameterisation and tests against Bodhaine, Kasten-Young and the ozone column.
- A2 atmosphere rendering: 5 (4-7). Drives the range: three camera regimes, the ellipsoid in figure coordinates, aerial perspective on meshes, Sun disc and HDR calibration.
- Q quadtree, cube sphere and tile format, core: 1.5 (1-2).
- E1 tile cache and tools (BMNG, water and historic lakes, ETOPO): 5.5 (4.5-8). Drives the range: border filtering, the indirection texture, streaming under warp, the size of the data processing.
- E2 Earth surface (glint, night lights 1968, relief, monthly albedo, detail, Cape inset): 4 (3-6). Drives the range: the night-light estimate and the inset's anachronism handling.
- C1 cloud field and data (ERA5 tool, format, climatology, pad truth): 2.5 (2-4). Drives the range: ARCO-ERA5 access and the layer-height model.
- C2 cloud rendering: 10 (7-14). The largest risk. Drives the range: continuity across the three regimes, temporal reprojection with warp and camera motion, sunset lighting quality, performance at Retina.
- M1 Moon core and data (photometry, horizon algorithm, LOLA/LROC tool): 3.5 (2.5-5). Drives the range: data volume, horizon-map compute time, the albedo choice.
- M2 Moon rendering (CDLOD, geomorph, shadows, earthshine, far fallback): 5 (4-7). Drives the range: crack-free LOD on the cube sphere, precision, shadow quality at the terminator.
- V validation (Apollo 8 geometry tests 1, snapshot photo-match and goldens 1.5, performance 0.5): 3 (2-4).

Totals:
- Full area: about 44.5 d (range about 34-63).
- Lean cut (no near-field volumetric clouds, LDEM_64 only, a 16k Earth texture instead of the tile store for the Earth): about 26-30 d.
- About 14-16 calendar days with 4 Mac and 3 cloud sessions; the critical path is P0 → A2 alongside C2 → V.
- The Linux-capable share is about 11 d (A1, C1 core, Q, M1 core, V-geo).
- For scale, M1.5's design put precomputed scattering at 2-3 weeks and lunar terrain LOD at 3-4 weeks; this plan is about 1.5 weeks for the atmosphere and about 2.5 weeks for the Moon including the shared tile store.

## Risks

- Scale and the Mac bottleneck. Nothing in Sources/OrbitSim compiles on Linux. About 33 of the 44.5 d need a Mac session, every app change needs xcodebuild plus a harness screenshot, and only the core (about 11 d) runs in the cloud.
- P0 is shared. HDR and exposure change the look of everything (vessels, plumes, HUD, stars). If P0 slips or is designed by another area without the AtmosphereContext, compute pre-pass and depth resolve seams, A2, C2, E2 and M2 collide in Renderer.swift, RenderTypes.swift and Shaders.swift.
- Performance at native Retina with 4x MSAA. The volumetric clouds and the space-view march are the budget risk. Mitigations: quarter-res plus reprojection and presets. Reprojection ghosting under fast camera orbit or warp needs the fallback rules.
- Precision. Float at the Earth's radius gives about 0.5 m. Cloud noise and ocean phase need double-precision offsets from the CPU; tile and terrain origins must be camera-relative in double.
- The ellipsoid against spherical LUTs. The figure-coordinate trick keeps the error at about 0.34% of altitude; a naive spherical shell would misplace the polar limb by up to 21 km.
- Continuity across the cloud regimes (popping between volumetric, slab and surface layer). Mitigated by generating the far-field BRDF from the volumetric march, and by cross-fade bands.
- Historical cloud accuracy. ERA5 before 1979 has little satellite data, so fine structure is procedural. The pad observation can disagree with ERA5, hence the scenario override; ESSA comparisons may show misplacement.
- Data volume and logistics: BMNG 500 m is about 2 GB of PNG per month; LOLA is 2-10 GB. Downloads are owner-run, and fetch scripts must verify sha256 and be resumable. NASA URLs move: the Visible Earth image pages now redirect to science.nasa.gov.
- Licences.
  - ERA5 and GHSL are CC BY 4.0, not CC0, so attribution is required and committing derived files needs the owner's decision.
  - SLDEM2015's Kaguya part is unverified.
  - Avoid GPL and LGPL sources: Scatterer is GPL-3 (checked), plus D3D9Client, GSHHG and NASSP.
  - Some logins (CDS, LAADS) are the owner's.
- Moon data quality.
  - LOLA's equatorial track gaps stripe under low sun, exactly on Apollo 8's ground track: use GLD100 or SLDEM, or smoothing.
  - Residual topographic shading in the WAC-normalised albedo can double-shade slopes.
- Anachronisms: BMNG 2004 (Aral Sea, Lake Chad, Amazon clearing, snow cover), Landsat-era Cape features, modern lights. Mitigated by options §6-8, but some remain and should be documented.
- Time warp. Tile streaming and ERA5 prefetch must follow the predicted path. A wrong motion bias gives blurry or popping ground at warp.
- Validation brittleness. Golden images differ across GPU families and OS versions, so keep per-machine goldens and loose SSIM. Photo matches are partly qualitative (clouds); only the geometry (phase, terminator, horizon silhouette) is exact.
- Runtime shader compile time grows with the source and slows launches, especially in Debug; consider an MTLBinaryArchive.
- Some figures quoted here come from a low-precision ephemeris check and must be pinned with DE421 before tests assert them: the Earth's 0.69 phase at Earthrise, the 7° launch Sun, the 20-30°E lunar terminator. AS08-16-2593's GET (about 004:36) and Apollo 8's 12° lunar-orbit inclination must be confirmed in the Mission Report.
