# Preparing AMD GI during loading

The first encounter with a material shader combination can require seconds of
driver compilation. AMD GI builds these programs in the background, using up to
four low-priority workers. Native lighting remains usable until a complete,
compatible GI set is ready. This does not change AMD's lighting algorithms.

A game can hide this transition behind its loading screen:

1. Add the level to its world and immediately call
   `RenderingServer.scenario_set_amd_gi_preparation(world.scenario, [], true)`.
   The hold prevents compiling each intermediate material set during setup.
2. Finish asset loading, actors, equipment, and restoration. Collect the materials
   that the level can use, including invisible meshes and expected material
   variants such as a weapon's emission-enabled state. Keep those Material
   resources alive. Staging does not create geometry or illuminate anything.
3. Submit their RIDs with `hold=false`. Keep rendering the level and its camera
   beneath an opaque CanvasLayer. Pause gameplay separately once setup is ready;
   pausing too early can prevent asynchronous scene setup from finishing.
4. Poll `RenderingServer.viewport_get_amd_gi_preparation_status(viewport_rid)`.
   Require `ready=true` on fresh `rendered_frame` values before uncovering it.
   A few additional GI frames allow initial lighting history to settle.
5. Handle cancellation, a timeout, an empty snapshot, and `disabled`/`unavailable`.
   Always release the hold. Clear staged materials on unloading; all viewports
   sharing that scenario share the preparation request.

`completed_passes`/`total_passes` indicate driver-pipeline progress after shader
bytecode is available. Show an indeterminate indicator before that.
`material_errors` counts omitted/invalid staged materials; GI-ineligible fog,
screen-reading effects, and other unsupported materials are not made traceable by
preparation. `failed` retains the native fallback and retries with bounded delays.
`ready` requires an actual successful GI draw, not just compilation completion.
The API is independent of expensive GI debug readbacks.

Shader IDs and texture bindings are stable across discovery order for an identical
material set (hash collisions are resolved safely). Godot's shader cache and
Vulkan pipeline cache are reused across launches. Successful GI preparation
requests an asynchronous disk checkpoint, even below the usual save-size
threshold; replacement preserves the previous file if writing is interrupted.
Keep the project shader-cache and pipeline-cache settings enabled. A different
shader set, texture-array capacity, engine shader source, GPU, or driver can still
require preparation. `bytecode_or_resident_cache_hit` is not a driver-cache-hit
guarantee. Caches cannot generally be shipped from one GPU to another.

This is GI preparation, not a universal asset or raster-shader prewarmer. Future
materials absent from the supplied list still prepare asynchronously when first
encountered. Loading new shaders can temporarily restore native lighting.

Engine implementers: see `docs/internals/amd-gi.md`, the preparation regression
fixture, and the RenderingServer class reference in the fork repository.
