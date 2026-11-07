# HybridPiP integration and porting contract

Experimental branch implementation based on `91c24b8bd6`, November 2026.
Read [shared RT](shared-raytracing.md), [AMD GI](amd-gi.md) and
[RT shadows](rt-shadows.md) before porting this layer. Implement it **after** those
consumers, not as independent copies of them. The disabled path remains the
established renderer. The original preparation API uses a one-region batch while inactive. The resident API uses the player's ordinary renderer while inactive.

## Resident ADS lifecycle

Preserve both preparation entry points. `RendererViewport` owns the ordinary render buffers and an optional `scope_buffers` reference per viewport. Resident preparation records configuration and advances its generation. The first eligible active draw creates the scope parent at viewport output size, with zero parent jitter and target VRS suppressed. `_draw_3d` selects one parent for the logical camera. Keep the ordinary parent and its scaling configuration intact. Reconfiguration can invalidate the scope parent. Disabling drops the optional reference. Prepared child batches share their regional world; hip-fire retains its own buffer state.

On a parent switch, invalidate the previous camera frame and preserve the reset through the ordinary Forward+ pass. Child histories require a consecutive rendered frame. Keep distinct Streamline handles, explicitly suspend frame generation on the departing normal handle and suppress it on the regional parent. Route GI preparation/diagnostics to the drawn buffers and report `viewport_size` even before the scope parent exists. The engine does not know which weapon is equipped. See the [project integration contract](../../GodotForkDocs/features/hybrid-pip.md) for allocation gates and coverage.

## Ownership and schedule

`AMDGI::WorldData` owns persistent world-cache/reservoir/light/environment state;
`ViewData` owns screen/probe/reflection history and a strong world reference.
Parent render buffers own `BatchData`, shared ray/hit/work/origin buffers and a
single logical GI frame. `RenderForwardClustered::HybridPiPData` retains two
child render-buffer sets, their scene-data objects and composition outputs.
It clears borrowed scene pointers after synchronous rendering. Preserve teardown
order; a child must not free another child's world state.

Forward+ extracts ordinary scene stages, then coordinates two regional depth
passes, shared pre-opaque preparation, one GI batch, two regional color passes,
regional TAA when selected, HDR composition/blur and one parent display pass.
Scene collection, source material preparation, BLAS and the existing distinct
GI/shadow TLAS remain shared. Do not call the complete native GI render twice
with a shared cache. Screen probe grids remain regional even though their stored
positions are world-space.

The GI shader's shared-world access qualifier distinguishes read-only regional
screen work from producers. Writer bodies retain prototypes but are compiled
only in producer variants; a newly reachable writer in a read-only pass must
fail compilation. Reflection tracing is an explicit exception for cache-key
lifetime refresh: keys remain writable while cached radiance is read-only.
Keep these declarations synchronized with actual writes and preserve real RD
dependencies. The source-only optimization retained dispatch order and barriers.

The batch shader family compacts live regional probes into contiguous primary
work ranges. The secondary range starts at fixed prepared capacity C, not the
live primary count. Reservoir storage uses this stable capacity ABI. A shared
primary-origin buffer preserves each selected probe's origin. Global cache
maintenance, combined hit registration/update, light-grid work and reservoir
phase advance occur once. Regional probe/reflection/filter stages retain their
own current and previous surfaces. Preserve all-hit and non-all-hit dispatch
bounds and validators when changing this schedule.

One shared source-buffer read group is borrowed by both synchronous region
contexts; its lifetime cannot outlive their stack owner. Descriptor preparation
warms both screen/world parity combinations. The batch family has its own
capability checks (41 storage buffers, 32 sampled textures and 34 samplers per
shader stage, with corresponding per-set checks); native limits
are unchanged. Preparation rollback retains geometry resources but invalidates
failed GI state. Partial dispatch failure never reruns GI as a fallback in the
same frame. The next frame recovers uniformly. Disabling or unsupported fallback
releases batch state and invalidates incompatible native histories.

## Coordinates and histories

`hybrid_pip_layout.h` defines bounded integer crop placement, capacity and parent
UV mapping. `RenderSceneDataRD::configure_region_from` copies value state, crops
current/previous projections and transforms jitter without copying UBO ownership.
Keep CPU and `scene_data_inc.glsl` layouts synchronized. Reverse-Z and the existing
surface-plane correction remain unchanged.

