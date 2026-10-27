# GI CPU retention and dependency preparation

Completed implementation and targeted validation: [results and limits](RESULTS.md).

The approved work removes redundant Godot adapter CPU work while preserving
AMD GI 1.2 transport, lighting coverage, ray counts, temporal behavior and update
frequency. The starting executable includes the preceding local CPU/GPU work on
top of `66bd97e00d`; its SHA-256 is
`a4a921ed54aa6ee0e6e38e1df649ea17631c7f616dce9b9aac78a11d3492a0cf`.
Existing documentation and source changes in the working tree are preserved.

## Evidence and scope

The isolated Live World snapshot contains 16,198 GI inputs and 16,528 accepted
surfaces, including 12,121 MultiMesh elements across 2,693 parents. In the paused
diagnostic window, 120 consecutive updates change no Hit, material Context or
TLAS records, but the scene loop still costs about 2.29 ms. Live windows change
roughly 108–121 Hit records per update. These are instrumented diagnostic values,
not promised savings; sampled inner timers substantially perturb their own work.

The default GI pipeline registers 37,512 source-buffer reads per render through
12 geometry/material sweeps. The diagnostic run attributes about 1.66 ms to these
sweeps; the ordinary executable's complete GI command span is about 1.63 ms, so
the instrumented sweep value cannot be presented as recoverable clean-build time.

1. [Scene retention](SCENE_PLAN.md): retain complete stable parent/surface groups,
   refresh current unique resources, and rebuild only groups whose inputs change.
   Original processing remains the correctness fallback.
2. [Command preparation](COMMANDS_PLAN.md): resolve source-buffer owner kinds
   once per GI render, then use typed full-RID lookup and current transfer/graph
   tracking at every original read site. No raw resource pointer survives a call.

AMD reference `914b91596cd119eda85fbc1d3c7ee6ac391b1452` retains instance/material
descriptions between relevant changes. It still visits all transforms when any
transform changes and does not support independent material changes. Sparse Godot
group retention is an adapter improvement, not a claim about AMD's exact behavior.

## Review and execution order

- Separate owners implement scene/material retention and RD/command preparation.
  A third agent reviews both plans and implementations adversarially. The parent
  owns integration, compilation, all runtime execution and benchmark coordination.
- Preserve a clean starting executable and source snapshot. Build diagnostic
  instrumentation separately and restore production sources/executable afterward.
- Collect current baseline and diagnostic runs in a Game Director quiet window.
  Release it during implementation and ordinary correctness work. Obtain another
  confirmed window before timing comparisons; do not overlap engine builds/tests.
- Add actual fast-path reconstruction oracles and independent bypass controls.
  Validation must exercise retained candidates rather than force all work through
  the fallback merely because an oracle is enabled.
- Build optimized editor; run targeted GPU/material/lifecycle tests. Fix failures
  before comparing performance. Test the new internal RD helper on actual GPU
  work through an opt-in native fixture, without adding a script API for testing.
- Compare both enabled with each optimization independently bypassed. Repeat clean
  baseline/final captures and retain all results, including noisy/outlier runs.
- Update implementation/porting notes and record exact executable hashes, test
  completion assertions, image comparisons, performance distributions and limits.

## Acceptance requirements

Scene retention preserves full RID identity, dense surface ordering, live local/
global/instance uniforms and TIME, texture-use notifications, material eligibility,
mesh-region revisions, posed geometry, masks, MultiMesh rendered interpolation and
buffer changes, source replacement, multiple viewports, and failed-preparation
recovery. Caches publish reusable metadata only after successful preparation.

Command batching preserves every pass dependency and existing barrier, current
upload-transfer handling, storage/indirect merged access, resource destruction and
replacement checks, and device isolation. A preparation/replay error cannot proceed
to dispatch with incomplete dependencies. No cross-frame pointer cache is added.

Validation routes include scene metadata, MultiMesh, deformation, descriptor
lifecycle, source-material changes, light/emitter behavior, and actual buffer-read
GPU dependencies. Extend fixtures for missing cases rather than claiming existing
fixtures cover an internal method they never call.

Benchmark conditions: frozen project revision
`0361687daec58ed8709971962f6ab693519d7378`, grass off, 1280×720 window, DLSS Quality,
fixed view, isolated user data, 62 simple-body NPCs, live and paused phases. Game
source/assets and desktop editor are not changed by this task. CPU spans measure
rendering timestamps, not total game simulation; CPU/GPU times overlap.

The initial two clean baseline medians vary (6.594 and 5.993 ms rendering CPU).
No monitored competing process appeared, but this is not proof of zero system
interference. Use repeated comparisons and final-executable bypass controls;
do not select only the slow baseline or discard unfavorable runs.
