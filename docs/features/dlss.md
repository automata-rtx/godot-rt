# DLSS (NVIDIA Streamline)

Running DLSS in this fork: prerequisites, settings, super resolution, model presets, frame
generation, costs, verified status. Not here: the interposer, resource tagging and the motion
vector/depth conventions (`docs/internals/dlss.md`); symptoms (`docs/TROUBLESHOOTING.md`); the
reactive-mask failure and the alignment defect as incidents (`docs/HISTORY.md`); re-applying it
(`docs/PORTING.md`).

## Read this first: why DLSS reports itself unavailable

Almost every report is one of these, in this order. Check them before reading any message.

| # | Cause | Detail |
| --- | --- | --- |
| 1 | On the D3D12 rendering driver | `rendering/rendering_device/driver.windows` must be `"vulkan"`. Streamline is loaded from the Vulkan *context* driver, so on D3D12 none of it runs and no Streamline setting changes that. The editor writes `"d3d12"` into every project it creates (`editor/editor_node.cpp:8435`), which makes this the common case. |
| 2 | `rendering/streamline/enabled` off | Ships `false`, **restart-required** (`GLOBAL_DEF_RST_BASIC`, `core/config/project_settings.cpp:1970`), because enabling it replaces the process's Vulkan entry-point loader. |
| 3 | Not Windows | `STREAMLINE_ENABLED` needs `VULKAN_ENABLED` and `WINDOWS_ENABLED` both (`drivers/vulkan/streamline_vk.h:33-36`). Everywhere else the integration compiles to nothing. |
| 4 | Binaries not there | No SDK binaries are vendored — only headers, under `thirdparty/streamline/`. |
| 5 | Binaries there but not NVIDIA's | Refused unless the OS trusts the Authenticode signature *and* the signer is NVIDIA Corporation (`drivers/vulkan/streamline_vk.cpp:575-579`), because a hostile `sl.interposer.dll` next to the executable would otherwise take over the Vulkan loader for the whole process. **A self-built Streamline will not load.** |
| — | Looks the same: super resolution needs Forward+ | On Mobile or Compatibility the set warns and is rejected outright (`renderer_viewport.cpp:1103-1105`). |
| — | Looks the same: every DLSS feature unavailable while Reflex IS available | Not the files and not the GPU: NGX is declining to initialize for want of an identity. `slInit` is handed `rendering/streamline/project_id`, or a GUID built into the engine when that is empty, and the fallback is load-bearing — NGX accepts either an application id NVIDIA issued for the title or a project GUID paired with an engine name and version, and given neither it turns itself off. `slInit` still succeeds, the interposer still loads, and then every NGX-backed feature (which is every DLSS feature) reports `eErrorFeatureNotSupported` while Reflex keeps working, because Reflex runs through NVAPI instead. Set the project id to the GUID NVIDIA issues you if you have one; that is what selects the per-title tuning they ship over the air. |

## Getting it running

1. Download a release from <https://github.com/NVIDIA-RTX/Streamline/releases> (the frame generation
   plugin is closed source) and put the binaries in one directory — next to the executable is the
   default, and where an exported game's own libraries land. **Each DLSS feature needs two files,
   not one**: the Streamline plugin, and separately the NGX model that does the work.

   | For | Files |
   | --- | --- |
   | Always | `sl.interposer.dll`, `sl.common.dll` |
   | Super resolution | `sl.dlss.dll`, `nvngx_dlss.dll` |
   | Frame generation | `sl.dlss_g.dll`, `nvngx_dlssg.dll` |
   | Reflex (pulled in by frame generation) | `sl.reflex.dll`, `sl.pcl.dll` |

   The `nvngx_*.dll` files sit apart from the `sl.*.dll` ones in the SDK tree, and releases carry a
   production and a `development/` copy of each. **Copying only the `sl.*.dll` files leaves Reflex
   working and DLSS reporting itself unavailable** — the most confusing way to get this wrong.
