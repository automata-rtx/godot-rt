# HybridPiP implementation plan

Planning baseline: `91c24b8bd6ad8259e89c2a541c199316444982ed`, 2026-11-06.
Branch: `HybridPiP`, created from current `master`. Implementation subsequently
authorized by the owner, including repeated renderer validation. This document
preserves the design and acceptance gates; current source contracts live in
[the integration guide](../internals/hybrid-pip.md). It does not itself authorize
engine/game runs or changes to project assets.

Initial regional prototype checkpoint (historical): the initial regional renderer is implemented and has targeted
GPU validation, but its performance and transition gates are not closed. The
[validation report](../validation/hybrid_pip/RESULTS.md) records negligible 720p
matched-blur GPU savings, extra CPU/memory cost, deferred 1080p/native performance
controls, and regional upscalers that remain unimplemented. Further render runs
are currently prohibited by the owner. Do not read this plan as a completion claim.

## Resident renderer and sight placement checkpoint, November 8, 2026

The [runtime guide](../../GodotForkDocs/features/hybrid-pip.md) describes the
resident ADS path, independent regional DLSS reconstruction, lens-only composition
and automatic fallback to ordinary ADS. The sandbox uses a centered opening and
height-based calibration. The following placement and camera policies are proposals.

- For a reference source square of 360 pixels at 2560 × 1440, use final 3D
  output dimensions and compute `s = min(width / 2560, height / 1440)` with
  floating-point division. Round `360 * s` once. Center the fitted reference
  frame. A 1280 × 800 output has a 1280 × 720 reference with 40 extra rows at
  either end and a 180-pixel square. A 1280 × 1280 output keeps that same
  square. A 3440 × 1440 output keeps the 360-pixel square.
- Showing additional scenery in those extra rows would require a gameplay
  camera decision. Today's player camera holds vertical FOV constant. To
  preserve the reference composition, hold the reference vertical FOV on
  wider displays and its corresponding horizontal FOV on taller displays.
  The renderer can project a lens with either camera policy.
- A fixed reference square is easy to tune for a centered prototype. For
  production sights, author a non-rendered plane at the visible glass opening
  or ordered rim markers for an irregular aperture. Project the opening with
  the actual ADS camera into final output coordinates. Check coverage at the
  selected zoom and across the expected sway range.
- The source rectangle, reconstructed texture and visible aperture have
  different extents. The current API can translate a fixed-size crop each
  frame and retains previous crop mapping. Keeping the source fixed while
  moving the glass is another candidate within available coverage. The
  current compositor derives its optical axis from the aperture vertices.
  Independent image motion, glass clipping and eye-position shading would
  require an explicit design and moving-image validation.
- Prepare buffer dimensions on sight or output changes. Avoid resizing on
  sway. Validate lens coverage, edge history and ADS transitions on 16:9,
  ultrawide and square outputs before adopting a placement policy.

## Target and boundaries

One logical perspective camera, with a native-resolution region covering the
entire visible scope and its opening, and a background rendered at half resolution
on each axis. No extra optic magnification or supersampling in this first version.
The game supplies scope coverage and ADS intent; the renderer must not depend on
a particular weapon, scene, or camera distance.

Use two conventional rectangular render regions: a half-resolution full-view
background and a native-resolution crop with a filtering border. This deliberately
renders some overlapping pixels and repeats some raster geometry work. It avoids
building two independent scene/lighting systems. It is neither a second gameplay
camera nor a guarantee that all rendering work happens only once.

Keep the feature off by default. Feature disabled uses the established renderer.
Feature enabled with ADS inactive uses uniform rendering with the new persistent
state; that path also needs regression validation. Keep AMD's algorithms and
existing fork fixes. Limit changes to ownership, scheduling, coordinate mapping,
and resolution-dependent integration. Any necessary estimator change requires a
separate justification, not an incidental rewrite inside this feature.

