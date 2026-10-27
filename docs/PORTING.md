# Rebuilding godot-rt on a newer Godot

This is the dependency map for a clean reimplementation, not a promise that an
old patch applies. Audited at `66bd97e00d` (2026-10-26). The feature guides below
own shader/data contracts, algorithms, source symbols, and per-feature tests.
Read those for the feature being rebuilt; the portable pack is for game authors.

| Layer | Technical specification |
| --- | --- |
| Shared ray-tracing geometry and RT direct shadows | [RT shadows](internals/rt-shadows.md) |
| Native source-material evaluation and GI hit metadata | [RT materials](internals/rt-materials.md) |
| AMD GI transport, caches, samplers, filters and diagnostics | [AMD GI](internals/amd-gi.md) |
| Visibility-bitmask ambient occlusion | [VBAO](internals/ambient-occlusion.md) |
| Directional screen-space contact shadows | [Screen-space shadows](internals/screen-space-shadows.md) |
| DLSS, frame generation and device/SDK lifetime | [Streamline](internals/dlss.md) |

## Establish the source contract first

The original fork base is `b56a91878e7c94977e4af978968e41d0670c0a8b`; it exists
in this repository and is an ancestor of the audited revision. Inspect
`git diff b56a91878..66bd97e00d -- <path>` for provenance. Do not assume every
intervening commit is a self-contained rendering feature or copy an older stage
recipe over later fixes. Preserve upstream and third-party licenses.

For the target Godot version, map symbols and consumers again. Verify:

- RenderingDevice's AS creation/build/update and resource dependency APIs,
  device addresses, buffer owners/usage bits, descriptor limits and capabilities.
- Draw-graph hazard tracking for compute writes, indirect reads, transfer copies
  and acceleration-structure builds. A buffer can be storage and indirect input
  in the same dispatch; required access masks must be combined.
- Mesh compression, index/attribute layouts, skeleton/blend-shape buffers,
  motion-vector buffer switching and mesh/resource revision notifications.
- Culler instance types and surface/material shadow eligibility; instance/layer
  masks; MultiMesh CPU versus GPU-indirect ownership; viewport/scenario lifetime.
- Native shader generation, motion/depth/material attachments, descriptor and
  push-constant layouts, internal resolution, and final direct/indirect lighting.

Do not assume newer upstream has the same ray-tracing layer merely because the
version number is higher. Capability checks and buffer allocation must agree.

## Rebuild order and acceptance gates

| Step | Integrate | Gate before proceeding |
| --- | --- | --- |
| 1. Device and graph contracts | Fork RD helpers, buffer address/lifetime handling, combined storage+indirect access, TLAS update eligibility/accounting, backend implementations and safe shutdown hook | AS/buffer/indirect fixtures pass on the intended driver; invalid/replaced resources fail safely |
| 2. Startup capabilities and geometry | RT master latching; buffer flags at static and deformed upload sites; `rt_geometry` shared BLAS cache; native decoding and revision tracking | Compressed, uncompressed, in-place-updated, skinned and blend-shaped geometry matches current raster geometry |
| 3. RT scene and direct shadows | Culler gather, masks/light slots, shadow TLAS, tracing, denoiser and fallback/map routing | Local and directional lights, material/caster exclusions, transparent/fog paths and frame history remain correct |
| 4. Raster feature adapters | VBAO final AO-buffer integration; screen-space-shadow depth/caster attachments and restricted gather | Each works independently and together at odd sizes, with current motion/depth prepass layouts |
| 5. Native GI material/scene adapter | Full native material identity and source paths, attribute/opacity/emission evaluation, world-space geometry/hits, instance transforms, revisions, MultiMesh and emitter updates | Source-material, metadata mutation, shared-material, deformation and light/emitter regressions pass |
| 6. AMD GI scheduling | Pinned AMD transport/caches/probes, compaction and dispatches; current-frame AS preparation and failure recovery; sky/reflections; radiance feedback | Known-answer and production-pipeline checks pass; no stale descriptor/scene fallback on failed preparation |
| 7. Optional controls and lifetime | GI diagnostics/visualizers and filters; native upscaler integration; Streamline binding and cleanup | Toggle/resize/multiview-resource tests, local-device isolation and clean exits; disabled resources are never sampled accidentally |
| 8. Public API and delivery | Registration, bindings, class docs, inspector hints, matching editor/export templates and runtime DLLs | New-project and exported-project smoke tests use the exact built artifacts; hooks and required reference docs pass |

