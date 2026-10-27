# TLAS CPU preparation reuse

This is a Godot resource/submission adapter optimization. It changes neither
AMD GI estimators nor GPU TLAS build/refit policy. Runtime results belong in the
parent results report; the contracts below do not imply tests have passed.

## Contract

`RenderingDevice::tlas_build` retains ordered full BLAS RIDs, resolved native
instance inputs, native packed instance bytes, and the unique BLAS tracker list
on each TLAS. If the ordered BLAS list remains identical and its cache is valid,
only changed transform/ID/mask/SBT-offset/flag inputs are packed again. Transform
comparison uses exact object bytes; signed zero changes are retained, and any
padding differences can only trigger extra packing. There is no float tolerance.

Every call still reserves its own complete mapped upload range, copies every
packed instance into that range, and registers every BLAS tracker with the graph.
No prior mapped range is modified or reused while queued/in-flight GPU work can
read it. Native GPU resources, scratch allocation, build flags, refit eligibility,
and graph synchronization retain their existing lifetimes and rules.

Unchanged topology keeps both weak dependency directions intact. A BLAS rebuild
or free clears each dependent TLAS's cache-valid flag before removing the link.
The next call must resolve and validate all source references again, even when
BLAS RIDs have not changed. Cached tracker pointers/native addresses cannot be
read on that path until reconstruction succeeds. Cold preparation validates each
unique BLAS once and publishes replacement weak links only after all instances
pass validation. Failed staging remains invalid; it cannot expose a partial cache
when a subsequent call returns to an earlier topology. Invalid live SBT ranges
also invalidate the cache before returning an error.

The CPU cache lives with its TLAS and is bounded by its allocated instance
capacity. CPU-only vectors are cleared before the AS is copied into deferred GPU
destruction, avoiding an unnecessary duplicate of large preparation arrays.

## Reference practices

- The [Vulkan acceleration-structure specification](https://docs.vulkan.org/spec/latest/chapters/accelstructures.html)
  requires a complete instance description for an update and valid referenced
  BLAS objects when a TLAS is accessed. Reusing CPU packing does not relax those
  requirements; active/inactive transitions still use the existing rebuild rules.
- [NVIDIA's ray-tracing best practices](https://developer.nvidia.com/blog/best-practices-for-using-nvidia-rtx-ray-tracing-updated/)
  identify command-generation CPU work as a meaningful cost and recommend
  reusing unchanged geometry. This change applies those general principles to
  the fork's measured submission path; the exact retained-cache design is a
  Godot integration decision, not an AMD or NVIDIA algorithm prescription.

## Diagnostics and reproduction

- `GODOT_RT_DISABLE_TLAS_REUSE=1` executes the original owner lookup, weak-link
  rebuilding, packing and mapped-write loop for controlled comparisons.
- `GODOT_RT_VALIDATE_TLAS_REUSE=1` reconstructs every packed byte and unique graph
  tracker from current owners, and verifies both weak dependency directions.
  `RT TLAS reuse oracle: checked=true` is emitted only after a retained topology
  actually passes. Keep this disabled for performance measurements.
- `GODOT_RT_CPU_PROFILE=1` reports averages over 120 calls: preparation, complete
  upload, and graph submission time; total instances, repacked instances and
  retained-topology calls. Bypass uploads are inside the original preparation
  loop, so compare summed time across modes rather than the upload bucket alone.

Run the [native RD fixture](../shadow_validation/tlas_cpu_reuse.gd) using a Vulkan
editor build, the `shadow_validation` project directory, and
`--script res://tlas_cpu_reuse.gd`. It expects 136 queued ray queries with zero
failures, across eight batches. Run with the oracle and separately with the
bypass, and reject script/native errors or timeout. The fixture covers unchanged
inputs; ID, transform, mask, flags and SBT-offset mutation; active/inactive slots;
BLAS order, instance counts and empty input; same-RID BLAS content rebuild;
source-buffer destruction and BLAS replacement; and repeated same-frame builds
interleaved with queries before submission. Actual ray IDs/misses validate GPU
behavior; the native oracle checks flag/SBT bytes and dependency equivalence.

[run_native.py](run_native.py) runs this fixture and the original upload-lifetime
fixture, with separate user-data folders, parsing, bounded Vulkan execution,
strict error/completion checks, and executable/script hashes. Use
`--engine PATH --output NEW_DIRECTORY --env GODOT_RT_VALIDATE_TLAS_REUSE=1`
for the candidate; use `--env GODOT_RT_DISABLE_TLAS_REUSE=1` in a separate output
directory for the original path. Validation mode requires an actual retained
topology oracle success in both fixtures; the two modes cannot be combined.

Also retain [the upload lifetime fixture](../shadow_validation/tlas_instance_upload_lifetime.gd),
native winding, shared shadow/GI lifecycle, and deformation/metadata rigs. The
script RD API does not expose the C++ `p_update` argument, so normal GI runtime
exercises refit submission while the existing
`test_rendering_device_tlas_update.cpp` covers its eligibility rules. This fixture
does not deliberately submit invalid native resources; failure safety also needs
source review and the project's existing preparation-recovery checks.

## Conservative invalidation stress

[tlas_cpu_stress.gd](../shadow_validation/tlas_cpu_stress.gd) submits 16,000
instances sharing one BLAS, with 64 changed transforms per iteration. It runs
120 retained-topology submissions followed by 120 submissions preceded by an
explicit rebuild of the same BLAS. Every iteration submits and waits for GPU
completion outside its timed `tlas_build` call. The first retained-topology sample
includes initial preparation; subsequent samples can reuse it.

Set `RT_TLAS_STRESS_OUT` to a writable JSON file path, and run on the same binary
with reuse enabled and with `GODOT_RT_DISABLE_TLAS_REUSE=1`. Raw CPU samples,
medians and percentiles are saved. `GODOT_RT_CPU_PROFILE=1` adds native 120-call
phase totals and counters; its logging can affect the last wall-time sample.
Script wall time includes array conversion, while the native profile excludes
that shared overhead. This is a targeted shared-geometry invalidation stress,
not a prediction for scenes with many unique meshes or GPU frame performance.
