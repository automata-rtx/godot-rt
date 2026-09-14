# DLSS internals (NVIDIA Streamline)

Loader attachment, the resource tagging rule, the constants conventions, the velocity pre-fill, the
hudless copy, the code map. Not here: settings and quality modes (`docs/features/dlss.md`); symptoms
(`docs/TROUBLESHOOTING.md`); incidents (`docs/HISTORY.md`); rebase (`docs/PORTING.md`).

All of it compiles only under `STREAMLINE_ENABLED`, Windows-only. Off Windows the driver files
compile to empty objects — nothing here is exercisable in CI or from a Linux checkout.

## 1. How it attaches: loader interposition

Three lines in `drivers/vulkan/rendering_context_driver_vulkan.cpp`:

| Line | What happens |
| --- | --- |
| `:920` | `streamline_proc_addr = StreamlineVK::initialize()` — loads `sl.interposer.dll`, runs `slInit`, returns the interposer's `vkGetInstanceProcAddr` as a `uint64_t`, or `0` |
| `:923` | `volkInitializeCustom(PFN_vkGetInstanceProcAddr(...))` when non-zero |
| `:924` | otherwise the ordinary `volkInitialize()` |

volk resolves every entry point through whatever proc-address function it is given, so the
interposer returns **its own proxy** for the entry points Streamline wants and the real function for
everything else. **No engine call site changes.** NVIDIA's "manual hooking" route for Vulkan, and
what lets frame generation own the swap chain.

Two distinct sets of proxied entry points, routinely conflated — see section 10:

| Set | Members | Consequence |
| --- | --- | --- |
| **Plugin-registered hooks** — `FunctionHookID`, `thirdparty/streamline/include/sl_hooks.h:69-76` | `vkQueuePresentKHR` (`eVulkan_Present`), `vkCreateSwapchainKHR`, `vkDestroySwapchainKHR`, `vkGetSwapchainImagesKHR`, `vkAcquireNextImageKHR`, `vkDeviceWaitIdle`, `vkCreateWin32SurfaceKHR`, `vkDestroySurfaceKHR` | A loaded plugin may register a before- and/or after-hook on any of these. |
| **The interposer's own proxies** — not in that enum | `vkCreateInstance`, `vkCreateDevice` | `sl_helpers_vk.h:218-219,251`: `slSetVulkanInfo` is to be called **only** when NOT using them. This fork uses them, so it is never called and the engine duplicates none of the instance extensions, device extensions, Vulkan 1.2/1.3 feature bits or extra queues Streamline needs — the proxies add them. |

| Property | Because |
| --- | --- |
| **The enable flag is restart-required.** `rendering/streamline/enabled` is read once, in `StreamlineVK::initialize()`. | Interposition happens at `volkInitializeCustom`, before `vkCreateInstance`. By the time a setting could be toggled the instance, device and swap chain exist through one loader or the other, and the process's entry-point table cannot be swapped underneath live objects. |
| **Failure is all-or-nothing.** Setting off, DLL missing, signature not NVIDIA's, an export failing to resolve, or `slInit` refusing → `initialize()` returns `0`, the singleton is never created, `volkInitialize()` runs as before. | Every entry point below sits behind a null check on `StreamlineVK::get_singleton()`, so there is no half-loaded state. The cause is kept in the static `unavailability_reason` string so a later warning can name it. |
| **The header boundary.** Nothing in `drivers/vulkan/streamline_vk.h` names a Vulkan or Streamline type; native handles cross as `uint64_t`, as `RenderingDevice::get_driver_resource()` already hands them out. **Preserve this when adding to the wrapper.** | It is what keeps `servers/rendering/renderer_rd/effects/dlss.cpp` free of both include paths. |

## 2. Which features are loaded, and why `sl.dlss_g` is not loaded in the editor

`streamline_vk.cpp:643-646`:

```
internal->frame_generation_requested = !Engine::get_singleton()->is_editor_hint();
const sl::Feature features[] = { kFeatureDLSS, kFeatureReflex, kFeaturePCL, kFeatureDLSS_G };
const uint32_t feature_count = internal->frame_generation_requested ? 4 : 3;
```

