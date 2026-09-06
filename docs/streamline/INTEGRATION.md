# NVIDIA Streamline in this fork

DLSS super resolution and DLSS frame generation, on Vulkan, on Windows. This is the current
description of what the engine does; `EVALUATION.md` beside it is the design note that preceded
it and is now historical.

**No DLSS frame has been produced on hardware yet.** The load path is confirmed on an RTX 5090
running Vulkan: the interposer loads, its signature is accepted, `slInit` succeeds and Reflex
reports itself available. Past that, every claim below is read out of the Streamline SDK's headers
and guides or out of this engine's own code — whether DLSS produces a correct image, and whether
the constants handed to it are right in sign and scale, is unverified. Section 8 lists the specific
things to check first.

---

## 1. Getting it running

1. Download a release from <https://github.com/NVIDIA-RTX/Streamline/releases>. The engine
   vendors the SDK's headers but none of its binaries: the frame generation plugin is closed
   source, and the rest is loaded at run time.
2. Put the binaries in one directory. Next to the executable is the default and is where an
   exported game's own libraries end up. **Each DLSS feature needs two files, not one** — the
   Streamline plugin and, separately, the NGX model that does the work:

   | For | Files |
   | --- | --- |
   | Always | `sl.interposer.dll`, `sl.common.dll` |
   | Super resolution | `sl.dlss.dll`, `nvngx_dlss.dll` |
   | Frame generation | `sl.dlss_g.dll`, `nvngx_dlssg.dll` |
   | Reflex (pulled in by frame generation) | `sl.reflex.dll`, `sl.pcl.dll` |

   The `nvngx_*.dll` files live apart from the `sl.*.dll` ones in the SDK tree, and releases carry
   both a production and a `development/` copy of each. Copying only the `sl.*.dll` files leaves
   Reflex working and DLSS reporting itself unavailable, which is the most confusing way to get
   this wrong.
3. Make sure the project is on the **Vulkan** rendering driver:
   `rendering/rendering_device/driver.windows` must be `"vulkan"`. This is worth checking rather
   than assuming — the editor writes `"d3d12"` into every project it creates, and Streamline is
   loaded from the Vulkan context driver, so on D3D12 none of it runs and no amount of enabling
   will change that.
4. Turn on `rendering/streamline/enabled` and restart. If the binaries are elsewhere, point
   `rendering/streamline/binary_path` at the directory first.
5. For super resolution, set the viewport's 3D scaling mode to **DLSS** and its 3D scale to the
   quality you want. For frame generation, turn on `rendering/streamline/frame_generation`.

Startup reports what happened in the editor's Output panel and the debugger, at normal severity —
no `--verbose` and no command line needed. Expect three things in order: the directory it resolved,
a line confirming the version once `slInit` succeeds, and the list of features the adapter actually
supports once the graphics device exists. A missing interposer, a rejected signature, a failed
`slInit` and an unsupported feature each print their own message naming the cause.

`rendering/streamline/verbose_logging` raises Streamline's *own* log level, which only takes effect
after `slInit` succeeds. It is for diagnosing a feature that loaded and then misbehaved, not for
finding out why nothing loaded.

Streamline is handed an identity at `slInit`: `rendering/streamline/project_id`, or a GUID built
into the engine when that setting is empty. The fallback is not decoration. NGX accepts either an
application id NVIDIA issued for the title or a project GUID paired with an engine name and
version, and given neither it turns itself off — `slInit` still succeeds, the interposer still
loads, and then every NGX-backed feature, which is every DLSS feature, reports
`eErrorFeatureNotSupported`, while Reflex goes on working because it runs through NVAPI instead.
Set the project id to the GUID NVIDIA issues you if you have one; that is what selects the
per-title tuning they ship over the air.

The interposer is refused unless the operating system trusts its Authenticode signature *and*
the signer is NVIDIA Corporation. Without that check, dropping a hostile `sl.interposer.dll`
next to the executable would be enough to take over the Vulkan loader for the whole process. A
self-built Streamline will therefore not load; use NVIDIA's binaries.

## 2. How it attaches

Streamline is loaded before volk, and volk is then initialized with the `vkGetInstanceProcAddr`
the interposer exports rather than the Vulkan loader's. Everything the engine resolves after that
comes from Streamline where Streamline wants it — the entry points listed in `sl_hooks.h`,
which include `vkCreateInstance`, `vkCreateDevice`, `vkCreateSwapchainKHR`,
`vkAcquireNextImageKHR` and `vkQueuePresentKHR` — and from the Vulkan loader for everything
else. No call site in the engine changes. This is NVIDIA's "manual hooking" route for Vulkan, and
it is what lets frame generation own the swap chain.

Taking the create-instance and create-device proxies also hands Streamline the job of adding the
instance extensions, device extensions, Vulkan 1.2/1.3 feature bits and extra queues its features
need. That is why none of that is duplicated in the engine and why `slSetVulkanInfo` is never
called.

