# AMD GI hit-normal coordinate-space investigation

Reference: Capsaicin `914b91596cd119eda85fbc1d3c7ee6ac391b1452` (v1.3 package, GI-1.2 renderer). This investigation concerns the transform expressions at that revision, not every version of AMD GI. No upstream renderer image was produced for this investigation.

## Conclusion

The missing and repeated instance transforms are localized coordinate-space errors in the pinned implementation. They are not explained by the technique's screen-space/world-space split. This conclusion follows from the producers, consumers, shared buffer bindings and an equivalent-world-geometry counterexample. It does not rely on variable names alone or assume that every geometry/shading-normal difference is an error.

No renderer normal policy was changed during the investigation. The owner subsequently conditionally approved the alternative when AMD's transforms are incorrect. The evidence below establishes that condition; implementation of the narrow correction is now authorized.

## Follow the data into the passes

Paths below are relative to `src/core/src` in the AMD reference checkout.

1. **Static mesh upload:** `capsaicin/capsaicin_internal_scene.cpp:1074` copies mesh positions and normals into `Vertex` without applying an instance transform. The separate transform upload at line 1527 copies `instances[i].transform` into the instance transform buffer. A mesh can therefore be shared by differently transformed instances.
2. **Animated mesh upload:** `capsaicin/generate_animated_vertices.comp:76` multiplies the skin matrix by `g_InstanceInverseTransform` before transforming positions and normals. Deformation does not establish a special world-space-normal contract for the GI fetches.
3. **Fetch helpers:** `geometry/mesh.hlsl:145` and `:175` read the same vertex indices and `.getNormal()` values. Neither `fetchVerticesNorm` nor `fetchVerticesNormUV` transforms normals. The latter additionally fetches UVs. `gpu_shared.h:153` returns the stored normal directly.
4. **Shared bindings:** `render_techniques/gi1/gi1.cpp:2025` binds the same vertex buffer, vertex-data index and instance transform buffer to the GI program. The dispatch sequence at lines 2414–2470 does not swap in world-space normals for the multibounce or cache-shading pass.
5. **Transform helper:** `math/transform.hlsl:36` constructs the normal matrix using cofactors and determinant sign; `transformNormal` at line 58 multiplies by that matrix. It is an instance normal transform, not a projection or a world-to-view conversion. For a pure rotation it applies that rotation.

## Screen-indexed buffers still contain world-space normals

The raster visibility path in `render_techniques/visibility_buffer/visibility_buffer.mesh:83` transforms positions to world and transforms vertex normals by the instance normal matrix. The fragment shader at `visibility_buffer.frag:87` derives geometric normals from derivatives of **world positions**. Its normal-map tangent basis also uses those world-position derivatives. It encodes these world-space normals into screen-sized textures at lines 129–135.

The ray-traced visibility alternative independently confirms the contract: `visibility_buffer_rt.comp:100` transforms local geometric normals once, line 148 transforms shading normals once, and lines 159–179 write these values into the same kinds of screen buffers.

The near-field screen-space pass reads that shading-normal texture and explicitly names the decoded value `world_normal` (`render_techniques/ssgi/ssgi.comp:153`). Where its bent-normal integration operates in a view-aligned basis, it explicitly converts back using `inv_view` at line 128. Those legitimate conversions do not occur in the suspect GI hit-reconstruction blocks.

Screen space determines where samples are stored/looked up. It does not require their normal vectors to be expressed in screen or view coordinates.

## Affected and control paths

| Path | Reconstruction | Subsequent contract |
| --- | --- | --- |
| `gi1.comp:2401`, `GenerateReservoirs` | Transforms vertex positions and normals; interpolates and normalizes world normal. | Light sampling uses world position/directions; temporal feedback compares directly with a decoded world normal from the previous screen buffer. Consistent control path. |
| `gi1.comp:1869`, `PopulateMultibounceCells` | Transforms vertex positions and normals. | Samples continuation direction and launches a world-space ray. Consistent control path. |
| `gi1.comp:2603`, `GenerateMultibounceReservoirs` | Transforms positions but leaves fetched vertex normals local. | Passes that local normal to `sampleLightsListCone` alongside world position and `normalize(origin - world)`. Also uses it for spatial jitter and the reservoir's packed normal. No intervening basis conversion. |
| `gi1.comp:2040`, `PopulateCells` | Crosses edges after transforming positions to world, then applies the instance normal transform to that cross product again. Separately interpolates untransformed vertex normals as `shadingNormal`. | The twice-transformed geometric normal offsets a world-space shadow ray and later enters the BRDF with world-space view/light directions. The local shading normal reaches light evaluation; cosine environment sampling uses it to orient a hemisphere. |
| `gi1.comp:2801`, `TraceReflectionsHandleHit` | Transforms fetched vertex normals once. | Compares them directly with previous world-space screen-buffer normals and uses them for lighting/cache queries. Consistent control path. |

