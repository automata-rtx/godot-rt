# NVIDIA Streamline in this fork

DLSS super resolution and DLSS frame generation, on Vulkan, on Windows. This is the current
description of what the engine does.

**DLSS super resolution works.** Confirmed on the RTX 5090 target, running Vulkan fullscreen at
3440x1440 with a 3D scale of 0.67 — the equivalent of DLSS Quality — and opaque geometry is clean:
no ghosting, no smearing under camera motion, no shimmer at rest. Transparency was not: world-space
label text ghosted badly in the same build, which is what the billboard fix in section 5 and the
reactive mask in section 3 came out of.

That result retires most of what this document used to hedge about, because every convention DLSS
depends on fails *visibly* and in its own way — steps 3 to 6 of section 9 map each artifact back to
the one cause that produces it — and not one of those artifacts is present. So the sign and scale
conventions in section 5, and the camera-motion pre-fill of the velocity buffer that step 4 of
section 9 explains, are confirmed in practice rather than only from the SDK headers. Read them as
describing what runs, with one exception: both fixes for the transparency failure were written
after that run and have not been back on the machine since.

**Two things here have never run on hardware**, so plan a session around both rather than one.
**Frame generation** is now genuinely reachable for the first time: it refuses without motion
vectors, and TAA is never used here, so super resolution is the only thing that fills the velocity
buffer for it — the two antialiasing configurations in this project are exclusive, DLSS doing the
antialiasing whenever it is on and SMAA whenever it is off, and SMAA leaving no velocity buffer at
all. **The reactive mask** (`rendering/streamline/reactive_mask`, section 3) is off by default for
exactly that reason: an earlier attempt at it blacked out every opaque pixel on hardware, and the
version in the tree fixes that cause but has never been tried. Section 9 checks both.

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
| `servers/rendering/renderer_rd/shaders/effects/dlss_reactive.glsl` | The reactive mask copy. Globbed by the effects `SCsub`, so nothing registers it. |
| `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp/.h` | The `SCALE_DLSS` branch that fills the effect's parameters, and the reactive mask's `RB_SCOPE_DLSS` texture. |
| `servers/rendering/renderer_rd/storage_rd/render_scene_data_rd.cpp` | The previous frame's `main_cam_inv_view_matrix`, so billboards produce a motion vector. A stock Godot bug, not Streamline-specific. |
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

Inputs are the internal color, depth and velocity buffers, plus the auto-exposure buffer when
the camera has auto exposure on; without it DLSS estimates exposure itself. The output is the
upscaled color buffer the engine already allocates for FSR2.

### Model presets

`rendering/anti_aliasing/quality/dlss_preset` forces a DL model instead of letting the runtime
choose. It is read every frame, so it can be changed without restarting, and it is applied to every
quality mode at once — the mode follows the viewport's 3D scale and therefore moves under the
project's feet, so a preset that only bound to whichever mode happened to be selected would be a
trap.

Only Default, J, K, L and M are offered. Of the SDK's sixteen slots, A–D were removed, E and F are
deprecated, and G, H, I, N and O are documented as reverting to default behavior; listing them would
be five entries that do nothing.

**Nothing reads back which model is actually running.** `sl::DLSSState` carries only
`estimatedVRAMUsageInBytes`, and every NGX preset parameter is a write-only *hint*
(`DLSS.Hint.Render.Preset.*`). So a viewport left on Default reports the preset the SDK's own header
documents for its quality mode — K for DLAA, Quality and Balanced, M for Performance, L for Ultra
Performance — and says "documented default" rather than presenting it as fact, because the same
header warns the choice "may or may not change after an OTA". Force a preset and the overlay reports
it plainly, because then it is exactly what was handed to the runtime.

The one thing that does report the model authoritatively is NVIDIA's on-screen DLSS indicator,
which the runtime draws into the upscaled image from inside `nvngx_dlss.dll` — where the choice is
actually made. It is a machine-wide registry switch with no API behind it, and the SDK ships the
two files that flip it: `scripts/ngx_driver_onscreenindicator.reg` sets
`HKLM\SOFTWARE\NVIDIA Corporation\Global\NGXCore\ShowDlssIndicator` to 1, and the `_off`
variant back to 0. Writing it needs elevation; reading it does not, so the overlay reads the value
and, when the indicator is on, says so and defers to the letter on screen.

