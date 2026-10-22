# M1.6 Q: the cube sphere, the tile format and the quadtree

What track Q built for E1 (the Earth's tile store), E2, MR2 (the Moon's terrain) and M2.5 (touchdown heights), and the rules their code must follow. The design is design-earth-moon.md §3; the code is the reference, and its doc comments give the details.

| File | Target | What |
|---|---|---|
| `Sources/OrbitCore/Bodies/CubeSphere.swift` | OrbitCore | `CubeSphere` (faces, the mapping and its inverse), `TileKey`, figure directions on an `Ellipsoid` |
| `Sources/OrbitCore/Bodies/PlanetTileFormat.swift` | OrbitCore | OSTILES1: `PlanetTileFile` (reader), `PlanetTileWriter`, `PlanetTile` (bilinear lookup) |
| `Sources/OrbitScene/Planet/PlanetQuadtree.swift` | OrbitScene | `PlanetQuadtree`: CDLOD selection, culling, budget, motion bias, the morph rule and the seams |

All three are pure Swift + Foundation and are tested on Linux (CubeSphereTests, PlanetTileFormatTests, PlanetQuadtreeTests).

## Directions and faces

- Tiles live on the unit sphere of **figure directions**: body-fixed directions in figure coordinates, which are body-fixed coordinates with z stretched by a/b, so that the figure becomes a sphere of radius a. This is the frame the planet shader already ray-traces in: the direction of its hit point is the tile direction, with no latitude in between.
  - `Ellipsoid.surfacePoint(figureDirection:)` gives the surface point (a dx, a dy, b dz).
  - `figureDirection(latitude:longitude:)` takes a geodetic latitude to the parametric latitude, tan β = (1 - f) tan φ.
  - `geodeticCoordinates(figureDirection:)` is the inverse; use it to sample BMNG or LOLA rasters by latitude and longitude.
  - On the Moon's sphere a figure direction is the geocentric direction in MOON_ME.
- Faces, by outward normal. Seen from outside with +v up, u runs to the right:

  | Face | Normal | u | v |
  |---|---|---|---|
  | 0 `posX` | +x (0°) | +y (east) | +z (north) |
  | 1 `posY` | +y (90° E) | -x (east) | +z |
  | 2 `negX` | -x (180°) | -y (east) | +z |
  | 3 `negY` | -y (90° W) | +x (east) | +z |
  | 4 `posZ` | +z (north pole) | +y | -x |
  | 5 `negZ` | -z (south pole) | +y | +x |

- The mapping is gnomonic with a tangent warp per axis, a = tan(πs/4) for s = 2u - 1 (S2's "tangent" projection). Tile edges are great-circle arcs.
- Distortion over a face:
  - the area per du dv runs from 1/√2 to 1 of the face centre's, a ratio of √2 = 1.414 (the design's "about 1.4x");
  - arcs per step run from 2/3 to 2/√3 of the nominal size, `CubeSphere.tileAngle(level:)` = (π/2)/2^level.
- `direction(face:u:v:)` accepts u and v past [0, 1] by less than half a face, along the face's own projection. Tile borders are sampled that way.

## Tiles

- A `TileKey` is (face, level, x, y), with x along u and y along v. Level 0 is the whole face, and the deepest level is 27.
- `id` is a 64-bit number: face in bits 60-62, level in 55-59, y in 27-53, x in 0-26. A file's index is sorted by it.
- `neighbor(_:)` and `neighborAndEdge(_:)` give the same-level tile across each edge, including across face edges and at the cube's corners, where three tiles meet.
  - Across a face edge the along-edge coordinate may run in the opposite direction. Code that copies texels across an edge must go through directions, or through the returned edge, never through raw indices.
- `tilesAround(corner:)` gives the same-level tiles that share a corner, each with the index of its own corner there: four, or three at the cube's corners. `diagonalNeighbor(corner:)` is the one that touches only at that corner.

## OSTILES1

The byte layout is in the header comment of PlanetTileFormat.swift. That comment is the specification. The conventions that matter to a renderer:

