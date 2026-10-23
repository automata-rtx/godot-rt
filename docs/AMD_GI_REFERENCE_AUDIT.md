# AMD GI reference audit and correction

Status: **in progress; reference fidelity is not established**. The previous
"scoped pipeline implemented" statement did not establish completion of the
requested AMD implementation. No algorithmic departure is approved by the owner.

Baseline: AMD Capsaicin v1.3, commit
[`914b91596cd119eda85fbc1d3c7ee6ac391b1452`](https://github.com/GPUOpen-LibrariesAndSDKs/Capsaicin/tree/914b91596cd119eda85fbc1d3c7ee6ac391b1452/src/core/src/render_techniques/gi1), under
`src/core/src/render_techniques/gi1/`. Fork audit baseline: `d4b39f5`.
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
| Light reservoir storage | `world_space_restir.hlsl`, `gi1.comp:GenerateReservoirs`, `CompactReservoirs`, `ResampleReservoirs` | One reservoir per directional radiance cell replaces a separate spatial hash containing multiple hit reservoirs | Independent reference hash, per-hit records, collision search, spatial jitter and prefix compaction translated; GPU ownership, prefix sums, multiple-hit entries, reuse and exact resource-release checks pass. Proposal distribution and fresh-RIS semantics remain open |
| Light proposals | `components/light_sampler_grid_cdf/`, `components/light_sampler_grid_stream/`, `components/light_sampler_uniform/` | Custom balanced tree for analytic lights; different selection infrastructure | Open correction; identify the reference's selectable sampler and preserve its estimator |
| Emissive lights | `components/light_builder/`, the reference light samplers | Separate emitter hierarchy and diffuse hit-emission partition replace integrated area-light sampling | Open correction; passing a flicker fixture is not equivalence |
| Reflections | `glossy_reflections.hlsl`, `gi1.comp:TraceReflections` through `NoDenoiserReflections` | Single roughness threshold and integrated single-probe estimate replace low/high thresholds and four-probe stochastic lookup; custom reconstruction, temporal and firefly rules | Reference default a-trous first/iter/last reconstruction and dual-source temporal blend translated; low/high roughness behavior restored. Rendered mirror/moving-emitter, dispatch equivalence and resource-release regression passes at quarter diffuse budget; split-estimator alternative and complete reference-image comparison remain open |
| Material evaluation | `gi1.comp:GenerateReservoirs`, `TraceReflectionsHandleHit`, native `MakeMaterialEvaluated` | Godot shader captures are sampled from tiny per-triangle tiles, including a one-sample-per-triangle fallback | Open design departure; no approval to retain the detail compromise |
| Probe guiding and reuse | `screen_probes.hlsl`, `gi1.comp:ReprojectScreenProbes`, `SampleScreenProbes`, `BlendScreenProbes` | Similar stages do not establish identical candidate search, BRDF weighting, confidence or cache policy | Detailed comparison outstanding |
| Radiance-cache temporal update | `gi1.comp:UpdateTiles`, `BlendScreenProbes` | Fork weights new hit batches differently, skips zero-update aging inside touched tiles, caps history after light changes and bypasses probe hysteresis | Reference update equations and touched-tile zero-update aging restored; light-change history override removed. GPU equation oracle passes 4,096 cases including zero-update aging; rendered light-reuse test passes. Integrated diffuse, reflection and FSR2 regressions pass |
| Radiance cache and multibounce | `hash_grid_cache.hlsl`, `gi1.comp:PopulateMultibounceCells` through `ResolveCells` | Different storage/accumulation and custom continuation/update controls | Detailed comparison outstanding; distinguish representation from estimator changes |
| Accumulation and quality defaults | Fixed-point radiance sums; reference cache sizes, sampler defaults and RNG | Fork uses floating-point list reduction, smaller caches, different RNG state timing and different default flags | Open comparison/correction; previous performance or precision rationales are not owner approval |
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
implementation. Remote publication remains blocked pending explicit authorization.

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

## Additional confirmed differences and correction status

- **Radiance-cache capacity and hashing:** reference defaults are 16,384 buckets ×
  16 tiles; the fork has 1,024 × 4. The reference hashes unpacked position,
  direction, level and short-ray flag with separate PCG/xxHash functions; the fork
  hashes a packed full key with one PCG chain. Keeping full keys can avoid checksum
  aliases, but no measured benefit/cost case has been presented or approved.
- **Radiance representation:** reference `UpdateTiles` writes packed half radiance
  sums and counts, with fixed-point update atomics. The fork retains float means
  and counts and reduces linked hit lists. Restoring the temporal equation does
  not establish equivalence of quantization, overflow, update ordering or capacity.
- **Secondary material BRDF:** AMD forces metallicity zero and roughness one, then
  evaluates its material BRDF, including its rough dielectric specular term. The
  fork currently evaluates Lambert diffuse alone. Matching the metallic override
  does not establish a matching secondary BRDF. Hit-normal capture also needs the
  same base/detail-normal distinction as screen inputs.
- **Defaults and controls:** reference `gi1_use_resampling` and
  `gi1_use_temporal_feedback` default false. The fork enables both, and incorrectly
  couples fresh RIS to the reuse flag. In AMD, disabling temporal reservoir reuse
  retains fresh light sampling. Correct this with the proposal-sampler replacement.
- **Emission and screen feedback:** AMD bypasses the cache at emissive primary
  diffuse hits and does not add the fork’s separate probe-origin emitter estimator.
  The current estimator split, two-sided emission and feedback eligibility remain
  open comparisons; they must be corrected together to avoid double counting.
- **Reflection hit lookup:** the restored default denoiser does not finish the
  reflection transport audit. Reference hit-position jitter, cache-lifetime touch and cache-miss distance
  semantics are now restored and pass the rendered reflection regression. Separate diffuse/glossy
  depth and normal thresholds are restored. Native previous-surface positions
  reconstruct the current-to-previous UV displacement including jitter; its
  integration passes the reflection and FSR2 fixtures; gameplay acceptance remains open. Hit-material and cache-representation
  differences remain open.

These are confirmed source differences, not speculative causes assigned to the
reported gameplay artifacts. Probe candidate search/guiding, material evaluation
and full multibounce scheduling still require detailed comparison.
