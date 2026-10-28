# Live AMD GI tuning

Requires Vulkan Forward+, enabled AMD GI, and a build containing these controls.
Defaults remain AMD's baseline. These are experimental adjustments, not a proven preset.

## What the controls do

**Cache history — how quickly bounced lighting catches up.**
- **Lower (toward 12):** gives new lighting more influence. Flashlight bounce should
  follow changes sooner, but dim areas may flicker or boil more.
- **Higher (toward 16, default):** steadier lighting, but more delay after lights move.
- Try lowering this first for sluggish flashlight bounce. It changes saved lighting
  used by GI, not the flashlight's direct beam. It also lets finer lighting detail
  appear with fewer samples, which can expose noise.

**Denoiser history — how much the final diffuse image remembers.**
- **Lower (toward 75%):** less lingering from smoothing, but more visible grain or
  shifting patches. Spatial smoothing may also become more apparent.
- **Higher (toward 100%, default):** calmer lighting, but changes can look slower.
- Try a small reduction if bounce still lingers after adjusting cache history.
  This cannot remove delay already present in the cache. It does not tune reflections.

**Distant cell size — how much lighting detail is kept farther away.**
- **Lower (toward 75%):** can separate smaller bright and dark regions rather than
  grouping them together. May help distant patches, but can increase noise and
  pressure on the fixed-size cache. It is not guaranteed to fix over-darkening.
- **Higher (toward 100%, default):** more sharing between nearby lighting samples,
  usually steadier coverage, but coarser detail.
- Changes happen in steps: a small adjustment may do nothing in one area and halve
  cell size in another. Changing this clears saved GI lighting; let it settle before
  judging. It does not allocate extra VRAM or increase the ray count.

Start at defaults, change one control slightly, then test walking and moving the
flashlight. Combine adjustments after understanding each effect. More responsive
lighting and finer detail can both expose noise; neither is a free quality increase.

## Agent integration

Prefix: `rendering/global_illumination/amd_gi/tuning/`.

| Setting suffix | UI label | Bounds / default | UI step | Apply |
| --- | --- | --- | --- | --- |
| `cache_history_updates` | Cache history | 12–16 / 16 | 1 | Immediately; preserves history |
| `denoiser_history_scale` | Denoiser history | 0.75–1 / 1 | 0.05 (5%) | Immediately; preserves history |
| `distant_cell_scale` | Distant cell size | 0.75–1 / 1 | 0.05 (5%) | On release/Apply; resets histories |

```gdscript
const GI_TUNING := "rendering/global_illumination/amd_gi/tuning/"
# Example: UI displays 90%; engine receives 0.90.
ProjectSettings.set_setting(GI_TUNING + "denoiser_history_scale", 0.90)
```

- Read with `ProjectSettings.get_setting()`; write with `set_setting()`. Global,
  live, no restart. Persist only on explicit Save. Reset defaults to `16, 1.0, 1.0`.
- Clamp UI/presets to the table; reject NaN/infinity. Engine independently clamps,
  rounds cache history, and defaults nonfinite inputs, but does not rewrite the
  stored ProjectSettings value. Show percentages for the two scale controls.
- Keep rendering/lighting updates running while the panel captures mouse/input.
  Response changes settle naturally. Detail changes reset all GI histories for each
  eligible viewport without reallocation; repeated equal effective values do not.
- Show a settling notice after detail changes, including A/B preset switches.
  There is no convergence signal or guaranteed settling time. A/B does not restore
  saved lighting history. Keep resolution, VBAO, exposure and probe spacing fixed.
- Reuse the explanations above as help text. Leave probe spacing at its current
  value; only 8/16/32 are supported. No intermediate budget or panel scene is supplied.

Engine rationale and validation: [implementation notes](../../docs/internals/amd-gi.md#bounded-live-tuning),
[checks and remaining hardware tests](../../docs/validation/amd_gi_tuning/README.md).
