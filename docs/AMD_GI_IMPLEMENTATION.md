# AMD GI integration

**Status: the main AMD GI-1.2 pipeline and default-path correction pass are implemented for qualified inputs. Full feature parity and production qualification remain incomplete.**
The [live consequential correction record](AMD_GI_CONSEQUENTIAL_CORRECTIONS.md) lists every correction, approved exception, test and remaining input limitation. Optional AMD features remain deferred.
The previous completion statement covered stage presence, not fidelity to AMD.
See [the complete source comparison](AMD_GI_FULL_COMPARISON.md) and
[coverage appendix](AMD_GI_COMPARISON_COVERAGE.md) for every stage and option.
The [earlier correction ledger](AMD_GI_REFERENCE_AUDIT.md) is historical;
its restored/translated labels do not certify reference equivalence.
Cached diffuse GI, sky lighting, and glossy reflections run on Vulkan Forward+.
It implements sparse screen probes, directional hashed world radiance, multibounce
feedback, reconstruction, and temporal/spatial GI denoising. Progress captures use
the default approximately 1/4 primary GI ray per internal pixel per frame, with
denoising on. Earlier one-ray captures remain historical evidence only.
See [the implemented pipeline and explicit port gaps](features/amd-gi.md).
Sampling, cache-update and glossy scheduling stages are implemented. Software-Vulkan
integration, controlled motion and game-scene checks are recorded below. Engine-specific
material and scene limits are documented explicitly; this is an adaptation, not a
pixel-identical Capsaicin renderer or a general path tracer.

The [2026-10-23 gameplay audit](AMD_GI_GAMEPLAY_AUDIT.md) reproduced full-history
resets on light toggles, complete glossy-history rejection on a moving metal object,
material-capture churn, and default-capacity suppression in Crossroads and Fieldway.
Those findings apply to the audited `3038a14` build. Native previous-surface
reprojection, explicit emitter sampling, reflection firefly cleanup/compaction,
GPU material expansion/residency and capacity preflight are now implemented locally;
combined gameplay checks now cover these paths. Settled stills and global reset
counts did not establish gameplay quality. These are implementation defects and
missing stages, not a justification to increase the primary ray budget.

The requested endpoint remains an optional Vulkan Forward+ implementation of AMD's
GI-1.x architecture, including the later reflection and multibounce work. This file
separates that endpoint from implemented code. No performance or fidelity claim for
AMD GI in this fork has been measured.

## Reference corrections after 848af68

The current working tree restores GridStream unified light proposals, primary
emission bypass, the rough dielectric secondary BRDF, reference RNG, packed
radiance sums and default cache capacity, delayed multibounce updates, and probe
reuse/guiding. Both reference optional feedback flags now default off. A sixth
GI-only prepass attachment supplies primary albedo/metalness. See the live
[consequential correction record](AMD_GI_CONSEQUENTIAL_CORRECTIONS.md) for evidence and remaining limits;
the older implementation/measurement notes below are not a completion claim.

The environment follow-up restores wide-proposal/narrow-final sky cones, a complete
ordinary cubemap mip chain, fresh-reservoir target conversion and blocked-reservoir
invalidation. The current correction replaces AMD's material atlas with native source
shading and removes its arbitrary instance/light collection caps. The sole-emitter
fixture passes with zero atlas residency. Qualified source-material and affine emitter tests pass. The approved distance correction restores full participating-scene collection and the reference ray extent; the extended sky-removal regression passes. Exceptional-domain decisions and remaining native-input limitations are explicit in the live consequential record rather than the older build results below.

## Implemented infrastructure

`servers/rendering/renderer_rd/environment/rt_geometry.{h,cpp}` extracts geometry
ownership from `RaytracingScene`. The existing RT shadow path uses that cache:

- Static instances of a mesh share one BLAS per surface. Deforming surfaces retain
  their per-instance buffers and pose update behavior.
- Compressed positions still use the existing GPU dequantization pass. Uncompressed
  positions still use the source buffer directly.
- Surface lookup exposes the BLAS, the actual position and index buffers used to
  build it, vertex/index counts, index element size, and a successful-build revision.
  A pose rebuild advances the revision even if the BLAS RID is unchanged.
- Visibility selection, layer folding, and the shadow TLAS stay in `RaytracingScene`.
  Materials and lighting do not belong to the geometry cache.