The array is fixed and only the **count** changes, so in the editor `kFeatureDLSS_G` is not named in
`preferences.featuresToLoad`. A feature left out of that list is freed on discovery rather than
loaded, and its hooks go with it.

**Necessary, not tidiness.** `sl.dlss_g` is the only plugin registering a hook on
`vkCreateSwapchainKHR`, and the interposer returns a before-hook's error verbatim **without calling
the driver** — a swapchain DLSS-G declines is a swapchain that is not created. Every editor context
menu and menu-bar dropdown is an OS window with its own swapchain, so with the plugin loaded each
renders blank. Frame generation could never run there anyway: the presented image is the editor's
own interface.

Ruled out, both checked against SDK source rather than assumed:

| Claim | Why it fails |
| --- | --- |
| `PreferenceFlags::eUseManualHooking` suppresses the hook | The interposer reads that flag only in `slUpgradeInterface` and in sl.common's D3D12 pipeline restore; the Vulkan wrapper hands out its proxies unconditionally. The DLSS-G guide's "unless manual hooking is used" is about the DXGI factory proxy, and its own worked example for the multiple-swapchain case reaches for `slSetFeatureLoaded`. The flag stays set (`streamline_vk.cpp:670`) because it describes how this engine attaches; clearing it only re-arms D3D paths. |
| A multi-window *game* is handled the same way | It is **not handled at all**. `RenderingDeviceDriverVulkan` batches every window's swapchain into one `vkQueuePresentKHR`, so there is no per-window native/proxy split to route around it. Exported games request `kFeatureDLSS_G` unconditionally — `Engine::is_editor_hint()` compiles to a constant `false` in a release template. |

Full preference flag set (`streamline_vk.cpp:669-673`): `eDisableCLStateTracking`,
`eUseManualHooking`, `eUseFrameBasedResourceTagging`, `eAllowOTA`, `eLoadDownloadedPlugins`.
`renderAPI` is `eVulkan` — without it `slGetFeatureRequirements` and the create-device proxy both
assume D3D12.

## 3. Device binding (`StreamlineVK::set_physical_device`)

From `drivers/vulkan/rendering_device_driver_vulkan.cpp:1914`, once the physical device exists.
Everything feature-related happens here, not at `slInit`.

| Behavior | Because |
| --- | --- |
| **The LUID is load-bearing.** `sl::AdapterInfo` is filled from `VkPhysicalDeviceIDProperties`; a device reporting no LUID warns. | It is what reaches the plugin's per-adapter test. Without it `slIsFeatureSupported` returns early (`if (!ctx->isSupported || !adapterInfo.deviceLUID) return Result::eOk;`) and the only surviving gate is "is any adapter on this machine supported" — which on a mixed-vendor machine answers about a GPU the engine is not rendering on. |
| `FEATURE_DLSS_FRAME_GENERATION` is **skipped entirely** in the support loop when `frame_generation_requested` is false, rather than queried. | The plugin's config is cached on discovery and only then freed for not having been requested, so the query answers `eErrorFeatureMissing` and the warning would name two DLLs already in the directory. |
| Per-feature entry points resolve here via `slGetFeatureFunction` (`streamline_vk.cpp:810-815`); each resolution failure warns by name. | A feature can be reported available by `slIsFeatureSupported` — which needs only the adapter — and still fail to hand over its entry points. |
| **Reflex is switched on process-wide here**, mode `eLowLatency`. `reflex_running` gates `frame_generation_set_enabled`. | It paces CPU against GPU, not a per-view idea; and frame generation reports `eFailReflexNotDetectedAtRuntime` and stops presenting interpolated frames without it. |
| A second `VkDevice` (a local rendering device) is ignored. | `device_ready` latches on the first. |

## 4. The resource tagging rule

**Anything tagged for Streamline must be a texture of its own — never a view, never a slice.**

Mechanism, verified in the driver source:

