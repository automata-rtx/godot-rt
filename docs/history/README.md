# Historical evidence — opt in by topic

These records preserve measurements, rejected approaches and old implementation
details. They are not current configuration instructions. Start with
[current status](../STATUS.md) or the [portable guide](../../GodotForkDocs/FORK_GUIDE.md).
Search a relevant heading; do not load these large files wholesale into AI context.

| Need | Record |
| --- | --- |
| Earlier AMD GI audits, approved corrections, measured experiments | [AMD archive](AMD_GI_ARCHIVE.md) |
| RT/VBAO/contact-shadow/DLSS measured and refuted ideas | [Pre-audit history](pre-streamline-2026-10-26/docs/HISTORY.md) |
| Former detailed port recipe, numeric layouts and old pitfalls | [Pre-audit porting](pre-streamline-2026-10-26/docs/PORTING.md) |
| Prior feature implementation derivations | [RT shadows](pre-streamline-2026-10-26/docs/internals/rt-shadows.md), [VBAO](pre-streamline-2026-10-26/docs/internals/ambient-occlusion.md), [contact shadows](pre-streamline-2026-10-26/docs/internals/screen-space-shadows.md), [DLSS](pre-streamline-2026-10-26/docs/internals/dlss.md) |
| GI investigation chronology and local shutdown evidence | [Pre-audit GI handoff](pre-streamline-2026-10-26/docs/AMD_GI_IMPLEMENTATION.md) |
| Old validation results and their methodological limits | [Pre-audit validation](pre-streamline-2026-10-26/docs/VALIDATION.md) |

`pre-streamline-2026-10-26/` preserves the 19 original active documents from source
commit `66bd97e00d` before restructuring. Some assertions were already stale then;
the banner is deliberate. Old line numbers, branch names, personal testing
permissions, tuning defaults and relative links must not override current source
or current instructions. Active guides retain the contracts needed for rebuilding;
the snapshot retains deeper derivations and experimental context without imposing
them on every project question.