Consumer checks: `ray_tracing/trace_ray.hlsl:131` offsets the supplied world position using the supplied normal; it performs no instance-space conversion. `gi1.comp:2006` evaluates the BRDF with `payload.normal`, `normalize(origin - payload.world)` and the traced ray direction. `materials/material_evaluation.hlsl:206` directly dots the normal with the light direction. `lights/light_evaluation.hlsl:975` calculates directions from light/world positions, and its cosine-environment branch uses the supplied normal directly.

The local `shadingNormal` in `PopulateCells` is not used by every light type. For example, point-light evaluation derives direction from positions without consulting it. That limits the affected cases; it does not establish a valid alternate coordinate convention.

## Numerical counterexample

A flat local triangle has normal +X. Rotate its instance 90 degrees around Z: its world normal is +Y. Compare it with the identical world triangle whose rotation is baked into its vertices/normals and whose instance transform is identity. Use a world light direction +Y. There is no normal map, backface, negative scale, screen projection, disocclusion or denoising involved.

| Extracted reconstruction | Rotated instance: normal · light | Baked equivalent: normal · light |
| --- | ---: | ---: |
| `GenerateReservoirs` | 1 | 1 |
| `GenerateMultibounceReservoirs` | 0 | 1 |
| `PopulateCells` geometric normal | approximately 0 | 1 |

The second path retains +X; the third rotates +Y again to -X. A surface that faces the light can therefore acquire a zero cosine purely because its transform was represented as an instance matrix rather than baked geometry. Identity transforms conceal both errors. Positive nonuniform scale does not eliminate them.

Reproducer: `/workspace/gi-validation/amd-consequential-corrections/check_normal_spaces.py`. It extracts the three reconstruction blocks unchanged from the pinned source, compiles them with C++ host implementations of the HLSL vector/matrix operations, and compares instanced/baked geometry for 0, 30, 60 and 90 degrees, with and without positive nonuniform scale. All 24 path/input cases satisfy the stated expectations. Generated source and numeric results are in the adjacent `normal-space/` directory. This proves the finite-input algebraic inconsistency; it is not a GPU integration or image-equivalence test. It does not establish the visible severity in an upstream demo scene.

## Narrow correction covered by the conditional approval

- In multibounce reservoir generation, transform interpolated vertex normals into world space, matching `GenerateReservoirs` and `PopulateMultibounceCells`.
- In cache shading, construct the geometric normal from **local** triangle edges and apply the normal transform once, following AMD's existing `MakeIntersectData`/visibility-RT convention. This avoids treating a second transform of world edges as intentional. Preserve the existing hit-facing convention; mirrored-instance behavior still needs its own qualification.
- Transform and normalize the cache-shading vertex normal consistently before passing it to world-space light evaluation.

Preserve which call sites use geometric normals versus interpolated vertex normals versus normal-mapped shading normals. The investigation does **not** approve replacing all normals with one kind, adding normal mapping to passes where AMD omits it, or changing sampling, history, material response or the screen-space/world-space architecture. Expected benefit: remove transform-dependent wrong bounce direction/weight and shadow-ray offset. This is not a claim that it fixes the reported boiling, gun artifacts or all missing GI.

## Port implementation and qualification after approval

The port now fetches interpolated vertex normals directly from native packed source/pose buffers and constructs geometric normals from shared BLAS triangle positions. It decodes compressed axis-angle normals using Forward+'s convention. Both normals receive the inverse-transpose instance transform once and hit-facing orientation once. Reservoir generation, resampling and continuation keep interpolated vertex normals; final cache BRDF evaluation and shadow offsets receive geometric normals. Final light evaluation restores the source vertex normal after reservoir-normal quantization, matching the reference's reconstruction boundary.

The production decoder passes 36 software-Vulkan GPU cases against original authored CPU normal expectations (maximum vector error 0.00005052), including two mirrored bases and positive nonuniform scale. The quarter-budget integration passes cache/hit/continuation diagnostics, resize and disable. The four/eight-weight deformation fixture passes its existing image thresholds, including FSR2 pose-buffer swapping. The reflection regression also passes all 344 GPU-checked frames and existing image thresholds; the winding fixture passes 48 front/back ray queries including mirrored instances. These tests qualify this correction; they do not establish full AMD renderer equivalence or close the source-material and half-barycentric handoff gaps.
