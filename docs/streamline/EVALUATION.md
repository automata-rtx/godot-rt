# Streamline in this fork: how it would attach

An evaluation, not a plan of record. The question asked was how to get DLSS super resolution and
frame generation into this engine cleanly, and what the inputs cost. Read against Streamline SDK
**2.12.0** (`e8aaa6e`), which is what the conclusions below were checked against; NVIDIA moves this
SDK quickly and a later version may change the two limits in section 5.

## 1. The short version

Two seams in Godot's Vulkan backend decide everything, and both are already in the right shape.

**Super resolution is a scaling mode.** Godot already has the whole scaffolding: a
`VIEWPORT_SCALING_3D_MODE` enum with FSR2 and MetalFX Temporal in it, a jittered projection, motion
vectors, an internal-vs-target size split, and an upscaled texture target. `FSR2Effect::Parameters`
is, field for field, close to what DLSS wants -- colour, depth, velocity, exposure, output, jitter,
near and far, vertical FOV, delta time, a reset flag and the reprojection. A DLSS mode sits beside
FSR2 rather than replacing anything, and MetalFX is the precedent for a vendor upscaler that only
exists on some hardware.

**Frame generation is a present-path feature**, and this is where an engine usually has to be torn
open. It does not here. Godot loads `vkQueuePresentKHR` and `vkAcquireNextImageKHR` once through
`GetDeviceProcAddr` into a function-pointer table and calls them only through that table. Those two
entry points are exactly what Streamline's Vulkan frame generation intercepts. Pointing that table
at Streamline's proxy is a small, local change, and it avoids the interposer DLL that the SDK
otherwise expects to sit in front of the application.

So the recommendation is **manual hooking, in-tree, Vulkan first**, rather than the interposer.

## 2. Why not the interposer

Streamline's default deployment replaces `vulkan-1.dll` / `dxgi.dll` next to the executable and
interposes every call. It needs no engine changes, which is why the SDK leads with it.

It is the wrong choice here for three reasons. It moves a load-bearing part of the renderer outside
the build and outside CI. It makes the editor and the exported game behave differently, since only
one of them ships next to those DLLs. And this fork already reaches into device creation for
raytracing, so the objection it answers -- "we cannot touch the device" -- does not apply.

Manual hooking is documented (`docs/ProgrammingGuideManualHooking.md`) and is the path NVIDIA
expects custom engines to take.

## 3. What has to change at device creation

Streamline requires this **before** the instance and device exist, per feature, from
`slGetFeatureRequirements`:

| What | Where it lands in Godot |
| --- | --- |
| Instance extensions | `_register_requested_instance_extension()` already exists and takes a required flag |
| Device extensions | the equivalent device-side registration in the device driver |
| Vulkan 1.2 / 1.3 feature bits | merged into the feature chain the device driver builds |
| **Extra queues** | `_add_queue_create_info()` -- `max_queue_count_per_family` is currently `1` |
| A dedicated optical-flow queue family | only for native OFA; without it frame generation falls back to interop mode |

The queue change is the one with a trap in it. `max_queue_count_per_family` is a local constant and
`queue_priorities` is a `static` array **sized from that same constant**, so raising one without the
other is a buffer overrun that will not necessarily crash. Streamline then needs to be told where
its queues begin -- `slSetVulkanInfo` takes the index at which SL's queues start after the host's,
so Godot's own queue indices have to stay at the front.

Everything Streamline needs to be handed afterwards is already reachable:
`get_driver_resource()` exposes the logical device, physical device, instance, command queue, queue
family, image and image view.

## 4. The inputs, and what each costs

### Super resolution

Almost free, because the fork already pays for most of it.

| Input | Status |
| --- | --- |
| Colour, depth, motion vectors | already produced; this fork **forces motion vectors on** for raytraced shadows, so a project using RT shadows has them regardless |
| Jitter | already generated for the existing temporal upscalers; DLSS wants the same offsets it was rendered with |
| Exposure | FSR2 already threads one through |
| Near, far, FOV, delta time, reset | already in `FSR2Effect::Parameters` |
| Output at target size | the upscaled texture target already exists |

### Frame generation

This is where the real work is, and it is not in the graphics API.