Internal depth/GI/AO texture UVs are regional. Cluster lookup and public spatial
`SCREEN_UV`, `FRAGCOORD`, and `VIEWPORT_SIZE` refer to the logical parent view.
The raster compiler uses its coordinate helpers; the ray material compiler must
override inherited raster renames and use its own parent-coordinate provider.
Godot shader builtins still belong in `fragment()`; pass values into user helper
functions rather than assuming they are in global shader-language scope.

World cache/reservoir hashes use the logical parent camera footprint. Regional
probe footprints use sampling density. Current/previous lighting feedback maps
parent UV into the matching region, preferring valid native coverage and falling
back to background coverage. Near-field taps can consult the other region.
Parent-view coordinate mapping and regional history validity are separate
concepts. GI reads unblurred lighting feedback, never presentation blur.

RT shadows prepare analytic-light slots/sample phase once and render both regions
with that token. Invalid regional history uses current-frame visibility and fresh
metadata; it does not change the configured ray sample count. TAA has an explicit
reset path and a logical-density variance reference;
its copies use actual internal extents. The rectangular AA experiment can filter the inner region with FXAA/SMAA and optionally apply outer FXAA before blur. The magnified double-DLSS path resolves each child before composition.
Temporal child reconstruction uses separate render buffers, history and jitter sequences per region. DLSS also needs distinct Streamline viewport handles, motion-vector updates while the parent runs without temporal AA, and separate color and depth extents during composition. For arbitrary ratios the lens-only raster extent rounds the product of target size and requested input fraction to the nearest pixel. The lens-only composition maps reconstructed texels to output pixels by an integer translation about the optical axis. Validate the visible aperture against that translated reconstructed footprint; the source rectangle may be smaller than the glass. See [the runtime controls](../../GodotForkDocs/features/hybrid-pip.md).

In rectangular composition mode the native crop covers the outward-rounded protected scope, with pixel-aligned
placement and zero required padding. Existing screen-space passes operate on the
child texture extent. Regional near-field and shared-world feedback still have
access to both views. A larger prepared capacity creates optional overlap for
depth-aware blending. Composition uses native color throughout the protected
rectangle and reconstructs the background outside. The current-depth aperture
blur uses a prepared color mip pyramid and 16 weighted disk samples, with
fourfold angular symmetry and four-point radial quadrature. Small radii use mip
zero; larger radii select continuous LOD with variance compensation. Aperture
pixels retain the sharp base image. The near/far curve remains 2/10.72 pixels
at 720p over 0.12/25 meters. The aperture UBO is 512 bytes (16 vertices and 16
samples). Shader and C++ layouts must stay paired.

Composition writes pyramid mip zero; each downsample reads one prepared mip
view and writes the next, in separate compute lists. The blur reads the chain
and writes the borrowed parent HDR target directly. That target is never freed
by the compositor. Preparation warms all levels; ADS does not allocate them.
Keep/Canvas/CameraFeed backgrounds are rejected before warming, which can write
the parent's color before its uniform preparation frame overwrites it. The
source-only optimization's build/static checks do not establish visual parity:
see [optimization validation](../validation/hybrid_pip/GPU_OPTIMIZATIONS.md).

## Source map and acceptance

- `renderer_viewport.*`, `rendering_server.*`, `storage/render_scene_buffers.h`:
  configuration, runtime API and status. Reprepare increments a generation;
  ordinary ADS toggles retain allocations.
- `forward_clustered/render_forward_clustered.*`: coordinator, compatibility
  gates, child resources, preparation/recovery and parent continuation.
- `environment/amd_gi.*`, `shaders/effects/amd_gi*_inc.glsl`: world/screen split,
  batch dispatch ABI, feedback and footprint adapters.
- `storage_rd/render_scene_data_rd.*`, `scene_data_inc.glsl`, Forward+ shaders
  and `rt_material_source*`: projection and public/internal coordinate contract.
- `effects/rt_shadows.*`, `effects/taa.*`: shared light token and history reset.
- `effects/hybrid_pip.*`, its compute shader: prepared composition/blur resources.

Porting gates: feature-off control; enabled uniform; no-AA regional images;
moving crop/camera, TAA and fallback histories; all-hit/non-all-hit and multibounce
queue bounds; material/emitter/light mutation; deformation/MultiMesh; odd resize;
independent viewport lifetimes; preparation failure and live-resource shutdown.
Run layout tests, offline shader compilation, editor/template development builds
and actual GPU fixtures. Check total viewport GPU time, CPU span, memory and ADS
transition distributions. Texture preallocation alone does not establish absence
of driver first-use work. Test evidence belongs in the validation report, not in
an unconditional claim of compatibility or performance.
