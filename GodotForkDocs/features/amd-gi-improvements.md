# Optional AMD GI improvements

Experimental opt-ins on `feature/amdgi-improvements`; all default to **false**.
The frozen original remains `amdgi-frozen-2026-10-30`. These changes do not replace
AMD GI, increase its primary-ray allowance, or enable GI by themselves.

Use live `ProjectSettings` keys under
`rendering/global_illumination/amd_gi/improvements/`:

| Key | Practical effect | Tradeoff |
| --- | --- | --- |
| `responsive_history` | Repeated lighting changes replace stale bounce sooner. Stable regions recover longer history. | Mistaking sampling noise for change can increase noise. Extra cache bandwidth and 22 MiB metadata, or 44 MiB with multibounce, at default capacity. No extra rays. |
| `demand_scheduling` | Spend the existing probe-update budget on missing, changing, or overdue regions. | More selection work; different rays can cost different amounts. Does not increase spatial resolution. Change priority uses `responsive_history`; coverage and age priority work independently. |
| `cache_transitions` | Blend fine lighting into its immediate coarser estimate near the sample threshold. | Detail appears earlier and more gradually, potentially admitting noise or blur. No extra persistent storage or rays. Does not fix transitions between world-cell size levels. |

Switching any option resets GI history for a clean comparison. Response toggles
also resize cache storage. Let these application costs settle before measuring.
Keep all three false for the original algorithm. GI disabled allocates/renders
none of this optional metadata or work.

```gdscript
const GI_IMPROVEMENTS := "rendering/global_illumination/amd_gi/improvements/"
ProjectSettings.set_setting(GI_IMPROVEMENTS + "responsive_history", true)
```

For diagnosis use native resolution with FSR2/TAA **off**, quarter sampling, and
the GI denoiser **on**. Compare the same frame after a light change, not just
settled images. FSR2 Native AA is reserved for final presentation comparisons.
Disable VBAO while diagnosing. Do not infer GPU timings from cloud CPU rendering.

See [validation](../../docs/validation/amd_gi_improvements/README.md) for what was
actually exercised and remaining acceptance. These are not yet recommended
shipping defaults or a claim that flashlight/reflection artifacts are resolved.