| # | Step |
| --- | --- |
| 1 | A tag names its resource by its native `VkImage`. |
| 2 | `RenderingDeviceDriverVulkan::get_resource_native_handle` answers `DRIVER_RESOURCE_TEXTURE` with `tex_info->vk_view_create_info.image` (`rendering_device_driver_vulkan.cpp:7294-7296`) — the image, not the view. |
| 3 | `texture_create_shared` (`:2547-2589`) copies the parent's whole `VkImageViewCreateInfo` and replaces only the swizzle/format fields; `texture_create_shared_from_slice` (`:2605-2642`) does the same for the subresource range. Both then `*tex_info = *owner_tex_info` and overwrite only `vk_view`. **`.image` is inherited unchanged in every case.** |
| 4 | Parent, swizzled view and slice therefore all resolve to one handle through `StreamlineVK::texture_from_rid` (`streamline_vk.cpp:906`). |
| 5 | With `eUseFrameBasedResourceTagging` set (`streamline_vk.cpp:671`), two tags built from any of them **name the same resource and collide**. |

### The reactive mask, and the incident that established the rule

| | |
| --- | --- |
| **What Godot's reactive mask is** | The color buffer's **alpha channel**. `pass_alpha_multiplier` (`storage_rd/render_scene_data_rd.cpp:130`, consumed at `shaders/forward_clustered/scene_forward_clustered.glsl:3274`) zeroes alpha across the opaque pass whenever the motion pass runs; the transparent pass then blends into it, so the channel accumulates transparent coverage. FSR2 is handed an alpha-swizzled **view** of that buffer — `get_internal_texture_reactive()` (`storage_rd/render_scene_buffers_rd.h:281`, all four swizzles `TEXTURE_SWIZZLE_A`), passed at `render_forward_clustered.cpp:3098` — and needs nothing else, because the engine binds that view itself as an ordinary shader resource in its own dispatch and never goes through Streamline's tagging. |
| **The incident** | Tagging that same view as `kBufferTypeBiasCurrentColorHint` gave the color tag and the reactive tag the same image handle. DLSS sampled the swizzled view **as its input color** — alpha replicated to all four channels, and alpha is zero everywhere the opaque pass drew — so every opaque pixel went black. FSR2 was unaffected, per above. Incident: `docs/HISTORY.md`. |
| **The fix** | `dlss_reactive.glsl` (`servers/rendering/renderer_rd/shaders/effects/`) exists solely to obey the rule: it copies the alpha into a distinct `R8_UNORM` image at the internal size, created on demand at `render_forward_clustered.cpp:3159-3164` as `RB_SCOPE_DLSS` / `RB_TEX_DLSS_REACTIVE` (`render_forward_clustered.h:56-57`), `SAMPLING \| STORAGE`. |
| **Lifetime** | The texture lives in the `RB_SCOPE_DLSS` scope and is freed when the render buffers are next **configured**, not when `rendering/streamline/reactive_mask` goes off — turning the setting off mid-run stops the copy but leaves the texture allocated until a resize or viewport reconfigure. |

### What is tagged

Super resolution, `streamline_vk.cpp:1157-1169`, all `eValidUntilEvaluate` because every one is read
and written inside the single `slEvaluateFeature` call:

| Tag | Source | Extent |
| --- | --- | --- |
| `kBufferTypeScalingInputColor` | internal color | internal rect |
| `kBufferTypeDepth` | depth | internal rect |
| `kBufferTypeMotionVectors` | velocity | internal rect |
| `kBufferTypeScalingOutputColor` | upscaled color | none — it is the full output image |
| `kBufferTypeExposure` | luminance buffer, only when the camera has auto exposure | none |
| `kBufferTypeBiasCurrentColorHint` | the `RB_SCOPE_DLSS` / `RB_TEX_DLSS_REACTIVE` texture, only when `rendering/streamline/reactive_mask` is on | internal rect |

Frame generation, `streamline_vk.cpp:1349-1353`, all `eValidUntilPresent` because DLSS-G reads them
inside the present hook long after the command buffer was submitted: `kBufferTypeDepth`,
`kBufferTypeMotionVectors`, `kBufferTypeHUDLessColor`.

