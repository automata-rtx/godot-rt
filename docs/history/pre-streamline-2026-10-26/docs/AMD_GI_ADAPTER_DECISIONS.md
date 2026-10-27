> Historical snapshot from `66bd97e00d` before the 2026-10-26 documentation audit. Claims and line numbers may be superseded. Do not use as current configuration guidance.

# AMD GI approval boundaries

Current as of 2026-10-25. AMD's pinned algorithm is the baseline. Further deviations
require explicit owner approval with a high-confidence justification. A compatibility
limitation is not permission to invent an alternative estimator or history policy.
Read [current status](AMD_GI_IMPLEMENTATION.md) first. Exact prior proposals, proofs,
responses and withdrawn recommendations are preserved in the
[decision archive](history/AMD_GI_ARCHIVE.md#snapshot-amd-gi-adapter-decisions).

## Approved, narrowly scoped

- Negative/subtractive lights are explicitly unsupported by AMD GI for this game. Retain native direct lighting, exclude them from GI light sampling and outgoing-light feedback, and warn rather than invent signed cache transport.
- Orthographic cameras are explicitly unsupported by AMD GI. Clear only the affected view's GI output and retain native lighting; do not evict shared perspective-view resources.
- Fix TLAS input-buffer accounting, muzzle-flash integration overhead and material-pipeline preparation recovery without changing AMD estimators. Ordinary game-used MultiMesh remains required. Full shader-driven grass deformation depends on its performance cost and is not enabled by this approval.
- Investigate shutdown crashes only; do not modify their suspected code paths or system configuration in this pass. Broader lifecycle work, prewarming/loading overlays and unrelated Godot compatibility remain deferred.
- Preserve Godot's authored light attenuation, energy, masks and final material response at the integration boundary. This does not authorize coarse captures or estimator changes.
- Transform hit geometry and shading normals to world space exactly once. The owner's conditional approval applied after source tracing proved localized AMD missing/double transforms, not an intentional screen/world split. Preserve their separate roles.
- Read the multibounce bypass flag for its actual hit rather than the uncompacted index.
- Map secondary bypass results to their correct parent ray and apply AMD's existing BRDF/PDF weight before injection; do not inject the raw unweighted light.
- Classify a native shader writing EMISSION as emissive independently of current emitted RGB; preserve authored RGB. Black texels/dark phases retain the classification.
- For flat light-grid bounds, select the single cell along a zero-width direction; do not expand bounds by an arbitrary minimum thickness.
- Keep actual tracing/hit positions at the reference 1e9 range; cap only stored probe reprojection distance at 65504 and widen only its integer accumulator. RGB and sampling weights unchanged.
- Reject historical light samples whose index is outside the current logical light list. Do not reset unrelated history or invent stable-ID remapping.
- Use actual supported affine emitter texture coordinates (alternate UVs, scaling/translation/rotation, supported aliases/varyings) in AMD's unchanged filtering formula. Arbitrary warped/texture-driven mappings were excluded from the recommendation; unsupported cases retain a diagnosed fallback.

## Withdrawn or not approved

- Immutable firefly-cleanup input: withdrawn at the owner's request because no worthwhile lighting improvement was established. Keep AMD's in-place cleanup; exceptional nonfinite behavior is not fixed by claiming consistency.
- Do not add generic RGB clamps, substitute finite tracing limits, arbitrary history resets, higher preview ray counts or silent coarse material fallback.
- Remaining optional AMD modes and Godot compatibility work are recorded, not newly implemented or blanket-approved by this document. Full refraction/nested specular transport is beyond the current baseline.

Only read the archived decision subsection/source proof relevant to a proposed change.
Do not request approval again for the exact scope already approved above.


## Runtime options authorization, 2026-10-25

Owner requested all diagnostic tools, both sky samplers, debug visualizers and
alternate AMD reflection denoising as live options. Implemented against Capsaicin
`914b91596cd119eda85fbc1d3c7ee6ac391b1452` (GI 1.2). Cosine is the recommended sky
default; existing AMD a-trous remains the reflection default. These recommendations
are source-reviewed, not hardware-measured presets.

Necessary sky integration corrections: Vulkan cube-face orientation, black-face
and floating-point CDF endpoint handling, and storing importance sample world
direction in the existing signed-half2 octahedral payload. Upstream stored-sample
evaluation lacks its importance branch; retaining seeds would reconstruct the
wrong direction or remap it when sky contents change. Direction storage preserves
sample identity without another buffer/readback; half precision remains a measured
CPU quantization limitation. No extra rays or replacement estimator was added.

Diagnostics preserve complete direct-light feedback before display isolation.
Paged visualizers expose actual directional cache tiles and retained probe slots.
Readback is opt-in and sampled, with frame IDs. Source-only permission still applies.
No prewarming, shutdown changes, game edits or new grass transport were included.
