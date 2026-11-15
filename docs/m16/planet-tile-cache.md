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
| `Sources/OrbitRender/Planet/PlanetTileCache/PlanetTileShaders.swift` | OrbitRender | `PlanetTileCommon` (the MSL lookup) and the probe kernel |

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
- Downloads resume. A file already recorded with a matching sha256 is skipped.
- SOURCES.txt gets one block per file: dataset, URL, licence, credit, date, size, sha256.
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
| water | `earth-water.ostiles` | PNG grey | 0-5 (1.22 km) | 255 × max(1 − land, lakes, the historic Aral Sea and Lake Chad) |
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

Measured on the M3 Pro (Release):
WATER_TIMING

## The cache

`PlanetTilePass` (P0) runs in this order each frame:
1. It finds the layers in `~/Library/Application Support/OrbitSim/Tiles`, or `ORBITSIM_TILES_DIR`, off the main thread. The albedo is the month nearest the scenario's date; E2's EarthLayers may choose otherwise.
2. It selects once through `PlanetQuadtree`, at the deepest layer's level. Each layer maps the selection through its own `finestAvailable`. All Earth layers have 256-texel tiles, so a shallower layer's selection is the deep one's tiles clamped to its levels.
3. It predicts the camera's track: a two-body arc in orbit, a straight line over the ground below 80 km. From 0.5, 1 and 2 real seconds ahead (times the warp), the views turned with the track are selected, every fourth frame. This is skipped while the ground moves under 1 km in that time.
4. It runs each layer's `PlanetTileCache.update` into one blit encoder on the frame's command buffer.

`PlanetTileCache`, for one layer:
- **Atlas.** A `texture2d_array` of (n + 2b)² slots: images in `rgba8Unorm_srgb`, `rgba8Unorm` or `r8Unorm`, with 3 mips (down to a 1-texel border); raw tiles in `r8`/`rg8`/`rgba8Unorm` or `r16`/`rg16`/`rgba16Snorm`, one mip.
- **Indirection.** An `r32Uint` `texture2d_array`, a slice per face, 2^L² at mip 0 (L = min(maxLevel, 9)), mip m for level L - m. Each entry is the finest resident tile at that level or coarser, packed as slot | level << 16 | 1 << 31.
- **Deep table.** For tiles deeper than L (the Cape's levels 10-12): an open-addressed hash of tile id to entry, linear probing, backward-shift deletion. The shader probes from the wanted level up to L, at most `maxProbe` buckets each, then reads the texture.
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

Until E2, `PlanetPass` takes the Earth's albedo from the albedo layer once anything is resident, in place of earth.jpg. Without tile files the pass does nothing: the Earth keeps today's look (earth.jpg, else the plain ocean), and the console says why and how to make the tiles (`PlanetTilePass.status`).

### Cost

CACHE_TIMING

## Tests

- Linux (OrbitSceneTests: `PlanetTileBuildTests`, `PlanetTileResidencyTests`, `PlanetTileCatalogTests`):
  - rasters: bilinear across the antimeridian, halving with no data, the work-file round trip, footprint averaging (a checkerboard to ½, taps near the pole);
  - polygons: area with a hole and an island, partial edge coverage, GeoJSON properties;
  - tiles from a synthetic field: written, read back and checksummed, within 0.006 of the field at every level; border texels equal the neighbour's inside a face, and values read through a border agree with the other face's tile across every face edge;
  - region keys round LC-39; texel footprints;
  - relief normals of known slopes;
  - TIFF: an LZW, big-endian, predictor-2 file made by macOS's `tiffutil`; tiled float with the floating-point predictor (ETOPO's layout); uint16 strips with predictor 2 (Landsat's);
  - UTM against Snyder's worked example (Clarke 1866, to 0.2 m), round trips;
  - the deep hash table against a dictionary; the indirection against a brute-force finest resident ancestor, through insertions and removals;
  - residency: parents first, leaves out, quarantine, pinned levels, current over prefetch; a simulated flight at 30× with the GPU two frames behind, which never reuses a slot an in-flight frame could read;
  - the wanted order; track prediction in orbit and on the pad; catalogs of base plus inset, orphans dropped; month discovery; texel mips.
- GPU (OrbitRenderTests `PlanetTileCacheTests`):
  - the probe kernel's lookup (indirection and deep table) and texel against the CPU mirror, through Metal's IO queue and by copy;
  - JPEG colour tiles upright in the sRGB atlas;
  - a camera crossing face edges with a 48-slot atlas and three frames in flight, every frame's probes finding that frame's tiles while slots churn;
  - memory and uniforms.