Extents are set explicitly to the internal rect rather than left implicit
(`effects/dlss.cpp:129-140`): color, depth and velocity happen to be allocated at the internal size
today, and stating it keeps what Streamline upscales from tied to the renderer's internal size if
one is ever allocated larger than the region rendered.

### Layouts, and the callback seam

Streamline is handed the **raw command buffer** and records its own passes into it; the engine
records none of the work. `RenderingDevice::driver_callback_add()` is that seam
(`effects/dlss.cpp:156`, `:221`), handing it over at a point where the render graph has already put
every resource declared alongside it into a known layout.

| Seam detail | Rule |
| --- | --- |
| `texture_from_rid` takes a `TextureUse` and reports the layout that implies — `VK_IMAGE_LAYOUT_GENERAL` for `TEXTURE_USE_STORAGE`, `VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL` otherwise. | **The `CallbackResource` list passed to `driver_callback_add` is what actually produces those layouts, so the two lists must agree.** In `DLSSEffect::upscale` every sampled input is `CALLBACK_RESOURCE_USAGE_TEXTURE_SAMPLE` and the output `CALLBACK_RESOURCE_USAGE_STORAGE_IMAGE_READ_WRITE`, matching the `TEXTURE_USE_*` each was converted with. Adding a tagged resource means adding it to **both** lists. |
| `texture_from_rid` also rebuilds the image's `VkImageUsageFlags` from `texture_get_format()`, because Streamline hands them straight to its own Vulkan backend. | That mapping mirrors `RenderingDeviceDriverVulkan::texture_create()` by hand and **must not drift from it**. |
| `to_sl_command_buffer` (`streamline_vk.cpp:258-265`) converts the callback's `CommandBufferID` via `RenderingDeviceDriverVulkan::command_buffer_get_vulkan_handle` (`:3495`). | Safe by construction: the only callers are callbacks registered through `RenderingDevice::get_singleton()`, and Streamline drives that one device only. |

## 5. Constants: motion vector, depth, jitter and matrix conventions

`StreamlineVK::_set_constants` (`streamline_vk.cpp:979-1007`), sent once per evaluate and once per
frame-generation tag. Every feature reads these, so an error here is a **wrong image rather than a
missing one**. Each convention fails visibly and in its own way, which is what makes an artifact
attributable:

| Constant | Value | Why | Symptom if wrong |
| --- | --- | --- | --- |
| `mvecScale` | `{1, 1}` (`:989`) | The buffer already holds a whole-screen displacement as 1.0 | smearing under camera motion |
| `motionVectorsJittered` | false (`:1004`) | The motion pass subtracts jitter from both endpoints | smearing under camera motion |
| `depthInverted` | true (`:1000`) | The engine's depth is reverse-Z: 1.0 at the near plane | no image, or garbage |
| `cameraMotionIncluded` | true (`:1001`) | Camera motion is in the buffer, not derived | double or missing reprojection |
| `motionVectors3D` / `motionVectorsDilated` | false | 2D screen-space, undilated | — |
| `clipToPrevClip` | `to_sl_matrix(...)`, straight copy (`:983`) | see below | ghosting that survives a **still** camera |
| `jitterOffset` | pixels (`:985`) | same expression FSR2 is handed | stable but soft, or shimmering at native scale |
| `cameraFwd` | `-basis.get_column(2)` (`:994`) | Godot cameras look down -Z | — |

**Motion vector unit, from the shader**
(`servers/rendering/renderer_rd/shaders/forward_clustered/scene_forward_clustered.glsl:3295-3301`;
the `prev_` pair is the same expression against `scene_data_block.prev_data.taa_jitter`):

```
vec2 position_clip = (screen_position.xy / screen_position.w) - scene_data.taa_jitter;
vec2 position_uv = position_clip * vec2(0.5, 0.5);
motion_vector = prev_position_uv - position_uv;
```

NDC spans 2.0 across the screen, so the `* 0.5` puts the difference in UV units: a displacement
across the whole screen is 1.0 — the same unit a pixel-space buffer reaches after division by the
render size, which is what Streamline calls normalized. Hence `mvecScale` of 1.