Start with Vulkan Forward+, one perspective view, MSAA off, base scale 1.0.
Hardware VRS is not required or stacked on top for the initial regional tests.
XR, orthographic views, frame generation, arbitrary extra viewports, dynamic
resolution, and optic magnification are outside the first acceptance scope.
Detect unsupported combinations and retain uniform rendering with an explicit
status; never silently disable GI, shadows, or the user's selected AA.

## Architecture and nonnegotiable contracts

| Lifetime/owner | Resources and responsibilities |
| --- | --- |
| Shared scene preparation | Visibility preparation for the parent view; mesh/material updates; shared BLAS; existing distinct GI and shadow TLAS; scene/material pipeline preparation; light identities |
| Logical camera GI state | One persistent world radiance cache, keys, ownership/update storage, compatible light-resampling state, environment sampling resources, logical frame number and cache invalidation policy |
| Logical-frame work | Combined region requests/hit ranges, lighting preparation, source-buffer dependencies, world-cache update/maintenance and barriers |
| Regional screen state | Depth, normals, previous-surface data, color/lighting feedback, screen probe grids and their cached-probe bookkeeping, reflection buffers, GI/shadow denoising and AA histories |
| Final output | Common exposure, regional reconstruction/composition, accepted peripheral blur, tone/display processing and native-resolution UI |

The current `AMDGI::ViewData` mixes these lifetimes. A probe's world-space position
does not make its screen-indexed cache safe to share. Classify every buffer and
counter before moving ownership. Keep invalidation reasons separate: an ADS
layout change invalidates incompatible screen history, not automatically the world
cache or material pipelines. Genuine scene/configuration changes retain existing
invalidation rules.

At current default cache capacities, selected fixed allocations total about
953 MiB per GI state, before screen histories and other resources. This is an
allocation-size calculation, not a measured VRAM total or proof those capacities
are scanned every frame. Independent normal/background/crop world caches would
multiply that subtotal to about 2.8 GiB. Do not adopt that shortcut.

### Coordinate and resolution contract

Each region carries its full-output rectangle, valid interior, allocation extent,
sample density, current/previous crop transforms, jitter and history generation.
Distinguish parent-view UV, regional UV, allocation UV, and pixel units explicitly.
Use the parent's camera pose and perspective; cropping changes the projection's
window, not the camera origin or the scene's apparent scale.

- Preserve reverse-Z, unjittered motion conventions, deformed previous positions,
  and the primary-ray surface-plane correction that fixed black splotches.
- World-cache cell addressing uses a common parent-camera reference. Regional
  probe footprints use their actual sampling footprint. These currently share
  `frame.settings.y`; splitting their meanings is a deliberate adapter requiring
  single-region equivalence checks. Ordinary parent FOV changes can still change
  cache detail as they do today; crop dimensions must not masquerade as FOV changes.
- Screen-edge history weights use parent-view position; history validity checks
  use the actual region and available samples. Do not treat the scope crop boundary
  as the physical screen edge or accept missing history beyond its allocation.
- GI screen-lighting reuse resolves a parent-view location into the appropriate
  current/previous regional resource. Preserve depth, normal, exposure and age
  checks. Prefer a valid native sample where covered, otherwise the valid background
  sample. Do not discard all off-crop hits or feed blurred presentation color back
  into GI. Keep unblurred outgoing-lighting feedback.
- Preserve public screen-coordinate semantics for materials while adapting
  internal texture sampling. Audit screen/depth-reading shaders, particle effects,
  fog, clustered lights, AO and contact shadows explicitly; a crop projection alone
  does not fix their addressing.

### One logical frame

1. Prepare the scene, geometry and the two existing TLAS consumers once. Reuse
   appropriate render-list/material work. Use parent-view coverage and conservative
   detail requirements so the crop does not change LODs or omit valid ray casters.
2. Produce both regions' geometry/surface inputs. Prepare shared analytic light
   data once; trace and denoise RT shadow visibility at each region's density.
   Advance shadow sample phase once per logical frame, not once per region.
3. Begin one GI cache frame. Perform regional probe reprojection/selection and
   collect their ray/hit work with explicit region identity and nonoverlapping ID
   ranges. Preserve primary/secondary parent links, sample seeds and queue bounds.
