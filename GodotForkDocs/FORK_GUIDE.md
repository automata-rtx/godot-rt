# godot-rt: project-facing fork notes

For game authors, testers and AI assistants. Audited against engine source
`66bd97e00d` on 2026-10-26 (Godot 4.8-dev). This describes the fork's behavior,
not a promise that a particular downloaded executable contains it.

**Copy this entire `GodotForkDocs` folder into a project.** Its user guides are
self-contained; they do not require the engine checkout. In that project's AI
instructions, link this file for rendering questions. Read this entry point and
only the feature guide relevant to the task. Do not load all the guides by default.
Record the executable/revision actually used by each project separately.

## What differs from stock Godot

| Feature | Purpose | Read when needed |
| --- | --- | --- |
| Hardware ray-traced shadows | Direct-light occlusion for local lights and optionally the sun | [RT shadows](features/rt-shadows.md) |
| VBAO | An alternative screen-space ambient-occlusion estimator using a visibility bitmask | [Ambient occlusion](features/ambient-occlusion.md) |
| Screen-space shadows | Additional directional-light contact shadows from visible depth | [Screen-space shadows](features/screen-space-shadows.md) |
| AMD GI 1.2 integration | Dynamic diffuse bounce lighting and glossy reflections, with caches and denoisers | [AMD GI](features/amd-gi.md) |
| NVIDIA Streamline | DLSS upscaling, Reflex and optional frame generation | [DLSS](features/dlss.md) |

These are separate controls, not a single quality preset. **AMD GI currently
requires the RT-shadow master switch enabled at startup**, because it creates the
shared ray-tracing infrastructure and mesh buffers. Direct shadows and indirect
lighting remain different effects. The additions target Forward+; hardware/API and
material requirements differ by feature. Follow the relevant guide rather than
assuming Vulkan support alone makes every feature available.

The fork also changes defaults on **new lights**, even when its optional effects
are off: OmniLight3D and SpotLight3D cast shadows by default and use `light_size =
0.05`; DirectionalLight3D uses `light_angular_distance = 0.25`. These affect ordinary
shadow maps and other consumers of light size too. Scenes only serialize values
that differ from defaults, so moving a scene between stock Godot and this fork
can change its appearance. When sharing scenes across engines, verify the saved
values or assign required properties in initialization code; resetting an Inspector
property to its default does not force serialization. See the RT-shadow guide for
`shadow_map_enabled`.

## Before changing a project

1. Verify the actual executable, rendering method/driver, GPU and active upscaler.
   Use editor and export templates from a matching fork build. Stock templates
   do not acquire these features from the project's settings.
2. Enable and test one effect at a time. A saved request is not proof the renderer
   accepted it; inspect warnings, effective upscaler state and GI diagnostics.
3. Distinguish engine defaults from project overrides. Existing scenes,
   Environment resources and settings scripts can override the values below.
4. Check each guide's live/restart behavior. `ProjectSettings.set_setting()` changes
   an in-memory setting; persisting it is a separate project decision.
5. Follow the project's permission and save-data rules. This folder grants no
   permission to launch a game, overwrite assets or change persistent preferences.

AMD GI remains an experimental integration with documented material/geometry
limits and unresolved reflection quality cases. Optional samplers, filters and
debug views are implemented; their presence is not proof of image parity or a
performance improvement. Use the documented defaults as a starting point and
keep comparison captures when tuning.

## Focused follow-ups

- Wrong/missing lighting, noisy reflections or a crash: [troubleshooting](TROUBLESHOOTING.md).
- Reproducing a bug or comparing cost/quality: [testing](TESTING.md).
- Building a runtime GI debug overlay: [AMD GI diagnostics](features/amd-gi-debug.md).
- Modifying/rebuilding the engine: in the engine repository, start at
  `docs/PORTING.md`, then the appropriate `docs/internals/` guide. Those technical
  notes and historical experiments are intentionally outside this project pack.

Do not replace this fork's documented behavior with assumptions from stock Godot.
Conversely, do not treat a project's preferred AA mode, hardware target, grass
setting or art direction as an engine-wide requirement.
