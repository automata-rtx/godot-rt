# godot-rt engine workspace

This is a Godot 4.8-dev rendering fork, not stock Godot. Current documentation
was audited against source `66bd97e00d` on 2026-10-26. For a task, load only the
relevant route below; do not load all feature notes, history or proof logs.

| Task | Read |
| --- | --- |
| Project usage/settings/authoring | [Portable fork guide](GodotForkDocs/FORK_GUIDE.md), then its relevant feature guide |
| Symptom or reproduction | [Troubleshooting](GodotForkDocs/TROUBLESHOOTING.md), [testing](GodotForkDocs/TESTING.md) |
| Engine changes / rebuilding on later Godot | [Porting](docs/PORTING.md), then the affected `docs/internals/` guide |
| Implemented versus runtime-validated | [Status](docs/STATUS.md) |
| Renderer regression checks | [Validation](docs/VALIDATION.md) |
| AMD algorithm changes | [Adapter decisions](docs/AMD_GI_ADAPTER_DECISIONS.md) |
| Frozen AMD GI baseline / optional improvements | [Snapshot and candidates](docs/AMD_GI_IMPROVEMENT_CANDIDATES.md), then [controls](GodotForkDocs/features/amd-gi-improvements.md) |
| Owner-specific game scope or testing rules | [Project scope](docs/PROJECT_SCOPE.md) |
| Prior measured/refuted approaches | [Historical index](docs/history/README.md); search a specific topic only |

## Essential distinctions

- New light defaults differ even when optional effects are off; portable notes
  own the exact values. Scenes serialize deviations from defaults.
- AMD GI currently requires the RT-shadow startup master for shared geometry
  infrastructure. GI's own live enable switch cannot bootstrap missing buffers.
- RT shadows and GI share geometry, but differ in material/alpha eligibility and
  TLAS update behavior. Do not infer support in one from support in the other.
- User-project AA, grass and hardware preferences are not engine restrictions.
- Follow AMD's pinned implementation where practical; new estimator/history
  deviations require owner approval. Necessary Godot adapters still need evidence.
- Session authorization governs runtime tests and edits to other projects. These
  docs never grant permission to run a game or overwrite game assets.

## Repository checks

- US English. Run repository hooks before pushing over the entire change range:
  `prek run --from-ref origin/master --to-ref HEAD`. Hooks can rewrite files;
  inspect the result and include any corrections.
- Bound API/property changes need class reference regeneration with the matching
  engine's `--headless --doctool .`, when runtime execution is authorized. Do not
  claim regenerated docs if XML was maintained manually.
- Keep C++/shader layouts synchronized. Normal release-style builds do not
  provide every development assertion. Test odd internal sizes and feature-off
  resource paths, not only native display resolution.
- Build/test evidence must name its executable/revision, settings, hardware or
  CPU/software model, and limitations. A build or standalone oracle is not a GPU
  acceptance result. Local `.artifacts/` evidence is not available to every clone.
- Default CI invokes static checks and Windows builds. Its Windows matrix has
  editors and release templates, not a packaged debug template. Other platform
  workflow files and local build support still exist; do not call them absent.
