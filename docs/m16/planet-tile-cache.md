# M1.6 E1: the Earth's tile store, its tools and its cache

Track E1 (plan.md §M1.6 briefs; design-earth-moon.md §3-4) builds on track Q's cube sphere, OSTILES1 format and quadtree (planet-tiles.md). It covers three things:
- the owner-run fetch;
- `PlanetTiles earth`, which turns the fetched sources into tile files;
- the GPU cache that streams those files while the app flies.

E2 (the Earth's surface and ocean) reads the cache. Until E2 lands, the planet pass takes only its albedo from it.

| File | Target | What |
|---|---|---|
| `tools/fetch_planet_data.sh` | owner-run | downloads with SOURCES.txt, resumable, `--dry-run` |
| `tools/PlanetTiles/{main,Earth,Landsat,Support}.swift` | macOS tool | `earth albedo|water|relief|cape|all|demo`, `info`, `tiff` |
| `tools/data/cape_paintout.json` | data | the strips painted out of the Cape inset |
| `Sources/OrbitScene/Planet/GeoRaster.swift` | OrbitScene | latitude-longitude rasters, mips, footprint sampling, the OSRASTR1 work files |
| `Sources/OrbitScene/Planet/GeoPolygons.swift` | OrbitScene | GeoJSON polygons, antialiased even-odd rasteriser |
| `Sources/OrbitScene/Planet/PlanetTileBuilder.swift` | OrbitScene | texels by geodetic latitude and longitude, footprints, region keys, parallel ordered builds |
| `Sources/OrbitScene/Planet/ReliefNormals.swift` | OrbitScene | normals in the local east-north-up frame |
| `Sources/OrbitScene/Planet/TIFFReader.swift` | OrbitScene | TIFF/GeoTIFF: strips, tiles, predictors 2 and 3, LZW; Deflate handed in |
| `Sources/OrbitScene/Planet/TransverseMercator.swift` | OrbitScene | UTM for the Landsat scene (Krüger to n⁴) |
| `Sources/OrbitScene/Planet/PlanetTileCatalog.swift` | OrbitScene | a layer's files as one (base plus insets), finding the Earth's layers, texel mips |
| `Sources/OrbitScene/Planet/PlanetTileIndirection.swift` | OrbitScene | the indirection's CPU mirror and its deep hash table |
| `Sources/OrbitScene/Planet/PlanetTileResidency.swift` | OrbitScene | slots, parents first, LRU leaves, in-flight quarantine; the wanted order |
| `Sources/OrbitScene/Planet/PlanetTrackPredictor.swift` | OrbitScene | the camera's velocity, two-body arcs, the view turned with the track |
| `Sources/OrbitScene/Settings/PlanetTileSettings.swift` | OrbitScene | memory, uploads, prefetch, synchronous loads |
| `Sources/OrbitRender/Planet/PlanetTileCache/PlanetTileCache.swift` | OrbitRender | the atlas, indirection and deep table on the GPU; streaming |
| `Sources/OrbitRender/Planet/PlanetTileCache/PlanetTileLoader.swift` | OrbitRender | ImageIO decodes and Metal IO loads off the main thread |
| `Sources/OrbitRender/Planet/PlanetTileCache/PlanetTilePass.swift` | OrbitRender | the P0 pass: layers, selection, prefetch, updates, status |
| `Sources/OrbitRender/Planet/PlanetTileCache/PlanetTileShaders.swift` | OrbitRender | `PlanetTileCommon` (the MSL lookup), the probe kernel, and `.planetTiled`, the planet shader with the albedo tiles |

## Fetching (owner-run)

```sh
tools/fetch_planet_data.sh --dry-run     # sizes, nothing downloaded
tools/fetch_planet_data.sh               # BMNG July and December, Natural Earth, ETOPO 2022, then Landsat
```

What it fetches, into `~/Library/Application Support/OrbitSim/Sources/earth`:

| Dataset | Files | Size | Licence |
|---|---|---|---|
| NASA Blue Marble Next Generation 2004, base map ("world"), 500 m, per month | 8 lossless GeoTIFFs (`--bmng-format jpg`: NASA's JPEGs) | 2.42 GB per month as GeoTIFF; 0.36 GB as JPEG | public domain; credit NASA Earth Observatory (Reto Stöckli) |
| Natural Earth 1:10m land, lakes, historic lakes (commit ca96624, as tools/make_landmask.py) | 3 GeoJSON | 15 MB | public domain |
| NOAA ETOPO 2022, 30" surface elevation | 1 GeoTIFF | 1.59 GB | public domain (NOAA NCEI) |
| Landsat 9 OLI C2 L1, LC09_L1TP_016040_20221209_20230318_02_T1 (9 Dec 2022, 0.08 % cloud over land) | B2, B3, B4, B8, MTL | about 0.45 GB | public domain (USGS) |

- July and December come by default, 6.48 GB; adding October (`--months 07,10,12`) makes 8.97 GB. The Landsat scene comes on top.
- The script runs its arithmetic in the C locale, so sizes print right under a comma-decimal locale. A 404, a timeout or no network shows the file as NOT FOUND, and nothing is fetched.
- First the script lists every file and asks its size. It prints the total and the disk's free space, stops if the download would not fit, and warns if building the tiles (up to 18 GB more) would not.
- Downloads resume. A file already recorded with a matching sha256 is skipped.
- SOURCES.txt gets one block per file: dataset, URL, licence, credit, date, size, sha256, and a note of what PlanetTiles changes in it.
  - BMNG: the 1960s Aral Sea and Lake Chad painted in.
  - Landsat: pan-sharpened, the SLF cloned out, colour-matched, feathered.
  - The Cape tile file's own metadata says the same.
- Landsat Collection 2 Level-1 needs a USGS ERS sign-in: the LandsatLook URLs redirect to ers.cr.usgs.gov, and `s3://usgs-landsat` is requester-pays. The script lists the five files to download while signed in and checks them on its next run. `--landsat-aws` fetches them with your AWS credentials instead.

## Building the tiles

```sh
swift run -c release PlanetTiles earth all       # water, relief, every month's albedo, the Cape
swift run -c release PlanetTiles info ~/Library/Application\ Support/OrbitSim/Tiles/*.ostiles
```

Every layer uses 256-texel tiles with 4-texel borders on WGS 84. Each texel, borders included, is sampled where it lies on the Earth: its figure direction goes through `geodeticCoordinates(figureDirection:)` to the source's latitude-longitude grid. Each source is averaged over the texel's footprint: its pyramid level matches the footprint's shorter side, interpolated with the next, with taps along the longer side near the poles. So no level aliases, and the borders hold the same function as the neighbours: within a face they are exact, across a face edge they are a resample.

| Layer | File | Format | Levels | From |
|---|---|---|---|---|
| albedo | `earth-bmng-2004-MM.ostiles` | JPEG q 0.9, RGB | 0-7 (texel 305 m nominal) | BMNG month; sRGB mips in linear light; the late-1950s Aral Sea and early-1960s Lake Chad painted in |
| albedo inset | `earth-cape-landsat.ostiles` | JPEG, RGB | 8-12 over 28.30-28.85° N, 80.85-80.45° W | the Landsat scene, see below |
| water | `earth-water.ostiles` | PNG grey | 0-5 (1.22 km) | 255 × max(1 − land, lakes, the historic Aral Sea and Lake Chad), each set filled in a pass of its own (`WaterMask`): the modern lakes lie inside their 1960s outlines, and one even-odd pass would make them holes |
| relief | `earth-relief.ostiles` | PNG RGB | 0-5 | ETOPO 2022 heights, normals (east, north, up) as 0-255; flat over water |

- **The 1960s lakes (decision 33).** Natural Earth's historic-lakes layer holds four lakes. The tool takes the Aral Sea ("late 1950s") and Lake Chad ("early 1960s"); Lake Texcoco (1500s) and Lop Nur (1970s) are left out.
  - The water layer takes both outlines in.
  - The albedo mosaic is painted at BMNG's own 15" before its pyramid. Each lake's colour is the darkest 30 % of its own 2004 water (Natural Earth's modern lakes inside it). If those are not bluer than red, a deep-lake sRGB (24, 44, 58) is used instead. The paint is blended by coverage where 2004 is dry.
- **Relief.** Normals come from central differences of the footprint-averaged heights, half a texel either side. Water at a sample point takes the centre's height, so lakes at altitude (Titicaca) do not cliff, and water texels are straight up. E2 turns them with the ellipsoid's normal and may exaggerate their x and y.
- **The Cape inset.**
  - Bands 2-4 (30 m) and 8 (15 m) are read in their UTM zone-17 grid, through `TransverseMercator`, as top-of-atmosphere reflectance from the MTL's rescaling. They are pan-sharpened (Brovey).
  - The Shuttle Landing Facility runway is painted out with ground cloned from 500 m to its south-west: 15/33 with its 305 m overruns, half-width 75 m. The ends are the FAA's runway-end coordinates, in `tools/data/cape_paintout.json`.
  - Colours are matched to the BMNG month by a per-channel least-squares gain and offset, over every clear 15" BMNG texel in the region. The inset is feathered into BMNG over 2 km at the region's edge and wherever the scene has no data. Levels 8-12 come from it; 0-7 stay the base file's.
  - **Open:** the SLF's apron, its mate-demate site and the tow-way to the VAB are not yet in the paint-out file. They are added once `PlanetTiles earth cape --preview FILE` shows the fetched scene.

Work space: the albedo mosaic is 86,400 × 43,200 RGB, 11.2 GB, plus its pyramid (3.7 GB), mapped from files in `~/Library/Application Support/OrbitSim/Work`. They are deleted after each month unless `--keep-work`.
- The mosaic is written as `bmng-MM-0.osrastr.partial` and renamed only once every BMNG tile is in and the lakes are painted (`GeoRasterFile.build`).
- A run interrupted by Ctrl-C, a kill, a full disk or a missing tile leaves at most the .partial, which the next run starts over. A complete mosaic of the same shape is reused.

Measured on the M3 Pro, in Release:
- `earth water`, on the real Natural Earth files: 18.7 s wall, 152 s of CPU and 1.5 GB resident at most.
  - That covers rasterising 6,837 land polygons and 1,368 lakes on the 30" grid (43,200 × 21,600), the pyramid, and 8,190 tiles to level 5.
  - The file is 15.3 MB: 1.6 KB a tile at level 5, 12.8 KB at level 0. Its checksums verify. The Aral Sea and Lake Chad tiles show their late-1950s and early-1960s outlines.
- `earth demo --image Textures/earth.jpg --max-level 4` (BMNG July at 8 km): 2,046 tiles, 14.9 MB, 3.6 s.
- `PlanetTiles tiff`: the reader matches ImageIO on NASA's 5400 × 2700 BMNG GeoTIFF (Deflate strips), on all 43.7 M samples.
- `PlanetTiles earth cape-selftest` runs the Cape's processing on a synthetic scene: uint16 GeoTIFFs tied PixelIsPoint in UTM zone 17, an MTL, a bright runway on the SLF's line, and a BMNG window made from it by a known mapping. 688 tiles at levels 8-12 in 7 s.
  - The colour match finds gain 0.798 and offset 0.0201 per channel, against 0.8 and 0.02.
  - The runway's middle drops from about 166 to 68 (scrub).
  - The region's edge matches BMNG to under one code.
  - A faint seam remains where the cloned strip meets the synthetic texture. Judge it on the real scene's preview.
- After the review's fix the Aral Sea and Lake Chad tiles are water throughout, the modern lakes inside them included (the first build had them as land).
- **Not yet run:** the albedo, relief and Cape steps on the full sources, which need the owner's fetch. From the water step's rate, a month of albedo (131,070 tiles; reading and decompressing 2.4 GB of GeoTIFF; the 11 GB mosaic and its pyramid) should take about 10-20 min, and `earth all` with two months about 30-45 min. `PlanetTiles info` prints what came out.

## The cache

`PlanetTilePass` (P0) runs in this order each frame:
1. It finds the layers in `~/Library/Application Support/OrbitSim/Tiles`, or `ORBITSIM_TILES_DIR`, off the main thread. The albedo is the month nearest the scenario's date; E2's EarthLayers may choose otherwise.
2. Each layer selects through `PlanetQuadtree` on its own:
   - to its own deepest level;
   - within its own budget, `selectionShare` (0.5) of its own slots: 220 tiles for the albedo, 146 for the water, 110 for the relief;
   - refining only where finer tiles are stored, through `refinable: catalog.hasStoredChildren`, an opt-in parameter E1 added to Q's quadtree. The albedo with the Cape inset therefore goes past level 7 only over the Cape (and in the balancing ring round it), and spends no budget on levels 8-12 elsewhere.
   - Each layer maps its selection through its own `finestAvailable`, to the deepest stored ancestor.
3. It predicts the camera's track: a two-body arc in orbit, a straight line over the ground below 80 km.
   - The views 0.5, 1 and 2 real seconds ahead (times the warp), turned with the track, are made every fourth frame.
   - Each layer selects them on a frame of its own, warm-started from its last ones, so the layers' prefetch selections never land on the same frame.
   - All of this is skipped while the ground moves under 1 km in that time.
4. It runs each layer's `PlanetTileCache.update` into one blit encoder on the frame's command buffer.

`PlanetTileCache`, for one layer:
- **Atlas.** A `texture2d_array` of (n + 2b)² slots: images in `rgba8Unorm_srgb`, `rgba8Unorm` or `r8Unorm`, with 3 mips (down to a 1-texel border); raw tiles in `r8`/`rg8`/`rgba8Unorm` or `r16`/`rg16`/`rgba16Snorm`, one mip.
- **Indirection.** An `r32Uint` `texture2d_array`, a slice per face, 2^L² at mip 0, mip m for level L - m. Each entry is the finest resident tile at that level or coarser, packed as slot | level << 16 | 1 << 31.
  - L is the deepest level the layer stores everywhere (`catalog.completeLevel`), at most `maxTextureLevel` (9): 7 for BMNG with or without the Cape inset, 5 for the water and relief.
  - So the albedo's texture is 0.5 MB on the GPU, plus the same on the CPU, never 8 MB for an inset.
- **Deep table.** For tiles deeper than L (the Cape's levels 8-12): an open-addressed hash of tile id to entry, linear probing, backward-shift deletion.
  - The shader probes from the wanted level up to L+1, at most `maxProbe` + 1 buckets each, then reads the texture.
  - A pixel that wants a level past 7 makes up to five probes, at most 5 × (maxProbe + 1) bucket reads, even away from the Cape, before it finds BMNG's level 7.
- **Residency.** Parents first and leaves out, so every resident tile's ancestors are resident. Levels 0-1 (30 tiles) are pinned and always wanted first, so every point has a tile from the first frames on. Use stamps make the current selection's tiles evict prefetched ones and never the other way round.
- **Frames in flight.** An evicted slot is quarantined until the GPU has finished the frame that dropped it, which the command buffers' completion handlers report. Staging buffers are recycled the same way. Uploads (each mip by blit from a staging buffer) and the indirection's changed rectangles go into the frame's own command buffer, so they are ordered with the frames that read them. A changed deep table is a new buffer; in-flight frames keep the old one.
- **IO.** Images are decoded by ImageIO on a concurrent background queue into the staging buffer, with their mips made on the CPU (sRGB in linear light), and no colour management. Raw tiles load through `MTLIOCommandQueue` straight from the file into the staging buffer, since payloads start on 16-byte boundaries.
- **Limits.** At most `uploadsPerFrame` (12) uploads and `maxPendingLoads` (24) loads per layer. `synchronous` loads everything wanted before the frame.
- **Memory.** `atlasMemoryMB` (256) is split 60/10/30 between albedo, water and relief. Each slot takes (n + 2b)² × texel bytes × 4/3.

The MSL side is `ShaderHeader.planetTileCommon`:
- `planet_tile_face`: a figure direction to its face and face coordinates, as `CubeSphere.faceCoordinates`.
- `planet_tile_uv_delta`: screen derivatives of the direction to face coordinates, analytically, so the hardware filters each tile with its true anisotropic footprint and nothing jumps at tile edges.
- `planet_tile_level`: the level for that footprint, allowing 8× anisotropy.
- `planet_tile_find`: the deep table, then the indirection.
- `planet_tile_sample`, and `planet_tile_sample_level` for an explicit mip.
- A layer is bound with `PlanetTileCache.bindFragment` or `bindCompute`: atlas, indirection, deep table and `PlanetTileLayer` uniforms.

Until E2, `PlanetPass` takes the Earth's albedo from the albedo layer once anything is resident, in place of earth.jpg. This is a minimal hook, marked `E2 replaces`:
- The tiled Earth draws with `ShaderModule.planetTiled`: E2's `planetShaderSource` with the tile arguments inserted after its sampler and the lookup before its grid.
- Every other draw (no tile files, the Moon, the user's textures off) uses the plain `.planet` module. PlanetShaders.swift is unchanged from main.
- If the planet shader loses those two anchors, the tiled module carries an `#error`. ShaderCompileTests says so, and the Earth stays untiled.

- `planetTile.enabled` off draws the fallback look even with tiles resident.
- Snapshots (`SnapshotRenderer`) always load the user's tiles synchronously. A snapshot is one whole frame, and no run loop would deliver a catalog opened in the background.

Without tile files the tile pass does nothing, and the console says why and how to make the tiles (`PlanetTilePass.status`). Every image is byte-identical to main's:
- orbitsnap at main 231113f and on this branch, with an empty tile directory, render the golden specs' 57 shots to identical PNG and PFM files;
- `PlanetTileFallbackTests` renders four planet shots through the default passes with an empty tile directory and through the same passes without the store, and requires the same bytes. With an all-magenta July albedo layer it renders the Earth magenta, and plain again with `planetTile.enabled` off;
- a planet module compiled with the tile code switched off by a function constant did *not* give identical images: it moved a few dozen fp16 samples on 20 shots. Hence the separate module.

### Cost

**Atlas memory**, at the default `atlasMemoryMB` = 256:

| Layer | Slots | Atlas | Indirection |
|---|---|---|---|
| albedo (RGBA8 sRGB, 3 mips) | 440 | 153.5 MB | 0.5 MB on the GPU and as much on the CPU: levels 0-7, BMNG's complete levels; the Cape's 8-12 are in the deep table, 14 KB for 880 buckets |
| water (R8, 3 mips) | 293 | 25.6 MB | 32 KB |
| relief (RGBA8, 3 mips) | 220 | 76.8 MB | 32 KB |

Staging buffers come on top: at most 68 per layer, at 372 KB each for albedo, and they are recycled.

**Streaming** comes from `PlanetTileTimingTests` (`ORBITSIM_TIMINGS=1`; Release; holds the GPU lock).
- **The configuration is the app's:** PlanetTilePass's own frame logic over three caches with the slots it gives them at 256 MB:
  - the albedo with the Cape inset over it, to level 12;
  - the water;
  - the relief.
- **The tiles** are coloured value noise, about as heavy to decode as BMNG's land:
  - the albedo and inset as 264² JPEGs at q 0.9, 9.7 KB each;
  - the water as PNG, 1.9 KB;
  - the relief as PNG, 11.4 KB.
  - Full pyramids go to level 5. The albedo has levels 6-7 where the flight wants them, so its indirection texture stops at 5 here (BMNG's goes to 7), and the inset covers levels 8-12 over the Cape.
- **The flight:** the parking orbit (185 km, 32.5°, the Earth turning), the camera looking 20° below the horizontal ahead, 50° high on 3,024 × 1,964, 300 frames at each warp. Then 30 km over the Cape looking at LC-39, where the inset streamed to level 11.
- **Pacing:** 60 frames a second with three frames in flight. The first second of each segment, which loads its first view, is left out.
- **Load:** other sessions kept the Mac loaded (load 4.5-6). Between such runs the main-thread times vary by up to about 1.6×; this is the quietest.

| Segment | Main thread, ms (mean / max) | Uploads per frame (mean / max) | Upload, MB per frame | Decode, CPU ms per frame | GPU blit, ms (mean / max) | Wanted but not resident (mean / max) | Frames with any |
|---|---|---|---|---|---|---|---|
| 1× | 0.63 / 2.2 | 0.08 / 4 | 0.03 | 0.08 | 0.02 / 1.8 | 0 / 0 | 0 of 300 |
| 10× | 0.60 / 2.3 | 0.49 / 12 | 0.17 | 0.39 | 0.14 / 1.9 | 0 / 0 | 0 of 300 |
| 100× | 0.91 / 3.8 | 6.7 / 17 | 2.2 | 6.5 | 0.13-1.0 / 2.0 | 5.1 / 82 | 207 of 300 |
| 1000× | 0.41 / 0.89 | 6.8 / 18 | 1.9 | 5.9 | 0.19-0.89 / 2.4 | 0.4 / 6 | 69 of 300 |
| Cape, 30 km, 1× | 0.36 / 0.90 | 0 / 0 | 0 | 0 | 0.00 / 0.00 | 0 / 0 | 0 of 180 |

- **Main thread at 1×, for the three layers:**
  - 0.21 ms of selections;
  - 0.16 ms of prefetch on average, at most about 1.3 ms on a frame that selects the albedo's three prefetch views;
  - 0.08 ms for the wanted lists;
  - 0.18 ms for the three caches' updates.
  - The selections stay under the 0.5 ms the plan gives the quadtree, and the whole pass's average is 0.6 ms.
- **No refusals.** No tile was ever ready without a slot.
- **Decode** costs about 1 ms of CPU per 264² tile with its mips, on the background threads.
- **Upload** costs 0.35 MB per albedo tile (three mips), plus the indirection's changed rectangles. The GPU time of the frame's blits varied between runs with the other sessions' GPU work; the ranges are the means seen.
- **At 100×**, BMNG's level 7 is still selected: the quadtree's motion limit only cuts it from about 160×. Level-7 tiles cross the view every few frames, so about two-thirds of the frames show a few tiles one level coarse while their finer tile streams in.
- **At 1000×** the motion limit holds every layer to level 4, and the three layers stream about 7 tiles a frame between them.
- **Over the Cape** the inset's tiles (deep table) stream in within the first second; after that nothing loads.

**The planet pass's lookup** in place of the single equirect sample (`orbitsnap --timings 60`, 3,024 × 1,964, the July demo layer):

| Shot | Planets pass with tiles | With earth.jpg |
|---|---|---|
| the whole Earth from 22,000 km | 0.87 ms | 0.82 ms |
| the parking orbit's limb | 0.85 ms | 0.75 ms |
| the ground filling the screen from orbit | 1.21 ms | 0.91 ms |

The tile pass itself takes 0.00 ms on frames that upload nothing.

## Tests

- Linux (OrbitSceneTests: `PlanetTileBuildTests`, `PlanetTileResidencyTests`, `PlanetTileCatalogTests`):
  - rasters: bilinear across the antimeridian, halving with no data, the work-file round trip, footprint averaging (a checkerboard to ½, taps near the pole); a work raster reused only when its build finished, never an interrupted one's .partial;
  - polygons: area with a hole and an island, partial edge coverage, GeoJSON properties; the water mask with modern lakes nested in a 1960s outline;
  - selection refined only where tiles are stored: no budget bias over the Pacific where refining to 12 everywhere overruns it, levels 10+ over the Cape;
  - tiles from a synthetic field: written, read back and checksummed, within 0.006 of the field at every level; border texels equal the neighbour's inside a face, and values read through a border agree with the other face's tile across every face edge;
  - region keys round LC-39; texel footprints;
  - relief normals of known slopes;
  - TIFF: an LZW, big-endian, predictor-2 file made by macOS's `tiffutil`; tiled float with the floating-point predictor (ETOPO's layout); uint16 strips with predictor 2 (Landsat's);
  - UTM against Snyder's worked example (Clarke 1866, to 0.2 m), round trips;
  - the deep hash table against a dictionary; the indirection against a brute-force finest resident ancestor, through insertions and removals;
  - residency: parents first, leaves out, quarantine, pinned levels, current over prefetch; a simulated flight at 30× with the GPU two frames behind, which never reuses a slot an in-flight frame could read;
  - the wanted order; track prediction in orbit and on the pad; catalogs of base plus inset, orphans dropped; month discovery; texel mips.
- GPU (OrbitRenderTests `PlanetTileCacheTests`, `PlanetTileFallbackTests`):
  - without tile files, the frame is byte for byte the one without the store; the plain planet module has nothing of it;
  - the probe kernel's lookup (indirection and deep table) and texel against the CPU mirror, through Metal's IO queue and by copy;
  - JPEG colour tiles upright in the sRGB atlas;
  - a camera crossing face edges with a 48-slot atlas and three frames in flight, every frame's probes finding that frame's tiles while slots churn;
  - memory and uniforms.
