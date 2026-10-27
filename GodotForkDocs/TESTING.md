# Testing a project with godot-rt

Use this for project reproduction and acceptance. Engine fixture commands and
rebuild checks live in the engine repository's `docs/VALIDATION.md`.

## Record enough to reproduce

Record the executable path and revision (or checksum), GPU/driver, Forward+
driver, viewport size, internal render scale, upscaler/AA, affected scene/material,
and changed fork settings. Distinguish requested settings from effective runtime
state. A source commit and an installed binary are not automatically the same build.

Use a small window for diagnosis unless resolution is the variable under test.
Keep camera, lighting, exposure, resolution and dynamic content comparable.
Record whether grass/particles/NPCs are enabled; disabling them is a test control,
not an engine requirement. Do not silently save diagnostic overrides into a project.

## Quality checks

- Compare the feature off/on without changing other effects. Wait for temporal
  history to settle, but also inspect the first frames after a change.
- Test stationary views, forward/backward motion, strafing, turns and disocclusion.
  Stable stills do not establish correct moving reflections or shadows.
- Include thin/alpha-tested geometry, moving/skinned meshes, MultiMeshes,
  material edits, blinking lights, scene changes, resize and feature toggles when
  relevant. Unsupported geometry needs an intentional fallback, not a hidden error.
- Compare both shadow and GI behavior if shared geometry/material data changed.
  A mesh may be eligible for one and excluded from the other.
- Use ordinary production settings first. More rays or more blur can conceal a
  defect; they do not demonstrate the underlying problem is fixed.

For quantitative image comparisons, decode sRGB captures into linear light and
keep exposure/tonemapping controlled. Screen-space effects cannot know all
off-screen geometry; separate that method limit from an implementation error.

## Performance checks

Warm shader pipelines before steady-state measurements and report first-load
stalls separately. Record CPU and GPU frame times independently; FPS alone does
not identify which stage became cheaper. Control VSync, caps and competing GPU
work. Report results for the actual machine and scene, not as a universal preset.

Disable GI debug statistics/readbacks, expensive visualizers and capture tools
for production timing. Sampled GPU statistics intentionally synchronize on sampled
frames and can create spikes. A driver/compiler change may invalidate warm caches.

## Exit and restart checks

Close the test normally. Check the process exit result, engine errors and the
Streamline log when enabled. On Windows, inspect newly generated Windows crash
dumps and NVIDIA Streamline exception dumps: a caught SDK exception can precede
the final exit. A disappearing window is insufficient evidence of a clean shutdown.

If diagnosing a save-related or scene-load issue, isolate test saves/preferences
using the project's supported mechanism. Do not delete existing saves to make a
test pass. Keep logs with the build that produced them.

## Report the limit of the result

Use precise outcomes: build passed; CPU oracle passed; renderer fixture passed;
project reproduction passed; visual acceptance pending. None substitutes for the
next. A single clean run is evidence for that case, not proof of every scene,
device, optional filter or future driver version.
