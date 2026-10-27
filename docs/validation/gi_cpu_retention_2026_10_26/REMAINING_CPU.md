# Remaining CPU costs after scene retention

Focused profiling on 2026-10-26, authorized after the completed optimization
benchmarks. This is diagnostic evidence and a candidate ranking, not another
implemented optimization. Production source and editor were preserved unchanged.

## Findings

The largest remaining scene cost is validation/bookkeeping over unchanged scene
groups, not the live TLAS refit/build path or RT shadows. Pausing the scene leaves
most of that work running.

Coarse diagnostic scopes, means of three accepted aggregate blocks per phase:

| CPU work | Live, ms | Paused, ms |
| --- | ---: | ---: |
| GI group validation/preparation loop | 1.247 | 1.212 |
| GI input collection | 0.439 | 0.419 |
| Material Context scan/upload | 0.086 | 0.087 |
| Hit-record scan/upload | 0.098 | 0.097 |
| GI TLAS input comparison | 0.106 | 0.109 |
| Emitter-batch comparison | 0.091 | 0.090 |
| GI TLAS refit/build preparation and submission | 0.214 | approximately 0 |
| Changed-emitter dispatch preparation | 0.095 | 0 |
| Shadow collection plus shadow scene update | 0.274 | 0.186 |

These rows select distinct work but do not account for every renderer operation.
The separate GI wrapper takes about 2.07 ms live and 1.70 ms paused, **including**
the GI loop and subsequent GI stages above; it must not be added to them.

The profiler's `Update RT Acceleration Structures` label includes collection and
both shadow/GI scene updates. In this captured view its next timestamp is
`Render 3D Scene`. Work after the actual RT update adds only about 0.004 ms here;
the label boundary is broad, but unrelated post-RT work does not explain the cost.

GI command preparation is separately about 0.74 ms. Sampled detail attributes
about 0.36 ms to barrier/list finalization, 0.22 ms to the twelve source-buffer
dependency replays, and 0.09 ms to initial dependency-group preparation. Descriptor
preparation is about 0.012 ms; uniform-set cache lookup totals about 0.004 ms.
Another descriptor-cache micro-optimization has little budget in this view.

## Strongest next candidates

1. **Reduce repeated validation of shared surface sources and unchanged group
   metadata.** The 1.21–1.25 ms loop still visits 6,770 groups. It invokes source
   preparation 6,975 times per update although only 332 material refreshes and
   1,032 layout refreshes are required. Source validation is a lead to investigate,
   alongside group identity/geometry/metadata work. Fine samples cannot reliably
   apportion the loop because nested timer overhead differs. Explore one
   current-update prepared result per exact
   material/mesh/surface combination and less copying of stable group metadata.
   Preserve original first-use ordering and all current resource refreshes. The
   two marginal refresh counts do **not** establish the number of unique combined
   keys or an exact cache-hit rate; inventory those combinations before adding a
   new cache or promising a saving. Metadata scratch clearing alone costs only
   about 0.04 ms, so in-place metadata alone is not a demonstrated large win.
2. **Carry known changed ranges into the later record checks.** Context, Hit,
   TLAS and emitter comparisons cost roughly 0.38 ms even while paused, when all
   16,528 accepted surfaces are retained. Reuse the scene traversal's knowledge of
   changed groups so later stages inspect affected ranges instead of rescanning
   all records. Preserve full invalidation on reorder, count change and failed
   preparation. This concerns CPU comparison work; queued GPU builds still need
   distinct in-flight upload storage and correct whole-structure updates.
3. **Retain the collected GI input ranges.** Collection still clears and emits
   16,198 input records each update, including MultiMesh children whose transforms
   already come from cached expansions. The 0.42–0.44 ms collection phase is a
   separate opportunity to reuse unchanged parent ranges. Eligibility, masks,
   materials, transforms and viewport differences must remain current. Some
   traversal is still necessary, so the entire collection time is not recoverable.

These are code-specific opportunities with measured cost budgets. No additional
millisecond saving is established until implemented and compared. Each targets
Godot adapter bookkeeping; none requires fewer GI rays, delayed visible updates
or a change to AMD's lighting algorithm.

Barrier/list-finalization work is a secondary investigation: its roughly 0.36 ms
budget is real, but the calls enforce dependencies. The measurement does not
justify removing synchronization. Ordinary shadow preparation is also a lower
priority than the remaining GI loop in this particular view.

## Controls and interpretation limits

Same isolated Live World snapshot/settings as [the completed optimization
report](RESULTS.md): 62 simple-body NPCs, grass off, 1280×720 window, DLSS Quality,
fixed camera/seed/simulation delta. Game Director explicitly confirmed a quiet
window and received its release after all four serial runs. No monitored competing
engine/compiler process appeared in the measured windows. Settings hashes and
successful fixture completion were checked for every run.

| Run | Live rendering CPU median, ms | Paused rendering CPU median, ms |
| --- | ---: | ---: |
| Untouched production editor | 4.277 | 3.811 |
| Diagnostic editor, timers disabled | 4.165 | 3.763 |
| Coarse timings/counts | 4.075 | 3.553 |
| Coarse plus sampled scene detail | 4.466 | 3.866 |

Instrumentation and launch variation affect these totals. The lower coarse-run
time is not an optimization result. Coarse stage means provide the cost budgets;
fine samples identify likely subcomponents rather than exact recoverable time.
Nested source timings contain their own timer overhead. Do not multiply and add
them into an asserted frame total or subtract clock calibration as an exact fix.

Scene reports aggregate 128 successful updates; command/outer reports aggregate
120 calls. The analysis discards the first block of each report family in each
measurement phase to exclude pre-window work, then accepts three complete blocks.
Their intervals differ slightly, so means from different families need not sum
exactly. Command detail samples one fixed call parity in eight and can alias
periodic work; sampled-versus-unsampled differences are not pure clock overhead.
Scene group sampling rotates one in 32. Its source samples cover candidate
validation, whereas all-call counters also include reconstruction. Reported
calls/updates should not be generalized to unique engine frames or many viewports.

## Reproduction and preservation

Local artifact root: `.artifacts/gi-cpu-followup-20261026/`.
`build-manifest.json` identifies each original/instrumented source hash.
`runs/{production,probe-off,coarse,sampled}/` contains raw logs, per-frame timing,
captures, executable/project hashes and process monitoring. `analysis.json`
contains accepted aggregate blocks and means; `analyze.py` reproduces it.

The separate diagnostic executable has SHA-256
`2c36fa1411f2de3228230e9bf0465f1fe3c1f344c0fe349e33566fedfab98fa8`.
It is for profiling only. The production editor remained
`fc2b5242d2f9ab670e0b25c6b616653294118a50c13153e9a7243db62be25569`.
Build output was redirected into the artifact directory; temporary source/SCsub
changes were restored and the temporary header removed. The live fps-proto
project, desktop editor and production implementation were not modified.
