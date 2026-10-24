# AMD GI: current status and local handoff

Updated 2026-10-24. Pushed baseline: `9f4386ed09` on **`feature/amd-gi`**.
Emitter performance implementation: **`feature/amd-gi-emitter-performance`**,
branched directly from that baseline.
Read this file first. Read [controls](features/amd-gi.md), [material internals](internals/rt-materials.md),
or [approval boundaries](AMD_GI_ADAPTER_DECISIONS.md) only as needed.
Older documentation is preserved in one [historical archive](history/AMD_GI_ARCHIVE.md).
Search a specific heading/finding there; do not load the entire archive into AI context.

## State of the implementation

Windows freeze investigation (RTX 5090, 2026-10-24): the branch now splits AMD GI
entry points before SPIR-V generation instead of specializing one large native
material shader 54 times. It also retains both storage and indirect-command
access when a compute buffer has both roles. Dropping the indirect access let
dispatches consume stale counts; the unchanged engine failed cache ownership
validation on this GPU. The 256-dispatch regression produced 7,567 incorrect
words before the graph fix and zero afterward. The source-material oracle and
consequential cache/viewport regression pass on the corrected Windows build.

Actual fps-proto menu transitions through Systems Sandbox and Crossroads are
responsive with GI enabled. Cold shader creation can still pause loading; it is
not asynchronous. On the baseline branch, a deeper synchronized GPU profile at
1280x720 attributes about **121 ms to light-grid construction** and **17 ms to
emitter geometry regeneration** on the RTX 5090, out of roughly 140 ms total.
The earlier 122 ms hit-shading / 19 ms acceleration-structure attribution was
incorrect: ordinary timestamp boundaries allowed work to cross the labels.
Actual primary/secondary hit shading is about 0.17 ms combined; GI TLAS building
is about 0.2 ms. The light grid scans 5.29 million emissive triangles for each of
256 cells. Only 56 of 12,563 emitter batches changed in one snapshot, but all
were rebuilt. See the [profiling report and reproducible evidence](validation/amd_gi_profile_2026_10_24/README.md)
for controls, exact-zero candidate counts and the recommended fix work.
That investigation installed no production performance optimization.
The separate emitter-performance branch now rebuilds only changed native emitter
geometry and prepares current-frame emission once before traversing ordered
exact-zero masks. It preserves original light IDs, strata, weights and RNG order;
GPU oracles compare against the full original scan and full geometry regeneration.
A fresh Crossroads comparison at 1280x720 measured **135.604 ms whole GPU frame
before, 3.509/3.496 ms after** on this RTX 5090. Synchronized new stage timings:
0.484 ms emission preparation, 0.006 ms upper masks, 0.559 ms light grid,
0.092 ms emitter geometry. Extra scratch storage is approximately 82 MiB per
active GI viewport at this emitter count. This is not a gameplay FPS or Radeon
780M claim. See the [adversarial evaluation, implementation and evidence](validation/amd_gi_emitter_performance_2026_10_24/README.md).
Its automated runs also exposed a separate exit-time `nvcuda64.dll` access
violation, reproduced with the unchanged delivered editor; root cause remains
unresolved. The game's saved video settings override the project's
upscaler at runtime; Streamline initialization alone does not prove active DLSS.