- Cache construction performs no GPU allocation or shader initialization. The
  existing shadow enable/support gate still controls initialization.

The shared GI scene adapter is now a second geometry consumer, used by both the cached diffuse path and transport validator. Storage remains owned
by the shadow scene, while `RendererSceneRenderRD::update_raytracing_scene()` coordinates
one `begin_update()`/`end_update()` around both consumers. They share the build budget
and BLASes but build independent TLASes. GI selection does not reuse the shadow-caster
predicate. Do not add a second cache or reset its budget per consumer.

### Lifetime contract

All calls run on the rendering thread. A pointer returned by `get_surface()` is
borrowed and may expire on the next cache mutation; copy the `Surface` descriptor
before another request. Clients never free the GPU handles. Mesh replacement or
removal can destroy a BLAS through RenderingDevice dependencies, so a retained
TLAS does not permit retaining an unchecked descriptor. Request each surface again
before tracing, and compare both BLAS RID and revision when deciding whether to
rebuild a client TLAS. A null lookup means unavailable geometry, not permission to
trace a stale snapshot.

The shared cache now detects in-place vertex/index edits through mesh surface
geometry revisions. Permanent ineligible entries remain a limitation. Its age and build budget
are per scene update, not per display frame. These are described in
[internals/rt-shadows.md](internals/rt-shadows.md). Sharing with another consumer
uses explicit consumer tracking: when validation is disabled, `release_gi_only()`
removes entries used by GI that the current shadow update did not request. Shared
shadow entries survive. Normal cache age-out alone would not release GI-only resources.

## Implementation coverage and limits

| Work | Required result |
| --- | --- |
| Automatic hit shading | Native shader source, uniforms, textures and vertex attributes are evaluated at hits; source attribute copies follow revisions and poses reuse shared GPU geometry. Source-specific qualification and unsupported shader/particle inputs remain explicit limits |
| Scene collection | Independent mesh/light collection includes native poses, off-screen non-casters and authored GI participation; buffers grow with supported inputs. The full participating scene is collected and the default ray extent is 1e9; unsupported classes are reported/skipped individually |
| World radiance cache | Reference-capacity checksum-hashed tiles with packed sums, sample-count-selected mips, touched-tile updates and delayed indirect accumulation; unified GridStream proposals and independent multi-hit reservoir reuse. Native hit inputs and registered sample membership have controlled GPU validation; whole-renderer pixel parity and target-hardware performance are not established. |
| Screen probes | Dense stored grid with sparse updates, adaptive hole patching, current-grid neighborhood hit reprojection, bounded displaced-probe LRU reuse, radiance/BRDF guiding, angular rebinning/filtering, hierarchical mask lookup, two-dimensional temporal blue-noise sampling and SH9 reconstruction |
| Multiple bounces | Continuations populate and shade secondary world receivers, then propagate current direct light and previous indirect feedback through separate histories; compatible combined native screen-lighting feedback is implemented; all-hit update scheduling is implemented with an optional lower-cost mode |
| Reflections | GGX sampling, rough-probe reuse, compacted tracing, firefly cleanup, ratio reconstruction, virtual/surface temporal history and a-trous filtering implemented; secondary materials follow AMD's diffuse approximation rather than general nested specular transport; gameplay quality validation remains |
| Conventional denoising | Diffuse geometry reprojection, rejection, temporal clamping and adaptive spatial filtering; native previous-surface reprojection including native poses; glossy temporal/spatial variance, surface/virtual reprojection and outlier cleanup. No NRD or Ray Reconstruction |
| Composition | Validation diffuse uses Forward+'s shared incoming-diffuse input before fog, tone mapping, and upscaling; specular shares the native incoming-reflection channel; FSR2 software-Vulkan checks pass, DLSS runtime testing remains |
| Controls and comparisons | Script-accessible runtime controls and exclusive dynamic backend selection, retaining native Godot GI for comparisons |
| Validation | Software-Vulkan reference/controlled images, moving scenes, resource lifetime checks and actual game-map collection checks pass. Measurements on the 780M/5090 and DLSS runtime validation are outstanding |

### Native source materials and legacy capture

