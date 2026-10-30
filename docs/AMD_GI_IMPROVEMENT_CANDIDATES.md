# Frozen AMD GI baseline and improvement candidates

Recorded 2026-10-30. The owner subsequently authorized implementation of the three
main candidates. Experimental implementations live on `feature/amdgi-improvements`,
behind independent switches defaulting off. The frozen refs below are unchanged.
See [controls](../GodotForkDocs/features/amd-gi-improvements.md) and
[validation](validation/amd_gi_improvements/README.md); implementation is not
shipping-quality acceptance or target-hardware performance evidence.

## Frozen baseline

- Commit: `1c069bd46ab7aaf8fef76591d5c788d913babad2`.
- Annotated tag: `amdgi-frozen-2026-10-30`.
- Preservation branch: `baseline/amdgi-frozen-2026-10-30`.
- Source branch at capture: `feature/amdgi-debug-views`; clean working tree,
  matching its remote at capture.
- Scope: the entire engine source, including AMD GI, shared RT infrastructure,
  live tuning, and debug modes 32–37. This is not a game-project or binary backup.
- Preserve the tag and branch: do not advance, rewrite, or delete them during
  experiments. Use a separate branch/worktree for changes.

Create a separate baseline checkout without disturbing current work:

```sh
git fetch origin tag amdgi-frozen-2026-10-30
git worktree add --detach ../godot-rt-amdgi-baseline amdgi-frozen-2026-10-30
```

“Frozen, safe” means a preserved rollback/comparison point, not a new certification
that GI is bug-free. Existing limitations in [status](STATUS.md) still apply.
The latest debug additions passed C++ object compilation, selected shader
compilation with a stub material, source checks, and repository hooks; they were
not newly GPU-visually validated here. This snapshot creates no new editor build.
Project settings and scene state must also match when comparing renders.

## Recommended first package

Keep AMD's existing architecture and quarter-sample primary-ray budget. Preserve
the original algorithm as an exact selectable comparison. Confidence below is
engineering judgment about a specific benefit, not measured performance or a
promise to resolve every reported artifact.

### 1. Coordinated response to confirmed lighting changes

**Practical effect:** flashlight bounce appears and disappears sooner, while
unchanging dark areas keep longer history for stability.

Current source has three sequential temporal stages: cache accumulation in
`gi_cache_accumulate`, screen-probe hysteresis in `resolve_probe`, and final
`gi_denoiser_accumulate`. A positive fresh probe value against black history can
receive only 9.75% weight (the existing hysteresis retains 0.95 squared of history).
The final change detector itself uses a 1/8 blend. Existing tuning does not directly
control the screen-probe hysteresis.

Proposed changes:
- Track persistent, consistent brightening and darkening with compact metadata.
- Increase fresh-cache influence only when change is credible; retain protection
  against isolated bright samples.
- Carry change confidence through probe reconstruction so downstream stages do
  not independently suppress the same confirmed transition.
- Reduce final history weight before adding fresh lighting; restore normal history
  gradually after stabilization. Do not globally reset history.
- Keep current-lighting confidence distinct from geometric validity. Do not retain
  a large count and falsely declare changed illumination well sampled.

**Cost:** metadata, bandwidth, and arithmetic within existing passes; no inherent
extra rays or duplicate RGB lighting cache. **Confidence:** high for reducing lag,
medium-high for retaining acceptable stability. False change detection is the main
failure mode. Thresholds, packing, and propagation are not finalized. Updates are
not necessarily frames; sparse refresh and multibounce feedback still affect delay.

### 2. Local demand-aware probe selection

**Practical effect:** use the same ray allowance to refresh areas that need it sooner.

At default spacing, select among the four stored 8x8 probes within each 16x16
update region using missing history, confirmed change, and update age. Retain
within-probe jitter, add a maximum-wait rule, and preserve coverage/hole patching.
Modify the existing `select_probe` path; do not introduce a global sort or an
unbounded update queue. Maintain existing slot capacity and maximum primary rays.

**Cost:** bounded local comparisons and priority metadata. Equal ray counts do
not guarantee equal tracing time because selected geometry changes. **Confidence:**
medium-high for better refresh allocation, high for containing scheduling cost.
Prevent starvation and repeated selection of the same region; test interactions
with the existing adaptive patching and retained-probe paths.

### 3. Two-level transitions in cache detail

**Practical effect:** fine lighting detail emerges gradually instead of switching
abruptly when an entry reaches the sample threshold.

Modify `read_component` to transition between a fine estimate and its immediate
parent near the existing threshold. Use at most two adjacent levels and return to
one estimate outside the transition. Do not treat empty entries as black samples.
Keep allocation, mip construction, and the baseline threshold intact initially.

**Cost:** additional cache reads during transitions; no persistent lighting storage
or rays. **Confidence:** high for smoothing sample-threshold transitions. This is
not a proven cure for distance-dependent darkening and does not smooth transitions
between world-cache size levels. Check for increased blur, light leakage, and noise
from premature fine-detail admission, including consumers in reflections.

## Deferred proposals and corrected expectations

- **Priority-light sampling within the same budget:** AMD already evaluates
  multiple candidates before visibility selection. A different allocation can
  shift noise to other lights rather than improve overall quality. Benefit and
  estimator/reservoir integration are not established.
- **Separately evaluate the flashlight:** credible targeted quality option, but
  extra shadow work and separating its contribution without double counting need
  a dedicated design. Not part of the first package.
- **Geometry-aware cache rejection / two surface records:** rejecting mixed
  estimates can remove the only usable lighting. Robust recovery can require more
  sampling or a cache redesign; not a low-risk first step.
- **Automatic extra-ray bursts:** first evaluate better scheduling at the existing
  budget. Any later increase must be an explicit, bounded quality option.
- **Compact metadata is not automatically cheap:** at default capacity there are
  2^14 buckets x 16 tiles x 64 base cells. Four bytes per base cell is 64 MiB per
  cache, or 128 MiB for direct plus indirect, before duplicate histories. Prefer
  coarser metadata only where its accuracy is sufficient; budget actual storage.

No Split Radiance Cascades component is being ported by this plan. Its research
motivated discussion, but the package above is a proposed modification of our AMD
pipeline, not a published or benchmarked AMD/Split RC improvement.

## Acceptance and boundaries

Implement and measure candidates separately before combining them. Preserve the
frozen baseline, AMD defaults, feature-off resource behavior, and a selectable
original algorithm. The owner authorized this first package; deferred proposals
still require separate approval under the existing deviation policy.

- Compare flashlight on/off and movement; require improvement in both directions.
- Check unchanged dim areas, flickering hazards, disocclusion, moving objects,
  camera cuts, and sustained movement for noise, trails, or update starvation.
- Exercise multibounce, reflections, retained probes, adaptive sampling, odd
  viewport sizes, feature toggles, multiple views, and DLSS/FSR integration.
- Use native resolution without FSR2/TAA for diagnosis; reserve FSR2 Native AA
  for final result presentations, per the owner's later instruction.
- Use the default quarter-sample budget with denoising enabled. Match scenes,
  resolution, exposure, and other rendering settings; isolate VBAO when diagnosing.
- Measure GPU time and VRAM as well as visual quality on the 5090 and 780M.
  No percentage saving, millisecond cost, or superiority to another GI method has
  been established. Require the visual gain to justify the measured cost.

Known likely failures (noise, starvation, over-soft transitions) have remedies
within these components. This is a scope assessment, not proof that implementation
cannot expose deeper issues. Reflections and all distant dark patches are not
promised solved by this package.