2. Set `rendering/rendering_device/driver.windows` to `"vulkan"`, turn on
   `rendering/streamline/enabled`, and **restart** — pointing `rendering/streamline/binary_path` at
   that directory first if it is not the executable's. Then: super resolution = viewport 3D scaling
   mode **DLSS** at the 3D scale wanted; frame generation = `rendering/streamline/frame_generation`.

### What startup prints

Normal severity, in the editor's Output panel and the debugger — no `--verbose`, no flag.

| Line, in order | Source |
| --- | --- |
| the directory it resolved, plus the engine build hash | `streamline_vk.cpp:533` |
| `Streamline <major>.<minor>.<patch> initialized.` once `slInit` succeeds | `streamline_vk.cpp:689` |
| the features the adapter actually supports, once the graphics device exists | `streamline_vk.cpp:805` |

- On failure, each of a missing interposer, a rejected signature, a failed `slInit` and an
  unsupported feature prints a message naming the cause. An unavailable feature is named with its
  result code — the only thing separating "this GPU cannot" from "the plugin DLL is missing" — and
  where the code blames the files the message also names the two DLLs and the directory.
- `rendering/streamline/verbose_logging` raises Streamline's **own** log level, and only after
  `slInit` succeeds: it diagnoses a feature that loaded and then misbehaved, not one that never
  loaded. That log is `sl.log`, in the user data directory, warnings and errors by default.

## Settings