4. Run AMD's ordered world-cache registration, lighting, multibounce and update
   stages over that combined work. Global resets, purge, light-grid preparation,
   cache mip generation and frame advancement each occur once at their existing
   dependency point. Never call the complete existing GI render twice against a
   shared cache or update a cache while another region reads an unfinished result.
5. Resolve regional probes, diffuse lighting, traced reflections and their filters
   from the completed cache. Render regional scene color/transparency with the
   corresponding lighting and feedback attachments.
6. Resolve supported AA per the contract below, reconstruct and compose the
   regional image using common exposure, then apply the peripheral depth blur.
   UI stays at output resolution. Feed display effects neither into GI history nor
   back through a second temporal filter.

Initially retain necessary overlap samples from both rectangular regions. AMD's
existing cache-cell ownership/all-hit accumulation must arbitrate combined work;
do not add arbitrary weights or a new ray scheduler to remove overlap. Verify
that overlap does not introduce a lighting seam or bias beyond normal sampling
variation. Overlap-removal optimization is deferred until correctness and timings
show it is worthwhile. If shared scheduling cannot preserve the sampling contract,
reassess before proceeding rather than reverting to multiple large world caches.

## Region boundaries, image quality and compatibility

Use a bounded, preallocated crop capacity and a stable, aligned valid rectangle.
Allow scope sway and small layout changes without allocating new textures every
frame. Protect the whole scope mesh as well as the lens; the static fixture's
`depth < 1 m` shortcut is not a production mask. Keep aperture shape separate from
the rectangular native-render region so only the lens stays unblurred.

Derive the filtering border from the complete chain of active spatial kernels,
probe neighborhoods and jitter. Motion can invalidate history even inside a
wide border; validate/reject history independently. Test the crop seam with blur
disabled first, then use depth/normal-aware reconstruction and composition. Do
not smear background lighting across the scope silhouette to disguise a seam.

For the existing 368 x 448 native rectangle at 1280 x 720, the full half-resolution
background plus crop covers about 42.9% of native pixels before guards. Adding
32 pixels to every crop side makes it 49%; 64 pixels makes it 56%. These are
illustrative pixel counts, not selected guard sizes or GPU-time predictions.
Compute the actual border and budget rather than borrowing the VRS mask's two-pixel
jitter allowance.

Begin correctness work with AA disabled. Add regional TAA with explicit history
validity, then validate the existing FSR2 and DLSS paths using independently
owned regional contexts, matched jitter/motion/depth units and common exposure.
Do not send a mixed-density stitched image to an unmodified upscaler and assume
its uniform-input contract still holds. With temporal upscaling, the peripheral
context has half-resolution input and full-view output; the native crop uses
native input/output. Accordingly, peripheral DLSS is upscaling while the crop can
use DLAA. Include the full output-resolution reconstruction cost in measurements.
Validate non-temporal FXAA/SMAA placement against the composed output as well.

The compatibility checklist must cover transparency, muzzle flashes/particles,
screen/depth-reading materials used by the project, fog, sky/exposure, VBAO,
screen-space shadows, native material feedback and CompositorEffect callbacks.
Define whether each callback receives regional or resolved full-view resources;
do not accidentally invoke a game callback twice with changed semantics. Any
required full-resolution compatibility pass is a reported cost, not hidden work
claimed to be quarter resolution. Unsupported active effects trigger a documented
uniform-render fallback until integrated and validated.

## ADS preparation and transitions

Expose a small runtime contract: prepare/query readiness, set active, update scope
coverage/aperture, and report effective mode/fallback reason. Keep capacity and
diagnostic controls in advanced options. Avoid making game scripts manage GI
buffers, internal temporal states or individual rendering passes.

Prepare required regional resources, shader pipelines and selected upscaler
contexts during level/weapon preparation. Allocate for the configured maximum;
grow or change unsupported configurations during an explicit preparation interval.
If ADS is requested before readiness, retain uniform rendering until ready. A
readiness result must include feature-specific resources, not only AMD material
preparation. Validate actual driver first-use behavior rather than assuming shader
bytecode availability eliminates every compilation stall.