**Hudless colour is the hard input.** Frame generation wants the scene *before* UI is drawn, and the
guide calls it critical rather than optional. Godot draws 3D and then draws canvas -- including every
`Control` -- over it into the same render target, inside `_draw_viewport`. So there is a well-defined
moment when the buffer is exactly hudless, and the cheap answer is one full-resolution copy taken
there. That copy is the honest cost: it buys correct interpolation of a scene whose UI would
otherwise smear.

**UI alpha is the input Godot cannot currently produce.** Streamline wants either a single-channel
alpha or a premultiplied colour-and-alpha buffer of just the UI, obeying
`Final = UI.rgb + (1 - UI.a) * Hudless.rgb`. Godot has no separate UI target. Rendering canvas to its
own transparent buffer and compositing is possible but is a real change to the 2D path. It is also
optional: hudless alone is the critical one, and UI alpha is an image-quality addition on top.

**Reflex is effectively mandatory.** Frame generation needs the latency markers, which means a
`sl.pcl` / `sl.reflex` integration around the frame boundary as well.

## 5. Two limits that constrain the backend choice

Both verified in the 2.12.0 frame generation guide:

- **VSync with frame generation is D3D12 only.** On Vulkan, frame generation requires VSync off.
- **Dynamic multi-frame generation is D3D12 only.** Vulkan gets the fixed multiplier (`eOn`).

Godot's Forward+ runs on both, so this is a live choice rather than a blocker. Vulkan is the smaller
change and the better-trodden path in this fork; D3D12 buys VSync and dynamic MFG at the cost of a
second integration against a backend none of the raytracing work has touched.

## 6. XeSS

**Streamline 2.12.0 does not ship XeSS.** The plugin set is `sl.common`, `sl.deepdvc`,
`sl.directsr`, `sl.dlss`, `sl.dlss_d`, `sl.imgui`, `sl.nis`, `sl.pcl`, `sl.reflex`, `sl.template`.
There is no XeSS plugin and no mention of it in the headers or the documentation.

The cross-vendor path that does exist inside Streamline is **DirectSR** (`sl.directsr`), which
enumerates whatever upscaler variants the OS and driver expose -- which is where XeSS would appear on
Intel hardware. Two things make it a poor fit here: it is **D3D12 only**, and it runs on a command
queue rather than recording into an existing command list, which is a scheduling difference rather
than a detail. NVIDIA's own guide recommends `sl.dlss` over `sl.directsr` on RTX hardware.

So if XeSS matters, it is a **separate integration against Intel's own SDK**, sitting beside
Streamline behind the same scaling-mode abstraction -- not something Streamline provides.

## 7. Suggested order

Each step ends somewhere testable, and the first two are worth having even if the rest is abandoned.

1. **Init and shutdown only.** Link Streamline, `slInit`, query feature support, log it. No feature
   enabled, no pixel changes. Confirms the DLL loading and signature checking work in both the
   editor and an exported build.
2. **Device creation.** Extensions, features and queues from `slGetFeatureRequirements`, then
   `slSetVulkanInfo`. Still no feature enabled. Confirms nothing regressed on hardware that will
   never run DLSS -- including the Radeon laptop, which is the useful negative test.
3. **DLSS super resolution** as a new scaling mode beside FSR2. Tag colour, depth, motion vectors and
   exposure; feed the existing jitter. This is the step with a real payoff and a bounded blast
   radius.
4. **Reflex / PCL markers** around the frame boundary. Useful on its own for latency.
5. **Frame generation.** The present-table redirect, the hudless copy, and the vsync constraint from
   section 5. Optionally UI alpha afterwards.

## 8. What this evaluation did not establish

- Nothing here has been compiled or run. The Godot-side facts are read out of this tree; the
  Streamline-side facts are read out of the 2.12.0 documentation and headers.
- Whether the DLSS and DLSS-G binaries the SDK expects can be loaded from an exported Godot game's
  directory layout, and how signature checking behaves there, is unexamined.
- Frame pacing interaction with Godot's own main-loop timing is unexamined and is the most likely
  place for an unpleasant surprise.
- D3D12 was not investigated beyond the two limits in section 5.
