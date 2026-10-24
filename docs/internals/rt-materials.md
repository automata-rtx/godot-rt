# RT materials: current implementation map

Start with [AMD GI status/limits](../AMD_GI_IMPLEMENTATION.md) and
[approved boundaries](../AMD_GI_ADAPTER_DECISIONS.md). The complete old material
capture guide is preserved in [the archive](../history/AMD_GI_ARCHIVE.md#snapshot-rt-materials);
read it only when changing the legacy validator.

## AMD GI source materials

- `servers/rendering/renderer_rd/environment/rt_material_source.{h,cpp}` compiles native vertex/fragment material programs into GI compute helpers. Native material/global/instance uniforms, texture/sampler bindings and packed vertex attributes are inputs.
- `rt_gi_scene.cpp` collects supported surfaces/lights and reports omissions. `renderer_scene_cull.cpp` supplies scene instances and honors `GI_MODE_DISABLED`.
- Shared `RaytracingGeometry` supplies BLAS triangle positions/indices and posed geometry. Source attribute copies gain device addresses only on revisions; no CPU mesh readback or triangle material atlas is used for AMD GI.
- `rt_material_source_inc.glsl` reconstructs native material inputs at hits. Vertex outputs/varyings are interpolated. Geometry and shading normals remain distinct and transform once; the screen shading-normal path includes normal maps.
- `ShaderCompiler` has an opt-in affine coordinate analysis used by this consumer. Supported emitter mappings supply triangle-corner coordinates to AMD's existing footprint formula. Ordinary UV0 retains its helper. No additional rays, passes, buffers or full material invocations are added by this correction; hardware cost is unmeasured.
- Explicit authored texture LOD/gradient reads remain explicit. Vertex implicit reads use mip zero. Unknown emitter mappings warn and retain fallback filtering; raster-derivative shaders are omitted rather than receiving invented zero derivatives.
- Resource/shader initialization is gated by GI enable. Disable releases the source consumer resources. Compilation/first-use and target-hardware cost still need profiling.

`GODOT_AMD_GI_VALIDATE_SOURCE=1` enables diagnostic known-value readbacks; it is not
normal frame rendering. Source, mapped emitter, winding and deformation fixtures
are in `docs/validation/shadow_validation/`. See [validation](../VALIDATION.md).

## Legacy capture is a separate consumer

The uncached `rt_validation` integrator and standalone material-bake diagnostic
still use `rt_material_capture.cpp` / `rt_material_expand.glsl` and the capture atlas.
The `material_atlas_mb`, `material_preparation_budget`, `material_tile_size` and
`material_adaptive_resolution` controls do not improve current AMD GI materials.
Do not reintroduce their coarse material representation into AMD GI.
