# CPU follow-up benchmark and desktop delivery

2026-10-26, after user acceptance and publication of `05983ca524` to
`feature/amd-gi` and `master`. The owner authorized these benchmarks and desktop
replacement separately from the earlier source-only implementation work.

## Controlled comparison

Four serial runs in baseline/candidate/candidate/baseline order completed in
188 seconds. Game Director explicitly acknowledged a quiet window and held its
and its specialists' heavy tests until explicit release after the fourth run.
The session inventory showed no other active local task outside this task and
Game Director. No competing Godot/compiler process was observed in the recorded
measurement windows. This is bounded process monitoring, not a guarantee that
every background OS activity was absent.

Same frozen Live World snapshot as the earlier profiling: project revision
`0361687daec58ed8709971962f6ab693519d7378`, 62 NPCs, grass off, 1280x720 window,
DLSS Quality (853x480 internal), fixed camera/seed/simulation delta, uncapped
presentation, RTX 5090 and Ryzen 7 7800X3D. Each run measures 480 live and 480
paused samples after warmups. Screenshots occur after timing. Isolated user data
and frozen project inputs avoid concurrent game-source changes. All four runs
exited successfully and preserved the snapshot's project settings hash.

Median times in milliseconds:

| Run | Live rendering CPU | Scene/AS preparation CPU | GI commands CPU | Live GPU frame | Live wall frame | Paused rendering CPU |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Baseline 1 | 4.411 | 3.047 | 0.755 | 3.157 | 6.732 | 3.817 |
| Candidate 1 | 3.434 | 2.101 | 0.735 | 3.153 | 6.497 | 3.056 |
| Candidate 2 | 3.475 | 2.132 | 0.746 | 3.153 | 5.783 | 3.110 |
| Baseline 2 | 4.120 | 2.776 | 0.746 | 3.149 | 6.388 | 3.671 |

Against the faster baseline, rendering CPU improves **15.7–16.7%** (0.645–0.686 ms),
and scene/AS preparation improves **23.2–24.3%**. Paused rendering CPU improves
15.3–16.8%. Candidate live rendering CPU p95 is 3.837–3.893 ms versus 4.536 ms
for the faster baseline; baseline 1 was noisier at 6.561 ms.

GPU time is effectively unchanged. Overall wall-frame results vary substantially
more than rendering CPU: candidate medians span 5.783–6.497 ms versus baseline
6.388–6.732 ms. Do not translate the rendering CPU reduction into an equal FPS
increase, add overlapping CPU/GPU spans, or extrapolate this scene to every level.
The scene/AS label includes collection, shadow preparation and GI preparation;
it is not pure TLAS build time. No per-candidate bypass runs were performed, so
these results establish the combined benefit, not individual contributions.

Baseline 2 and candidate 2 live screenshots were inspected: no noticeable visual
change in this view. This is not exhaustive material/reflection acceptance or a
replacement for the targeted mutation/lifecycle regression suite. No additional
source optimization was made during benchmarking.

## Identity and delivery

Baseline SHA256:
`fc2b5242d2f9ab670e0b25c6b616653294118a50c13153e9a7243db62be25569`.
Candidate SHA256:
`2497553bf8097ce6e71e76d9651782b7bd4a6601d39d03b2e3228d2c28918340`.

The candidate is the exact owner-tested binary, built before the publication
commit, so its embedded revision need not equal `05983ca524`. It replaced
`C:/Users/Andrew/Desktop/GodotRT/godot.windows.editor.x86_64.exe` and its installed
checksum was verified. The previous shutdown-tested editor remains beside it as
`godot.windows.editor.x86_64.exe.before-cpu-followup-20261026-203324.bak`.
The older separate GodotRTGI shortcut installations were not replaced.

Local evidence: `.artifacts/gi-cpu-ranges-20261026/desktop-install.json` and
`benchmark/`: harness, snapshot identity, driver logs, per-frame JSON, run
manifests, summaries and screenshots. `run_comparison.py` records the four-run
order; `comparison.json` preserves complete summary statistics. The live
fps-proto project was not edited by this task. The quiet window is released and
all owned benchmark processes have exited.
