# FPS refinement validation

This round refines the three opt-in experiments in sequence: response, probe
scheduling, then cache-detail transitions. The preserved starting implementation
is `c0c4b264e3346f668845a8b2c9a826f57e6abfd1` with all three experiments enabled.
The original AMD path is also captured with all three disabled. The frozen tag
and branch are unchanged. No game-project files are modified.

## Test conditions

`../shadow_validation/amd_gi_fps.gd` builds a procedural FPS scene with a covered
shack, shaded recesses, partition, props, rigid NPC proxy, polished weapon and
side panel. It uses sky lighting, a directional sun and nine lamps; the response
experiment's special all-dark analytic-light shortcut cannot handle this scene.

- Native 640×360, quarter-sample primary budget, GI denoising, multibounce and
  default half-resolution reflections. FSR2, TAA and VBAO are off.
- Flashlight: the game's energy 6, angle 26°, range 45. Its **visibility** changes;
  the beam really disappears. No indirect-only toggle masquerades as light-off.
- Three-frame muzzle flashes use the game's energy 6 and range 7. Emissive strips
  alternate every four frames and then turn off.
- Fixed 60 Hz simulation; frame counts describe response. Software Vulkan runs
  do not establish RTX 5090 / 780M GPU costs or actual real-time frame rates.
- No high-sample reference. Settled images use the same quarter sampling and
  remain convergence references, not ground truth.

`GI_FPS_PHASE` selects `all` (switching, sweep, camera translation, actor, muzzle,
hazard), `response`, `close` (light-painted interior at close flashlight range),
`cache` (newly exposed surfaces), `day` (moving sun, camera turn, curved polished
barrel and weapon/wall intersection), or `stability` (64 stationary captures after
256 lit frames). The NPC proxy is rigid; this does not certify skinned animation.
The accelerated sunset is a stress transition, not a proposed game day length.

Use the existing `run.sh` with `GI_TEST_RIG=amd_gi_fps`, `GI_FPS_PHASE`, separate
output directories/displays, and `GODOT_BIN` to select preserved executables.
The runner checks parsing, render errors and completion, and records the binary
SHA-256. `capture.json` contains exact frame and scene state; `progress.json`
is only partial provenance if a run is interrupted.

## Reading comparisons

Run `fps_compare.py BEFORE AFTER OUTPUT` for matched sequences. It verifies
settings, common frame/camera/light records, and identical GI-disabled controls.
The paired PNGs retain their original pixels; response plots are separate.

Response measurements convert tonemapped PNGs to display-linear luminance. A
fixed before-derived mask excludes the direct beam and polished surfaces.
Reflected flashlight highlights must not be counted as diffuse bounce: they
resolve much faster and would conceal diffuse lag. Response is normalized to
each run's own settled light-on value. Stationary noise is per-pixel standard
deviation across the shared steady captures. Report both response and noise;
brightness alone does not establish correctness.

Artifacts live under `/workspace/preview/amdgi-fps-refinement/`, including raw
captures, comparison PNGs, metrics and source/binary provenance. Folders ending
in `-interrupted` are incomplete cloud-interruption records, not acceptance
results. The initial dark-material close pilot was replaced by a matched
light-painted close test to make the visual response easier to inspect.

## Results

### Response selection

Keep the 0.35 relative-change threshold and three-observation confirmation, lower
the absolute floor from 0.02 to 0.002, and interpolate **fresh-sample influence**
using squared confidence. The final-history cap becomes
`1 / mix(1/65, 1/4, confidence²) - 1`; its endpoints remain 64 and 3. No rays,
buffers or passes are added by this refinement. The original zero-flag path is
unchanged.

Isolated response-stage results in the mixed-lighting wide scene, with scheduling
and cache transitions held at their starting implementation:

| Trial | Bounce reached after 32 on-frames ↑ | Bounce remaining after 32 off-frames ↓ |
| --- | ---: | ---: |
| Starting implementation | 32% | 64% |
| Lower detection floor only | 44% | 56% |
| Linear fresh-weight interpolation | 64% | 27% |
| **Squared confidence — selected** | **55%** | **47%** |
| Additional matched-probe support gate | 56% | 50% |
| Support gate + original raw-cache cutoff | 50% | 63% |

The fastest trial increased measured steady diffuse variation substantially.
Squared confidence retained useful speed with less variation. The extra support
gate and separate cache cutoff did not justify their poorer overall tradeoff;
neither is retained. In the painted close test, the selected version reached 51%
versus 28% after 32 on-frames, and retained 42% versus 54% after 32 off-frames.

The change is not noise-free. The close test's short steady diffuse standard
deviation rose from 0.000139 to 0.000211 in display-linear luminance. The 64-frame
stationary test also showed more variation on a polished weapon face. Inspecting
the actual size matters: that face varied by at most 3 of 255 RGB code levels,
versus 1 before; its top face's variation was essentially unchanged. These tiny
absolute variations should not be described as large fireflies merely because
their relative standard-deviation increase is large. Dynamic cases remain part
of the final comparison.

### Scheduling selection

Retain the existing scheduler. A gentler priority coefficient (4 instead of 16)
and a flexible policy (coefficient 8, overdue threshold 6 instead of 4 at quarter
sampling) were built and captured separately. Both retained the primary-ray
budget. The flexible policy passed the bounded starvation test and actually
redistributed updates: a continuously demanding probe received 410 of 1,024
selections versus 205 for an unchanged probe in the four-probe synthetic test.

