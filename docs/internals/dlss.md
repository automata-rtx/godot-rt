# DLSS / Streamline implementation and rebuild contract

Source-checked against `66bd97e00d`, including the shutdown fix. User setup and runtime controls: `GodotForkDocs/features/dlss.md`. The wrapper uses the vendored Streamline headers; external signed runtime DLLs remain a deployment requirement.

## Integration map

| Source | Responsibility |
| --- | --- |
| `drivers/vulkan/streamline_vk.{h,cpp}` | Windows Vulkan SDK loader, signature check, feature queries, native resources, per-viewport SDK state, frame tokens, Reflex, cleanup. |
| `drivers/vulkan/rendering_context_driver_vulkan.cpp` | Interposed instance entry points and final DLL lifetime. |
| `drivers/vulkan/rendering_device_driver_vulkan.*` | Owning-device binding, local-device creation isolation, shutdown preparation. |
| `servers/rendering/rendering_device.*` and device-driver base | Drain work and invoke `prepare_for_shutdown` before GPU resource destruction. |
| `servers/rendering/renderer_rd/effects/dlss.*` | RenderingDevice external-command callbacks for evaluation/tagging. |
| `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp` | Motion prefill, SR inputs/output, reactive mask, matrices and preset. |
| `servers/rendering/renderer_rd/renderer_scene_render_rd.cpp` | Frame-generation eligibility and HUD-less capture before canvas composition. |
| `servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.*` | Stable SDK viewport handles and release on render-buffer destruction. |
| `servers/rendering/renderer_viewport.cpp`, `scene/main/viewport.*` | Requested/effective scaling mode, fallback, public properties/status. |
| `servers/rendering/rendering_server_default.cpp` | Token and latency markers surrounding rendering/presentation. |
| `core/config/project_settings.cpp`, `servers/rendering/rendering_server.cpp` | Settings and public bindings. |

`STREAMLINE_ENABLED` is conditional on Windows and Vulkan. Keep non-Streamline builds working; do not expose raw SDK types throughout the generic renderer. Loading happens early enough to interpose Vulkan creation, which is why enabling or relocating the runtime requires restart. Validate both OS trust and NVIDIA signer identity before loading the interposer. Project identity is supplied at startup, with an engine fallback GUID when none is configured.

## Super-resolution and temporal inputs

The viewport resolves requested DLSS to an effective scaling mode. Unsupported DLSS falls back to FSR2 in the eligible Forward+ path; temporal accumulation is unsuitable for one-shot/non-updating viewports, which fall back to bilinear. Preserve effective-mode/internal-size/status accessors so a project overlay can show what actually runs.

`DLSSEffect` schedules an external Vulkan command callback through RenderingDevice instead of issuing SDK calls on arbitrary game threads. Inputs include internal-resolution color, depth, velocity and optional exposure/reactive information; output is target resolution. The wrapper tags native Vulkan resources and tracks their extents/layouts for Streamline. Preserve callback data lifetime and command-graph ordering: the SDK must see completed inputs and subsequent passes must see its output.

Camera constants form one shared contract for SR and frame generation:

- Reverse-Z (`depthInverted=true`), camera looking along Godot's negative Z basis.
- Normalized 2D motion, previous UV minus current UV, with `mvecScale=(1,1)`.
- Camera motion included; vectors are not dilated and do not include jitter.
- Pixel-space jitter and matched current/previous projection transforms.
- `to_sl_matrix` deliberately maps storage/math conventions; do not add a second transpose by intuition.

DLSS cannot use the engine's old invalid-motion sentinel `(-1,-1)` as FSR2 can. Clustered rendering first fills camera-derived velocity, then moving geometry overwrites it. Preserve this prefill, previous camera transforms for billboards and the timing of the motion pass. AMD GI also consumes motion/depth, so rebuilding either feature must not silently change the other's coordinate or scheduling contract.