If any step fails — the setting is off, the DLL is missing, the signature is wrong, `slInit`
refuses — the singleton is never created, `volkInitialize()` runs as before, and every feature
below reports itself unavailable. There is no half-loaded state.

**Seams, for a future rebase:**

| File | What was added |
| --- | --- |
| `drivers/vulkan/streamline_vk.h/.cpp` | The whole runtime wrapper. Everything Streamline- or Vulkan-specific lives here. |
| `drivers/vulkan/rendering_context_driver_vulkan.cpp` | `volkInitializeCustom()` with the interposer's proc address; `StreamlineVK::finalize()` in the destructor. |
| `drivers/vulkan/rendering_device_driver_vulkan.cpp/.h` | `set_physical_device()` once the device exists; `command_buffer_get_vulkan_handle()`. |
| `servers/rendering/renderer_rd/effects/dlss.h/.cpp` | Super resolution and frame generation as renderer-side effects. |
| `servers/rendering/rendering_server_default.cpp` | Frame token and latency markers around the render frame. |
| `servers/rendering/renderer_rd/renderer_scene_render_rd.cpp` | Frame generation's per-frame update, including the hudless copy. |
| `servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.h/.cpp` | The per-viewport Streamline handle and its release. |
| `servers/rendering/renderer_viewport.cpp/.h` | The DLSS fallback rule and `is_render_target_presented()`. |
| `platform/windows/detect.py` | `wintrust` on the link line, for the signature check. |

Nothing in `streamline_vk.h` names a Vulkan or Streamline type: native handles cross as
`uint64_t`, the way `RenderingDevice::get_driver_resource()` already hands them out. That is what
keeps the renderer side free of both include paths.

## 3. Super resolution

`VIEWPORT_SCALING_3D_MODE_DLSS` sits beside FSR2 and MetalFX Temporal and falls back to FSR 2
wherever Streamline is off, missing, or the GPU cannot run DLSS.

Unlike the other upscalers the work is not recorded by the engine: Streamline is handed the raw
command buffer and records its own passes into it. `RenderingDevice::driver_callback_add()` is
exactly that seam — it hands over the command buffer at a point where the render graph has
already put every resource named alongside it into a known layout, which is also what the
resource tags report to Streamline as each image's state.

The viewport's 3D scale keeps driving the internal size and additionally picks the quality
preset nearest that scale:

| Scale | Preset |
| --- | --- |
| ≥ 0.834 | DLAA (native resolution) |
| ≥ 0.624 | Quality (0.667) |
| ≥ 0.539 | Balanced (0.58) |
| ≥ 0.417 | Performance (0.5) |
| below | Ultra Performance (0.333) |

Inputs are the internal colour, depth and velocity buffers, plus the auto-exposure buffer when
the camera has auto exposure on; without it DLSS estimates exposure itself. The output is the
upscaled colour buffer the engine already allocates for FSR2.

## 4. Frame generation

One switch for the whole application, not a per-viewport setting, because it takes over the swap
chain. It runs nowhere in the frame the engine records: the interpolation happens inside the
present hook the interposer installed, long after the command buffer has been submitted. All the
engine does is hand Streamline the inputs it will read there, tagged as valid until present.

A fixed 2x multiplier. Dynamic multi-frame generation is deliberately not used: it is D3D12-only
in this SDK, so `DLSSGMode::eDynamic` would silently do nothing on Vulkan.

Reflex is switched on for the process as soon as the device exists, because frame generation
reports `eFailReflexNotDetectedAtRuntime` and stops presenting interpolated frames without it.
Its latency markers are emitted around the render frame.

It refuses rather than half-applies in four cases:

- **In the editor.** The presented image there is the editor's own interface. Running a project
  from the editor is a separate process, so an embedded game window is not affected.
- **Without motion vectors.** Interpolation is driven by them, and the engine only fills the
  velocity buffer for a viewport running a temporal upscaler or TAA. Pair frame generation with
  DLSS or FSR 2 scaling. A warning says so once.
- **In stereo.** There is no single presented image to interpolate.
- **On a viewport no window presents.** A SubViewport's image never reaches the swap chain.

### V-Sync

Streamline cannot pace generated frames against vertical sync on Vulkan — that path is
D3D12-only. Force V-Sync from the graphics driver's control panel instead (NVIDIA Control Panel →
Manage 3D settings → Vertical sync → On) for a tear-free result.

### The hudless copy

Frame generation needs the presented image without the interface drawn over it, because it
interpolates the two neighboring frames and interpolated UI is the artifact people notice
first.

The copy is taken at the one moment that image exists: the scene renderer has just tone-mapped
into the render target, and the canvas has not been drawn over it yet. Both the copy and the
texture it lands in are created only while frame generation is actually running on that viewport,
and freed again the moment it stops — so a project that leaves the feature off never allocates
the texture and never pays for the copy.