How thoroughly this was checked, so nobody spends the day repeating it: the NGX parameter namespace
is 393 defines and the only `Get`-prefixed keys in it are the four dynamic render extents; the whole
preset surface is six keys with `Hint` in every name; the only NGX runtime query that exists returns
`SizeInBytes`, `OptLevel` and `IsDevSnippetBranch`, which describe how the DLL was built rather than
which model it picked; Streamline reads 25 parameter values in its entire source tree and none is
preset-shaped; and `sl.dlss`'s own debug HUD prints mode, viewport, runtime and VRAM
(`dlssEntry.cpp:84-91`, filled at `:772-775`) — NVIDIA's own overlay, with full access to the
plugin's state, cannot print a preset letter either, because the plugin does not know it.

### The editor overlay

**View → View Information** in the 3D viewport gains two lines whenever DLSS is the upscaler that
actually ran:

```
DLSS: 2304 × 964 → 3440 × 1440 (67%)
Quality, preset K (documented default)
```

The resolutions come from `RenderingServer::viewport_get_internal_size`, not from multiplying the
viewport size by its 3D scale, and the mode from
`RenderingServer::viewport_get_effective_scaling_3d_mode` — both of which answer what the renderer
did rather than what it was asked to do. That distinction is the point: a DLSS request lands on
FSR 2 wherever DLSS cannot run, and the old `Size:` line would have gone on reporting the requested
scale as though it had been honored. It now uses the same authoritative number.

### The reactive mask, and why it ships off

Godot builds a reactive mask every frame an upscaler runs -- the color buffer's **alpha channel**,
which is zeroed across the opaque pass by `pass_alpha_multiplier` and then accumulates transparent
coverage -- and FSR2 is handed it at `render_forward_clustered.cpp:3098` as
`get_internal_texture_reactive()`. Unless `rendering/streamline/reactive_mask` is on, DLSS is not
handed it, so at the shipped defaults alpha-blended surfaces ghost worse under DLSS than under FSR2
at the same scale. That much is real.

**Tagging that same RID as `kBufferTypeBiasCurrentColorHint` does NOT fix it. It was tried on
hardware and every opaque pixel went black**, leaving only alpha-blended surfaces and the HUD
visible. FSR2 was unaffected because it never goes through Streamline's tagging at all -- the engine
binds that same view itself, as an ordinary shader resource in its own dispatch.

**The rule this establishes is more general than the one RID that broke it: anything tagged for
Streamline has to be a texture of its own.** A tag names its resource by its native `VkImage`, and
`RenderingDeviceDriverVulkan::get_resource_native_handle` answers `DRIVER_RESOURCE_TEXTURE` with
`vk_view_create_info.image` -- a field that a swizzled view and a texture *slice* alike inherit
unchanged from the texture they were carved out of, because `texture_create_shared_from_slice`
copies the parent's whole create-info and replaces only the view. So parent, view and slice all
resolve to one handle through `texture_from_rid` (`streamline_vk.cpp`), and with
`eUseFrameBasedResourceTagging` in the preference flags (`streamline_vk.cpp:671`) two tags built
from any of them name the same resource and collide.

`get_internal_texture_reactive()` is the instance that cost a frame: it is not a texture but an
**alpha-swizzled view of the color buffer**, so the color tag and the reactive tag carried the same
image handle, and DLSS sampled the swizzled view as its input color -- which is alpha replicated to
all four channels, and alpha is zero everywhere the opaque pass drew. The symptom reads like a
lighting or exposure failure and is neither.

**The proper version is implemented and ships OFF**, behind `rendering/streamline/reactive_mask`,
and **has never been run on hardware**. `effects/dlss_reactive.glsl` copies the color buffer's
alpha into an `R8_UNORM` texture of its own at the internal size, and that texture -- a distinct
`VkImage` -- is what carries the tag. The setting is read every frame, so it can be flipped in game
without a restart; the texture lives in the `RB_SCOPE_DLSS` scope and is freed when the render
buffers are next configured, not when the setting goes off. It costs one full screen single channel
copy per frame while enabled.

It stays off because **nothing in this repository can exercise it**: the Streamline driver
files compile to empty objects anywhere but Windows, so CI type-checks them and no test runs them.
The shader itself is validated -- `glslangValidator` compiles it to SPIR-V and reflects a 16 byte
push constant block matching the `static_assert` -- but that says nothing about whether DLSS likes
the tag. Step 7 of section 9 is how to answer that on a machine that can. Do not re-attempt the
view: the first attempt was reasoned as additive and low risk, both of which were claims about the
code, and the failure was in the runtime.