That allocation did not translate into a worthwhile rendered improvement. At
frame 32, flexible scheduling moved switch-on response only from 53.5% to 54.6%
and switch-off remainder from 46.7% to 46.3% in this stage's fixed mask. After
camera movement, its eight-frame back-wall settling error was 0.000793 versus
0.000658, and partition error 0.000308 versus 0.000276. Other regions were mixed.
The gentler-only policy was similarly mixed. Neither scheduling change is kept;
the original age/coverage protection is preserved.

Each stage uses its own fixed before-derived response mask. Compare values
within a stage, not small numerical differences between stages' masks.

### Cache-detail selection

Retain the existing 75–100% sample-threshold transition. Compare it against no
blending, earlier admission (50–100%), and later admission (87.5–100%), holding
the selected response and original scheduler fixed. Each run captures all 32
stationary frames after the camera exposes new surfaces, plus later settling.

Earlier admission slightly reduced the eight-frame diffuse settling error
(0.000435 versus 0.000447), but increased the largest later pixel step from 5 to
8 RGB code levels. Later admission did not improve settling and reached a
7-level step. All variants' 99th-percentile later step was one level. These are
small differences; neither alternative establishes a worthwhile improvement.
Keep the current transition rather than widening its noise exposure.

### Final selection

The final renderer patch is exactly the selected squared-confidence response
trial. The scheduler and cache-transition alternatives are reverted. Preserved
executables and source patches identify each trial; final close and stationary
captures reuse that exact selected executable, with explicit reuse records.
The full combined motion/day sequences are independently rerun after selection.

The original all-switches-off path and frozen refs remain intact. All three
switches still default off. This round adds no shader passes, rays, buffers,
public settings, or descriptor changes beyond the preceding experimental
implementation. Response arithmetic changes; actual GPU cost still requires
target-hardware measurement. Fixed ray budgets alone do not prove equal cost.

### Complete before/after

The final independent full run completed all 1,399 main-sequence frames and 768
day/weapon frames. Matched close and stationary sequences contain 440 and 480
frames. Both runs' GI-disabled controls are pixel-identical; frame/camera/light
records match. The main rerun slightly differs numerically from the isolated
response trial, so use the following final figures for the complete comparison:

| Test | Before | Selected |
| --- | ---: | ---: |
| Wide shack: bounce reached after 32 on-frames | 32% | 57% |
| Wide shack: bounce remaining after 32 off-frames | 64% | 47% |
| Painted interior: bounce reached after 32 on-frames | 28% | 51% |
| Painted interior: bounce remaining after 32 off-frames | 54% | 42% |

These fractions use each run's own settled brightness, not the total screen
brightness. Early response is not uniformly faster. Neither settling reference
nor these fractions establish physical accuracy.

The tradeoff is real: wide shaded-region steady temporal deviation increases
from 0.00000915 to 0.00001024 (about 12%); the close test increases about 51%.
The more aggressive linear-weight trial roughly doubled the wide shaded-region
variation, supporting selection of squared confidence instead.

- **Camera movement/disocclusion and flashlight sweep:** effects are mixed and
  generally subtle. Some regions settle faster and others slower; no broad
  motion-quality improvement is established.
- **Moving rigid NPC:** back-wall error relative to the later settled image drops
  from 0.000431 to 0.000287, while other regions are nearly unchanged or worse.
  This does not validate skeletal motion.
- **Muzzle flash and changing sun:** matched images are included. Neither shows
  a dramatic general quality improvement in this fixture.
- **Alternating emissive hazard:** bounce is noisier in the selected version.
  Comparing matching phases of three cycles, diffuse shaded-region variation
  rises from 0.0000183 to 0.0000249, about 36%; back-wall variation rises about
  40%. This metric includes remaining settling, not only random noise. The
  hazard is not solved by faster response; its polished reflection stays noisy.
- **Polished weapon/camera turns and wall intersection:** visible reflection
  noise persists, including after stopping. These diffuse-response refinements
  do not replace the reflection reconstruction/denoiser or certify the game's
  previously reported wall-intersection artifact as fixed.

The selected configuration is the best tested response/stability balance for
this pass, not a claim of a global optimum or uniform improvement. Keep it
opt-in. All before/after PNGs retain native pixels and exposure. MP4 companions
slow captured sequences without frame interpolation and label their speed;
use original PNGs for pixel inspection. The preview ZIP includes the complete
paired set, response plots, metrics and reading notes, not only favorable shots.

### Verification and remaining limits

- Linux release-style editor build passed. Its executable SHA-256 is
  `5fd723063d306aa756d1f0839ac12b04bb1750f805fa2ece1da4fff3c9a31bf8`, identical
  to the selected trial executable used for captures. The embedded commit is the
  preceding checkpoint; the saved final source patch identifies this refinement.
- Production scalar policy tests, tuning/source contracts, and all 59 shader
  variants passed. Shader compilation uses a constant material stub; rendered
  fixtures exercise native StandardMaterial3D, not every Godot shader feature.
- Final software-Vulkan lifecycle run passed: independent/combined switches,
  probe retention, adaptive patching, multibounce, all-hit caching, reflections,
  spacing changes, viewport resize, GI disable and original-path restoration.
  Probe budget and cache ownership checks passed; GI-off allocation stayed fixed.
- Target-GPU frame times, Windows, actual Crossroads gameplay, skinned NPCs,
  emissive atlases and upscaler interactions are not newly validated here.
  These are targeted synthetic visual tests, not a broad compatibility claim.
