# RT GI transport validation

An optional **uncached diffuse transport integrator** now connects scene geometry,
native material capture, Vulkan ray queries, and Forward+ indirect lighting. It is a
validation checkpoint for the AMD GI port. It is not the optimized AMD GI-1.x backend
and must not become a shipping graphics preset.

The renderer traces independent diffuse paths for each internal-resolution pixel.
Secondary hits read captured albedo, normals, metallic, alpha, and HDR emission.
Directional, omni, and spot lights contribute direct illumination at these hits,
with additional visibility rays. More secondary encounters add diffuse bounces.
The visible surface's albedo and metallic term are applied by Forward+ before fog,
tone mapping, and temporal upscaling. Native direct lighting and RT shadows remain
the baseline being compared.

## Diagnostic captures (not implementation progress)

Build this fork, then run from `docs/validation/shadow_validation` with Vulkan and
the harness's normal Xvfb/lavapipe dependencies available:

```sh
RTGI_SAMPLES=1 ./run.sh gi
```

The rig creates a room with colored walls and white boxes, fixes the camera and
exposure, and saves PNGs in `out/gi/`:

- `gi_disabled.png`: direct lighting and RT shadows.
- `gi_one_bounce.png`: one secondary diffuse encounter.
- `gi_three_bounces.png`: three secondary diffuse encounters.
- `gi_indirect_zero.png`: GI enabled, but the light's indirect energy set to zero.
- `gi_material_changed.png`: the right wall changes from green to blue; it does not
  cast shadows, but must still contribute reflected light.
- `gi_disabled_after.png`: GI disabled again, with original scene settings restored.

`score_gi.py` requires visible indirect light, additional energy from extra bounces,
and a corresponding color change on the white box. Zero indirect energy and disabling
GI must each restore the disabled image byte-for-byte. The printed memory counters
are engine-reported allocations, not a hardware profiler. Software Vulkan timings
cannot predict performance on the 780M or RTX 5090.

## Controls

These project settings are live and can be changed with `ProjectSettings.set_setting()`:

| Setting under `rendering/global_illumination/rt_validation/` | Default | Meaning |
| --- | --- | --- |
| `enabled` | `false` | Explicitly opt into the validation integrator |
| `samples_per_pixel` | `1` | Independent paths per internal pixel; 1–4096 |
| `bounces` | `2` | Secondary diffuse encounters; 1–8 |
| `max_distance` | `50.0` | Ray segment limit and camera-centered gathering box half-extent, in world units |

For example:

```gdscript
ProjectSettings.set_setting("rendering/global_illumination/rt_validation/samples_per_pixel", 1)
ProjectSettings.set_setting("rendering/global_illumination/rt_validation/bounces", 3)
ProjectSettings.set_setting("rendering/global_illumination/rt_validation/enabled", true)
```

The project must already enable RT shadows at startup so uploaded mesh buffers have
acceleration-structure usage. This mode requires Vulkan Forward+, a WorldEnvironment,
one view, and no MSAA. SDFGI, SSIL, VoxelGI, and lightmaps must be disabled for the
comparison; native settings are preserved, not changed automatically. Set ambient
light to zero for a pure transport comparison, as the rig does; existing authored
ambient light otherwise remains part of the baseline. The shared
geometry budget can defer initialization until later frames.

## Compare with native Godot GI

`./run.sh gi_compare` now uses the actual cached AMD diffuse pipeline at low ray
budgets, with denoising enabled, against native VoxelGI and SDFGI. See the
[current comparison protocol](amd-gi.md#native-comparisons).

The original 512-sample images remain historical transport debugging references.
They are not representative progress images or fair runtime-budget comparisons.

## Scope and limitations

This mode has no radiance cache, screen probes, temporal accumulation, denoiser,
glossy reflections, or environment/sky sampling. It uses Lambertian secondary
reflection, two-sided secondary shading, ideal point/spot/directional light sampling,
and a small ray-origin offset. It is not a perfect path-traced reference for all
Godot material models. High sample counts produce useful stills at deliberately
high cost; the results say nothing about a viable 780M quality tier.

It accepts MeshInstance3D geometry, including native skeleton/blend-shape output.
CPU-managed 3D MultiMeshes are supported with per-element material inputs.
GPU-indirect MultiMeshes, particles, material overlays, lightmaps, vertex-deforming, screen-reading, unsupported blend modes,
unshaded, and multipass materials are not supported. Area lights are not supported;
textured light projectors and distance fades also suppress the validation contribution. Unsupported
geometry/materials and capacity overflow suppress the GI contribution instead of
silently rendering a partial scene. The safety limits are 65,536 surface instances
and 1,024 lights. Material atlas layers grow on demand up to the live AMD GI
`material_atlas_mb` setting; each layer holds 1,024 tiles, packed in 32-triangle
rows. Expanded capture geometry persists until source revisions change. Compatible
instances share captured material pixels; tracked static material inputs reuse
pixels, while dynamic inputs retain native per-frame evaluation.

Each triangle uses an 8-pixel tile. This limits texture/normal-map/cutout detail and
does not establish the final material-cache representation. Geometry is collected
outside the view frustum and independently of shadow-caster flags, but only within
the configured camera-centered volume. Rays are clipped to that volume.

No resources or pipelines for this mode are initialized until it is requested.
Disabling destroys the validation TLAS, atlases, buffers, and pipeline, releases
GI-only BLAS entries, and clears each rendered viewport's validation output. Shared
shadow BLASes survive. Deferred driver destruction follows normal RenderingDevice
lifetime rules. Exact disabled images do not establish hardware timing equivalence.
Native material-bake renderer buffer pools can remain allocated after this mode was
used. In the lifecycle rig, texture bytes returned exactly to the cold baseline after
12 drain frames, while buffer bytes remained 761,760 above it. Do not claim complete
cold-start memory equivalence after toggling. A project that never enables this mode
does not run captures or initialize these validation resources.

DLSS/FSR run after composition at their normal position in the renderer. The
validation signal has no history to reproject, but that ordering alone is not a
completed DLSS/FSR compatibility test. Neither upscaler was exercised by this rig.

The first bounded world-cache/screen-probe path is now implemented separately; use
[AMD GI progress captures](amd-gi.md#progress-captures) with denoising enabled to
evaluate actual implementation progress. Overall status remains in
[AMD_GI_IMPLEMENTATION.md](../AMD_GI_IMPLEMENTATION.md).

### Forward-only transparency

Transparent passes that neither write depth nor cast material shadows stay in the
native raster path. This includes outline shells, stencil-only masks and additive
effects. They do not become opaque GI occluders and do not disable GI for the scene.
Opaque/cutout surfaces retain normal transport. Depth-writing mix-alpha materials
use stochastic opacity: fully opaque texels remain surfaces, zero-alpha texels
transmit, and fractional texels select coverage probabilistically. The same test
applies to GI visibility rays; native RT-shadow behavior is unchanged. This is
straight-through opacity, not refraction or colored transmission. Multipass and
unsupported deformation retain strict checks. Forward-only effects do not emit GI.
`amd_gi_overlays` checks that physical-scene GI and history survive these passes.
