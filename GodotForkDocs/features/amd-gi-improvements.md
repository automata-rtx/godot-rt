# Optional AMD GI improvements

Editor location: see the [General / Advanced Fork Options map](../SETTINGS.md).
Setting keys and runtime access are unchanged.

Emitter-transition history retention defaults to **on**. The three other controls default to **off**.
The frozen original remains `amdgi-frozen-2026-10-30`. These changes do not replace
AMD GI, increase its primary-ray allowance, or enable GI by themselves.

Use live `ProjectSettings` keys under
`rendering/global_illumination/amd_gi/improvements/`:

| Key | Practical effect | Tradeoff |
| --- | --- | --- |
| `responsive_history` | Repeated lighting changes replace stale bounce sooner. Stable regions recover longer history. | Mistaking sampling noise for change can increase noise. Extra cache bandwidth and 22 MiB metadata, or 44 MiB with multibounce, at default capacity. No extra rays. |
| `demand_scheduling` | Spend the existing probe-update budget on missing, changing, or overdue regions. | More selection work; different rays can cost different amounts. Does not increase spatial resolution. Change priority uses `responsive_history`; coverage and age priority work independently. |
| `cache_transitions` | Blend fine lighting into its immediate coarser estimate near the sample threshold. | Detail appears earlier and more gradually, potentially admitting noise or blur. No extra persistent storage or rays. Does not fix transitions between world-cell size levels. |
| `retain_history_on_emitter_transitions` | Keep settled GI when a mesh briefly starts or stops emitting in a scene with a powered directional, omni, or spot light. Sky-only and sole-emitter scenes keep the original reset. | The indirect flash can appear weaker or linger. With light resampling enabled, a simultaneous change to the ordinary light list can discard one frame of light selections. |

Switching any option resets GI history for a clean comparison. Response toggles
also resize cache storage. Let these application costs settle before measuring.
Keep all switches false for the original algorithm. GI disabled allocates/renders
none of this optional metadata or work.

```gdscript
const GI_IMPROVEMENTS := "rendering/global_illumination/amd_gi/improvements/"
ProjectSettings.set_setting(GI_IMPROVEMENTS + "responsive_history", true)
```

For diagnosis use native resolution with FSR2/TAA **off**, quarter sampling, and
the GI denoiser **on**. Compare the same frame after a light change, not just
settled images. FSR2 Native AA is reserved for final presentation comparisons.
Disable VBAO while diagnosing. Do not infer GPU timings from cloud CPU rendering.

The recorded FPS refinement (engine repository:
`docs/validation/amd_gi_improvements/FPS_REFINEMENT.md`)
keeps the same controls. Response detects smaller changes in dark bounce and
shortens history more effectively when change is confirmed. Flashlight bounce
responds sooner, with some additional noise. Tested scheduler and cache-transition
alternatives did not justify changing their current values.

Engine evidence: `docs/validation/amd_gi_improvements/README.md`.
Those software-Vulkan experiments are not current target-GPU acceptance. The
owner found the responsive-history trial unsatisfactory for flashlight bounce;
do not present it as an accepted fix. Flashlight-prioritized updates remain a
deferred proposal, with no priority-light tag or scheduling API implemented.
