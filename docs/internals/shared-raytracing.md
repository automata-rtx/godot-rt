# Shared RT foundation — required by shadows and AMD GI

Read this before either feature's implementation guide. This is one shared
foundation, implemented once, with two distinct scene consumers. Source review:
2026-11-06, `b3c0262131` plus working changes. See [porting coordination](../PORTING.md).

## Ownership and boundaries

| Component | Owner / source | Consumers and constraints |
| --- | --- | --- |
| Geometry allocation and revisions | `storage_rd/mesh_storage.*` | Static, compressed and posed upload buffers; both clients need current legal AS inputs |
| BLAS cache and dequantization | `environment/rt_geometry.*` | One cache owned through `RaytracingScene::geometry`; GI borrows it, never constructs a second cache |
| Update coordinator | `renderer_scene_render_rd.cpp::update_raytracing_scene` | One begin/end scope encloses shadow update, GI update or suspension, and GI-only release |
| MultiMesh expansion | `renderer_scene_cull.*`, `InstanceGeometryData::rt_multimesh_expansion` | Shared value cache; each client still applies its own current eligibility |
| GPU AS and dependency APIs | `servers/rendering/rendering_device*`, Vulkan backend | Shared native packing, lifetimes, upload storage and synchronization; distinct TLAS handles |
| Depth/motion/normal attachments | Forward+ renderer and scene shader | One coordinated layout consumed by shadows, GI, contact shadows and temporal upscalers |

Abbreviated `environment/`, `storage_rd/`, and renderer files are under
`servers/rendering/renderer_rd/`; the culler is under `servers/rendering/`.
These are integration ownership boundaries for a port, not separately duplicated
libraries. Coordinate edits to the shared files before merging feature work.

## Startup and update order

The RT master is latched at startup. MeshStorage uses it with device capabilities
to choose legal buffer usage. AMD GI's live enable cannot retrofit missing usage
flags. Preserve this prerequisite even if the first ported feature is GI.
The current code locates the shared geometry owner inside `RaytracingScene`:
a GI-first port still needs that ownership/startup shell, not necessarily the
shadow filter/shading passes. Splitting that owner differently is a deliberate
architecture change requiring review, not an incidental feature implementation.

Current coordinator sequence:

1. Complete the gathered current poses, including GI-only offscreen non-casters.
2. `geometry.begin_update()` resets the one shared new-build budget.
3. Update shadow scene; request and copy shared surface records.
4. Update the GI scene using the same geometry reference; then request compatible
   material preparation. No ready GI scene means no valid GI draw.
5. An ineligible auxiliary view suspends GI scene use without destroying it.
   A truly empty/disabled GI scene releases its consumer and GI-only geometry.
   An idle pipeline compiler can remain alive while pending work retires.
6. `geometry.end_update()` performs shared eviction. GPU graph dependencies still
   order skinning, dequantization, BLAS/TLAS and ray-query reads.

Do not reset the shared budget between clients, treat global frame number as
the scene-update epoch, or consume a TLAS only because its RID remains valid.
Multiple views can update within a frame. Preserve the auxiliary-view suspension
path: an inventory preview must not discard the main view's GI resources.

## Shared geometry and lifetime

`RaytracingGeometry` owns BLAS and optional dequantized positions. It knows geometry, not visibility, lights or materials. Shadow and GI consumers have separate TLAS and metadata. GI enable/disable must not invalidate BLAS still used by shadows.

- Mesh upload and posed buffers require AS-build-input, device-address and storage usage as appropriate. `MeshStorage::_raytracing_buffers_required()` is gated by the RT master setting and device features. This is why the master switch requires restart and why AMD GI currently depends on it.
- A compressed position buffer is expanded into float32 XYZ by compute. Allocate its destination with **`vertex_buffer_create`**, including `BUFFER_CREATION_AS_STORAGE_BIT`, device address and AS-build-input flags. A storage-buffer RID is rejected by the RD BLAS vertex-owner lookup; a vertex buffer without storage usage cannot be written by the dequantization shader.
- Only nonempty 3D triangle surfaces are admitted. Indexed and nonindexed triangles work. Preserve index width and source format, including the 65,536-vertex index-width boundary.
- Static cache keys use full mesh RID and surface. Posed keys use full posed-buffer RID and surface, distinguishing instances and rotating buffers. Never replace full RIDs with local indices that lose generations.
- READY entries validate source buffer identity and `MeshStorage::Surface::geometry_revision`. Vertex/index-region edits advance that revision and rebuild even if the RID is unchanged. Old documentation claiming these edits remain stale is obsolete.
- A posed version change triggers a **full BLAS rebuild**, including dequantization when necessary. This is not a BLAS refit implementation. A successful build advances the exported surface revision used by downstream caches.
- New builds are limited to 64 surfaces and roughly 1,048,576 triangles per update. A single admitted surface can exceed the remaining triangle allowance; existing posed refreshes are not bounded by this new-build allowance.
- Entries unused for more than 60 shared updates are eligible for eviction; sweeps run every eighth update. These are update counts, not wall time. `release_gi_only()` promptly drops GI-only entries and preserves current shadow users.
- Borrowed `Surface` pointers expire on cache mutation. Copy required handles/fields before another lookup can mutate storage. Destroy owned expanded buffers and BLAS through their actual lifetimes; do not assume upstream buffer destruction leaves dependent AS handles usable.