| Setting | Default | When read |
| --- | --- | --- |
| `rendering/streamline/enabled` | `false` | **restart** |
| `rendering/streamline/binary_path` | `""` (executable's directory) | **restart** |
| `rendering/streamline/project_id` | `""` (engine GUID) | **restart** |
| `rendering/streamline/verbose_logging` | `false` | **restart** |
| `rendering/streamline/frame_generation` | `false` | every frame |
| `rendering/streamline/reactive_mask` | `false` | every frame |
| `rendering/anti_aliasing/quality/dlss_preset` | `Default` (`0`) | every frame |
| `rendering/scaling_3d/mode` | Bilinear (`0`); DLSS is `6` = `Viewport.SCALING_3D_MODE_DLSS`, "DLSS (Slow)" in the inspector | project start |
| `rendering/scaling_3d/scale` | `1.0` | project start |

Verified against `core/config/project_settings.cpp:1966-1998` and
`servers/rendering/rendering_server.cpp:3835-3847`.

- Per viewport, `rendering/scaling_3d/mode` and `/scale` seed `Viewport.scaling_3d_mode` and
  `Viewport.scaling_3d_scale`, both settable at run time.
- `rendering/scaling_3d/mode` lists DLSS on **every** platform, not behind a `.windows` override: a
  dotted setting registers a feature override `GLOBAL_GET` resolves *before* the base value, so a
  `.windows` variant would pin it to its own default on Windows and discard what the project set
  (`rendering_server.cpp:3830-3836`). Off Windows it costs an option that falls back to FSR 2.

## Super resolution

| Behavior | Detail |
| --- | --- |
| The mode | `VIEWPORT_SCALING_3D_MODE_DLSS`, beside FSR 2 and MetalFX Temporal. |
| Inputs and output | The internal color, depth and velocity buffers, plus the auto-exposure buffer when the camera has auto exposure on; without it DLSS estimates exposure itself (`render_forward_clustered.cpp:3123-3126`). Output is the upscaled color buffer the engine already allocates for FSR 2. |
| **Falls back to FSR 2 wherever DLSS cannot run**, silently as far as the image is concerned | `renderer_viewport.cpp:187-207`. A warning names which half failed: wrong rendering driver, or the recorded unavailability reason. |
| **DLSS and TAA are mutually exclusive** | Any temporal scaling mode turns TAA off internally with a warning (`renderer_viewport.cpp:286-291`). This project never uses TAA; see `CLAUDE.md`. |
| **A viewport that draws once or never falls back to bilinear**, not to FSR 2 | A temporal upscaler on absent history invents pixels along every silhouette. Update modes `ONCE` and `DISABLED` (`renderer_viewport.cpp:147-149`, warning at `:220-229`). Every bake viewport takes this. |
| **Alpha is upscaled only on a transparent-background render target** | `render_forward_clustered.cpp:3179`, `streamline_vk.cpp:1099`. NVIDIA documents alpha upscaling as costing performance, so it is asked for only where the alpha is read. |
| **No way to reset the accumulation** | `reset_accumulation` is hard-coded `false` (`render_forward_clustered.cpp:3177`, marked FIXME), so a camera cut or teleport cannot tell DLSS to drop its history. |
| **Switching a viewport away from DLSS at run time leaks its Streamline resources** | Until the render buffers are destroyed: `super_resolution_release` is reached only from their destructor (`render_scene_buffers_rd.cpp:66`), and `configure()` rebuilds the same object. |

**3D scale picks the quality mode.** The scale keeps driving the internal size and also selects the
mode nearest it, with thresholds halfway between the modes' own scale factors
(`drivers/vulkan/streamline_vk.cpp:965-977`).

| 3D scale | Quality mode | Mode's own scale |
| --- | --- | --- |
| >= 0.834 | DLAA (native resolution) | 1.0 |
| >= 0.624 | Quality | 0.667 |
| >= 0.539 | Balanced | 0.58 |
| >= 0.417 | Performance | 0.5 |
| below | Ultra Performance | 0.333 |

**Nothing validates the render extent against the mode's range.** `slDLSSGetOptimalSettings`
(`renderWidthMin`/`renderWidthMax` per mode) is never resolved or called: the mode comes from the 3D
scale, the render size is computed independently. Clean at the tested 0.67; other scales untested.

## Model presets

`rendering/anti_aliasing/quality/dlss_preset` forces a DL model instead of letting the runtime
choose. Read every frame, so no restart, and **applied to every quality mode at once**, because the
mode follows the viewport's 3D scale and so moves under the project's feet. Offered: **Default, J,
K, L, M**; of the SDK's sixteen slots, A-D were removed, E and F are deprecated, and G, H, I, N, O
are all documented as reverting to default.

**Which model is running cannot be read back**: `sl::DLSSState` carries only
`estimatedVRAMUsageInBytes`, every NGX preset parameter is a write-only **hint**
(`DLSS.Hint.Render.Preset.*`), and `sl.dlss`'s debug HUD prints quality mode, viewport, runtime and
VRAM but no preset letter — the plugin does not know it either. So on **Default** the overlay gives
the preset the SDK's own header documents for the quality mode, labeled as such, because the header
warns the choice "may or may not change after an OTA" (`streamline_vk.cpp:334-346`): **K** for DLAA,
Quality and Balanced, **M** for Performance, **L** for Ultra Performance. Force a preset and the
overlay reports it plainly — exactly what was handed to the runtime.

**The authoritative answer is NVIDIA's on-screen DLSS indicator**, drawn into the upscaled image
from inside `nvngx_dlss.dll`, where the choice is made. Machine-wide registry switch, no API behind
it: `HKLM\SOFTWARE\NVIDIA Corporation\Global\NGXCore\ShowDlssIndicator`, flipped by the SDK's
own `scripts/ngx_driver_onscreenindicator.reg` (and the `_off` variant). Writing it needs elevation,
reading it does not, so the overlay reads it and defers to the letter on screen when the indicator
is on (`streamline_vk.cpp:348-380`, `:1018-1035`).

## Seeing what actually ran

**View -> View Information** in the 3D viewport gains two lines whenever DLSS is the upscaler that
actually ran (`editor/scene/3d/node_3d_editor_viewport.cpp:3738-3748`): internal size, output size
and percentage, then the quality mode and preset. They and the `Size:` line above come from
`viewport_get_internal_size`, not the viewport size times its 3D scale, and the mode from
`viewport_get_effective_scaling_3d_mode` — what the renderer **did**, not what it was asked to do,
because a DLSS request lands on FSR 2 wherever DLSS cannot run. Bound, so usable from GDScript
(`servers/rendering/rendering_server.cpp:2918-2920`):

| Method | Returns |
| --- | --- |
| `viewport_get_internal_size(viewport)` | the size the 3D scene was actually rendered at |
| `viewport_get_effective_scaling_3d_mode(viewport)` | the mode that ran, after every fallback |
| `viewport_get_upscaler_status(viewport)` | e.g. `"Quality, preset K (documented default)"`, empty when DLSS did not run |

## The reactive mask

`rendering/streamline/reactive_mask`, off by default, live (read every frame). Godot builds a
reactive mask every frame an upscaler runs and hands it to FSR 2; DLSS is not handed one unless this
is on, so **alpha-blended surfaces ghost worse under DLSS than under FSR 2 at the same scale.**

| | |
| --- | --- |
| What it costs | `effects/dlss_reactive.glsl` copies the color buffer's alpha into an `R8_UNORM` texture of its own at the internal size, and that texture carries the tag. One full-screen single-channel copy per frame. |
| Status | **Never run on hardware**, and nothing in this repository can exercise it — the Streamline driver files compile to empty objects off Windows and CI runs nothing that reaches them (`docs/VALIDATION.md`). |
| Do not re-attempt | An earlier attempt **blacked out every opaque pixel** on hardware by tagging a view instead of a texture of its own; the mechanism and the rule it established are in `docs/internals/dlss.md` section 4, the incident in `docs/HISTORY.md`. |
| Trying it | Turn it on with super resolution running and watch an alpha-blended surface cross the frame. Success is that surface holding its edge instead of dragging a trail. If anything happens to **opaque** pixels, turn it straight back off. |

## Frame generation

`rendering/streamline/frame_generation`: one switch for the whole application, not per viewport,
because it takes over the swap chain. Needs everything in the failure ladder above, plus:

| Requirement | Detail |
| --- | --- |
| **Motion vectors** | A temporal upscaler or TAA must be running on the viewport (`renderer_scene_render_rd.cpp:1556-1560`). This project never uses TAA, and SMAA leaves no velocity buffer at all, so **super resolution is the only thing that fills it** — frame generation is reachable only while DLSS super resolution (or FSR 2) is running. |
| **Reflex** | Switched on for the process as soon as the device exists (`streamline_vk.cpp:824-836`). Frame generation reports `eFailReflexNotDetectedAtRuntime` and stops presenting interpolated frames without it. |
| An RTX 40 series GPU or newer | Per the class reference (`doc/classes/ProjectSettings.xml:3619`). |

**It refuses rather than half-applies**, in five cases (`renderer_scene_render_rd.cpp:1541-1560`):

| Refusal | Why |
| --- | --- |
| In the editor | The presented image is the editor's own interface, and `sl.dlss_g` is not even loaded there because its `vkCreateSwapchainKHR` hook would blank every editor popup — `docs/internals/dlss.md` section 2. Running a project *from* the editor is a separate process, unaffected. |
| Without motion vectors | Interpolation is driven by them. Warns once, naming the fix. |
| In stereo | No single presented image to interpolate. |
| On a viewport no window presents | A `SubViewport`'s image never reaches the swap chain. Every `SubViewport` in a project takes this path. |
| On a reflection probe render | Not a presented frame. |

| Constraint | Detail |
| --- | --- |
| **Fixed 2x only** | Dynamic multi-frame generation is D3D12-only in this SDK, so `DLSSGMode::eDynamic` would silently do nothing on Vulkan. |
| **A game presenting more than one window is unhandled** | `RenderingDeviceDriverVulkan` batches every window's swapchain into a single `vkQueuePresentKHR`, so there is no per-window native/proxy split to route around it. |
| **V-Sync with frame generation is D3D12-only** | Streamline cannot pace generated frames against vertical sync on Vulkan; force it from the driver control panel (NVIDIA Control Panel -> Manage 3D settings -> Vertical sync -> On). |
| **UI alpha is not provided — the largest known gap** | Frame generation gets the presented image without the interface drawn over it (the "hudless" copy). Streamline also accepts a UI Color and Alpha buffer, which would let it recompose the interface, but Godot draws canvas straight onto the same render target as the 3D image and has no separate interface target to hand over. **A moving interface element smears across generated frames.** `docs/internals/dlss.md` section 7. |
| **Testing it needs an exported game** | It never runs in the editor: export against this fork's own `windows-template` CI artifact as a custom release template (`docs/VALIDATION.md`). Refusals arrive as a status bitfield rather than a failed call, read back each frame and reported once in words (`streamline_vk.cpp:267-291`, `:1364-1366`); the common ones are Reflex not running and the output resolution being too low. |

## Costs

Unmeasured; no timing harness here reaches Streamline (`docs/VALIDATION.md`). What it allocates:

| | Engine-side allocation | Per frame |
| --- | --- | --- |
| Super resolution | nothing beyond what FSR 2 already needs | — |
| with the reactive mask on | one `R8_UNORM` texture at the internal size | one full-screen single-channel copy |
| Frame generation | one full-resolution color texture per running viewport, only while it runs | one full-resolution copy |
| not counted | Streamline's own history, interpolation resources and optical flow surface, allocated under the viewport handle | — |
| Streamline off | none — the singleton does not exist and every entry point is behind a null check | none |

## What DLSS changes about the rest of the fork

- Every fork pass dispatches from `get_internal_size()`, so the contact shadow's march length,
  `denoiser/min_filter_pixels` and `MAX_PENUMBRA_PIXELS` are in internal pixels and reach a
  different distance across the output image (`docs/internals/dlss.md` section 9).
- DLSS is the only feature that makes the render size arbitrary, so it is what exposes a latent
  size-alignment assumption; Godot truncates the internal size, so check a new pass against an
  awkward size (`CLAUDE.md`). One defect was found this way
  (`docs/internals/ambient-occlusion.md`, `docs/HISTORY.md`).

## Verified status

| | Status |
| --- | --- |
| **DLSS super resolution** | **Works.** Observed on hardware: RTX 5090, Vulkan, fullscreen, 3440x1440, 3D scale 0.67 (DLSS Quality). Opaque geometry clean — no ghosting, no smearing under motion, no shimmer at rest. |
| Transparency under super resolution | **Failed in that same run**: world-space label text ghosted badly. Two fixes were written afterward — the billboard previous-camera fix and the reactive mask — and **neither has been back on the machine**. |
| **The reactive mask** | Implemented, ships off, **never run on hardware.** |
| **Frame generation** | Implemented, **never run on hardware.** |
| The conventions super resolution rides on | **Confirmed by that run**, because each fails visibly and differently: motion vector sign and `mvecScale` smear under motion, the `clipToPrevClip` transpose ghosts with the camera still, the jitter sign reads as softness, bad resource tags give black. None were present. **Do not describe them as unverified**; they are in `docs/internals/dlss.md` section 5. |

## XeSS is not available

Streamline 2.12.0 (`thirdparty/streamline/include/sl_version.h:24-26`) does not ship XeSS: no
`sl.xess` plugin in the source tree, and neither `include/` nor the programming guides mention it.
Streamline's own cross-vendor path is DirectSR, which is D3D12-only and which NVIDIA's guide advises
against on RTX hardware. Adding XeSS means integrating Intel's SDK directly (`libxess.dll`,
`xess_vk.h`), **not** adding a Streamline feature id. The shape the fork grew for DLSS is reusable
as is — a new `VIEWPORT_SCALING_3D_MODE_*` value, an effect class beside `DLSSEffect` working inside
a `driver_callback_add()`, and the same fallback rule in `renderer_viewport.cpp`
(`docs/internals/dlss.md`).
