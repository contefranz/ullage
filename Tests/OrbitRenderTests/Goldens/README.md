Golden images for OrbitRenderTests: 640×400 PNGs in one folder per GPU family
(`<gpu-family>/<shot>.png`), read from the source tree (the folder is excluded
from the test target, so it is not bundled). Other GPU families skip the
pixel comparison. Regenerate them on the owner's Mac with
`ORBITSIM_UPDATE_GOLDENS=1` and review the contact sheet before committing.

A shot renders the same bytes from run to run and whatever the renderer drew
before it (`RenderDeterminismTests`): `SnapshotRenderer` starts the renderer
over before each shot (`SceneRenderer.startOver`), and the renderer keys
parts and thrusters by `ObjectSerial`, never by address. Two things still
vary: shots with particles (P3 composites them in the GPU's atomic order;
measured at most a few thousand pixels, max ΔE 1.4, between two identical
runs), and cloud shots rendered without the weather fields
(`Sources/OrbitScene/Resources/*.oscloud`, not in git), which fall back to
the climatology: bless and compare scene goldens with the fields present.