AMD GI now uses `rt_material_source` to evaluate native material programs and
textures at actual hits, including source alpha candidates and emitter sampling.
It does not allocate or prepare a triangle-material atlas. See
[internals/rt-materials.md](internals/rt-materials.md) for resource ownership and
qualification limits. The approved affine emitter adapter now follows each supported texture mapping rather than always using UV0 for filtering; arbitrary warped/texture-driven mappings remain unqualified. Geometry and shading normals transform once under the
owner-approved correction. The owner also approved classifying an EMISSION-writing shader as emissive independently of its sampled RGB; dark texels and phases retain that classification.

The following capture description applies to the uncached transport validator
and standalone material-bake diagnostic, not the current AMD GI material path.

`environment/rt_material_capture.{h,cpp}` adds an explicit, bounded capture primitive.
It evaluates Godot's own material shaders into GPU textures for a selected range of
triangles. Placement and original vertex IDs use a separate storage buffer, preserving
the source UV0, UV2, colors, tangents, and custom inputs. Neither the source mesh nor
its UV layout is modified. Surface materials, material overrides, current parameters,
textures, cutout alpha, and HDR emission flow through the native material pass.

`RenderingServer.bake_render_triangle_material()` exposes synchronous readback for
validation only. Its four images follow the existing `BakeChannels` order. The
internal capture class retains GPU textures without reading the output back. The
opt-in transport validator calls it before preparing the main scene render lists;
ordinary frames with validation disabled do not. Capture resources exist only after
an explicit call and are released by `clear()` or destruction.

The material cache uses native shader capture rather than a separate authored hit
material system. Preparation
expands native packed source attributes on the GPU without source readback; active
GI retains that geometry and its targets until source revisions change. Material
pixels persist for tracked static inputs, with dynamic inputs refreshed per frame. Output pages are bounded, but fixed
per-triangle sampling (8/4-pixel maximum, automatic 4/2-pixel capacity adaptation) can lose texture detail and waste memory. New preparation is bounded by a live
chunk budget; completed pages persist until the collected scene is ready.
Particles and screen/camera-dependent hit materials are not supported. Explicitly
excluded GI geometry stays outside transport; included unsupported geometry reports
a fallback instead of silently disappearing from the traced scene. See [internals/rt-materials.md](internals/rt-materials.md)
for the representation, limitations, and renderer contract.

The discarded initial draft overwrote UV2 and had unbounded page allocation. Do not
restore that approach. A native material test is required before changing capture
placement or source attributes; checking only StandardMaterial3D colors is insufficient.

### Transport validation checkpoint

See [features/rtgi-validation.md](features/rtgi-validation.md) for the runnable scene,
live settings, and limitations. `RTGIValidation` is intentionally uncached: every
validation frame captures the current materials and traces independent diffuse paths.
A fixed scene is deterministic, and moving materials cannot leave a temporal history
behind. High sample counts produce useful stills without a denoiser; they are not
performance presets. The mode is a test of the transport connection, not a substitute
for implementing AMD's two-level radiance caching.

The controlled room demonstrates indirect light in shadows, colored interreflection,
additional energy from more bounces, and material changes on a wall that does not cast
shadows. Setting indirect energy to zero or disabling the mode restores the direct-only
control exactly. Results are software Vulkan correctness evidence, not target-GPU timings.

