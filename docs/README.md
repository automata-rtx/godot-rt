# Fork documentation map

Audited against `66bd97e00d`, 2026-10-26. Load one route, not this entire tree.

| Task | Entry point |
| --- | --- |
| Use the fork in any 3D project; copy notes to a project | [Portable fork guide](../GodotForkDocs/FORK_GUIDE.md) |
| Diagnose or report a project rendering issue | [Troubleshooting](../GodotForkDocs/TROUBLESHOOTING.md), then [testing](../GodotForkDocs/TESTING.md) |
| Know what is implemented versus actually validated | [Current status](STATUS.md) |
| Rebuild the fork on a later Godot version | [Porting](PORTING.md) |
| Change shared RT/GI geometry or native source-material evaluation | [RT implementation](internals/rt-shadows.md), [material integration](internals/rt-materials.md) |
| Change AMD GI algorithms, scheduling or diagnostics | [GI implementation](internals/amd-gi.md), [approved adapter decisions](AMD_GI_ADAPTER_DECISIONS.md) |
| Restore frozen AMD GI or work on optional improvements | [Snapshot and candidates](AMD_GI_IMPROVEMENT_CANDIDATES.md), [controls](../GodotForkDocs/features/amd-gi-improvements.md) |
| Change VBAO, contact shadows or DLSS | `internals/ambient-occlusion.md`, `internals/screen-space-shadows.md`, `internals/dlss.md` |
| Validate an engine modification | [Validation](VALIDATION.md) |
| Work on this owner's personal project | [Project scope](PROJECT_SCOPE.md); not part of the portable pack |
| Investigate an old result or rejected idea | [Historical index](history/README.md); search only the relevant record |

`GodotForkDocs/` owns current user/tester instructions. `docs/internals/` owns
implementation contracts and per-feature rebuild details. `PORTING.md` owns
cross-feature integration order. `STATUS.md` owns validation limits. Historical
records are evidence, not current behavior specifications. Old entry paths are
short redirects for existing links.
