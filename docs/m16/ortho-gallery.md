# The Linux ortho gallery (M1.6 track L0)

Test support for seeing and measuring vehicle geometry without Metal, so
that cloud sessions (VG1-VG3, VM1, LC) can check what they build. Its code
is in `Tests/OrbitSceneTests/Support`:

- `OrthoRaster.swift`: the rasteriser, and `OrthoSheet`, which puts several views on one file and records where each landed;
- `PNG.swift`: the PNG writer;
- `Silhouette.swift`: the outline measures.

It reads only OrbitCore, so it could move to another test target's
Support folder. Test support is visible only inside its own target: tests
that use it live in `Tests/OrbitSceneTests`.

## Writing the gallery

```sh
ORBITSIM_ORTHO_DIR=/path/to/dir swift test --filter OrthoGallery
```

- The command writes PNGs and an `index.txt` into the directory, creating it if needed. Without the variable the test is skipped.
- It takes about 40 s in Debug, and about 20 s through `scripts/test.sh fast --filter OrthoGallery` (the variable passes through).
- The files total about 50 MB, because stored deflate leaves them uncompressed.
- Open the images with the Read tool. Each file is read back and must decode to the image written.
- Pillow also opens them.

What it draws:

| File | Shows |
|---|---|
| `saturn-v-positions.png` | The stack from Positions I-IV, side by side (14 px/m) |
| `saturn-v-top.png`, `-bottom.png` | The stack from above and from below (40 px/m) |
| `saturn-v-<band>-positions.png` | Crops at 40-50 px/m, from Positions I-IV: `sic-base` (STA −120 to 560), `sic-sii-interstage` (1400-1950), `sii-sivb-interstage` (2450-2900), `spacecraft` (3150-4245) |
| `saturn-v-sic-base-bottom.png` | The F-1s and the S-IC base from below, cut at STA 130 |
| `saturn-v-sic-section-top.png` | The S-IC's base region from above, cut at STA 400 |
| `csm-apollo-11-*.png`, `csm-apollo-7-*.png` | The CSM alone: Positions I-IV (80 px/m), top and bottom (100 px/m) |

How to read the images:

- **Side views** are drawn nose up. A strip on the left has a tick every 100 in STA, a longer one every 500 in, and the label in inches. Xa = STA − 2756.56.
- **Position numerals.** The Position facing the viewer is at the top. The Positions seen edge-on are at the left and right: a Position I view has II on the right and IV on the left.
- **Top and bottom views** put Position I at the bottom. From above, II is on the right; from below, IV is.
- **Sheets.** A file of several panels (every `-positions.png`) has an 8 px border round them and 8 px gutters between them, lighter than the background so the panels' edges show. Its first panel's top-left pixel is (8, 8), not (0, 0), and the later panels start after the earlier ones' widths and gutters; the widths differ with the view. A file of one image (`-top`, `-bottom`, the sections) is that image, its panel at (0, 0).
- **`index.txt`** gives, for each panel of a file, its top-left pixel (X0, Y0) in the file and its size (px), and its top-left corner (left, top) in the view's screen frame (m):

  ```text
  saturn-v-positions.png  …  14.0 px/m  panel 1 at (8, 8) px, 242 x 1605 px, corner (-10.205, 109.721) m  panel 2 at (258, 8) px, …
  ```

  Pixel (X, Y) of the file, in the panel at (X0, Y0), is at right = left + (X − X0 + 0.5)/k and up = top − (Y − Y0 + 0.5)/k at k px/m. A side view's up is construction x, and STA = x / 0.0254. Without X0 and Y0, a row of `saturn-v-positions.png` reads its station 8/k m (22.5 in) too low. In a test, `OrthoSheet.screen(X, Y)` does the same.

## Rendering in a test

```swift
let scene = OrthoScene(VesselLibrary.saturnV())             // or OrthoScene(vessel, where: { $0.name == "CM" })
let view = OrthoView.position(1, scale: 40, stations: AS506.station(2450)...AS506.station(2900))
let image = OrthoRaster.render(scene, view)                 // OrthoImage
try PNG.write(image.image, to: url)
image.surface(x, y)                                         // the index into scene.surfaces seen at a pixel
let sheet = OrthoSheet((1...4).map { OrthoRaster.render(scene, .position($0, scale: 40)) })   // I-IV on one file
try PNG.write(sheet.image, to: url)
sheet.screen(x, y)                                          // a pixel of the file: its panel and screen coordinates
```

- **Views.** `OrthoView` covers:
  - `.position(n, …)`;
  - `.side(azimuth:)` for any azimuth θ, measured from Position I towards II as `VisualShape.vehicleAzimuth` measures it;
  - `.top` and `.bottom`.

  Each view takes a scale in px/m and an optional band of construction x. The band crops a side view and cuts a section for a top or bottom view.
