# Retain unchanged GI scene groups

Status: implemented and validated; see [measured results and limits](RESULTS.md).
This is an integration optimization; AMD GI lighting, material evaluation and
sampling algorithms stay unchanged. Fully changing scenes can pay additional
reconstruction overhead and need separate performance validation.

## Evidence and target

The controlled 2026-10-26 diagnostic measured approximately 2.29 ms in the GI
instance loop with 16,198 inputs / 16,528 accepted surfaces. The paused scene had
zero changed material contexts, hit records, transforms or TLAS records across
120 updates. It contained 12,121 MultiMesh elements from 2,693 parents, 1,032
unique geometry preparations, 332 materials, 996 layouts and 715 attributes.
Existing caches already refresh each shared source once per update. The remaining
target is repeated per-element construction and checking, not another cache of
individual arithmetic expressions. The measured loop is an upper bound, not a
promised saving; shared-resource validation still has to run.

## Design reviewed before implementation

Retain the existing dense material Context, HitData, AS instance, geometry
revision, emitter batch and emissive range arrays. Each update uses cursors. A
matching unchanged group advances those cursors without reconstructing or copying
its records. A changed group runs the existing complete preparation and replaces
its dense slots. Arrays are truncated after traversal. Membership/order changes
invalidate downstream reuse through group identity and dense offset comparisons.

A group is one ordinary input or a complete collector-produced MultiMesh parent.
The collector stamps complete expansions with a globally monotonic generation
and first-element count. Generation changes when the expansion is rebuilt for
rendered buffer revisions, parent transform, mesh, bounds or count. Its global
identity cannot repeat when parent expansion storage is destroyed and recreated.
Zero or incomplete generation/count metadata takes the complete path. The
generation does not replace current masks, materials or instance uniform offsets.

For each candidate group, compare full input RIDs, first element, count,
generation, transform, material override/surface overrides, masks and uniform
offset. In original first-use order, refresh each shared current geometry and
native source-material/layout resource. Compare full geometry snapshots, material
identity, shader presence/code, `next_pass`, and the resulting base Context.
`next_pass` is explicitly polled because it can change without the material
content revision. Region writes are polled through current mesh data revisions;
current posed buffers/revisions and BLAS rebuild revisions are also compared.

Numeric material uniforms and texture index buffers continue updating. Native
`TIME` still updates the frame header, global/instance uniforms still use live
buffers, and `set_as_used()` keeps offscreen render-target textures live. The
unique refresh path touches all retained material/layout/attribute resources for
pruning. Texture discovery occurs in the original first-use order, preserving
dense texture indices. No evaluated lighting or material color is cached.

Source-mode emitter records contain geometry and source IDs, not evaluated
emission. Retain them only when the group's dense surface start, emitter batch
start, triangle prefix and emissive-sampling state all match. Compare full batch
and range contents in the oracle, including range first/count fields that its
ordinary identity operator excludes. Sampling changes or earlier emitter
membership/count changes reconstruct affected offsets; GPU `update_emitters`
behavior and per-frame native emission evaluation stay unchanged. Exclusion-report
and motion-history diagnostic modes use complete traversal; ordinary
timing/statistics do not disable reuse.

Shader identity checks first compare owning COW String storage, avoiding repeated
scans of unchanged source text per group. Different allocations still use full
content equality. The retained owning String keeps that allocation alive, and
native String writes detach shared storage; raw shader pointers are not retained.

Before mutating dense arrays, invalidate retained metadata. Publish new metadata
only after the complete scene, uploads, TLAS and emitter preparation succeed.
Any failure requires full reconstruction on the next update, so partial records
cannot become a reusable scene. Existing readiness suppression is preserved.

## Adversarial checks and validation

Review required full RID/generation identity, explicit parent metadata, native
first-use ordering, default/null material behavior, complete cursor truncation,
failed-publication protection and oracle coverage of actual retained subjects.
The source-material retain operation returns failure rather than letting an
invalid range advance only some of the parallel arrays.

- `GODOT_AMD_GI_DISABLE_RETAINED_GROUPS=1`: full preparation bypass.
- `GODOT_AMD_GI_TRACE_RETAINED_GROUPS=1`: actual reused/oracle group, surface,
  emitter batch and triangle counts, plus emission-containing groups that still
  needed reconstruction.
- `GODOT_AMD_GI_VALIDATE_SCENE_CACHE=1`: candidates run full current reconstruction
  and compare retained Context, HitData, every AS field, geometry revision,
  EmitterBatch, EmissiveRange and dense counts before overwrite. Existing uncached geometry/layout checks and GPU
  upload comparisons remain active. Per-group oracle logs include full instance
  RID so fixture coverage cannot be satisfied by an unrelated static floor.

Use both original emissive and nonemissive metadata-fixture subjects, plus
emission and emissive-sampling on/off transitions. Require actual emitter reuse,
not just floor/other nonemissive reuse. Required coverage includes independent material
and next-pass changes, region writes, mesh-buffer replacement, MM colors/custom
data/count/bulk/reallocation/interpolation, parent transform/base-type changes,
multiple viewports, resource free/recreation, growth/shrink and preparation
failure/recovery. Deformation and material-binding lifecycle fixtures supplement
it. Parent agent owns all builds and runtime passes.

Benchmark the preserved baseline, scene-only candidate and combined changes in
coordinated quiet windows, with actual reuse coverage. Report measured CPU render
and preparation spans; do not sum the temporary sampled timer estimates or treat
them as exact savings.
