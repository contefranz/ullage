# Third-party notices

OrbitSim is MIT-licensed (see LICENSE). This file lists code ported from
other projects, with their licences, and credits the methods and data the
code implements. M1.6's integration track finalises it.

## Code

### three.js: AgX tone mapping

`Sources/OrbitScene/Look/ToneCurves.swift` (`ToneCurves.agx`) ports the
AgX tone curve's matrices, log encoding and sigmoid from three.js,
`src/renderers/shaders/ShaderChunk/tonemapping_pars_fragment.glsl.js`
(commit 7b690028, 2024-08-09). three.js bases it on Filament's AgX
(google/filament#7236, Apache-2.0), itself after Troy Sobotka's AgX for
Blender; the sigmoid's polynomial fit is from iolite-engine's minimal AgX.

```
The MIT License

Copyright © 2010-2026 three.js authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## Methods implemented from their publications

- **Khronos PBR Neutral** tone mapper and its inverse
  (`ToneCurves.neutral`, `neutralInverse`, and the post shader), from its
  specification in KhronosGroup/ToneMapping, `PBR_Neutral/README.md`
  (repository Apache-2.0). The tests check it against that repository's
  `pbrNeutral.cube`.
- **CIE 1931 colour-matching functions** in the multi-lobe fits of Wyman,
  Sloan and Shirley, "Simple Analytic Approximations to the CIE XYZ Color
  Matching Functions", JCGT 2(2), 2013.
- **Luminous solar constant**: Darula, Kittler and Gueymard, "Reference
  luminous solar constant and solar luminance for illuminance
  calculations", Solar Energy 79(5):559-565, 2005 (133.334 klx).
- **Photometric exposure** (EV100, pre-exposure, saturation-based speed):
  Lagarde and de Rousiers, "Moving Frostbite to Physically Based
  Rendering", SIGGRAPH 2014 course notes.
- **Bloom pyramid** (13-tap downsample, tent upsample): Jimenez, "Next
  Generation Post Processing in Call of Duty: Advanced Warfare", SIGGRAPH
  2014. **Weighted MSAA resolve**: Karis, "Real Shading in Unreal Engine 4"
  and "High Quality Temporal Supersampling", 2013-2014.
- **Blue noise**: Ulichney, "The void-and-cluster method for dither array
  generation", Proc. SPIE 1913, 1993.
- **Star colours**: Ballesteros, "New insights into black bodies", EPL 97,
  34008, 2012 (B-V to temperature).
- **Veiling glare**: the Stiles-Holladay disability-glare formula, scaled
  down for a camera lens.

## Data

- **IAU 2015 Resolution B3**: the Sun's nominal radius and effective
  temperature.
- **Allen's Astrophysical Quantities**: the illuminance of a magnitude-0
  star, and the Sun's limb darkening.
- **Hipparcos** stars, through `tools/make_stars.py` (see README).