The current skinned rebuild failure path warns that the old shadow can be stale. This is a remaining failure limitation, not a guarantee that every failed GPU preparation recovers atomically.

## Shared CPU submission reuse

`RenderingDevice::tlas_build` retains each TLAS's ordered full BLAS RIDs, native
instance inputs/packed bytes and unique graph trackers. An identical validated
BLAS order permits repacking only changed transforms, IDs, masks, flags or SBT
offsets. Every build still copies the complete input into its own reserved mapped
ring range and registers every BLAS graph dependency. Retaining CPU bytes does
not authorize reusing an in-flight GPU upload range or omitting synchronization.

`_blas_remove_tlas_dependencies` invalidates dependent CPU caches on both rebuild
and free, including same-RID rebuilds. Reconstruction validates all references
before publishing replacement weak links in both directions. Failure leaves the
cache invalid; no borrowed tracker/native address can be used until validation
succeeds. Clear CPU-only arrays before deferred GPU destruction copies the AS.
Frequent topology changes or posed BLAS rebuilds conservatively reconstruct the
cache; this optimization does not eliminate those workloads.

`GODOT_RT_DISABLE_TLAS_REUSE=1` restores original submission preparation;
`GODOT_RT_VALIDATE_TLAS_REUSE=1` compares every native byte, both weak dependency
directions and graph trackers against current owners. The native fixtures must
allocate BLAS inputs with both AS-build-input and device-address usage and verify
a nonzero address. See [acceptance and runtime fixtures](../validation/rt_cpu_optimization_2026_10_26/TESTING.md)
and [detailed submission notes](../validation/rt_cpu_optimization_2026_10_26/TLAS_REUSE.md).

## Device-address read groups

`RenderingDevice::buffer_read_group_prepare` publishes full RIDs with owner types
and the originating device's ObjectID only after validation succeeds.
`compute_list_add_buffer_read_group` revalidates handles and device-address usage,
checks current transfers, and resolves current draw trackers for each replay.
Keep every dependency on every consuming compute segment; a failed replay must
prevent the following dispatch. Never replace this with cached raw buffer pointers.
Storage and indirect argument uses in the same dispatch need combined access masks.

## Shared data does not mean identical rendering policy

| Decision | RT shadows | AMD GI |
| --- | --- | --- |
| Scene records | Shadow casters and folded eight-bit masks | Transport participants, native materials and full hit metadata |
| Alpha | Admitted triangles are opaque | Source opacity/culling evaluated on eligible candidates |
| TLAS update | Content-hash reuse or full build | Ordered comparison, skip, conditional transform-only refit or full build |
| Posed geometry | Full shared BLAS rebuild | The same rebuilt BLAS; not a second build or independent refit |
| Disable/cleanup | Own scene/effect lifetime | Release GI-only resources without evicting current shadow users |

GI-specific TLAS flags, material records and emitter storage belong in
[material/scene integration](rt-materials.md); shadow TLAS and light slots belong
in [RT shadows](rt-shadows.md). Preserve both policies on the common foundation.

## Attachment integration gate

The Forward+ pass enum, scene-shader versions, framebuffer formats, attachment
locations and samplers must be reconciled together. GI's eight-target motion
prepass also supplies the restricted contact-shadow caster slot. Previous-position
XYZ and camera-relative surface-plane W are different contracts; do not overwrite
W with an assumed constant. The plane-normal encoding must match primary-ray
projection, or moving black splotches can return. See [GI pass flow](amd-gi.md#per-view-data-and-pass-flow)
and [contact-shadow prepass](screen-space-shadows.md#amd-gi-prepass-integration).

## Acceptance before calling the foundation integrated

- Master off and unsupported-device paths retain native rendering.
- Same-buffer geometry edits, compressed/indexed/nonindexed meshes, posed buffers
  and ordinary MultiMesh updates reach both consumers in the same update.
- Shadows alone, shadows plus GI, GI disabled/re-enabled, empty scenes and an
  ineligible preview between eligible views preserve ownership and current output.
- Removing/recreating resources, failed preparation and pending shutdown cannot
  replay stale descriptors, graph trackers or instance upload ranges.
- Run AS upload/lifetime, indirect-storage and BufferReadGroup fixtures from
  [validation](../VALIDATION.md), then combined-feature image tests. A build or
  isolated feature test alone does not establish shared integration acceptance.

The current posed-BLAS refresh failure can retain stale geometry, as described
above. Preserve the limitation honestly; solving it is separate implementation
work, not a guarantee supplied by this documentation.