- **Visibility.** Each pixel shows the nearest surface at its centre, with no antialiasing.
  - A feature narrower than a pixel shows only where it covers a pixel's centre, as on the GPU without MSAA (see `radius(…, resolving:)` below).
  - Back faces are culled except on `twoSided` shapes, as the vessel pass culls them.
  - Shapes linked to thrusters are drawn as mounted, with the gimbal at null.
  - Coplanar faces show the first one drawn.
- **Style.** `OrthoStyle` sets the lighting:
  - `.flat`: ambient plus a key light from the viewer's upper left;
  - `.albedo`: the paint as it is.

  It also turns the outlines and the annotations (ticks and numerals) on or off. `OrthoStyle.albedo` turns everything off, for probing colours.
- **Paint (for VM1).** The last argument of `render` is an `OrthoPaint`, `(OrthoFragment) -> (Double, Double, Double)`, which returns linear RGB. It defaults to each shape's `color`. A fragment carries:
  - the part and the shape;
  - its surface coordinates (u, v, r, s), interpolated across the triangle as the GPU does;
  - its construction-frame position and normal;
  - whether it is a two-sided shape's back face.

  The evaluator plugs in there, reading its stations and azimuths from `f.surface` (u, v in the vehicle frame for the shapes that carry it):

  ```swift
  OrthoRaster.render(scene, view, style: .albedo) { f in /* VM1's colour at f.surface.u, f.surface.v */ f.shape.color }
  ```

## Measuring the outline (for VG1-VG3)

`Silhouette` measures on the triangles. It is exact for the tessellation and does not depend on any image's resolution. Stations are construction x in metres (`AS506.station(sta)`, `AS506.apolloStation(xa)`); azimuths are θ in radians, with Position I at 0, II at π/2, III at π and IV at 3π/2.

```swift
let s = Silhouette(VesselLibrary.saturnV())
s.diameter(at: AS506.station(1000), azimuth: .pi / 4)        // the skin: reach(θ) + reach(θ + π)
s.reach(at: x, azimuth: 0)                                   // a ray cast out from the axis at θ
s.radius(at: AS506.station(1000), azimuth: .pi / 4)          // how far the outline reaches towards θ
s.width(at: AS506.station(1000), viewedFrom: 0)              // radius(θ + π/2) + radius(θ − π/2)
s.radius(over: AS506.station(81)...AS506.station(137), azimuth: .pi / 4)   // the most over a band of stations
s.radius(at: x, azimuth: .pi / 2, resolving: 1 / 40)         // what a 40 px/m view from I must show on its right
s.section(at: x).cover(azimuth: .pi / 2)                     // the stretches a row at x crosses, towards θ
s.stations                                                   // lowest and highest x
```

The two measures differ wherever something stands proud of a skin, so pick the one that matches what is being checked:

- **`radius`** is the outline's support function: the largest p·radial(θ) over the cross-section. It is the half-width that a drawing, or a view from θ − π/2, shows on its right. Measure outlines, spans and fin tips with it (a fin span is `radius` at 45° plus 225°). It is not local to θ. A feature standing h proud of a skin of radius R, at Δ from θ, reaches R cos Δ + h towards θ, so it raises `radius` wherever Δ < acos(1 − h/R). For 11 in on the S-II's 198 in skin, that is 19°: VG2's systems tunnel at θ = 32° makes `radius` at 45° read 203.9 in, so the S-II would measure 407.8 in across there instead of 396.
- **`reach`** sees only the half-plane at θ, a ray from the axis. A skin's radius beside a tunnel or fairing is the skin's, and sweeping θ finds bumps (fairings, modules, ports) at their own azimuths. **`diameter`** adds the two rays of a line through the axis. Measure stage and skin diameters with these, on rays that miss the features themselves. `SilhouetteTests` measures them along the fin diagonals, which miss VG2's S-II tunnel and VG1's S-II ullage-motor fairings; beside both, it checks that the diameters stand and that `radius` reads the features.

Both count every triangle, back faces and insides included. `SilhouetteTests` pins the vehicle as VG1-VG3 draw it against docs/SaturnV-CSM-exterior-datasheet.md.

**What an image can show.** `Silhouette` is exact; an image samples each pixel at its centre. A side view's row at station x crosses the shapes along the section's `cover`, the stretches of the line that the section's segments project onto, so a pixel of the row is covered when its centre lies in a stretch. The row's last covered pixel therefore lies at most `radius` out, and less than a pixel inside `radius(at:azimuth:resolving:)`, the far end of the farthest stretch at least a pixel long. The two are the same wherever what reaches farthest is a pixel or more across at x. They differ at a sliver: at 40 px/m, the row 0.005 in above the lowest point of an APS pitch engine's 6.43 in exit (P1's) crosses its lip, which stands 0.5 in proud of the module's face, along 0.34 mm. `radius` reads the lip there; the image, and `resolving`, show the face. `OrthoRasterTests` checks this rule on every row of the S-IVB's aft skirt from Positions I and II, where that row is the only sliver, and on a toy nozzle. To check a drawing at k px/m, compare with `radius(…, resolving: 1 / k)`.
