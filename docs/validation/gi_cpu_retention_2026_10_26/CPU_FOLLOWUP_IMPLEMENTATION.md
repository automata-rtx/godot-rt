# CPU follow-up: source-reviewed implementation

2026-10-26. All three candidates from [the measured cost breakdown](REMAINING_CPU.md)
were planned and independently reviewed before implementation. The owner prohibited
new benchmarks. The agent performed no Godot/game runs for these changes. The
owner subsequently tested the delivered build and reported that it works,
authorizing publication. This is user smoke-test acceptance, not a repeated
regression suite or performance measurement. Prior timings remain comparison
baselines, not results for this build.

## Decisions and implementation

1. **Shared source preparation**, targeting the 1.21–1.25 ms group loop. Memoize
   successful base material Contexts by full material RID, mesh RID and surface
   index for one scene-update epoch. The first use still performs native resource
   refresh, texture ordering and mesh-region polling. Instance color/custom data,
   element and uniform offset are applied afterward. Failures are never cached;
   subsequent epochs refresh before reuse and unused entries are pruned.
2. **Known changed ranges**, targeting about 0.38 ms of dense comparisons.
   Coalesce reconstructed surface/emitter group ranges; compare those against
   each consumer's last successful snapshot. Retained ranges already proved
   unchanged need no second scan. Context writes separately accumulate a pending
   interval that survives aborted preparation and failed uploads. Count changes,
   buffer replacement, disabled retention and recovery use conservative checks.
   TLAS structure and transform comparisons share a pass, but queued builds still
   receive the whole input and retain distinct in-flight upload storage.
3. **Collected MultiMesh inputs**, targeting the 0.42–0.44 ms collection stage.
   Keep the existing dense vector with a write cursor. Complete unchanged parent
   blocks advance that cursor without copying every child. Eligibility and shared
   material/mask/uniform inputs remain current; a globally unique expansion
   generation proves child transforms/bounds/count. Changed inputs overwrite,
   and the final vector trims before downstream use. No second collection cache.

These changes concern Godot CPU bookkeeping. AMD sampling, shader work, quality
settings, synchronization and update frequency are unchanged.

## Adversarial findings

All three plans and final patches received an independent source review with no
remaining correctness blockers. Specific risks addressed:

- A prior partially failed scene cannot justify skipping comparison against GPU
  state: group metadata becomes valid only after complete successful preparation.
- A buffer replacement or resized dense prefix cannot inherit an old upload
  proof. Context pending writes reset only after successful upload/publication.
- A Context cache key cannot include only material or only mesh. Full combined
  identity is required, and per-instance fields must remain outside the cache.
- A MultiMesh block cannot be accepted solely from its first child's transform.
  It must be complete, begin at element zero, occupy the untouched suffix and
  carry the current expansion generation and shared inputs.
- The legacy non-AMD collection path keeps its bounded overflow behavior;
  collection counters use the current cursor, not retained vector capacity/size.

The combined-key cache adds miss/insertion/pruning overhead. Existing marginal
material/layout counts do not establish its exact hit rate. Runtime inventory
was deferred because runs are prohibited, so no saving is promised. Stable group
metadata COW copies were left alone: their measured cleanup cost is small and a
more complex ownership rewrite lacks demonstrated value. All three candidates
have useful implementations without that additional rewrite.

## Verification and future comparison

Windows release-style editor compilation and repository source hooks passed.
An offline Context state model passed 12,000 deterministic updates, including
3,944 injected preparation/upload failures and 9,621 full-difference comparisons.
This models bookkeeping; it does not execute the engine or establish runtime or
visual correctness. Local build log, source hashes and identity:
`.artifacts/gi-cpu-ranges-20261026/`.

Editor SHA256:
`2497553bf8097ce6e71e76d9651782b7bd4a6601d39d03b2e3228d2c28918340`.

When runs are authorized, existing metadata, retained MultiMesh/light-storage,
deformation and resource-lifecycle fixtures remain the targeted checks. The
existing `GODOT_AMD_GI_VALIDATE_SCENE_CACHE=1` now additionally reconstructs cached
Context hits and compares optimized Hit/TLAS/refit/emitter decisions with complete
CPU scans. Its collector oracle still checks every child's semantic output.

Future same-binary comparison controls (set to `1`):

- `GODOT_AMD_GI_DISABLE_PREPARED_CONTEXTS`: reconstruct each base Context.
- `GODOT_AMD_GI_DISABLE_CHANGED_RANGES`: use full Context/scene record comparisons.
- `GODOT_AMD_GI_DISABLE_INPUT_REUSE`: emit all collected input records.
- `GODOT_AMD_GI_TRACE_PREPARED_CONTEXTS`: count calls, hits and unique successful
  combined keys per completed update; this diagnostic is not a timing result.

Retain the previous measured `fc2b5242...` build for later comparisons. The legacy
material-response scorer's baseline failure remains unresolved; prior fixture
passes do not certify these new changes. The owner approved committing and
pushing after testing. The desktop installation remains unchanged.
