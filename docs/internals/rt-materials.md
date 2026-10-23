# Raytraced GI material preparation

This describes the native material-capture primitive shared by
[AMD GI](../features/amd-gi.md) and the opt-in
[transport validator](../features/rtgi-validation.md). It is independent of their
lighting and denoising algorithms.
Overall status and remaining work are in [../AMD_GI_IMPLEMENTATION.md](../AMD_GI_IMPLEMENTATION.md).
Shared acceleration geometry is described in [rt-shadows.md](rt-shadows.md).

## Why a native material pass

A ray-query hit identifies geometry and barycentrics; a shadow only needs visibility.
GI also needs surface properties, including off-screen textures and emission. Those
properties are not stored in a BLAS. Copying a few StandardMaterial3D parameters
would omit custom shaders and many material inputs.

`RendererRD::RaytracingMaterialCapture` evaluates a surface through the Forward+
material shader variant already used by Godot's baking tools. The output comprises
albedo/alpha, encoded normal, occlusion/roughness/metallic/SSS, and HDR emission.
It does not evaluate direct or indirect lighting. This primitive is independent of
the eventual GI algorithm and does not create an acceleration structure.

GI scene captures request the underlying geometry normal, before normal-map application, as required by GI-1 hit shading. The standalone material-bake diagnostic retains the shaded normal by default. Normals use Forward+'s existing best-fit encoding. Decode with
`normalize(encoded.rgb * 2 - 1)`, not just `encoded.rgb * 2 - 1`. The captured camera
transform is identity, so these normals include the supplied object's world transform.

## Page representation

The caller selects a surface, starting triangle, triangle count, tile size, transform,
and optional material override. A page contains at most 1024 triangles, at most 32
columns, and square tiles of 2 pixels or from 4 to 64 pixels. Counts clip to the remaining surface
triangles. Indexed triangles are expanded into a temporary non-indexed mesh while
preserving native packed source attributes. `rt_material_expand.glsl` expands the
selected index range directly from GPU vertex/normal, attribute, skin, and index
buffers. The native material vertex shader decodes compressed attributes as usual.
Original vertex IDs travel in a separate SSBO; no source-buffer readback occurs.

Triangle `i` occupies tile `(i % columns, i / columns)`. Its corners, relative to the
tile origin, are `(1, 1)`, `(tile_size - 1, 1)`, and `(1, tile_size - 1)` in pixel-edge
coordinates. For barycentrics `(u, v)` corresponding to the second and third corners,
the continuous position is `tile_origin + 1 + (tile_size - 2) * (u, v)`.
For the compact 2-pixel fallback, corners are `(0,0)`, `(2,0)`, `(0,2)`;
the hit sampler always selects pixel `(0,0)`, at barycentrics `(1/4,1/4)`.
This retains one native material sample per triangle, with reduced texture,
cutout, and smooth-normal detail. It never drops geometry.
Rasterization samples pixel centers. Uncovered texels remain clear: there is no
edge dilation or mip generation. The ray-hit sampler clamps/folds barycentric
addresses to covered texel centers; ordinary bilinear sampling across tile edges
would read another triangle or clear padding.

The output attachments are three RGBA8 textures and one RGBA16F texture, plus R32F
and depth attachments needed by the existing material pass. At the largest allowed
page, the six attachments occupy approximately 112 MiB before driver overhead
(2048 squared texels times 28 bytes, arithmetic only). This bound is not a sensible
per-mesh default or a total cache budget. The GI adapter uses fixed 1024-triangle
chunks, adaptive tile sizes and an unused-capture residency budget of one quarter
of the atlas limit, with a 120-update age limit. Active source geometry and capture
targets remain separate allocations and belong in total memory measurements.

## Renderer and lifetime contract

- Construction allocates nothing. `capture()` replaces previous resources; `clear()`
  and destruction free the framebuffer, textures, SSBO, and temporary mesh.
- Internally, `prepare()` builds reusable expanded geometry and capture targets;
  `render()` evaluates the current material, transform, textures, and instance
  uniforms into them. The GI scene packs captures into demand-allocated atlas layers
  bounded by `amd_gi/material_atlas_mb`. It re-prepares a page when its source mesh/surface/triangle
  range, immutable vertex-buffer RID, or mesh data revision changes, and frees
  excess pages when the scene shrinks. Pose changes do not re-prepare geometry.