**Matrices cross as a straight copy, deliberately.** `to_sl_matrix` (`streamline_vk.cpp:100-110`)
writes `p_projection.columns[i]` into `out.row[i]`. Godot stores columns and multiplies as `M * v`;
Streamline stores rows and multiplies as `v * M`. Those are transposes of each other in both
convention and storage, and the two cancel. **Do not "fix" this by adding a transpose.** Sources:
`render_forward_clustered.cpp:3186-3191` (super resolution) and
`renderer_scene_render_rd.cpp:1586-1592` (frame generation), both building `clip_to_prev_clip =
(correction * prev_proj) * prev_transform.affine_inverse() * cur_transform * clip_to_view` — the
same reprojection FSR2 is given.

These conventions are **confirmed in practice**, not only from the SDK headers: super resolution ran
clean on hardware with none of the artifacts above present (`docs/features/dlss.md`, "Verified
status").

## 6. The velocity buffer pre-fill, and `MotionVectorsStore`

`render_forward_clustered.cpp:2824-2847`. Godot clears the velocity buffer to `(-1, -1)` as a
**sentinel** meaning "nothing wrote a motion vector here". FSR2 gets away with it because Godot
patched its shader to recognize the value and derive camera motion from depth on the spot
(`FFX_FSR2_OPTION_GODOT_DERIVE_INVALID_MOTION_VECTORS`, implemented by `derive_motion_vector` in
`shaders/effects/motion_vector_inc.glsl`).

**DLSS's shader cannot be patched.** It reads whatever the buffer holds, and with `mvecScale` at 1
the plugin multiplies by the render size, so the sentinel arrives as a full screen of motion at
every pixel the motion pass did not overwrite — in a still scene, every pixel. History then misses
everywhere on every frame, nothing accumulates, and the output stays at the current jittered
low-resolution render with every edge crawling through the jitter sequence forever.

So `SCALE_DLSS` takes the same camera-motion pre-fill MetalFX Temporal does — `if (scale_type ==
SCALE_MFX || scale_type == SCALE_DLSS)` calls `motion_vectors_store->process(rb, cam_projection,
cam_transform, prev_cam_projection, prev_cam_transform)`, every other mode clears to `(-1, -1)`.
That is why `RendererRD::MotionVectorsStore` is **no longer MetalFX-only**.

`MotionVectorsStore::process` (`effects/motion_vectors_store.cpp:51`) builds the same reprojection
matrix as FSR2 and dispatches `shaders/effects/motion_vectors_store.glsl` over the internal size,
writing `derive_motion_vector(uv, depth, reprojection)` into every texel. The motion pass that
follows overwrites it for anything actually moving.

### The billboard previous-camera fix

`storage_rd/render_scene_data_rd.cpp:295`: `MaterialStorage::store_transform(prev_cam_transform,
prev_ubo.main_cam_inv_view_matrix)`.

| | |
| --- | --- |
| The bug (**stock Godot, not Streamline-specific**) | The `memcpy` seeding the previous-frame UBO had left that field holding the **current** camera, so the previous-frame vertex evaluation — the one that exists to produce a motion vector — oriented billboard quads with the basis the camera has now. A billboard therefore reported almost no motion of its own however fast the camera turned, and every temporal consumer downstream (DLSS, FSR2, TAA) smeared it. |
| Why `prev_cam_transform` and not a new `prev_main_cam_transform` | Motion vectors are calculated only from `_render_scene`, where `main_cam_transform` and `cam_transform` are both `p_camera_data->main_transform`. The three paths setting `main_cam_transform` to something else — shadow append, particle collider heightfield, material render — all leave `calculate_motion_vectors` false and never reach here. |

## 7. The hudless copy

Frame generation interpolates two neighboring frames and interpolated UI is the artifact people
notice first, so DLSS-G wants the presented image **without** the interface drawn over it.

**Where it is taken.** `RendererSceneRenderRD::_process_frame_generation` is called at
`renderer_scene_render_rd.cpp:1517`, immediately after `_render_scene` returns — the scene renderer
has just tone-mapped into the render target and the canvas has not been drawn (`_draw_3d` at
`renderer_viewport.cpp:475`, the canvas loop only from `:780`). That gap is the one moment the image
exists. Source is `TextureStorage::render_target_get_rd_texture(render_target)`; the copy is a
straight `texture_copy` into a texture allocated by `StreamlineVK::frame_generation_capture_hudless`
(`streamline_vk.cpp:1263`), matching the source's format and size.

| Detail | |
| --- | --- |
| Allocated only while frame generation actually runs on that viewport; freed by `_free_hudless` the moment it stops or the render target resizes. | Feature off → no texture, no copy. |
| Issued from `DLSSFrameGeneration::update` (`effects/dlss.cpp:185`) **before** `driver_callback_add`. | So the render graph orders it ahead of the tag. |
| Destination created `SAMPLING \| CAN_COPY_TO \| CAN_COPY_FROM` only, named "Streamline HUD-less Color". | |
| A render target sized differently from what frame generation was configured with warns once and still copies. | The copy succeeds, but what Streamline interpolates no longer matches what it was told to expect. A stretch mode making the render target a different size from the swap chain has not been considered. |
| **Why a copy rather than tagging the render target.** | The tag is `eValidUntilPresent` — DLSS-G reads it inside the present hook, and the render target has the UI drawn over it before present, so tagging it directly would hand DLSS-G the composited image. |
| **UI alpha is not provided — the largest known gap.** | Streamline also accepts a UI Color and Alpha, or a UI Alpha buffer, which would let it recompose the interface over the generated frame instead of leaving the previous frame's in place. Godot draws canvas straight onto the same render target as the 3D image and has no separate interface target to hand over, so producing one means a second canvas pass into its own buffer. Without it, a moving interface element smears across generated frames. |

## 8. Frame token and latency markers

`servers/rendering/rendering_server_default.cpp:80-160`. A frame's whole Streamline workload —
token, latency markers, tags, feature evaluations — happens on whichever thread renders. Nothing
crosses to the main thread: `draw()` queues this without waiting, so a token taken during simulation
could be replaced while the previous frame was still being tagged.

Order: `frame_begin()` + `sleep()` + `MARKER_SIMULATION_START` → scene/canvas/particle updates →
`MARKER_SIMULATION_END`, `MARKER_RENDER_SUBMIT_START` → `draw_viewports` →
`MARKER_RENDER_SUBMIT_END`, `MARKER_PRESENT_START` → `rasterizer->end_frame()` (where the swap chain
is presented, so frame generation's interpolation runs here, inside the present hook) →
`MARKER_PRESENT_END`, `frame_end()`.

Cost: with a threaded rendering model the simulation markers bracket the render thread's frame
rather than the game's simulation step, so Reflex's latency **report** is approximate. Its pacing,
and frame generation's requirement that Reflex be running, are satisfied either way.
Single-threaded, the markers land where they belong.

## 9. Every fork pass is budgeted in internal pixels

**Every pass this fork adds dispatches from `get_internal_size()`**, not the output size:

| Pass | Dispatch size |
| --- | --- |
| Raytraced shadow trace and denoiser | `render_forward_clustered.cpp:2184`, `:2203` — `internal_size` |
| Bend screen space contact shadow | `render_forward_clustered.cpp:2230` — `rb->get_internal_size()` |
| GTAO prefilter / gather / filter | `render_forward_clustered.cpp:1557` — `get_internal_size()` as `full_size` |
| DLSS itself | `effects/dlss.cpp` — `p_params.internal_size` |

So **three** fork quantities are in **pixels** rather than world units and silently rescale relative
to the output image. Arithmetic from the scale factor, not measured; user-facing table in
`docs/features/dlss.md`.

| Quantity | Where | At a 0.67 scale |
| --- | --- | --- |
| Contact shadow march length (fixed in samples by its quality tier) | `docs/internals/screen-space-shadows.md` | reaches ~2/3 as far across the output |
| `raytraced_shadows/denoiser/min_filter_pixels` | `environment/rt_scene.cpp:154-155`, clamped 0-8 | reaches ~2/3 as far across the output |
| `MAX_PENUMBRA_PIXELS` | `shaders/effects/rt_shadow_trace.glsl:28`, `rt_shadow_atrous.glsl:37`, both `32.0` | covers ~1.5x as much of the output |

**DLSS is the only feature that makes the render size arbitrary**, so it is what exposes a latent
size-alignment assumption — Godot truncates the internal size, and a new pass must be checked
against an awkward size rather than the native one (`CLAUDE.md`). One defect was found this way, in
the GTAO depth prefilter's mip bound (`shaders/effects/gtao_prefilter.glsl:143-150`); mechanism in
`docs/internals/ambient-occlusion.md`, incident in `docs/HISTORY.md`.

## 10. Two claims to distrust

Both were stated the other way in the pre-restructure Streamline integration document; both were
checked against the code and headers here.

| Old claim | Correction |
| --- | --- |
| `vkCreateInstance` / `vkCreateDevice` are in `sl_hooks.h` | **They are not.** `FunctionHookID` (`thirdparty/streamline/include/sl_hooks.h:46-79`) lists eight Vulkan entries and neither is one; they are separate interposer proxies (`thirdparty/streamline/include/sl_helpers_vk.h:218-219,251`). Section 1 has the correct split. The conclusion drawn from the old wording — that `slSetVulkanInfo` is never called because the proxies are used — is nevertheless right. |
| The GTAO mip-bound defect was reachable only through DLSS | It was invisible on the **3440x1440** target, which divides cleanly at every level — not invisible at every native resolution; 1920x1080 trips it at level 4 (`docs/internals/ambient-occlusion.md`). |

## 11. Code map

| File | What is there |
| --- | --- |
| `drivers/vulkan/streamline_vk.h/.cpp` | The entire runtime wrapper. All Streamline- and Vulkan-specific code. Handles cross as `uint64_t`. |
| `drivers/vulkan/rendering_context_driver_vulkan.cpp` | `StreamlineVK::initialize()` + `volkInitializeCustom()` at `:920-923`; `StreamlineVK::finalize()` in the destructor. |
| `drivers/vulkan/rendering_device_driver_vulkan.cpp/.h` | `set_physical_device()` at `:1914`; `command_buffer_get_vulkan_handle()` at `:3495`; `get_resource_native_handle()` at `:7276`. |
| `servers/rendering/renderer_rd/effects/dlss.h/.cpp` | `DLSSEffect` (super resolution + the reactive mask dispatch) and `DLSSFrameGeneration`, both renderer-side effects driven by `driver_callback_add`. |
| `servers/rendering/renderer_rd/shaders/effects/dlss_reactive.glsl` | Copies the color buffer's alpha into an `R8_UNORM` texture of its own. Globbed by the effects `SCsub`, so nothing registers it. |
| `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp/.h` | The `SCALE_DLSS` branch (`:3121`), the velocity pre-fill (`:2838`), `RB_SCOPE_DLSS` / `RB_TEX_DLSS_REACTIVE` (`.h:56-57`). |
| `servers/rendering/renderer_rd/effects/motion_vectors_store.h/.cpp` | The camera-motion pre-fill, no longer MetalFX-only. |
| `servers/rendering/renderer_rd/storage_rd/render_scene_data_rd.cpp` | Previous frame's `main_cam_inv_view_matrix` (`:295`), so billboards produce a motion vector; `pass_alpha_multiplier` (`:130`). |
| `servers/rendering/renderer_rd/renderer_scene_render_rd.cpp/.h` | `_process_frame_generation` (`:1517` call, `:1522` body), including the hudless capture. |
| `servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.h/.cpp` | The per-viewport Streamline handle (`streamline_viewport`, 0 means unclaimed) and its release; `get_internal_texture_reactive()` (`.h:281`). |
| `servers/rendering/rendering_server_default.cpp` | Frame token and latency markers around the render frame. |
| `servers/rendering/renderer_viewport.cpp/.h` | The DLSS → FSR 2 fallback rule (`:183-205`) and `is_render_target_presented()` (`:138`). |
| `platform/windows/detect.py` | `wintrust` on the link line, for the Authenticode check. |
| `thirdparty/streamline/` | Headers only — `LICENSE.txt` and `include/`. No SDK binaries are vendored. |