**UI alpha is not provided.** Streamline also accepts a UI Color and Alpha or a UI Alpha buffer,
which lets it recompose the interface over the generated frame rather than leaving the previous
frame's interface in place. Godot draws canvas straight onto the same render target as the 3D
image and has no separate interface target to hand over, so producing one would mean a second
canvas pass into its own buffer. Without it, a moving interface element will smear across
generated frames. This is the largest known gap.

## 5. Motion vector and depth conventions

These are derived from the engine's own code rather than measured, and are the most likely place
for a sign or scale error:

- **Motion vectors** are written as `prev_position_uv - position_uv` with the jitter subtracted
  from both endpoints, so a displacement across the whole screen is 1.0. That is the same unit a
  pixel-space buffer reaches after being divided by the render size, which is what Streamline
  calls normalized, so `mvecScale` is `{1, 1}` and `motionVectorsJittered` is false.
- **Depth** is reverse-Z, so `depthInverted` is true.
- **Camera motion** is included in the motion vectors, so `cameraMotionIncluded` is true.
- **Matrices** cross as a straight copy. Godot stores columns and multiplies as `M * v`;
  Streamline stores rows and multiplies as `v * M`. Those are transposes of each other in both
  convention and storage, and the two cancel.
- **Jitter** is handed over in pixels, the same expression FSR2 is given.

## 6. XeSS

Streamline 2.12.0 does not ship XeSS. There is no `sl.xess` plugin in the source tree, and
neither `include/` nor the programming guides mention it — unlike frame generation, which has no
source plugin either but does ship `sl_dlss_g.h` and its own guide. The cross-vendor path inside
Streamline is DirectSR, which is D3D12-only and which NVIDIA's own guide advises against on RTX
hardware.

Adding XeSS therefore means integrating Intel's SDK directly (`libxess.dll` and `xess_vk.h`),
not adding a Streamline feature id. The shape is already there for it: a new
`VIEWPORT_SCALING_3D_MODE_*` value after DLSS, an effect class beside `DLSSEffect` that does its
work inside a `driver_callback_add()`, and the same fallback rule in `renderer_viewport.cpp`.
Everything the engine had to grow to make one external upscaler possible — raw command buffer
access, native image handles with their layouts and usage flags, a stable per-viewport handle --
is reusable as is.

## 7. Costs

- Super resolution: no engine-side allocation beyond what FSR2 already needs. Streamline
  allocates its own history under the viewport handle.
- Frame generation: one full-resolution colour texture per running viewport, and one
  full-resolution copy per frame, both only while it runs. Streamline allocates the
  interpolation resources and an optical flow surface of its own.
- Neither costs anything when Streamline is off: the singleton does not exist, and every entry
  point is behind a null check.

## 8. What to check first on hardware

In roughly the order a failure would be easiest to diagnose:

1. **It loads.** Startup prints the directory it resolved and then confirms the version. If it
   prints neither, the setting is off or was changed without a restart; if it names a directory and
   then errors, the message says whether the file was missing, unsigned, or rejected by `slInit`.
2. **Feature support.** Once the device exists, startup lists the available features and warns
   individually about each unavailable one with the result code, which is what separates "this GPU
   cannot" from "the plugin DLL is missing". Every DLSS feature unavailable *while Reflex is
   available* is a third thing again: that pattern is NGX declining to initialize, so look at the
   identity in section 1 before the files.
3. **Super resolution produces an image at all.** A black or garbage output points at the
   resource tags — format, layout, extent — before it points at the constants.
4. **Ghosting or smearing under camera motion** points at the motion vectors: first the sign of
   each axis, then `mvecScale`.
5. **Ghosting that survives a still camera** points at `clipToPrevClip`, i.e. the matrix
   transpose convention in section 5.
6. **Jitter.** If the image is stable but soft, or shimmering at native scale, check the sign of
   the jitter offset against DLSS's convention.
7. **Frame generation starting.** It refuses through a status bitfield rather than by failing a
   call, so the engine reads that back each frame and warns once with the reason in words. The
   common refusals are Reflex not running and the output resolution being too low.
8. **Interface smearing across generated frames** is the known UI alpha gap in section 4, not a
   bug in the hudless copy.

Two structural limits that would show up as puzzling behavior rather than an error:

- The latency markers bracket the render thread's frame rather than the game's simulation step
  when the rendering thread model is threaded, because the frame token cannot safely cross that
  boundary. With a single-threaded rendering model they land where they belong. Reflex's pacing
  and frame generation's requirement that Reflex be running are satisfied either way; only the
  latency *report* is approximate.
- Frame generation is configured with the render target's size, which is the window's size for a
  root viewport. A stretch mode that makes the render target a different size from the swap chain
  has not been considered.
