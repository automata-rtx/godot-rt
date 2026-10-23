# AMD GI gameplay audit — 2026-10-23

**Historical audit of `3038a14`, before the subsequent implementation work.** The audited port is not a valid
basis for judging AMD GI's finished quality or choosing shipping performance tiers.
This audit adds diagnostics and reproductions, not rendering fixes or a new editor
release. Increasing sample counts is not the repair for these failures.

## Scope and evidence

Engine `3038a14b44ccd2f82a876fb16f4cccf0cf93b3b2`, plus opt-in diagnostic logging;
fps-proto `996f0f9` (the pushed sandbox combat encounters and progress saves);
Capsaicin v1.3 `914b91596cd119eda85fbc1d3c7ee6ac391b1452` as the source reference.
Linux Vulkan Forward+, lavapipe, isolated Xvfb. No target-hardware performance or
Windows compiler comparison is established. The user's report was from Clang;
these reproduced defects are present in renderer source independently of compiler.

The controlled room uses 321×181 output and the default quarter primary diffuse
budget, with denoising, multibounce and reflections on. Actual-game diagnostics use
641×359 output and FSR2 Performance, with custom grass and RT soft shadows off to
isolate GI. Other AMD GI controls stay at defaults, including 128 MiB/8-pixel
material storage. Reflection, visibility and continuation rays are additional.
Diagnostic GPU readback intentionally stalls; these runs must not be timed as
benchmarks. All four game runs and the controlled reproduction exited successfully;
that means the diagnostics completed, not that visual acceptance passed.

## Confirmed failures

### Short-lived lights clear unrelated history

`RaytracingGIScene::update_scene()` hashes the sorted light identities and compares
light data. A membership change advances the scene revision; `AMDGI::render()`
uses that revision to reset all histories. Three on/off pulses in the controlled
scene produced six full resets. Toggling the real sandbox flashlight off and back
on produced two. The game's muzzle flash lasts 0.045 seconds and changes visibility,
so this mechanism explains why recovery can outlast the flash.

Light reservoirs currently store frame-local light indices. Simply removing the
reset would permit references to the wrong lights. Repair needs stable identities
or remapping, independent reservoir invalidation, and local response to illumination
changes. Abrupt light direction/intensity changes can also trigger the global cut.

### Moving reflective objects reject their own history

`temporal_reflection()` rejects a sample when its reflected ray intersects any
dirty motion bound. A ray starting on a moving object's surface starts inside that
object's expanded bound, so it rejects its own history. Current reprojection also
uses camera matrices without object velocity. Removing rejection alone would allow
stale history and is not a correct fix.

| Reproduction | Result |
| --- | --- |
| Controlled metal object, 16 moving frames | All 6,109 measured glossy samples had history count 1; no global resets |
| Same object after 32 stationary frames | Mean retained history recovered to 11.50 |
| Actual gold AK in contested building, translated 1 mm/frame for 12 frames with simulation frozen | All 21,225 measured glossy samples had history count 1; no global resets |
| Same view after 24 stationary frames | Mean retained history recovered to 13.41 |

The metric includes visible samples with roughness below 0.5; it is not an image
error metric or an object-ID mask. Freezing simulation lets the renderer keep
accumulating while weapon movement stops, consistent with the reported Escape
behavior. This does not establish the user's exact wall-clock recovery time.

### Material residency causes repeated preparation

The current material cache deletes captures unused in the current scene update.
A hidden emitter loses its prepared geometry and targets; showing it recreates
them. Packed triangle-page ranges can change when earlier surfaces enter or leave,
causing additional re-preparation. `RaytracingMaterialCapture::prepare()` reads the
entire source surface per page through `MeshStorage::mesh_get_surface()`, which uses
synchronous `RenderingDevice::buffer_get_data()` calls. Only output-image readback
is diagnostic-only; source-buffer readback occurs during ordinary GI preparation.

The controlled flickering mesh was prepared on all six appearances. At the real
sandbox spawn, the first 24 stationary draws after the stage marker included 406
page preparations across 11 frames, with no full GI resets. This count excludes
the following weapon equip. The later stationary contested segment had four page
preparations on its first frame and none afterward; frozen segments had none.
This is a concrete stall mechanism, not a measured attribution of the user's CPU
spikes. The screenshot's electrical field really is flickering emissive geometry,
without a dedicated light (`features/hazards/electrical_field.gd`).

Repair needs bounded retained residency, stable page assignments and preparation
that avoids synchronous GPU-to-CPU geometry reads in the rendering critical path.

### Default capacity suppresses GI on larger maps

| Directly loaded map | Default-capacity test |
| --- | --- |
| Crossroads | Suppressed: first failing surface requires 110,240 total tiles; 104,448 available |
| Fieldway | Suppressed: first failing surface requires 130,144 total tiles; 104,448 available |
| Sandbox Hideout | Scene became ready with 75,968 tiles and 20 lights; reported missing illumination remains unresolved |

