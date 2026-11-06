# godot-rt: project-facing fork notes

For game authors, testers and AI agents using this Godot 4.8-dev fork.
Documentation audited 2026-11-06 against `b3c0262131` plus the local working
changes, including loading preparation, conservative RT-shadow denoising,
emitter-history retention and the settings UI cleanup. This identifies source
behavior, not the contents of every installed editor or export template.

Copy this entire `GodotForkDocs` folder into a project. Link this entry point
from the project's AI instructions; read only the relevant guide below.
Keep the project's executable identity and overrides in its own documentation.
Do not load engine history or all feature guides for ordinary project work.

| Task | Read |
| --- | --- |
| Find settings; understand General versus Advanced Fork Options | [Settings map](SETTINGS.md) |
| Configure direct shadows, light size or caster coverage | [RT shadows](features/rt-shadows.md) |
| Configure ambient/contact shading | [VBAO](features/ambient-occlusion.md), [screen-space shadows](features/screen-space-shadows.md) |
| Enable bounce lighting or reflections; check supported geometry/materials | [AMD GI](features/amd-gi.md) |
| Prepare GI behind a loading screen | [Loading API](features/amd-gi-loading.md) |
| Build a GI overlay or diagnose a rendering stage | [Diagnostics](features/amd-gi-debug.md) |
| Tune bounce response or compare optional algorithms | [Bounded tuning](features/amd-gi-tuning.md), [improvements](features/amd-gi-improvements.md) |
| Configure upscaling/frame generation | [DLSS / Streamline](features/dlss.md) |
| Investigate an artifact, stall or crash | [Troubleshooting](TROUBLESHOOTING.md), then [testing](TESTING.md) |

## Essential rules

- These are separate Forward+ features, not a single preset. **AMD GI requires
  the RT-shadow master enabled at startup** for shared geometry buffers. Its live
  switch alone cannot bootstrap that infrastructure. See its guide for Vulkan,
  camera, AA and Environment compatibility.
- New OmniLight3D/SpotLight3D nodes default to shadows on and `light_size=0.05`.
  DirectionalLight3D defaults to `light_angular_distance=0.25`. These defaults
  apply with RT off too. Scenes serialize deviations, so transferring scenes
  between stock and fork builds can change appearance; verify authored values.
- Use matching fork editor/export templates. Verify the actual binary, renderer,
  GPU and effective upscaler. Project overrides and runtime scripts can differ
  from engine defaults; `ProjectSettings.set_setting()` does not itself save.
- AMD GI remains experimental, with documented material/geometry limits and
  motion/reflection tradeoffs. An implemented option is not a proven quality or
  performance improvement in every scene.
- Follow project permissions before launching a program or changing persistent
  data. These docs grant no execution or asset-edit permission. Grass, resolution,
  hardware targets and art direction are project choices, not engine restrictions.

For engine changes or a later Godot port, use `docs/PORTING.md` and the relevant
`docs/internals/` guide in the engine repository. They deliberately stay outside
this portable pack. Do not substitute stock-Godot assumptions for these contracts.
