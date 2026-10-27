# AMD GI integration decisions

This is the durable engineering boundary, verified against commit `66bd97e00d`.
Use [implementation contracts](internals/amd-gi.md) for rebuilding and the portable
AMD GI feature guide for use. Historical proposals and approval conversations live
in [the archive](history/AMD_GI_ARCHIVE.md); they are not the current feature list.

## Baseline and scope

- Follow AMD Capsaicin GI 1.2 at `914b91596cd119eda85fbc1d3c7ee6ac391b1452` as closely
  as practical. Necessary Godot/Vulkan adapters do not justify new estimators,
  arbitrary invalidation, or altered artistic intent. Further algorithm deviations
  require strong evidence and owner approval.
- Preserve Godot light attenuation, energy, masks, authored materials, and final
  material response. Native shader execution replaces the validator's coarse
  captures; materials may change independently of meshes.
- Ordinary CPU-managed 3D MultiMesh is required and implemented. GPU-indirect
  MultiMesh and shader-driven displacement remain outside supported ray transport.
  Grass displacement needs a separate performance/accuracy decision.
- Orthographic views and negative/subtractive GI lights are deliberately unsupported.
  Retain their native lighting rather than inventing signed cache transport.
- Diagnostic tools, uniform/cosine/luminance sky choices, debug displays, and AMD's
  split-ratio reflection alternative are implemented options. Cosine sky and a-trous
  reflections are recommended defaults, not hardware-measured winners.

## Corrections and adapters to preserve

| Contract | Reason |
| --- | --- |
| Transform hit shading and geometry normals to world space exactly once. | Source review found missing/double transforms; their distinct roles still matter. |
| Index multibounce bypass by the actual compacted hit; map secondary results to the correct parent and apply the existing BRDF/PDF weight. | Preserve AMD's intended contribution, not raw unweighted injection. |
| Treat a shader that writes EMISSION as an emitter independently of its current RGB. | Black texels or a dark animation phase must not repeatedly change material/scene classification. |
| Keep a flat light-grid axis as one cell. | Avoid inventing arbitrary thickness for degenerate bounds. |
| Retain the reference 1e9 tracing range; cap only stored probe reprojection distance at 65504 and widen its integer accumulator. | Half-float storage limits must not change actual hit locations or RGB/weights. |
| Reject historical samples whose light index is outside the current logical list. | Avoid stale reads without invented stable IDs or unrelated history resets. |
| Use supported affine emitter UV mappings in the existing filtering formula; diagnose unsupported nonlinear mappings. | Respect authored coordinates without silently claiming arbitrary shader-map support. |
| Convert Vulkan cube orientation and preserve sampled world direction in the existing half2 octahedral payload. | Re-evaluating a stored seed through upstream's missing importance branch would reconstruct a different direction. Black-face/CDF endpoint handling is integration correctness, not an extra-ray estimator. |
| Keep source-material pipelines compatible with the current scene signature and publish only a complete prepared set. | Failed preparation must not bind a partial set or stale material ABI. |
| Track same-frame acceleration-structure build inputs and shared geometry through both shadow and GI consumers. | Native RD ordering and ownership must cover all consumers. |

## Do not revive without new justification

- Immutable-input firefly cleanup was withdrawn; preserve AMD's in-place cleanup.
- Do not hide failures with generic RGB clamps, shorter tracing limits, arbitrary
  history resets, more preview rays, or silent coarse-material fallback.
- Full refraction/nested specular transport and universal Godot compatibility are
  not goals of this integration.

The shutdown cleanup fix is implemented; older investigation-only restrictions are
historical. Program-run permissions are governed by the current conversation, not
an old dated approval diary. Prepared fixtures and CPU/source proofs are not proof
of GPU acceptance; retain that distinction in future completion claims.