A separate repeated-level stall remained with the desktop's implicit Vulkan
layers: Sandbox → Crossroads → Live World stopped at a GPU fence, with or without
DLSS. Excluding `VK_LAYER_RTSS` for the test process completed that sequence with
GI and effective DLSS mode 6 on every level. Excluding all implicit layers also
completed it; a small DLSS/MultiMesh test alone did not reproduce it. Treat this
as a tested local RivaTuner compatibility workaround, not a proven defect inside
RivaTuner or a general reason to disable overlays. The supplied desktop launcher
sets `VK_LOADER_LAYERS_DISABLE=VK_LAYER_RTSS` only in its child process environment;
no global overlay settings were changed. See the
[Vulkan loader's layer filtering documentation](https://github.com/KhronosGroup/Vulkan-Loader/blob/main/docs/LoaderLayerInterface.md#layer-filtering).
The independent dispatch regression still fails before the graph fix and passes
afterward with RivaTuner excluded, so that engine correction is separate.

The main AMD GI-1.2 pipeline and audited default-path corrections are implemented
for supported inputs. **Full feature coverage, Godot compatibility and production
validation are unfinished.** No claim that all reported gameplay defects are fixed.
Reference: AMD Capsaicin `914b91596cd119eda85fbc1d3c7ee6ac391b1452`, package v1.3 / GI-1.2.
The full source audit is complete; a completed audit is not proof of complete implementation.

Implemented: sparse screen probes, guiding/reuse/filtering, world radiance cache,
GridStream light selection, multibounce, default near-field screen-space GI,
reflections and AMD diffuse/reflection denoising. Native hit materials replace the
old coarse capture atlas. Supported emitter texture scaling/rotation/alternate UVs
now use their actual mapping for AMD filtering. Other mappings still have limits.

Vulkan Forward+, RT-capable hardware, MSAA off. Reuses RT shadow BLAS geometry;
GI has its own TLAS to include non-shadow-casting GI geometry. Resources are lazy;
disabled GI performs no GI collection/render passes and releases GI resources.
This is not a measured literal zero-CPU-cost claim. FSR2 has controlled coverage;
DLSS with GI still needs hardware validation. NRD/Ray Reconstruction are outside this baseline.
No authored probes, baking or special UV layout required for supported materials.

## Missing AMD features: value and effort

These are optional AMD paths/controls, not secretly missing stages of its default pipeline.
Potential benefits below are unmeasured in this game. Effort is a relative engineering judgment, not a schedule.

| Missing item | What we miss / potential benefit | Tradeoff and complexity |
| --- | --- | --- |
| Alternative split-ratio reflection denoiser; independent reflection denoiser selection | Another noise/detail/speed choice to compare on shiny weapons and other reflections | No demonstrated improvement over the default. Moderate integration/testing effort. |
| Additional GridStream selection modes: directional cells, intermediate resampling, random/with-replacement merging, cell overlap | More ways to spend a small ray budget on useful lights; potentially less noise around many lights/emitters | Some add computation or change quality tradeoffs. Moderate–high effort across all modes. |
| Fast centroid and parallel light-grid construction | Simpler preparation or more GPU parallelism; possible savings with many lights | Simpler preparation is less accurate; parallelism may not help small scenes. Moderate effort. Not a proven stutter fix. |
| Cosine and importance environment sampling | Spend more sky samples in useful directions or on bright regions | Benefit depends on the sky; dynamic skies require updates. Moderate effort. Uniform sampling exists. |
| Low-emission area-light exclusion and threshold | Avoid spending explicit light-sampling work on very dim glowing surfaces | Can lose subtle light. Relatively low effort; primary visible emission is a separate matter. |
| Remaining cache/detail/history, near-field, reflection cleanup and category/debug controls | More tuning for hardware presets and isolated comparisons | Some defaults are fixed and some controls coupled. Low–moderate per control; no measured shipping presets. |
| Probe/cache/mip/decay/propagation/reflection visualizers and occupancy/overflow statistics | See where stored lighting is missing, stale or overloaded; diagnose failures | No direct image improvement. Moderate effort for the full suite. Existing test readbacks are not equivalent tools. |

Exact frozen option/function inventory: [coverage snapshot](history/AMD_GI_ARCHIVE.md#snapshot-amd-gi-comparison-coverage).
Its old “absent” statements describe the pre-correction revision; use this page for current status.
The default near-field GI stage is now implemented. Other APIs and unrelated Capsaicin renderer features are not missing work for this Vulkan-only request.

## Godot compatibility gaps, ranked by potential impact

Ranking is conditional on actual asset use, not evidence that each category is active in the game.
Skipped geometry can remain visible on screen but fail to block/bounce light or appear in ray-traced reflections.
Supported objects continue rendering GI; unsupported objects no longer suppress the whole GI scene.

| Priority / gap | Current consequence and benefit of support | Complexity |
| --- | --- | --- |
| 1. Material overlays and multipass/layered materials | Can omit the whole affected object/surface from GI. Support would restore blocking, bounce and reflected appearance, not just its decorative layer | Moderate–high: combine layer color, opacity and emission correctly. Simple decorative cases are easier. |
| 2. Custom shader geometry movement/position transforms; GPU-indirect MultiMesh | GI cannot generally follow these shapes/placements. Support would match visible moving geometry | High: evaluate positions and keep RT geometry synchronized efficiently. Ordinary CPU-managed MultiMesh, skeletal animation and blend shapes already have support. |
| 3. Particles, unshaded and additive effects | A visible flame/effect does not automatically contribute its shape/emission to GI. Separate supported lights can still contribute | High for transparent particle systems; narrower ordinary glowing-mesh cases are easier. Not every decorative effect should block light. |
| 4. Projector and distance-faded lights; unsupported light types | These contribute native direct light but are skipped by GI light sampling. Support restores the authored projected pattern/fade in bounced light | Moderate for projector/fade adapters; additional light types require their own sampling. Relevant to a flashlight only if it uses these features. |
| 5. Screen/depth/normal-buffer-dependent or raster-derivative shaders | Some materials are omitted because their appearance requires the camera image or neighboring screen pixels | High; arbitrary off-screen equivalents may not exist. Requires explicit semantics, not invented zero inputs. |
| 6. Complex emitter texture mappings | Nonlinear, texture-driven, loop/helper/partial-write and other unqualified mappings retain fallback filtering with a warning. Light can be incorrectly averaged or noisy | Moderate for selected patterns, high for arbitrary shaders. Ordinary supported affine mappings are fixed. |
| 7. General transparent glass behavior | Cutouts and some fractional coverage work; general refraction/colored transmission do not | Very high. Full glass transport expands beyond AMD GI's existing model; not a simple Godot adapter omission or automatically approved extension. |
| 8. Objects assigned baked lightmaps | Objects can be excluded; mixed baked/dynamic lighting is not integrated | Moderate–high: avoid counting baked illumination twice. Lower immediate relevance to the stated VBAO-based game. |

These are the known audited gaps, not a certification of every Godot feature.
AMD's approximate secondary material model is retained; full nested specular transport
is not an unimplemented default AMD feature. Screen normal maps remain supported.
The checked game's grass explicitly sets `GI_MODE_DISABLED`; adding deformation support
alone would not make it participate. Recheck actual local assets before diagnosing them.

## Local PC handoff: issues still requiring reproduction

The owner intends to open a new local session, pull this repository and allow direct
interaction with the game. Do not infer local checkout paths, build identity or current
settings from cloud paths. Verify engine revision, `fps-proto` revision and runtime settings.
The owner used the Windows **clang editor**, default AMD GI settings unless stated.
An earlier MSVC artifact crashed loading the project; do not assume that is resolved.

Retain all reported cases until a local before/after reproduction establishes their status:

- Sandbox prototyping level: frequent consistent spawn-platform stutter/flicker and incorrect prop lighting.
- Scavenging/shack area: indirectly lit surfaces boil with a stationary flashlight or when toggled; contribution changes with aim.
- Camera translation sometimes loses/restarts GI; turning alone did not trigger the same earlier symptom. A wall could lose GI until movement resumed.
- First-person assault rifle intersecting a wall creates a large box artifact.
- Muzzle-flash light causes surrounding GI to disappear/recover for longer than the flash lasts.
- Crossroads, Fieldway and Hideout appeared to have little/no GI while stutter remained.
- Golden AK reflections become noisy/firefly-heavy with tiny motion, settle slowly, and oddly resolve immediately on pause. Full-resolution reflections help settled noise but do not eliminate fireflies.
- Rapidly alternating electrical hazard causes severe noise. One diffuse sample/pixel reduces flashlight boiling but does not eliminate it.

Capture the actual game, settings, motion and logs; distinguish omissions, history resets,
shader compilation/scene preparation and GPU work using evidence. `GODOT_AMD_GI_TRACE_HISTORY=1`
is opt-in instrumentation. Check warnings for skipped surfaces/lights and unqualified mappings.
Do not use higher ray counts, disabled denoising or settled stills to hide defects.
The local investigation is the next task; this documentation change does not implement extra features.

## Owner constraints and hardware targets

- AMD's actual algorithms take priority. New deviations need a strong evidence-backed explanation and **explicit owner approval before implementation**; see [approved scope](AMD_GI_ADAPTER_DECISIONS.md).
- Keep GI fully optional and user-configurable. Preserve comparison with native Godot GI and a possible future separate backend. Do not mix backends for a comparison.
- Default previews: **quarter primary diffuse ray/pixel budget**, denoiser enabled. No repeated 1-sample comparison unless requested; no high-sample substitutes.
- Game preview screenshots: representative **Crossroads** location. Cloud previews use FSR2 at native render/display scale, not extra downscaling. Deliver PNGs in the preview directory, not HTML-only viewers.
- Laptop and Radeon 780M machine are the same device: Ryzen 7 7840HS. Recalled baseline ~60 FPS at 2560×1600 display, FSR2 Performance, RT shadows + VBAO, grass disabled, RT soft shadows disabled.
- GI goal ~40 FPS; lowest GI setting must stay above 30 FPS under those conditions. Neither target is validated. RTX 5090 desktop has headroom; its visual defects still matter.
- Do not describe clang/MSVC as different GI quality modes; they are compiler/build variants. Verify the commit for comparisons.

## Evidence and navigation

Software-Vulkan checks cover default quarter-budget integration, cache/hit ownership,
multibounce, moving reflections, light/sky changes, FSR2 poses, odd sizes and disable/lifetime.
Latest affine follow-up: 704 material samples pass; existing source oracle: 256 pass;
emitter room and five unsupported-mapping warning cases pass. These are sample checks,
not a high-samples-per-pixel preview. Earlier reflection regression covers 344 checked frames.
These do not prove user-game quality, hardware performance or full AMD pixel equivalence.

- [Controls](features/amd-gi.md): live settings/defaults and backend conflicts.
- [Material integration](internals/rt-materials.md): current source map and resource contract.
- [Validation](VALIDATION.md) and [harness](validation/shadow_validation/README.md): commands/scorers; proofs live in `docs/validation/amd_gi_source_proofs/`.
- [Archived corrections/evidence](history/AMD_GI_ARCHIVE.md#snapshot-amd-gi-consequential-corrections): finding IDs, measured values, failed attempts and test limits.
- Windows renderer checkpoint build: [run 40064182311](https://github.com/automata-rtx/godot-rt/actions/runs/40064182311) for `837fb30`. Check run/artifact status before claiming a downloadable build. Later documentation commits do not change the renderer.

Cloud evidence paths in the archive are not guaranteed to exist locally. Committed fixtures
and proofs are portable; regenerate outputs when needed rather than assuming those logs were pushed.
