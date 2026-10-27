# AMD GI source-buffer dependency batching

Implemented and validated: [runtime results and limits](RESULTS.md).

## Measured problem

The diagnostic run counted 37,512 explicit source-buffer read registrations per
AMD GI render call: 12 sweeps over 1,747 geometry buffers and 1,379 material or
attribute buffers. The original API finds each buffer by probing several RID
owners; a storage buffer requires five mutex-protected `owns()` probes. The same
source HashSets/HashMaps are also traversed for every sweep.

The clean baseline AMD GI command span was approximately 1.65 ms. Diagnostic
timers increased that span to approximately 2.13 ms, so their bucket sums must
not be presented as achievable savings. They identify the repeated source-read
work as the main command-setup target. Performance acceptance uses clean builds.

## Reviewed design

1. Collect geometry/material source RIDs once, after source preparation and
   before the main AMD GI compute list. The collection is local to this render
   call; the original submission methods remain available for comparison.
2. Prepare an RD `BufferReadGroup` containing full RIDs and validated owner types.
   Publish it only after every buffer passes ownership and device-address-usage
   validation. A failed prepare clears the destination and leaves it unusable.
3. Replay the group at every original source-read site. Resolve each RID directly
   through its recorded owner, retaining the full generation check. This removes
   repeated owner-discovery mutex probes without borrowing pointers across calls.
4. Check current transfer-worker state and declare the current resource tracker's
   storage-buffer read for every list segment. Keep all dispatches and barriers,
   including the existing repeated first SHADE_HITS registration.
5. On preparation failure, invalidate the GI view and return through the existing
   fallback. On replay failure, close the active compute list exactly once and
   return before its next dispatch.

The adversarial review approved this design with the requirements above. It
deliberately retains one inexpensive typed lookup per replay instead of caching
raw pointers or introducing global buffer-mutation epochs.

## Correctness invariants

- Group identity uses the RenderingDevice's ObjectID, not an address that could
  be reused by a later device.
- No RID local-index-only lookup, raw Buffer pointer, or ResourceTracker pointer
  is retained in the group.
- A freed/reallocated buffer cannot inherit the old RID's membership.
- An immutable buffer becoming mutable between preparation and replay uses its
  newly created tracker; pending transfers are still checked before consumption.
- Every compute-list segment retains the same graph reads. Existing graph logic
  still merges storage/indirect usage for buffers used in both roles.
- A partially declared failed list never proceeds to the following GI dispatch.
- AMD sampling, shader code, ray counts, lighting quality, and pass ordering are
  unchanged.

## Files and coordination

- `servers/rendering/rendering_device.{h,cpp}`: native-only group preparation and
  replay APIs.
- `servers/rendering/renderer_rd/environment/amd_gi.cpp`: one render-local group
  and replacement of the four existing paired read-call sites.
- `rt_gi_scene.{h,cpp}` and `rt_material_source.{h,cpp}`: narrow RID collection
  accessors, implemented by the scene-work owner to avoid concurrent edits.
- `tests/servers/rendering/test_rendering_device_buffer_read_group.cpp`: opt-in
  native GPU regression; no new scripting API or application startup hook.

## Validation entrypoints

- `GODOT_AMD_GI_DISABLE_BUFFER_READ_GROUPS=1` uses the original per-buffer path
  for clean A/B attribution. Leave it unset for the optimized path.
- `GODOT_AMD_GI_VALIDATE_BUFFER_READ_GROUPS=1` exercises the optimized path while
  independently checking each typed lookup against original RID-owner discovery.
  Do not use this oracle for performance measurements.
- Run `amd_gi_scene_metadata.gd` with the group oracle and its existing scene
  cache oracle enabled. Its vertex-region writes, same-RID primitive replacement,
  material edits and visibility changes exercise source lifecycle updates.
- Run the existing AMD GI MultiMesh fixture and source/preparation recovery
  fixtures with the group oracle. Reject engine errors, not only nonzero exits.
- Build with `tests=yes`, then explicitly select
  `--test --test-case="*Buffer read groups preserve BDA dependencies*" --no-skip`.
  This native Vulkan test is excluded from normal unit runs. It must actually
  initialize Vulkan/BDA and complete GPU output assertions; capability absence
  or zero selected tests is not a passing result.
- The native test covers mixed vertex/index/uniform/storage buffers, pending
  uploads, current tracker state after an immutable-to-mutable change,
  GPU-written indirect arguments read through BDA, repeated list barriers,
  queued work followed by immediate source free/reallocation, failed preparation,
  stale RIDs and isolation between local RenderingDevices.

The parent task owns builds, program launches, quiet-window coordination and
before/after benchmark reports. This document records the plan, not completion
of those checks.
