# The Linux ortho gallery (M1.6 track L0)

Test support for seeing and measuring vehicle geometry without Metal, so
that cloud sessions (VG1-VG3, VM1, LC) can check what they build. Its code
is in `Tests/OrbitSceneTests/Support`:

- `OrthoRaster.swift`: the rasteriser;
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
- The files total about 40 MB, because stored deflate leaves them uncompressed.
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
- **`index.txt`** gives each panel's top-left corner in the view's screen frame (m), so pixels map back to stations: row y of a side view at k px/m is at construction x = top − (y + 0.5)/k, and STA = x / 0.0254.

## Rendering in a test

```swift
let scene = OrthoScene(VesselLibrary.saturnV())             // or OrthoScene(vessel, where: { $0.name == "CM" })
let view = OrthoView.position(1, scale: 40, stations: AS506.station(2450)...AS506.station(2900))
let image = OrthoRaster.render(scene, view)                 // OrthoImage
try PNG.write(image.image, to: url)
image.surface(x, y)                                         // the index into scene.surfaces seen at a pixel
```

- **Views.** `OrthoView` covers:
  - `.position(n, …)`;
  - `.side(azimuth:)` for any azimuth θ, measured from Position I towards II as `VisualShape.vehicleAzimuth` measures it;
  - `.top` and `.bottom`.

  Each view takes a scale in px/m and an optional band of construction x. The band crops a side view and cuts a section for a top or bottom view.
- **Visibility.** Each pixel shows the nearest surface at its centre, with no antialiasing.
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
s.radius(at: AS506.station(1000), azimuth: .pi / 4)          // how far the outline reaches towards θ
s.width(at: AS506.station(1000), viewedFrom: 0)              // radius(θ + π/2) + radius(θ − π/2)
s.radius(over: AS506.station(81)...AS506.station(137), azimuth: .pi / 4)   // the most over a band of stations
s.reach(at: x, azimuth: 0)                                   // a ray cast out from the axis at θ
s.stations                                                   // lowest and highest x
```

- **`radius`** is the largest p·radial(θ) over the cross-section. It is the half-width that a drawing, or a view from θ − π/2, shows on its right. Fin tips, a fin span (`radius` at 45° plus 225°) and stage diameters are measured with it.
- **`reach`** sees only the half-plane at θ, so sweeping θ finds bumps (fairings, modules, ports) at their own azimuths.

Both count every triangle, back faces and insides included. `OrthoRasterTests` checks that the drawn outline matches `Silhouette` to within a pixel. `SilhouetteTests` pins today's vehicle against docs/SaturnV-CSM-exterior-datasheet.md.
