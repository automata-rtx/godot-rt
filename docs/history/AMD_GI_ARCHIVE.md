# AMD GI historical archive

Archived on 2026-10-24 from `837fb30`. These are dated snapshots, not current instructions or completion claims.
Read [the current handoff](../AMD_GI_IMPLEMENTATION.md) first. **Do not load this whole archive into model context.** Search for a filename, finding ID or heading and read only that section. Older contradictions and failed tests are deliberately preserved. Cloud `/workspace/gi-validation/` outputs mentioned below are not committed artifacts and may not exist on another PC.

## Snapshot index

- [docs/AMD_GI_ADAPTER_DECISIONS.md](#snapshot-amd-gi-adapter-decisions)
- [docs/AMD_GI_COMPARISON_COVERAGE.md](#snapshot-amd-gi-comparison-coverage)
- [docs/AMD_GI_CONSEQUENTIAL_CORRECTIONS.md](#snapshot-amd-gi-consequential-corrections)
- [docs/AMD_GI_FULL_COMPARISON.md](#snapshot-amd-gi-full-comparison)
- [docs/AMD_GI_GAMEPLAY_AUDIT.md](#snapshot-amd-gi-gameplay-audit)
- [docs/AMD_GI_IMPLEMENTATION.md](#snapshot-amd-gi-implementation)
- [docs/AMD_GI_NORMAL_SPACE_INVESTIGATION.md](#snapshot-amd-gi-normal-space-investigation)
- [docs/AMD_GI_REFERENCE_AUDIT.md](#snapshot-amd-gi-reference-audit)
- [docs/features/amd-gi.md](#snapshot-amd-gi)
- [docs/internals/rt-materials.md](#snapshot-rt-materials)
- [docs/features/rtgi-validation.md](#snapshot-rtgi-validation)
- [docs/HISTORY.md](#snapshot-gi-history)
- [docs/TROUBLESHOOTING.md](#snapshot-gi-troubleshooting)

<a id="snapshot-amd-gi-adapter-decisions"></a>

## Snapshot: docs/AMD_GI_ADAPTER_DECISIONS.md

# AMD GI adapter decisions and approval scope

The owner explicitly requires approval for departures from AMD. On October 23, 2026, the owner approved the authored-light/material boundary and conditionally approved correcting the normal transforms if the pinned AMD implementation is incorrect. The completed normal-space investigation establishes that condition. The individual sections below record the approved exceptions, the bounded affine mapping extension and the withdrawn snapshot proposal. Qualified corrections are implemented; neither these approvals nor passing helper tests establish full native-input support, optional AMD feature parity or production readiness.

## Approved: preserve authored Godot lighting at the input/output boundary

Approved boundary: retain Godot's light energy, range/decay, spot attenuation, masks and shadow opacity when evaluating a light, and retain Forward+'s authored material BRDF/DFG/AO at final composition. Use those same light values in both the GridStream proposal and selected-light target. All GI transport, probe/cache/reservoir and denoiser algorithms remain AMD's. Source textures and actual hit attributes must replace the coarse material atlas; that compromise is **not** included in this proposal.

Why: otherwise direct lighting and its bounce would describe different lights. AMD's glTF spot model has inner/outer cone angles; Godot's authored spot uses a different attenuation control. There is no exact parameter conversion for all authored values. The same issue applies to non-default native light decay, masks and material extensions. Replacing the native primary lighting as well would change existing game lighting outside the GI implementation.

Concrete difference: for unit intensity, range 8, distance 4, and native decay 2, the Godot radial factor is `(1-(4/8)^4)^2 / 4^2 = 0.05493164`; Capsaicin's point-light factor is `(1-(4/8)^4)/(0.0001+4^2) = 0.05859338`. This is an intentional authored-light contract difference, not a claim of pixel equivalence. The benefit is agreement between direct and indirect authored lighting, not a claimed speedup.

Approval covers only this boundary. It does not approve finite default tracing range, coarse materials, omitted geometry, changed history policy, extra radiance clamps or an alternative GI estimator.

Source-domain proof scripts are preserved in [validation/amd_gi_source_proofs](../validation/amd_gi_source_proofs/README.md). Their outputs in the correction evidence directory are CPU proofs, not upstream GPU runs.

## Undefined reference operations need a separately bounded Vulkan policy

The audit already flagged writable-neighborhood/out-of-bounds reflection cleanup and the multibounce visibility-index handoff. Do not infer that every apparent difference is an upstream bug or that arbitrary clamps are permitted. The decisions below record the separately qualified bounds behavior, approved corrections, and withdrawn snapshot proposal.

Additional source issue identified while correcting coverage: Capsaicin defines `MAX_HIT_DISTANCE=1e9` and can put this (or a miss sentinel) into `packHalf4` screen-probe radiance, then converts the decoded distance through `uint4(round(10000*radiance))`. The finite ray extent and the probe's stored-distance representation must be treated separately. Copying an overflowing half/integer conversion into Vulkan is not evidence of equivalent results. This requires a reference execution/defined-domain decision, not simply raising the fork's 50-unit scene bound.

## Correction to the original L05 finding

The audit's assertion that AMD universally invalidates reservoir hash history on light-index changes was too broad. At the pinned commit:

- `LightBuilder::run` sets `lightIndexesChanged` for count/index changes.
- GridStream uses that to update its configuration.
- `LightBuilder::getLightSettingsUpdated` returns a separate `lightSettingsChanged` flag: environment-count changes, crossing zero/nonzero area/delta-light counts, and environment sampling mode changes.
- GI1 reinitializes through `light_sampler->needsRecompile`; its `ClearReservoirs` shader clears the **current** hash, not universally the previous hash whenever indices change.

Correction now implemented: persistent identity remapping was removed. The fork uses reference light indices and reinitializes GI on environment-count or zero/nonzero area/delta-light changes. Ordinary count changes within a nonzero class do not globally reset GI. An old reservoir index beyond the current light count is still rejected explicitly for Vulkan safety; that exceptional-domain handling is not claimed as a reference equation match. The sole-emitter fixture verifies nine settings resets across four off/on cycles and final removal; no configuration or invalid-frame reset is accepted. It passes its existing energy and phase-response thresholds. This does not prove arbitrary dynamic light-list equivalence.

## Approved: multibounce bypass index-domain correction

The pinned `gi1.comp` writer appends valid shadow rays with
`VisibilityRayBuffer[ray_index] = did`, then stores the bypass flag in bit 31.
`ray_index` comes from `InterlockedAdd(VisibilityRayCountBuffer[0], 1, ray_index)`.
`UpdateMultibounceCells`, however, reads that flag at `did2 = did + VisibilityCountBuffer0[0]`,
which is a **visibility-hit index**, not an index into that compact shadow-ray queue.
There is no identity-order guarantee, even when every hit selects a valid light.

Concrete permitted execution: primary hits 0, 1, 2 and secondary hit 3 exist;
only primary 0 and secondary 3 append shadow rays. The queue begins
`[0, 0x80000003]`. Secondary hit 3 requires bypass, but the updater reads entry
3, outside the populated queue, rather than entry 1. A zero old value loses
the bypass; a stale value can select another hit's flag. Independently, an
exhaustive enumeration of four valid hits, all append permutations and all
flag assignments produces 288 incorrect results in 768 secondary reads.
The source-checked reproducer and output are
`/workspace/gi-validation/amd-consequential-corrections/check_bypass_indices.py`
and `bypass-indices.json`. This is an index-equation proof, not a claim that
Capsaicin itself was rendered on this machine.

**Approved narrow correction:** associate the bypass flag with its visibility
hit, preserve AMD's `distance(reconstructed_origin, reconstructed_hit) < cell_size`
predicate, and consume that hit's flag when accumulating its continuation.
Do not alter the continuation probability, cache filter, BRDF/PDF or radiance
weight. This restores the source's documented thin-wall leak protection and
removes dependence on unrelated append order. The owner explicitly approved
this separate correction: “Yes, you may make that correction.” The flag is
set only for a valid selected shadow ray, as in the source writer, and cleared
for each new secondary hit; an invalid reservoir cannot inherit a stale flag.

## Exceptional-domain decisions

- **Firefly scratch:** withdrawn. Cleanup uses AMD's in-place updates; zero-valued border loads and depth-reconstructed sky neighbors now match the reference. No invalid-input lighting fix is claimed.
- **Planar/point light-grid bounds:** approved. Preserve true zero extent and select the sole cell on that axis. Five GPU cases cover point, line, plane, tiny positive extent and ordinary volume.
- **Near-field infinite sky:** the unapproved finite endpoint substitute was removed. The port now follows the reference homogeneous divide. Infinite-projection exceptional behavior remains a source limitation; finite native projections are tested.

## Approved condition met: correct localized hit-normal transform errors

The owner's requested follow-up is recorded in [the normal-space investigation](#snapshot-amd-gi-normal-space-investigation). Tracing static/animated uploads, both fetch helpers, GI program bindings, raster/ray-traced screen buffers and world-space light/BRDF consumers rules out the screen-space/world-space split as an explanation. The pinned source contains localized missing/repeated instance normal transforms.

A reproducer extracts the actual three reconstruction blocks and evaluates equivalent baked/instanced triangles. With a 90-degree rotated instance facing the light, the consistent primary path gives normal-dot-light 1, while multibounce reservoir generation and cache shading give 0; all give 1 with the identical rotation baked into the mesh. This is a CPU algebra proof, not a rendered upstream comparison.

The proposal is now narrowly specified: transform secondary-hit vertex normals into world space as AMD's adjacent paths do; compute cache geometric normals from local edges and transform once; transform/normalize cache shading normals before world-space light evaluation. Preserve the geometry/vertex/normal-mapped distinctions at their respective call sites and qualify mirrored-instance orientation separately. The owner subsequently answered: “If AMD's is correct, do that. If it's not, do the other.” The evidence establishes the latter condition, authorizing these specific transform corrections. The correction now uses source vertex normals and separate geometric normals; the GPU decoder, integration and deformation regressions pass. Subsequent corrections replace the coarse atlas with source material evaluation and preserve half barycentrics in cached visibility. Those are separate corrections, not permissions inferred from the normal-transform approval.

## Approved: classify native emissive shader programs before texture evaluation

AMD's `GenerateReservoirs` and glossy closest-hit branch test the source material's base emissivity before evaluating its emission texture. A positive base factor with a black texel still terminates the path; the emitted contribution is zero. The current fork instead tests final sampled emission, so black texels and procedural off phases change the transport path. Exact texture access alone does not correct this distinction.

Godot's spatial shader API exposes a program writing `EMISSION`; it does not expose glTF's separate base-emissivity factor. Even StandardMaterial3D supports adding its emission color to its emission texture, whereas glTF multiplies them. Arbitrary ShaderMaterial programs can depend on uniforms, time, world position and branches. Inferring a base factor from uniform names or one sampled output would be unreliable.

Proposed native input encoding: a shader that writes `EMISSION` represents an emissive material with unit base factor and an authored emission function supplying the actual RGB. A shader that never writes `EMISSION` has zero base factor. Apply AMD's front-face/base-emissivity termination rule to that classification, and evaluate the complete native program for the emitted RGB. The unit factor is a representation, **not** an added light intensity; proposal/target evaluation must use the authored emitted RGB, with reference texture/cone filtering where applicable. This proposal does not approve different sampling weights, point-only emitter proposals, coarse captures or missing texture LOD.

For example, a shader returning `2 * texture(uv).rgb` is represented by base `1` and emission function `2 * texture(uv).rgb`. The emitted radiance is identical at every UV, while a black texel now terminates just as AMD's emissive material does. A procedural shader's dark phase likewise stays an emissive material. This removes an unsupported dependency of cache transport on which texel or phase was sampled.

The tradeoff is explicit: a shader that writes `EMISSION` but currently returns zero everywhere is still classified as emissive. Its hit contributes zero emitted light and does not become a diffuse cache-shading surface. Removing the emission feature/program write makes it nonemissive. This is the same distinction as a unit-base glTF emissive material with a black texture, but it is not equivalent to encoding that same black appearance using a zero glTF base factor. That input-encoding choice requires owner approval; the earlier approval for native final material response did not settle it.

Status: the owner explicitly approved this native emissive classification. Primary cache shading/feedback, probe injection and glossy closest-hit termination now use a separate front-face/base-emissivity flag. Source RGB remains evaluated normally, including black texels and dark procedural phases. Secondary cache shading retains the reference behavior. This does not approve other emitter-footprint or alpha-contract changes.

## Withdrawn: deterministic firefly input snapshot

Finite-domain correction is now being implemented for cleanup borders and sky neighbors: reproduce D3D's zero-valued out-of-range loads and reconstruct neighbor positions from depth, including sky. The former port skipped out-of-range taps and substituted zero world positions for sky. Those are reference differences, not justified bounds handling. The odd-resolution mark pass also now checks the actual full-resolution sample coordinate.

For the remaining in-place issue, `CleanupFireflies` changes only marked pixels, and marked neighbors have zero weight. Therefore an immutable input snapshot gives identical contributions for finite inputs regardless of execution order. The source-checked proof in `exception-proofs/firefly_snapshot.py` verifies 10,000 finite permutations. Its deliberately simple unit plane/filter weights are sufficient to exhibit the exceptional case; it is a CPU arithmetic proof, not a Capsaicin GPU render.

A marked NaN neighbor changes the conclusion: `NaN * 0` is NaN until another invocation cleans that neighbor. For inputs `[NaN, 10, 1]` with marks `[1, 1, 0]`, legal cleanup orders produce `[0, 1, 1]` and `[0, 0, 1]`. An immutable input produces `[0, 0, 1]`, followed by AMD's same final sanitization. Proposal: retain that deterministic snapshot behavior, rather than allow shader scheduling to choose between different outputs. No finite radiance clamp or filter-weight change is included. The border/sky corrections are separate from this exceptional-value decision.

The owner challenged the practical benefit. The proposal established repeatability
for exceptional inputs, not a demonstrated visual improvement or worthwhile
performance tradeoff. It did not meet the owner's approval standard and was
withdrawn. Cleanup now restores the reference in-place update of marked samples,
with half-precision output and unchanged weights/sanitization. Border and sky-load
corrections remain. Invalid-input scheduling behavior is a retained source
limitation, not a claimed fix or an approved departure.

## Approved: zero-width light-grid axes

Pinned `CalculateBounds` computes `cellScale = largestAxis / 16`, `numCells = max(ceil(sceneExtent / cellScale), 1)` and `cellSize = sceneExtent / numCells`. On a planar bound, the collapsed axis has one cell of width zero; querying it then divides by zero before clamping the cell coordinate. An all-coincident bound additionally divides zero by zero while calculating the dimensions.

Proposal: retain zero extents, use coordinate zero on a one-cell axis, and use one cell on each axis for an all-coincident bound. Continue consuming the reference position-jitter random draws, including collapsed axes. Every positive-extent calculation remains unchanged. Planar proposal volumes retain exactly zero thickness rather than the current arbitrary `1e-5` expansion. The wholly coincident case has no unique reference execution or unique sampling-grid limit; one point cell is an explicitly chosen deterministic policy, not a claimed upstream numeric match. It evaluates light importance at the actual point without inventing a spatial extent.

The owner explicitly deferred to selecting the single grid cell along a flat direction. The implementation now preserves zero extents and selects that cell without division; all-coincident bounds select the sole cell in each direction. Reference jitter draws are still consumed.

## Approved: represent far distances without half/integer overflow

The source-checked `exception-proofs/distance_domain.py` confirms two distinct limits. AMD's `MAX_HIT_DISTANCE=1e9` (and its still larger miss sentinel) becomes infinity in `ScreenProbes_PackRadiance`. Separately, even the largest finite binary16 distance, 65504, overflows the 32-bit fixed-point distance sum after seven samples share a bin. Float-to-integer conversion of infinity is not a portable Vulkan contract. Microsoft's documented SM4 `ftou` clamps out-of-range inputs, but the DXIL specification uses LLVM conversion instructions; the SM4 documentation alone does not establish the pinned SM6 renderer's behavior. These reference documents are saved in the evidence directory. No upstream GPU execution is claimed.

Proposal: restore the reference **1e9 ray extent and scene coverage**, retaining actual hit positions/distances for traversal and world-cache placement. Only the screen-probe reprojection-distance channel is capped at binary16's maximum finite value, 65504. Use a two-word integer sum for that channel to prevent accumulation wrap; RGB, sample counts, sampling weights and cache estimators are unchanged. Finite distances up to 65504 retain the reference half representation and integer quantization. This is an explicit correction, not numeric equivalence in overflow cases.

For a sky/far endpoint represented at 65504, lateral camera displacement of 1 unit introduces at most about 0.000875 degrees of parallax; 10 units gives 0.00875 degrees and 100 gives 0.0875 degrees. Real finite distances above that bound are likewise approximated only during screen-probe reprojection. This replaces an infinite/undefined projection input with a bounded error while preserving the requested long-range triangle tracing. The distance accumulator adds 256 bytes of shared memory per 64-bin group and an extra word/carry operation for each distance addition; target-hardware performance is unmeasured. There is no radiance clamp in this proposal.

Status: the owner deferred to the recommendation, approving this scope. Implementation restores a 1e9 default ray extent, collects the participating scene without the old camera-centered cutoff, and limits only the screen-probe distance representation. Twenty GPU distance cases verify the stored-distance limit, exact accumulator carries and unchanged RGB.

## Approved: secondary bypass query ownership and raw injection

This is separate from the already approved shadow-queue flag indexing. Source tracing reveals that `VisibilityQueryBuffer` has two domains: primary entries point to screen-probe ray queries; secondary entries point to **primary visibility entries**. `PopulateCells` and `UpdateMultibounceCells` nevertheless both pass a secondary entry's query value directly to `ScreenProbes_AccumulateRadiance`, which indexes the screen-probe ray array.

The source-checked `exception-proofs/secondary_query.py` gives a concrete primary mapping `[7, 3, 11]`. A secondary hit whose parent is primary visibility 1 belongs to probe ray 3, while both source writers address probe ray 1. Fixing the shadow-queue flag lookup does not correct this additional ownership mismatch.

There is also a weight-domain issue: `PopulateCells` injects the secondary hit's raw direct lighting on bypass before the parent's BRDF/PDF/continuation weight is applied. `UpdateMultibounceCells` later performs that weighting and injects again. A perfectly black parent has zero continuation contribution, yet the first write can inject positive secondary lighting into a probe. This follows the equations irrespective of GPU append order. It is a source/index/BRDF proof, not a rendered Capsaicin comparison.

Proposed scope: keep direct raw bypass injection for primary hits only; secondary bypass injection uses the already weighted `UpdateMultibounceCells` result and the parent's **screen-probe query**. Preserve the reference filtered-cache resolve and delayed multibounce cache update; do not redesign their blend or sampling weights. This is already how the fork's explicit primary/secondary records route the contribution, but it is an additional justified source correction requiring approval to retain. The earlier approval was explicitly limited to the flag's shadow-queue index and is not expanded retroactively.

The owner subsequently deferred to the recommendation for the secondary ownership/raw-injection correction. This authorizes retaining the correct parent query and weighted injection described above, independently of the earlier shadow-queue flag approval.

## Approved: reject a historical light index outside the current list

`exception-proofs/stale_light_index.py` checks the source accessor and demonstrates
an ordinary two-to-one point-light transition. Both old and new delta-light classes
remain nonempty, so the reference settings transition does not reset GI. An old
reservoir selecting index 1 is outside the new logical light list of length 1.
The source `getLight` directly reads `g_LightBuffer[index]`; it has no logical range
check. Retained allocation capacity may make the read physically addressable, but
does not make it a current light. This is a source-domain proof, not an upstream
GPU execution or a claim that every such read is physically out of bounds.

Proposal: retain the explicit rejection before any light evaluation. Preserve
reference index reuse for every index still in range, including reordered lists;
do not reintroduce persistent identity remapping or reset all GI history. This
prevents a deleted source from supplying stale lighting and prevents invalid
addresses if its allocation actually shrinks. Rejection consumes no merge RNG
for this unavailable sample, as with the neighboring invalid-sample guards.
The owner explicitly approved discarding these invalid samples. The existing guard is retained within this narrow scope; no global history reset or identity remapping is added.

## Retained reference limitation: RGB float-to-uint conversion

Cache RGB quantization still uses the reference rounded float-to-uint conversion
and 32-bit wrapping sums. This is defined for finite nonnegative rounded values
below 2^32; negative, NaN, infinity and larger values are not a portable Vulkan
conversion contract. Removing the old 60000 radiance clamp did not settle those
cases. The documented SM4 conversion behavior cannot prove the pinned SM6 output.
No new clamp or conversion policy has been installed. Distance overflow has a
separately approved correction above; it does not authorize changing RGB conversion.


## Approved: affine emitter texture coordinates outside AMD's single-UV input model

AMD's `gather_area_lights.comp` stores one `vertex.getUV()` per corner, rounded
through `packUVs`. `evaluateAreaLightConeAM` uses that same mapping for the texture
sample and its triangle-area LOD. The native source path now matches that contract
for post-vertex UV0, including half UV precision and vertex-stage mip-zero reads.
The earlier adapter did not correctly filter an implicit emission texture read using a different
mapping, such as UV2 or a fragment-stage coordinate transformation. Evaluating
its RGB source program correctly does not establish the correct filtering footprint.

A source-checked example is in `emitter-coordinate-boundary.json` in the correction
evidence directory. A mapping four times wider than UV0 needs two additional mip
levels. For a 1024-square texture and shared cone offset -6, the current footprint selects mip 4 instead of mip 6; both are inside the available 0–10 range. It therefore selects four times finer linear detail.
This can increase noise or select the wrong averaged emission. This was a consequential adapter finding, not an optional visual improvement. The textual game-source
inventory found ordinary UV0 emission textures and constant emission, but that does
not establish the contents of imported binary assets or justify leaving the gap.

Original proposed direction: supply AMD's existing triangle/cone formula
with each emission texture's own mapped triangle coordinates. Preserve the fast
single-UV path. For a native shader that computes another mapping, evaluate that
mapping at the triangle corners; affine mappings reproduce the reference formula
on an equivalent remapped mesh. This requires additional material-program work
for those shaders and further restrictions/qualification for nonlinear coordinates,
branches, loops, or texture-dependent coordinates. No cost or general nonlinear
accuracy claim is made. This is a material-input extension absent from AMD's fixed
material model; it must not be installed as an unexplained algorithm change.


The owner approved the recommendation on October 24, 2026: “Continue with your
recommendation.” The approved scope is the clearly understood mapping cases;
arbitrary warped or texture-driven coordinates were explicitly not presented as
solved. No new estimator or more GI rays are authorized by this decision.

Implementation now uses an opt-in shader-compiler analysis to reconstruct affine
texture coordinates at triangle corners. It recognizes UV0/UV2, interpolated or
flat vertex varyings, local aliases/reassignment, component swizzles, addition,
translation, multiplication by triangle-constant scalar/vector/matrix values,
and division by triangle-constant values. Uniform-built rotation matrices are
supported. Material/global/instance uniforms remain native inputs. A qualified
read feeds AMD's unchanged triangle/cone LOD formula using half-precision mapped
corners; the texture sample itself retains the authored coordinate expression.
Ordinary UV0 and its direct aliases retain the existing footprint helper. Explicit
textureLod/textureGrad operations remain authored. No extra material-program
invocations, passes, ray queries, GPU buffers or CPU geometry readbacks are added.

Analysis is conservative: nonlinear coordinates, partial/array mutations, loop-
or spatial-branch-dependent mappings, aliases merged after conditional writes,
custom helper calls and non-2D implicit textures are not certified. Such emitter
programs warn once when compiled and retain their existing fallback. This is a
remaining native-material limitation, not a fix for those cases. Additional
arithmetic occurs for corrected mapped reads; target-hardware cost is unmeasured.

The GPU known-mip/coordinate oracle passes 704 samples across eleven mappings,
uncompressed/compressed inputs and changed uniforms (maximum component error
0.00008534). The existing 256-sample native material oracle passes (0.00000142).
The emitter-room regression passes at the quarter primary budget with denoising.
Evidence: `/workspace/gi-validation/amd-emitter-coordinates/`. These are Vulkan
correctness tests, not hardware performance or a proof that the reported game
hazard/firefly symptoms were caused by this mapping issue.


<a id="snapshot-amd-gi-comparison-coverage"></a>

## Snapshot: docs/AMD_GI_COMPARISON_COVERAGE.md

# AMD GI comparison coverage appendix

This appendix freezes the **pre-correction audit**. Current dispositions and validation are in [the live consequential record](#snapshot-amd-gi-consequential-corrections); statements such as “absent” below describe that audited revision.

Companion to [the completed source comparison](#snapshot-amd-gi-full-comparison). These are source dispositions, not equivalence certificates. Baselines: AMD `914b91596cd119eda85fbc1d3c7ee6ac391b1452`; fork `d932f4ac0260c49ebd1dbbc61db9b8580726dcf0` plus the preexisting local follow-up. All finding IDs refer to that report.

## Main AMD GI functions

All 70 definitions in `src/core/src/render_techniques/gi1/gi1.comp` are accounted for, including wrappers, optional modes and diagnostics. Inline ray queries map to Vulkan queries; the alternate DXR dispatch wrappers are explicitly outside the requested API scope.

| AMD function / line | Fork counterpart or explicit absence | Comparison |
| --- | --- | --- |
| `ClearCounters` :164 | AMDGI host dispatch, reset/queue initialization; debug draws/SBT dispatch absent | Host scheduling / H01-H04 |
| `GenerateDraw` :188 | AMDGI host dispatch, reset/queue initialization; debug draws/SBT dispatch absent | Host scheduling / H01-H04 |
| `GenerateDispatch` :209 | AMDGI host dispatch, reset/queue initialization; debug draws/SBT dispatch absent | Host scheduling / H01-H04 |
| `GenerateDispatchRays` :220 | AMDGI host dispatch, reset/queue initialization; debug draws/SBT dispatch absent | Host scheduling / H01-H04 |
| `ClearProbeMask` :243 | reset_cache / filter_mask / closest_probe | Probe placement and history / P01,P04,P07,P08 |
| `FilterProbeMask` :249 | reset_cache / filter_mask / closest_probe | Probe placement and history / P01,P04,P07,P08 |
| `InitCachedTileLRU` :287 | reset_cache | Probe placement and history / P01,P04,P07,P08 |
| `ReprojectScreenProbes` :293 | reproject_probe / previous_probe | Probe placement and history / P01,P04,P07,P08 |
| `CountScreenProbes` :502 | bin_cached_probe / find_cached_probe; different bin/list representation | Probe placement and history / P01,P04,P07,P08 |
| `ScatterScreenProbes` :542 | bin_cached_probe / find_cached_probe; different bin/list representation | Probe placement and history / P01,P04,P07,P08 |
| `SpawnScreenProbes` :556 | select_probe; fixed update slots, not identical compaction | Probe placement and history / P01,P04,P07,P08 |
| `CompactScreenProbes` :582 | select_probe; fixed update slots, not identical compaction | Probe placement and history / P01,P04,P07,P08 |
| `PatchScreenProbes` :616 | patch_probe | Probe placement and history / P01,P04,P07,P08 |
| `SampleScreenProbes` :647 | prepare_probe / trace_probe / sample_cell | Probe guiding and eviction / P01,P06,P08 |
| `PopulateScreenProbesHandleHit` :986 | trace_probe / trace_hit / allocate_tile / register_ray; shared rt_gi_transport | Primary transport / T01-T05,C01-C06,L01-L06 |
| `PopulateScreenProbesHandleMiss` :1078 | trace_probe / trace_hit / allocate_tile / register_ray; shared rt_gi_transport | Primary transport / T01-T05,C01-C06,L01-L06 |
| `PopulateScreenProbesTraceRay` :1086 | trace_probe / trace_hit / allocate_tile / register_ray; shared rt_gi_transport | Primary transport / T01-T05,C01-C06,L01-L06 |
| `PopulateScreenProbes` :1107 | trace_probe / trace_hit / allocate_tile / register_ray; shared rt_gi_transport | Primary transport / T01-T05,C01-C06,L01-L06 |
| `PopulateScreenProbesMain` :1161 | trace_probe / trace_hit / allocate_tile / register_ray; shared rt_gi_transport | Primary transport / T01-T05,C01-C06,L01-L06 |
| `BlendScreenProbes` :1167 | resolve_probe | Probe blend and LRU / P06-P08,C01-C06 |
| `ReorderScreenProbes` :1334 | order_cached_probes / store_cached_probe | Probe blend and LRU / P06-P08,C01-C06 |
| `FilterScreenProbes` :1357 | filter_probe (X/Y) | Probe spatial filter / P02,P04 |
| `ProjectScreenProbes` :1446 | project_probe | SH projection / P03 |
| `InterpolateScreenProbes` :1515 | interpolate_pixel / probe_irradiance; SSGI/bent-cone portion absent | Probe interpolation and near-field GI / P05,P09 |
| `PurgeTiles` :1715 | reset_cache | Cache and multibounce / C01-C06 |
| `PopulateMultibounceCellsHandleHit` :1761 | populate_secondary / secondary allocate/register; rt_gi_transport | Cache and multibounce / C01-C06 |
| `PopulateMultibounceCellsTraceRay` :1854 | populate_secondary / secondary allocate/register; rt_gi_transport | Cache and multibounce / C01-C06 |
| `PopulateMultibounceCells` :1869 | populate_secondary / secondary allocate/register; rt_gi_transport | Cache and multibounce / C01-C06 |
| `PopulateMultibounceCellsMain` :1943 | populate_secondary / secondary allocate/register; rt_gi_transport | Cache and multibounce / C01-C06 |
| `UpdateMultibounceCells` :1948 | indirect_hit / shade_indirect_hit / update_indirect | Cache and multibounce / C01-C06 |
| `UpdateMultibounceCellsMain` :1986 | indirect_hit / shade_indirect_hit / update_indirect | Cache and multibounce / C01-C06 |
| `PopulateCellsHandleHit` :1993 | shade_hit / shade_direct / gi_light_visibility | Cache and multibounce / C01-C06 |
| `PopulateCellsHandleMiss` :2006 | shade_hit / shade_direct / gi_light_visibility | Cache and multibounce / C01-C06 |
| `PopulateCellsTraceRay` :2022 | shade_hit / shade_direct / gi_light_visibility | Cache and multibounce / C01-C06 |
| `PopulateCells` :2040 | shade_hit / shade_direct / gi_light_visibility | Cache and multibounce / C01-C06 |
| `PopulateCellsMain` :2111 | shade_hit / shade_direct / gi_light_visibility | Cache and multibounce / C01-C06 |
| `GenerateUpdateTilesDispatch` :2130 | cache dispatch / update_cell / update_indirect / build_mip / resolve_probe | Cache and multibounce / C01-C06 |
| `UpdateTiles` :2143 | cache dispatch / update_cell / update_indirect / build_mip / resolve_probe | Cache and multibounce / C01-C06 |
| `ResolveCells` :2351 | cache dispatch / update_cell / update_indirect / build_mip / resolve_probe | Cache and multibounce / C01-C06 |
| `ClearReservoirs` :2394 | reservoir_reset | Light reservoirs / L01-L06 |
| `GenerateReservoirs` :2401 | resampled_direct / shade_direct at primary and secondary hits | Light reservoirs / L01-L06 |
| `GenerateMultibounceReservoirs` :2603 | resampled_direct / shade_direct at primary and secondary hits | Light reservoirs / L01-L06 |
| `CompactReservoirs` :2699 | reservoir_scan / reservoir_compact | Light reservoirs / L01-L06 |
| `ResampleReservoirs` :2713 | resampled_direct / reservoir_find_previous / reservoir_load_previous | Light reservoirs / L01-L06 |
| `TraceReflectionsHandleHit` :2801 | prepare_reflection / classify_reflection / trace_reflection / screen_lighting | Reflection tracing / R01-R06,T01-T05 |
| `TraceReflectionsHandleMiss` :2905 | prepare_reflection / classify_reflection / trace_reflection / screen_lighting | Reflection tracing / R01-R06,T01-T05 |
| `TraceReflectionsTraceRay` :2915 | prepare_reflection / classify_reflection / trace_reflection / screen_lighting | Reflection tracing / R01-R06,T01-T05 |
| `TraceReflections` :2933 | prepare_reflection / classify_reflection / trace_reflection / screen_lighting | Reflection tracing / R01-R06,T01-T05 |
| `RatioEstimator_GaussianFilter` :3014 | Split-ratio-only helper absent | Reflection tracing / R01-R06,T01-T05 |
| `AtrousRatioEstimator_GaussianFilter` :3020 | resolve_reflection exponential/Gaussian weights | Reflection tracing / R01-R06,T01-T05 |
| `MarkFireflies_BoxFilter` :3026 | mark_reflection_fireflies weights | Reflection tracing / R01-R06,T01-T05 |
| `CleanupFireflies_NeighborhoodFilter` :3031 | clean_reflection_fireflies weights | Reflection tracing / R01-R06,T01-T05 |
| `TraceReflectionsMain` :3039 | prepare_reflection / classify_reflection / trace_reflection / screen_lighting | Reflection tracing / R01-R06,T01-T05 |
| `ResolveReflections_SplitRatioEstimatorX` :3045 | Absent optional algorithm | Missing optional split-ratio estimator / O01 |
| `ResolveReflections_SplitRatioEstimatorY` :3157 | Absent optional algorithm | Missing optional split-ratio estimator / O01 |
| `ReprojectReflections` :3282 | temporal_reflection / reflection_history_at | Reflection reconstruction/history / R01-R06 |
| `ResolveReflections_AtrousRatioEstimator_First` :3448 | resolve_reflection first/iter/last pass branches | Reflection reconstruction/history / R01-R06 |
| `ResolveReflections_AtrousRatioEstimator_Iter` :3554 | resolve_reflection first/iter/last pass branches | Reflection reconstruction/history / R01-R06 |
| `ResolveReflections_AtrousRatioEstimator_Last` :3663 | resolve_reflection first/iter/last pass branches | Reflection reconstruction/history / R01-R06 |
| `MarkFireflies` :3813 | mark_reflection_fireflies | Reflection reconstruction/history / R01-R06 |
| `CleanupFireflies` :3883 | clean_reflection_fireflies | Reflection reconstruction/history / R01-R06 |
| `NoDenoiserReflections` :3958 | output_reflection_pixel with global denoiser disabled; control differs | Reflection reconstruction/history / R01-R06 |
| `ReprojectGI` :3997 | reproject_pixel / gi_denoiser_accumulate | Diffuse denoising / D01-D03 |
| `FilterGI` :4105 | filter_pixel / gi_denoiser_filter_weight | Diffuse denoising / D01-D03 |
| `ClearBucketOverflowCount` :4158 | Absent AMD diagnostic kernels; fork diagnostic readbacks differ | Missing AMD diagnostic kernels / O03 |
| `ClearBucketOccupancy` :4170 | Absent AMD diagnostic kernels; fork diagnostic readbacks differ | Missing AMD diagnostic kernels / O03 |
| `ClearBucketOverflow` :4188 | Absent AMD diagnostic kernels; fork diagnostic readbacks differ | Missing AMD diagnostic kernels / O03 |
| `BuildBucketStatistics` :4200 | Absent AMD diagnostic kernels; fork diagnostic readbacks differ | Missing AMD diagnostic kernels / O03 |
| `FormatBucketOccupancy` :4237 | Absent AMD diagnostic kernels; fork diagnostic readbacks differ | Missing AMD diagnostic kernels / O03 |
| `FormatBucketOverflow` :4257 | Absent AMD diagnostic kernels; fork diagnostic readbacks differ | Missing AMD diagnostic kernels / O03 |

## Companion source and dependency contracts

| AMD source family | Fork source / disposition | Findings |
| --- | --- | --- |
| `gi1.cpp/.h`, `gi1_shared.h`, `gi1.hlsl` | `environment/amd_gi.cpp/.h`, shader layouts and RD dispatches; allocations, formats, options, bindings, constants, clears, swaps, GUI/termination reviewed | H01–H04, O01–O04 |
| `screen_probes.hlsl` | Probe structures, masks, SH, hemisphere mapping, cache allocator in `amd_gi.glsl` | P01–P09 |
| `hash_grid_cache.hlsl` | Cache key/read/allocation/mips in `amd_gi.glsl`, `amd_gi_cache_inc.glsl` | C01–C06 |
| `world_space_restir.hlsl` | `amd_gi_reservoirs_inc.glsl`, `amd_gi_lights_inc.glsl` | L04–L05 |
| `glossy_reflections.hlsl` | `amd_gi_reflections_inc.glsl` | R01–R06 |
| `gi_denoiser.hlsl` | `amd_gi_denoiser_inc.glsl`, pixel histories/filters | D01–D03 |
| `gi1.frag/.vert` | Native Forward+ final shading; AMD debug screen/cache/reflection draws absent | R01, T05, O03 |
| `gi1.rt` | Raygen/hit/miss wrappers route to the same core; fork Vulkan inline queries, no DXR SBT | H03, T02–T03 |
| `light_sampler_grid_stream/*` | Bounds/build/proposal helpers in `amd_gi_lights_inc.glsl`, host buffers | L01–L06 |
| `light_sampler_grid_cdf/*`, `light_sampler_uniform/*` | Inspected as alternative component contracts; not default GI1 stages; no claimed port | O04 |
| `light_builder/*`, `lights/*` | `rt_gi_emitters.glsl`, `rt_gi_scene.cpp`, light target/volume/visibility helpers; uniform triangle/area PDF and default environment formulas present; alternate modes explicitly missing | L01–L06, T03–T05 |
| `materials/*` | Rough dielectric BRDF and bounded GGX helpers present; source hit material/texture/packing replaced by captured atlas | T01, C04,C06,L03,L04 |
| `geometry/*`, `ray_tracing/*` | Shared `rt_geometry`, transport ray query/alpha/hit reconstruction, material expansion/capture and culling | T01–T04, H04 |
| `math/*`, random generator, blue-noise sampler | Hemisphere/SH/quaternion/hash/PCG/blue-noise/VNDF helper contracts; same tables, different routing/precision at call sites | P03,P06,P07,C04,L04 |
| `ssgi/*` | Default near-field radiance, horizon occlusion and bent-cone path absent; all five options missing | P09 |
| VisibilityBuffer and previous buffers | Native geometry/detail normals, depth, velocity, previous surface and primary material attachments | P07,R03,D02,H01 |
| Combine, BRDF LUT, environment, exposure | Native Forward+ response/feedback/sky/exposure adapter; no blanket equivalence | D03,T05 |
| PrefilterIBL | Bound by AMD host but prefiltered texture unused by GI1 shaders; ordinary cube is used | O04 |
| GI1Renderer graph / remaining postprocessing | Native atmosphere/skybox/FSR2 or DLSS/exposure/bloom/tone mapping services; not missing GI transport stages | O04 |

## Every fork pass

| Pass | Disposition |
| --- | --- |
| `PASS_ALLOCATE` | Primary transport/cache membership; T01–T03,C02–C03 |
| `PASS_ALLOCATE_SECONDARY` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_BIN_CACHED` | Probe placement/history/cache; P01,P06–P08 |
| `PASS_BLUR_X` | Diffuse denoiser; D01–D02 |
| `PASS_BLUR_Y` | Diffuse denoiser; D01–D02 |
| `PASS_FILTER_X` | Probe reconstruction; P02–P05,P09 |
| `PASS_FILTER_Y` | Probe reconstruction; P02–P05,P09 |
| `PASS_INDIRECT_MIP1` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_INDIRECT_MIP2` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_INDIRECT_MIP3` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_INTERPOLATE` | Probe reconstruction; P02–P05,P09 |
| `PASS_LIGHT_BOUNDS` | GridStream; L01–L03,L06 |
| `PASS_LIGHT_BOUNDS_RESET` | GridStream; L01–L03,L06 |
| `PASS_LIGHT_GRID` | GridStream; L01–L03,L06 |
| `PASS_MASK` | Probe reconstruction; P02–P05,P09 |
| `PASS_MIP1` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_MIP2` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_MIP3` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_ORDER_CACHED` | Probe placement/history/cache; P01,P06–P08 |
| `PASS_PATCH` | Probe placement/history/cache; P01,P06–P08 |
| `PASS_POPULATE` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_PREPARE` | Probe placement/history/cache; P01,P06–P08 |
| `PASS_PROJECT` | Probe reconstruction; P02–P05,P09 |
| `PASS_REFLECTION_BUILD_DISPATCH` | Reflection dispatch/tracing; H02,R01–R04 |
| `PASS_REFLECTION_CLASSIFY` | Reflection dispatch/tracing; H02,R01–R04 |
| `PASS_REFLECTION_CLEAN_FIREFLIES` | Reflection reconstruction/output; R01–R06,D03 |
| `PASS_REFLECTION_FIRST` | Reflection reconstruction/output; R01–R06,D03 |
| `PASS_REFLECTION_ITER` | Reflection reconstruction/output; R01–R06,D03 |
| `PASS_REFLECTION_LAST` | Reflection reconstruction/output; R01–R06,D03 |
| `PASS_REFLECTION_MARK_FIREFLIES` | Reflection reconstruction/output; R01–R06,D03 |
| `PASS_REFLECTION_OUTPUT` | Reflection reconstruction/output; R01–R06,D03 |
| `PASS_REFLECTION_TEMPORAL` | Reflection reconstruction/output; R01–R06,D03 |
| `PASS_REFLECTION_TRACE` | Reflection dispatch/tracing; H02,R01–R04 |
| `PASS_REGISTER` | Primary transport/cache membership; T01–T03,C02–C03 |
| `PASS_REGISTER_SECONDARY` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_REPROJECT` | Probe placement/history/cache; P01,P06–P08 |
| `PASS_RESERVOIR_COMPACT` | World-space reservoir allocation/scan/compaction; L04–L05 |
| `PASS_RESERVOIR_RESET` | World-space reservoir allocation/scan/compaction; L04–L05 |
| `PASS_RESERVOIR_SCAN` | World-space reservoir allocation/scan/compaction; L04–L05 |
| `PASS_RESERVOIR_SCAN_BLOCKS` | World-space reservoir allocation/scan/compaction; L04–L05 |
| `PASS_RESERVOIR_SCAN_TOP` | World-space reservoir allocation/scan/compaction; L04–L05 |
| `PASS_RESET` | Host clear/cache purge/LRU initialization; C01,H01–H02 |
| `PASS_RESOLVE` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_SELECT` | Probe placement/history/cache; P01,P06–P08 |
| `PASS_SHADE_HITS` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_SHADE_INDIRECT_HITS` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_STORE_CACHED` | Probe placement/history/cache; P01,P06–P08 |
| `PASS_TEMPORAL` | Diffuse denoiser; D01–D02 |
| `PASS_TRACE` | Primary transport/cache membership; T01–T03,C02–C03 |
| `PASS_UPDATE` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_UPDATE_INDIRECT` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |

The separate environment conversion shader has base conversion and mip-generation branches (T05). `rt_gi_emitters.glsl` builds the sampled triangle list (L03); `rt_material_expand.glsl` expands native geometry for capture (T01). Forward+ writes the native primary inputs and pre-fog feedback and composites diffuse/specular outputs (T05,H03). Shared transport also serves the separate RT-validation backend; unused helpers or its uncached estimator are not additional AMD stages.

## Every AMD GI option

Defaults are read from AMD `GI1::RenderOptions`. “Fixed” means the default value exists but the corresponding AMD control is not exposed; it is not a complete control port.

| AMD option | Default | Fork mapping / disposition |
| --- | --- | --- |
| `gi1_use_dxr10` | `false` | Vulkan inline queries only; authorized API scope (H03) |
| `gi1_use_resampling` | `false` | `light_resampling=false`; branch differences L04–L05 |
| `gi1_disable_alpha_testing` | `false` | No independent equivalent; inherited AMD visibility option; T03,O02 |
| `gi1_use_direct_lighting` | `true` | No identical debug switch; native direct lighting retained and GI emission/NEE enabled; L02,O02 |
| `gi1_use_temporal_feedback` | `false` | `screen_feedback=false`; reflection coupling and diffuse-feedback/multibounce exclusivity differ; R02 |
| `gi1_use_multibounce` | `true` | `multibounce=true`; C04 |
| `gi1_disable_albedo_textures` | `false` | No equivalent independent reference debug switch; O02,T01 |
| `gi1_disable_specular_materials` | `false` | No equivalent independent reference debug switch; O02,T01 |
| `gi1_hash_grid_cache_cell_size` | `32.0F` | Fixed 32-pixel cache footprint; O02 |
| `gi1_hash_grid_cache_min_cell_size` | `1e-1F` | `minimum_cell_size=0.1` |
| `gi1_hash_grid_cache_tile_cell_ratio` | `8` | Fixed 8; same default, no general tile-ratio control |
| `gi1_hash_grid_cache_num_buckets` | `14` | `cache_bucket_exponent=14` (2^14) |
| `gi1_hash_grid_cache_num_tiles_per_bucket` | `4` | Fixed 2^4=16; same default |
| `gi1_hash_grid_cache_max_sample_count` | `16.0F` | Fixed 16; same nominal cap, C03–C05 inputs differ |
| `gi1_hash_grid_cache_discard_multibounce_ray_probability` | `0.7F` | Complement of `continuation_probability=0.3`; random comparison differs, C04 |
| `gi1_hash_grid_cache_max_multibounce_sample_count` | `16.0F` | Fixed 16; same nominal cap, C03–C05 inputs differ |
| `gi1_hash_grid_cache_debug_mip_level` | `0` | Missing corresponding AMD visualization/statistics/control; O03 |
| `gi1_hash_grid_cache_debug_propagate` | `false` | Missing corresponding AMD visualization/statistics/control; O03 |
| `gi1_hash_grid_cache_debug_max_cell_decay` | `0` | Missing corresponding AMD visualization/statistics/control; O03 |
| `gi1_hash_grid_cache_debug_stats` | `false` | Missing corresponding AMD visualization/statistics/control; O03 |
| `gi1_hash_grid_cache_debug_max_bucket_overflow` | `64` | Missing corresponding AMD visualization/statistics/control; O03 |
| `gi1_reservoir_cache_cell_size` | `16.0F` | Fixed 16-pixel footprint; same default; L04–L05 |
| `gi1_glossy_reflections_halfres` | `true` | `reflections/half_resolution=true` |
| `gi1_glossy_reflections_denoiser_mode` | `1` | Default a-trous present; split mode absent; independent off mode absent; R06,O01 |
| `gi1_glossy_reflections_cleanup_fireflies` | `true` | `reflections/firefly_filter=true`; R05 |
| `gi1_glossy_reflections_low_roughness_threshold` | `0.2F` | `reflections/trace_roughness_threshold=0.2` |
| `gi1_glossy_reflections_high_roughness_threshold` | `0.6F` | `reflections/probe_roughness_threshold=0.6`; R01 |
| `gi1_glossy_reflections_atrous_pass_count` | `4` | `reflections/filter_passes=4` |
| `gi1_glossy_reflections_full_radius` | `11` | Split-estimator radii absent with estimator; O01 |
| `gi1_glossy_reflections_half_radius` | `11` | Split-estimator radii absent with estimator; O01 |
| `gi1_glossy_reflections_mark_fireflies_half_radius` | `3` | Fixed matching default selected by resolution; independent controls absent; R05–R06 |
| `gi1_glossy_reflections_mark_fireflies_full_radius` | `2` | Fixed matching default selected by resolution; independent controls absent; R05–R06 |
| `gi1_glossy_reflections_mark_fireflies_half_low_threshold` | `0.0F` | Single `reflections/firefly_low_threshold=0`; modes coupled |
| `gi1_glossy_reflections_mark_fireflies_full_low_threshold` | `0.0F` | Single `reflections/firefly_low_threshold=0`; modes coupled |
| `gi1_glossy_reflections_mark_fireflies_half_high_threshold` | `1.0F` | Single `reflections/firefly_high_threshold=1`; modes coupled |
| `gi1_glossy_reflections_mark_fireflies_full_high_threshold` | `1.0F` | Single `reflections/firefly_high_threshold=1`; modes coupled |
| `gi1_glossy_reflections_cleanup_fireflies_half_radius` | `2` | Fixed matching default selected by resolution; independent controls absent; R05–R06 |
| `gi1_glossy_reflections_cleanup_fireflies_full_radius` | `1` | Fixed matching default selected by resolution; independent controls absent; R05–R06 |

## Every dependency option

| AMD dependency option | Default | Fork disposition |
| --- | --- | --- |
| `ssgi_slice_count_` | `1` | SSGI stage and control absent (P09) |
| `ssgi_step_count_` | `2` | SSGI stage and control absent (P09) |
| `ssgi_view_radius_` | `0.2F` | SSGI stage and control absent (P09) |
| `ssgi_falloff_range_` | `0.05F` | SSGI stage and control absent (P09) |
| `ssgi_unroll_kernel_` | `false` | SSGI stage and control absent (P09) |
| `light_grid_stream_num_cells` | `16` | Fixed matching 16; bounds domain differs (L01) |
| `light_grid_stream_lights_per_cell` | `64` | Fixed matching 64 (L01) |
| `light_grid_stream_octahedron_sampling` | `false` | Nondefault mode absent; default false behavior only (L06) |
| `light_grid_stream_resample` | `false` | Nondefault mode absent; default false behavior only (L06) |
| `light_grid_stream_merge_type` | `1` | Only default mode 1, without replacement; modes 0/2 absent (L06) |
| `light_grid_stream_parallel_build` | `false` | Nondefault mode absent; default false behavior only (L06) |
| `light_grid_stream_centroid_build` | `false` | Nondefault mode absent; default false behavior only (L06) |
| `light_grid_stream_cell_overlap` | `false` | Nondefault mode absent; default false behavior only (L06) |
| `delta_light_enable` | `true` | Analytic lights included; no independent category-enable equivalent (L02) |
| `area_light_enable` | `true` | `emissive_sampling=true`; evaluation/cap differences (L03) |
| `environment_light_enable` | `true` | Native environment source/energy contract; proposal always reserved (L01,T05) |
| `environment_sampling_mode` | `static_cast<uint8_t>(EnvironmentSamplingMode::Uniform)` | Uniform implemented; cosine/importance modes absent (L06) |
| `low_emission_area_lights_disable` | `false` | No equivalent AMD low-emission culling option (L06) |
| `low_emission_threshold` | `1.0F` | No equivalent control; inactive upstream by default (L06) |

## Every Godot AMD GI setting

Prefix: `rendering/global_illumination/amd_gi/`. Defaults and declarations are captured verbatim in the machine-readable evidence. These rows also identify fork-only quality departures, not just upstream controls.

| Setting | Default | Disposition |
| --- | --- | --- |
| `enabled` | `false` | Required off gate; H03 |
| `probe_spacing` | `16` | 8/16/32 map to AMD compile-time one/quarter/sixteenth budgets; default 16 matches |
| `material_atlas_mb` | `128` | Fork-only material budget; T01,T04; unapproved quality/suppression behavior |
| `material_tile_size` | `8` | Fork-only coarse material representation; T01 |
| `material_adaptive_resolution` | `true` | Fork-only automatic material-detail reduction; T01 |
| `material_preparation_budget` | `64` | Fork-only native preparation scheduling/readiness; T04,H04 |
| `multibounce` | `true` | AMD default enabled; C04 |
| `screen_feedback` | `false` | AMD diffuse option default off; incorrectly also controls reflection reuse (R02) |
| `cache_all_hits` | `true` | True matches all-hit intent; false owner-only estimator is a departure (C03) |
| `cache_bucket_exponent` | `14` | AMD default 14; adjustable capacity (C02–C03) |
| `denoiser` | `true` | Global coupled diffuse/reflection switch; no independent reflection mode parity (R06) |
| `importance_sampling` | `true` | Default reference radiance guiding present with P06 differences; disable is a fork-only quality mode |
| `adaptive_sampling` | `true` | Default reference adaptive placement intent; P01,P08; disable is a fork-only quality mode |
| `probe_cache` | `true` | Default reference off-screen reuse intent; P08; disable is a fork-only quality mode |
| `light_resampling` | `false` | AMD optional world-space reuse, default off; L04–L05 |
| `reflections/enabled` | `true` | Requested independent feature toggle; disabled path must release its resources (H03) |
| `reflections/half_resolution` | `true` | AMD matching default true; R04–R05 |
| `reflections/trace_roughness_threshold` | `0.2` | AMD low threshold; default matches |
| `reflections/firefly_low_threshold` | `0.0` | AMD low thresholds collapsed to one control; default matches |
| `reflections/firefly_high_threshold` | `1.0` | AMD high thresholds collapsed to one control; default matches |
| `reflections/probe_roughness_threshold` | `0.6` | AMD high threshold; R01 fallback differs |
| `reflections/filter_passes` | `4` | AMD default four a-trous passes; R04–R06 |
| `reflections/firefly_filter` | `true` | AMD cleanup switch; R05 boundary differences |
| `reflections/ray_compaction` | `true` | Work scheduling toggle; prior equivalence regression, H02 |
| `emissive_sampling` | `true` | Area proposal category; default enabled; L03/T01 |
| `brdf_sampling` | `true` | Default reference BRDF guiding intent; disable is a fork-only quality mode |
| `minimum_cell_size` | `0.1` | AMD minimum cell size; default matches |
| `continuation_probability` | `0.3` | Complement of AMD discard probability; C04 |
| `max_distance` | `50.0` | Fork-only finite tracing/collection limit, default 50; T02 |

## Compile-time and alternate branch accounting

- `USE_INLINE_RT`: Vulkan inline path is the requested backend; DXR pipeline wrappers are excluded by API scope, not silently forgotten.
- `USE_MULTI_BOUNCE`: both enabled/disabled source paths are present; C04 covers remaining enabled-path differences.
- `USE_RESAMPLING`: default false and optional true are both compared; L04–L05 remain open.
- `DISABLE_SPECULAR_MATERIALS`, alpha and albedo disable controls: reference debug alternatives are not completely exposed/equivalent (O02). Their material packing differs too (L04).
- `DEBUG_HASH_CELLS`, `DEBUG_HASH_STATS`: reference visualizers/statistics are absent (O03).
- GI1 optional occlusion/near-field inputs: supplied in the default AMD renderer; absent here (P09).
- The dead `#if 0` alternative inside `NoDenoiserReflections` is not an active AMD algorithm requirement.
- Optional GridStream/environment modes are explicitly listed above. General library BRDF/sampling helpers not called by these paths are not additional GI1 stages.

## Evidence and reproducibility

`/workspace/gi-validation/amd-source-audit-2026-10-23/build_inventory.py` regenerates the inventories and checks source hashes without modifying renderer source. `write_coverage.py` generates this appendix from explicit, exhaustiveness-checked mappings. `checks.json` records the blue-noise/counter/algebra checks. Source hashes cover shared files that also contain non-GI routines; listing such a file is not a claim that unrelated renderer behavior was audited.


<a id="snapshot-amd-gi-consequential-corrections"></a>

## Snapshot: docs/AMD_GI_CONSEQUENTIAL_CORRECTIONS.md

# Consequential AMD GI correction record

This is the live record for resolving consequential findings while deferring
completeness. The default-path corrections are implemented and tested for the
qualified input domain below, with the owner's explicitly approved exceptions.
The last approved material correction covers affine emitter mappings. Arbitrary
custom mappings, additional native scene classes, optional AMD features and
hardware/gameplay qualification remain incomplete; this is not a claim that the
entire requested integration is finished or that every reported game issue is fixed.

Reference: Capsaicin `914b91596cd119eda85fbc1d3c7ee6ac391b1452`, package v1.3 / renderer GI-1.2. Starting fork: `d932f4a` plus the preexisting local follow-up. The [full comparison](#snapshot-amd-gi-full-comparison) and [coverage appendix](#snapshot-amd-gi-comparison-coverage) remain the historical source inventory. The [adapter decision record](#snapshot-amd-gi-adapter-decisions) records each approved correction, the withdrawn firefly snapshot, and the approved affine emitter-coordinate extension and its remaining native-material limits.

## Latest approved boundary

T01/L03 now include correct affine emitter filtering for alternate UV layouts,
scaling, translation, rotation, mirroring and supported aliases/varyings. The
704-sample GPU oracle and ordinary material/emitter regressions pass. Complex
nonlinear/texture-driven/control-flow mappings retain an explicitly diagnosed
fallback; they were excluded from the recommendation the owner approved.
No additional algorithm exception awaits approval. Full AMD optional-feature
parity, complete native-material/scene coverage and target-hardware qualification
remain unfinished.

## Implemented corrections and remaining qualification

“Implemented” below describes source changes, not whole-pipeline equivalence. The evidence directory is `/workspace/gi-validation/amd-consequential-corrections/`; `preexisting.patch` separates this work from earlier local changes. The preceding corrections are available in the Windows artifacts from [run 40062237050](https://github.com/automata-rtx/godot-rt/actions/runs/40062237050), commit `1d486a02d5`; those artifacts predate the affine follow-up below. No target-hardware performance result is supplied by this work.

| Finding | Current disposition |
| --- | --- |
| P01 | Implemented accepted-center reuse increment; eviction now sees accepted center reuse. |
| P02 | Implemented hierarchical nearest-probe search, alternating tap order, full plane footprint, linear-view-depth weighting and per-neighbor reference NaN handling. |
| P03 | Implemented 1/8 SH projection and irradiance units through diffuse reconstruction/denoising; final Lambert division occurs at composition. |
| P04 | Implemented floor-halved mask dimensions, clamped hierarchy lookup, and mask generation before probe filtering/projection. Odd-size integration exercises the path. |
| P05 | Implemented exact zero squared-weight fallback and reference finite-domain depth divisor. |
| P06 | Implemented unconditional CDF variate, reference CDF floor, compact live-probe order and registered-hit RNG IDs. Atomically appended hits may have a different scheduling order, as with upstream GPU appends; full GPU trace equivalence is not established. |
| P07 | Added separate R10G10B10A2 geometry/shading normals and R16F roughness; cached normals round through packed-normal precision. Diffuse history reconstructs continuous previous UV with sampled depth. The native row-matrix/jitter proof passes 4096 cases; four/eight-weight GPU poses, blend shapes, FSR2 buffers and viewport lifetime pass their controlled regressions. Target-hardware behavior remains unmeasured. |
| P08 | Replaced allocation/claim/reorder logic with old-LRU-rank ownership, allocation supersession, retained-old-order and appended-MRU handling. Fixed partial-edge bin coordinates. GPU LRU permutation/ownership validation passes under motion. |
| P09 | Added the default one-slice/two-step near-field SSGI, radius 0.2/falloff 0.05, previous-lighting integration, bent normal and cone SH convolution. The arbitrary finite substitute for a homogeneous w=0 endpoint was removed; reconstruction now follows AMD directly. Finite native projections are the tested domain; an infinite-projection endpoint retains the reference undefined division rather than an unapproved policy. VBAO has not been substituted for this stage. |
| C01 | Implemented age >=50 purge boundary. |
| C02 | Implemented first-empty hash termination and removed local-coordinate clamp. The retained signed 8-bit level can represent the finite useful exponent domain of this float cache; infinity/overflow inputs are not certified. |
| C03 | Registered hits now receive compact work indices; continuation and shading consume indirect compact dispatches. Valid selected-light samples now atomically add their quantized RGB/count into the cell, as in AMD. A rejected fresh reservoir contributes no count; a valid occluded sample still contributes count one. Linked lists exist only in the explicitly enabled GPU ownership diagnostic. GPU diagnostics check every registered primary/secondary contribution, integer sums/counts, cache membership and occupied-tile ownership under motion, deformation, empty-screen dispatch and resize. Integer overflow retains the reference wrap behavior; owner-only quality mode remains a nonbaseline option. |
| C04 | Implemented `u>0.7` continuation, half BRDF/PDF handoff and reference per-injection half rounding/order. The owner approved both distinct upstream corrections: associate the bypass flag with its actual secondary hit, and route only the weighted secondary contribution to its parent probe ray. Source-checked index/black-parent counterexamples are retained. The combined ownership integration and final four/eight-weight pose regression pass. Registered hits whose half-barycentric reconstruction has zero length are now processed, as in AMD, instead of being incorrectly discarded. |
| C05 | Removed broad 60000/whole-vector transport clamps; restored reference sanitization and nonzero-injection tests at their actual stages. RGB fixed-point conversion and wrapping sums retain AMD behavior. Nonfinite/negative/out-of-range float-to-uint inputs remain a source limitation, not an approved new clamping policy. The separately approved distance-only overflow correction leaves RGB unchanged. |
| C06 | Implemented the explicitly approved native base-emissivity encoding: an EMISSION-writing program has a unit base factor, independent of sampled RGB. Front-facing primary/glossy hits terminate even at black texels or dark procedural phases; back faces and secondary cache shading retain their reference roles. The GPU source fixture verifies the flag remains set at zero RGB and clears when the emission write is removed. |
| L01 | Bounds accumulate during hit insertion. Reference light order and conditional environment entry are retained. The approved flat-axis policy removes the arbitrary epsilon thickness, retains actual zero extents and selects the sole cell without division; jitter draw consumption is unchanged. Positive-extent arithmetic is unchanged. |
| L02 | **Approved boundary:** native authored attenuation, energy, masks and material response. A concrete numerical comparison and narrow scope are in the adapter proposal. The owner explicitly approved this boundary on October 23, 2026. |
| L03 | Source emitter geometry replaces capture tiles, and proposals/targets execute the material source with triangle/cone LOD. The 256-sample GPU fixture verifies point/volume/cone values and native attribute/uniform changes. The former emitter cap is removed, and the source-emitter room passes. Post-vertex UV0 is half-packed as in the reference light builder. Native EMISSION is the approved RGB function with unit emission-texture alpha; surface opacity is separate traversal coverage. The approved affine-coordinate extension now passes 704 GPU samples. Complex mappings outside that subset are explicitly diagnosed and remain unsupported for correct emitter filtering; see the adapter decision for the precise scope. |
| L04 | Implemented zero-weight draw consumption, fresh-confidence branch behavior, draw order, half sample parameters, packed albedo/normal inputs, incremental MIS-normalized merging, previous M cap and reference validity checks. The multi-light fixture now passes with world reuse exercised and exact zero-indirect/disabled controls. Native screen feedback now accumulates each analytic light using its authored indirect-energy multiplier. |
| L05 | Removed persistent identity remapping. Restored reference index reuse and environment/zero-count light-settings reset boundaries; the original universal-reset audit assertion was corrected. The owner explicitly approved rejecting a historical sample whose light index is outside the current logical list. Existing in-range index semantics and other history are retained. |
| L06 | Deferred completeness: optional GridStream modes and sampling configurations. Default algorithm corrections remain in scope. |
| R01 | Implemented rough fallback from filtered diffuse irradiance divided by pi, eliminating the extra pi division. |
| R02 | Reflection hit feedback is active independently of diffuse feedback. Diffuse feedback is exclusive with multibounce. Previous opaque lighting is also needed by default SSGI, so `screen_feedback=false` no longer frees that required input. |
| R03 | Feedback reads previous geometry normals and accepts relaxed diffuse confidence. Removed extra current-visibility/coverage rejection; native motion adaptation passes the independent matrix/jitter and GPU pose regressions. It is not a rendered Capsaicin pixel-parity proof. |
| R04 | Raw/history glossy backing storage now uses 64-byte packed records with half color/count, direction and variance handoffs; float position/normal fields support native reprojection. All readers and CPU diagnostics decode that layout. The combined reflection regression passes 344 checked frames, including compact/direct comparison, moving emitter, half/full reconstruction and history restoration. |
| R05 | Restored reference additive-center fallback, zero-valued border loads, depth-based sky-neighbor reconstruction and odd-size phase bounds. The snapshot proposal was withdrawn because no worthwhile visual benefit had been demonstrated. Cleanup now updates marked samples in place, as AMD does, and writes half precision. Nonfinite scheduling dependence is retained as a source limitation. The combined 344-frame reflection regression passes with in-place cleanup restored. |
| R06 | Deferred completeness: split ratio estimator. |
| D01 | Implemented irradiance units at denoiser input, preserving reference thresholds. |
| D02 | Implemented continuous-UV previous-world reconstruction, decoded normal inputs, half color/history/delta and R8_SNORM blur mask. Persistent diffuse records now use 32 bytes instead of 48; all reads/writes use packed backing storage. Combined ownership/motion/resize/disable integration passes. The final native pose/FSR2 regression passes with GI MAE 0.001130/0.002276 against independently baked four/eight-weight geometry. |
| D03 | Supplies effective native manual/automatic exposure to reflection temporal luminance weighting, using the previous completed luminance reduction without a CPU readback. Dynamic exposure integration fixture added; this is not whole-renderer exposure equivalence. |
| T01 | AMD hit albedo/emission/alpha now execute native shader source with native uniform/texture/sampler/attribute inputs. No AMD material-capture atlas is allocated or prepared. The source oracle passes 256 GPU samples (maximum component error 0.00000142), including vertex-stage mip-zero reads, UV/UV2, custom/color data, varying interpolation, uniform changes, compressed inputs, transforms, mip levels, actual alpha/discard rays and emissive classification. Affine emitter footprint qualification passes; arbitrary warped/texture-driven/control-flow mappings remain a native-material limitation. |
| T02 | Added shared-BLAS position/index buffer access, barycentrically reconstructed transformed hit positions, and query hit distance. Native front-face orientation is used. Source vertex normals now come from native packed/posed buffers; geometric normals come from shared triangle positions. Both transform into world space once and remain separate through reservoir sampling, shadow offsets and final cache shading. Compact 48-byte visibility records now retain the actual query point/distance and half barycentrics separately; source shading reconstructs from the latter. The new integration passes hit/cache/continuation checks, including empty-screen dispatch and odd resize. The approved distance correction restores the 1e9 default ray extent and full participating-scene collection; only screen-probe reprojection distance is capped at 65504, with a two-word sum. Twenty GPU cases verify exact integer carries and unchanged RGB. The [normal-space investigation](#snapshot-amd-gi-normal-space-investigation) traces producers and consumers and demonstrates missing/repeated transforms on equivalent baked/instanced geometry; the owner's conditional approval now authorizes the narrow correction. |
| T03 | Source object-position/frame xxHash coverage, strict >0.5 cutout, nonopaque sidedness and opaque traversal flags now match the reference adapter contract. Candidate material opacity is evaluated at the actual hit. Source tests exercise textured opacity and procedural discard in actual ray queries; earlier endpoint tests and native winding checks are retained. |
| T04 | Removed AMD arbitrary instance/light/emitter collection caps; buffers grow with the supported scene. Unsupported shader/scene/light classes are reported and skipped individually rather than suppressing supported GI. The GPU fixture passes 1025 analytic lights plus an emitter, shrink to one light, unsupported-shader isolation and zero atlas allocation. Additional scene classes remain deferred completeness; omissions are explicit, not claimed as support. |
| T05 | Sky orientation, ordinary mip conversion, cone filtering and native composition corrections are retained. Final combined sky-removal checks pass: receiver maximum 0.035294 at 64 frames, exactly 0 at 128/256. A source-checked counterexample disproves the old assumption that AMD guarantees removal within 64 display frames: decay depends on tile updates. The early residual remains reported; no reset/history-policy shortcut was added. The combined regression also passes gain, orientation, color response and exact disabled restoration. |
| H01 | First sampling frame is 0. Tile scheduling now uses a separate frame-local atomic claim: hash-slot and timestamp winners can differ, so using either as a scheduling claim duplicated active cells under pose/FSR2 changes. The old failing log is retained; the new deformation run passes all cell/hit ownership diagnostics. Resize/disable and light-settings lifetimes exercised. The final lifecycle fixture additionally passes abrupt camera replacement and a second viewport creation/resize/destruction without resetting the main camera history. Sampling starts at 0 and skips UINT_MAX on wrap as in Capsaicin. This does not certify every target-hardware presentation/upscaler configuration. |
| H02 | Occupied world-cache tiles now have packed persistent lists and indirect purge, replacing repeated full hash-table purge scans. Active tiles, registered hits and probe schedules feed indirect work. Reservoir compaction now visits registered primary/secondary hits in the baseline path. Probe radiance/SH/cache, diffuse histories and glossy histories use packed backing storage. Required hash resets/scans and dense image/probe stages remain; no target-hardware performance parity is claimed. |
| H03 | Existing lazy Vulkan/Forward+ gating, shared BLAS/separate GI TLAS, disabled teardown and upscaler integration retained. New inputs require eight MRTs, eleven storage-image bindings and 16-bit storage support. Disabled integration exercised; literal measured zero CPU instructions is not claimed. |
| H04 | Shared geometry uses device addresses with explicit RD read dependencies and transfer synchronization. Native source attributes are copied on source revisions when their original buffers lack device addresses. No duplicate triangle vertex atlas or CPU mesh readback is added. Source material resources are released with the disabled consumer; compilation/first-use and hardware costs remain unmeasured. |
| O01 | Deferred completeness: split reflection estimator controls. |
| O02 | Deferred completeness: optional reference controls/debug switches. Existing fork quality deviations are not baseline equivalence. |
| O03 | Deferred completeness: reference visualizers/statistics. Existing validation readbacks remain explicitly opt-in. |
| O04 | Native surrounding renderer services retained within the existing requested scope. D03/T05 approval/qualification is not silently waived. |

## Validation and limits

- Reference finite-input helper fixture: 4,096 cases, zero failures. It does not test the whole renderer or newly corrected source-material access.
- Quarter-budget integration: accepted center/cache ownership, all registered hit membership and multibounce ownership pass through still frames, camera motion and resize. The compact-dispatch version also passes these diagnostics. The expanded fixture includes an empty-screen dispatch case.
- Sole-emitter test after light-settings correction: explicit receiver energy 0.027713, hit-only 0.023322, removed 0; all four off phases 0, on phases 0.019100–0.024515. Its earlier “never reset” assertion contradicted the pinned reference zero-light settings transition. The replacement assertion requires exactly nine settings-only resets; existing image thresholds were not loosened. This is a controlled room result, not the game's electrical hazard.
- Multi-light regression after native weighted feedback, compact visibility and fused light bounds: gain ratios 0.924903 and 0.918257, differences 0.003435 and 0.002530. World reservoir reuse and allocation toggling pass; zero-indirect and disabled controls are exact. The earlier zero-indirect and dispatch-row failures are retained. Evidence: `feedback-bounds/run.log` and `feedback-bounds/score.log`.
- Historical sky test: black-sky receiver maximum 0.058824 after 64 frames exceeded the original 0.02 threshold. The subsequent source investigation established that this deadline is not guaranteed by AMD; the extended final test and the retained 64-frame residual are reported below. No engine history shortcut was introduced.
- Shared-geometry integration passes cache/hit/continuation diagnostics, zero-work screen, odd-size resize and disable. Opacity endpoints pass: zero/hidden MAE 0.000386, one/opaque 0.000321, fractional coverage lies between them.
- Reflection regression passes at its required 641×359 fixture resolution: 733 reflected emitter pixels in the mirror, motion shift 13.727 pixels, return overlap 0.989, vacated-region residual 0/0, half/full MAE 0.002550, compact/direct linear-RGB MAE 0.000960. The first invocation used 321×181 against fixed 641×359 scorer regions and was invalid; its failed ROI score is retained in the record and not interpreted as a renderer result.
- Manual/automatic exposure integration passes: restoration MAE 0.005276, accumulated glossy history, only initial-frame reset. This exercises the exposure input and history lifetime, not a paired Capsaicin dynamic-exposure oracle.
- Source-normal GPU fixture: 36 cases pass, maximum vector error 0.00005052 against authored CPU normal expectations. It covers normal-only, normal/tangent and compressed source formats; unindexed, 16-bit and 32-bit indices; rotation, positive nonuniform scale and two mirrored bases. The local-RD fixture completes test-buffer uploads explicitly; the production path uses GPU buffer-read dependencies without readback. The initial unsynchronized fixture failure is retained separately.
- Source-normal quarter-budget integration passes cache ownership, all-hit membership, continuation, empty-screen dispatch, resize and disable. Four/eight-weight posed meshes match independent static baked references: GI display-RGB MAE 0.001191/0.002384, direct MAE 0.000008/0.000918. Eight-weight coverage includes alternating FSR2 pose buffers. Existing image thresholds are unchanged.
- Source-normal reflection regression also passes: 344 GPU-checked frames, 733 reflected-emitter pixels, restoration MAE 0.002420, moving-emitter shift 13.823 pixels, return overlap 0.989, vacated residual 0/0, half/full MAE 0.002483, compact/direct linear-RGB MAE 0.000861. Denoising and the quarter diffuse-ray budget remained fixed. The native winding fixture additionally passes 48 front/back ray queries, including mirrored instances.
- Persistent ray records now use 48 bytes: actual query point/distance, sampled direction/cache key and packed visibility. Expanded shading data, including distinct normals, is local to the shader. Source metadata uses 160 bytes for shared geometry addresses, source-normal layout and transforms. No target-hardware performance claim is made.
- Source-material replacement now evaluates generated native shader helpers, native uniform/texture resources and GPU-copied source attributes. Affine emitter filtering is corrected; arbitrary custom-coordinate filtering remains outside the qualified subset. Initial shader integration failures are retained in `source-material-first/` and `source-material-marker/`; neither is a passing renderer test. The atlas is now retained only for the uncached legacy transport validator; current AMD preparation bypasses it.
- Runs and completed scorers are recorded separately in the evidence directory. An image file or “capture finished” line alone is not a passing image-quality test.

All new integration captures use the default quarter primary budget and enabled denoising. Controlled small fixtures are correctness tests, not requested game previews. No higher primary sample count has been used to represent these corrections. Future game previews remain Crossroads, native-resolution FSR2, PNGs in the preview directory.

### Source material and direct-update follow-up

- `source-atomic-binding/`: combined quarter-rate integration passes with hit ownership, atomic sums/counts, cache LRU, multibounce, motion, empty-screen, odd resize and disable checks. Failed intermediate shader/binding attempts are retained separately and are not passing evidence.
- `firefly-bounds/`: 344 reflection validation frames pass. Offscreen emitter: 733 mirror pixels; movement 13.823 pixels, return overlap 0.989, no detected vacated-region ghost. Half/full display-RGB MAE 0.002438; compact/direct linear RGB MAE 0.000838. This validates the filter correction under the fixture, not the user hardware or all nonfinite inputs.
- The source emitter/atlas-removal binary builds (`build-source-lod.log`, 72.74 seconds locally). Its material diagnostics report zero resident capture pages, zero draws/copies and zero atlas layers/bytes. Its emitter regression passes: explicit receiver energy 0.029161, hit-only 0.024098, removed 0; all off phases are zero and all nine reference settings transitions are verified.

### Latest combined evidence

- `packed-final/`: packed histories and reference-order injection pass hit/cache/continuation ownership, occupied-tile bijection, empty-screen work, odd resize and disable.
- `packed-reflections/`: 344 checked GPU frames pass; 733 mirror emitter pixels, 13.858-pixel motion, return overlap 0.989, no detected vacated residual, half/full MAE 0.002545, compact/direct linear MAE 0.000930. This run predates restoration of in-place cleanup; `combined-reflections/` below supplies that rerun.
- `source-approved/`: 256 native material GPU samples pass, maximum component error 0.00000279. Dark emission and removing the emission program write are separate tested phases.
- `collection-growth/`: 1025 analytic lights plus an emitter grow/shrink correctly; an unsupported derivative shader does not suppress two supported surfaces. All atlas/preparation/draw counters are zero.
- `distance-fixed/`: 20 GPU cases import the production packing/bin functions and verify exact low/high sum words for 1, 6, 7, 64 and 1024 samples at distances 1, 50, 65504 and 1e9. RGB stays unchanged. The initial fixture parse failure is retained in `distance/`.
- `exception-proofs/sky_decay.py`: source-checked CPU algebra shows why 64 display frames is not a reference guarantee. `packed-sky-fixed/score-extended.log` reports both the residual at 64 and exact removal at 128/256; the original failing score remains evidence of the earlier test criterion.
- `check_native_motion.py` checks 4096 finite native row-matrix/jitter/reprojection cases, maximum world-position error 4.263e-14. This is CPU algebra, not a replacement for GPU pose and FSR2 tests.

- `source-final/`: all 256 GPU samples pass after emitter half-UV packing and vertex-LOD isolation, maximum component error 0.00000142. Vertex texture reads are part of the authored albedo oracle, so a leaked cone LOD would fail this test.
- `lifecycle-final/`: hit/cache/continuation diagnostics, abrupt camera replacement, a second viewport creation/resize/destruction, empty-screen dispatch, odd primary resize and disabled teardown pass.
- `deformation-registered-hit/`: GI MAE 0.001130/0.002276 for four/eight weights; direct MAE 0.000008/0.000918. Both pose formats, blend shapes and FSR2 buffer alternation pass after accepting registered zero-length reconstructed hits. The two preceding failed runs are retained; their diagnostic isolated this dropped-hit bug.
- `combined-reflections/`: 344 checked frames pass with AMD's in-place cleanup restored; compact/direct linear MAE 0.000901.
- `combined-lights/`: identical/varied resampled-to-fresh gain 0.929269/0.900644; MAE 0.003341/0.003201. Allocation toggling and exact direct-only controls pass.
- `combined-emitters/`: explicit receiver energy 0.026938, hit-only 0.022132, removed 0. All off phases are zero; on phases 0.019051–0.025079, with exactly nine reference settings transitions.
- `combined-sky/`: removal maxima at 64/128/256 frames 0.035294/0/0; gain 0.333953, occlusion response 0.113938, orientation response 0.047100. Disabled restoration passes.
- `flat-grid/`: the twenty distance cases and five point/line/plane/tiny-positive/volume grid cases pass using the production shader helpers.

The owner subsequently approved the bounded affine input extension. Its tests and
remaining native-material limits are recorded in the follow-up below.

- `reflections-final/`: the final registered-hit/material build passes 344 GPU-checked frames. Mirror emitter pixels 733, emitter shift 13.671 pixels, return overlap 0.989, no detected vacated residual, half/full MAE 0.002376, compact/direct linear MAE 0.000951. Denoising and the quarter primary budget remain enabled.

### Affine emitter follow-up — 2026-10-24

`/workspace/gi-validation/amd-emitter-coordinates/final-mapped/` passes 704 GPU
samples with maximum component error 0.00008534. `ordinary/` passes the existing
256 source-material samples, error 0.00000142. `room/` passes with explicit/hit-only
receiver energy 0.027311/0.022281, zero removed/off energy and nine reference
settings transitions. `limits/` completes without renderer errors and explicitly
diagnoses all five unsupported mapping cases; this validates warnings, not their
filtering correctness. No primary ray-budget increase or disabled denoiser was used.
The initial fixture attempted a forbidden fragment UV write, and the first limits
fixture lacked a WorldEnvironment; neither is passing evidence. Corrected fixtures
are retained in the repository. No target-hardware timing claim is made.


<a id="snapshot-amd-gi-full-comparison"></a>

## Snapshot: docs/AMD_GI_FULL_COMPARISON.md

# Complete AMD GI source comparison — 2026-10-23

**The source comparison is complete. The implementation is not a faithful, complete AMD GI baseline.** Several central equations are present, but important inputs, default paths, history policies, material evaluation and optional algorithms differ. Earlier descriptions of a stage as “translated” or “restored” must not be read as establishing its equivalence. This report supersedes those conformance claims in the historical [correction ledger](#snapshot-amd-gi-reference-audit).

No renderer code was changed, no build was started, and no new gameplay investigation or preview was performed during this audit. No deviation is approved by this report. Where the fork differs, the default disposition is to restore AMD behavior. Proposed exceptions are explicitly separated below and require the owner's approval before adoption.

Live implementation status is tracked separately in [consequential corrections](#snapshot-amd-gi-consequential-corrections).

**Correction-work erratum:** L05 overstated AMD's light-index reset policy. See [adapter decisions and source trace](#snapshot-amd-gi-adapter-decisions). The frozen evidence remains unchanged; this report is the pre-correction baseline, not the current implementation status.

## Baselines and meaning of completion

- AMD: [Capsaicin commit 914b91596cd119eda85fbc1d3c7ee6ac391b1452](https://github.com/GPUOpen-LibrariesAndSDKs/Capsaicin/tree/914b91596cd119eda85fbc1d3c7ee6ac391b1452). The package is v1.3; the actual renderer registers itself as **GI-1.2**. This is the pinned implementation being compared, not a claim to have checked every later upstream revision.
- Fork: **d932f4ac0260c49ebd1dbbc61db9b8580726dcf0 plus the existing uncommitted environment/cone/reservoir follow-up**. The working tree is deliberately included rather than assuming HEAD describes all available code. See the frozen manifest and pre-audit patch in the evidence directory.
- The published Windows clang artifact from [run 39992968091](https://github.com/automata-rtx/godot-rt/actions/runs/39992968091) is d932f4a. It does **not** include that uncommitted follow-up. Findings about the converted cubemap and corrected cone/reservoir targets therefore describe local source, not the executable previously supplied to the owner.
- Evidence: `/workspace/gi-validation/amd-source-audit-2026-10-23/`. `fork-state.json`, `amd-state.json`, and `*-working.patch` freeze revisions and preexisting changes. `source-manifest.json` hashes 131 source/dependency files. `coverage.json` inventories all **70 function definitions in AMD's gi1.comp**, companion shaders, all **51 fork pass identifiers**, shader definitions, **38 GI options**, **19 dependency options**, and **29 Godot GI settings**. `checks.json` records the independent checks described below. The portable [coverage appendix](#snapshot-amd-gi-comparison-coverage) maps the stages and every option.

“Complete source comparison” means every GI stage, host contract, dependency family, default/nondefault mode and integration boundary has a disposition. It does **not** mean the two renderers have been proven equivalent. They demonstrably are not. The list below includes differences whose numerical or image consequence needs a controlled test; those are recorded as differences/uncertainties, not silently declared acceptable. A function inventory proves coverage of the inventory, not algorithmic correctness.

Scope includes GI-1.2's probes, hash cache, multibounce, GridStream light sampling, optional world-space reservoir reuse, reflection paths, both denoisers, near-field SSGI dependency, material/geometry/alpha/light/environment inputs, final composition, history/resource lifecycle, diagnostics and quality controls. Other Capsaicin renderers and unused generic sampling-library algorithms are not additional requirements of GI-1.2. The alternative split reflection estimator and optional GridStream modes *are* included because GI-1.2 exposes them.

## What actually matches

These are specific matches, qualified by the findings below; none is a whole-stage certificate.

| Area | Present reference behavior | Qualifications |
| --- | --- | --- |
| Probe budget and representation | 8×8 angular probes, dense 8-pixel screen lattice, quarter-budget spawning on 16-pixel tiles, adaptive hole patching, equal-area hemisphere mapping, Halton candidate sequence, nine SH coefficients, temporal radiance reuse and an off-screen probe cache | P01–P09 change actual reuse, filtering, inputs and output scale |
| Random data and samplers | Reference old-state PCG construction, four extracted blue-noise dimensions, reference frame rotation; bounded VNDF and corresponding PDF; rough dielectric continuation BRDF | Same generators do not imply same random-number routing or consumption (P06, C04, L04) |
| Radiance cache | Directional hashed tiles; default 2^14 buckets × 16 tiles; 8→4→2→1 cell mip chain (85 cells/tile); 32-pixel footprint, 0.1 minimum cell; quantized integer RGB accumulation at ×1000; packed half history; 16-sample update cap and touched-tile zero-update aging | C01–C06 and T01–T05 affect membership, radiance and timing |
| Multibounce | Default enabled; stochastic continuation probability 0.3; second hit's freshly updated direct cache; indirect contribution made available through delayed cache updates; intentionally rough diffuse secondary material treatment exists in AMD too | This is iterative cached propagation, not a fixed full path-tracing bounce count. C04 covers precision, sample sequence and bypass-index differences |
| Default light sampler | Shared analytic/triangle/environment proposal list; GridStream 16 cells along largest axis, 64 strided reservoirs/cell; expanded/jittered cell sampling; eight candidate segments merged without replacement | L01–L06 change actual domains, light values, zero-weight behavior and reuse |
| Optional world-space reuse | Separate spatial hash, hit reservoirs, collision search, normal/position tests, prefix compaction and resampling; default off as in AMD | Not a complete implementation of AMD's branch semantics (L04–L05) |
| Default glossy reconstruction | Separate 0.2/0.6 roughness thresholds; traced low roughness, stochastic four-probe lookup at intermediate roughness; half-resolution phase; compressed-radiance ratio estimator; moments, four a-trous passes; dual virtual/surface temporal histories and vignette-limited accumulation | R01–R06 affect fallback, feedback, inputs, storage and boundaries |
| Firefly cleanup | AMD's default low/high thresholds 0/1; marking radii 3/2 and cleanup radii 2/1 for half/full resolution | R05; not a guarantee of acceptable moving-emitter behavior |
| Diffuse denoiser helpers | Reference accumulation/eviction formulas, relative-view-depth spatial weighting, pre-update blur timing and two spatial passes | D01–D03: the values fed to those helpers and storage differ |
| Native integration | Vulkan ray queries, Forward+, shared shadow BLAS, separate GI scene, per-viewport resources, GI outputs before temporal upscaling, live settings, lazy construction and disable teardown | Required integration architecture exists; H/T findings prevent calling it fully qualified |

## Probe placement, reuse, filtering and reconstruction

Reference locations in this section are under `src/core/src/render_techniques/gi1/`; fork shader locations are under `servers/rendering/renderer_rd/shaders/effects/`.

| ID | AMD behavior and fork difference | Consequence and correction expectation |
| --- | --- | --- |
| **P01 — accepted center reuse never counted** | `gi1.comp:SampleScreenProbes` increments the accepted-center count (line 744) before deciding whether to evict (762). Fork `amd_gi.glsl:prepare_probe` declares the shared `center_reuse_count`, initializes it at 835 and tests it at 892, but **never increments it**. A whole-file occurrence check confirms this. | The fork can take the eviction path despite reusing its center. Restore AMD's count/decision. Expected to remove unjustified evictions and cache churn; this alone does not prove the reported periodic stutter's cause. |
| **P02 — different probe spatial filter** | AMD `FilterScreenProbes` (1357) uses hierarchical `ScreenProbes_FindClosestProbe`, alternating offsets −1,+1,−2,+2,−3,+3, full cell-footprint plane tolerance and linear view-depth weighting. Fork `filter_probe` (1337) reads direct dense indices, iterates −3…+3, uses **0.1× footprint** plane tolerance and radial eye distance. | This changes which probes contribute and their weights, not just implementation order. Restore the hierarchical search and exact acceptance/weight rules. Expected to recover AMD's spatial support and reduce unsupported discontinuities; smoothing/leak behavior must be compared dynamically. |
| **P03 — SH normalization differs** | AMD `ProjectScreenProbes` (1446) accumulates each angular sample with `radiance / probe_size` (1/8). Fork `project_probe` (1379) uses `2π/64`. AMD cosine convolution then final `ResolveGI1` divides diffuse by π. Fork convolution already includes that division and Forward+ multiplies the output by albedo without compensating the projection factor. | For identical probe radiance, full-hemisphere convolution and before half rounding/native BRDF differences, **fork/AMD diffuse scale = π/4 ≈ 0.785398**. This is an algebraic comparison, not a measured whole-frame brightness ratio. Restore AMD units through projection, interpolation, denoising and composition together. Expected to restore the reference energy scale. |
| **P04 — mask hierarchy and scheduling** | AMD uses native mip dimensions (floor-halved, minimum 1) and clamped hierarchical coordinates. Fork `mask_dimensions`, `filter_mask`, `closest_probe` use ceil-halving without the same lookup clamping. AMD builds the hierarchy before probe filtering; fork builds it after filter/project and its filter does not consume it. | Odd internal dimensions and partially populated neighborhoods can choose different probes. Restore dimensions, bounds and dependency ordering, including awkward sizes used by FSR/DLSS. |
| **P05 — interpolation fallback threshold** | AMD `InterpolateScreenProbes` falls back when `dot(weights,weights)==0`; fork `interpolate_pixel` uses `sum(weights)<=1e-5`. Fork adds depth denominator guards and some boundary comparison differences. The reflection four-probe path uses the zero test instead. | Weak but valid diffuse weights can become uniform relaxed weights with reduced history confidence. Restore the reference finite-domain behavior; treat any exceptional-input guard separately. Expected to avoid fork-only fallback transitions. |
| **P06 — sample routing and CDF consumption** | AMD RNG IDs follow compacted live probes/hits. Fork retains fixed slots including skipped/sky slots. AMD consumes the diffuse CDF variate unconditionally and normalizes by `max(total,1e-5)`; fork consumes it only with valid history and positive total and samples an unnormalized CDF with `u*total`. First-frame numbering also differs (H01). | Generic RNG helper equality does not establish identical samples. The near-zero CDF case changes more than sample ordering. Restore the reference sample domains, draw order and fallback semantics; expect the intended spatial/temporal sample distribution, not a guaranteed per-frame noise reduction. |
| **P07 — reprojection and packing inputs** | AMD reconstructs previous world position at continuous reprojected UV using sampled depth. Fork often uses a stored position at the selected integer pixel center. Cached AMD normals use packed-normal precision; fork stores float normals derived from native buffers. Radiance is half-rounded in many corresponding stages, but input and intermediate rounding points still differ. | Boundary acceptance, angular bins, parallax and history weights can differ even when helper equations match. Align each input contract and round-trip point, including moving/deformed surfaces and jitter. Expected to make history rejection correspond to AMD rather than merely look similar in a settled still. |
| **P08 — off-screen cache allocation/LRU** | AMD bins cached probes using `uv*ceil(size/8)` and uses LRU rank, allocation count, claim invalidation and append order. Fork bins with `uv*size/8`, allocates unmarked physical slots, preserves old ordering differently, and resolves existing claims/evictions differently (`find_cached_probe`, `order_cached_probes`, `store_cached_probe`). | Partial edge tiles and allocation conflicts do not select/retain the same history. Restore the full allocator/claim/reorder policy, not just an “LRU” label. Expected to retain the same useful off-screen history under motion. The updated-entry flag is **not** independently claimed as a bug: AMD also distinguishes updated entries from newly appended MRU entries. |
| **P09 — default near-field SSGI missing** | AMD `renderers/gi1/gi1_renderer.cpp` explicitly runs **SSGI before GI1**. `ssgi.comp:Main` supplies horizon-based occlusion, bent normal and near-field previous-lighting integration; default one slice, two steps, radius 0.2, falloff 0.05. `InterpolateScreenProbes` adds that near-field GI and evaluates SH over the bent visibility cone. Fork has no corresponding path and evaluates full-hemisphere SH. | VBAO is not this radiance-plus-bent-cone stage. Restore AMD's stage and composition, then account for the game's AO without inventing a replacement. Expected benefits are near-field indirect detail and directional occlusion of probe lighting. The effect on an existing VBAO-authored look must be shown, not assumed equivalent. |

## Radiance cache and multibounce

| ID | AMD behavior and fork difference | Consequence and correction expectation |
| --- | --- | --- |
| **C01 — decay boundary** | AMD `PurgeTiles` discards at age **>=50**; fork `reset_cache` uses **>50**. The touched-tile temporal update and zero-update aging formulas otherwise track the reference. | Tiles survive one extra frame. Restore the reference lifetime. This is a small definite difference, not evidence that it causes all flicker. |
| **C02 — hash lookup and coordinate bounds** | AMD `HashGridCache_FindCell` stops on the first empty hash slot. Fork `find_tile` scans past an empty slot. Fork also clamps local cell coordinates to 0…7 and packs a level into eight bits instead of preserving AMD's full-width representation. | Lookup after deletion/collision and extreme-domain behavior differ. Restore AMD behavior unless a separately demonstrated upstream defect justifies a proposal. A plausible robustness improvement is not approval. |
| **C03 — work representation and sample membership** | AMD compacts cache-visible hits and uses atomic fixed-point accumulation. Fork uses fixed ray slots, per-hit records and linked-list reductions. For **the same quantized contributions**, uint addition is commutative and can match; compaction IDs, overflow membership, ordering and rounding before quantization are not established equivalent. `cache_all_hits=false` additionally shades only an owner subset. | Keep the arithmetic identity narrowly stated. Restore reference work/sample membership. Owner-only mode is an explicit quality deviation, not AMD's default algorithm. CPU/GPU work cost of the fixed-slot/full-capacity passes is not equivalent to AMD's indirect compacted dispatches. |
| **C04 — continuation, packing and bypass handoff** | Both continue 30% of paths, but AMD accepts `u>0.7`, fork `u<0.3`; the same seed selects different paths. AMD packs BRDF/PDF for the later multibounce update; fork recomputes at full precision. Fork explicitly applies a short-secondary connection bypass. AMD `UpdateMultibounceCells` reads the bypass flag from `VisibilityRayBuffer[did2]`, while that buffer's writing path uses compacted visibility-ray indices. | Restore random consumption and packing. The **index-domain discrepancy is recorded, not declared a proven AMD bug**: reference and fork code are not mechanically equivalent here, and an isolated upstream execution/oracle is needed to establish the reference output for mixed bypass/non-bypass hits. No speculative fix is authorized. Expected benefit of aligning the rest is correct path weights and reference temporal propagation. |
| **C05 — additional radiance sanitization/clamp** | Fork `clean_color` zeros a whole vector for any nonfinite channel and clamps RGB to 0…60000 at many transport stages. AMD uses its compress/saturate/uncompress NaN handling at specific stages, with a different effective upper range. Half storage and fixed-point overflow further bound both implementations differently. | Bright emitters and outliers can have different energy before sampling, accumulation and filtering. Restore the reference handling and placement. Do not sell this as a firefly fix; arbitrary energy clamps can hide estimator errors. |
| **C06 — emissive-hit termination predicate** | AMD tests base material emissivity/front-face before texture evaluation and terminates that primary emissive path even if the sampled texel is black. Fork tests final captured emission after sampling. Secondary rough diffuse overrides and excluding separately accounted emission/sky are intentional in AMD. | Black texels on an emissive material can take different transport branches. Restore the predicate and partitioning, together with exact material access. Expected to prevent fork-only path accounting changes. |

## Light sampling, emitters and world-space reservoirs

| ID | AMD behavior and fork difference | Consequence and correction expectation |
| --- | --- | --- |
| **L01 — GridStream input domain** | AMD requests grid bounds from successfully registered cache hits. Fork `light_grid_bounds` includes all valid primary/secondary hits, including cache-registration failures. AMD includes emissive hits if registration succeeds; they are **not** categorically excluded. Fork clamps degenerate extents to 1e-5. Fork always reserves an environment proposal; AMD's live light list follows environment availability/settings. Light ordering also differs. | Cell sizes, partitions and candidate sequences can differ despite matching stream-selection equations. Restore actual bounds membership and light-list semantics. Assess a finite degenerate-bounds rule separately rather than folding it into “identical.” |
| **L02 — analytic light model and visibility** | AMD's glTF light evaluation uses its point/spot range and angular formulas. Fork uses Godot range/decay, spot attenuation, energy conventions, layers, shadow masks and shadow opacity. Native direct lighting/RT shadows remain the primary-lighting path. GI negative-light handling is not equivalent to signed native lighting because transport is nonnegative/clamped. | Native light compatibility is a real integration requirement, but it changes both target radiance and proposal weights. A narrow proposal is below; this does not justify changing GridStream or reservoir math. Projectors/distance fade and unsupported native light classes remain incomplete (T04). |
| **L03 — emissive texture evaluation and proposal construction** | AMD samples actual triangle UVs, alpha-scaled emission and cone-dependent texture LOD; its volume proposal uses the reference light-volume estimate. Fork samples a tiny per-triangle atlas at LOD0, uses captured emission averages and a capped emitter list. Uniform triangle square-root sampling and the area-measure geometry/PDF relationship are present. | Fine emissive detail and changing emission enter a different proposal distribution and final radiance. Restore actual UV/material evaluation and AMD cone/volume semantics. Expected to reduce aliasing-driven estimator variation; not a promise that rapidly blinking lights become noiseless. |
| **L04 — zero-weight, confidence, packing and RNG branches** | AMD reservoir update consumes a variate and increments M even for zero targets; fork `gi_reservoir_add` returns early. AMD fresh reservoir can retain original M on an early no-history return; fork initializes reuse confidence to 1. Fresh merge versus lookup-offset draws occur in a different order. Fork can search old history when the fresh selected ID is invalid, while AMD skips queueing such an entry. AMD packs material (gamma RGB565 plus 8-bit metalness/roughness with specular enabled; RGB10 without) and normals before later reuse; fork does not reproduce all those round trips. | Reuse probability, history population and weights differ, especially around disappearing, blocked or zero-contribution lights. Restore branch-by-branch behavior and packing, not only the positive finite formula. The local cone/fresh-target/invalidation corrections improve specific branches but do not close this finding. |
| **L05 — light-identity history policy** | Fork remaps persistent light IDs and rejects incompatible individual entries. AMD's host invalidates reservoir hash history when LightBuilder/GridStream reports index/settings changes. | The fork deliberately retains a different population of samples when lights are added/removed/reordered. There is no approval to retain this policy. Restore the AMD baseline; any later preservation policy needs an evidence-backed proposal showing estimator validity and a benefit. |
| **L06 — optional sampling alternatives** | The default GridStream configuration is implemented with differences above. Octahedral directional cells, local target resampling, random-reservoir selection, with-replacement merge, parallel many-light build, centroid build and overlap weighting are not implemented. Uniform environment sampling is present; optional cosine/importance environment sampling and low-emission area-light culling are not equivalent/exposed. | These are explicitly missing **nondefault** AMD modes, not explanations for every default artifact. Implement them if claiming complete exposed AMD functionality. The separate CDF/uniform sampler components are alternative framework components, not extra stages secretly used by default GI1. |

## Glossy reflections and diffuse denoising

| ID | AMD behavior and fork difference | Consequence and correction expectation |
| --- | --- | --- |
| **R01 — rough reflection fallback has extra π division and wrong input** | For high roughness, AMD `gi1.frag:ResolveGI1` uses the **filtered diffuse irradiance** divided by π. Fork `reflection_probe_value` recomputes unfiltered probe SH and divides `probe_irradiance` by π although that function already returns E/π. | Independent of P03, there is an extra inverse-π factor and missing diffuse filtering. Combined with P03, identical probe input gives a **1/4 reference scale before primary BRDF and rounding**, not a prediction for every rendered pixel. Restore filtered irradiance reuse and units. Expected to restore rough-reflection energy and stability. |
| **R02 — reference reflection feedback disabled by default** | AMD `TraceReflectionsHandleHit` always tries valid previous combined lighting, independently of the optional diffuse temporal-feedback setting. Fork `screen_lighting` returns immediately unless `screen_feedback` is enabled; that setting defaults false. In the optional diffuse mode, AMD disables temporal feedback when multibounce is on; fork instead permits feedback when multibounce **or** reflections is on, and suppresses it for incompatible native indirect-energy settings. The owner-only cache branch also does not run the same all-hit feedback path. | Default fork reflections fall back to the radiance cache when AMD would use valid visible previous lighting. Decouple the two paths and restore AMD's reflection behavior and diffuse-feedback/multibounce exclusivity. Expected to recover visible-surface lighting detail and reduce unnecessary dependence on coarse cache estimates. |
| **R03 — feedback validation uses wrong previous normal contract** | AMD reflection-hit feedback compares hit normals against `PrevGeometryNormal`. Fork `screen_lighting` reads `previous_pixels.normal_delta`, written with the **shading normal** in `interpolate_pixel`. It also rejects relaxed diffuse confidence (`old.position.w != 1`) and adds current-visibility/coverage checks absent from the same AMD test. | Normal maps and diffuse interpolation fallback can reject otherwise valid previous lighting. Restore the actual reference inputs and acceptance tests. **Correction to an early audit suspicion:** the reflection *temporal denoiser* correctly uses shading/detail normals on both sides; the geometry/detail mismatch is in hit-lighting feedback, not that temporal-history test. |
| **R04 — reflection storage/precision and reconstruction representation** | AMD stores raw specular, direction, resolved color, deviation and history in half textures; fork uses FP32 SSBO records for several of these and half textures for intermediate filters/moments. AMD stores camera-relative hit information in half; fork retains world-space floats and reconstructs. Tap loop nesting and accumulation order also differ. | Different rounding can change firefly marks, moments, temporal rejection and memory/bandwidth cost. More precision is not automatically a justified departure. Restore reference packing/round-trip semantics unless a particular representation is approved with measured benefit. |
| **R05 — cleanup boundaries and fallbacks** | Fork uses immutable scratch input and explicit out-of-bounds handling where AMD's cleanup accesses a writable image with its API's load semantics. For tiny total weights, AMD adds a center contribution to the partial neighborhood and normalizes; fork replaces partials. Fork also guards zero roughness sums and some sky/invalid neighborhoods differently. Default marking thresholds and radii match. | Edge pixels and degenerate neighborhoods can differ. Restore finite, defined AMD cases. Explicit Vulkan boundary safety is a narrow proposal below; this report does **not** assert a proven upstream data race or approve a different filter. |
| **R06 — denoiser modes and controls incomplete** | AMD offers split-ratio X/Y, a-trous and no-reflection-denoiser modes with independent reflection controls. Fork has a-trous and a globally coupled `denoiser=false` path, not independent mode parity. Split-estimator radii/options and separate half/full threshold controls are missing or collapsed. | Missing optional functionality is distinct from a broken default. Restore mode/control parity if claiming the full implementation. Turning denoising off is not the proposed normal comparison configuration. NRD and Ray Reconstruction are outside the requested baseline. |
| **D01 — diffuse denoiser units** | AMD denoises irradiance before final Lambert division; fork denoises its E/π-like probe output, additionally scaled by P03. Fixed absolute small-value thresholds and sanitization were copied without a complete unit conversion. | Similar-looking history formulas do not receive equivalent values. Restore end-to-end units, rather than independently adjusting brightness at composition. Expected to restore reference threshold behavior and light response. |
| **D02 — diffuse history inputs/storage** | Previous world position is reconstructed differently (P07); fork normalizes some normals where AMD uses decoded values directly. Fork color sums/deltas use FP32 SSBOs versus AMD half targets; fork blur mask uses half versus AMD SNORM8. | History weights and rounded blur radii can differ. Align these contracts and storage. The two spatial passes, repeated center contribution and pre-update mask timing themselves follow the reference. |
| **D03 — exposure supplied to temporal reflection weighting** | AMD uses `exp2(g_Exposure[0])` from its exposure pipeline in the luminance-difference weight. Fork supplies camera exposure-normalization factor as `params.exposure`; automatic exposure is handled elsewhere in Godot. Cache transport is unexposed and feedback is divided by previous normalization, which is a sensible boundary, but the actual adaptation signal is not the same contract. | Match the reference effective exposure used for history weighting through a deliberate native adapter. A fixed-exposure equation oracle does not cover this. Test exposure changes after correction; do not assume helper equality proves dynamic equivalence. |

## Hit materials, geometry, lights, sky and composition

| ID | AMD behavior and fork difference | Consequence and correction expectation |
| --- | --- | --- |
| **T01 — tiny captured materials replace reference hit evaluation** | AMD fetches triangle vertices, hit barycentrics, UVs and source material textures. Fork `rt_material_capture.cpp`, `rt_material_expand.glsl`, `rt_gi_scene.cpp`, `rt_gi_transport_inc.glsl` rasterize native material data into per-triangle tiles, sample nearest LOD0 and adapt 8→4→2 under capacity pressure. The smallest layout effectively supplies one material sample/triangle. Capture is 8-bit for several channels and half for emission; capture geometry-normal mode bypasses normal-map evaluation. | This is a substantial, unapproved fidelity compromise, not required by Vulkan ray queries or BLAS reuse. It affects albedo, emission, alpha, normal detail and material-dependent sampling simultaneously. Replace it with reference-equivalent hit access for the baseline; support for arbitrary native shader evaluation needs an explicit design rather than silently substituting a coarse approximation. Expected benefit is accurate spatial material/light detail, especially textured emitters and fine geometry. |
| **T02 — scene/ray coverage and normal transport** | AMD ray queries use an effectively unbounded scene (`MAX_HIT_DISTANCE` 1e9, miss sentinels including FLT_MAX); fork gathers a camera-centered AABB and defaults to max distance 50. Distance also participates in probe parallax/cache decisions. Fork reconstructs hit displacement/distance and faces normals toward the ray, while AMD uses hit front-face state and interpolated transformed vertex normals. AMD also separates the triangle geometry normal used for NEE ray offsets from its shading-normal evaluation; fork transport does not preserve that same pair of hit normals. | Missing distant occluders/bounces and different distances/normals change results before denoising. Restore baseline coverage and input semantics. A finite-distance performance setting is a quality departure requiring an explicit fidelity tradeoff, not an invisible default limitation. |
| **T03 — alpha and sidedness** | AMD accepts opaque/cutout alpha with strict `>0.5`, and its stochastic alpha hash uses object-space hit position/frame. Fork uses `>=0.5` and a different hash of origin/direction/instance/primitive/frame. AMD's nonopaque one-sided rejection is not reproduced. Fork forces nonopaque traversal for GI instances even though shared BLAS geometry is opaque. | Cutout/transparent coverage and temporal correlation differ; ray-query work differs too. Restore alpha/sidedness semantics, preserving the native-authoring boundary explicitly. Native alpha hash/scissor settings are not automatically represented by the simplified hit test. |
| **T04 — supported scene and preparation contract** | Fork collection/material preparation has caps: 65,536 GI instances, 1,024 analytic lights, 262,144 sampled emissive triangles, default 128 MiB atlas and a 64-page preparation budget. Unsupported vertex/POSITION/screen/depth/normal-buffer-dependent material behavior, unshaded material cases, multipass/overlay/lightmap cases, nonmesh/GPU-indirect MultiMesh paths, and unsupported projector/distance-fade light behavior are rejected or skipped according to collector/capture branches. Forward-only transparent surfaces may be skipped; other unsupported/over-budget/deferred states suppress the **whole GI result** until ready. `gi_mode=DISABLED` objects are excluded from the GI scene but can remain receivers. | AMD's scene/asset model is different, but whole-scene suppression and lost authored materials are not “complete integration.” They can explain why a map has no GI *in principle*; this audit does not assert which current map triggers which condition. Complete the native adapter and expose truthful readiness/capacity diagnostics. Do not mask the gap with screenshots from only supported scenes. |
| **T05 — environment and final surface response** | The uncommitted follow-up converts Godot's octahedral sky to a cubemap and ordinary half-float mip chain, then uses AMD cone LOD formulas. That is closer than the shipped path, but source orientation/border/filter precision, dynamic sky refresh, separate native diffuse/reflection energy and constant ambient differ from AMD's single environment. Final Forward+ shading uses Godot BRDF/DFG/energy compensation, metallic, clearcoat and AO, rather than literally AMD `ResolveGI1` and its BRDF LUT/dominant-direction diffuse response. Native feedback is stored before fog/tone mapping/upscaling. | Keep representation conversion distinct from lighting-model substitutions. The cube/cone helper checks are useful, but the wider sky regression currently fails. A native material/lighting contract requires a narrow approved adapter (proposal below), with unit, emission, sky and exposure validation. It cannot excuse the P03/R01 scale errors. |

## Host scheduling, optionality and validation coverage

| ID | Comparison | Disposition |
| --- | --- | --- |
| **H01 — frame/history lifetime** | AMD starts frame-index sampling at 0 and resets shared previous buffers through framework resets. Fork increments its per-viewport counter before rendering (first frame 1) and resets validity/configuration without restarting that counter. Option changes rebuild/reset different sets of histories. Light-index changes use L05's custom retention policy. Moving-object dirty-region metadata is still gathered but is not a shader cache-invalidation policy in the audited source. | Per-viewport ownership is required; sampling/reset semantics still need an explicit reference mapping. No finding that ordinary camera motion must globally reset GI is made. Camera cuts, resize, viewport replacement and sky/exposure changes need defined behavior. |
| **H02 — dispatch/resource schedule** | AMD uses append/scan/compact/indirect work and per-stage typed resources. Fork maps this into 51 pass IDs, fixed arrays, indirect reflection compaction, linked-list reductions and broad capacity scans with ordered RD barriers. Diffuse temporal/spatial filtering runs before reflection processing, unlike AMD. Reordering independent work is possible, but R01 does not consume AMD's filtered input. | API/descriptor/barrier changes are necessary; work membership, input age and numeric round trips must remain equivalent. No evidence supports claiming equal performance. Reflection compaction on/off has prior regression evidence but not whole-pipeline source equivalence. |
| **H03 — off gate, shared geometry and backend coexistence** | Native feature is lazy, Vulkan/Forward+ only, single-view, MSAA-off and dependent on RT-capable shadow setup. Shared `RaytracingGeometry` supplies BLAS; GI builds its own TLAS to represent GI geometry beyond shadow casters. Disabling releases GI resources and GI-only BLAS. It excludes SDFGI/SSIL/VoxelGI while active and suppresses SSR when GI reflections are active; it does not rewrite authored settings. FSR2/DLSS consume GI-composited native buffers. | These implement the owner's requested integration scope. Source shows no GI rendering passes/scene collection when disabled; it does not prove literal zero CPU instructions or a measured zero cost. Vulkan-only is explicitly authorized; absence of DXR pipeline/SBT variants is not an unauthorized fidelity shortcut. Native lightmaps/unsupported objects and fallback behavior remain T04. |
| **H04 — acceleration structure/preparation lifecycle and diagnostics** | Shared BLAS handles compressed geometry, skinned buffers, geometry revisions, build budgets and stale eviction. Dynamic geometry uses rebuilds rather than a refit API; GI material capture adds its own residency/update/preflight costs. GI TLAS is separate and updated from its collected scene. Diagnostic readbacks are gated by environment variables. Some unused helpers/comments (`reflection_kernel`, `diffuse_hit_emission`, owner-only wording) no longer describe the default execution. | Reuse exists; equivalent scene contents and performance are not established merely by reuse. Readiness interruptions, capacity/full scans and native preparation must be qualified. Remove misleading dead-path descriptions only during correction, not as an algorithm substitution. |
| **O01 — split reflection estimator** | AMD `ResolveReflections_SplitRatioEstimatorX/Y` and their radius controls are absent. Default a-trous is present with R findings. | Missing optional AMD algorithm, explicitly counted. |
| **O02 — optional light/material/debug switches** | Missing GridStream modes and environment modes are L06. Reference independent alpha/albedo/specular disable switches, direct-light debug behavior and several cache scale/history controls are absent, fixed or tied to native settings. Additional fork toggles can disable importance/adaptive/cache/BRDF/emissive behavior not exposed that way by AMD. | The appendix accounts for every declared option. Matching defaults is distinct from complete optional-feature parity. Nondefault fork quality modes remain departures, not alternate proofs of the baseline. |
| **O03 — reference visualizers/statistics** | AMD provides screen-probe, cache-cell/mip/decay/propagation, reflection views and occupancy/overflow histograms. Fork diagnostic readbacks/test fixtures do not reproduce these visualizers or all six statistics kernels. | Missing diagnostic functionality, not a hidden lighting stage. Relevant to establishing equivalence; must be acknowledged in a complete implementation claim. |
| **O04 — surrounding renderer components** | Visibility-buffer inputs are supplied by native prepass data; direct shading/Combine by Forward+; FSR by native FSR2/Streamline. Atmosphere, skybox, automatic exposure, bloom, tone mapping and lens are surrounding renderer functions, not additional GI transport algorithms to transplant wholesale. AMD declares/binds PrefilterIBL in GI1 but the prefiltered environment texture has no GI1 shader use beyond its declaration; the actual cone path uses the ordinary environment cube. | Preserve native engine services, with the explicit T05/D03 contracts. No missing GI algorithm is inferred solely from an unused binding. Other APIs, NRD, RR and unrelated Capsaicin techniques are outside this requested baseline. |

## Proposed exceptions — none approved

The audit found no justification to retain the changed probe filter, missing near-field stage, normalization errors, coupled reflection feedback, coarse material fallback, reservoir branch changes, changed LRU policy or arbitrary default range as the AMD baseline.

Only the following narrow exceptions have a defensible integration rationale. They are pitches, not decisions or permissions to proceed with a changed algorithm:

1. **Preserve Godot's authored primary material/light semantics at a defined adapter boundary.** Godot assets can specify light decay, spot attenuation, energy, masks and BRDF features that AMD's glTF viewer does not represent. Replacing those authored meanings would change the existing game even with a mathematically faithful GI estimator. Proposed benefit: direct lighting and bounce lighting describe the same authored sources/materials. Cost: final pixels will not equal Capsaicin for materials outside the common model. Required evidence: identical results on the common Lambert/GGX/light subset, and explicit tests for each native extension. This proposal does **not** include tiny material captures, omitted hit data, alternative reservoir equations or added AO replacing AMD SSGI.
2. **Define safe Vulkan behavior only where AMD's access is out of range or arithmetic is undefined.** Use explicit boundary checks/immutable input where the native API requires them, preserving every finite, in-range reference contribution. Benefit: defined portable execution. Cost: edge/degenerate cases can differ from the source API's behavior. Required evidence: parity on valid neighborhoods and documented expected boundary results. No blanket approval of different fallbacks, clamps or presumed “upstream fixes” is implied.

BLAS reuse, Vulkan descriptors, coordinate conversion, per-viewport ownership, optional enable/disable and native temporal-upscaler integration already follow the requested scope. They are not permission to alter sample distributions or lighting energy. L05's persistent-light remapping is not pitched as superior: current evidence is insufficient. C04's apparent index-domain issue is not pitched as an upstream bug fix until demonstrated.

## Checks performed and what remains unproven

This audit performed source inspection and narrow read-only checks, not rendering or performance tuning:

- **Blue-noise extraction:** independently evaluated AMD's Sobol/ranking/scrambling tables at the used base index/dimensions; all **16,384 packed words** in the fork match. This validates the data, not differing RNG call sites/sequence routing.
- **Center-reuse counter:** searched the complete shader; only declaration, zero initialization and read exist. There is no increment.
- **SH/reflection scale:** independently evaluated the coefficients, followed the final composition, and recorded π/4 and 1/4 ratios for identical full-hemisphere probe input. These are algebraic checks with stated assumptions.
- **Coverage and baseline:** generated all main GI shader function/pass/option inventories; hashed the source and checked it remained unchanged during documentation work.

Prior evidence is retained with its limits. The 4,096-case finite-input equation oracle and controlled diffuse/reflection/cache/reservoir/FSR2 regressions establish specific helper/regression behavior, **not AMD input/pipeline equivalence**. Earlier settled Crossroads stills show an appearance improvement over GI-off, not fidelity or temporal stability. The rapid-emitter fixture previously reported residual **2.42% at frame 32 against a 2% limit**. The uncommitted environment directional/mip helper checks passed, but the broader sky fixture failed (recorded gain 0.290043, occlusion 0.140094, rotation 0.041585). These failures are not waived by this audit.

There is no paired whole-pipeline AMD-versus-fork GPU trace/image validation, no representative 780M/5090 performance qualification of this baseline, and no proof that all reported gameplay artifacts share one cause. The source comparison has exposed enough definite mismatches to reject a completion claim without asking the owner to test another intermediate build.

The next implementation work must correct the listed reference mismatches and missing stages, using AMD as the baseline. Any retained exception requires explicit approval. Verification must cover changing lights, disocclusion, camera and object motion, bright emitters, exposure/sky changes, odd dimensions, capacity and disabled rendering work; settled stills are insufficient. Future preview comparisons remain at the owner's **default quarter primary sample per pixel**, denoiser enabled, and native-resolution FSR2 in cloud previews. No increased ray count is a substitute for completing the algorithm.


<a id="snapshot-amd-gi-gameplay-audit"></a>

## Snapshot: docs/AMD_GI_GAMEPLAY_AUDIT.md

# AMD GI gameplay audit — 2026-10-23

**Historical audit of `3038a14`, before the subsequent implementation work.** The audited port is not a valid
basis for judging AMD GI's finished quality or choosing shipping performance tiers.
This audit adds diagnostics and reproductions, not rendering fixes or a new editor
release. Increasing sample counts is not the repair for these failures.

## Scope and evidence

Engine `3038a14b44ccd2f82a876fb16f4cccf0cf93b3b2`, plus opt-in diagnostic logging;
fps-proto `996f0f9` (the pushed sandbox combat encounters and progress saves);
Capsaicin v1.3 `914b91596cd119eda85fbc1d3c7ee6ac391b1452` as the source reference.
Linux Vulkan Forward+, lavapipe, isolated Xvfb. No target-hardware performance or
Windows compiler comparison is established. The user's report was from Clang;
these reproduced defects are present in renderer source independently of compiler.

The controlled room uses 321×181 output and the default quarter primary diffuse
budget, with denoising, multibounce and reflections on. Actual-game diagnostics use
641×359 output and FSR2 Performance, with custom grass and RT soft shadows off to
isolate GI. Other AMD GI controls stay at defaults, including 128 MiB/8-pixel
material storage. Reflection, visibility and continuation rays are additional.
Diagnostic GPU readback intentionally stalls; these runs must not be timed as
benchmarks. All four game runs and the controlled reproduction exited successfully;
that means the diagnostics completed, not that visual acceptance passed.

## Confirmed failures

### Short-lived lights clear unrelated history

`RaytracingGIScene::update_scene()` hashes the sorted light identities and compares
light data. A membership change advances the scene revision; `AMDGI::render()`
uses that revision to reset all histories. Three on/off pulses in the controlled
scene produced six full resets. Toggling the real sandbox flashlight off and back
on produced two. The game's muzzle flash lasts 0.045 seconds and changes visibility,
so this mechanism explains why recovery can outlast the flash.

Light reservoirs currently store frame-local light indices. Simply removing the
reset would permit references to the wrong lights. Repair needs stable identities
or remapping, independent reservoir invalidation, and local response to illumination
changes. Abrupt light direction/intensity changes can also trigger the global cut.

### Moving reflective objects reject their own history

`temporal_reflection()` rejects a sample when its reflected ray intersects any
dirty motion bound. A ray starting on a moving object's surface starts inside that
object's expanded bound, so it rejects its own history. Current reprojection also
uses camera matrices without object velocity. Removing rejection alone would allow
stale history and is not a correct fix.

| Reproduction | Result |
| --- | --- |
| Controlled metal object, 16 moving frames | All 6,109 measured glossy samples had history count 1; no global resets |
| Same object after 32 stationary frames | Mean retained history recovered to 11.50 |
| Actual gold AK in contested building, translated 1 mm/frame for 12 frames with simulation frozen | All 21,225 measured glossy samples had history count 1; no global resets |
| Same view after 24 stationary frames | Mean retained history recovered to 13.41 |

The metric includes visible samples with roughness below 0.5; it is not an image
error metric or an object-ID mask. Freezing simulation lets the renderer keep
accumulating while weapon movement stops, consistent with the reported Escape
behavior. This does not establish the user's exact wall-clock recovery time.

### Material residency causes repeated preparation

The current material cache deletes captures unused in the current scene update.
A hidden emitter loses its prepared geometry and targets; showing it recreates
them. Packed triangle-page ranges can change when earlier surfaces enter or leave,
causing additional re-preparation. `RaytracingMaterialCapture::prepare()` reads the
entire source surface per page through `MeshStorage::mesh_get_surface()`, which uses
synchronous `RenderingDevice::buffer_get_data()` calls. Only output-image readback
is diagnostic-only; source-buffer readback occurs during ordinary GI preparation.

The controlled flickering mesh was prepared on all six appearances. At the real
sandbox spawn, the first 24 stationary draws after the stage marker included 406
page preparations across 11 frames, with no full GI resets. This count excludes
the following weapon equip. The later stationary contested segment had four page
preparations on its first frame and none afterward; frozen segments had none.
This is a concrete stall mechanism, not a measured attribution of the user's CPU
spikes. The screenshot's electrical field really is flickering emissive geometry,
without a dedicated light (`features/hazards/electrical_field.gd`).

Repair needs bounded retained residency, stable page assignments and preparation
that avoids synchronous GPU-to-CPU geometry reads in the rendering critical path.

### Default capacity suppresses GI on larger maps

| Directly loaded map | Default-capacity test |
| --- | --- |
| Crossroads | Suppressed: first failing surface requires 110,240 total tiles; 104,448 available |
| Fieldway | Suppressed: first failing surface requires 130,144 total tiles; 104,448 available |
| Sandbox Hideout | Scene became ready with 75,968 tiles and 20 lights; reported missing illumination remains unresolved |

These requested counts are the first failure, not full-scene requirements. Each
failed map retried preparation on all eight observed GI frames. Crossroads prepared
169 pages before its first failure; Fieldway prepared 17. In this frozen test the
following retries prepared zero new pages, but still traversed/validated the scene.
Do not claim repeated geometry readback on those unchanged failure frames.

Older successful Crossroads captures used 4-pixel tiles and a 256 MiB atlas, not
the defaults. Increasing the cap alone does not meet the requested automatic scene
support or solve capture memory/preparation costs. Failure needs early detection,
bounded retry behavior and a visible status, alongside a scalable material scheme.

## Missing stages with direct relevance to these reports

- **Emissive-triangle light sampling.** The fork's light proposals include only
  sun/point/spot lights. Emission is obtained when a ray happens to hit a triangle
  (and through compatible screen feedback), without explicit emitter sampling.
  Thin bright bolts produce rare large contributions. Upstream GI uses
  `LightSamplerGridStream` and `LightBuilder`, which gather emissive mesh lights.
  Emission support at hits is not equivalent to this sampling support. Adding it
  requires consistent sampling weights/MIS so direct-hit emission is not doubled.
- **Object motion reprojection.** Upstream GI consumes velocity; this port does not
  use it for moving receiver history. Correct previous positions, geometry identity,
  disocclusion and moving-occluder handling are needed across diffuse and glossy paths.
- **Dedicated reflection firefly cleanup.** Upstream `gi1.comp` implements
  `MarkFireflies` and `CleanupFireflies`, dispatched by `gi1.cpp` before ratio resolve.
  This port has ratio reconstruction, clamping and a-trous filtering but lacks those
  dedicated stages. Full resolution cannot fix lost history or rare bright outliers.
- **Remaining sampling/scheduling differences.** Material-BRDF sampling in probe
  tracing, upstream's separate light-grid reservoir arrangement, and adaptive
  reflection ray compaction remain absent or replaced with simpler adaptations.
- **Material and scene completeness.** Fixed 4/8-pixel triangle capture can lose
  detail. Custom vertex deformation, particles and GPU-indirect MultiMeshes are
  unsupported. Layered/anisotropic reflections and general nested specular transport
  are incomplete. Capacity, residency and visibility changes are not robust enough.
- **Acceptance on target machines.** Moving-scene quality, DLSS runtime behavior,
  peak frame time/memory on 5090 and 780M, and disabled-path hardware timing remain
  unverified. FSR2 running successfully does not validate the GI motion signal.

Sparse screen probes, adaptive probe updates, probe reuse, a directional world
radiance cache, analytic-light resampling, multibounce feedback, GGX reflections,
conventional denoising and native composition do exist. Their existence does not
make the implementation complete or establish parity with AMD's reference.

## Symptoms unresolved at the audit checkpoint

The exact rifle/wall box, angle-dependent loss of a whole wall, incorrect spawn-prop
lighting, and Hideout's reported absent GI have not been reproduced visually here.
Coarse dirty AABBs can reject rectangular regions of wall history; probe coverage,
cache invalidation and material capture also need isolated checks. Those are
hypotheses, not confirmed causes of each screenshot artifact. Flashlight-toggle
resets are confirmed; all stationary indirect boiling is not explained by toggles.

The user subsequently requested completion of the intended implementation rather
than following an isolated repair order. Current implementation progress and
remaining validation are tracked in [AMD_GI_IMPLEMENTATION.md](#snapshot-amd-gi-implementation)
and [features/amd-gi.md](#snapshot-amd-gi); this audit preserves baseline evidence.

NRD or Ray Reconstruction is not a substitute for those repairs. Neither is part
of this audit. No sample-count increase or denoiser disablement was used to hide
the reported behavior.

## Reproduction artifacts

The tracked `docs/validation/shadow_validation/amd_gi_gameplay_audit.tscn` is a
defect reproduction, not a passing acceptance test. Run the editor binary against
that validation project with Vulkan at 321×181, setting
`GODOT_AMD_GI_TRACE_HISTORY=1`, `GODOT_AMD_GI_TRACE_REFLECTION_HISTORY=1` and
`GODOT_AMD_GI_VALIDATE_MATERIALS=1`. The new glossy diagnostic reads the actual
temporal output and logs sample count, fresh samples and mean history. It performs
synchronous readback only when explicitly enabled. Do not benchmark with it.

Session logs, aggregate JSON, actual-game harnesses, source patch and a phone-readable
report are saved under `/workspace/preview/amd-gi-gameplay-audit/`. The game harnesses
are diagnostic scripts, not changes to gameplay or authored assets. Use isolated
user-data directories when reproducing because the game saves progress.


<a id="snapshot-amd-gi-implementation"></a>

## Snapshot: docs/AMD_GI_IMPLEMENTATION.md

# AMD GI integration

**Status: the main AMD GI-1.2 pipeline and default-path correction pass are implemented for qualified inputs. Full feature parity and production qualification remain incomplete.**
The [live consequential correction record](#snapshot-amd-gi-consequential-corrections) lists every correction, approved exception, test and remaining input limitation. Optional AMD features remain deferred.
The previous completion statement covered stage presence, not fidelity to AMD.
See [the complete source comparison](#snapshot-amd-gi-full-comparison) and
[coverage appendix](#snapshot-amd-gi-comparison-coverage) for every stage and option.
The [earlier correction ledger](#snapshot-amd-gi-reference-audit) is historical;
its restored/translated labels do not certify reference equivalence.
Cached diffuse GI, sky lighting, and glossy reflections run on Vulkan Forward+.
It implements sparse screen probes, directional hashed world radiance, multibounce
feedback, reconstruction, and temporal/spatial GI denoising. Progress captures use
the default approximately 1/4 primary GI ray per internal pixel per frame, with
denoising on. Earlier one-ray captures remain historical evidence only.
See [the implemented pipeline and explicit port gaps](#snapshot-amd-gi).
Sampling, cache-update and glossy scheduling stages are implemented. Software-Vulkan
integration, controlled motion and game-scene checks are recorded below. Engine-specific
material and scene limits are documented explicitly; this is an adaptation, not a
pixel-identical Capsaicin renderer or a general path tracer.

The [2026-10-23 gameplay audit](#snapshot-amd-gi-gameplay-audit) reproduced full-history
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
[consequential correction record](#snapshot-amd-gi-consequential-corrections) for evidence and remaining limits;
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
[internals/rt-shadows.md](../internals/rt-shadows.md). Sharing with another consumer
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
[internals/rt-materials.md](#snapshot-rt-materials) for resource ownership and
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
a fallback instead of silently disappearing from the traced scene. See [internals/rt-materials.md](#snapshot-rt-materials)
for the representation, limitations, and renderer contract.

The discarded initial draft overwrote UV2 and had unbounded page allocation. Do not
restore that approach. A native material test is required before changing capture
placement or source attributes; checking only StandardMaterial3D colors is insufficient.

### Transport validation checkpoint

See [features/rtgi-validation.md](#snapshot-rtgi-validation) for the runnable scene,
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
[its protocol](#snapshot-amd-gi) records
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
[features/amd-gi.md](#snapshot-amd-gi) records the implemented subset and deviations.

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
in [HISTORY](#snapshot-gi-history) and `amd_gi_scene_churn` / `amd_gi_flashlight` rigs.


<a id="snapshot-amd-gi-normal-space-investigation"></a>

## Snapshot: docs/AMD_GI_NORMAL_SPACE_INVESTIGATION.md

# AMD GI hit-normal coordinate-space investigation

Reference: Capsaicin `914b91596cd119eda85fbc1d3c7ee6ac391b1452` (v1.3 package, GI-1.2 renderer). This investigation concerns the transform expressions at that revision, not every version of AMD GI. No upstream renderer image was produced for this investigation.

## Conclusion

The missing and repeated instance transforms are localized coordinate-space errors in the pinned implementation. They are not explained by the technique's screen-space/world-space split. This conclusion follows from the producers, consumers, shared buffer bindings and an equivalent-world-geometry counterexample. It does not rely on variable names alone or assume that every geometry/shading-normal difference is an error.

No renderer normal policy was changed during the investigation. The owner subsequently conditionally approved the alternative when AMD's transforms are incorrect. The evidence below establishes that condition; implementation of the narrow correction is now authorized.

## Follow the data into the passes

Paths below are relative to `src/core/src` in the AMD reference checkout.

1. **Static mesh upload:** `capsaicin/capsaicin_internal_scene.cpp:1074` copies mesh positions and normals into `Vertex` without applying an instance transform. The separate transform upload at line 1527 copies `instances[i].transform` into the instance transform buffer. A mesh can therefore be shared by differently transformed instances.
2. **Animated mesh upload:** `capsaicin/generate_animated_vertices.comp:76` multiplies the skin matrix by `g_InstanceInverseTransform` before transforming positions and normals. Deformation does not establish a special world-space-normal contract for the GI fetches.
3. **Fetch helpers:** `geometry/mesh.hlsl:145` and `:175` read the same vertex indices and `.getNormal()` values. Neither `fetchVerticesNorm` nor `fetchVerticesNormUV` transforms normals. The latter additionally fetches UVs. `gpu_shared.h:153` returns the stored normal directly.
4. **Shared bindings:** `render_techniques/gi1/gi1.cpp:2025` binds the same vertex buffer, vertex-data index and instance transform buffer to the GI program. The dispatch sequence at lines 2414–2470 does not swap in world-space normals for the multibounce or cache-shading pass.
5. **Transform helper:** `math/transform.hlsl:36` constructs the normal matrix using cofactors and determinant sign; `transformNormal` at line 58 multiplies by that matrix. It is an instance normal transform, not a projection or a world-to-view conversion. For a pure rotation it applies that rotation.

## Screen-indexed buffers still contain world-space normals

The raster visibility path in `render_techniques/visibility_buffer/visibility_buffer.mesh:83` transforms positions to world and transforms vertex normals by the instance normal matrix. The fragment shader at `visibility_buffer.frag:87` derives geometric normals from derivatives of **world positions**. Its normal-map tangent basis also uses those world-position derivatives. It encodes these world-space normals into screen-sized textures at lines 129–135.

The ray-traced visibility alternative independently confirms the contract: `visibility_buffer_rt.comp:100` transforms local geometric normals once, line 148 transforms shading normals once, and lines 159–179 write these values into the same kinds of screen buffers.

The near-field screen-space pass reads that shading-normal texture and explicitly names the decoded value `world_normal` (`render_techniques/ssgi/ssgi.comp:153`). Where its bent-normal integration operates in a view-aligned basis, it explicitly converts back using `inv_view` at line 128. Those legitimate conversions do not occur in the suspect GI hit-reconstruction blocks.

Screen space determines where samples are stored/looked up. It does not require their normal vectors to be expressed in screen or view coordinates.

## Affected and control paths

| Path | Reconstruction | Subsequent contract |
| --- | --- | --- |
| `gi1.comp:2401`, `GenerateReservoirs` | Transforms vertex positions and normals; interpolates and normalizes world normal. | Light sampling uses world position/directions; temporal feedback compares directly with a decoded world normal from the previous screen buffer. Consistent control path. |
| `gi1.comp:1869`, `PopulateMultibounceCells` | Transforms vertex positions and normals. | Samples continuation direction and launches a world-space ray. Consistent control path. |
| `gi1.comp:2603`, `GenerateMultibounceReservoirs` | Transforms positions but leaves fetched vertex normals local. | Passes that local normal to `sampleLightsListCone` alongside world position and `normalize(origin - world)`. Also uses it for spatial jitter and the reservoir's packed normal. No intervening basis conversion. |
| `gi1.comp:2040`, `PopulateCells` | Crosses edges after transforming positions to world, then applies the instance normal transform to that cross product again. Separately interpolates untransformed vertex normals as `shadingNormal`. | The twice-transformed geometric normal offsets a world-space shadow ray and later enters the BRDF with world-space view/light directions. The local shading normal reaches light evaluation; cosine environment sampling uses it to orient a hemisphere. |
| `gi1.comp:2801`, `TraceReflectionsHandleHit` | Transforms fetched vertex normals once. | Compares them directly with previous world-space screen-buffer normals and uses them for lighting/cache queries. Consistent control path. |

Consumer checks: `ray_tracing/trace_ray.hlsl:131` offsets the supplied world position using the supplied normal; it performs no instance-space conversion. `gi1.comp:2006` evaluates the BRDF with `payload.normal`, `normalize(origin - payload.world)` and the traced ray direction. `materials/material_evaluation.hlsl:206` directly dots the normal with the light direction. `lights/light_evaluation.hlsl:975` calculates directions from light/world positions, and its cosine-environment branch uses the supplied normal directly.

The local `shadingNormal` in `PopulateCells` is not used by every light type. For example, point-light evaluation derives direction from positions without consulting it. That limits the affected cases; it does not establish a valid alternate coordinate convention.

## Numerical counterexample

A flat local triangle has normal +X. Rotate its instance 90 degrees around Z: its world normal is +Y. Compare it with the identical world triangle whose rotation is baked into its vertices/normals and whose instance transform is identity. Use a world light direction +Y. There is no normal map, backface, negative scale, screen projection, disocclusion or denoising involved.

| Extracted reconstruction | Rotated instance: normal · light | Baked equivalent: normal · light |
| --- | ---: | ---: |
| `GenerateReservoirs` | 1 | 1 |
| `GenerateMultibounceReservoirs` | 0 | 1 |
| `PopulateCells` geometric normal | approximately 0 | 1 |

The second path retains +X; the third rotates +Y again to -X. A surface that faces the light can therefore acquire a zero cosine purely because its transform was represented as an instance matrix rather than baked geometry. Identity transforms conceal both errors. Positive nonuniform scale does not eliminate them.

Reproducer: `/workspace/gi-validation/amd-consequential-corrections/check_normal_spaces.py`. It extracts the three reconstruction blocks unchanged from the pinned source, compiles them with C++ host implementations of the HLSL vector/matrix operations, and compares instanced/baked geometry for 0, 30, 60 and 90 degrees, with and without positive nonuniform scale. All 24 path/input cases satisfy the stated expectations. Generated source and numeric results are in the adjacent `normal-space/` directory. This proves the finite-input algebraic inconsistency; it is not a GPU integration or image-equivalence test. It does not establish the visible severity in an upstream demo scene.

## Narrow correction covered by the conditional approval

- In multibounce reservoir generation, transform interpolated vertex normals into world space, matching `GenerateReservoirs` and `PopulateMultibounceCells`.
- In cache shading, construct the geometric normal from **local** triangle edges and apply the normal transform once, following AMD's existing `MakeIntersectData`/visibility-RT convention. This avoids treating a second transform of world edges as intentional. Preserve the existing hit-facing convention; mirrored-instance behavior still needs its own qualification.
- Transform and normalize the cache-shading vertex normal consistently before passing it to world-space light evaluation.

Preserve which call sites use geometric normals versus interpolated vertex normals versus normal-mapped shading normals. The investigation does **not** approve replacing all normals with one kind, adding normal mapping to passes where AMD omits it, or changing sampling, history, material response or the screen-space/world-space architecture. Expected benefit: remove transform-dependent wrong bounce direction/weight and shadow-ray offset. This is not a claim that it fixes the reported boiling, gun artifacts or all missing GI.

## Port implementation and qualification after approval

The port now fetches interpolated vertex normals directly from native packed source/pose buffers and constructs geometric normals from shared BLAS triangle positions. It decodes compressed axis-angle normals using Forward+'s convention. Both normals receive the inverse-transpose instance transform once and hit-facing orientation once. Reservoir generation, resampling and continuation keep interpolated vertex normals; final cache BRDF evaluation and shadow offsets receive geometric normals. Final light evaluation restores the source vertex normal after reservoir-normal quantization, matching the reference's reconstruction boundary.

The production decoder passes 36 software-Vulkan GPU cases against original authored CPU normal expectations (maximum vector error 0.00005052), including two mirrored bases and positive nonuniform scale. The quarter-budget integration passes cache/hit/continuation diagnostics, resize and disable. The four/eight-weight deformation fixture passes its existing image thresholds, including FSR2 pose-buffer swapping. The reflection regression also passes all 344 GPU-checked frames and existing image thresholds; the winding fixture passes 48 front/back ray queries including mirrored instances. These tests qualify this correction; they do not establish full AMD renderer equivalence or close the source-material and half-barycentric handoff gaps.


<a id="snapshot-amd-gi-reference-audit"></a>

## Snapshot: docs/AMD_GI_REFERENCE_AUDIT.md

# AMD GI reference audit and correction

Current correction status: [consequential corrections](#snapshot-amd-gi-consequential-corrections). This earlier ledger is historical; its pass/restored statements do not supersede open findings.

Current status: **the full source comparison is complete; reference fidelity is not established and corrections remain unfinished**.
See [the complete comparison](#snapshot-amd-gi-full-comparison) and its
[function/pass/option coverage appendix](#snapshot-amd-gi-comparison-coverage).
They supersede this historical ledger's conformance claims. In particular,
probe eviction/filtering, SH normalization, reflection feedback/rough fallback,
near-field SSGI, material evaluation and reservoir branch behavior still differ.
No renderer changes were made during that comparison and no deviation was approved.

The previous
"scoped pipeline implemented" statement did not establish completion of the
requested AMD implementation. No algorithmic departure is approved by the owner.

Baseline: AMD Capsaicin v1.3, commit
[`914b91596cd119eda85fbc1d3c7ee6ac391b1452`](https://github.com/GPUOpen-LibrariesAndSDKs/Capsaicin/tree/914b91596cd119eda85fbc1d3c7ee6ac391b1452/src/core/src/render_techniques/gi1), under
`src/core/src/render_techniques/gi1/`. Historical ledger baseline: `d4b39f5`.
The complete comparison uses `d932f4a` plus the existing uncommitted follow-up.
Tests of the fork alone establish regression behavior, not equivalence to AMD.

The table records source differences, not permission to retain them. A proposed
departure requires a concrete benefit, evidence, costs, and explicit owner approval.
Until then, it remains an open correction. Shader language translation, descriptor
binding, native coordinate conventions and resource lifetime are integration work;
changing an estimator, rejection rule, material representation or sampling
distribution is not automatically integration work.

| Area | Reference source | Finding at fork baseline | Disposition |
| --- | --- | --- | --- |
| Diffuse temporal denoiser | `gi1.comp:ReprojectGI` | Custom neighborhood clamp; averaged rather than summed history; changed sample eviction; missing vignette and grazing-angle rejection tolerance; different fallback handling | Reference history equations restored; GPU equation oracle passes 4,096 cases; rendered core regression passes (reprojection inputs still covered separately) |
| Diffuse spatial denoiser | `gi1.comp:FilterGI`, `gi_denoiser.hlsl` | Plane-distance exponential replaces relative view-depth weight; blur radius uses new instead of previous history; center tap omitted from loop | Reference relative-depth weights, center tap and pre-update blur-mask timing restored; equation oracle and rendered core regression pass |
| Light reservoir storage | `world_space_restir.hlsl`, `gi1.comp:GenerateReservoirs`, `CompactReservoirs`, `ResampleReservoirs` | One reservoir per directional radiance cell replaces a separate spatial hash containing multiple hit reservoirs | Independent reference hash, per-hit records, collision search, spatial jitter and prefix compaction translated; GPU ownership, prefix sums, multiple-hit entries, reuse and exact resource-release checks pass. Fresh GridStream RIS and unified analytic/area/environment proposals are now translated; cone-filtered material evaluation remains open |
| Light proposals | `components/light_sampler_grid_cdf/`, `components/light_sampler_grid_stream/`, `components/light_sampler_uniform/` | Custom balanced tree for analytic lights; different selection infrastructure | Default GridStream translated: 16-cell largest axis, 64 strided reservoirs, expanded bounds and segmented proposals; reference default reuse is off |
| Emissive lights | `components/light_builder/`, the reference light samplers | Separate emitter hierarchy and diffuse hit-emission partition replace integrated area-light sampling | Separate hierarchy/probe-origin estimator removed; primary front-face emission bypass and shared area-light RIS restored; rendered validation in progress |
| Reflections | `glossy_reflections.hlsl`, `gi1.comp:TraceReflections` through `NoDenoiserReflections` | Single roughness threshold and integrated single-probe estimate replace low/high thresholds and four-probe stochastic lookup; custom reconstruction, temporal and firefly rules | Reference default a-trous first/iter/last reconstruction and dual-source temporal blend translated; low/high roughness behavior restored. Rendered mirror/moving-emitter, dispatch equivalence and resource-release regression passes at quarter diffuse budget; split-estimator alternative and complete reference-image comparison remain open |
| Material evaluation | `gi1.comp:GenerateReservoirs`, `TraceReflectionsHandleHit`, native `MakeMaterialEvaluated` | Godot shader captures are sampled from tiny per-triangle tiles, including a one-sample-per-triangle fallback | Open design departure; no approval to retain the detail compromise |
| Probe guiding and reuse | `screen_probes.hlsl`, `gi1.comp:ReprojectScreenProbes`, `SampleScreenProbes`, `BlendScreenProbes` | Similar stages do not establish identical candidate search, BRDF weighting, confidence or cache policy | Reference candidate score, plane tolerance, Halton/sky selection, random hole patching, all-candidate gathering and eviction rules translated; integrated validation in progress |
| Radiance-cache temporal update | `gi1.comp:UpdateTiles`, `BlendScreenProbes` | Fork weights new hit batches differently, skips zero-update aging inside touched tiles, caps history after light changes and bypasses probe hysteresis | Reference update equations and touched-tile zero-update aging restored; light-change history override removed. GPU equation oracle passes 4,096 cases including zero-update aging; rendered light-reuse test passes. Integrated diffuse, reflection and FSR2 regressions pass |
| Radiance cache and multibounce | `hash_grid_cache.hlsl`, `gi1.comp:PopulateMultibounceCells` through `ResolveCells` | Different storage/accumulation and custom continuation/update controls | Packed half sums, quantized contributions, reference capacity/hash and next-frame multibounce handoff translated; all-hit default retained |
| Accumulation and quality defaults | Fixed-point radiance sums; reference cache sizes, sampler defaults and RNG | Fork uses floating-point list reduction, smaller caches, different RNG state timing and different default flags | Reference defaults, deterministic seeds and old-state PCG restored; direct integer list reduction has the same commutative uint accumulation as atomic sums |
| Sampling sequence | reference blue-noise sampler and GGX sampler | Fork introduced R2 increments and its own GGX implementation | R2 substitution removed; reference dimensions 1/2 and 2/3 restored. Bounded VNDF and matching PDF restored; GPU numerical oracle passes 4,096 cases. Reflection integration regression passes; full-frame reference comparison remains open |
| Geometry/normals/motion | native reference G-buffer and visibility inputs | Godot bindings, coordinates and shared BLAS integration are necessary; shading/geometric normal distinction and history tests require verification | Separate geometry-normal prepass input added; probes and plane rejection use it, BRDF/denoiser use native shading normals. Build and 344-frame reflection regression pass |
| Optionality/composition | reference render graph versus Godot Forward+ | Per-viewport lifetime, explicit off switch, native GI exclusion and pre-upscaler composition | Required by the owner; retain while checking native BRDF/exposure semantics |

Secondary metallic hits being treated as rough diffuse surfaces is present in
AMD's `GenerateReservoirs` and `GenerateMultibounceReservoirs`; it is not a fork-only
shortcut. This does not validate the fork's other material compromises.

## Acceptance evidence

For each correction, record the upstream functions, preserved equations and data
flow, necessary engine substitutions, reference-derived numerical checks, and
rendered regression results. Keep denoising enabled and the ordinary quarter/one
primary diffuse budgets. Do not replace reference conformance with settled stills,
raise ray counts to hide problems, or weaken an existing test merely to pass.
Target-hardware performance and gameplay acceptance remain separate requirements.

No Windows artifact from `d4b39f5` should be described as the completed faithful
implementation. The owner has now requested a new Windows build; publication and artifact validation remain part of this task.

## Current validation boundary

`amd_gi_reference` runs production GLSL helper functions and an independent oracle
extracted from AMD's source in the same Vulkan compute dispatch. It covers 4,096
finite-input cases of diffuse history accumulation/eviction, blur weights, bounded
VNDF normals and matching PDFs, including view directions below the shading normal,
and radiance-cache temporal updates including unsampled cells in touched tiles.
Maximum observed difference: zero on lavapipe. This is numerical equation evidence;
it does not validate every renderer input, stage schedule or full-frame output.

The rendered diffuse regression passes at quarter and one primary budgets with
denoising enabled. Disabled images and texture allocation return to baseline.
Reflection reconstruction and separate geometry-normal integration pass the 344-frame
reflection rig. Half/full-resolution display-RGB MAE is 0.001704; compact/direct
dispatch linear-RGB MAE is 0.000422. These are internal regressions, not comparisons
against an image rendered by Capsaicin. The independent reservoir hash passes its rendered integration and structural checks.
After the temporal-cache and basis corrections, resampled/exhaustive indirect energy
ratios are 1.001590 for identical lights and 0.985010 for varied lights; no ray-budget or denoiser change. The cache-update equation also passes the 4,096-case oracle. Integrated diffuse, reflection and FSR2 regressions pass. Quarter/one diffuse
display-RGB gains are 0.035895/0.035232; FSR2 gains are 0.039776/0.038269. These
are fixture metrics, not target-hardware quality or timing measurements.
The final shared-scratch layout passes 28 frames of GPU reservoir and LRU
ownership checks, including multi-hit reuse and eviction. Linux editor build and
repository hooks pass. No new target-GPU performance result or Windows artifact exists.

## Current correction work after 848af68

- GridStream replaces both proposal trees. It uses the reference 16-cell-axis /
  64-reservoir default, expanded bounds, strided streaming reservoirs, jittered
  lookup and segmentation without replacement. Analytic, triangle and environment
  lights share the distribution. Barycentrics and area PDFs survive temporal reuse;
  analytic and triangle identities are remapped per viewport.
- Primary emission bypasses the cache, only on front-facing hits. The extra
  probe-origin emitter estimator is removed. Continuation emission and sky are not
  added again on paths already estimated by NEE. Primary temporal feedback now
  injects into the cache and bypasses fresh NEE/filtered readback.
- Secondary shading restores the rough dielectric BRDF and Fresnel compensation,
  including BRDF/PDF continuation weights. The numerical oracle now covers this
  BRDF in addition to history, GGX sampling and cache equations.
- `light_resampling` and `screen_feedback` default false. Fresh RIS remains active
  with reservoir reuse disabled. RNG uses reference deterministic MT19937 seed
  data (5489) and old-state PCG output timing; blue-noise dimensions are unchanged.
- Radiance storage uses packed half sums/counts and uint-quantized updates.
  PCG bucket selection and xxHash checksums hash the unpacked descriptor fields.
  Default capacity is 16,384 × 16 tiles; an explicit bucket-exponent setting allows
  smaller quality configurations. Persistent caches update touched tiles, and
  indirect contributions follow AMD’s next-frame update schedule. Integer list
  reduction for direct updates preserves the same commutative uint sum; indirect
  updates use atomics into persistent pending storage.
- Probe guiding uses AMD’s separate specular/diffuse decision, native primary
  albedo/metalness and bounded VNDF. Reuse gathers all compatible cached candidates
  using reference fixed-point angular accumulation. The cached pool matches the
  screen-probe count. Custom motion-bound history wipes and cached-probe age expiry
  are removed. LRU partition uses a bounded-scratch chunked prefix scan.

The grid, restored BRDF and RNG passed a 28-frame Vulkan reservoir/LRU check.
The packed cache at the full reference capacity and delayed multibounce schedule
passed that same check. The integrated probe gathering and sixth prepass attachment
also passed. These are focused execution checks, not completed gameplay acceptance.
Broader rendered regressions and Windows packaging are pending for this working tree.

## Remaining fidelity work

- Hit materials still use the native triangle atlas, with adaptive 8/4/2-pixel tiles.
  Exact hit-coordinate texture/alpha/normal evaluation and ray-cone material LOD
  remain a substantial gap; native shader compatibility does not justify coarse tiles.
- Grid volume and final cone evaluation still obtain emissive texture values from
  that atlas. Environment cone/mip sampling is now translated using a complete cubemap converted
  from the native sky; see the validation below. Godot analytic attenuation is an engine
  semantic requirement; the proposal formula and support require dedicated checks.
- GI hit captures now select geometry normals before normal-map application;
  interpolation remains limited by the triangle tiles. Full scene collection and
  native custom/deformed-material support remain limitations.
- Probe seed selection, reprojection/scoring, SH packing and full stage scheduling
  still need a complete numerical/data-flow comparison, beyond the corrections above.
- Default glossy reconstruction is ported; the alternative split ratio estimator
  remains unported. Full-frame comparisons and target-GPU performance are outstanding.

No remaining difference is approved merely because the fork’s regression tests pass.

### Further source corrections and failed controls

The probe port now uses half-precision candidate scores, AMD's plane tolerance
without the extra distance rejection, the reference Halton phase, sky-seed culling
and random atomic hole patching. Evictions are based on actual center-probe sample
reuse, preserve the current reprojected probe, and claim existing cache entries
before allocating. Cached updates store unfiltered radiance and preserve their
world metadata. Untouched probes retain reprojected SH instead of recomputing it.
Half-precision rounding is retained at probe storage boundaries.

Ray origins use the reference position-dependent integer offset and shadow-end
fraction. A new independent 48-ray native-mesh test established that GI TLAS
instances require Vulkan's facing-flip flag, including mirrored transforms. Without
it the front-face emission correction made the reflection-emitter regression fail;
that failure was not waived or its image threshold lowered.

Fork-specific whole-history invalidation for camera displacement, environment edits
and atlas resizing is removed. Swept bounds no longer invalidate probe, radiance or
glossy history; their CPU collection now runs only under the diagnostic flag.

A whole-scene collection trial on Crossroads required 5,647,232 padded material
triangles and exceeded the existing 128 MiB atlas even at its smallest tile size.
That trial was withdrawn rather than publish a default known to suppress GI in the
game. The existing 50-unit collection limit remains an **unresolved departure**,
not an approved optimization. Exact hit material evaluation and cone-dependent
texture sampling remain substantive missing work; none of these corrections make
the existing tiny material tiles equivalent to AMD's material inputs.

### Environment cone and reservoir follow-up

`evaluateEnvironmentLightCone` and the two GI-1 cone widths are now translated.
A GI-owned cube converts the native octahedral level zero and generates ordinary
box-filtered mips. Conversion preserves native orientation/exposure; static sky
revisions reuse the cube, dynamic skies refresh it, and disabling GI frees it.
RenderingDevice now permits 2D-array views of cube faces for compute storage; this
is a resource-view integration change, not a new sampling estimator.

The independent Vulkan direction test covers 4,096 cube lookups: maximum absolute
channel error 0.002671 against an analytic direction-colored 64x64 input; each
face's final mip differs from its base-level mean by at most 0.000932. Both bounds
include native-source interpolation and half-float rounding. The equation oracle
includes the cone LOD and still has maximum error zero over 4,096 cases.

When temporal resampling is enabled, the fresh reservoir is first reweighted under
the narrow target before merging previous candidates. Blocked samples now retain
zero W, as `PopulateCellsHandleHit` requires. Previously they retained their
unoccluded proposal weight in next frame's reservoir.

The rough-BRDF target omits AMD's common scalar albedo normalization: for a hit,
that factor multiplies every candidate target by the same positive constant c.
Selection probabilities `(c*w_i)/sum(c*w)` and the final weight
`sum(c*w)/(M*c*selected_target)` are unchanged; the same cancellation applies to
each temporal merge. No BRDF lobe, relative candidate weight, sampling distribution
or estimator is replaced by this algebraic cancellation.

### Integrated d932f4a evidence and failures

Software Vulkan: diffuse quarter/one, light reservoirs, multibounce, FSR2,
reflections, gameplay history continuity and native material fixtures pass.
Reflection validation covers 344 frames, including a moving off-screen emitter;
its mirror contains 799 emitter pixels versus 26 with the incorrect facing flag.
Moving glossy receivers kept history: 1,200 of 24,446 samples were fresh in the
controlled gameplay fixture. Light pulses and geometry flicker did not cause
whole-history resets. This is a controlled fixture, not validation on the owner's
5090 or of the golden weapon itself.

The rapid-emitter quality fixture **fails**: 32 frames after removal, receiver
linear energy is 0.000882 versus lit 0.036523 (2.42%, above the 2% threshold).
Short off/on pulse pairs blur together and do not satisfy the response assertion.
The threshold was not changed. This prevents a claim that the electrical hazard
or muzzle-flash temporal response is fixed.

Crossroads still captures at 640x360 internal / 1280x720 FSR2 Performance show GI
contributing at both quarter and one primary budgets, with denoising enabled,
grass off and hard RT shadows. A frozen scene and 62-frame settle are recorded in
`preview/amd-gi-d932f4a-crossroads/capture.json` in the workspace. They do not show
movement quality, hardware performance, or the later environment-cone follow-up.

Windows clang editor and release template artifacts were successfully produced by
[run 39992968091](https://github.com/automata-rtx/godot-rt/actions/runs/39992968091)
for d932f4a. They precede the environment-cone follow-up.

The later [normal-space investigation](#snapshot-amd-gi-normal-space-investigation) identifies localized upstream transform errors and records the owner's conditional approval. The port now preserves source interpolated and geometric normals separately; GPU decoder and deformation regressions qualify that change. This supersedes the historical capture-normal description for AMD GI, without claiming that atlas material evaluation is resolved.


<a id="snapshot-amd-gi"></a>

## Snapshot: docs/features/amd-gi.md

# AMD GI implementation

This is an experimental Vulkan Forward+ implementation of AMD GI-1.x, adapted from
Capsaicin v1.3 at `914b91596cd119eda85fbc1d3c7ee6ac391b1452`. The main default pipeline and audited corrections are implemented for qualified inputs; full feature parity and hardware/gameplay qualification remain incomplete.
The [full source comparison](#snapshot-amd-gi-full-comparison) is complete; its
[coverage appendix](#snapshot-amd-gi-comparison-coverage) accounts for every stage
and control. The [live consequential correction record](#snapshot-amd-gi-consequential-corrections) tracks every correction, approval, validation result and remaining limitation. The prior
[correction ledger](#snapshot-amd-gi-reference-audit) is historical, not a fidelity certificate.
Target-hardware qualification and shipping presets are also unverified.
It uses sparse directional screen probes,
a world-space radiance cache, multibounce cache feedback, reconstruction, and
temporal/spatial GI denoising, sky lighting, and a separate glossy-reflection path. It does not render a high-sample path-traced image
as a substitute for those stages.

The [gameplay audit](#snapshot-amd-gi-gameplay-audit) records failures in `3038a14`.
Current corrections remove persistent light-ID remapping and restore AMD light-settings transitions. They add native previous-surface inputs, reference probe filtering/LRU and irradiance units, default near-field SSGI, independent reflection feedback, compact GI work and exact shared triangle-buffer access. Native source shading now replaces coarse material capture; its ordinary and affine emitter-mapping cases have controlled GPU qualification; arbitrary custom mappings remain limited.
Software-Vulkan regressions cover these stages, with game-scene checks for the
reported collection/history failures. Historical checkpoint stills do not establish
current quality or target-hardware stability.

The controls below describe current behavior. Default-path algorithm corrections and approved numerical/native adapter exceptions are recorded in the live correction ledger. Optional quality modes are not claims of AMD baseline equivalence. Approved distance handling restores full participating-scene coverage; the extended sky-removal test passes while reporting its early residual.
Default reflection feedback is now independent of `screen_feedback`; default SSGI
also consumes previous opaque lighting. Comparisons use the default quarter primary
ray budget and keep the denoiser enabled.

## Enable and configure

RT shadow support must already be enabled at engine startup, so shared mesh buffers
have acceleration-structure usage. Use Vulkan Forward+, a WorldEnvironment, and no
MSAA. The current input path requires eight color attachments, eleven storage-image bindings and 16-bit storage support. All controls below are live `ProjectSettings` values under
`rendering/global_illumination/amd_gi/`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `enabled` | `false` | Creates the GI scene consumer and cached pipeline only when requested. |
| `probe_spacing` | `16` | Budget one 64-ray probe update per 8×8, 16×16, or 32×32 screen tile: approximately 1, 1/4, or 1/16 primary GI ray per internal pixel per frame. Stored probes always use an 8-pixel grid. |
| `cache_all_hits` | `true` | Shade and accumulate every registered cache hit. Disabling keeps one selected hit per cell and releases hit lists/sample records. Primary ray count is unchanged; visibility, continuation, shading and memory costs can decrease. |
| `screen_feedback` | `false` | Optional diffuse hit feedback; effective only with multibounce disabled and compatible native indirect-light multipliers. Reflection hit feedback and default near-field SSGI remain active independently. Previous opaque lighting is retained for those default consumers while GI is enabled. |
| `multibounce` | `true` | Populate secondary world cells from a subset of primary cache updates, shade their direct light, and propagate indirect light through separate histories. Disabling skips seven stages and frees continuation/indirect storage. |
| `continuation_probability` | `0.3` | Probability of an additional continuation per registered primary hit (per selected cell hit with all-hit updates off); contributions are probability compensated. |
| `minimum_cell_size` | `0.1` | Minimum world-space cache cell size. Actual size also depends on distance, resolution, and field of view. |
| `denoiser` | `true` | Temporal reprojection and adaptive spatial GI denoising. Probe reconstruction/filtering remains part of the GI algorithm. Progress captures leave this enabled. |
| `importance_sampling` | `true` | Guide diffuse probe rays using reprojected radiance times the surface cosine. Keeps the same primary ray count; disabling uses stratified angular samples. Switching resets history. |
| `brdf_sampling` | `true` | Use native albedo, metalness and roughness for AMD’s Fresnel-weighted choice between a bounded-VNDF GGX sample and diffuse radiance guiding. No extra primary rays. |
| `adaptive_sampling` | `true` | Redirect existing updates from reusable probes to uncovered screen tiles. Does not add rays. Switching resets history. |
| `probe_cache` | `true` | Retain one displaced-probe slot per internal 8×8 screen tile, with least-recently-used eviction. Turning this off releases the pool and skips its binning, ordering, and store stages; histories reset. |
| `light_resampling` | `false` | Enable reuse of up to four previous hit reservoirs from AMD’s independent spatial hash. Fresh GridStream RIS remains enabled in both modes. Hash headers use 96 MiB across both frames, plus 64 bytes per hit slot and scan scratch; disabling releases that temporal storage. |
| `cache_bucket_exponent` | `14` | World-cache bucket count is 2 to this power, with 16 tiles per bucket. AMD’s default is 16,384 buckets / 262,144 tiles. Values 8–14 expose the reference capacity tradeoff: fewer buckets reduce memory but increase collision overflow and missing cache coverage. Live changes recreate history. |
| `reflections/enabled` | `true` | Enable the separate glossy path. Turning it off skips all glossy stages and releases reflection-sized resources. |
| `reflections/half_resolution` | `true` | One glossy sample per 2×2 internal pixels, with rotating sample locations; disabling uses full internal resolution. Independent of diffuse probe spacing. |
| `reflections/trace_roughness_threshold` | `0.2` | Trace below this roughness. Between this and the high threshold, use AMD’s stochastic GGX lookup in four screen probes. Missing probe coverage falls back to tracing. |
| `reflections/probe_roughness_threshold` | `0.6` | At or above this threshold, use the diffuse probe irradiance approximation. Missing coverage falls back to tracing. Keep this at least as high as the trace threshold. |
| `reflections/firefly_filter` | `true` | AMD’s rank-based marking and plane-weighted cleanup before reconstruction. Runs only with reflections and the denoiser enabled. |
| `reflections/firefly_low_threshold` / `firefly_high_threshold` | `0.0` / `1.0` | Reference rank thresholds. The reference defaults do not reject ordinary rank outliers; narrower bounds enable more rejection. |
| `reflections/ray_compaction` | `true` | Classify sky/probe-reused pixels, compact the remaining glossy samples on GPU, and dispatch tracing indirectly. Changes scheduling, not sample count or the estimator. |
| `emissive_sampling` | `true` | Include GPU-built triangle emitters in the shared GridStream distribution for world receivers. Primary hits contribute emission directly. Adds selected visibility rays; disabling retains primary hit emission. |
| `reflections/filter_passes` | `4` | Two to eight a-trous passes: first reconstruction, zero or more intermediate passes, then full-resolution reconstruction. Reference default is four. |
| `material_atlas_mb` | `128` | Legacy uncached transport-validator capture control only. AMD GI source shading ignores it. |
| `material_preparation_budget` | `64` | Legacy uncached transport-validator capture control only. AMD GI source shading ignores it. |
| `material_tile_size` | `8` | Legacy uncached transport-validator capture control only. AMD GI source shading ignores it. |
| `material_adaptive_resolution` | `true` | Legacy uncached transport-validator capture control only. AMD GI source shading ignores it. |
| `max_distance` | `1000000000` | Maximum ray distance, matching AMD. The participating scene is collected independently of the camera. Smaller explicit values are nonbaseline quality limits. Screen-probe reprojection stores distances up to 65504; actual hits retain their distances. |

```gdscript
ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
```

Primary probe rays are not the total ray count: cache updates also issue visibility
rays for lights, and multibounce adds continuation rays and sometimes another light
visibility query. Unified light sampling adds at most one selected visibility ray per shaded world receiver. Glossy primary rays are also additional. Partial screen tiles are rounded up. The controls are experimental
quality knobs, not measured 780M presets.

Native SDFGI, VoxelGI, SSIL, and lightmaps must be absent when using this path. Native
settings are preserved; conflicts suppress RT GI rather than silently combining
backends. AMD GI takes precedence over the separate `rt_validation/enabled`
diagnostic setting if both are requested. The existing default `GI_MODE_STATIC` and `GI_MODE_DYNAMIC` both participate automatically and support movement. Explicit `GI_MODE_DISABLED` excludes an object from transport while keeping visible surfaces as screen-space receivers; this honors the game's existing grass/outline/tracer settings. No bake, authored probes, or special UV layout is required.

## Implemented pipeline

`RaytracingGIScene` owns the shared hit-material/light adapter, material atlases,
and GI TLAS. It shares BLASes with RT shadows through `RaytracingGeometry`.
`RTGIValidation` now contains only the separate diagnostic renderer.

`AMDGI` owns lazily compiled compute pipelines. Each viewport owns its caches,
probe and pixel histories, and intermediate textures through render-buffer custom
data. Specialized stages use explicitly ordered dispatches; the probe-mask
stage dispatches once per mip level:

1. Age/clear world-cache tiles and reset update ownership.
2. Reproject an 8-pixel stored probe grid using all 64 candidate screen positions
   per tile. Retain compatible histories independently of the tracing budget.
   Select sparse updates using a repeating Halton sequence, then match uncovered
   tiles to reusable update slots with the reference random atomic exchange.
   Competing holes can overwrite a slot; sky seeds are culled and no extra rays are added. Bin cached world-space probes into the current
   screen grid. Reproject hits from a compatible 3×3 current reprojected-probe neighborhood
   plus all qualifying displaced probes into the selected probes. Build a
   64-cell cumulative distribution from radiance times the surface
   cosine. Trace 64 guided, jittered equal-area hemi-octahedral samples per probe,
   reading native materials at triangle hits. Cells without reusable history and
   completely dark distributions fall back to stratified samples.
3. Allocate directional world-space tiles using AMD's PCG bucket hash, xxHash
   checksum and 16 candidate slots per bucket. Publication and subsequent lookup
   are separate passes. Checksums follow the reference collision behavior; full
   keys are retained for diagnostics, not used to change identity matching.
4. Register every primary hit in a bounded per-cell list. By default, shade each
   hit independently and accumulate its contribution/evidence in the cache. With
   multibounce on, each registered primary hit can schedule one continuation,
   according to `continuation_probability`. `cache_all_hits=false` retains one
   selected update/continuation candidate per touched cell as a lower-cost option. Allocate/register the secondary hits
   as additional world-cache receivers. Primary owners win when both reach a cell.
5. Shade direct light for the primary and newly populated secondary receivers.
   Separate direct and indirect histories prevent feedback races. Store
   reflected radiance only: emission is added at the exact ray hit so the spatial
   cache does not enlarge emitters. Rays shorter than a world-cache cell bypass
   filtered readback, including continuation rays, to reduce leaks at thin walls.
   Fresh light proposals use GridStream: 16 cells along the largest axis, up to 64
   strided reservoirs per cell, expanded-cell volume weights, jittered lookup and
   at most eight non-overlapping segments. Analytic lights, emissive triangles and
   the environment share this distribution. Triangle samples retain barycentrics
   and area-measure PDFs. One selected visibility ray evaluates each fresh reservoir.
   Optional world-space reservoir reuse re-evaluates at most four compatible previous
   reservoirs and caps their confidence at 20. Reference light indices are retained;
   environment/zero-light-class settings transitions reset GI.
   Godot analytic attenuation, layers and shadow-opacity semantics remain native.
6. Update packed-half direct and indirect cache sums using the reference temporal
   equation and integer-quantized contributions. Build the three coarser mips and
   choose the finest mip with 16 samples. Persistent storage updates only touched
   tiles. Continuation rays read the updated secondary direct cache and write
   probability-compensated contributions to the next frame’s indirect update buffer,
   matching AMD’s one-frame multibounce handoff. Continuation misses and emissive hits
   do not add another light estimator on top of NEE. Primary emissive hits inject Le
   directly into probes; they bypass filtered cache radiance.
7. Resolve probe radiance and average samples landing in each angular cell. Apply
   AMD's empty-cell radiance backup and shadow-preserving temporal hysteresis,
   followed by horizontal/vertical filters with plane and hit-direction rejection.
8. Build the valid-probe mask hierarchy before filtering, then project radiance
   into nine spherical-harmonic coefficients. Run the default near-field SSGI
   and bent-cone integration. Reconstruct incoming diffuse irradiance from four
   neighboring probes using AMD's depth/normal weights and plane-constrained lookup
   blue-noise jitter. Four spatial dimensions are precomputed from Capsaicin's
   Sobol/ranking/scrambling tables; the shader retains its golden-ratio temporal
   rotation. The shared buffer contains the 64 KiB spatial table followed by deterministic MT19937 seed data, with a minimum 1920×1080 seed allocation. It exists only while AMD GI is active.
   Relaxed interpolation fills otherwise uncovered pixels, with a low-confidence
   hint that prevents those fallback estimates from growing temporal history.
   Cache displaced surface probes, update reused entries, and reorder the bounded
   pool so unused entries are evicted first. A stable GPU prefix scan preserves
   frame-granularity least-recently-used order without CPU readback or sorting.
9. Reproject GI history using AMD’s accumulated radiance sums, sample eviction,
   confidence vignette and fallback rules. The blur radius uses pre-update history.
   Apply the reference relative-view-depth and normal-weighted horizontal/vertical
   filters, then composite before fog, tone mapping, DLSS or FSR.
10. Trace bounded-VNDF GGX samples below the low roughness threshold. Between the
    two thresholds, stochastically look up four screen probes; above the high
    threshold, use filtered diffuse irradiance divided by pi. Hit radiance comes from native screen
    feedback or the world cache, with hit emission and sky handled separately.
    AMD’s default a-trous path filters compressed radiance and RGB second moments,
    performs full-resolution reconstruction, then combines surface and virtual-ray
    temporal histories. The alternative split estimator is not ported. Native
    Forward+ applies the primary material BRDF before fog and temporal upscaling.

Sky input converts Godot's unfiltered octahedral radiance into a GI-owned cubemap
with a complete ordinary mip chain. This preserves Capsaicin's environment cone
sampling instead of substituting the native GGX roughness prefilter. Fresh light
selection uses `4*pi/(8*1.5)` and resampling/final shading use
`4*pi/(8*12000)`; grid volume weights use the coarsest mip of all six faces.
Sky-ray misses still use level zero. Conversion follows native sky revisions;
TIME/position/light-dependent skies update each frame. Orientation and exposure
remain native inputs. The cubemap and conversion exist only while GI is enabled. Camera movement, sky/light changes and material-atlas repacking do not
force a global history reset. AMD's surface reprojection, cache updates and decay
handle scene changes. Initialization, resource recreation and explicit quality
configuration changes reset the relevant history. When sky ambient
is enabled, GI replaces that unoccluded ambient term and preserves the environment's
remaining color-ambient mixture. Reflection sky selection follows the environment's
reflection source independently.

The default hash has 16,384 buckets, 16 tiles per bucket, and 85 cells per tile including
mips. Bucket selection uses the reference PCG chain and checksum uses xxHash. Base-cell history is limited to 16 updates, tile lifetime to 50 unused frames,
and final GI history to at most 64 samples with adaptive reduction. These are live
temporal histories, not unlimited accumulation for screenshots. Histories reset on
allocation, resource recreation and relevant quality/light-settings changes. Ordinary camera motion or camera replacement does not globally reset GI; surface/probe reprojection rejects incompatible history. Reference light-settings changes include environment presence and crossing zero/nonzero light-class counts, not every brightness or light-count change. Native surface reprojection rejects incompatible geometry; the fork’s swept-bounding-box probe-history wipes have been removed. Smooth lighting changes retain history; small camera motion reprojects existing histories. Material colors refresh
through new cache samples and the reference temporal weighting.
GI collection is sorted by stable instance and light IDs before building the
signature and material layout; spatial-tree traversal permutations must not
invalidate history. The focused cache harness verifies this explicitly.

Disabling destroys the GI scene consumer and its shader pipelines, releases GI-only
BLASes, and clears rendered viewports' GI custom data and texture scopes. Shared
shadow geometry survives. A never-enabled viewport allocates none of these resources.
Native material-bake buffer pools can remain warm after use; deferred destruction
follows RenderingDevice's usual lifetime rules. Exact image restoration is not a
hardware timing measurement.

## Supported scope and port differences

These are current implementation facts, not approved departures from AMD.
The [reference audit](#snapshot-amd-gi-reference-audit) tracks corrections and the
evidence needed before reference fidelity can be claimed:

- Reprojection retains the visible 8-pixel grid. Guiding gathers a 3×3 reprojected
  neighborhood and every qualifying displaced-cache candidate in those bins.
  Integer atomic angular accumulation uses AMD’s 10,000 quantization factor.
  The displaced pool matches the screen-probe count; it no longer expires at an
  arbitrary 50-frame age. World radiance tiles retain AMD’s separate 50-frame decay.
  Primary albedo and metalness now come from a GI-only native prepass attachment,
  supporting the reference diffuse/specular sampling choice.
- Cache updates accumulate all registered primary/secondary hits by default.
  The optional one-hit-per-cell control remains a non-reference quality mode.
  The custom analytic and emissive proposal trees and probe-origin emitter estimator
  are removed. GridStream unifies light selection; `light_resampling` controls previous
  reservoir reuse only and defaults off, as does screen feedback.
  Secondary shading evaluates AMD’s fully rough dielectric BRDF including Fresnel
  compensation and specular energy. Multibounce sampling carries BRDF/PDF weights.
  Reference deterministic MT19937 seeds and PCG output/state ordering replace the
  previous ad hoc per-pass seeds.
- Glossy transport, ratio reconstruction, temporal rejection, and a-trous denoising
  are implemented. The matte room alone cannot validate them; use the dedicated
  mirror/glossy-floor rig. This is an adaptation, not an exact port of all Capsaicin
  reflection heuristics. Native primary materials retain their BRDF; secondary
  shading uses GI-1's rough diffuse approximation, including metallic hit base color.
  This avoids black metallic receivers without adding nested specular rays; it is
  not layered/anisotropic or general nested specular transport. Reflection-only
  hits read the world cache; upstream Capsaicin also performs cache lookup here
  rather than inserting those hits. The custom uncached reflection-lighting fallback has been removed. Compatible screen hits can reuse
  visible native specular lighting, but this is view-dependent feedback rather
  than general nested specular transport.
  Half-resolution mirrors can show reconstruction artifacts.
- Native source material programs read uniforms, textures and packed attributes at
  hits. AMD GI does not prepare capture pages or wait for an atlas budget. Source
  emitter sampling follows point/triangle/cone LOD. Affine UV0/UV2, rotation/scaling/translation, supported aliases and varying mappings are qualified by 704 GPU samples. Arbitrary warped, texture-driven, helper/loop-dependent or other unqualified mappings retain a diagnosed fallback; full native material coverage remains incomplete.
- MeshInstance3D geometry, native skeletons/blend shapes and CPU-managed 3D
  MultiMesh elements are collected without the former fixed instance/light caps.
  Particle/GPU-indirect MultiMesh geometry and unsupported native shader/light
  classes remain limitations. These are reported and skipped individually rather
  than suppressing supported geometry across the entire scene. Missing classes can
  still cause incorrect visibility/lighting; no full scene-class support is claimed.
- Reprojection uses native previous-surface positions from the GI depth prepass, including previous native poses. Swept object bounds no longer erase probe history. Controlled rotation/deformation, gold-weapon motion and first-person intersection sequences have software-Vulkan coverage; this is not an exhaustive gameplay guarantee. FSR2 has
  software-Vulkan coverage; DLSS runtime compatibility remains untested.

AMD's shader copyright/license is retained in `amd_gi.glsl` and `COPYRIGHT.txt`.
Equal-area hemisphere mapping, SH projection/convolution, cache layout, probe
sampling/blending/filtering and their inputs are being compared against the cited
reference stage by stage; matching stage names alone does not establish fidelity. See
[AMD_GI_IMPLEMENTATION.md](#snapshot-amd-gi-implementation) for the larger work plan.

Angular accumulation now uses the reference fixed-point uint atomic sums and
counts. Radiance and SH round to half precision at storage boundaries. The
reprojected angular buffer remains scratch until resolve finishes. Mask dimensions
round up at each level to retain odd-sized edge tiles. An unchanged ray budget
does not establish unchanged GPU cost.

The displaced pool uses 1,216 bytes per entry, with one entry per stored screen
probe plus transient snapshots for displaced updates. Separate ownership/list
state and double-buffered order indices prevent competing writes. Eviction follows
actual center-probe reuse, preserves reprojected radiance, and uses the reference
LRU policy without the fork's former 50-frame cached-probe expiry. World radiance
tiles retain AMD's separate decay policy.

## Progress captures

Routine game preview comparisons use GI disabled versus the default **1/4 primary
diffuse ray per pixel** (16-pixel probe spacing), with denoising enabled. Do not
add a 1-ray-per-pixel comparison unless explicitly requested; the user considers
the settled stills sufficiently similar (2026-10-23).

Cloud game previews use FSR2 Native AA at 100% render scale: internal and output
resolutions must match. Do not upscale an already-small software-rendered preview.
For Crossroads, prefer a close view of shaded surfaces beside directly lit geometry,
such as the service-yard garage interior, rather than distant buildings behind fog.
Keep the authored lighting, fog and materials. Record camera coordinates, engine
revision, primary ray budgets and settling frames alongside the PNGs in `preview/`.

From `docs/validation/shadow_validation`:

```sh
./run.sh amd_gi
```

This runs the real sparse pipeline at 16-pixel and 8-pixel probe spacing, with
multibounce, probe filtering, and GI denoising enabled. Startup and approximately
32/64-frame captures make settling visible. The two extra draw frames used by the
capture helper are part of those approximate labels. No high-sample reference pass
is enabled. Controls cover indirect-energy zero, a changed non-shadow-casting wall,
camera cuts, small camera motion, resize, and disabling/restoring the baseline. `score_amd_gi.py` checks those
lighting/restoration controls; software Vulkan timings are not GPU benchmarks.

Progress images must state their primary ray budget and enabled filtering. A raw
diagnostic image is useful only when explicitly labeled. Historical 128/512-sample
transport images are debugging references and must not represent shipping quality
or this pipeline's progress.

`./run.sh amd_gi_sampling` holds the camera, 16-pixel spacing, multibounce, and
denoiser fixed during the importance-sampling off/on/off comparisons. It also
tests an all-black history, discovers an emissive ceiling enabled by a material
uniform change, and measures residual indirect light after removing that emission.
It also toggles adaptive placement and the displaced-probe cache, and exercises
the 1/16 primary-ray schedule. A separate camera sweep and return exercises
displaced-probe reuse. Static stages get 64 settling frames plus capture synchronization. The box-front
measurement excludes the visible emitter. Sampling toggles must preserve GPU
allocation counts; disabling must restore the exact image and texture allocation.
This is an integration/response check, not an accuracy ranking between samplers.

Both that rig and `./run.sh amd_gi_cache` enable `GODOT_AMD_GI_VALIDATE_CACHE=1`.
The focused cache rig sweeps the camera out and back while keeping its displaced cache resident, then renders another 64 frames. It requires history to survive small
camera motion, and checks the disabled image exactly. This diagnostic reads
the actual GPU queues, spawn assignments, ownership, and LRU order every frame.
It rejects duplicate/out-of-range assignments and invalid permutations, verifies
the update budget, and requires both eviction and reuse to be exercised. It
synchronizes the GPU and must not be enabled for timing or shipping presets.

`./run.sh amd_gi_lights` compares exhaustive and resampled light evaluation at
the same primary-ray budget. `GODOT_AMD_GI_VALIDATE_RESERVOIRS=1` synchronously
checks actual GPU light indices, finite weights and confidence in [1, 81], plus
the complete hash prefix, unique hit ownership, multi-hit entries and compaction. The
identical-light and varied-light stages retain multibounce and denoising. This is
an integration/normalization check; exhaustive light evaluation does not turn the
sparse GI pipeline into a perfect-reference renderer.


## Native comparisons

`./run.sh gi_compare` compares this pipeline at 16- and 8-pixel probe spacing
against native VoxelGI and SDFGI in the same inherited room. Multibounce, probe
filters, and GI denoising remain enabled; AMD captures follow 64 settling frames.
No uncached reference tracing is enabled.

All methods use the same 641x359 camera, materials, direct point light, hard RT
shadows, and AgX exposure. AO, sky light, and antialiasing/upscaling are absent.
The meshes are marked static only to make them eligible for native GI; the light
uses `BAKE_DYNAMIC`. No separate energy or exposure matching is applied.

| Capture | Configuration |
| --- | --- |
| `gi_disabled` | Direct lighting and RT shadows. |
| `amd_quarter`, `amd_one` | Approximately 1/4 or 1 primary probe ray per internal pixel per frame, continuation probability 0.3, denoiser on, distance limit 20. |
| `voxel_128`, `voxel_256` | Baked volume centered at `(0, 1.5, 0)`, size `(6, 4, 6)`, high cone-tracing quality, 128/256 subdivisions, interior mode, two bounces, energy 1, propagation 0.5, bias 1.5, normal bias 0. |
| `voxel_256_normal_bias` | Same 256-subdivision bake, bias 0, normal bias 1.5. |
| `sdfgi_default` | Four cascades, minimum cell size 0.2, 75% Y scale, occlusion off, sky reading off. |
| `sdfgi_fine_occlusion` | Minimum cell size 0.1, occlusion on; otherwise unchanged. |

Native methods use full-resolution composition. SDFGI uses 16 rays per probe,
30-frame convergence, light updates every frame, energy 1, feedback 0.5, and
normal/probe biases 1.1. The camera sits outside the room: minimum cell size is
not the resolution throughout the room. Each native configuration gets 120
settling frames, an early capture, 60 additional frames, and a final capture.
The scorer reports the remaining difference and requires exact disabled
restoration after each backend. These different transport models are not equal
GPU-cost configurations or ground-truth accuracy rankings.

## Sky and reflection checks

`./run.sh amd_gi_sky` checks sky illumination, occlusion against native unoccluded
ambient, live color/removal/rotation changes, and exact disabled restoration.
`./run.sh amd_gi_reflections` keeps diffuse at 1/4 primary ray/pixel and denoising on,
compares half/full glossy resolution, removes an emissive object behind the camera,
exercises camera motion, and checks reflection-buffer release. Its opt-in
`GODOT_AMD_GI_VALIDATE_REFLECTIONS=1` reads actual GPU sample records for finite
values and reports traced versus probe-reused samples. Diagnostic readback is not
part of ordinary rendering or a performance preset.

`./run.sh amd_gi_dirty_materials` checks retained material pixels against texture
updates in place, emission parameters, shader changes, TIME, and global uniforms.
Unchanged static pages must stop drawing, while only the dynamic page refreshes.
`./run.sh amd_gi_fsr2` exercises the jittered 320×179 internal image in a 641×359
FSR2 Performance viewport with diffuse, reflections, multibounce and denoising on.
DLSS and target-device timings still require the Windows/NVIDIA and 780M machines.

`./run.sh amd_gi_dynamic_lighting` animates a TIME-driven sky, sky rotation,
a directional sun and a local light. It requires exactly one initialization reset
through the continuous segment. Its older abrupt-removal reset expectation predates the reference correction and is not current acceptance evidence. This lighting test does not certify moving meshes; deformation and scene-churn
rigs separately check local invalidation.

With the default 8-pixel material tiles, captures occupy 32-triangle rows across
dynamically allocated 256×256 atlas layers. A layer stores 1,024 triangle tiles and
costs 1.25 MiB across four channels. The 4-pixel option uses one quarter of those
texels per layer. `material_atlas_mb` bounds this atlas; native capture targets and expanded
source geometry are additional. The default permits 102 layers, allocated only as
needed. Layers and scene buffers grow geometrically, retaining pixels during growth;
lowering the live budget shrinks the atlas. The collection safety caps are 65,536
surface instances and 1,024 lights, with buffers allocated for the actual count.
These are safety limits, not recommended scene budgets or hardware measurements.

Compatible instances share material captures by mesh, surface, material, and pose.
For the uncached transport validator, transform-independent captures store local normals, transformed by the ray hit's
inverse-transpose matrix. World/instance-dependent shaders, normal-map/tangent
inputs, and instance uniforms conservatively retain per-instance evaluation.
Repeated static props therefore share both geometry and material captures.
`amd_gi_material_sharing` checks repeated geometry and transform-only reuse;
`amd_gi_atlas` checks relocation, growth beyond the old 32-layer limit, and live
budget shrinkage.

CPU-managed 3D MultiMeshes collect each visible element within the GI volume.
The native capture preserves element colors, custom data, and `INSTANCE_ID`, and
tracks the element separately for material invalidation and motion. The
`amd_gi_multimesh` rig compares them against independently shaded MeshInstances,
then exercises movement and live color/custom updates. GPU-indirect MultiMeshes
and particles remain unsupported.

### Native deformation and local motion

`./run.sh amd_gi_deformation` compares four/eight-weight skeletons combined with a
blend shape against independently baked static meshes. It checks GI transport,
retained material preparation, FSR2 buffer swapping, and disabled restoration.
`GODOT_AMD_GI_VALIDATE_CACHE=1` additionally checks that each enable initializes
history once while subsequent animation reports local swept regions.

Swept bounds are collected only under `GODOT_AMD_GI_TRACE_HISTORY` for diagnostics.
They do not reject probe, diffuse or glossy history. Native previous-surface
positions provide reprojection; world-cache lighting uses AMD's UpdateTiles
weighting, including zero-update aging in touched tiles. Geometry and lighting
changes converge through fresh samples and the reference rejection/filter rules.

### Matched primary-ray comparison

`./run.sh amd_gi_budget_compare` starts both budgets from released resources and
uses the same 62 settle draws plus two capture draws. Cache diagnostics verify the
actual uninterrupted history lengths are equal. Denoising, multibounce, importance
sampling, adaptive updates, displaced-probe reuse, light resampling and reflection
settings remain identical. Primary diffuse budgets are approximately 1/4 and 1 ray
per internal pixel per frame; visibility, continuation and glossy rays are additional.
The existing matte room primarily demonstrates diffuse reconstruction, not sky or
specular fidelity. A checkpoint comparison does not mean the backend is complete.

## NRD evaluation later

NRD is not integrated. Its Vulkan compute pipelines can be driven through Godot's
RenderingDevice without replacing the scene or ray-tracing system. An integration
must supply demodulated diffuse/specular signals, suitable per-lobe ray-hit
distances, view depth, normal/roughness, motion vectors, camera/jitter and history
reset data. Sparse probes require a deliberate reconstruction/confidence adapter;
feeding them directly as per-pixel ray samples would violate that contract.
Glossy denoising is a useful first isolated comparison against the current filter.
NRD cannot correct cache bias, missing transport, or undersampled hit materials.
See [NRD's current input requirements](https://github.com/NVIDIA-RTX/NRD#inputs).
No quality/performance advantage has been measured in this fork.

## Testing on the target machines

Use an editor built from the experimental `feature/amd-gi` branch. Existing fork
builds from before that branch do not contain these controls. The Windows CI
artifacts are `windows-editor` (MSVC), `windows-editor-clang` (clang-cl) and
`windows-template`; select the matching commit,
and use the release template for export (the fork has no debug export template).
Both editor builds target Windows x86-64; the Clang executable has `.llvm.exe`
in its name. An editor job passing compilation does not by itself mean an artifact
exists: check the run's uploaded artifacts. Keep the existing Streamline runtime
setup when testing DLSS.

Start with GI disabled and reproduce the game baseline. Then enable `amd_gi/enabled`
and leave `probe_spacing=16`, denoising, importance/adaptive sampling and probe cache
on. Reflections have an independent toggle and half-resolution option; compare
diffuse alone before adding their cost. None of these values is a measured 780M
quality preset. Watch renderer warnings: unsupported materials/geometry or capacity
overflow suppress the contribution, so checking only the enabled setting is not
proof that GI is running. Test FSR2 on the laptop and DLSS on the desktop, movement,
lighting changes, scene transitions and disabling/re-enabling as well as a still.
A controlled run of `fps-proto`'s `levels/test_level.tscn` now passes with the native
extension, three NPCs, RT shadows, VBAO and FSR2 Performance. It uses a 641×359
window (320×179 internal), grass and RT soft shadows off, and frozen gameplay for
matched 64-draw quarter/one stills. Its material atlas grows to 64 layers for 34,464
triangle tiles. This is software-Vulkan integration evidence, not full gameplay,
all-map or target-hardware validation. Keep custom grass off: its opaque custom
vertex deformation remains unsupported by GI.

### Forward-only transparency

Transparent passes that neither write depth nor cast material shadows stay in the
native raster path. This includes outline shells, stencil-only masks and additive
effects. They do not become opaque GI occluders and do not disable GI for the scene.
Opaque/cutout surfaces retain normal transport. Depth-writing mix-alpha materials
use stochastic opacity: fully opaque texels remain surfaces, zero-alpha texels
transmit, and fractional texels select coverage probabilistically. The same test
applies to GI visibility rays; native RT-shadow behavior is unchanged. This is
straight-through opacity, not refraction or colored transmission. Multipass and
unsupported deformation retain strict checks. Forward-only effects do not emit GI.
`amd_gi_overlays` checks that physical-scene GI and history survive these passes.

### Light proposal grid

GridStream builds volume-weighted strided reservoirs on GPU over current traced
hit bounds. Analytic, area and environment lights share the grid. A jittered lookup
merges disjoint segments into fresh RIS; optional previous-reservoir reuse is
separate and off by default. The former analytic binary tree, emissive tree and
probe-origin area-light estimator have been removed. See the pipeline above for
proposal counts and remaining native material/cone-sampling limitations.

### Native screen-lighting feedback

Opaque Forward+ draws optionally write their combined HDR lighting to a fourth
color attachment before fog, tone mapping, and temporal upscaling. GI reads that
texture on the following frame, matching the previous pixel geometry and removing
the previous exposure. Background/transparent pixels have no valid coverage.
Native current-to-previous UV displacement, relative depth and normal agreement
reject invalid reuse. The reference diffuse thresholds are 5% depth and 0.5 normal
agreement; glossy uses 1% and 0.95. Reflections retain the world-cache fallback;
continuations currently also retain explicit shading fallbacks under audit; the system does not require everything to remain on screen.

The texture exists only while feedback is active. Native feedback shader variants
compile on demand for materials that request them. Disabling GI adds no feedback
attachment, pass, trace or copy; ordinary native pipeline caches may remain warm,
but new or edited materials do not compile feedback variants unless requested.
The `ShaderRD` on-demand group is separate from global group enablement for this
reason. Feedback includes the visible material's native lighting/AO; it is an
approximate view-dependent radiance reuse, not a new exact path-tracing bounce.

`amd_gi_feedback` checks actual GPU acceptance, unfogged/unexposed radiance,
per-light indirect-energy fallback, texture release and exact disabled restoration.
Its synchronous diagnostics are opt-in with `GODOT_AMD_GI_VALIDATE_FEEDBACK` and
must not be enabled when measuring performance. The dedicated counter occupies
previously unused queue-header space; ordinary rendering does not increment it.

### All-hit cache updates

`cache_all_hits` retains bounded lists of registered hits, shades them in parallel,
and reduces their contributions per world cell. Primary hits contribute independent
continuation estimates; secondary-only cells receive direct lighting. Counts are capped at 16 by the reference temporal update. The update averages
this frame’s hit batch, then blends with weight 1/capped_count; it does not weight
the frame by its hit count. Unsampled cells inside a touched tile age as upstream.
Each shaded hit now publishes its own light reservoir into the independent spatial
hash; the radiance cell’s owner no longer determines the sole reusable light sample.

The optional storage is one additional head per world cell plus 48 bytes per primary
hit slot (and per secondary slot when multibounce is on). The lower-cost mode skips
both per-hit shading passes and releases this storage. It preserves the original
one-update-per-cell behavior. Primary diffuse rays are identical between modes;
additional visibility and continuation rays must be included when profiling.
`amd_gi_hit_updates` reads actual GPU lists to verify every registered hit is present
exactly once, all samples are shaded, and toggling releases the extra buffers.

### Historical capture-atlas memory (superseded for AMD GI)

Material capture is a separate quality/memory axis from screen-probe ray density.
`material_tile_size=4` uses 128×128 array layers with the same 32×32 triangle layout;
8 uses 256×256 layers. Addressing derives the tile size from the actual texture.
Live changes discard old captures/atlas textures while
retaining shared shadow geometry. The default remains 8; quality is not silently
reduced when a scene exceeds its atlas budget. Capacity warnings report tile counts.

Transform-independent captures also share repeated identical instance colors;
the exact color is part of the capture key. Shader instance IDs/custom data,
world/camera dependencies and other context-sensitive inputs retain their existing
separate captures. Tint sharing changes storage, not rendered material values.

Crossroads replaces TestLevel as the project's evaluation scene. Its Main Street
camera currently needs 545,376 material tiles at 50 m trace distance, exceeding the
8-pixel atlas's maximum 512 MiB budget. Four-pixel tiles fit with a 256 MiB budget
(the current growing atlas allocates 268,369,920 bytes). Separate capture targets,
expanded geometry, BLASes and GI histories are additional. This is a measured
correctness-test footprint, not a validated 780M quality/performance preset.

### Scene changes and history diagnostics

Geometry is matched by stable instance RID and MultiMesh element across sorted
collection lists. Entering/leaving the camera-centered collection, visibility
changes and topology/material-content edits invalidate the old/new local bounds.
The current correction no longer uses persistent light-ID remapping. Ordinary index changes retain history; reference environment/zero-count light-settings boundaries reset it. Lighting changes use the reference cache accumulation; the former forced fast-refresh weighting has been removed. Explicit quality/resource changes reset history; camera and environment changes use reference reprojection and cache updates.

`GODOT_AMD_GI_TRACE_HISTORY=1` logs reset reasons and dirty-region counts without
GPU readback; it is opt-in and only runs in the enabled GI path. `amd_gi_scene_churn`
checks collection-boundary crossings, rotation, additions/removals and material
edits. `amd_gi_flashlight` checks continuous spotlight movement, indirect light,
resampling against exhaustive light shading and removal of light after switch-off.
Both use the quarter primary budget with denoising enabled. They do not establish
hardware timing or final gun-mounted flashlight quality in fps-proto.

## Earlier integration additions (2026-10-23)

Historical record: the capture-atlas and emitter hierarchy descriptions below predate the current native source-material/GridStream path. Use the live correction record for current behavior.

Historical checkpoint: the stable-ID policy described below was subsequently removed.
Use the [live correction record](#snapshot-amd-gi-consequential-corrections) for current
behavior, input formats, default SSGI/feedback, evidence and remaining gaps.

The lighting buffers now carry full light-instance identities. Each viewport maps
its previous light indices to current indices before using reservoirs. Removing a
light invalidates its proposals, not all GI histories. Reference temporal cache
weighting now handles changed lighting without the former custom fast-refresh rule. Keeping proposal storage in zero/one-light scenes avoids reallocating
all histories when a flashlight changes a scene from one light to two.

The optional GI depth variant writes native motion vectors and previous world
positions, including previous skin/blend-shape vertices. Its RGBA32F target exists
only while GI is active. Probe, diffuse-pixel, and glossy-surface reprojection use
that previous position. A receiver's own swept bound no longer automatically
rejects its reflection history. Intersecting connections remain conservative.

Emissive surfaces supply actual shared RT vertex/index buffers to a GPU extraction
pass. Native captured emission/opacity establishes triangle power, including every
covered material texel so textured emission retains sampling support. A binary hierarchy combines triangle power and receiver distance bounds. Stratified screen-probe proposals retain the exact tree-walk and area PDFs. Screen probes integrate
`Le/pdf_solid_angle` into equal-area angular cells; this avoids enlarging thin
emitters by treating importance samples as uniform angular samples. World-hit
shading adds explicit emitter irradiance. Supported diffuse hit-emission paths are
partitioned out to avoid double counting; specular primary hits retain emission.
Screen-feedback continuations subtract the already-accounted emission term.
This is explicit area sampling, not a claim of full emitter ReSTIR/MIS parity.

The hierarchy is bounded to 262,144 triangle entries (up to 32 MiB); overflow
surfaces retain ordinary hit-emission sampling. Unchanged batches reuse the GPU
hierarchy; geometry, transform, native material-pixel, and packing changes rebuild
it. No emitter dispatch occurs when there are no eligible emitters. Disabling
`emissive_sampling` releases its large buffer on the next scene update and returns
to ordinary hit sampling. Primary diffuse budgets are unchanged; visibility costs
must be counted separately.

Glossy classification resolves compatible rough probes and skips sky. Remaining
sample IDs go into a bounded appended queue and use an indirect GPU dispatch.
Compaction can be disabled independently for scheduling comparisons. Firefly
marking and cleanup use separate dispatches and immutable source neighborhoods,
followed by the existing ratio reconstruction, temporal history and a-trous
filters. The reference rank thresholds, bounded-VNDF sampling and default a-trous
reconstruction/dual-history equations have now replaced the custom rules. Full
transport/material parity remains under audit; a passing history-count check alone
does not establish reflection quality.

Atlas placements now remain stable across ordinary appearance/removal and source
resize. Free intervals admit new captures; compaction occurs only if fragmentation
prevents a preflight-proven fit. This removes whole-atlas copy churn as well as
repeated geometry preparation. Emitter storage similarly retains physical capacity
across flicker while its logical tree size follows the current active set; turning
emitter sampling off releases the large allocation.

When no temporal upscaler/compositor needs velocity, the GI prepass uses a velocity
target in its own resource scope. Disabling GI releases it with previous-position
storage. With DLSS/FSR2, the native velocity target is shared and remains owned by
the upscaler. No GI motion pass, capture, queue, denoising or composition runs when
the backend is disabled.

AMD GI hit normals now come directly from native packed source/pose buffers and shared triangle positions, with separate geometric and interpolated vertex normals. The authored-light/material boundary and the narrow upstream transform correction have owner approval. Native source-texture evaluation and the approved coverage correction are implemented. Final qualification and outstanding consequential findings remain in the [live correction record](#snapshot-amd-gi-consequential-corrections); this is not a complete-baseline or hardware-performance claim.


<a id="snapshot-rt-materials"></a>

## Snapshot: docs/internals/rt-materials.md

# Raytraced GI material preparation

AMD GI now evaluates native material source at triangle hits. The opt-in
[transport validator](#snapshot-rtgi-validation) retains the older capture
primitive described below. These are distinct material paths sharing RT geometry.
Current qualification and open boundaries are tracked in
[the consequential correction record](#snapshot-amd-gi-consequential-corrections).

## AMD GI source evaluation

`environment/rt_material_source.{h,cpp}` compiles the native Forward+ material's
vertex and fragment programs into the GI compute shader. It reads native material,
global and instance uniforms and native texture/sampler bindings. Source vertex
attributes retain their native packed layout; GPU copies supply device addresses
only when their source revision changes. No CPU mesh readback or triangle texture
atlas is used by AMD GI. Vertex outputs and private varyings are interpolated at the
hit barycentrics. Source geometry/shading normals remain separate and transform to
world space once; screen shading retains native normal maps.

Implicit 2D texture reads use point LOD for ordinary hits and AMD's triangle/cone
footprint for emitter proposals and targets. Explicit authored LOD/gradient reads
remain explicit. Post-vertex UV0 emitter coordinates round through half precision, matching AMD's light builder; native vertex implicit reads use mip zero independently of the fragment footprint. An opt-in compiler analysis reconstructs affine UV0/UV2/varying mappings and uniform scaling/rotation/translation at triangle corners, then uses AMD's unchanged triangle/cone LOD. Direct UV0 aliases retain the existing helper. This adds no material reruns, ray queries, buffers or passes. Nonlinear, texture-driven, loop-dependent and other unqualified reads produce an emitter-program warning and retain their existing fallback; they are not certified as correctly filtered. Shader programs requiring raster derivatives are reported as
unsupported; they are not replaced with zero derivatives. Unsupported surfaces
are skipped individually, so they can leave geometry/material omissions; this
is not support for those classes. Supported surfaces keep running.

The source context is rebuilt from active scene inputs. Resource allocation and
shader initialization remain behind the GI enable gate; disabling the consumer
releases its source resources. `GODOT_AMD_GI_VALIDATE_SOURCE=1` adds a diagnostic
pass/readback for known-value material tests; it has no resource or dispatch when
unset. Shader compilation/first-use costs and target-hardware performance remain
unqualified.

## Legacy capture path

The following sections describe the uncached transport validator and standalone
material-bake diagnostic. Their atlas, tile-size and preparation-budget settings
no longer control AMD GI material fidelity or readiness.

## Why a native material pass

A ray-query hit identifies geometry and barycentrics; a shadow only needs visibility.
GI also needs surface properties, including off-screen textures and emission. Those
properties are not stored in a BLAS. Copying a few StandardMaterial3D parameters
would omit custom shaders and many material inputs.

`RendererRD::RaytracingMaterialCapture` evaluates a surface through the Forward+
material shader variant already used by Godot's baking tools. The output comprises
albedo/alpha, encoded normal, occlusion/roughness/metallic/SSS, and HDR emission.
It does not evaluate direct or indirect lighting. This primitive is independent of
the eventual GI algorithm and does not create an acceleration structure.

GI scene captures request the underlying geometry normal, before normal-map application, as required by GI-1 hit shading. The standalone material-bake diagnostic retains the shaded normal by default. Normals use Forward+'s existing best-fit encoding. Decode with
`normalize(encoded.rgb * 2 - 1)`, not just `encoded.rgb * 2 - 1`. The captured camera
transform is identity, so these normals include the supplied object's world transform.

## Page representation

The caller selects a surface, starting triangle, triangle count, tile size, transform,
and optional material override. A page contains at most 1024 triangles, at most 32
columns, and square tiles of 2 pixels or from 4 to 64 pixels. Counts clip to the remaining surface
triangles. Indexed triangles are expanded into a temporary non-indexed mesh while
preserving native packed source attributes. `rt_material_expand.glsl` expands the
selected index range directly from GPU vertex/normal, attribute, skin, and index
buffers. The native material vertex shader decodes compressed attributes as usual.
Original vertex IDs travel in a separate SSBO; no source-buffer readback occurs.

Triangle `i` occupies tile `(i % columns, i / columns)`. Its corners, relative to the
tile origin, are `(1, 1)`, `(tile_size - 1, 1)`, and `(1, tile_size - 1)` in pixel-edge
coordinates. For barycentrics `(u, v)` corresponding to the second and third corners,
the continuous position is `tile_origin + 1 + (tile_size - 2) * (u, v)`.
For the compact 2-pixel fallback, corners are `(0,0)`, `(2,0)`, `(0,2)`;
the hit sampler always selects pixel `(0,0)`, at barycentrics `(1/4,1/4)`.
This retains one native material sample per triangle, with reduced texture,
cutout, and smooth-normal detail. It never drops geometry.
Rasterization samples pixel centers. Uncovered texels remain clear: there is no
edge dilation or mip generation. The ray-hit sampler clamps/folds barycentric
addresses to covered texel centers; ordinary bilinear sampling across tile edges
would read another triangle or clear padding.

The output attachments are three RGBA8 textures and one RGBA16F texture, plus R32F
and depth attachments needed by the existing material pass. At the largest allowed
page, the six attachments occupy approximately 112 MiB before driver overhead
(2048 squared texels times 28 bytes, arithmetic only). This bound is not a sensible
per-mesh default or a total cache budget. The GI adapter uses fixed 1024-triangle
chunks, adaptive tile sizes and an unused-capture residency budget of one quarter
of the atlas limit, with a 120-update age limit. Active source geometry and capture
targets remain separate allocations and belong in total memory measurements.

## Renderer and lifetime contract

- Construction allocates nothing. `capture()` replaces previous resources; `clear()`
  and destruction free the framebuffer, textures, SSBO, and temporary mesh.
- Internally, `prepare()` builds reusable expanded geometry and capture targets;
  `render()` evaluates the current material, transform, textures, and instance
  uniforms into them. The GI scene packs captures into demand-allocated atlas layers
  bounded by `amd_gi/material_atlas_mb`. It re-prepares a page when its source mesh/surface/triangle
  range, immutable vertex-buffer RID, or mesh data revision changes, and frees
  excess pages when the scene shrinks. Pose changes do not re-prepare geometry.
- Call only on the rendering thread, before preparing the frame's render lists.
  Capture uses the secondary render list and the renderer's material-bake state.
- `get_texture()` returns borrowed GPU handles; `readback()` synchronously copies
  four output images to the CPU. The public diagnostic
  `RenderingServer.bake_render_triangle_material()` captures, reads back, and releases
  its resources in one call. Frame rendering never calls that readback API; the
  opt-in validator uses the GPU capture class directly before scene render lists.
- Only Forward+ reports capture support. Other renderers return an empty array
  through the public API. The tested graphics API is Vulkan.
- Material capture uses descriptor set 4, bindings 0–1, only in `MODE_RENDER_MATERIAL`.
  Binding 0 has a 64-byte header: layout `uvec4`, instance color `vec4`, custom
  data `vec4`, and instance information `uvec4`, followed by 32-bit source vertex IDs.
  Binding 1 borrows the current native pose buffer, or a dummy buffer for static
  captures. The first vector stores tile size, columns, source vertex count, and
  normal/tangent/pose presence bits and bit 3 selecting geometry-normal output. Scene flag
  bit 9 selects triangle placement; regular UV2/projection baking binds an existing
  dummy buffer and does not read it. Ordinary scene shader variants have no new set.
- UV0 and UV2 remain material inputs. Atlas placement must never overwrite them.
  Shader `VERTEX_ID` refers to the original mesh; internal placement uses the
  expanded mesh's `gl_VertexIndex`.
- Pending material updates are flushed before the draw. The surface's default
  material must be queried with `mesh_surface_get_material()`; geometry readback
  does not populate `SurfaceData.material`.

## Limits before integration

Preparation now uses metadata-only mesh accessors, GPU expansion, and native
material rendering. The public `SurfaceData` readback/CPU decode path is no longer
used by `prepare()`. The standalone diagnostic API still reads capture outputs.

Active captures retain their atlas placements. New captures fill free intervals; only fragmentation or a tighter budget triggers compaction. Source chunks stay fixed at 1,024 triangles, independently of packed atlas offsets.
Packing changes copy rows across atlas layers without preparing expanded geometry
again. Unused captures survive for up to 120 scene updates, subject to an LRU
unused-residency budget of one quarter of `material_atlas_mb`; active captures are
retained. This bounds inactive native targets/expanded buffers separately from the
packed atlas. It does not make active capture memory equal to the atlas budget.

A metadata-only preflight counts unique material keys before capture begins.
`material_adaptive_resolution` (default on) reduces the selected 8/4-pixel maximum
to 4 or 2 as necessary to fit the atlas budget. Reduced resolution remains in use
until the scene consumer is recreated or its size/budget/adaptation setting changes;
visibility changes cannot alternate capture resolutions each frame. If even the
compact representation cannot fit, preflight reports the limit without repeatedly
preparing an incomplete scene. The source [gameplay audit](#snapshot-amd-gi-gameplay-audit)
records the former behavior at commit `3038a14`.

Vertex/index/attribute/skin region edits advance the mesh's data revision;
vertex/index edits also invalidate shared BLAS geometry. Surface replacement is
detected through the shared geometry build revision. Attribute-only edits do not
force BLAS reconstruction.

Material pixels now persist for materials with local uniforms and tracked image
textures. Material/shader updates advance a content revision. Image-backed 2D,
layered, and 3D texture uploads advance texture revisions; proxy lookups follow the
actual owner and compare the backing GPU RID as well as the revision. Replacement,
material rebinding, source-data edits, and model-transform changes invalidate the
page. Only dirty pages render and copy into the hit atlas.

TIME, global/instance uniforms, viewport textures, drawable textures, and external
GPU textures retain per-frame evaluation because their values are not covered by
that static content contract. The other pages remain cached. The dirty-material
rig verifies image updates in place, emission parameters, shader changes, TIME and
global uniforms. Bounded preparation work per frame, higher material resolution,
and further capture-memory reduction remain work.

The public API takes a mesh, not a scene instance. It does not apply skeleton poses,
blend shapes, instance uniforms, MultiMesh colors/custom data, or particles. The
internal entry point receives an instance-uniform offset, optional mesh instance,
and MultiMesh element color/custom data/ID. These are applied at the same point
as native instancing before material evaluation.
It reads the native GPU skeleton/blend-shape output before material evaluation: float3
positions followed by packed octahedral normals/tangents. Original UV/color/custom
inputs still come from the retained source mesh. No second skinning pass or pose
readback is performed. Godot importers disable attribute compression for these
meshes; manually compressed pose buffers are rejected. Four/eight-weight skeletons,
combined blend shapes, and FSR2 pose-buffer swapping have a separate deformation rig. Vertex shader code runs, including the provided model
transform, but this does not prove correspondence with deformed RT geometry.

There is no scene camera or scene screen texture in this pass. Camera-dependent,
screen-reading and multipass hit materials are unsupported. Forward-only transparency
stays in rasterization; depth-writing mix-alpha materials use stochastic coverage.
TIME-driven fragment shading refreshes each frame. The shared GI query forces
non-opaque candidate processing while retaining the same opaque BLAS used by RT
shadows. Cutouts use captured alpha; fractional blend coverage uses a stochastic
acceptance test. Texture/cutout fidelity is limited by the material tiles.

Fixed tiles can undersample material detail. The adapter captures the bounded
camera-centered GI collection, sharing compatible instances, rather than the entire
world. The live preparation budget limits new chunks per scene update; a partial
scene is never published as ready.

## Validation

Run `docs/validation/shadow_validation/run.sh material` under Vulkan. The rig checks
analytically known outputs for indexed/non-indexed and compressed geometry, original
UVs and vertex IDs, custom attributes, tangent-space normals, transforms, material
and texture updates, cutouts, range clipping, and existing UV2 baking. It exits
nonzero on any mismatch. This is a correctness test, not a GI performance benchmark.

Also run the geometry image regression when modifying shared scene shaders or
renderer setup. It verifies that the exercised normal shadow-rendering path remains
unchanged while no capture is requested. Hardware timing and resource accounting
remain necessary for an eventual zero-cost-when-disabled GI backend claim.


The GI adapter packs capture chunks into 32-triangle rows across its atlas layers.
The source captures keep their own pixels; moving a packed address requires only
an atlas copy. Fixed source chunks are independent of atlas placement. A chunk's
first triangle and requested count both participate in preparation invalidation;
only source range changes rebuild expanded geometry.
The `amd_gi_atlas` rig covers relocation and surfaces spanning multiple layers.

## Shared captures

The GI adapter keys capture pages by mesh, surface, material, pose and (when
required) instance/element context. Conservative shader input tracking permits
identity-transform evaluation only for transform-independent materials without
normal/tangent inputs or instance uniforms. Their captured normals are local;
HitData.triangles bit 31 marks inverse-transpose transformation at a ray hit.
World-dependent captures keep world normals. The current shared HitData is 64 bytes: material/layer metadata, shared position/index buffer addresses, source-normal address/layout, and reserved padding. The uncached transport validator still uses captured normals. AMD GI reads source normals directly as described below.

Atlas resize preserves existing layers before releasing the old textures, with
both allocations briefly live. Lowering the budget invalidates addresses in removed
layers. Allocation grows on demand; expanded capture targets and geometry are
outside the atlas setting and must be included in total memory measurements.
CPU-managed MultiMesh collection uses visible counts, element bounds, stable
instance/element ordering, and the existing shared mesh BLAS. GPU-indirect data
and particles cannot use this CPU collection contract.

Forward-only transparency is selected using the native shader predicates:
`uses_alpha_pass()`, no `uses_depth_in_alpha_pass()`, no always-depth draw, and no
material shadow casting. Only a single-pass surface can be excluded this way.
This avoids capturing presentation-only shells or treating them as opaque blockers;
opaque vertex deformation remains unsupported. Depth-writing mix-alpha materials
now use the captured alpha for stochastic coverage in GI ray queries. This retains
opaque portions of imported mixed-opacity meshes without making glass solid.
It does not implement refraction or tinted transmission.

The GI adapter exposes 4/8-pixel triangle tiles separately from the native capture
API. Four-pixel tiles use 128×128 array layers and one interior triangle sample;
8-pixel tiles retain more barycentric detail. This is a material/normal fidelity
tradeoff, not a lower geometry LOD or a different diffuse ray budget. Captures with
identical non-white instance colors can share when their other inputs are context
independent; exact color joins the material-cache key. Changes in live tile size
release/recapture the atlas and advance history revision.

## AMD GI source hit normals

AMD GI no longer reads its hit normal from the material atlas. `amd_gi_geometry_inc.glsl` reads the shared triangle indices/positions and native packed vertex normals through buffer device addresses. Normal/tangent packing, compressed axis-angle frames and the current skeleton/blend-shape output follow Forward+'s decoding. These GPU reads are declared to RenderingDevice for transfer/compute synchronization; there is no geometry readback in rendering.

Local geometric normals use Godot's clockwise triangle winding; interpolated vertex normals remain distinct. Both use the inverse transpose exactly once, followed by hit-facing orientation. Reservoir/continuation shading uses vertex normals; selected-light cache shading and shadow-ray offset use geometric normals, with vertex normals retained for environment sampling. This implements the [approved correction of specific upstream transform errors](#snapshot-amd-gi-normal-space-investigation). It does not add normal-map evaluation to AMD hit paths that omit it. The screen-space shading-normal path continues to include native normal mapping.

RayHit is now 96 bytes to preserve both normals in full precision. Atlas albedo, alpha, roughness and emission remain a consequential fidelity limitation; source-normal access does not make that material representation reference-equivalent. Run `run.sh amd_gi_normals`, `run.sh amd_gi_deformation`, and the consequential/reflection regressions when changing this access path.


<a id="snapshot-rtgi-validation"></a>

## Snapshot: docs/features/rtgi-validation.md

# RT GI transport validation

An optional **uncached diffuse transport integrator** now connects scene geometry,
native material capture, Vulkan ray queries, and Forward+ indirect lighting. It is a
validation checkpoint for the AMD GI port. It is not the optimized AMD GI-1.x backend
and must not become a shipping graphics preset.

The renderer traces independent diffuse paths for each internal-resolution pixel.
Secondary hits read captured albedo, normals, metallic, alpha, and HDR emission.
Directional, omni, and spot lights contribute direct illumination at these hits,
with additional visibility rays. More secondary encounters add diffuse bounces.
The visible surface's albedo and metallic term are applied by Forward+ before fog,
tone mapping, and temporal upscaling. Native direct lighting and RT shadows remain
the baseline being compared.

## Diagnostic captures (not implementation progress)

Build this fork, then run from `docs/validation/shadow_validation` with Vulkan and
the harness's normal Xvfb/lavapipe dependencies available:

```sh
RTGI_SAMPLES=1 ./run.sh gi
```

The rig creates a room with colored walls and white boxes, fixes the camera and
exposure, and saves PNGs in `out/gi/`:

- `gi_disabled.png`: direct lighting and RT shadows.
- `gi_one_bounce.png`: one secondary diffuse encounter.
- `gi_three_bounces.png`: three secondary diffuse encounters.
- `gi_indirect_zero.png`: GI enabled, but the light's indirect energy set to zero.
- `gi_material_changed.png`: the right wall changes from green to blue; it does not
  cast shadows, but must still contribute reflected light.
- `gi_disabled_after.png`: GI disabled again, with original scene settings restored.

`score_gi.py` requires visible indirect light, additional energy from extra bounces,
and a corresponding color change on the white box. Zero indirect energy and disabling
GI must each restore the disabled image byte-for-byte. The printed memory counters
are engine-reported allocations, not a hardware profiler. Software Vulkan timings
cannot predict performance on the 780M or RTX 5090.

## Controls

These project settings are live and can be changed with `ProjectSettings.set_setting()`:

| Setting under `rendering/global_illumination/rt_validation/` | Default | Meaning |
| --- | --- | --- |
| `enabled` | `false` | Explicitly opt into the validation integrator |
| `samples_per_pixel` | `1` | Independent paths per internal pixel; 1–4096 |
| `bounces` | `2` | Secondary diffuse encounters; 1–8 |
| `max_distance` | `50.0` | Ray segment limit and camera-centered gathering box half-extent, in world units |

For example:

```gdscript
ProjectSettings.set_setting("rendering/global_illumination/rt_validation/samples_per_pixel", 1)
ProjectSettings.set_setting("rendering/global_illumination/rt_validation/bounces", 3)
ProjectSettings.set_setting("rendering/global_illumination/rt_validation/enabled", true)
```

The project must already enable RT shadows at startup so uploaded mesh buffers have
acceleration-structure usage. This mode requires Vulkan Forward+, a WorldEnvironment,
one view, and no MSAA. SDFGI, SSIL, VoxelGI, and lightmaps must be disabled for the
comparison; native settings are preserved, not changed automatically. Set ambient
light to zero for a pure transport comparison, as the rig does; existing authored
ambient light otherwise remains part of the baseline. The shared
geometry budget can defer initialization until later frames.

## Compare with native Godot GI

`./run.sh gi_compare` now uses the actual cached AMD diffuse pipeline at low ray
budgets, with denoising enabled, against native VoxelGI and SDFGI. See the
[current comparison protocol](#snapshot-amd-gi).

The original 512-sample images remain historical transport debugging references.
They are not representative progress images or fair runtime-budget comparisons.

## Scope and limitations

This mode has no radiance cache, screen probes, temporal accumulation, denoiser,
glossy reflections, or environment/sky sampling. It uses Lambertian secondary
reflection, two-sided secondary shading, ideal point/spot/directional light sampling,
and a small ray-origin offset. It is not a perfect path-traced reference for all
Godot material models. High sample counts produce useful stills at deliberately
high cost; the results say nothing about a viable 780M quality tier.

It accepts MeshInstance3D geometry, including native skeleton/blend-shape output.
CPU-managed 3D MultiMeshes are supported with per-element material inputs.
GPU-indirect MultiMeshes, particles, material overlays, lightmaps, vertex-deforming, screen-reading, unsupported blend modes,
unshaded, and multipass materials are not supported. Area lights are not supported;
textured light projectors and distance fades also suppress the validation contribution. Unsupported
geometry/materials and capacity overflow suppress the GI contribution instead of
silently rendering a partial scene. The safety limits are 65,536 surface instances
and 1,024 lights. Material atlas layers grow on demand up to the live AMD GI
`material_atlas_mb` setting; each layer holds 1,024 tiles, packed in 32-triangle
rows. Expanded capture geometry persists until source revisions change. Compatible
instances share captured material pixels; tracked static material inputs reuse
pixels, while dynamic inputs retain native per-frame evaluation.

Each triangle uses an 8-pixel tile. This limits texture/normal-map/cutout detail and
does not establish the final material-cache representation. Geometry is collected
outside the view frustum and independently of shadow-caster flags, but only within
the configured camera-centered volume. Rays are clipped to that volume.

No resources or pipelines for this mode are initialized until it is requested.
Disabling destroys the validation TLAS, atlases, buffers, and pipeline, releases
GI-only BLAS entries, and clears each rendered viewport's validation output. Shared
shadow BLASes survive. Deferred driver destruction follows normal RenderingDevice
lifetime rules. Exact disabled images do not establish hardware timing equivalence.
Native material-bake renderer buffer pools can remain allocated after this mode was
used. In the lifecycle rig, texture bytes returned exactly to the cold baseline after
12 drain frames, while buffer bytes remained 761,760 above it. Do not claim complete
cold-start memory equivalence after toggling. A project that never enables this mode
does not run captures or initialize these validation resources.

DLSS/FSR run after composition at their normal position in the renderer. The
validation signal has no history to reproject, but that ordering alone is not a
completed DLSS/FSR compatibility test. Neither upscaler was exercised by this rig.

The first bounded world-cache/screen-probe path is now implemented separately; use
[AMD GI progress captures](#snapshot-amd-gi) with denoising enabled to
evaluate actual implementation progress. Overall status remains in
[AMD_GI_IMPLEMENTATION.md](#snapshot-amd-gi-implementation).

### Forward-only transparency

Transparent passes that neither write depth nor cast material shadows stay in the
native raster path. This includes outline shells, stencil-only masks and additive
effects. They do not become opaque GI occluders and do not disable GI for the scene.
Opaque/cutout surfaces retain normal transport. Depth-writing mix-alpha materials
use stochastic opacity: fully opaque texels remain surfaces, zero-alpha texels
transmit, and fractional texels select coverage probabilistically. The same test
applies to GI visibility rays; native RT-shadow behavior is unchanged. This is
straight-through opacity, not refraction or colored transmission. Multipass and
unsupported deformation retain strict checks. Forward-only effects do not emit GI.
`amd_gi_overlays` checks that physical-scene GI and history survive these passes.


<a id="snapshot-gi-history"></a>

## Snapshot: docs/HISTORY.md

## Approved affine emitter filtering — 2026-10-24

`[software Vulkan correctness; hardware cost unmeasured]` The owner approved
correcting the clearly understood alternate texture-layout/scaling/rotation cases.
The compiler reconstructs affine mappings at triangle corners for AMD's existing
LOD formula. Ordinary UV0 uses the existing helper; no extra material invocations,
rays, passes or GPU buffers are added. Complex mappings outside the certified
subset warn and retain their fallback. This is not a general custom-shader fix.

The new oracle passes 704 known mip/coordinate samples (maximum error 0.00008534),
and the existing native material oracle passes 256 samples (0.00000142). The
quarter-budget emitter room passes its original thresholds. All five unsupported
mapping fixtures produce the expected diagnostics and finish without renderer errors. Details and limitations
are in [the adapter decisions](#snapshot-amd-gi-adapter-decisions).

## Consequential AMD GI correction work — 2026-10-23

`[in progress, not a release]` Restored probe filter/LRU/units/default near-field SSGI,
reference light-list/reservoir behavior, reflection feedback and precision, primary
normal/roughness contracts, compact work dispatch and object-space alpha hashing
using shared triangle buffers. [The live record](#snapshot-amd-gi-consequential-corrections)
accounts for every finding and records remaining consequential gaps. Native authored
lighting, localized normal transforms, both multibounce ownership fixes, native emissive classification, flat light-grid axes, distance-only overflow handling and invalid old-light rejection have explicit approval. The firefly input snapshot was withdrawn; in-place AMD cleanup is restored.

Quarter-budget cache/hit/multibounce integration and opacity endpoints pass on software
Vulkan. Manual/auto exposure integration passes with restoration MAE 0.005276 and no
history reset beyond frame zero. The emitter fixture passes reference light-settings
transitions and its unchanged image thresholds. The final combined sky and multi-light controls now pass; the retained sky residual at 64 frames is consistent with source tile-update aging and reaches zero at 128/256. No history shortcut was added. The reflection regression also passes at 641×359, including emitter motion/return, resolution variants and buffer release. No Windows build or target-hardware result
is represented by this checkpoint.

## Complete AMD GI source comparison — 2026-10-23

`[source comparison]` Compared Capsaicin `914b91596cd119eda85fbc1d3c7ee6ac391b1452`
(v1.3 package, GI-1.2 renderer) against fork `d932f4a` plus the preexisting local
follow-up. [The full report](#snapshot-amd-gi-full-comparison) and
[coverage appendix](#snapshot-amd-gi-comparison-coverage) account for all 70 main shader
functions, 51 fork passes, 38 GI options, 19 dependency options and 29 fork settings.
The source comparison is complete; the requested implementation is not.

Confirmed differences include the never-incremented center-reuse counter, altered
probe filter/LRU, SH normalization, missing default near-field SSGI/bent-cone path,
disabled default reflection-hit feedback, rough-reflection scaling/input, coarse
hit materials, and reservoir/precision/host-contract differences. Independent
checks match all 16,384 packed blue-noise words; the SH scale comparison gives
pi/4 for identical inputs before rounding, not a measured frame-brightness ratio.
No renderer code, build or preview was changed during this audit. No deviation was
approved, and the earlier rapid-emitter/sky failures remain open.

## AMD GI environment cones and integrated validation — 2026-10-23

`[shadow_validation]` The integrated d932f4a revision passes diffuse, reservoir,
multibounce, reflection, FSR2, native material and controlled gameplay-history
checks. It also **fails** the rapid-emitter removal and pulse-response quality
fixture. Removal residual is 2.42% at 32 frames against a 2% limit; short off/on
pulses blur together. The limits were not lowered and this is not a completed
baseline. Crossroads quarter/one PNGs and provenance are in the workspace preview.
The Windows clang editor artifact for d932f4a was built successfully in Actions.

The follow-up restores Capsaicin's environment mip/cone sampling and zero-weight
storage for occluded reservoirs. Native octahedral skies convert to an ordinary
cubemap mip chain only while GI is enabled; static revisions reuse it. An independent
4,096-direction GPU check measures 0.002671 maximum channel error against an
analytic direction texture and 0.000932 maximum mip-mean error, including 64x64
source interpolation and half rounding. The 4,096-case equation oracle, now also
covering cone LOD, has maximum error zero. These are software-Vulkan measurements.

## AMD GI GridStream, cache and probe corrections — 2026-10-23

Work after `848af68` replaces proposal trees with reference GridStream, restores
front-face primary emission and rough secondary BRDF weighting, packed radiance
sums/integer updates, reference cache capacity and RNG, delayed indirect updates,
probe reprojection/guiding/eviction and removal of custom history wipes. The sixth
GI-only native prepass attachment supplies primary albedo and metalness. Both
optional temporal feedback and light-reservoir reuse now default off, as upstream.

`[shadow_validation]` Intermediate integration passed diffuse quarter/one budgets,
light-change decay and exact cold zero-energy/disabled controls. At 128 frames,
zero-energy residual display-RGB gain was 0.005758 of its lit value. Fresh/reused
light gain ratios were 1.004315 and 0.989611. Multibounce ownership passed 66 frames.
The updated probe code passed 28 reservoir and LRU ownership scans. These are
intermediate software-Vulkan regressions, not target-hardware performance results
or proof that the final integrated revision has passed.

The front-facing emission change exposed a native Vulkan winding mismatch in the
mirror test. A separate 48-ray test confirmed the required instance-facing flip.
A full-scene Crossroads trial exceeded the existing material atlas at 5,647,232
padded triangles; the default collection change was withdrawn. The atlas and
scene-range departures remain open, not approved. See the current
[reference audit](#snapshot-amd-gi-reference-audit) before describing completion.

## AMD GI reference-fidelity correction — 2026-10-23

The earlier “scoped pipeline implemented” status is withdrawn. Passing the fork’s
regressions did not establish that its estimators, history rules, material inputs
or sampling matched AMD. No algorithmic departure has owner approval. The
[source-by-source correction ledger](#snapshot-amd-gi-reference-audit) uses Capsaicin v1.3
`914b91596cd119eda85fbc1d3c7ee6ac391b1452` as the reference and `d4b39f5` as the fork
baseline. Earlier measurements below describe that earlier implementation.

Corrections restore the diffuse denoiser’s radiance sums, sample eviction,
vignette/fallback handling, pre-update blur radius, relative-depth weights and
center tap; reference blue-noise dimensions and bounded-VNDF GGX sampling; the
default reflection a-trous reconstruction and dual surface/virtual history;
separate geometry/shading normal inputs; and a separate world-space hash of
multiple hit reservoirs instead of one reservoir per directional radiance cell.
Reference cache temporal weighting and zero-update aging replace the custom
hit-count weighting and light-change override. Glossy cache lookup restores
hit jitter, lifetime touch and the invalid-sample sentinel on cache misses.

`[shadow_validation]` The numerical Vulkan oracle compares production helper
functions with independently extracted upstream equations over 4,096 cases,
including zero-update cache aging. Maximum observed difference is zero. The
rendered reservoir test verifies every prefix, compacted hit owner/slot, packed
confidence and allocation release, and exercises multi-hit entries and reuse.
Its resampled/exhaustive indirect gain ratios are 1.001590 for identical lights
and 0.985010 for varied lights. Primary budget remains approximately one quarter
ray per internal pixel with multibounce and denoising enabled.

The integrated diffuse, reflection and FSR2 regressions pass. Quarter/one diffuse
display-RGB gains are 0.035895/0.035232; GI-off restores the diffuse fixture exactly
and texture allocations return to baseline. The reflection rig checks 344 frames,
with mirror-emitter return overlap 0.992 and compact/direct dispatch linear-RGB
MAE 0.000422. FSR2 quarter/one gains are 0.039776/0.038269. These are fixture
regressions on software Vulkan, not images matched against Capsaicin or gameplay
quality/performance measurements. The Linux editor builds and updated property
documentation is generated with doctool. A final 28-frame GPU check verifies
reservoir and LRU scans after sharing their mutually exclusive workgroup scratch
to stay within the 32 KiB shared-memory requirement. Repository hooks pass.

The light-grid proposal sampler, integrated area-light estimator, hit-material
representation/BRDF, remaining cache representation/defaults and probe/multibounce
comparison remain unfinished. The reference reflection split-estimator alternative
is also not ported. No final gameplay, Windows-build or 780M/5090 performance
acceptance follows from this correction checkpoint.

## AMD GI sampling, motion and material integration — 2026-10-23

`[shadow_validation]` Local implementation after the `3038a14` audit adds native
previous-surface reprojection, stable light identity remapping, GPU material expansion,
capture residency and persistent placements, explicit emissive-triangle sampling,
BRDF-guided probes, and reflection classification/compaction and firefly cleanup.
No primary-ray budget was increased to make the checks pass. The controls and port
differences are in [features/amd-gi.md](#snapshot-amd-gi).

The native material rig passes compressed/indexed/non-indexed inputs, custom attributes,
UV2, normal maps and the compact two-pixel capture. The diffuse, native deformation
and FSR2 rigs pass; GI-off texture allocation returns to the baseline. The MultiMesh
rig passes native element inputs and live changes, including a 65,537-element
procedural instance explicitly excluded from GI. Multibounce receiver ownership and
allocation checks pass at quarter rate and continuation probability 0.3.

Explicit emission-only sampling has linear receiver energy 0.029353, versus 0.032935
with hit-only sampling at the same primary budget. The difference is a coarse-probe
reconstruction/variance comparison, not proof of an unbiased final image. Repeated
emitter flicker retains history and responds within the four-frame capture windows;
removed-emitter receiver energy falls to 0.000001 after settling. Moving-flashlight
indirect gains are 0.003707/0.003877 linear RGB. Its removal tail is 18.768% after six
frames and 0.188% after 26, without a global reset. These runs use conventional
denoising. These measurements precede the final two-dimensional sample-sequence and
secondary-metal shading refinements. Software Vulkan establishes behavior, not hardware frame cost.

`[game]` fps-proto `996f0f9`: default-budget Crossroads, Fieldway and Hideout reach a
ready GI scene. Crossroads also passes with authored high grass enabled. With bounded
preparation, its new captures are split into updates of at most 64 chunks; the
completed scene retains 1,243 captures and prepares/draws none on subsequent static
frames. Automatic capacity adaptation uses two-pixel triangle tiles in Crossroads
and four in Fieldway, with the documented loss of hit-material detail. This is
readiness/residency evidence, not final visual acceptance or 5090/780M performance.

The subsequent complete 64-draw Crossroads translation covers 16 meters without
global resets or pending material preparation. New capture preparation peaks at
16 chunks per update. The gold-weapon and wall-intersection sequences run through
the game's main-menu/sandbox path at fixed simulation time; they are visual
diagnostics, not frame-time measurements.

The final shader refinement uses independent two-dimensional temporal sampling
increments and AMD's diffuse secondary-metal approximation. The full glossy rig
passes with 863 reflected-emitter pixels, 14.859-pixel emitter displacement,
0.936 return overlap, and 0.068/0.000 residual patch overlap after motion/return.
Compacted versus direct dispatch has linear RGB MAE 0.000875. GPU reflection queue
and sample checks pass over 344 frames. Moving-metal continuity improves to
5 fresh samples out of 6,109 measured samples; light pulses do not globally reset
history and flickering geometry prepares only once. The sampling rig validates
ownership/LRU state over 694 frames at fixed primary budgets, including 1/16 rate.
Native VoxelGI (128/256 and alternate normal bias) and SDFGI (default/fine) comparisons
pass, and every disabled comparison image matches exactly. Linux editor and affected
release translation units compile; Windows artifacts are built separately through CI.

## Historical gameplay audit reproduces AMD GI blockers — 2026-10-23

`[shadow_validation]` Engine `3038a14` plus opt-in logging: three light pulses
caused six global resets. All 6,109 measured glossy samples across 16 moving-metal
frames had history count 1; after stopping, the mean recovered to 11.50. A mesh
hidden/shown six times was prepared on every appearance. These are failing-behavior
reproductions, not visual acceptance passes. Quarter primary budget, denoising on.

`[game]` fps-proto `996f0f9`, Vulkan lavapipe, FSR2 Performance at 641×359,
grass/soft RT shadows off: the actual golden AK translated 1 mm per frame rejected
all 21,225 measured glossy samples' history over 12 frames, without global resets.
After stopping, mean history recovered to 13.41. Flashlight off/on caused two global
resets. At stationary spawn, 406 material-page preparations occurred across 11 of
24 draws before equipping the gold weapon. Preparation uses synchronous source
GPU-buffer readback; these counters establish churn, not hardware stall times.
Crossroads and Fieldway exceeded the default atlas cap and suppressed GI on all
eight observed enabled frames. Hideout became ready; its reported missing lighting
was not reproduced by this readiness check.

The previous scene-membership fix and settled images did not establish gameplay
quality. Emissive-triangle sampling, object velocity reprojection and separate
reflection firefly cleanup are missing; local invalidation and material residency
are defective. See [the full audit](#snapshot-amd-gi-gameplay-audit) for evidence, remaining
unknowns. This paragraph records the old audit, not the status of the subsequent implementation.

## Sandbox scene changes repeatedly discarded GI history — 2026-10-23

`[game]` fps-proto main `307c068`, launched through the actual main menu into
Systems Sandbox, reproduced repeated global resets at the stationary spawn. The
electrical field toggles visible emissive cylinder meshes; their changing collection
membership altered the scene signature. The same mechanism reset history when
walking across collection boundaries. A 48-frame stationary segment had 23 resets;
the full launch/stationary/frozen/translation/rotation sequence had 29. After matching
geometry by stable identity and invalidating local old/new bounds, the repeated
sequence had one initialization reset. Hazard animation stayed enabled during the
live segment. Vulkan lavapipe, FSR2 Performance, 641×359 output, default AMD GI
settings; this establishes reset behavior, not target-GPU performance or complete
visual acceptance. The game still reports its observed shutdown resource leaks.

`[shadow_validation]` The collection-churn rig previously reset 15 times after
initialization during boundary crossings and additions/removals. It now preserves
history and emits one local region per change, including a material edit. Camera
rotation emits none. A moving spotlight with the game's default 26-degree cone,
45 m range and energy 6 has no movement resets. Linear-RGB indirect gains are
0.003669/0.003838 for its two aim directions; resampled versus exhaustive lighting
has MAE 0.000320 and mean ratio 0.994457. Switch-off matches the dark reference
exactly. Quarter primary budget, denoising and multibounce enabled. This isolated
spotlight test does not resolve every gun-mounted-light report.

## Dense-scene material storage option — 2026-10-23

`[shadow_validation]` `amd_gi_material_density` switches 8→4→8-pixel triangle
material tiles without changing ray density. The fixture's atlas falls from 80 to
20 MiB and returns to 80 MiB; 42 resident capture pages cover room geometry, a dense
sphere and 200 tinted instances. Density, atlas, MultiMesh and quarter/one budget
checks pass. Coarser material sampling loses texture/cutout/normal detail.

`[game]` Crossroads main-street captures at 1280×720 FSR2 Performance use the 4-pixel
option and a 256 MiB atlas cap: 545,376 triangle tiles, 1,617 resident capture chunks,
268,369,920 allocated atlas bytes. Both quarter and one primary budgets receive
64 actual GI frames, with denoisers, multibounce and reflections enabled. These
captures predate the sandbox history fix. They do not establish a 780M preset or
frame rate; native capture geometry and targets add memory outside that atlas.

## Crossroads exposes imported alpha-material support — 2026-10-23

`[game]` The small TestLevel was not a sufficient project evaluation scene. At the
user's direction, project captures now use Crossroads. Its imported Synty materials
combine alpha blending with forced depth writes; the original strict adapter
rejected them and suppressed GI. The adapter now preserves their opaque portions
and samples fractional alpha as straight-through coverage. It does not replace
these assets, modify their authored materials, or make glass an opaque occluder.

`[shadow_validation]` An off-screen emitter/blocker rig checks the two coverage
endpoints against hidden/opaque references. Display-RGB MAE is 0.000298 for zero
versus hidden and 0.000215 for one versus opaque. Indirect gains at zero/half/one
coverage are 0.050835/0.039761/0.024700. Denoising stays on at the quarter primary
budget, with feedback/multibounce disabled to isolate this test. No refraction,
tinted transmission or target-hardware performance is established by it.

## AMD GI all-hit cache accumulation — 2026-10-23

`[code]` Registered primary and secondary hits now shade independently and reduce
into their world cells. Per-cell lists separate registration, shading and reduction;
only the stable owner publishes a light reservoir. History evidence counts the
contributing samples. Each primary hit may schedule a probability-compensated
continuation. The live `cache_all_hits` toggle retains the cheaper one-hit-per-cell
path and releases the additional lists/sample records. Primary diffuse ray counts
are unchanged; visibility, continuation and shading work can increase.

`[shadow_validation]` GPU list validation passes 132 frames with exact coverage,
unique/acyclic lists, correct cell identity, and finite completed shading. Toggling
the mode releases 7,186,416 buffer bytes at the test's 641×359 quarter budget.
The multibounce test reports single/multiple display-RGB gains 0.024708/0.036473;
restoring single bounce gives 0.024742. Identical and mixed light resampling gain
ratios are 0.999064/0.997624 relative to exhaustive lighting in the controlled rigs.
Matched 64-frame quarter/one images give gains 0.036440/0.036067. Reflections,
FSR2 and native deformation checks pass. These are software-Vulkan correctness
results, not evidence of target-hardware performance or universal quality gains.

`[code]` The shader now uses 32 storage buffers. The support gate checks both
per-stage/set limits and 32 KiB compute shared memory before collecting GI geometry
or allocating its shaders. The prior documentation incorrectly called these
universal Vulkan minima; they are implementation requirements and are now described
as such.

## AMD GI native screen-lighting feedback — 2026-10-23

`[code]` Continuation and glossy hits can now reuse the previous opaque native HDR
lighting when geometry and motion checks accept it. A fourth opaque attachment
captures before fog/tonemapping/upscaling; reuse removes previous exposure.
Off-screen/disoccluded receivers retain explicit cache shading. Authored per-light
indirect-energy multipliers other than 1 automatically disable combined feedback,
since it cannot preserve separate light weights. A live toggle releases its target.

`[code]` The native feedback shader group compiles per material on demand. It is
never globally enabled, so future/newly edited materials do not compile unused
feedback variants after GI is disabled. Native pipeline caches may remain warm;
there are no feedback draws, attachments, copies or dispatches while GI is off.

`[shadow_validation]` The feedback rig confirms actual GPU hit acceptance. Fog and
exposure changes alter the final display image while the unexposed feedback mean
differs by 0.000123/0.000127 relative to its control. The toggle releases 1,866,240
texture bytes on lavapipe (driver-aligned allocation for a logical 1,840,952-byte
RGBA16F image). Zero indirect energy and disabled images restore exactly. The
initial scorer incorrectly equated driver allocation with logical texel bytes;
it now requires release of at least the logical size and matching repeated
allocations/fallbacks. No rendering code was changed to satisfy that correction.

`[shadow_validation]` Multibounce, mixed-light resampling, moving reflections,
FSR2 and matched 64-draw quarter/one comparisons pass with feedback enabled. The
quarter/one room display-RGB gains are 0.036672/0.036890. Native material/UV2 capture
and the exact RT-shadow geometry baseline also pass with on-demand shader groups.
Affected release translation units compile. These remain software-Vulkan
correctness checks, not target-hardware timing or a completed port claim.

## AMD GI spatial light proposals — 2026-10-23

`[code]` Fresh RIS candidates now traverse a bounded, spatially ordered light
hierarchy instead of sampling uniformly. Stable light indices preserve reservoir
identity across rebuilds. Exact traversal probabilities normalize the estimator;
node bounds/power affect proposals only. Unchanged light records do not rebuild or
upload the tree. Its 48-byte nodes use at most 96 KiB for 1,024 lights and release
with the resampling toggle. Zero/one-light scenes bypass it.

`[shadow_validation]` The identical four-light case gives a resampled/exhaustive
indirect-gain ratio of 1.000350 and display-RGB MAE 0.000684. A six-light mixed
point/spot/directional case, including empty tree leaves, gives ratio 0.926735 and
MAE 0.002154. The resource-release check includes the new tree; zero-indirect and
disabled images restore exactly. These finite-history image comparisons are not
proof of universal variance improvement or GPU speed. Multibounce ownership and
release also pass, with single/multiple indirect display-RGB gains 0.024716/0.036673.
Both use the same quarter primary-ray budget and enabled denoiser.

`[CI]` The first Windows Clang build exposed an inconsistent-missing-override
error: the new culler capture declaration alone used `override` while the existing
class declarations omit it. The declaration now follows its neighboring bake API;
its virtual dispatch and signature are unchanged. The local editor and affected
release translation units compile; Windows validation must be checked on the new
commit, not inferred from these Linux results.

## AMD GI game integration and probe preparation — 2026-10-23

`[game/software Vulkan]` A temporary, ignored harness loads the actual
`fps-proto` test level at source `307c068276f96dbd9fd130e85cd3b6dcff32df02`, using
its locally built native extension and existing game settings. Grass and soft RT
shadows are off; hard RT shadows, VBAO and FSR2 Performance remain on. Captures use
641×359 display / 320×179 internal resolution, frozen gameplay, and matched 64-draw
GI histories. The three NPCs and first-person presentation run without GI suppression.
34,464 triangle tiles grow the atlas to 64 layers, beyond its previous fixed limit.
These are integration stills, not gameplay or 780M/5090 performance results. Tracked
game files remain unchanged. The original source-`8feba59` PDF/PNGs are in preview.

`[code]` Displaced-probe motion rejection previously read a shared index initialized
only in another shader pass. It now uses the cached probe's own origin. Preparation
also gathers the current reprojected 3×3 grid, matching AMD's ordering. A separate
PREPARE dispatch reads immutable probe/radiance data before TRACE publishes new
seeds; it uses existing scratch storage and adds no rays.

`[shadow_validation]` The strengthened cache rig combines camera return with a
moving box; cache ownership, motion invalidation, history lifetime and exact disabled
restoration pass. The current-grid change also passes native deformation, moving
glossy reflections, FSR2 and equal-history quarter/one-budget checks. Denoisers and
ordinary primary-ray budgets remain unchanged.

## AMD GI forward-only effects — 2026-10-23

`[code]` Checking the game's presentation revealed that forward-only outline,
stencil and blended effect surfaces could suppress GI. The shared adapter now uses
native alpha/depth/shadow classification to leave these surfaces in rasterization.
Opaque/cutout geometry remains in transport. This does not implement transparent
transport or allow arbitrary opaque vertex deformation.

`[shadow_validation]` `amd_gi_overlays` covers a vertex-expanded unlit shell, an
invisible mask, lit alpha blending and an additive effect. GI remains active;
untouched surfaces differ by 0.000701 display-RGB MAE, history does not reset when
effects appear, and disabling restores the baseline exactly. Quarter primary-ray
sampling, multibounce and denoising remain enabled. Affected release code compiles.

## AMD GI shared materials and instancing — 2026-10-23

`[code]` Compatible mesh instances now share native captures, using local normals
transformed at the triangle hit. Context-dependent materials keep separate native
evaluation. Atlas layers and scene buffers grow on demand; the live atlas budget
is separate from capture targets and geometry. CPU-managed 3D MultiMeshes preserve
element transforms, colors, custom data and shader instance IDs.

`[shadow_validation]` The sharing rig covers 300 repeated spheres, exceeding the old
instance and duplicated-triangle limits. Fewer than 12 capture chunks remain, with
zero redraws through 78 transform/settle frames. Motion restoration and independent
world-capture display-RGB MAE are 0.000881 and 0.000931. Disabled restoration is exact.

`[shadow_validation]` Atlas growth reaches 64 layers, then a live 8 MiB budget shrinks
it to six. Growth/shrink room MAE is 0.000748/0.000711, with exact disabled restoration.
The MultiMesh rig matches independently shaded MeshInstances exactly with GI off;
GI correspondence/motion-restoration MAE is 0.000338/0.000664. Color/custom updates
change the image. Its initial reference incorrectly used Color shader uniforms,
which Godot converted to linear while MultiMesh supplied raw values; explicit
Vector4 reference inputs corrected that direct-only mismatch before comparison.

`[shadow_validation]` Native material and legacy UV2 baking pass with the 64-byte
capture header. Shared RT-shadow geometry remains pixel-identical to its baseline.
Native four/eight-weight deformation GI MAE is 0.001297/0.002410, including FSR2.
Affected release translation units compile. These are software-Vulkan correctness
checks, not 780M/5090 speed measurements or completion of the AMD port.

`[shadow_validation]` The final regression pass also covers FSR2 at awkward internal
sizes, matched 64-draw quarter/one histories, and half/full glossy reflections.
Quarter/one display-RGB GI gain is 0.036495/0.036686 in the controlled matte room.
The off-screen reflection emitter moves 15.256 pixels and returns with 0.774 mask
overlap; vacated-region residuals remain 2.6%/0.5%. All filters stay enabled.
Original PNGs and a phone-readable intermediate PDF are refreshed in the preview
folder. This remains an intermediate comparison, not the all-work-complete result.

## AMD GI atlas and deformation checkpoint — 2026-10-22

`[shadow_validation]` Under Vulkan lavapipe, the packed-atlas rig fits 48 small
surfaces, relocates retained pixels when an earlier mesh grows, and spans layers
when that surface grows again. Shift/split display-RGB MAE against the unchanged
room is 0.000724/0.000721; disabling restores the baseline exactly. The changed
source redraws, while relocated unchanged captures only copy.

`[shadow_validation]` The deformation rig uses native four/eight-weight skeletons
combined with a blend shape. Independently CPU-baked static geometry supplies a
separate correspondence check. With local motion invalidation, four-weight direct/GI
MAE is 0.000008/0.001449; eight-weight with FSR2 is 0.001046/0.002290. Each animation
section initializes history once, then reports 11/12 local motion updates without
further global resets. Source captures do not re-prepare during pose animation.
These are correctness/image metrics, not timings or a guarantee against motion
artifacts. The native material/UV2 rig and one-primary-sample transport checks also
pass; the latter restores disabled textures and pixels exactly.

`[shadow_validation]` The final build of this checkpoint also passes the exact
shadow geometry baseline (including in-place vertex/index changes) and affected
release translation units. The matched-budget rig verifies 64 actual uninterrupted
GI draws in each fresh history: quarter/one display-RGB gains are 0.036655/0.036626.
These are mean image differences, not quality scores. Original PNGs and a PDF are
in `/workspace/preview/current-amd-gi-checkpoint` and
`/workspace/preview/00-current-amd-gi-checkpoint.pdf`; the backend remains unfinished.

`[shadow_validation]` The moving-reflection rig verifies the off-screen emitter
shifts 15.294 pixels in the mirror, returns within 0.2 pixels of its initial center,
and leaves 2.6%/0.5% bright residual pixels in the tested vacated regions. The return
mask overlap is 0.775. There are no global history resets during this motion;
310 GPU sample checks exercise both glossy traces and rough-probe reuse. A first
whole-mirror MAE gate also measured unrelated stochastic lighting (0.022916 after
return), so it was replaced with emitter correspondence and vacated-region checks.
The original captures were rescored; no renderer change or image processing was
used to obtain that result. This does not establish noise-free reflections.

`[code]` Current GI pose capture reads the same native GPU deformation output used
by RT geometry. No duplicate skinning pass or per-frame pose readback is added.
Swept old/new bounds invalidate affected cache tiles and reused connections;
object motion-vector reprojection remains separate unfinished work.


# AMD GI preparation

## Continuous lighting history and FSR2, 2026-10-22

`[code]` Continuous sky redraws and tiny sun/light changes initially reset all GI
history. Dynamic skies now retain history, and light identities/masks and large
parameter discontinuities are handled separately from smooth parameter updates.
Geometry transform changes remain conservative resets.

`[shadow_validation]` The dynamic-lighting rig retains history over 132 frames
with exactly one initialization reset, while animating sky TIME/rotation, a sun
and a local light. Abrupt light/sky removal resets once and produces black.
The static sky regression still passes. FSR2 Performance at 641×359 display /
320×179 internal resolution passes with both GI lobes, multibounce and denoising:
quarter/one primary-ray display-RGB gains 0.034171/0.034717, restored difference
0.002290, disabled difference 0.001247. This is Vulkan integration on lavapipe,
not DLSS verification or a 780M timing result.


## Static material pixel reuse, 2026-10-22

`[code]` Native material pages now retain pixels as well as prepared geometry.
Local material/shader changes, tracked image uploads/replacement, source-data edits,
and transforms invalidate them. TIME, global/instance uniforms, viewport/drawable
textures and external GPU textures keep per-frame evaluation. Proxies follow the
actual image owner; comparing a texture RID alone would miss updates in place.

`[shadow_validation]` The dirty-material rig drew seven pages on initialization,
then zero on unchanged frames. Updating the wall image in place drew one page;
changing emission drew one page. TIME refreshed exactly one page on all 26 frames,
and global-uniform shading one on all 132 frames. Restoring the static material
drew one page, then stopped. Receiver green-channel emission gain was 0.011635;
texture/global changes reached indirect receivers and disabled restoration was
exact. These are draw-count/visual checks on lavapipe, not GPU timing results.


## Native sky and initial glossy reflections, 2026-10-22

`[code]` Sky misses reuse Godot's native unfiltered octahedral radiance, orientation,
border and IBL normalization. Sky rebuilds invalidate cached lighting. The glossy
path adds GGX visible-normal rays, rough directional-probe reuse, BRDF/PDF ratio
reconstruction, virtual/surface temporal reprojection and variance-guided a-trous
filtering. It has independent half/full sampling, roughness threshold, filter-count
and enable controls. Native material DFG/Fresnel remains in Forward+.

`[shadow_validation]` The sky rig at 1/4 primary rays, with denoising and multibounce
on, reports display-RGB gain 0.285756, occlusion versus native ambient 0.165225,
and orientation-change difference 0.076784. Black sky removes the contribution;
green sky shifts receiver color and disabled restoration is exact. The initial
reflection rig shows an emissive object behind the camera in the mirror. Half/full
mean absolute display-RGB difference is 0.003132, restored half-resolution difference
0.002607, and reflection-off difference 0.000505. The reflection buffers release
on disable. These are integration checks on lavapipe, not target-GPU performance
or proof of final image quality. A subsequent full-resolution resolve adjustment
removes unnecessary upsample blur and is being checked separately.

Layered/anisotropic lobes, nested specular, adaptive glossy compaction and the
complete Capsaicin firefly cleanup remain; half-resolution mirrors show artifacts.


## Secondary world-cell population and separate indirect history, 2026-10-22

`[code]` Multibounce now explicitly traces, allocates, registers, and shades
secondary world receivers. Current secondary direct light and previous secondary
indirect light update separate primary indirect histories, with probability
compensation and independent sample-count-selected mips. Uncached/short connections
retain local evaluation. Disabling multibounce skips seven stages and releases
both indirect buffers and the secondary-hit buffer. The shared pipeline has 30
specialized stages. Primary-ray budgets remain unchanged.

This still schedules one hit per cache cell rather than accumulating every visible
hit, and feeds back world indirect lighting rather than Capsaicin's combined screen
lighting. Secondary-only receivers clear stale indirect history when they have no
scheduled continuation; higher-order feedback depends on primary coverage over time.

`[shadow_validation]` At 1/4 primary ray/pixel and continuation probability 0.3,
the bounce rig's mean indirect display-RGB gains are 0.024697 (single), 0.036580
(multibounce), and 0.024737 (single restored). Actual GPU ownership checks pass
on 66 multibounce frames, including populated secondary-only cells. The exact
resource delta is released on disabling multibounce, and the disabled image
restores exactly. The repeated light-reservoir test also passes: resampled versus
exhaustive indirect-gain ratios are 0.999056 for identical lights and 0.954071 for
varied lights, with mean absolute display-RGB differences 0.000624 and 0.001817.
These are software Vulkan integration checks, not target-hardware timings.

## World-cell light reservoirs, 2026-10-22

`[code]` The diffuse cache shades hits with eight unshadowed light candidates,
RIS selection, and up to four distinct normal-compatible previous world-cell
reservoirs. Previous confidence is capped at 20 and the selected light's visibility
is traced at the current hit. The live `light_resampling` toggle releases its
double-buffered 8 MiB storage and switches to exhaustive light evaluation; scenes
with zero or one light bypass resampling automatically. Primary probe-ray budgets
are unchanged: candidate evaluation is shader arithmetic, not eight traced rays.

This adapts Capsaicin's reservoir construction/merge to the existing directional
world grid and bounded Godot light list. Its separate hash of hit reservoirs,
light-sampling hierarchy, full multibounce cache population, and reflections are
not implemented by this stage.

`[shadow_validation]` At approximately 1/4 primary ray per pixel, with multibounce
and denoising on, `amd_gi_lights` compares resampling with exhaustive lighting.
The mean indirect display-RGB gain ratio is 1.004198 for four identical lights
and 1.011975 for varied positions/colors/energy. Mean absolute image differences
are 0.000637 and 0.001643 respectively. Actual GPU buffer checks establish valid
light indices, finite weights, bounded confidence, and temporal reuse. The
reservoir allocation toggle and exact direct-only controls pass. These integrated
display-space metrics are not per-pixel accuracy guarantees or hardware timings.

## Dense probe reuse and temporal-history invalidation, 2026-10-22

`[code]` Stored probes now use an 8-pixel grid independently of the sparse
tracing budget. Adaptive scheduling redirects existing updates into uncovered
tiles; neighborhood reprojection, hierarchical mask lookup, four-probe
interpolation, and a bounded displaced-probe LRU cache retain useful history.
Interpolation uses Capsaicin's blue-noise spatial lookup with its temporal
rotation. Emission bypasses the world radiance cache, and short connections
bypass filtered cache readback to reduce thin-wall leaks. Primary-ray budgets
remain approximately 1/4 or 1 per internal pixel per frame.

`[shadow_validation]` Adding actual-GPU ownership validation exposed a preexisting
history bug: the controlled static scene advanced its GI revision every frame.
Diagnostic input records showed identical geometry, materials, transforms, and
lights in changing BVH traversal order. The order-dependent signature interpreted
those permutations as scene changes. Consequently, previous images and response
checks did **not** establish working temporal accumulation, cache feedback, or
reprojection, despite the corresponding controls being enabled. Earlier claims
about those mechanisms must be read with this correction.

`[code]` GI collection now sorts by stable instance and light IDs before capture,
TLAS assembly, and signature calculation. The focused `amd_gi_cache` regression
requires exactly one initialization reset during small camera movement and
stationary rendering, alongside GPU scheduling/LRU checks and visible cache reuse.
The final requested 1/4-versus-1 comparison remains pending the remaining backend
work; historical preview files are not the completed implementation.

`[shadow_validation]` The stable-order implementation passes `amd_gi_cache` with
one initialization reset and GPU queue/ownership/LRU checks over 128 frames.
Displacement and reuse are exercised, and the disabled image restores exactly.
The sampling rig passes the same GPU invariants on 694 active-cache frames,
including sampling/adaptive/cache switches and an emissive material uniform
change. Its box-front emission gain is 0.390962 in mean display RGB; residual
after removal is 0.042719. Unlike the earlier zero-residual record, this run has
working temporal feedback. The residual is below the rig's 20% response threshold,
but demonstrates that temporal lighting decay still needs visual evaluation.

## Retained material preparation and source revisions, 2026-10-22

`[code]` `RaytracingMaterialCapture` separates preparation of expanded geometry
and targets from rendering current native material pixels. The GI adapter retains
bounded preparation pages and invalidates only changed source pages. This removes
per-frame geometry readback, decoding, mesh expansion, and target allocation from
unchanged pages. Material pixels still redraw every active frame; this is not
dirty-material scheduling or a completed material cache.

`[code]` Mesh surface revisions detect in-place edits. Vertex/index updates
invalidate the shared BLAS and prepared material data; attribute/skin updates
invalidate prepared material data without an unnecessary BLAS rebuild. Stable
buffer RIDs alone were insufficient for this contract.

`[shadow_validation]` `amd_gi_materials` verifies 198 frames with exactly seven
initial page preparations and two single-page rebuilds. A non-caster wall's
vertex-color buffer changes from green to blue; the separate box-front RGB delta
is `[0.00270924, -0.05354846, 0.0430902]`. The edited-buffer result differs from a
freshly rebuilt source by 0.002729 mean absolute display RGB, below the rig's
0.015 stochastic tolerance. The disabled image restores exactly. The native
material capture analytical rig also passes. These are software Vulkan correctness
checks, not target-GPU performance measurements.

## Guided diffuse probe sampling, 2026-10-22

`[code]` The Vulkan diffuse path now ports GI-1's radiance-times-cosine sampling
distribution, hit-position reprojection, angular sample rebinning, empty-cell
backup, and shadow-preserving probe hysteresis. The live `importance_sampling`
control defaults on and keeps the primary ray budget unchanged. It adds no
persistent allocation or dispatch, but does add shader work. The Godot port uses
bounded workgroup-local integer lists with floating-point sums in place of
upstream fixed-point atomics. Reuse currently selects the nearest compatible
previous probe; neighborhood/LRU reuse and adaptive placement remain unfinished.

`[shadow_validation]` At 641x359 and approximately 1/4 primary ray/pixel/frame,
the `amd_gi_sampling` rig passes off/on/off sampling switches with unchanged GPU
allocation, black-history discovery, emissive removal, and exact disabled
restoration. Multibounce and denoising stay on. After 64 settling frames, an
emissive ceiling raises the box-front region's mean display RGB by 0.408730; after
removing emission and another 64 frames, that region matches its baseline exactly.
This measures response in one controlled scene, not radiometric accuracy.

`[shadow_validation]` The standard sparse progress rig also passes at approximately
1/4 and 1 primary ray/pixel/frame, including material transfer, camera movement,
resize, and disabled restoration. Appearance in this room remains broadly similar;
the coarse indirect gradients are not solved by this sampling stage. The full
Linux editor and AMD release translation unit compile. No target-GPU performance
or upscaler compatibility claim follows from software Vulkan captures.

## Sparse cached diffuse pipeline, 2026-10-22

`[code]` The first AMD GI diffuse slice now implements sparse directional probes,
a bounded world hash with directional tiles and mip levels, previous-frame cache
feedback for multibounce, SH reconstruction, and adaptive temporal/spatial GI
denoising. It is an incomplete GI-1.x adaptation, not the completed backend.
[The feature document](#snapshot-amd-gi) records each implemented stage and
remaining source-port gaps, including reflections and persistent material caching.

`[shadow_validation]` Progress captures now use approximately 1/4 and 1 primary
probe ray per internal pixel per frame, with multibounce probability 0.3, probe
filtering, and the GI denoiser enabled. Secondary/visibility rays are additional.
The 641x359 rig passes indirect-energy-zero, non-caster material-transfer, exact
disabled-restoration, and texture-release checks. It also renders camera cuts,
small camera movement, and an awkward 637x353 resize without engine errors; this
is not exhaustive motion/upscaler validation. Texture bytes return from 55,714,560
while active to the 10,017,536 baseline. Native bake buffer pools retain 761,760
bytes above the cold buffer baseline after disabling.

`[shadow_validation]` All 11 existing RT-shadow geometry images remain pixel-identical,
and native material checks pass. The separate uncached diagnostic controls also
pass at one sample per pixel. The full Linux editor and affected release objects
compile. No 780M/5090 GPU performance or DLSS/FSR compatibility is established.

**Presentation correction:** The earlier 128/512-sample transport images were
inappropriately presented as implementation progress. They are expensive debugging
references, not representative runtime results. Progress uses an explicit low
tracing budget and keeps implemented reconstruction/denoising enabled. The current
`gi_compare` rig now follows that rule too.

## Native GI still comparison, 2026-10-22

`[shadow_validation]` The original `gi_compare` run (since replaced by the sparse pipeline comparison) rendered the same 641x359 matte room with
the uncached diffuse validation mode (512 paths/pixel, three secondary encounters),
baked native VoxelGI at 128 and 256 subdivisions, and native SDFGI. Camera, direct
light, RT shadows, materials, and exposure are unchanged. See the
[complete protocol](#snapshot-rtgi-validation).

The RT validation image has localized colored fill on the shadowed white box faces,
with residual sampling grain. VoxelGI provides stronger overall fill but visible
bands on the box faces and ceiling. Increasing subdivisions and testing bias 0 /
normal bias 1.5 do not remove these artifacts in this view. SDFGI leaves the
shadowed faces substantially darker, both with default spatial settings and with
minimum cell size 0.1 / occlusion enabled. The camera is outside the room, so the
minimum cell size is not the cell size throughout the room; this is not evidence
that SDFGI behaves identically from an interior first-person camera.

All three disabled controls match the initial image exactly. After 120 settling
frames, another 60 frames leave every native capture unchanged except default
SDFGI, whose largest change is one 8-bit channel step. The observed differences
are not an unsettled-startup comparison.

These are different transport approximations with their native energy/feedback
settings, not radiometric accuracy rankings. Native GI supplies capabilities such
as approximate specular reflections that the current diffuse validator lacks.
The captures do not establish eventual AMD cache/reconstruction quality, motion
behavior, thin-geometry handling, upscaler compatibility, or target-GPU cost.

## Diffuse transport stills, 2026-10-22

An explicit `rt_validation` mode now connects a separate GI scene TLAS, shared shadow
BLASes, native material captures, and uncached diffuse path integration. This is a
transport checkpoint, not AMD's radiance-cache/screen-probe implementation. See
[features/rtgi-validation.md](#snapshot-rtgi-validation) for reproduction and limits.

| Result | Evidence | Tag |
| --- | --- | --- |
| Actual indirect illumination and extra-bounce energy | The 641x359 room rig passes at 128 and 512 paths/pixel under Mesa lavapipe 25.0.7 / LLVM 19.1.7. One and three secondary encounters brighten occluded white box faces; three recover more energy. | `[shadow_validation]` |
| Reflector selection is independent of shadow casting | The right wall does not cast shadows. Changing its material from green to blue reduces green and increases blue on the unchanged white box front. | `[shadow_validation]` |
| The effect is not an ambient/exposure offset | Zero indirect light energy restores the disabled image byte-for-byte. Disabling validation and restoring scene inputs also restores it exactly. | `[shadow_validation]` |
| Validation textures are released after deferred destruction | An 8-path lifecycle run waits 12 frames after disabling. Engine-reported texture bytes are 10,017,536 before, 53,848,320 while active, and 10,017,536 afterward. Buffer bytes remain 761,760 above the cold baseline; native material-bake buffer pools remain warm. This is not complete memory equivalence or hardware profiling. | `[shadow_validation]` |
| Existing rendering remains unchanged in the exercised cases | All 11 geometry regression images remain identical to the original shadow-scene baseline, and native material/legacy UV2 checks pass. | `[shadow_validation]` |

The Linux editor and affected release translation units build. No target-machine
performance, glossy reflection quality, AMD cache behavior, denoising, or DLSS/FSR
compatibility is established by this validation mode.

## Native material capture, 2026-10-22

Added explicit paged triangle capture through the native Forward+ material shaders.
The capture preserves source UV2 and vertex IDs using a separate placement buffer;
it is not invoked by frame rendering and does not enable GI. The public
`RenderingServer.bake_render_triangle_material()` method is a diagnostic readback
entry point. Representation and limits: [internals/rt-materials.md](#snapshot-rt-materials).

| Result | Evidence | Tag |
| --- | --- | --- |
| Analytical material checks pass | Vulkan/Mesa lavapipe 25.0.7, LLVM 19.1.7: indexed/non-indexed and compressed source data, original UVs/colors/custom attributes/vertex IDs, tangent-space normals, transforms, cutouts, HDR emission, parameter/texture updates, surface-material selection, page clipping, and legacy UV2 baking. | `[shadow_validation]` |
| Normal frame images remain unchanged | All 11 geometry captures at 641x359 again match the original shadow-scene baseline with zero changed RGB pixels after the material-pass changes. | `[shadow_validation]` |
| Surface data readback does not include the material RID | The first test run caught fallback to default gray. Capture now queries `mesh_surface_get_material()` separately. | `[code]` |
| Native bake normals require normalization after decoding | Best-fit encoding changes the stored vector length. The normal-map test decodes with `normalize(rgb * 2 - 1)`; comparing raw RGB with a unit vector's encoding was incorrect. | `[code]` |

The full Linux editor build, affected release translation units, class-reference
generation, and changed-file hooks pass. These results do not establish hardware
performance, complete scene material support, or a functioning AMD GI backend.

## Geometry extraction, 2026-10-22

`RaytracingGeometry` now owns the BLAS cache and dequantization code previously inside
`RaytracingScene`. The shadow scene retains selection, layer masks, and TLAS ownership.
This is infrastructure only: AMD GI lighting, reflections, multibounce, denoising, and
settings are not implemented. Current scope: [AMD_GI_IMPLEMENTATION.md](#snapshot-amd-gi-implementation).

| Result | Evidence | Tag |
| --- | --- | --- |
| No image change in the geometry regression | All 11 corresponding captures at 641x359 had zero changed RGB pixels against the original shadow-scene implementation at `e4e8d844470786e631b4d61ec622a5e0a2732aa1`, using Mesa lavapipe 25.0.7 / LLVM 19.1.7. The rig covers shared meshes, compression, 16/32-bit and non-indexed geometry, buffer replacement, blend shapes, eviction, and destruction. | `[shadow_validation]` |
| Reuse requires more than sharing the shadow TLAS | GI needs its own visibility and ordered hit metadata. A BLAS can rebuild in place with the same RID, so the extracted surface descriptor also exposes a successful-build revision. No second geometry consumer is wired yet. | `[code]` |

No hardware cost or GI quality result follows from this extraction. Older entries below
refer to the geometry methods by their original `rt_scene` locations; those methods
now live in `rt_geometry`.

---


### 2026-10-23 — approved source-normal correction (local, unshipped)

The owner approved the authored-light/material integration boundary and conditionally approved correcting the pinned AMD transform errors. Source tracing and an extracted-expression counterexample establish those errors independently of the screen/world split. AMD GI now reads native source/pose vertex normals and separate triangle geometry normals, with one world transform and distinct sampling/cache-shading roles. The 36-case GPU decoder check passes (maximum vector error 0.00005052). Existing deformation image thresholds pass for four/eight-weight skeletons, blend shapes and FSR2 pose-buffer swapping; GI MAE versus baked geometry is 0.001191/0.002384. Quarter-budget integration diagnostics pass. A separate per-frame cache-tile claim fixes the duplicate-active-cell race exposed by the deformation test. This is software-Vulkan correctness evidence; no new Windows artifact, hardware timing or full AMD equivalence is claimed. Material fidelity and other consequential findings remain unfinished.

## Consequential AMD source/material follow-up

The native material GPU oracle exposed and corrected compressed UV decoding when
Godot's UV scale is zero (normalized coordinates need no rescaling). The corrected
fixture passes 256 samples with maximum component error 0.00000279, including
source textures/LOD, uniforms, vertex attributes and actual alpha/discard rays.
The default ray range now matches AMD's 1e9, with owner-approved distance-only
storage/accumulation handling. The owner approved native emissive classification,
flat grid directions, multibounce index/weight corrections and rejecting references
to deleted lights. The immutable firefly snapshot proposal was withdrawn; cleanup
returns to AMD's in-place method. No hardware performance gain is claimed.
Detailed run evidence and outstanding qualification live in
[AMD_GI_CONSEQUENTIAL_CORRECTIONS.md](#snapshot-amd-gi-consequential-corrections).


<a id="snapshot-gi-troubleshooting"></a>

## Snapshot: docs/TROUBLESHOOTING.md

## Experimental AMD GI history

If GI repeatedly restarts while standing still or walking, enable the opt-in
`GODOT_AMD_GI_TRACE_HISTORY=1` environment variable to distinguish camera,
environment, configuration and scene resets from local dirty regions. The sandbox
regression fixed global resets caused by flickering electrical-field mesh visibility
and camera-centered geometry collection changes. Current dirty bounds are diagnostic.
The consequential correction removes stable-ID remapping and follows AMD's
light-settings transitions, including zero/nonzero emitter or analytic-light counts.
Native previous-surface reprojection, capture residency and capacity preflight remain;
capacity/unsupported-material preparation can still suppress GI. See the
[live correction record](#snapshot-amd-gi-consequential-corrections). See the historical [gameplay audit](#snapshot-amd-gi-gameplay-audit)
for the `3038a14` failures and the implementation status for current evidence.
These changes are not a substitute for checking moving images and actual hardware.
Default Crossroads/Fieldway scene preparation now adapts material resolution to fit
its budget; the compact fallback reduces within-triangle material detail. See
[AMD GI history diagnostics](#snapshot-amd-gi).

Current AMD GI no longer uses the capture atlas. Raising `material_atlas_mb`,
`material_preparation_budget` or `material_tile_size` cannot fix AMD GI source
shading; those settings now affect only the legacy uncached transport validator.
Unsupported source shader/scene classes produce a warning and are omitted
individually, so check warnings if particular objects are absent from transport.
An EMISSION-writing shader is classified as emissive even when its current RGB
is black; this owner-approved input encoding follows AMD's base-emissivity
termination distinction. See the live correction record before treating any
historical atlas workaround or settled still as current validation.


### AMD GI warns about an unqualified emitter texture mapping

The supported affine path handles ordinary/alternate UV layouts and straight
scaling, rotation or translation, with supported aliases and vertex varyings.
Nonlinear warping, texture-dependent coordinates, some control-flow/helper cases,
partial mutations and non-2D implicit reads are not certified. The warning names
the material shader; its existing filtering fallback remains active, so lighting
from it can still be noisy or incorrectly averaged. This does not indicate a GI
history reset. See [the precise adapter scope](#snapshot-amd-gi-adapter-decisions).
