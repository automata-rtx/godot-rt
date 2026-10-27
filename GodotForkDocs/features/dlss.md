# DLSS and Streamline

The fork integrates DLSS Super Resolution, DLAA and optional frame generation through NVIDIA Streamline. Super resolution reconstructs a larger image from a smaller 3D render; frame generation inserts presented frames and does not increase game simulation speed.

## Setup

Use a Windows build with Forward+ and **Vulkan** (`rendering/rendering_device/driver.windows = "vulkan"`), supported NVIDIA hardware/drivers, and NVIDIA-signed runtime binaries. This integration does not run through D3D12. The repository includes Streamline headers, not runtime DLLs.

Put matching runtime files next to the editor/game executable, or set `rendering/streamline/binary_path`:

| Feature | Runtime files |
| --- | --- |
| Common | `sl.interposer.dll`, `sl.common.dll` |
| Super resolution / DLAA | `sl.dlss.dll`, `nvngx_dlss.dll` |
| Frame generation | `sl.dlss_g.dll`, `nvngx_dlssg.dll` |
| Reflex, used by frame generation | `sl.reflex.dll`, `sl.pcl.dll` |

Enable `rendering/streamline/enabled` and restart. Select `Viewport.SCALING_3D_MODE_DLSS` and set `scaling_3d_scale`. Useful target scales are `1.0` (DLAA), about `0.667` (Quality), `0.58` (Balanced), `0.5` (Performance) and `0.333` (Ultra Performance). The wrapper chooses quality by scale thresholds; arbitrary scales do not create additional SDK modes.

## Settings and runtime controls

| Setting | Shipped default | Applied |
| --- | --- | --- |
| `rendering/streamline/enabled` | `false` | Restart |
| `rendering/streamline/binary_path` | Empty: executable directory | Restart |
| `rendering/streamline/project_id` | Empty: engine fallback GUID | Startup |
| `rendering/streamline/verbose_logging` | `false` | Restart |
| `rendering/streamline/frame_generation` | `false` | Live |
| `rendering/streamline/reactive_mask` | `false` | Live; experimental alpha-derived hint |
| `rendering/anti_aliasing/quality/dlss_preset` | `0` (Default) | Live: Default/J/K/L/M |

Project `rendering/scaling_3d/mode` and `/scale` seed viewport properties; change the **viewport properties** for an in-game overlay. A temporal upscaler provides its own anti-aliasing, so the effective viewport disables separate TAA. This is not a universal ban on TAA or MSAA elsewhere.

Keep preset Default and reactive mask off initially. A forced preset is an SDK request, not verified readback of the model NVIDIA ultimately runs. Driver/NVIDIA App overrides can affect selection.

For an overlay, query `RenderingServer.viewport_get_effective_scaling_3d_mode(viewport_rid)`, `viewport_get_internal_size(viewport_rid)` and `viewport_get_upscaler_status(viewport_rid)`. Requested DLSS can fall back to FSR2 when unavailable; one-shot/non-updating temporal viewports can fall back to bilinear. Report the effective mode rather than assuming the requested option is active.

## Frame generation and testing

Frame generation requires an eligible presented, single-view game viewport and motion vectors, normally supplied by DLSS or FSR2. It is excluded from editor UI rendering, but a game launched from the editor is eligible; an exported executable is not required. Vulkan exposes fixed 2× generation, not multi-frame generation. Super resolution and frame generation availability are checked separately.

Compare image quality and base frame time with frame generation off first. Check camera motion, moving objects, foliage, transparent effects and HUD edges. Camera-cut accumulation reset is not currently wired for DLSS. The reactive mask is not a general transparency fix. Separate UI alpha is not supplied to frame generation: verify your HUD rather than assuming artifact-free composition.

Startup output reports loaded directory, runtime version and feature support. Unavailability warnings explain the driver, binaries or feature failure; SDK logging goes to `sl.log` in user data. Include these and effective viewport mode in bug reports.

The shutdown fix explicitly releases Streamline before Vulkan destruction and protects separate local RenderingDevices. Engine rebuild/cleanup contracts: `docs/internals/dlss.md` in the fork repository.