- Call only on the rendering thread, before preparing the frame's render lists.
  Capture uses the secondary render list and the renderer's material-bake state.
- `get_texture()` returns borrowed GPU handles; `readback()` synchronously copies
  four output images to the CPU. The public diagnostic
  `RenderingServer.bake_render_triangle_material()` captures, reads back, and releases
  its resources in one call. Frame rendering never calls that readback API; the
  opt-in validator uses the GPU capture class directly before scene render lists.
- Only Forward+ reports capture support. Other renderers return an empty array
  through the public API. The tested graphics API is Vulkan.
- Material capture uses descriptor set 4, bindings 0–1, only in `MODE_RENDER_MATERIAL`.
  Binding 0 has a 64-byte header: layout `uvec4`, instance color `vec4`, custom
  data `vec4`, and instance information `uvec4`, followed by 32-bit source vertex IDs.
  Binding 1 borrows the current native pose buffer, or a dummy buffer for static
  captures. The first vector stores tile size, columns, source vertex count, and
  normal/tangent/pose presence bits and bit 3 selecting geometry-normal output. Scene flag
  bit 9 selects triangle placement; regular UV2/projection baking binds an existing
  dummy buffer and does not read it. Ordinary scene shader variants have no new set.
- UV0 and UV2 remain material inputs. Atlas placement must never overwrite them.
  Shader `VERTEX_ID` refers to the original mesh; internal placement uses the
  expanded mesh's `gl_VertexIndex`.
- Pending material updates are flushed before the draw. The surface's default
  material must be queried with `mesh_surface_get_material()`; geometry readback
  does not populate `SurfaceData.material`.

## Limits before integration

Preparation now uses metadata-only mesh accessors, GPU expansion, and native
material rendering. The public `SurfaceData` readback/CPU decode path is no longer
used by `prepare()`. The standalone diagnostic API still reads capture outputs.

Active captures retain their atlas placements. New captures fill free intervals; only fragmentation or a tighter budget triggers compaction. Source chunks stay fixed at 1,024 triangles, independently of packed atlas offsets.
Packing changes copy rows across atlas layers without preparing expanded geometry
again. Unused captures survive for up to 120 scene updates, subject to an LRU
unused-residency budget of one quarter of `material_atlas_mb`; active captures are
retained. This bounds inactive native targets/expanded buffers separately from the
packed atlas. It does not make active capture memory equal to the atlas budget.

A metadata-only preflight counts unique material keys before capture begins.
`material_adaptive_resolution` (default on) reduces the selected 8/4-pixel maximum
to 4 or 2 as necessary to fit the atlas budget. Reduced resolution remains in use
until the scene consumer is recreated or its size/budget/adaptation setting changes;
visibility changes cannot alternate capture resolutions each frame. If even the
compact representation cannot fit, preflight reports the limit without repeatedly
preparing an incomplete scene. The source [gameplay audit](../AMD_GI_GAMEPLAY_AUDIT.md)
records the former behavior at commit `3038a14`.

Vertex/index/attribute/skin region edits advance the mesh's data revision;
vertex/index edits also invalidate shared BLAS geometry. Surface replacement is
detected through the shared geometry build revision. Attribute-only edits do not
force BLAS reconstruction.

Material pixels now persist for materials with local uniforms and tracked image
textures. Material/shader updates advance a content revision. Image-backed 2D,
layered, and 3D texture uploads advance texture revisions; proxy lookups follow the
actual owner and compare the backing GPU RID as well as the revision. Replacement,
material rebinding, source-data edits, and model-transform changes invalidate the
page. Only dirty pages render and copy into the hit atlas.

TIME, global/instance uniforms, viewport textures, drawable textures, and external
GPU textures retain per-frame evaluation because their values are not covered by
that static content contract. The other pages remain cached. The dirty-material
rig verifies image updates in place, emission parameters, shader changes, TIME and
global uniforms. Bounded preparation work per frame, higher material resolution,
and further capture-memory reduction remain work.

