# RT CPU preparation acceptance

`lifecycle/` is a standalone deterministic hard-shadow fixture. Run the preserved
baseline and candidate with `run_lifecycle.py`, then compare their output folders
with `score.py`. A Python environment with Pillow and NumPy is needed for scoring.
The runner isolates user data, rejects engine errors, requires every stage, and
times out only its own child process. It does not alter a user game.

```text
python run_lifecycle.py --engine <baseline.exe> --output <new-baseline-folder>
python run_lifecycle.py --engine <candidate.exe> --output <new-candidate-folder> --env <oracle>=1 --require-marker <oracle-success>
python score.py <baseline-folder> <candidate-folder>
```

The fixture disables GI, screen-space shadows, antialiasing and the RT shadow
denoiser, and uses zero-size light emitters. Every corresponding image must be
pixel-identical. Separate shadow-eligibility controls must visibly change the
image, preventing acceptance of a fixture with no working traced shadows.

Coverage includes repeated/shared mesh and MultiMesh sources, unchanged frames,
per-instance and per-element transforms, bulk buffer writes, different shared
MultiMesh parents, visible count, same-resource buffer layout reallocation,
folded masks, surface material caster eligibility, directional scatter policy, moving lights/camera, local-only
lighting, same-buffer vertex edits, source buffer replacement, empty/repopulated
shadow structures, two independently changing viewports in one frame, and source
free/recreation. No ray-tracing algorithm or quality option changes between builds.

Pair this with the existing `shadow_validation` geometry/deformation and GI scene
metadata fixtures. Those cover compressed/nonindexed/index-width geometry,
current posed buffers, deferred geometry, materials and GI metadata. Native RD
submission validation must additionally compare packed instance bytes, unique
graph tracker membership and both directions of BLAS/TLAS dependency links.
Scene-level image tests cannot directly create inactive native instance slots or
malformed RD requests; those require internal API tests or source-level review.

CPU benchmarks are separate: never include readbacks, cache reconstruction
oracles, per-frame diagnostic logging or shader warmup in timed samples. Preserve
the same executable/settings/content identity and exclude competing process
windows. A measured CPU benefit does not justify stale geometry or skipped graph
dependencies.

## External design constraints

The [Vulkan acceleration-structure specification](https://docs.vulkan.org/spec/latest/chapters/accelstructures.html)
requires referenced BLAS objects to remain valid when a TLAS is accessed, input
buffers to remain available throughout device execution, and explicit ordering
between dependent BLAS and TLAS builds. CPU caching does not relax these rules.
The existing safe mapped-buffer reservation and graph dependency registration
must therefore remain on every submitted build.

Industry optimization guidance is linked in the accompanying implementation plan.
Reusing validated static CPU data does not imply that GPU refitting, reduced
caster coverage or different geometry are safe substitutes.
