# AMD GI reference audit and correction

Current correction status: [consequential corrections](AMD_GI_CONSEQUENTIAL_CORRECTIONS.md). This earlier ledger is historical; its pass/restored statements do not supersede open findings.

Current status: **the full source comparison is complete; reference fidelity is not established and corrections remain unfinished**.
See [the complete comparison](AMD_GI_FULL_COMPARISON.md) and its
[function/pass/option coverage appendix](AMD_GI_COMPARISON_COVERAGE.md).
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

The later [normal-space investigation](AMD_GI_NORMAL_SPACE_INVESTIGATION.md) identifies localized upstream transform errors and records the owner's conditional approval. The port now preserves source interpolated and geometric normals separately; GPU decoder and deformation regressions qualify that change. This supersedes the historical capture-normal description for AMD GI, without claiming that atlas material evaluation is resolved.
