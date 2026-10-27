# Validating engine changes

Select checks by the code being changed. This is a test index and acceptance
contract; [status](STATUS.md) records which checks actually ran. Project-facing
reproduction guidance is [here](../GodotForkDocs/TESTING.md). Runtime execution
still requires whatever authorization applies in the current task.

## Evidence levels

| Evidence | Establishes | Does not establish |
| --- | --- | --- |
| Source audit / build | Registration, types and linked implementation | GPU execution, visual correctness, speed |
| CPU oracle / isolated production-method test | Its mathematical or control-flow contract | Driver behavior, all materials, shader side effects |
| Offline GLSL compilation | Covered shader permutations parse/compile | Native project material pipelines or driver limits |
| Renderer fixture with scorer | The specified scene and asserted outputs | Every scene, resolution, GPU or user issue |
| Controlled target-game run | The observed reproduction on that build/machine | Universal parity, performance or long-term stability |

Require the expected completion marker **and** relevant zero-error assertions,
process result and logs. For Streamline, also check new SDK/Windows dumps and
successful SDK shutdown. Separate expected fallback warnings from actual failures;
do not discard all warnings/errors to get a green fixture.

## Regression routes

| Changed area | Existing entry points (under `docs/validation/` unless stated) |
| --- | --- |
| Buffer addresses, AS inputs, graph access | `shadow_validation/buffer_address_lifetime.gd`, `tlas_instance_upload_lifetime.gd`, `compute_indirect_storage.gd`; `tests/servers/rendering/test_rendering_device_tlas_update.cpp` |
| Shared geometry / compressed/deformed meshes | `shadow_validation/geometry.gd`, `amd_gi_deformation.gd`, `amd_gi_multimesh.gd`; test both RT shadows and GI |
| Native source-material evaluation / uniform and texture changes | `shadow_validation/material.gd`, `amd_gi_source_material.gd`, `amd_gi_material_sharing.gd`, `amd_gi_dirty_materials.gd`, `amd_gi_scene_metadata.gd` |
| GI scene/descriptor reuse and resource lifetime | `amd_gi_optimization_2026_10_26/run_regressions.py`; `bindings/` lifecycle fixture and ordinary-cache oracle; use bypass switches for matched performance checks |
| Retained GI scene groups and buffer-read groups | [Design and acceptance](validation/gi_cpu_retention_2026_10_26/PLAN.md); metadata subject oracle, actual-retention image/light-storage routes below, and `tests/servers/rendering/test_rendering_device_buffer_read_group.cpp` |
| GI CPU follow-up | [Source-reviewed implementation](validation/gi_cpu_retention_2026_10_26/CPU_FOLLOWUP_IMPLEMENTATION.md): combined source Context cache, changed-range decision oracles and collected MultiMesh retention; owner smoke test accepted, automated runtime regression pass pending |
| Shadow preparation and shared TLAS CPU reuse | `rt_cpu_optimization_2026_10_26/run_lifecycle.py` and `score.py` compare exact hard-shadow outputs; `run_native.py` exercises actual queued GPU queries and upload lifetimes; [acceptance contract](validation/rt_cpu_optimization_2026_10_26/TESTING.md) |
| Exact-default reflection rank shortcut | `amd_gi_optimization_2026_10_26/firefly/` CPU proof and extracted-production GPU comparison; then production reflection regression and game benchmark |
| Light/emitter updates and transient flashes | `shadow_validation/amd_gi_light_storage.gd`, `amd_gi_emitters.gd`, `amd_gi_emitter_coordinates.gd`, `amd_gi_flashlight.gd`; then the project reproduction |
| GI scheduling/cache/bounce/material identity | `shadow_validation/amd_gi_consequential.gd`, `amd_gi_cache.gd`, `amd_gi_scene_churn.gd`, `amd_gi_feedback.gd`, plus relevant `amd_gi_source_proofs/` oracle |
| GI sky/reflection/runtime options | `shadow_validation/amd_gi_sky.gd`, `amd_gi_reflections.gd`, `amd_gi_options.gd`; corresponding `score_amd_gi_*.py` tools |
| VBAO | `ao_validation/README.md`: scene render plus geometry and depth-buffer CPU references |
| Contact shadows / shadow opacity | `shadow_validation/README.md`: `probe`, `field`, `field_thin`, `opacity`; compare linear-light captures with the intended reference |
| Streamline cleanup | `streamline_shutdown/generate_test.py` generates isolated C++17 tests of production cleanup methods; follow with authorized enabled/unused/disabled, local-device and game exit tests |

Unqualified fixture and scorer filenames in these rows inherit the
`shadow_validation/` directory. The shadow harness's `run.sh` maps many names to scenes, scorer commands and
diagnostic environment variables. Inspect it and the fixture README before
running; not every standalone script is a runner target. It is a Linux shell
harness with software-Vulkan/Xvfb assumptions, not a Windows command template.