- One file per layer and body, e.g. `earth-bmng-2004-12.ostiles`, `moon-ldem128.ostiles`. A file may hold any subset of its pyramid, such as the Cape inset's deep levels around LC-39 only. `finestAvailable(_:)` finds the deepest stored ancestor.
- A tile is (n + 2b)² texels: n = `tileSize` (256 or 512), b = `border` (4).
  - Texel (i, j) is centred at tile-local ((i - b + ½)/n, (j - b + ½)/n). Row j runs along u, and rows go up in v.
  - A GPU texture coordinate (s, t) is therefore the tile-local (u, v) mapped into the bordered texel grid, with no flip: s = (u·n + b)/(n + 2b), and the same for t.
  - Image payloads are the same grid, encoded with the minV border's row as the image's first row.
- Borders hold the face's projection carried past the tile edge (`TileKey.direction(localU:localV:)` with local coordinates outside [0, 1]). Within a face that is exactly the neighbour's texels, so bilinear and anisotropic filtering never leave the tile.
  - Across a face edge the border is a resample, so the two sides agree to interpolation error. For the Moon's mesh, either take the edge vertices' heights from one side or average the two in the tool.
- Raw payloads (int16 or uint8, channels interleaved) give value = raw × scale + offset, with an optional no-data raw value.
  - Heights are metres above the figure along its normal: LOLA's are above the 1737.4 km sphere.
  - `PlanetTileWriter.add(_:values:)` writes nil, and any value that is not finite (a resampler's NaN over a gap), as no data. A layer without a no-data value refuses them.
  - The index keeps each tile's least and greatest value, borders included. The quadtree uses them as tighter per-tile height bounds: pass `tileHeights: { file.valueRange($0) }`. A file whose index holds a range that is not finite, or whose least value exceeds its greatest, fails to open; the writer refuses a range a Float32 cannot hold.
- Every payload has a CRC-32, and `verify()` checks them all. Payloads start on 16-byte boundaries, so MTLIOCommandQueue can load them by offset and length from `entry(_:)`.
- Metadata is a JSON object of strings. Suggested keys: `source`, `url`, `sha256`, `date`, `tool`, `licence`.
- Heights in the core, for M2.5's touchdown:
  - `file.height(below: bodyFixedPosition)` reads the terrain at the foot of the normal;
  - `file.height(latitude:longitude:)` reads it at a geodetic position;
  - `file.value(at: figureDirection)` reads any layer.

  All three are bilinear in the deepest stored tile, like the GPU's filter.

## The quadtree

- `PlanetQuadtree(parameters).select(view, previous: lastFrame)` returns `Selection.tiles`, sorted by id. Each visible point of the surface lies in exactly one of them. The result depends only on the arguments.
- Inputs:
  - **Parameters:** the figure, `maxLevel`, and `samplesPerTile` (the layer's texels, or the mesh grid's quads); `pixelError`; `tileBudget`; `heightRange` (0...0 for imagery on the figure, `PlanetQuadtree.moonRelief` for the Moon) with optional per-tile heights; the morph start ratio; and the frames per tile for the motion bias.
  - **View:** body-fixed, built by `view(cameraPosition:worldToView:fovY:viewportWidth:viewportHeight:orientation:velocity:warp:frameInterval:)` from what the renderer has.
- Level ℓ is fine enough from its detail distance a·tileAngle(ℓ)/samplesPerTile/(pixelError·pixelAngle) outwards. The detail distance halves per level.
- Culling is conservative, and nothing visible is culled:
  - the horizon is exact for the occluding figure, lowered by the least height;
  - the frustum's four side planes are tested against a cap around each tile.
- Selected tiles that touch, across an edge or only at a corner, differ by at most one level. A balancing pass splits any tile that touches one two or more levels finer.
- Each tile's `seams` say what it meets across each edge and round each corner: tiles of its own level (or none), a finer tile, or a coarser one. MR2's vertex rule needs them (below).
- Budget: when the selection would exceed `tileBudget`, the detail distances shrink by half an octave at a time (`lodBias`). Past 8 octaves the level limit drops instead.
- Motion: no tile is finer than the ground covers in `minimumFramesPerTile` (4) frames (`levelLimit`); 0 switches the bias off. Ground speed is the camera's horizontal body-fixed speed scaled to the surface.
  - In the parking orbit this has no effect at 1×. It stops at level 10 at 10× and at level 4 at 1000×.
  - BMNG at about level 7 is limited only from about 160×.

### For E1 (streaming the Earth's imagery)

- Make resident, for each selected key, `finestAvailable(key)` in the layer's file. Sample per pixel through the indirection texture at the finest resident ancestor.
- The selection is purely geometric, so it never depends on what is loaded. Prefetch along the predicted track by selecting a few future views.

### For MR2 (the Moon's CDLOD mesh)

- Each tile is an N-quad grid, with N even (32 in the design). Every cell is split along its (0, 0)-(1, 1) diagonal.
- Tile origins are camera-relative, in double on the CPU.
- Per instance, upload `Tile.seams` as it is: 16 bits, two per edge (bits 0-7, by `TileKey.Edge.rawValue`) and two per corner (bits 8-15, in `TileKey.corners` order), each 0 for its own level, 1 for finer, 2 for coarser.
- Per vertex, `Tile.morph(column:row:gridSize:distance:)` is the reference:
  - on a corner (both indices 0 or N), the corner's seam; else on an edge (one index 0 or N), that edge's seam: finer pins m = 0 and coarser pins m = 1;
  - otherwise, and on a seam of its own level, m = clamp((d - morphStart)/(morphEnd - morphStart), 0, 1), where d is the distance from the camera to the unmorphed vertex, placed with the tile's own heights. Level 0 never morphs (both bounds are infinite; upload a sentinel).
  - The vertex's height blends to the parent level's height at its position, with factor m.
  - The vertex moves toward its morph target, with factor m. The target is the vertex itself if both its indices are even. Otherwise it is the midpoint of the two vertices `PlanetQuadtree.morphTargets(column:row:)` names, placed with the parent level's heights.
- At m = 1 a tile is exactly its parent's mesh. Where two levels meet, the finer tile is pinned to its parent's mesh and the coarser to its own, which is the same mesh, so there are no cracks, whatever the distances. At a corner where two levels meet, every tile round it draws the coarser level's height.
  - The distance morph alone would not do. Selection bounds only the nearest point of a tile's volume, so a coarse tile's vertices on an edge it shares with a finer tile can lie a tile diagonal plus its height range past its detail distance, beyond its morph start. A tight budget (2.5 to 3.5 octaves of bias in the tests' views), a grid too coarse for its tiles, and the balancing pass's splits all get there. Where the distance bands do hold, the pins agree with them and change nothing.
  - The rule is symmetric, so it also holds across face edges, where the grids run in opposite directions. Strugar's original rule, which collapses odd vertices to the lower even index, would crack there.
  - Tiles of three levels never meet at a corner, so the heights there can always agree.
- The coarse heights come from the parent level's data. In a pyramid cache the parent is resident whenever the child is.
- Tuning: with 32-quad grids at 1 px and the full ±10 km relief, a view from 15 km selects about 42,000 tiles. Use about 4 px, per-tile height ranges from the file's index, and the budget.

### Cost

Measured on an Apple M3 Pro, release build, the fastest of 60 selections. A cold selection is `select(view)`; a warm one passes the last frame's selection as `previous`.

| View | Tiles | Cold | Warm |
|---|---|---|---|
| The parking orbit at 185 km, toward the limb, BMNG to level 7 | 302 | 0.09 ms | 0.09 ms |
| The same, down to level 14 | 534 | 0.16 ms | 0.16 ms |
| The pad at 100 m, down to level 16 | 1,004 | 0.29 ms | 0.29 ms |
| The same, budget 384 (bias 1) | 356 | 0.23 ms | 0.17 ms |
| The Moon from 15 km, 32-quad grids at 4 px, full relief, to level 12 | 4,490 | 1.4 ms | 1.4 ms |
| The same over a face edge, to level 16 | 5,911 | 2.0 ms | 2.0 ms |
| The same, budget 384 (bias 2.5) | 286 | 0.41 ms | 0.16 ms |

- The seams and the corner balancing cost 5 to 15% on top of the selection without them, measured the same way. The Linux cloud runner took about twice as long as this Mac before them.
- The plan budgets 0.5 ms of CPU per frame for the quadtree. Pass `previous` every frame.
- An over-budget pass stops as soon as it passes the budget. A warm frame is then usually one such short pass plus one that fits.
- Detail comes back by half an octave a frame as the pressure eases.
