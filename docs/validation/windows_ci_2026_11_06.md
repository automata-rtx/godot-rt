# Windows CI investigation, 2026-11-06

Investigated published revision `91c24b8bd6ad8259e89c2a541c199316444982ed`.
This report concerns C++ compilation and CI, not renderer performance or visual
acceptance. No local Godot or game launch is needed for these checks.

## Repeated failures and their corrections

| Failure | Evidence | Correction in current source |
| --- | --- | --- |
| Inner `columns` variable hides the probe-grid variable; MSVC C4456 / GCC `-Werror=shadow` | [October 24](https://github.com/automata-rtx/godot-rt/actions/runs/40102671542), [October 25](https://github.com/automata-rtx/godot-rt/actions/runs/40233519533), [October 27](https://github.com/automata-rtx/godot-rt/actions/runs/40426126164), [November 3](https://github.com/automata-rtx/godot-rt/actions/runs/41665294321), [November 4](https://github.com/automata-rtx/godot-rt/actions/runs/41885401056) | `amd_gi.cpp` uses distinct `dispatch_columns`; correction introduced by `d3b625cf3b` |
| A `CHECK` inside a callback passed within another `CHECK` creates nested doctest locals named `DOCTEST_RB`; GCC rejects the shadowing | [October 25](https://github.com/automata-rtx/godot-rt/actions/runs/40243717694), November 3 and 4 runs above | Preparation executes before the outer assertion; `recovered_pass` is checked separately, originally fixed by `d3b625cf3b` |
| Light-grid size arithmetic used 32-bit intermediate counts before a 64-bit allocation check; MSVC C4754 | [October 31 first repair](https://github.com/automata-rtx/godot-rt/actions/runs/41153405657) | `ensure_light_grid` calculates `leaves` and `tops` in `uint64_t`; corrected by `9980873213` |

The diagnostics above were read from failed compiler logs, not inferred from a
red workflow badge. CI deliberately treats warnings as errors. Local editor
builds with ordinary warning settings can succeed while these configurations
fail. clang-cl also accepted source rejected by the other compilers.

## Why the failures continued

All four Windows jobs passed at `9980873213` on
[`test/amdgi-fps-refinement`](https://github.com/automata-rtx/godot-rt/actions/runs/41157602512).
That commit was not an ancestor of the November 3 primary-branch commit
`d0a814e67c`; the November 4 primary branch likewise retained the old source.
This was a missing cross-branch integration, not evidence of a compiler cache
randomly resurrecting old code. The November 6 merge `91c24b8bd6` includes the
passing fixes and preserves the primary branch's intervening work.

## Validation

- Local MSVC 14.3 / Windows SDK 10.0.26100.0: all 18 C++ files changed by
  `28afc4e165` compiled as editor objects with `dev_mode=yes`, `debug_symbols=no`,
  and optional AccessKit/D3D12/ANGLE SDKs disabled. This covers strict warnings
  and the changed pipeline-preparation test, not a full editor link or runtime
  test. Logs: `.artifacts/ci-repair-20261106/strict-all-changed.log`.
- The same strict local check passed for all 15 changed non-editor C++ files as
  release-template objects. Log:
  `.artifacts/ci-repair-20261106/strict-template-changed.log`.
- Full four-compiler/target matrix at the published revision:
  [November 6 run](https://github.com/automata-rtx/godot-rt/actions/runs/42242616657).
  Completed successfully; static checks and all four Windows jobs passed.

| Windows job | Compilation | Unit tests | Assertions |
| --- | --- | --- | --- |
| MSVC editor | Passed | 1,419 passed, 0 failed | 423,045 passed |
| clang-cl editor | Passed | 1,419 passed, 0 failed | 423,045 passed |
| MSVC release template | Passed | 1,401 passed, 0 failed | 316,997 passed |
| GCC release template | Passed | 1,401 passed, 0 failed | 316,997 passed |

Four tests were skipped in each configuration. Artifact upload passed for both
editors and the MSVC template; GCC has no artifact-upload step in this matrix.
No additional engine-source or workflow change was needed: the latest published
merge already integrated the missing fixes. The only edits from this
investigation are this report and the contributor validation instructions.

Follow [the CI validation contract](../VALIDATION.md#windows-ci-and-branch-integration)
when publishing later fixes. Do not infer current success from this historical
report or from a successful job on another branch.