For a Windows graphical fixture, a typical explicit invocation is:

```powershell
& ./bin/godot.windows.editor.x86_64.console.exe --path docs/validation/shadow_validation --rendering-driver vulkan --audio-driver Dummy --windowed --resolution 321x181 res://amd_gi_scene_metadata.tscn
```

This launches Godot. The metadata oracle additionally requires
`GODOT_AMD_GI_VALIDATE_SCENE_CACHE=1`; set it only for that run and restore the
previous environment afterward. `amd_gi_light_storage` requires both
`GODOT_AMD_GI_VALIDATE_LIGHT_STORAGE=1` and
`GODOT_AMD_GI_VALIDATE_EMITTER_UPDATES=1`. `amd_gi_consequential` enables
`GODOT_AMD_GI_VALIDATE_HITS`, `GODOT_AMD_GI_VALIDATE_BOUNCES` and
`GODOT_AMD_GI_VALIDATE_CACHE`. A scene exit without its oracle is weaker coverage.
Some fixture scripts select their own resolution/settings; do not silently
override them when reproducing a recorded result.

For retained GI groups, run the metadata fixture with
`GODOT_AMD_GI_TRACE_RETAINED_GROUPS=1` and the scene-cache oracle, then run
`gi_cpu_retention_2026_10_26/score_retained_metadata.py` on its log. Check both the
default emissive subjects and `GODOT_AMD_GI_TEST_NONEMISSIVE_METADATA=1` variant.
The scorer requires subject-specific reconstruction checks after mutations,
emitter membership/prefix and sampling changes, and repeated preparation failure
followed by recovery. An unrelated unchanged floor cannot satisfy it.

The regression runner's `--retained-scene` route for `amd_gi_multimesh`,
`amd_gi_deformation` and `amd_gi_light_storage` removes history tracing so actual
record reuse occurs. It keeps image/GPU-byte assertions and requires complete
scene retention in settled stages; emissive scenes also require positive emitter
reuse. Run the ordinary route separately when checking history-reset assertions.
Do not use reconstruction-oracle or trace timings as performance measurements.

Build with `tests=yes` and run the opt-in native GPU case with
`--test "--test-case=*Buffer read groups preserve BDA dependencies*" --no-skip`.
Require its two-device/four-round completion marker and all 120 assertions; an
exit code alone does not prove the GPU test ran. On Windows, the console launcher
captures the assertion summary reliably. This exercises actual BDA reads, uploads,
indirect dispatch, barriers, stale handles and independent device ownership.

## Correctness coverage that matters

Test compressed/uncompressed and static/deformed geometry, in-place edits,
resource replacement/deletion, reused handles, shared materials, texture updates,
mirrored transforms, MultiMesh counts/transforms/color/custom data, empty scenes,
membership churn, descriptor growth and failed-preparation recovery as relevant.
Use odd internal dimensions, resize and feature toggles. Test more than one
viewport/scenario when modifying shared caches. No single fixture covers this all.

Check native depth/normal/motion/opacity/lighting capture separately from the
transport and denoiser. Unbiased reference inputs and an unchanged control prevent
an estimator defect from being mistaken for incorrect scene reconstruction.
Convert PNG sRGB to linear light before differencing. Software Vulkan can validate
supported contracts; inspect actual capability gates and do not call a fallback
render a successful RT/GI test.

For GI debug views, verify every selected resource exists for that combination,
off paths are black/safe, atlas last/out-of-range pages are bounded, mip/cache
switches are coherent, and diagnostics do not alter complete radiance feedback.
Turn reporting off and verify readbacks stop. The prepared options fixture covers
these combinations; its existence is not a record of completed execution.

## Performance and build gates

Measure CPU and GPU independently on target hardware after warmup. Keep shaders,
scene motion, exposure, internal size, upscaler and competing work controlled.
Disable validation readbacks/statistics/capture for normal cost measurements.
Keep first-load/shader preparation spikes separate from steady-state timings.
Test the relevant exported build too; use matching fork templates and runtime DLLs.

The default workflow invokes static checks and Windows jobs. The Windows matrix
contains MSVC/clang-cl editors and release templates, not `template_debug`.
Other platform workflows remain in the tree. A project can require a separately
built matching debug template; this is not an engine prohibition on debug exports.
Local compilation remains valid, for example:

```text
scons platform=windows target=editor arch=x86_64 dev_build=no debug_symbols=no
```

Run repository hooks over the full intended publication range. Regenerate bound
API class docs with the matching doctool when authorized; the default Windows
workflow does not replace the former Linux doctool/API-compatibility/export checks.

Detailed historical counts, captures, command variants and old methodology remain
in [archived validation](history/pre-streamline-2026-10-26/docs/VALIDATION.md).
Consult them for a named regression, not as a claim that a new build passed.
