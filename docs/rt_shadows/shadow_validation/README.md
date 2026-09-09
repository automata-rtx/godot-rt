# Measuring the screen space shadow against the trace

Everything here exists to answer one question with numbers instead of opinion: **how close does the
screen space contact shadow get to a ray trace of the same geometry, and which half of it is wrong?**

The reference is this fork's own raytraced shadow, deliberately, and not a shadow map. A map brings
its own resolution and depth-bias error to a comparison about millimeter-scale occluders, and would
be measuring two techniques' errors at once. The trace intersects the blade's actual triangles.

Every rig renders **one scene several ways, changing only the shadow term**. So the luminance a
capture loses relative to the unshadowed baseline *is* the shadow, everywhere, with no segmentation
mask and no assumption about which pixels are ground.

| capture | what it is |
| --- | --- |
| `a_off.png` | occluders cast nothing, screen space off — the unshadowed baseline, the divisor |
| `h<H>_t<T>.png` | screen space on, at that `hardness` and `surface_thickness` — under test |
| `b_rt.png` | occluders put **into** the acceleration structure and traced — **ground truth** |

## The one rule

**A PNG is sRGB encoded. Decode to linear before differencing anything.**

Every published number in the screen space section of `FINDINGS.md` was first taken by differencing
sRGB values directly, which measures gamma space rather than light, and all of them had to be
re-derived. Gamma compresses the dark end, so every ratio came out *lower* than the truth and the
technique looked consistently further from the reference than it is.

`score.py` decodes first, always. Its `--srgb` flag exists only so that a number found in an old
note can be *identified* as gamma-space rather than mistaken for a regression.

The error was caught by a control that could not miss and did: `opacity.gd` renders the same sun on
shadow maps, a path this fork does not touch, which applies `shadow_opacity` exactly once and must
therefore read `0.500` at an opacity of `0.5`. It read `0.336`. **If that control ever moves off
`0.500` again, fix the measurement before believing anything else it says.**

## The three numbers, and why it is not one

- **mass** — total light removed, relative to the trace's. Threshold free, no selection bias, and
  the only one of the three that is safe to tune `surface_thickness` against.
- **area** — how many pixels it shadows at all, relative to the trace's.
- **darkness** — mass ÷ area. *When it does find a shadow, is that shadow as dark as the trace's?*

They have to be read together. The screen space pass systematically **overshoots darkness while
undershooting area**, which is the signature of a `min()` composition that can only darken: where
the march finds the occluder it commits fully, and where it does not there is nothing at all. A
single figure of merit hides which half is wrong, and that is exactly the mistake that made
`surface_thickness` look like it wanted retuning when it did not.

`--bands` exists for the same reason at a smaller scale. A frame average hides that every variant
undershoots near the camera — where a tall blade throws a shadow longer than the quality tier's
march, which is bounded in **pixels** — and overshoots far away, where the fixed one pixel of
rasterization overshoot is proportionally huge on a blade under two pixels deep.

## The rigs

Each pins its own quality tier, capture resolution and geometry, because **each published table was
measured at different ones and they are not cosmetic**. The tier bounds the march in pixels and so
sets area directly; the resolution sets how many pixels wide a blade is, which is the entire
variable `hardness` exists for. Letting a rig inherit either from the shared `project.godot` is how
a run silently stops reproducing — it happened while this directory was being written.

| rig | geometry | tier | capture | what it is for |
| --- | --- | --- | --- | --- |
| `probe` | 20 separated prisms, 2.2 cm × 4 mm, 90 cm tall | Medium | 1280×720 | the `hardness` sweep. Few enough occluders that one shadow can be looked at |
| `field` | 4,504 blades, 1.0 × 1.5 cm × 25 cm, clustered | High | 1600×900 | what a game actually scatters. The `surface_thickness` question |
| `field_thin` | 15,000 blades, 2.2 cm × 4 mm | Medium | 1280×720 | nearly razor thin — the far end of the size range |
| `opacity` | boxes on open ground | — | 800×450 | is `shadow_opacity` linear on a raytraced sun, with the shadow-map control |

`probe` also carries the controls that ruled out explanations before the cause was found:
`SSS_SUN_AZ`, `SSS_SUN_EL`, `SSS_BLADE_W`, `SSS_BLADE_D`, `SSS_RANDOM_YAW`, `SSS_CONTRAST`,
`SSS_BIAS`, `SSS_NBIAS`. Set `SSS_BLADE_W=0.12` for fat blades whose shadow is tens of pixels
across, which is what a *width* measurement needs; it does not give the same numbers as the default
and is not a substitute for it.


## Getting a binary