Preflight resources and compatible pipelines before mutating shared frame state.
If preparation fails, choose the uniform route before starting the cache frame.
For a failure after commands have begun, use the existing safe-abort/invalidation
rules and recover on a subsequent frame; do not rerun the whole cache update as a
second fallback pass in the same frame. Pending GPU users must retain ownership.

Use an explicit lifecycle: unprepared, preparing, ready-uniform, ready-regional,
and failed-with-uniform-fallback. Activation changes scheduled work, not cache
ownership. Do not render inactive modes continuously just to keep histories warm.
Track last-produced frame, mapping, projection and resource generation for each
screen history. Reproject compatible custom histories; invalidate incompatible
ones. Never resume stale AA/shadow/reflection history solely because memory exists.
Keep resources alive until queued GPU users finish; avoid blocking device-wide
waits on an ADS toggle.

Current FSR2/DLSS calls hard-code `reset_accumulation = false`; explicit reset
plumbing is required. FSR2 documents additional work on reset. Therefore zero
transition spikes remains an acceptance goal, not a source-level guarantee.
Test mode switches at fixed FOV first, then the actual animated ADS FOV separately
so ordinary zoom behavior is not misdiagnosed as a regional-layout defect.
If cold screen history causes visible convergence or a measured switch hitch,
resolve that before claiming smooth ADS; extra cache resets or perpetual background
renders are not acceptable substitutes.

## Implementation sequence and gates

Each step is a reviewable checkpoint on `HybridPiP`. These are internal milestones,
not permission to deliver an unfinished feature as completed.

| Step | Work | Gate before proceeding |
| --- | --- | --- |
| 1 | Record source/binary control, add targeted counters/timestamps, specify buffer ownership, region transforms and frame schedule | Baseline reproducible; no render run until authorized; counters separate allocation, cache work, pixel work and CPU scene submission |
| 2 | Separate persistent GI/cache state from screen state; extract frame stages; retain ordinary one-region rendering | Seeded/native control agrees within justified numerical/sampling tolerance; existing material/emitter, reflection, shadow, lifetime and failure-recovery checks pass; no material CPU/GPU regression |
| 3 | Add two rectangular regions, shared scene preparation, coordinated GI batch and regional RT shadows; AA/blur off | Actual attachments/dispatch sizes prove reduced peripheral work; native scope quality, IDs, barriers, feedback routing and seams correct; no duplicated AS preparation or world-cache maintenance |
| 4 | Complete regional filtering/composition, current-depth blur, runtime preparation/state transitions and compatibility adapters | Moving scope/objects, disocclusion, first ADS and repeated toggles work; no hot-path allocation/compilation; selected AA and effects work or explicitly fall back |
| 5 | Validate temporal AA modes and production settings; benchmark total cost and transitions; finish docs/API/exports | Image quality and memory accepted, meaningful total savings demonstrated, normal-play regression checked, clean exit/failure paths; exact tested build delivered |

Test transition behavior as soon as step 3 can switch layouts; do not postpone
discovery of an architectural problem until final polishing. If step 2 cannot
cleanly preserve existing GI behavior, stop there and report the obstacle. Do not
build the regional renderer on an unverified cache refactor.

Acceptance includes odd dimensions, crop movement/clipping, camera cuts,
window/resolution changes, scene unload/reload, material/light mutation, emitter
zero crossings, MultiMesh/deformation, preparation failure, and shutdown. Check
feature-off and enabled-but-unscoped separately. Use meaningful coordinate/queue
tests, offline shader/build checks and the real GPU renderer; none substitutes
for the others. Preserve shared RT cleanup and current-frame geometry ordering.