---

## 4. Frame generation

**It is not loaded in the editor at all.** `sl.dlss_g` is the one plugin that hooks
`vkCreateSwapchainKHR`, and the interposer returns a before-hook's error verbatim without ever
reaching the driver, so a swapchain DLSS-G declines is a swapchain that does not get created. It
attaches to whichever swapchain it is offered and expects an application to have one; the editor is
a multi-window program where every context menu and menu-bar dropdown is an OS window with its own
swapchain, and it presents its own interface rather than a game frame, so it could never run frame
generation anyway. Leaving `kFeatureDLSS_G` out of `slInit`'s `featuresToLoad` frees the plugin on
discovery and takes its hooks with it. Exported games still request it; `Engine::is_editor_hint()`
is compiled to a constant `false` in a release template.

Two things this rules out, both verified against the SDK source rather than assumed. The
`PreferenceFlags::eUseManualHooking` flag does **not** suppress this — it is read only by
`slUpgradeInterface` and sl.common's D3D12 pipeline restore, and the Vulkan wrapper hands out its
proxies unconditionally; the DLSS-G guide's "unless manual hooking is used" is about the DXGI
factory proxy, and its own worked example for the multiple-swapchain case reaches for
`slSetFeatureLoaded` instead. And a game that presents more than one window is still unhandled:
`RenderingDeviceDriverVulkan` batches every window's swapchain into a single `vkQueuePresentKHR`,
so there is no per-window native/proxy split to route around it.

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
- **A billboard's previous-frame position** is oriented with the previous camera:
  `RenderSceneDataRD::update_ubo` writes `prev_cam_transform` into the previous frame UBO's
  `main_cam_inv_view_matrix`, a field the `memcpy` that seeds that UBO had left holding the CURRENT
  camera. Without it a billboard reports almost no motion however fast the camera turns, and DLSS
  smears it.
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

## 7. What DLSS does to the fork's other passes

Now that super resolution runs, this is the live interaction and it is easy to miss: **every pass
this fork adds runs at the viewport's INTERNAL size**, not its output size. The raytraced shadow
trace and denoiser, the Bend contact shadow march and the occlusion gather are all dispatched from
`get_internal_size()`. At DLSS Quality that is 0.67 of each axis, so about 45% of the pixels.

Three fork quantities are budgeted in **pixels** rather than in world units, so DLSS silently
rescales what they mean on screen:

- **The contact shadow's march length**, which the quality tier fixes in samples and therefore in
  pixels. At 0.67 it reaches roughly two thirds as far across the output image, so a shadow that
  ran out of march at native runs out sooner. `quality` is the knob; there is no world-space one.
- **`raytraced_shadows/denoiser/min_filter_pixels`**, the floor on filter reach.
- **`MAX_PENUMBRA_PIXELS`**, the cap the trace quantizes hit distance against, which covers about
  1.5x as much of the output image as it did at native.

None of this is wrong, and none of it needs a code change — it is the same tradeoff any upscaler
makes — but a contact shadow that looks shorter with DLSS on is this, not a bug.

**An odd internal size is the part that did bite.** 3440x1440 divides cleanly by 16; 3440x0.67 does
not. The GTAO depth prefilter's mip bound was `(size - 1) >> level` where the last valid index is
`max(1, size >> level) - 1`, which agree only when a dimension is a multiple of 2^level. At native
they always agreed, so the defect was invisible. Godot truncates the internal size
(`renderer_viewport.cpp:315` is a float expression assigned to an `int`), so DLSS Quality on that
display gives **2304x964**: 2304 is 2^8 x 9 and stays clean, but 964 is 2^2 x 241, so the guard
admitted one texel past the end of the row at mip levels 3 and 4 in HEIGHT. Two levels of five, one
axis -- enough to be a real out of bounds store, and reachable only through DLSS. Fixed, but worth
recording as the shape of the problem: **DLSS is the thing most likely to expose a latent
size-alignment assumption in a pass, because it is the only feature that makes the render size
arbitrary.** When a new pass builds a mip chain or tiles a dispatch, check it against an odd size,
not against 3440x1440.

---

## 8. Costs

- Super resolution: no engine-side allocation beyond what FSR2 already needs, unless the reactive
  mask is on, which adds one R8 texture at the internal size. Streamline allocates its own history
  under the viewport handle.