`run.sh` looks for `bin/godot.linuxbsd.editor.x86_64` at the repository root, or wherever
`GODOT_BIN` points. The binary is gitignored, so a fresh clone has none. Build one with:

```
scons platform=linuxbsd target=editor dev_build=no debug_symbols=no -j$(nproc)
```

The project's own builds come from GitHub Actions rather than from a local toolchain.
`.github/workflows/linux_builds.yml` still exists and carries `workflow_dispatch`, so a Linux binary
and the class-reference check can both be had from the Actions tab on demand, even though the
default push only runs the Windows jobs.

## Running it

```
./run.sh field                                       the default two hardness rows
./run.sh probe                                       the full hardness sweep, one render
./run.sh opacity                                     the shadow_opacity linearity check
SHADOW_THICKNESS=0.0025,0.005,0.010 ./run.sh field --bands
./run.sh field --srgb --overlay /tmp/agree.png
```

Anything after the rig name goes to `score.py`. `GODOT_BIN` points at the engine binary,
`SHADOW_RES` and `SHADOW_QUALITY` override a rig's pinned values — for deliberately re-deriving,
never for reproducing. `SHADOW_HARDNESS` and `SHADOW_THICKNESS` are comma-separated lists rendered
as a cross product; the whole sweep runs in **one** render, because every `screen_space_shadows`
setting is live from one frame to the next.

A field run is about a minute under lavapipe.

## What this harness cannot tell you

**Cost.** Every timing under lavapipe is meaningless; profile on hardware.

The raytraced reference itself is real under lavapipe — it advertises ray query support, the fork
takes it, and `GODOT_RT_DEBUG=1` shows the TLAS built and a mask slot granted and written. Startup
prints `OpTypeRayQueryKHR is not supported yet.` once; **that line comes from the Mesa stack, not
from the engine, and does not stop the trace.** The proof is behavioral rather than textual: the
opacity rig can distinguish the raytraced branch from the shadow-map branch, which it could not do
if the mask were absent. This is worth knowing because the line reads exactly like the reference
silently degrading, and believing it would make every "vs trace" ratio here look untrustworthy.

**`restrict_casters` has no rig here, and the four that exist cannot give it one.** All of them are
grass on an empty ground plane, so the only geometry in the acceleration structure is a flat plane,
and a flat plane cannot occlude itself from a 38 degree sun. Toggling the setting on these scenes
changes the frame by a single pixel -- which is correct, and tells you nothing. A rig that could
settle it needs real props at `cast_shadow = On` -- rocks, posts, a wall -- standing among the
grass, so there is genuinely redundant casting to remove; `field.gd` is the closest starting point.
Do not conclude from a one-pixel difference that the toggle does nothing. Why the default is off,
and what flipping it would take, is in section 10.6 of `FORK_GUIDE.md`.

It says nothing about temporal behavior. The denoiser is off and every capture is a settled
still frame, deliberately, because a filtered accumulating shadow is not deterministic frame to
frame and cannot be differenced against a fixed baseline. Ghosting, flicker and denoiser convergence
need a different rig that does not exist yet.

## The numbers to reproduce

If a change is not meant to move the screen space shadow, these should come back unchanged. All
linear; the sRGB column of `--srgb` is in `FINDINGS.md` beside them.

`./run.sh probe` — trace removes 0.2767 per px over 2217 px:

| `hardness` | darkness | mass | area |
| --- | --- | --- | --- |
| 0.00 (Bend) | 0.445 | 0.664 | 1.49 |
| 0.25 | 0.563 | 0.867 | 1.54 |
| 0.50 | 0.685 | 1.069 | 1.56 |
| 0.75 | 0.812 | 1.273 | 1.57 |
| 1.00 (default) | 0.939 | 1.477 | 1.57 |

`./run.sh field` — trace removes 0.1595 per px over 253,632 px:

| | darkness | mass | area |
| --- | --- | --- | --- |
| `hardness` 0 | 0.802 | 0.594 | 0.740 |
| `hardness` 1 (default) | 1.052 | 0.832 | 0.792 |

`./run.sh field_thin` — trace removes 0.1044 per px over 132,257 px:

| | darkness | mass | area |
| --- | --- | --- | --- |
| `hardness` 0 | 0.864 | 0.468 | 0.541 |
| `hardness` 1 (default) | 1.149 | 0.830 | 0.722 |

`./run.sh opacity` — every exponent `1.00`, and the shadow-map control at ratio `0.500`.

The harness is byte-for-byte deterministic under lavapipe: two consecutive runs of the same binary
and scene differ by zero pixels. So a difference of even a few hundred pixels is a real change, not
noise, and is worth explaining rather than dismissing.