`gi_compare` reuses that room for native VoxelGI and SDFGI still comparisons;
[its protocol](features/amd-gi.md#native-comparisons) records
bake settings, settling frames, and unchanged direct-only controls. It now evaluates
the sparse cached diffuse pipeline with denoising on. Historical high-sample
transport captures must not be used as representative progress images.

## Required optionality and controls

Disabled GI must allocate no GI histories, cache buffers, TLAS, material captures,
or shader pipelines, and must schedule no GI gathering, capture, trace, filtering,
or composition. Disabling an active backend must release its resources and invalidate
history before re-enabling. Shared shadow BLASes remain owned by the active shadow
consumer. Pipeline compilation and mesh buffer provisioning must be distinguished
from live quality settings; the latter must not require a restart.

The intended graphics options cover probe update density, cache memory, tracing
distance, multibounce, reflections and reflection quality, and denoising. Presets
must map to those controls rather than introduce a second set of renderer behavior.
The `rt_validation/*` settings control only the diagnostic integrator. The new
`amd_gi/*` controls configure the sparse cached path; neither group is a measured
shipping quality preset.

Backend selection must support native Godot GI, AMD GI, and a later independent
experimental backend. It must not silently sum AMD GI with SDFGI, VoxelGI, or SSIL.
An explicit policy is also needed for LightmapGI, reflection probes, sky lighting,
and the existing VBAO contribution. Preserve authored native settings when switching
back. Comparison scenes can require native-GI setup; AMD GI itself must not require
lightmap UVs, probe placement, bake steps, or replacement materials.

RR is outside this work. DLSS/FSR compatibility means correct integration and motion
handling, not reliance on either upscaler to hide an unstable GI signal. MSAA and
multiview are outside the game's current configuration; unsupported modes must
report a clear fallback instead of accessing missing render buffers.

## Acceptance and performance

Future game comparisons use only the default approximately 1/4 primary diffuse ray
per internal pixel per frame, with denoising enabled. Match the camera, materials,
lighting, exposure and settling protocol. Use Crossroads and native-resolution
FSR2 for cloud previews; save original phone-readable PNGs in `/workspace/preview`.
Earlier quarter-versus-one captures remain historical evidence. Record reflection,
continuation and visibility ray budgets separately.

1. Build and shader ABI checks, including release builds and awkward internal sizes.
2. Disabled-path images against the baseline, plus hardware GPU timing, memory, and
   allocation checks. Identical images alone do not establish zero runtime cost.
3. Static, compressed, indexed/non-indexed, deforming, instanced, replaced, and
   destroyed geometry; material/light changes and off-screen contributors.
4. Reference comparisons for diffuse transport, multiple bounces, and reflections.
5. Motion, disocclusion, resize, camera cuts, backend switches, and scene unload,
   including FSR2 on the 780M and DLSS on the RTX machine.

The user's baseline is approximately 60 FPS on the Radeon 780M laptop at a roughly
2560x1600 display resolution with FSR2 Performance, RT shadows, and VBAO; custom
grass and RT soft shadows are disabled. The intended GI target is about 40 FPS,
with the lowest GI quality staying above 30 FPS throughout measured gameplay on
that configuration. The corresponding approximate frame budgets are 25 ms and
33.3 ms (arithmetic, not measurements). The baseline is a remembered estimate,
not a captured benchmark. The RTX 5090 is the high-end target.

No setting can promise an all-scenes minimum from an average framerate. Measure
whole-frame times and individual GI stages on representative worst cases, including
cache initialization and streaming. Software Vulkan is useful for correctness but
cannot decide these quality tiers.

## Sources

- [AMD GI-1.0](https://gpuopen.com/download/publications/GPUOpen2022_GI1_0.pdf):
  two-level radiance caching with screen probes and a world-space cache.
- [Capsaicin's GI implementation](https://github.com/GPUOpen-LibrariesAndSDKs/Capsaicin/tree/master/src/core/src/render_techniques/gi1):
  source reference for the evolving implementation and reflection support.
- [AMD GI-1.2: multibounce indirect rendering](https://gpuopen.com/learn/gi-1-2-multibounce-indirect-rendering/).

The implementation reference is Capsaicin v1.3, commit
[`914b91596cd119eda85fbc1d3c7ee6ac391b1452`](https://github.com/GPUOpen-LibrariesAndSDKs/Capsaicin/tree/914b91596cd119eda85fbc1d3c7ee6ac391b1452/src/core/src/render_techniques/gi1).
In that revision, `gi1.comp` contains the additional multibounce cell population,
reservoir generation, and radiance updates; `hash_grid_cache.hlsl` defines the cache;
`screen_probes.hlsl` and `glossy_reflections.hlsl` supply the two reconstruction paths.
The upstream options include multibounce enablement and ray-discard probability,
half-resolution reflections, roughness thresholds, and denoiser pass counts. These
are reference controls, not implemented Godot settings or performance promises.

The diffuse shader adapts AMD algorithm source and retains its MIT notice. It does
not embed the Capsaicin renderer. `COPYRIGHT.txt` records the source attribution;
[features/amd-gi.md](features/amd-gi.md) records the implemented subset and deviations.

## Validation record — 2026-10-22

### Sparse cached diffuse progress

- Full Linux editor and affected `template_release` translation units compile.
  Repository hooks pass.
- The AMD progress rig passes at approximately 1/4 and 1 primary GI ray per
  internal pixel per frame, with multibounce, probe filtering, and denoising on.
  Visibility and continuation rays are additional. No uncached reference renderer
  is enabled in these captures.
- Material color changes transfer to indirect light. Camera cuts, small camera
  movement, and resizing complete without renderer errors. Disabling GI and
  setting indirect energy to zero each restore the direct-only image exactly.
  Texture allocation returns to baseline; native bake buffer pools remain warm.
- Shared shadow geometry regression images remain identical to their baseline;
  native material capture and the separate one-sample transport controls pass.
- These software Vulkan checks do not establish target-hardware performance,
  reflection support, full AMD GI-1.2 fidelity, or DLSS/FSR compatibility.

### Transport validation

- The full Linux editor and affected `template_release` translation units compile.
- The still rig passes with 128 and 512 samples per pixel on Mesa lavapipe 25.0.7,
  Vulkan 1.4.305 / LLVM 19.1.7: indirect illumination, extra-bounce energy, non-caster
  material color transfer, zero-indirect-energy control, and exact disabled restoration.
- A subsequent 8-sample lifecycle run drains 12 frames after disabling. Engine-reported
  texture bytes return from 53,848,320 to the original 10,017,536. Buffer bytes remain
  761,760 above the cold baseline; native material-bake buffer pools remain warm.
  No complete cold-start memory-equivalence claim follows from disabling the mode.
- ProjectSettings class documentation was regenerated with `--doctool .`.
- No target-hardware timings, AMD cache behavior, reflections, or upscaler compatibility
  are established by these captures.

### Native material capture

Current correction: AMD GI hit normals bypass the atlas and read native packed/posed vertex normals plus shared triangle geometry. Both transform once into world space and preserve their separate reference roles. The owner approved this narrow upstream correction and the native authored-light/material boundary. The older capture limitations below describe the legacy validator; AMD material source qualification is recorded in the live correction ledger.

- Full Linux editor build passed. Material capture and Forward+ translation units
  also compiled with `target=template_release`; this was not a full release build.
- `shadow_validation/run.sh material` passed with zero assertion failures and no
  engine errors on Mesa lavapipe 25.0.7, Vulkan 1.4.305 / LLVM 19.1.7. Its checks
  cover source attributes, compressed/indexed inputs, tangent-space normals,
  transforms, material/texture updates, cutouts, HDR emission, surface-material
  selection, page clipping, and legacy UV2 baking after triangle capture.
- All 11 geometry captures still match the original baseline below exactly.
- `--doctool .` regenerated the new RenderingServer method's class reference.
  Repository hooks passed for all changed files.

These checks do not validate runtime material-cache residency or invalidation,
animated-instance capture, GI tracing, upscaler integration, or hardware cost.

### Geometry extraction

- Full Linux editor build passed with `platform=linuxbsd target=editor dev_build=no
  debug_symbols=no -j4`.
- The extracted geometry and shadow-scene translation units also compiled with
  `target=template_release`; this was not a full release export build.
- `shadow_validation/geometry.gd` parsed and ran under Mesa lavapipe 25.0.7,
  Vulkan 1.4.305 / LLVM 19.1.7. The log established ray-query support and a traceable
  shadow TLAS, with no engine errors.
- All 11 geometry captures at 641x359 matched a baseline built from the original
  `rt_scene.{h,cpp}` at `e4e8d844470786e631b4d61ec622a5e0a2732aa1`: zero changed
  RGB pixels in every corresponding image. The baseline still linked the unused
  extracted class; no baseline code constructed it. Controls verified that shadows,
  source replacement, and deformation changed the image.
- Repository hooks passed for the changed files. No bound properties were changed.

This validates the extraction's exercised rendering behavior. It does not validate
AMD GI, GPU allocation/timing equivalence, skeletal animation, DLSS/FSR behavior,
Windows builds, or performance on either target GPU.

Scene-history regression coverage now includes flickering geometry and camera-centered
collection changes. Stable instance/element matching supplies local dirty bounds for
additions/removals and material/topology edits, retaining unrelated history. The later consequential correction removes stable-ID remapping and follows reference light-index reuse and environment/zero-count settings reset boundaries. Dirty bounds are diagnostic, not a shader invalidation policy. See the sandbox evidence
in [HISTORY](HISTORY.md) and `amd_gi_scene_churn` / `amd_gi_flashlight` rigs.