The public API takes a mesh, not a scene instance. It does not apply skeleton poses,
blend shapes, instance uniforms, MultiMesh colors/custom data, or particles. The
internal entry point receives an instance-uniform offset, optional mesh instance,
and MultiMesh element color/custom data/ID. These are applied at the same point
as native instancing before material evaluation.
It reads the native GPU skeleton/blend-shape output before material evaluation: float3
positions followed by packed octahedral normals/tangents. Original UV/color/custom
inputs still come from the retained source mesh. No second skinning pass or pose
readback is performed. Godot importers disable attribute compression for these
meshes; manually compressed pose buffers are rejected. Four/eight-weight skeletons,
combined blend shapes, and FSR2 pose-buffer swapping have a separate deformation rig. Vertex shader code runs, including the provided model
transform, but this does not prove correspondence with deformed RT geometry.

There is no scene camera or scene screen texture in this pass. Camera-dependent,
screen-reading and multipass hit materials are unsupported. Forward-only transparency
stays in rasterization; depth-writing mix-alpha materials use stochastic coverage.
TIME-driven fragment shading refreshes each frame. The shared GI query forces
non-opaque candidate processing while retaining the same opaque BLAS used by RT
shadows. Cutouts use captured alpha; fractional blend coverage uses a stochastic
acceptance test. Texture/cutout fidelity is limited by the material tiles.

Fixed tiles can undersample material detail. The adapter captures the bounded
camera-centered GI collection, sharing compatible instances, rather than the entire
world. The live preparation budget limits new chunks per scene update; a partial
scene is never published as ready.

## Validation

Run `docs/validation/shadow_validation/run.sh material` under Vulkan. The rig checks
analytically known outputs for indexed/non-indexed and compressed geometry, original
UVs and vertex IDs, custom attributes, tangent-space normals, transforms, material
and texture updates, cutouts, range clipping, and existing UV2 baking. It exits
nonzero on any mismatch. This is a correctness test, not a GI performance benchmark.

Also run the geometry image regression when modifying shared scene shaders or
renderer setup. It verifies that the exercised normal shadow-rendering path remains
unchanged while no capture is requested. Hardware timing and resource accounting
remain necessary for an eventual zero-cost-when-disabled GI backend claim.


The GI adapter packs capture chunks into 32-triangle rows across its atlas layers.
The source captures keep their own pixels; moving a packed address requires only
an atlas copy. Fixed source chunks are independent of atlas placement. A chunk's
first triangle and requested count both participate in preparation invalidation;
only source range changes rebuild expanded geometry.
The `amd_gi_atlas` rig covers relocation and surfaces spanning multiple layers.

## Shared captures

The GI adapter keys capture pages by mesh, surface, material, pose and (when
required) instance/element context. Conservative shader input tracking permits
identity-transform evaluation only for transform-independent materials without
normal/tangent inputs or instance uniforms. Their captured normals are local;
HitData.triangles bit 31 marks inverse-transpose transformation at a ray hit.
World-dependent captures keep world normals. HitData remains 16 bytes.

Atlas resize preserves existing layers before releasing the old textures, with
both allocations briefly live. Lowering the budget invalidates addresses in removed
layers. Allocation grows on demand; expanded capture targets and geometry are
outside the atlas setting and must be included in total memory measurements.
CPU-managed MultiMesh collection uses visible counts, element bounds, stable
instance/element ordering, and the existing shared mesh BLAS. GPU-indirect data
and particles cannot use this CPU collection contract.

Forward-only transparency is selected using the native shader predicates:
`uses_alpha_pass()`, no `uses_depth_in_alpha_pass()`, no always-depth draw, and no
material shadow casting. Only a single-pass surface can be excluded this way.
This avoids capturing presentation-only shells or treating them as opaque blockers;
opaque vertex deformation remains unsupported. Depth-writing mix-alpha materials
now use the captured alpha for stochastic coverage in GI ray queries. This retains
opaque portions of imported mixed-opacity meshes without making glass solid.
It does not implement refraction or tinted transmission.

The GI adapter exposes 4/8-pixel triangle tiles separately from the native capture
API. Four-pixel tiles use 128×128 array layers and one interior triangle sample;
8-pixel tiles retain more barycentric detail. This is a material/normal fidelity
tradeoff, not a lower geometry LOD or a different diffuse ray budget. Captures with
identical non-white instance colors can share when their other inputs are context
independent; exact color joins the material-cache key. Changes in live tile size
release/recapture the atlas and advance history revision.
