# VBAO implementation and rebuild contract

Source-checked against `66bd97e00d`. This is a map for rebuilding the feature on another Godot version, not a claim that source files can be copied without adaptation. User controls live in `GodotForkDocs/features/ambient-occlusion.md`; historical measurements are not acceptance criteria for new hardware.

## Ownership and integration seams

| Source | Responsibility |
| --- | --- |
| `servers/rendering/renderer_rd/effects/gtao.{h,cpp}` | Effect lifecycle, shaders, dispatches, push constants, gather dimensions. |
| `servers/rendering/renderer_rd/shaders/effects/gtao_{prefilter,gather,filter}.glsl` | Depth pyramid, GTAO/VBAO evaluation, spatial filtering and reconstruction. |
| `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.{h,cpp}` | `_use_gtao`, `_ensure_gtao_buffers`, `_process_gtao`, pre-opaque scheduling and fallback. |
| `servers/rendering/rendering_server.cpp` | Project settings and defaults. |
| `scene/resources/environment.{h,cpp}`, `servers/rendering/renderer_rd/storage_rd/environment_storage.*` | Environment method selection, forwarding and inspector visibility. |
| `doc/classes/Environment.xml` and rendering enums/server bindings | Public API documentation and method enum. |

Keep the effect behind Forward+ SSAO eligibility and the environment's SSAO enable flag. `_use_gtao` applies environment override/project default and refuses multiview, leaving legacy SSAO available. Reflection-probe renders skip this path. The implementation has no explicit orthographic gate, but its reconstruction/filter math is not a complete orthographic implementation; this is a limitation, not supported functionality.

## Data and pass contracts

The effect reuses Godot's downstream AO interface: `RB_SCOPE_SSAO` / `RB_FINAL`, a full internal-resolution `R8_UNORM` visibility texture. White means unoccluded. Do not add a competing lighting multiplier merely because the gather is new; opaque shading already consumes the final SSAO result.

The GTAO scope owns a five-mip `R32_SFLOAT` linear-depth pyramid plus `R16G16_SFLOAT` ping-pong gather textures. Gather red is visibility and green is **positive linear view depth**, including early-out/faded pixels. Filtering depends on green; clearing or omitting it produces unstable weights and false edges. Final-target usage includes storage, sampling and copy-to for the failure clear.

There are five compute stages: depth prefilter, gather, horizontal denoise, vertical denoise, upsample/copy to the shared SSAO final. Preserve inter-stage barriers and uniform bindings when adapting RenderingDevice APIs. All threads needed by shared-memory barriers must reach them, including lanes outside the valid image.

Gather dimensions are explicit:

- Full: `(W, H)`.
- Checkerboard: `(ceil(W/2), H)`.
- Quarter: `(ceil(W/2), ceil(H/2))`.

Carry an explicit gather stride into shaders. Integer division of full size by gather size is wrong for odd dimensions. Mip stores must use `max(screen_size >> mip, 1) - 1` as their bound, not `(screen_size - 1) >> mip`. Internal render dimensions can be odd under multiple scaling modes, not only DLSS.

`gtao.h` statically checks current CPU push-constant sizes: prefilter 32, gather 96 and filter 80 bytes. Treat the C++ and GLSL declarations as one ABI. A changed engine alignment rule requires an explicit audit, not deletion of the checks.

## Algorithm to preserve

The depth prefilter uses a farthest-biased weighted mean rather than a nearest-depth min pyramid. Gather samples the pyramid with the intended nearest/mipmap sampler. Reconstruction must match Godot's corrected reverse-Z projection and the positive view-depth convention; a transposed coefficient or doubled Y flip corrupts both radius and occlusion.

The gather uses GTAO slice geometry, projected-normal weighting, two-sided uniformly spaced marching and a static spatial dither. With `visibility_bitmask=true`, finite-thickness samples occupy a union of 32 angular visibility sectors and the sector result is cosine weighted. Turning it off uses the horizon gather. Neither path has an AO history buffer or temporal accumulation.

Sampling radius is defined from the full-resolution footprint, independent of gather rate. With distance scaling, radius grows in world space with depth while its image footprint stays approximately fixed; environment radius and `screen_radius` both affect it. Without scaling, the environment radius is a world-space radius projected at the pixel depth. Preserve the thickness model and sector overlap union: summing occupied sectors instead double-counts occlusion.

Strength uses the environment power, then a bounded intensity mapping. In source terms, for powered visibility `v`, the result is `v / max(v + (1 - v) * intensity, 0.0001)`, with `intensity = environment_intensity * intensity_scale`; distance fade blends toward white. This avoids unbounded negative visibility. Environment detail, horizon and sharpness belong to legacy SSAO, not this gather.

The spatial filter uses plane-aware weights and a small automatically chosen radius, then reconstructs full resolution. Preserve its depth and normal conventions together with gather. More blur is not an equivalent fix for a broken gather or incorrect depth channel.

## Resource lifecycle and coexistence

Size or shading-rate changes invalidate the GTAO scope; the legacy path clears it when taking over. Allocation checks prevent dispatching with missing buffers and clear a valid final result to white on failure. Render buffers own per-view resources; do not move them into one renderer-global history.

SSAO's final visibility is separate from the AMD GI radiance composite and from directional screen-space shadow masks. They can coexist, but visual darkness with several effects enabled is not evidence of a shared resource. Preserve the pre-opaque depth dependency and downstream AO binding when rebasing the clustered renderer.

## Rebuild sequence and validation

1. Restore Environment enum/property propagation and project defaults, keeping legacy SSAO selectable.
2. Add the effect and shader build registrations, then the named textures and final SSAO contract.
3. Integrate pre-opaque scheduling with the new engine's actual depth/normal resolve rules.
4. Reconcile projection math, push constants, samplers, explicit strides and barriers before tuning quality.
5. Exercise full/checkerboard/quarter rates, odd and small sizes, live radius/method changes, resize, disabled SSAO and multiview fallback. Use the existing `docs/validation/ao_validation/` fixtures as starting material, adapting their runner for the new engine.

After permission to run validation, inspect linear AO output and a geometric reference as well as final lighting. Include thin objects, adjacent planes, silhouettes and both camera motion and static views. Test with AMD GI and a temporal upscaler enabled to catch ordering or size assumptions. Compilation alone does not establish visual correctness; old timing or error figures must not be reused as new test results.
