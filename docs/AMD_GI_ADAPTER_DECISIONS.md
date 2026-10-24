# AMD GI approval boundaries

Current as of 2026-10-24. AMD's pinned algorithm is the baseline. Further deviations
require explicit owner approval with a high-confidence justification. A compatibility
limitation is not permission to invent an alternative estimator or history policy.
Read [current status](AMD_GI_IMPLEMENTATION.md) first. Exact prior proposals, proofs,
responses and withdrawn recommendations are preserved in the
[decision archive](history/AMD_GI_ARCHIVE.md#snapshot-amd-gi-adapter-decisions).

## Approved, narrowly scoped

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
