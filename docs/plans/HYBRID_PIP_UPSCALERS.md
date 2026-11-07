# HybridPiP temporal upscalers: follow-on contract

Historical design requirements from 2026-11-06. Regional temporal reconstruction and the resident ADS path were subsequently implemented. For current runtime support and fallback conditions use the [portable guide](../../GodotForkDocs/features/hybrid-pip.md). The requirements below record the original design review.

## Contexts and scheduling

- Keep independent, persistent contexts for uniform rendering, half-resolution
  background input/full-view output, and native crop input/output. The crop's
  render extent stays fixed while its parent-view position moves. Activation
  must not reconfigure or destroy contexts.
- FSR2 already exposes fixed input/output context creation and dispatch reset.
  Streamline already has distinct stable handles per `RenderSceneBuffersRD`.
  Regional DLSS uses DLAA for native input/output and the matching upscale mode
  for half-resolution background input/full-view output.
- Each active context evaluates once per logical frame. Streamline's frame token
  remains shared; never call its global `frame_begin()` for each region.
- Pass regional unjittered current/previous projections, regional normalized
  motion, and actual input-pixel jitter. Do not generate jitter independently by
  incrementing a counter in each regional pass. Settle the common jitter sequence
  deliberately: mapping native-parent jitter directly gives half the pixel
  excursion in the background, and FSR2 expects a longer sequence for 2x upscale.
- Invalidate history after inactivity, camera cuts, incompatible mapping changes,
  or generation changes. Reset the SDK without recreating its context. Warm
  frames are not valid gameplay history. Reset has GPU work and must be measured.

## Shared exposure and texture extents

- All regional contexts and the prepared uniform path need the same explicit
  exposure texture. Use the parent's previous completed exposure resource when
  enabled; use a persistent positive 1x1 constant when disabled. Do not let DLSS
  independently estimate exposure from each crop. Keep legacy behavior unchanged
  when HybridPiP is off, and validate any exposure-mode transition separately.
- Keep input origin at zero and fixed render extents equal to allocated input
  extents for the first integration. FSR2's wrapper has no arbitrary input-origin
  support. DLSS tags already accept input extents; also tag an explicit output
  target extent if its allocation is larger. Never submit stale padding as image.
- Run reconstruction before composition/blur. The compositor accepts distinct
  valid color and raw-depth extents, so full-resolution background reconstruction
  can retain half-resolution depth. Include this reconstruction cost in results.

## Preparation and failure handling

- FSR2 `create_context()` creates resources and shared compute pipelines, but
  dispatch still lazily creates mip views and descriptor sets. Both history
  parities and the UBO ring affect descriptor keys. A single warm dispatch is not
  proof that every later descriptor combination has been prepared.
- Add a checked FSR2 dispatch returning success, preserving its legacy entry
  point. Gate readiness on successful initialized-input dispatch and actual
  resource preparation, not merely a non-null context.
- Bundled Streamline declares `slAllocateResources` in `sl_core_api.h`. Resolve
  it optionally, share option configuration with evaluate, and invoke allocation
  in an RD driver callback before a real warm evaluation. Missing preparation
  support must disable regional readiness without breaking ordinary DLSS.
- The RD callback executes later than scheduling. Keep a per-owner, generation-
  tagged completion/result object alive through callback execution. Queuing work
  does not mean the SDK accepted it. The current DLSS callback discards evaluate
  failure; `_set_constants()` cannot return failure either. Both results must
  reach the preparation state before regional activation is permitted.
- Do not release SDK resources while evaluation commands remain pending. On
  runtime failure, do not present unwritten output; keep a safe, explicitly
  defined fallback. Readiness does not prove zero driver stalls: measure first
  activation, repeated toggles, reset frames, and configuration changes.

## Existing unit issues to isolate from this change

The native Forward+ calls currently pass degree-valued `Projection::get_fovy()`
to FSR2 and DLSS fields documented as radians. FSR2 also receives seconds where
its bundled header specifies milliseconds and its source divides by 1000.
These pre-existing issues were not changed by the preparatory work. Record and
validate any correction separately from the native-versus-regional control.
For a cropped frustum, derive angular scale from projection diagonal entries
rather than treating asymmetric frustum angle sums as a symmetric camera FOV.

## Minimum validation

Verify native control parity before enabling regional support; poisoned-history
reset; shared exposure while the crop sees a different brightness distribution;
moving crop and objects; disocclusions; crop seam with blur disabled; actual input
and output extents; no cross-context history contamination; injected SDK failure;
and steady-state/transition allocation, CPU, GPU, and memory measurements.

Primary source entry points: `effects/fsr2.{h,cpp}`, `effects/dlss.{h,cpp}`,
`drivers/vulkan/streamline_vk.{h,cpp}`, `thirdparty/amd-fsr2/ffx_fsr2.{h,cpp}`,
and `thirdparty/streamline/include/sl_{core_api,core_types,consts,dlss}.h`.
