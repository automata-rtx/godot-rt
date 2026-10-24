# AMD GI adapter decisions and approval scope

The owner explicitly requires approval for departures from AMD. On October 23, 2026, the owner approved the authored-light/material boundary and conditionally approved correcting the normal transforms if the pinned AMD implementation is incorrect. The completed normal-space investigation establishes that condition. The individual sections below record the approved exceptions, the bounded affine mapping extension and the withdrawn snapshot proposal. Qualified corrections are implemented; neither these approvals nor passing helper tests establish full native-input support, optional AMD feature parity or production readiness.

## Approved: preserve authored Godot lighting at the input/output boundary

Approved boundary: retain Godot's light energy, range/decay, spot attenuation, masks and shadow opacity when evaluating a light, and retain Forward+'s authored material BRDF/DFG/AO at final composition. Use those same light values in both the GridStream proposal and selected-light target. All GI transport, probe/cache/reservoir and denoiser algorithms remain AMD's. Source textures and actual hit attributes must replace the coarse material atlas; that compromise is **not** included in this proposal.

Why: otherwise direct lighting and its bounce would describe different lights. AMD's glTF spot model has inner/outer cone angles; Godot's authored spot uses a different attenuation control. There is no exact parameter conversion for all authored values. The same issue applies to non-default native light decay, masks and material extensions. Replacing the native primary lighting as well would change existing game lighting outside the GI implementation.

Concrete difference: for unit intensity, range 8, distance 4, and native decay 2, the Godot radial factor is `(1-(4/8)^4)^2 / 4^2 = 0.05493164`; Capsaicin's point-light factor is `(1-(4/8)^4)/(0.0001+4^2) = 0.05859338`. This is an intentional authored-light contract difference, not a claim of pixel equivalence. The benefit is agreement between direct and indirect authored lighting, not a claimed speedup.

Approval covers only this boundary. It does not approve finite default tracing range, coarse materials, omitted geometry, changed history policy, extra radiance clamps or an alternative GI estimator.

Source-domain proof scripts are preserved in [validation/amd_gi_source_proofs](validation/amd_gi_source_proofs/README.md). Their outputs in the correction evidence directory are CPU proofs, not upstream GPU runs.

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

The owner's requested follow-up is recorded in [the normal-space investigation](AMD_GI_NORMAL_SPACE_INVESTIGATION.md). Tracing static/animated uploads, both fetch helpers, GI program bindings, raster/ray-traced screen buffers and world-space light/BRDF consumers rules out the screen-space/world-space split as an explanation. The pinned source contains localized missing/repeated instance normal transforms.

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