These requested counts are the first failure, not full-scene requirements. Each
failed map retried preparation on all eight observed GI frames. Crossroads prepared
169 pages before its first failure; Fieldway prepared 17. In this frozen test the
following retries prepared zero new pages, but still traversed/validated the scene.
Do not claim repeated geometry readback on those unchanged failure frames.

Older successful Crossroads captures used 4-pixel tiles and a 256 MiB atlas, not
the defaults. Increasing the cap alone does not meet the requested automatic scene
support or solve capture memory/preparation costs. Failure needs early detection,
bounded retry behavior and a visible status, alongside a scalable material scheme.

## Missing stages with direct relevance to these reports

- **Emissive-triangle light sampling.** The fork's light proposals include only
  sun/point/spot lights. Emission is obtained when a ray happens to hit a triangle
  (and through compatible screen feedback), without explicit emitter sampling.
  Thin bright bolts produce rare large contributions. Upstream GI uses
  `LightSamplerGridStream` and `LightBuilder`, which gather emissive mesh lights.
  Emission support at hits is not equivalent to this sampling support. Adding it
  requires consistent sampling weights/MIS so direct-hit emission is not doubled.
- **Object motion reprojection.** Upstream GI consumes velocity; this port does not
  use it for moving receiver history. Correct previous positions, geometry identity,
  disocclusion and moving-occluder handling are needed across diffuse and glossy paths.
- **Dedicated reflection firefly cleanup.** Upstream `gi1.comp` implements
  `MarkFireflies` and `CleanupFireflies`, dispatched by `gi1.cpp` before ratio resolve.
  This port has ratio reconstruction, clamping and a-trous filtering but lacks those
  dedicated stages. Full resolution cannot fix lost history or rare bright outliers.
- **Remaining sampling/scheduling differences.** Material-BRDF sampling in probe
  tracing, upstream's separate light-grid reservoir arrangement, and adaptive
  reflection ray compaction remain absent or replaced with simpler adaptations.
- **Material and scene completeness.** Fixed 4/8-pixel triangle capture can lose
  detail. Custom vertex deformation, particles and GPU-indirect MultiMeshes are
  unsupported. Layered/anisotropic reflections and general nested specular transport
  are incomplete. Capacity, residency and visibility changes are not robust enough.
- **Acceptance on target machines.** Moving-scene quality, DLSS runtime behavior,
  peak frame time/memory on 5090 and 780M, and disabled-path hardware timing remain
  unverified. FSR2 running successfully does not validate the GI motion signal.

Sparse screen probes, adaptive probe updates, probe reuse, a directional world
radiance cache, analytic-light resampling, multibounce feedback, GGX reflections,
conventional denoising and native composition do exist. Their existence does not
make the implementation complete or establish parity with AMD's reference.

## Symptoms unresolved at the audit checkpoint

The exact rifle/wall box, angle-dependent loss of a whole wall, incorrect spawn-prop
lighting, and Hideout's reported absent GI have not been reproduced visually here.
Coarse dirty AABBs can reject rectangular regions of wall history; probe coverage,
cache invalidation and material capture also need isolated checks. Those are
hypotheses, not confirmed causes of each screenshot artifact. Flashlight-toggle
resets are confirmed; all stationary indirect boiling is not explained by toggles.

The user subsequently requested completion of the intended implementation rather
than following an isolated repair order. Current implementation progress and
remaining validation are tracked in [AMD_GI_IMPLEMENTATION.md](AMD_GI_IMPLEMENTATION.md)
and [features/amd-gi.md](features/amd-gi.md); this audit preserves baseline evidence.

NRD or Ray Reconstruction is not a substitute for those repairs. Neither is part
of this audit. No sample-count increase or denoiser disablement was used to hide
the reported behavior.

## Reproduction artifacts

The tracked `docs/validation/shadow_validation/amd_gi_gameplay_audit.tscn` is a
defect reproduction, not a passing acceptance test. Run the editor binary against
that validation project with Vulkan at 321×181, setting
`GODOT_AMD_GI_TRACE_HISTORY=1`, `GODOT_AMD_GI_TRACE_REFLECTION_HISTORY=1` and
`GODOT_AMD_GI_VALIDATE_MATERIALS=1`. The new glossy diagnostic reads the actual
temporal output and logs sample count, fresh samples and mean history. It performs
synchronous readback only when explicitly enabled. Do not benchmark with it.

Session logs, aggregate JSON, actual-game harnesses, source patch and a phone-readable
report are saved under `/workspace/preview/amd-gi-gameplay-audit/`. The game harnesses
are diagnostic scripts, not changes to gameplay or authored assets. Use isolated
user-data directories when reproducing because the game saves progress.