VBAO and contact shadows can be rebuilt independently of GI. Their **shared
prepass/layout integration** must still be revisited when GI adds attachments.
Streamline can likewise be integrated separately; do not turn this dependency
order into an unnecessary requirement to enable every effect in a game.

## Changes made for GI that an RT-shadow-only port would miss

- Geometry ownership moved into shared `RaytracingGeometry` infrastructure. Preserve
  coordinated frame boundaries across shadow and GI consumers: either consumer's
  cleanup must not evict resources still needed by the other.
- Current mesh/index geometry revisions invalidate shared BLAS state. Older notes
  that prescribe replacing a whole surface to update static RT geometry are stale.
- Retain the upload flags on **all** relevant source/deformed/dequantized buffers,
  including motion-vector buffer pairs. A storage RID is not interchangeable with
  a vertex RID merely because both refer to GPU memory.
- Shadow gathering and GI scene/material collection have distinct eligibility.
  GI's native alpha/material evaluation does not make opaque RT-shadow queries
  automatically alpha-aware. Shader displacement remains a separate limitation.
- GI has current-frame AS submission and conditional TLAS refit; do not describe
  the shadow TLAS as refitting merely because it shares the BLAS cache.
- Same-frame emitter/material preparation, cached descriptor/layout invalidation,
  and split light-capacity/emitter storage are part of GI's CPU integration. Port
  their mutation/lifetime contracts, not just the expensive shader passes.
- `RenderingDevice::BufferReadGroup` batches repeated device-address source reads.
  Preserve full RIDs and validated owner types, and check the originating device's
  ObjectID. Every replay must validate RID generations, check current transfer
  state and use current resource trackers; never retain raw buffer/tracker pointers.
  Declare dependencies again for every compute-list segment, preserving combined
  storage/indirect usages. Publish only fully validated groups; a failed replay
  must prevent the following dispatch and close the active list safely.
- AMD GI startup still depends on `raytraced_shadows/enabled` in this source.
  Its own live switch is not permission to allocate meshes without RT usage bits.

Concrete source maps and test prerequisites are in the RT and material guides.
The [native BDA regression](../tests/servers/rendering/test_rendering_device_buffer_read_group.cpp)
checks transfers, mutable-buffer transitions, GPU-written indirect arguments,
queued-resource lifetime, stale RIDs and local-device isolation. Build with
`tests=yes` and explicitly select `--test --test-case="*Buffer read groups preserve BDA dependencies*" --no-skip`.
Require an executed GPU test with successful output assertions; compilation,
default skipping or missing Vulkan/BDA support is not acceptance. The
[read-group plan](validation/gi_cpu_retention_2026_10_26/COMMANDS_PLAN.md) records
the design and separate oracle/benchmark controls.

## Shader and API compatibility checklist

Keep CPU struct sizes/offsets, GLSL descriptors, image formats, specialization
variants and barrier declarations synchronized. Validate offline shader variants,
then create the real driver pipelines: fallback shader compilation does not
compile every project's native materials. Use assertions/development diagnostics
where available, but do not rely on them being enabled in normal editor builds.

Preserve reverse-Z, matrix handedness, unjittered motion, exposure and radiance
units at native boundaries. Use actual internal render dimensions; test odd sizes
and nontrivial upscaling rather than assuming display size or rounding behavior.
Preserve full lighting feedback before debug display isolation. Do not substitute
arbitrary clamps, history resets, higher ray counts or extra blur for correctness.

Public property changes span `core/config/project_settings.cpp`, scene resources,
RenderingServer/RD bindings, storage/culling and `doc/classes/`. Copying only a
shader or only the inspector property is incomplete. GPU capability warnings
should state the actual checks, not stale limits copied from a prior handoff.

## Verification and provenance

Use [validation](VALIDATION.md) to choose the affected fixtures, then the target
project's reproduction. A fixture file, compiling editor or CPU oracle is not a
passing hardware result. Preserve an unchanged control, check feature-off paths,
resource churn, motion, resize and shutdown, and report the exact target machine.
Follow current execution authorization before launching any engine fixture.

For AMD algorithm changes, consult [approved adapter boundaries](AMD_GI_ADAPTER_DECISIONS.md)
and the pinned source before reinterpreting behavior. The detailed old derivations
and stage recipes remain [archived](history/pre-streamline-2026-10-26/docs/PORTING.md)
for targeted investigation, but their old line numbers and superseded claims are
not a current implementation recipe.
