# AMD GI: setup and runtime controls

AMD GI supplies diffuse indirect lighting and glossy reflections without baking,
authored probes, or special UV layouts. This fork adapts AMD Capsaicin GI 1.2 to
Godot materials, lights, scene changes, and Vulkan. It is not a general replacement
for every Godot GI feature. Start with the defaults below; there is no validated
universal performance preset.

By default, brief emissive flashes retain GI history in scenes with a powered
analytic light. The response, scheduling, and cache-transition experiments
default off. See the [settings and reference comparison](amd-gi-improvements.md).

## Enable it

1. Use **Vulkan Forward+**, a perspective camera, a single view, an Environment
   (normally a WorldEnvironment), and **MSAA disabled**.
2. Enable `rendering/lights_and_shadows/raytraced_shadows/enabled` **before engine
   startup** and restart after changing it. The current implementation needs this
   shared tracing infrastructure even if your purpose is GI. Existing mesh buffers
   cannot acquire acceleration-structure usage through a later live toggle.
3. Enable `rendering/global_illumination/amd_gi/enabled`. This setting itself is live
   once the startup prerequisite is satisfied.
4. Disable SDFGI and SSIL in the Environment and remove visible VoxelGI instances.
   These conflicts suppress AMD GI; the fork does not silently rewrite their settings.

On Windows, a new combination of material shaders can take several seconds for
the graphics driver to prepare. The viewport uses native lighting during that
interval and switches to AMD GI and its reflections when the full set is ready.
Another instance of an already supported material usually reuses the current set.
For a loading screen, use the [preparation API](amd-gi-loading.md) to collect hidden
materials, defer intermediate compilations, and wait for working GI before play.

Hardware must support Vulkan ray queries, buffer device addresses and half floats,
with at least 38 storage-buffer bindings per stage and aggregate pipeline layout, 12 storage-image
bindings per stage and aggregate pipeline layout, eight color attachments, and 32 KiB compute shared
memory. The source capability check is authoritative; an older warning still
mentions 32 buffers.

## Which objects participate

`GI_MODE_STATIC` (the default) and `GI_MODE_DYNAMIC` both participate and may move.
`GI_MODE_DISABLED` omits the object from ray transport; a visible surface can still
receive GI through the screen-space input. Lightmapped objects and material-overlay
objects are omitted from transport individually. No lightmap UV is required.

Ordinary CPU-managed 3D MultiMesh supports visible instance counts, transforms,
colors, and custom data. GPU-indirect MultiMesh and shader-driven ray-geometry
displacement are unsupported. Do not assume a moving grass shader has matching ray
geometry merely because its visible surface receives GI. Source materials requiring
raster derivatives are omitted from transport with a warning; arbitrary transparency,
layered/multipass materials, and custom deformation are not universally supported.
For engine-level material contracts, consult `docs/internals/rt-materials.md` in the
fork repository.

Orthographic views retain native lighting with no AMD GI output. Negative/subtractive
lights retain their native direct effect but are excluded from GI sampling and
feedback. These are deliberate scope limits of this personal fork. AMD GI takes
precedence over the separate `rt_validation/enabled` diagnostic backend. Native
SSR is suppressed when AMD reflection pipelines are ready and reflections enabled.

## Main project controls

These six controls are in Project Settings **General**, visible without its
Advanced Settings switch. All short names use
`rendering/global_illumination/amd_gi/`. Defaults below are engine defaults;
existing projects keep their own overrides.

| Setting | Default | Meaning / tradeoff |
| --- | --- | --- |
| `enabled` | `false` | Master GI switch; enable after satisfying the startup prerequisite. |
| `probe_spacing` | `16` | Choose 8, 16, or 32. Approximately 1, 1/4, or 1/16 primary probe ray per internal pixel per frame; larger spacing reduces update density. Stored probes retain an 8-pixel grid. |
| `multibounce` | `true` | Secondary cache transport. Disabling removes continuation/indirect work and its storage, but removes indirect bounces. |
| `reflections/enabled` | `true` | Separate glossy path; disabling skips it and releases its sized resources. |
| `reflections/half_resolution` | `true` | Rotating samples at one per 2x2 internal pixels. Full resolution costs more but can improve fine geometry. |
| `reflections/trace_roughness_threshold` | `0.2` | Trace dedicated reflection rays up to this roughness; higher values can stabilize moderately rough surfaces at additional cost. Clamped to the advanced probe threshold. |

Primary probe rays are only part of the cost: light visibility, continuations, and
glossy rays add work. Both GI and reflections scale with **internal rendering
resolution**, which may differ from the window resolution when upscaling is active.

## Live changes and remaining limits

```gdscript
const GI := "rendering/global_illumination/amd_gi/"
ProjectSettings.set_setting(GI + "enabled", true)
ProjectSettings.set_setting(GI + "sky_sampling", 1)
ProjectSettings.set_setting(GI + "reflections/denoiser", 1)
```

These changes affect every eligible viewport and need not be saved to disk.
Each viewport has its own histories. Sampling/filter changes reset relevant
histories; resource-layout changes can reallocate buffers and briefly stall.
Debug view changes do not reset histories. Allow settling before comparing images.

Glossy reconstruction still has a reported issue on thin/specific faces, with
blur and artifacts more apparent during forward/backward motion. The alternate
denoiser is not an accepted fix. The complete optional-mode matrix has prepared
fixtures but no recorded hardware acceptance; successful default rendering does
not validate every combination.

Use [diagnostics and advanced controls](amd-gi-debug.md) for overlay integration,
exclusion reports, cache views, sky comparisons, and reflection tuning. Engine
maintainers should read `docs/internals/amd-gi.md` and
`docs/AMD_GI_ADAPTER_DECISIONS.md` in the fork repository before changing transport.

For bounded cache/denoiser responsiveness and distant-detail experiments, see
[live tuning and game-panel integration](amd-gi-tuning.md). Defaults remain unchanged.
