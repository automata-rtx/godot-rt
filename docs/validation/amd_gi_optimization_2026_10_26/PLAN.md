# GI CPU/setup and reflection optimization plan

Baseline: `66bd97e00d`. Scope approved 2026-10-26: implement candidates 1, 2 and 3
after adversarial review, with before/after benchmarks. Emissive-material caching
and animated-BLAS refit (candidates 4/5) remain out of scope.

## Invariants

Preserve AMD's ray budgets, sample order, transport, denoising, history and native
material evaluation. Preserve current-frame geometry, complete GPU dependencies,
full RID generations, multi-viewport ownership and failed-preparation recovery.
No game source/assets or saved settings are changed. Tests use isolated user data,
grass off and a bounded window. Existing documentation changes are preserved.

## Sequence and acceptance

1. Preserve the existing tested executable and source identity. Capture baseline
   Live World render/CPU/GPU/frame timings with the current game configuration
   explicitly logged. Identify Live World by scene/name, not a stale menu index.
   Separate timed windows from screenshots and synchronous diagnostic readbacks.
2. **Scene preparation:** cache MultiMesh world transforms/AABBs using full resource
   identity, actual backend data revisions, current parent transform/mesh bounds
   and visible count. Keep current material/instance metadata live. Reuse copied
   shared geometry descriptors within one scene update, never across epochs or
   through borrowed pointers. Benchmark, run uncached reconstruction/mutation
   checks, and retain only safe useful behavior.
3. **GI binding setup:** compare exact resource binding lists once per relevant
   history parity/material set, retaining borrowed per-pass descriptor handles.
   Invalidate on shader version/resource-list changes and check native descriptor
   validity before reuse. Preserve every actual bind, barrier and explicit source
   buffer-read declaration. Benchmark against step 2 and exercise resize, material,
   texture, view and runtime-option transitions with an ordinary-path oracle.
4. **Default firefly rank shortcut:** skip only neighbor ranking when thresholds
   equal exactly 0 and 1. Preserve negative-distance marking, raw diagnostics,
   all final writes and the original cleanup pass. Custom/NaN thresholds follow
   the old path. Compare against step 3; require exact GPU marking equivalence
   plus ordinary production rendering and timing.
5. Review integrated changes, run relevant hooks and targeted regressions, preserve
   executable hashes and raw results, and document measured benefits and limits.
   Do not claim a fixture passed merely because it compiled or exited normally.

## Adversarial review before implementation

Three specialists examined scene reuse, binding reuse and reflection arithmetic.
Scene/binding specialists cross-reviewed revision coverage and lifetime handling;
the parent independently reviewed shared geometry epochs and the reflection proof.
Review rejected broad material/static-object early-outs, dropping graph reads,
using notification-only MultiMesh revisions, and removing the complete firefly
pass. Backend bulk/interpolation writes must invalidate placement caches. Shader
and resource invalidation must remain authoritative for cached binding handles.

The rank shortcut is an algebraic simplification, not a changed filter: counts
are bounded sums of zero/one, so default rank comparisons cannot succeed. An
isolated CPU proof covers all count pairs through the maximum supported radius,
nonfinite radiance, invalid pixels, full/half layouts and custom thresholds.
GPU output equality remains a separate acceptance gate.

## Measurement discipline

Use the same optimized compiler/build settings, resolution, upscaler, camera,
warmup and sample windows. Keep diagnostic oracles off timing runs. Record prior
and next executables so paired repeats can distinguish changes from run-to-run
variation. Do not benchmark while a known competing engine test/build is active.
Live gameplay can vary; report median/tail CPU and GPU separately and supplement
with controlled fixtures. Game content changes by other tasks invalidate direct
comparisons and must be detected rather than attributed to the engine.

The final result must say which candidates improved measurable cost, which were
limited by noise, and what correctness tests actually ran. No blanket FPS promise.
