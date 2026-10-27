# Screen-space shadows

This Forward+ effect adds short directional contact shadows by marching visible depth toward the sun, using Bend Studio's algorithm. It can complement [RT shadows](rt-shadows.md), including visible foliage omitted from RT shadow casting, but cannot replace off-screen or long-range scene shadows.

Only one shadow-casting `DirectionalLight3D` is selected per render pass. Omni and spot lights do not use it. Orthographic cameras, multiview and reflection-probe renders are excluded.

## Settings

All settings below are live, under `rendering/lights_and_shadows/screen_space_shadows/`.

| Setting | Shipped default | Purpose |
| --- | --- | --- |
| `enabled` | `false` | Enables the effect for eligible views. |
| `quality` | `1` (Medium) | Low/Medium/High march 32/60/96 samples. Higher settings extend the screen-space search and cost more. |
| `surface_thickness` | `0.005` | Depth tolerance. Excessive values create false occlusion; too little misses thin contacts. |
| `bilinear_threshold` | `0.02` | Controls depth-edge handling. |
| `hardness` | `1.0` | Controls shadow strength/shape; lower values soften the result. |
| `restrict_casters` | `false` | With a ray-traced sun, restricts casters to instance categories excluded from RT shadow casting. |
| `ignore_edge_pixels` | `false` | Optional depth-edge rejection; can remove artifacts and valid thin shadows together. |
| `debug_view` | `0` | Disabled, Edge Mask, Thread Index, Wave Index, Caster Mask (`0`–`4`). Diagnostics replace normal shadow output. |

Start with Medium and default thresholds. Full **internal** resolution determines both the effect's reach and its GPU cost.

## With RT shadows and AMD GI

The result only darkens the selected light's shadow factor; it does not add indirect light. `restrict_casters` is useful when a ray-traced sun already shadows ordinary meshes and screen-space shadows should cover excluded instances. Classification is instance-level, not a guarantee about every material surface or MultiMesh element.

Restriction is unavailable with MSAA or visible VoxelGI instances: the effect runs unrestricted and warns. It also requires directional RT shadow availability. AMD GI's depth prepass can supply the caster mask, so AMD GI does not by itself disable restriction.

Setting `cast_shadow` to Off can make an instance a restricted screen-space caster, but does **not** promise removal from AMD GI's acceleration structure. GI transport participation is separate. Consult the RT and AMD GI guides before using shadow flags as a performance control.

## Testing and limits

Check small contacts, foliage silhouettes, screen edges and a sun both in front of and behind the camera. In restricted mode, inspect Caster Mask, then restore Disabled before judging lighting.

Only frontmost visible depth is available. Off-screen objects cannot cast these shadows, transparent surfaces may lack suitable depth, and shadows can disappear as the camera turns. The effect is refused if required storage-image support or shader creation is unavailable; failed dispatch preparation clears toward fully lit instead of preserving stale shadows.

Engine rebuild notes: `docs/internals/screen-space-shadows.md` in the fork repository. Related guides: [ambient occlusion](ambient-occlusion.md), [AMD GI](amd-gi.md).