Benchmark matched uniform and regional configurations with the same blur/AA,
plus a plain native reference. Use balanced warmed runs and separate transition
captures; report GPU total and stage times, CPU render span, memory, steady-state
percentiles and the first/early frames of repeated ADS transitions. No screenshot
readbacks or diagnostic synchronization inside timing windows. Coordinate with
other active work within the owner's messaging authorization. Do not infer
lower-end hardware scaling from RTX 5090 alone.

## Reproduction baseline and delivery

- Systems Sandbox B3: camera `(8.5, 1.65, 6.5)` toward `(-8.5, 0.95, -6.5)`,
  vertical FOV 35 degrees, scope rear 12 cm from camera, 1280 x 720.
- Apocalypse `SM_Wep_Mod_Attach_Scope_06.tscn`; fixture opens its decorative lens
  in memory. Original assets remain untouched. No initial optic magnification.
- Accepted blur: radius 2 to 10.72 output pixels at 720p, smoothly increasing
  over camera depth 0.12 to 25 m; aperture clear. Establish output-size scaling
  explicitly. Replace the static depth capture with current-frame GPU depth.
- Grass and frame generation off. AA initially off, base scale 1.0. No final AA
  preference was selected by the owner; keep algorithm comparisons separate.
- Existing fixture/evidence: local `.artifacts/scope-study/`, especially
  `vrs/RESULTS.md`, `depth-blur-capped/`, `vrs-aa/` and `vrs-temporal-aa/`.
  These ignored artifacts do not ship with a clone. Package a reproducible minimal
  harness and settings with implementation evidence without copying game assets.
- Prior VRS test saved only about 0.047 ms versus whole-image supersampling;
  GI remained roughly 2.64 ms. It supports targeting GI pixel work, not a promise
  about the new design's savings. Shared/cache/geometry costs will remain.
- After successful local builds, follow the desktop-shortcut delivery rule in
  [project scope](../PROJECT_SCOPE.md); keep the Actions folder separate. Before publishing code,
  run repository hooks and applicable Windows development/matrix checks. Update
  user-facing and per-feature technical notes to actual validated behavior.

Confidence is high in avoiding duplicated scene/cache ownership and in the need
for explicit regional coordinates/history. Confidence is moderate in delivering
the combined renderer with useful savings and unobtrusive ADS transitions. The
shared-cache batch, boundaries and first-frame history are the decisive gates.
This remains a substantial renderer feature; the branch and staged verification
contain its risk but do not make it a small or proven change.

## Source anchors and external contracts

- `servers/rendering/renderer_rd/environment/amd_gi.h/.cpp`: `ViewData`, allocation
  formulas, pass ordering, frame advance, feedback and invalidation.
- `servers/rendering/renderer_rd/shaders/effects/amd_gi.glsl`: `footprint`,
  `cache_cell_size`, `screen_lighting`, owner/primary/secondary hit indexing.
- `amd_gi_denoiser_inc.glsl` and reflection filtering includes: history vignette,
  kernel dependencies and regional border requirements.
- `renderer_scene_render_rd.cpp`, `effects/rt_shadows.cpp`, and
  `forward_clustered/render_forward_clustered.cpp`: shared scene preparation,
  per-call shadow phase, framebuffer flow, callbacks and AA reset integration.
- Read [shared RT](../internals/shared-raytracing.md),
  [AMD GI](../internals/amd-gi.md), [RT shadows](../internals/rt-shadows.md) and
  [AMD adapter decisions](../AMD_GI_ADAPTER_DECISIONS.md) when implementing their
  boundaries; preserve pinned AMD baseline `914b91596cd119eda85fbc1d3c7ee6ac391b1452`.
- [AMD FSR2 integration](https://gpuopen.com/manuals/fidelityfx_sdk/techniques/super-resolution-temporal/)
  specifies input/motion/jitter and reset behavior, including reset overhead.
- [NVIDIA Streamline DLSS integration](https://github.com/NVIDIA-RTX/Streamline/blob/main/docs/ProgrammingGuideDLSS.md)
  documents distinct viewport identities and explicit resource allocation.
  Check the locally bundled SDK version before implementing; current online docs
  do not establish support in the installed version or correct regional inputs.
