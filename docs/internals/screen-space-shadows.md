# Screen-space shadows implementation and rebuild contract

Source-checked against `66bd97e00d`. User controls: `GodotForkDocs/features/screen-space-shadows.md`. The feature ports Bend Studio's directional depth march to Godot Forward+ and adds optional caster restriction. It does not replace RT scene traversal or GI.

## Source map

| Source | Contract |
| --- | --- |
| `thirdparty/bend_sss/bend_sss_cpu.h` | Vendored dispatch builder; preserve upstream attribution/license. |
| `servers/rendering/renderer_rd/effects/screen_space_shadows.{h,cpp}` | Effect creation, quality variants, sampler, dispatch list, push constants and failure clear. |
| `servers/rendering/renderer_rd/shaders/effects/screen_space_shadow.glsl` | GLSL march and diagnostics. |
| `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.*` | Eligibility, caster prepass, full-resolution mask, dispatch before opaque shading. |
| `servers/rendering/renderer_rd/forward_clustered/scene_shader_forward_clustered.*` and its scene GLSL | Prepass variants/attachments, mask output, lighting composition. |
| `servers/rendering/renderer_rd/storage_rd/light_storage.*` | First eligible directional light and its `sss_strength` flag. |
| `servers/rendering/renderer_scene_cull.cpp` | Shared RT shadow-caster predicate and persistent screen-space caster classification. |
| `core/config/project_settings.cpp` | Live user controls. |

## Render and projection contracts

`_using_screen_space_shadows` requires the setting, render buffers, a single perspective view and no reflection-probe render. Effect creation is lazy and can fail for missing `R8_UNORM` storage support or shader/pipeline creation. The active light is the first shadow-casting directional light selected by `LightStorage::update_light_buffers`; its `sss_strength` marks the light whose shading will consume the mask. No light means no march.

The target is a full internal-resolution `R8_UNORM` texture in `RB_SCOPE_SCREEN_SPACE_SHADOWS`. White means fully lit. The effect clears it **before** preparation early-outs, so a failed dispatch cannot retain last frame's shadows. The depth prepass must run and be resolved before sampling. A normal depth texture, not a light-space shadow atlas, supplies occluders.

Bend's CPU dispatch builder receives a projected **direction** (`w = 0`) toward the light. Godot's selected directional-light vector already points toward it; negating it reverses the shadow. Use the corrected, jittered projection that rasterized depth. Godot's Y correction and Bend's pixel mapping otherwise double-flip Y, so negate projected light Y at the adapter boundary while leaving the vendored builder unchanged. Keep clip-W sign handling for a sun behind the camera.

Depth is reverse-Z: near 1, far 0. The sampler clamps to black border so an off-screen lookup is far depth, not a repeated edge occluder. Orthographic projection cannot simply share this code: directional clip W becomes zero and the perspective march's depth transformation is inappropriate. The current explicit gate must survive a port.

Each workgroup has 64 lanes and shares depth along light rays. Preserve shared-memory/barrier participation even for invalid output lanes, dispatch offsets and inclusive viewport bounds. Current CPU/GLSL push constant ABI is 76 bytes with a C++ static assertion. Quality variants use 32/60/96 samples and fade lengths 5/8/12; all retain four hard-shadow samples. Contrast remains Bend's 4.0. The fork's hardness blends the mean of four shadow channels (zero: Bend's original behavior) with their minimum (one: a single sample can establish occlusion), improving thin-blade shadow strength without widening the depth tolerance. Keep this explicit Godot/project adaptation distinct from upstream behavior.

## Composition and restricted casters

Forward shading samples this mask for the selected directional light after native RT/cascade shadow calculation. It takes the minimum with the existing shadow factor, so the effect only darkens. Preserve the fragment eligibility gate `RT_MASK_ANSWERS_HERE` and RT sun-distance fade adjustment; blindly multiplying all surfaces can double-darken or apply a mask where no matching depth exists.

Restriction is a second contract, not a separate copy of RT visibility logic. In `renderer_scene_cull.cpp`, `_casts_into_acceleration_structure` describes the **RT shadow** instance eligibility (shadow casting enabled, mesh/MultiMesh, material caster eligibility); `_is_screen_space_shadow_caster` is its complement. Geometry updates persist this bit into `INSTANCE_DATA_FLAG_SSS_CASTER`; the depth shader writes it. Do not reinterpret this predicate as all AMD GI transport membership: GI can retain instances that do not cast RT shadows.

This classification intentionally does not duplicate per-surface masks, individual MultiMesh element culling, light range or BLAS budget decisions. It identifies broad instance categories, not a per-ray proof. Keep dependency updates wired when base type, material or shadow-casting eligibility changes.

`_using_restricted_sss_casters` is used both to select the writing prepass and to bind its mask. It requires directional RT availability and refuses MSAA or visible VoxelGI instances, falling back to unrestricted marching. A stored texture existing is not evidence it was written this frame. MSAA would need the caster value resolved from the depth-selected sample; averaging or OR-ing samples is not correct.

## AMD GI prepass integration

AMD GI introduced `PASS_MODE_DEPTH_GI_MOTION`, which now takes precedence in depth-mode selection. Its eight color attachments include normal/roughness, the caster slot, velocity, previous position, geometric normal, primary material, shading normal and roughness. `get_depth_fb(DEPTH_FB_GI_MOTION, ..., shared_sss_caster)` uses the shared `RB_TEX_SSS_CASTER` when restriction is eligible; otherwise it supplies a private GI-scope caster attachment to maintain the shader layout.

Without this GI path, `PASS_MODE_DEPTH_NORMAL_ROUGHNESS_SSS_CASTER` writes normal/roughness and the caster mask. Keep scene shader version enums, specialization groups, framebuffer formats and GLSL output locations synchronized. Do not restore the older assumption that only the dedicated SSS prepass writes the caster texture, or that VoxelGI always wins the overall depth-mode chain; the shared restriction predicate still explicitly rejects visible VoxelGI.

## Rebuild and validation

1. Restore the standalone effect, vendored dispatch builder, project settings and shader registrations.
2. Reconcile corrected projection, reverse-Z, sampler border, target lifetime and dispatch barriers against the destination engine.
3. Add light selection/flag propagation and the exact opaque composition gate.
4. Port the shared caster predicate and update notifications; integrate both dedicated and AMD GI depth variants before enabling restriction.
5. Validate normal and diagnostic output at odd/internal resolutions, both sun directions, depth edges, resize and live setting changes. Confirm rejected preparation becomes white.
6. Check mesh/MultiMesh/particle categories, shadow flags and alpha-cutout depth. Toggle AMD GI, RT sun, MSAA and visible VoxelGI, checking that masks are fresh and restrictions fall back as specified.

Run only with authorization. Compare visible contacts and profiler cost separately; old project-specific grass measurements are historical evidence, not a universal performance promise. Screen-only misses are inherent, but stale masks, mirrored shadows, out-of-bounds writes and disappearing eligible categories are integration defects.
