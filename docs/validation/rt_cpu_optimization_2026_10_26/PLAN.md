# RT CPU preparation optimization plan

Approved scope: finish the first two candidates from the 2026-10-26 CPU audit.
Baseline is `66bd97e00d` plus the previously tested, uncommitted GI optimization
changes (executable SHA-256 `c15d6f3b64ac765f7bccb95ac714cb369835bc5fab030f2c3617526faf756c74`).
Existing documentation edits are preserved. Game source/assets are outside scope.

## Design and adversarial acceptance

1. **Shadow preparation.** Reuse the existing value-only MultiMesh expansion
   cache for shadows, while evaluating current camera/light/scatter eligibility.
   Resolve repeated geometry sources once per scene update, copying handles and
   values rather than retaining borrowed geometry pointers. Retain per-input-slot
   source/transform contributions to avoid rehashing unchanged transforms. Build
   the complete ordered RD instance list only when a shadow TLAS build is needed.
   Source resolution still happens every update: destroyed resources, changed
   geometry, skinning and deferred builds cannot be hidden by the cache.
2. **Shared TLAS submission.** Retain ordered CPU inputs, packed instance bytes
   and unique BLAS dependencies. Repack changed records on a valid topology hit.
   Invalidate cached metadata when a dependent BLAS is rebuilt or freed. A cold
   path validates references before publishing a replacement dependency set.
   Copy the complete packed input into the existing reserved mapped ring range,
   and register every required graph dependency on every submitted build.

The independent reviewer challenges both implementations and owns focused
mutation/image fixtures. Particular hazards are full-RID generations, source
changes without RID changes, failed/deferred preparation, material masks, caster
selection/reordering, empty/repopulated scenes, multiple viewports, same-frame
TLAS builds, BLAS destruction/rebuild and in-flight upload lifetime. Diagnostic
bypasses and uncached oracles must exercise actual cache hits. Instrumentation
is opt-in and disabled during performance measurement.

No AMD sampling, material evaluation, shadow coverage, quality settings, build
budgets, GPU synchronization or AS build/refit policy changes are intended.
Animated BLAS refitting and static emissive caching remain deferred.

## Industry references and implications

- [Vulkan acceleration structure specification](https://docs.vulkan.org/spec/latest/chapters/accelstructures.html):
  a TLAS requires live referenced BLAS objects; an update still consumes a full
  input description and has strict membership/layout constraints. CPU reuse must
  not weaken lifetime tracking, synchronization or upload-range isolation.
- [Epic ray tracing performance guide](https://dev.epicgames.com/documentation/en-us/unreal-engine/ray-tracing-performance-guide-in-unreal-engine):
  separates geometry, scene construction and traversal costs. Our changes target
  CPU scene construction; they do not claim to remove dynamic GPU geometry cost.

These references inform adapter design, not a replacement for measurements of
this fork. No quality-reducing culling or reduced update frequency is proposed.

## Execution and evidence

1. Preserve the tested baseline executable and source patch. Coordinate quiet
   benchmark windows with Game Director and record competing processes.
2. Reuse the frozen fps-proto snapshot and isolated user data from the preceding
   optimization work. Windowed 1280x720, grass off, identical rendering settings,
   live and paused phases. Measure two baseline runs.
3. Build/test candidate 1 separately, preserve its executable and source patch,
   then measure before permitting candidate 2 into the production files.
4. Build/test candidate 2; compare stages and final repeats. Use bypass/oracle
   diagnostics separately from headline timing runs.
5. Run hard-shadow lifecycle/reference checks and the relevant existing GI
   MultiMesh, metadata, deformation and runtime-options checks. Compare output
   against the preserved baseline. Run appropriate repository hooks.
6. Record executable hashes, sample conditions, invalid runs, limits, results
   and implementation contracts. Keep a change only with correctness evidence
   and a defensible performance benefit. Leave publication/desktop replacement
   for an explicit request.
