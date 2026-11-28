# The effect slots' reconstruction (M1.6 look round 2, LR0)

How R6's composite brings the half-resolution layers (C2's clouds, P2's
plumes, P3's smoke, R6's test emitters) back to the frame, and what each
writer must report for it. Plan: `docs/m16/look-round-2.md` §3, LR0. Code:
`OrbitScene/Look/EffectSlots.swift` (the maths, which the shaders mirror line
for line), `OrbitRender/Passes/{HalfResTransparent,TransparentComposite}.swift`
and their shaders, the header `EffectSlotsCommon`.

## What was wrong

The composite filtered the layers bilinearly only where all four texels'
test depths were within 10 % of the pixel's. Otherwise it took the one texel
nearest in depth (Bavoil 2008). That rule ignores whether the depths matter:
- an effect wholly in front of both depths reads the same at either;
- yet over grazing ocean, at the horizon and round the tower, the depth
  changes more than 10 % a pixel row.

So every pixel there took one texel: 2-px stairs and row stripes on every
half-resolution layer.

## The rule

A texel *matches* a pixel when:
- its test depth is within the tolerance of the pixel's (10 %, relative), or
- every layer drawn at it **ended nearer than both scene depths**, the
  texel's and the pixel's, so neither depth cut it. The writers report where
  their effects ended (below).

Then, at the pixel:
- **all four match:** bilinear, exactly, one filtered sample a layer, as
  before;
- **some match:** the bilinear weights renormalised over the matching
  texels (Kopf et al. 2007, joint bilateral upsampling with a binary range
  kernel); each layer's front is the least of the texels that weigh;
- **none:** the texel nearest in depth alone (ties to the larger bilinear
  weight, then the lower index).

F9's "effect reconstruction" view shows which case each covered pixel took:
- grey: bilinear;
- green: bilinear across differing depths, made so by the writers' codes;
- yellow: renormalised;
- red: the nearest texel.

## What a writer reports

| Layer | Where | Format | Blend | Clear |
|---|---|---|---|---|
| Volumes (P2, the test cone) | the fronts' a (attachment 4) | rgba16Float, log2 of linear metres | max | −65504: nothing drawn |
| Clouds (C2's slot copy, the test slab) | clip codes' r (attachment 5) | rg8Unorm, a byte | min | 255: nothing drawn |
| OIT (P3's smoke, the test sprites) | clip codes' g (attachment 5) | rg8Unorm, a byte | min | 255: nothing drawn |

**A volume's back code** is `orbit_backCode(lastVisible, cut)`:
- it is log2 of the linear depth of the far end of its last step that added
  anything visible (1/4096 of coverage or of the front's radiance), plus a
  margin of 1/32 against half's rounding;
- it is 65504 (cut) where the scene lay in front of the proxy's far side, or
  hid the proxy wholly; an opaque early stop is not cut.

A proxy the scene cuts or hides is **drawn rather than discarded**, so that a
pixel beside it, whose scene lies behind, does not take its emptiness. The
composite lets the texel through for a pixel whose linear depth lies behind
the back.

**A clip code** is `orbit_clipCode(endsAt, sceneDistance)`. `endsAt` is the
linear depth from which no scene cuts the effect:
- the slab's far face;
- a sprite's view depth plus half its radius, where its soft fade begins;
- C2's back estimate (entry + 2 × (mean − entry)). Over the texel's own
  ground, the footprint's nearest ground (four corner rays) also bounds it,
  since clouds are never inside the ground.

The code:
- is 0 where `endsAt` lies behind the texel's scene (cut);
- is otherwise 1 + the whole sixteenths of an octave that `endsAt` lies in
  front of it, rounded down so it never claims more, at most 254;
- lets a pixel through when its scene lies at `endsAt` or beyond, to within a
  sixteenth of an octave (4.4 %).

A sprite or deck the texel's scene hides or fades out entirely writes 0
(the smoke still discards fragments that are empty anyway).

**The depth sprites test against** is the farthest depth of the texel's
upsample footprint (the 4 × 4 pixels that read it), not the texel's test
depth. A sprite behind the texel's own scene but in front of a neighbouring
pixel's still runs, fades out there and writes its cut code.

**The contract:** an effect lists the layers whose codes it writes in
`HalfResEffect.reconstructedLayers`. A layer is reconstructed across depths
on a frame only when every effect drawing it does (the uniforms'
`reconstruction.x`); otherwise it matches by depth alone, as R6 did, but
renormalised. LR4's launch cloud and LR5's trail switch their layers on
when they write their codes.

## Jitter and settle mode

**Jitter.** `orbit_effectJitter(texel, salt, e, blueNoise)` is R1's 64² blue
noise (texture 26), its values rotated by the golden ratio each frame
(`EffectSlotUniforms.reconstruction.y`, computed in Double from the frame
index).
- Over frames a texel's jitter is the golden-ratio sequence, the most even a
  sequence can be; each frame's pattern stays blue in space.
- `salt` shifts the tile for a second, independent use.
- The test cone uses it. C2's and P2's marches keep their interleaved
  gradient noise until their own PRs (LR2, LR3) take it up, with their
  goldens.

**Settle mode** (decision 7): a shot's `"settle": N` draws N frames before
its own:
- the frame index steps by one each, with temporal reset off;
- the effects' clocks stand still, since a shot is paused;
- temporal history (C2's) and the jitter converge, and the frame, its views
  and its timings are the settled one's.

0, the default, keeps the first frame as before.