The current call site sends `reset_accumulation=false`: camera-cut reset is not wired. Do not describe history resets as fully supported simply because the SDK wrapper has a reset field. The render-buffer destructor releases SDK viewport resources. Ordinary `cleanup()`/reconfiguration frees named engine textures while retaining the SDK handle; the wrapper updates its configuration on subsequent evaluation. Simply selecting another upscaler need not immediately free all cached SDK state.

Quality is derived from scale; `quality_from_scale` holds thresholds. Presets are applied to all SDK quality slots and resent when configuration changes. The displayed preset is the requested value or SDK-documented default, not model readback. The default lets the runtime choose.

The optional reactive mask copies color alpha into a separate `R8_UNORM` image. An alias/view of the color image is unsafe because native resource tagging identifies the underlying image. Keep it off by default and test transparency independently; a compile or shutdown test does not validate its visual behavior.

## Frame generation and presentation

The integration requests the frame-generation plugin only in game mode (`!is_editor_hint()`); a game launched by the editor qualifies. It requires a single-view presented render target, supported SDK features and an actual velocity buffer. Reflection probes and editor UI renders are excluded. This Vulkan path supports fixed two-times presentation, not multi-frame generation.

The renderer captures a dedicated HUD-less texture before canvas composition and tags depth/motion/camera data for the same frame. It does not supply a separate UI alpha layer. Preserve the copy's lifetime through presentation; tagging a render target later overwritten by HUD composition changes the SDK's input.

Frame-token creation and Reflex markers are coordinated in the rendering server around simulation/render submission/presentation. Do not move SDK token access independently of evaluation callbacks or duplicate tokens per viewport. Multiwindow behavior and particular HUD compositions require their own visual validation; the single-view eligibility gate is not proof that every presentation arrangement is correct.

## Shutdown and local-device safety

The latest fix is an ordering and ownership contract, not an exception suppression:

1. After successful `slInit`, remember initialized state. Bind the first owning Vulkan logical device immediately after creation, before later feature checks can fail.
2. Create additional local RenderingDevices using the native system Vulkan loader, bypassing Streamline's `vkCreateDevice` proxy. Otherwise its process-global dispatch table can be rebound to a temporary local device.
3. During `RenderingDevice::finalize`, drain Godot frame/worker work, then invoke `driver->prepare_for_shutdown()` **before** freeing dependent GPU resources or destroying the device.
4. Only the SDK-owning device calls `_shutdown`. Latch `shutdown_attempted` before SDK calls; disable ready/Reflex state and clear the active token.
5. Wait for device idle while SDK hooks and Vulkan objects are still alive. Release remaining SR/FG viewport resources and owned HUD-less textures, then call `slShutdown`.
6. Log SDK failures without retrying partially destroyed plugins. Keep Vulkan entry points/DLLs alive through device/instance destruction; unload the interposer only afterward. Retain fallback cleanup for partial startup/no-device paths.

A local device's destruction must not shut down the main SDK. Repeated teardown must be inert. A failure return from `slShutdown` is not authorization to call it again. Do not solve this by disabling FG, leaking the instance or moving all cleanup to a destructor after Vulkan is gone.

## Rebuild and validation

Port in dependency order: SDK facade/loader and device lifecycle; RenderingDevice external callbacks; viewport controls and fallback; SR/motion conventions; frame tokens/Reflex; FG capture/tag/presentation. Carry the cleanup protections from the start. Check shader build registration for `dlss_reactive.glsl` and motion-prefill shaders, plus scripting/editor status bindings and settings metadata.

Validation requires permission to run the engine. Cover runtime disabled/missing/unsupported, SR and DLAA, fallback, odd internal extents, moving geometry, camera motion, resize, viewport destruction/recreation and mode changes. Test FG off/on with HUDs separately. Check normal exit, partial initialization, repeated cleanup and creation/readback/destruction of a local RenderingDevice while main-viewport DLSS continues.

The shutdown fix's recorded validation included SDK success/failure cleanup mocks and RTX 5090 editor/game exits, including a live local-device test. That evidence supports its tested cases, not all future SDK versions or presentation configurations. Use the current validation records for reproduction details and rerun after porting; do not treat CUDA/NGX's presence in an old stack as proof of which component owns a new failure.