- Frame generation: one full-resolution color texture per running viewport, and one
  full-resolution copy per frame, both only while it runs. Streamline allocates the
  interpolation resources and an optical flow surface of its own.
- Neither costs anything when Streamline is off: the singleton does not exist, and every entry
  point is behind a null check.

## 9. What to check first on hardware

**None of this can be checked from a Linux checkout.** Streamline is Windows-only and needs an
NVIDIA GPU, so every step below wants a Windows binary on the machine that has one. The Windows job
in `.github/workflows/runner.yml` is the route to that binary — this project builds through GitHub
Actions rather than a local toolchain. The `windows-editor` artifact is what to test super
resolution and the reactive mask with; frame generation never runs in the editor, so steps 8 and 9
need a game exported against the `windows-template` artifact as a custom release template.

**Steps 1 to 6 below are answered** by the run described at the top of this document. They are kept
as the diagnostic ladder for a configuration that has not been tried — another GPU, a different
quality mode, windowed presentation — and because each one names the artifact its own failure
produces, which is how to attribute a new one. **Steps 7 to 9 are the two open items**, the reactive
mask and frame generation.

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
   Note that DLSS is given a camera-motion pre-fill of the velocity buffer, the same one MetalFX
   Temporal uses. It has to be: Godot clears that buffer to `(-1, -1)` as a sentinel for "nothing
   wrote here", FSR2 recognizes the value in its own patched shader and derives camera motion from
   depth, and DLSS -- whose shader cannot be patched -- would otherwise read the sentinel as a
   full screen of motion at every pixel the motion pass did not cover.
5. **Ghosting that survives a still camera** points at `clipToPrevClip`, i.e. the matrix
   transpose convention in section 5.
6. **Jitter.** If the image is stable but soft, or shimmering at native scale, check the sign of
   the jitter offset against DLSS's convention.
7. **The reactive mask.** Turn `rendering/streamline/reactive_mask` on with super resolution
   running — it is read every frame, so it toggles in place — and watch an alpha-blended surface
   cross the frame; world-space label text is the case it was written for. Success is that surface
   holding its edge instead of dragging a trail. Three failures to tell apart: **anything happening
   to opaque pixels at all** means the tag landed on something other than the mask's own texture —
   the failure section 3 describes — and is the reason to turn it straight back off; **transparency
   going noisy or flickering rather than sharper** means the hint is too strong, and its scale is a
   fixed `1.0` at the call site with no setting behind it; **no difference either way** means the
   tag is not reaching DLSS, which `sl.log` will say more about than the engine's own output.
8. **Frame generation starting.** It refuses through a status bitfield rather than by failing a
   call, so the engine reads that back each frame and warns once with the reason in words. The
   common refusals are Reflex not running and the output resolution being too low.
9. **Interface smearing across generated frames** is the known UI alpha gap in section 4, not a
   bug in the hudless copy.

Signatures worth recognizing:

- **`Couldn't create Vulkan swapchain (VkResult error -3)` repeating at frame rate**, with windows
  that render blank, is a Streamline plugin vetoing swapchain creation — not a driver fault.
  `VK_ERROR_INITIALIZATION_FAILED` arrives from a before-hook, and only `sl.dlss_g` registers one.
  Each retry also pays a full `_flush_and_stall_for_all_frames()`, so it is expensive as well as
  noisy.
- **A ghosting raytraced shadow is not a DLSS problem.** That denoiser accumulates over time in
  both antialiasing configurations, so its own `denoiser/*` settings are the knob and not the
  upscaler's; the tuning list in `docs/rt_shadows/FORK_GUIDE.md` says which one.
- Streamline's own log is warnings and errors by default now, written to `sl.log` in the project's
  user data directory. It is the only place Streamline's side of a refusal is recorded, and it is
  worth reading before forming a theory from the engine's own messages.

Two structural limits that would show up as puzzling behavior rather than an error:

- The latency markers bracket the render thread's frame rather than the game's simulation step
  when the rendering thread model is threaded, because the frame token cannot safely cross that
  boundary. With a single-threaded rendering model they land where they belong. Reflex's pacing
  and frame generation's requirement that Reflex be running are satisfied either way; only the
  latency *report* is approximate.
- Frame generation is configured with the render target's size, which is the window's size for a
  root viewport. A stretch mode that makes the render target a different size from the swap chain
  has not been considered.
