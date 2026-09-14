# godot-rt — Godot 4.8-dev with hardware raytraced shadows

**Not vanilla Godot.** Four additions to the Forward+ renderer: hardware raytraced shadows, a
GTAO/visibility-bitmask occlusion estimator, a Bend Studio screen space contact shadow, and NVIDIA
Streamline (DLSS). Node defaults differ. Answering about lights, shadows, fog, occlusion or
upscaling from memory of stock Godot produces wrong code and wrong advice.

This file is the router. It holds only what is needed to avoid a wrong answer without opening
anything else. **Open the file that covers the question before answering it.**

## Where things are

| Question | File |
| --- | --- |
| Something is broken or looks wrong | `docs/TROUBLESHOOTING.md` — indexed by symptom |
| How do I use / configure a feature | `docs/features/<feature>.md` |
| How does a feature work, I'm changing it | `docs/internals/<feature>.md` |
| Has this been tried, what did it measure | `docs/HISTORY.md` — read before re-attempting anything |
| How do I measure or validate a change | `docs/VALIDATION.md` |
| Re-applying the fork to a newer Godot | `docs/PORTING.md` |

`<feature>` is one of `rt-shadows`, `ambient-occlusion`, `screen-space-shadows`, `dlss`.

Each file states what it does not cover and links where that lives. Follow the link rather than
guessing; do not load all of them.

## What this engine is for

Single-player first-person shooter. Not a general engine release — a tradeoff that suits this game
is the right one even where a general answer would differ.

- **Two target machines.** RTX 5090 desktop at 3440x1440, and a Ryzen 7 7840HS / Radeon 780M
  laptop. Every published measurement was taken on one of them. "Weak hardware" means the 780M.
- **Never TAA. SMAA only when DLSS is off.** The two shipping AA configurations are exclusive: DLSS
  on means DLSS does the antialiasing and SMAA/FXAA are off; DLSS off means SMAA. Never both.
  Consequence: Godot fills the velocity buffer only for a viewport running a temporal upscaler, so
  **anything that ghosts is a DLSS-on problem** — with SMAA there is no temporal reprojection of the
  frame at all. The raytraced shadow denoiser is the exception; it accumulates in both.
- **MSAA off.** So "measure with MSAA off" is the shipping configuration, not a methodology note.
- **Not VR.** Every multiview and stereo fallback in this fork is dead code here.
- Builds come from **GitHub Actions**, not a local toolchain.

## Node defaults that differ from vanilla

A `.tscn` stores only what differs from a freshly constructed node, so these are what a new node
gets — not a project setting to look up.

| Property | Vanilla | Here |
| --- | --- | --- |
| `OmniLight3D.shadow_enabled` | `false` | **`true`** |
| `SpotLight3D.shadow_enabled` | `false` | **`true`** |
| `OmniLight3D` / `SpotLight3D` `light_size` | `0.0` | **`0.05`** |
| `DirectionalLight3D.light_angular_distance` | `0.0` | **`0.25`** |

New lights cast soft, contact-hardening shadows with no configuration. Set size back to `0.0` for
hard shadows.

These apply in **every** renderer, raytracing on or off, and reach past shadows: a non-zero angular
distance puts the cascade path on its PCSS branch, draws a visible **sun disk** in
`ProceduralSkyMaterial`/`PhysicalSkyMaterial`, and makes `LightmapGI` bakes soft and slower; a
non-zero lamp `light_size` makes every lit mesh compile the `use_light_soft_shadows` specialization.

`Light3D` gains one property, `shadow_map_enabled` (and
`RenderingServer.light_set_shadow_map_enabled`).

## All four features ship OFF

| Feature | Setting | Notes |
| --- | --- | --- |
| Raytraced shadows | `rendering/lights_and_shadows/raytraced_shadows/enabled` | restart required |
| ↳ for the sun | `.../raytraced_shadows/directional/enabled` | live, snapshotted per frame |
| Ground truth occlusion | `rendering/environment/ssao/method` | `Environment.ssao_method` follows it |
| Screen space shadows | `rendering/lights_and_shadows/screen_space_shadows/enabled` | sun only |
| DLSS | `rendering/streamline/enabled` | restart required, Windows only |

Raytraced shadows need Forward+, Vulkan and ray query support; they warn and fall back to shadow
maps otherwise. Every other `raytraced_shadows/*` setting is **live** — changed in the inspector or
via `ProjectSettings.set_setting()`, it takes effect next frame.

## Writing in this repo

- **US English.** `codespell` runs in CI and rejects British spellings; the -our, -re and -ise
  endings have each failed a build here. It rewrites in place, so it will also "correct" a sentence
  that quotes a British spelling as an example.
- **Run the repo's hooks before pushing**, over the range, not just what is staged:
  `prek run --from-ref origin/master --to-ref HEAD`. CI compares against the branch point, so a
  problem introduced two commits earlier fails the run for whichever commit is on top. `clang-format`,
  `ruff-format` and `codespell` rewrite in place — a hook that "fails" silently has edited your files.
- **A bound property change needs `godot --headless --doctool .` run and committed by hand.** CI is
  Windows-only now and no longer checks it.
- Every published number comes from a harness in `docs/validation/` or from a stated simulation, and
  says which. A number with neither behind it is an opinion. See `docs/VALIDATION.md`.
- Local build, for testing a change before pushing:
  `scons platform=linuxbsd target=editor dev_build=no debug_symbols=no -j4`

## Two traps worth carrying without opening a file

- **No `template_debug` build exists anywhere in the CI matrix.** So no shippable configuration has
  `DEBUG_ENABLED` on — and that is the flag that turns a C++/GLSL push constant mismatch into a hard
  error instead of a silently skipped pass. Debug exports also do not work; release exports do.
- **Godot TRUNCATES the internal render size** (`servers/rendering/renderer_viewport.cpp:315`, a
  float expression assigned to an `int`), so 0.67 of 3440x1440 is 2304x964, not 2305x965. Every pass
  this fork adds dispatches from `get_internal_size()`. Check a new pass against an awkward size,
  not against the native one — whether a dimension divides by 2^level is the whole question.
