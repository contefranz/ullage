Golden images for OrbitRenderTests: 640×400 PNGs in one folder per GPU family
(`<gpu-family>/<shot>.png`), read from the source tree (the folder is excluded
from the test target, so it is not bundled). Other GPU families skip the
pixel comparison. Regenerate them on the owner's Mac with
`ORBITSIM_UPDATE_GOLDENS=1` and review the contact sheet before committing.
