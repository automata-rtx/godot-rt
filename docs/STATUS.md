# Current implementation and validation status

Source baseline: `66bd97e00d`, audited 2026-10-26, with the optimization working
changes and runtime evidence below added that day. This file distinguishes source
support from runtime evidence; it is not a benchmark or a claim that all optional
paths are certified. Controls: [portable guide](../GodotForkDocs/FORK_GUIDE.md).

| Area | Current source | Evidence / remaining limit |
| --- | --- | --- |
| RT shadows | Local/directional tracing, denoising and shared RT geometry | Existing fixture history covers many cases; current shared-cache changes must be exercised alongside GI when porting |
| VBAO | Selectable visibility-bitmask ambient occlusion | Reference/scoring rigs exist; scene-dependent screen-space limitations remain |
| Screen-space shadows | Directional depth-based contact shadow with caster filtering | Existing analytic/RT comparisons; screen boundaries and depth-layer omissions are method limits |
| AMD GI core | Cached diffuse and glossy paths, light/sky proposals, multibounce, native material adapter | Runs in the owner's project; full AMD image parity and target performance are not certified |
| GI scene/CPU hardening | Same-frame AS preparation, conditional refit, material/geometry reuse, ordinary MultiMesh, light/emitter update separation, preparation recovery | Scene metadata, MultiMesh/deformation image references, 21-stage binding/resource lifecycle and injected preparation recovery passed on RTX 5090. This does not certify every prepared fixture |
| GI optional controls | Three sky modes, alternative reflection filtering, debug views, statistics and exclusion reports | Runtime-options fixture passed with binding validation; visual acceptance of every visualizer in every project remains separate |
| GI preparation/reflection optimizations | MultiMesh placement reuse, per-update shared geometry preparation, validated descriptor reuse, exact-default firefly rank shortcut | Independent reviews, targeted GPU regressions and Live World benchmarks passed; approximately 4–5% less CPU renderer time in the measured view. [Evidence and limits](validation/amd_gi_optimization_2026_10_26/RESULTS.md) |
| RT shadow/shared submission CPU reuse | Shared MultiMesh expansion, current-update geometry preparation, retained instance hashes/native bytes and BLAS dependencies | Exact shadow captures, native queued-ray fixtures and GI lifecycle/deformation passed. Live World CPU render span improved about 5.7% beyond the preceding build; forced-rebuild stress has a small CPU tradeoff. [Evidence and limits](validation/rt_cpu_optimization_2026_10_26/RESULTS.md) |
| GI retained scene/command preparation | Stable surface/emitter groups, current resource refresh, per-render buffer-read groups with every original dependency | Targeted material/lifecycle/deformation/emitter and native GPU tests passed. Live World rendering CPU improved another 24–28%, with unchanged GPU time. Fully changing scenes can pay extra reconstruction cost; one legacy material-response scorer still fails on baseline and candidate. [Evidence and limits](validation/gi_cpu_retention_2026_10_26/RESULTS.md) |
| GI CPU follow-up | Current-update combined source Context reuse, changed-record ranges, retained collected MultiMesh blocks | All three plans and patches independently reviewed; Windows build, source hooks and offline Context failure model passed. Owner tested the delivered build and reported it works. No new agent-run regression suite or benchmark; savings remain unmeasured. [Implementation and limits](validation/gi_cpu_retention_2026_10_26/CPU_FOLLOWUP_IMPLEMENTATION.md) |
| Streamline shutdown | SDK cleanup before Vulkan destruction, guarded repeats/partial init, local-device ownership | Three complete RTX 5090 runtime cases passed: enabled-unused, disabled, Live World with AMD GI+DLSS and local-device create/readback/destroy. Exit 0; no new Windows/SDK dumps |

## Open project observations

The owner-authorized three [GI improvement experiments](validation/amd_gi_improvements/README.md)
are implemented behind independent, default-off switches. Linux builds, shader
checks, and software-Vulkan response/coverage/lifecycle captures exist. Response
improves in the controlled fixture with some additional temporal variation; the
combined scheduler was refined after an adverse interaction. This is not target-GPU
performance acceptance or a claim that the reported game artifacts are resolved.

- Reflections became more stable, but the owner still reports excessive blur and
  face-specific artifacts during forward/backward movement; strafing shows much
  less of the problem. Thin faces and the player-facing magazine were earlier
  trouble areas. Preserve detail as well as stability when investigating.
- The game's full-resolution reflection override and trace cutoff `0.3` are
  project-specific experiments. They are not new engine defaults or universal fixes.
- Firing/muzzle-flash overhead received source changes, but a clean shutdown test
  did not exercise or establish acceptance of that gameplay issue.
- General material/resource lifecycle coverage, shader-driven displacement,
  GPU-indirect MultiMesh transport, layered/multipass and other unsupported
  material cases are not made complete by the recent runtime-options work.

See the feature guides for current exclusions. Do not carry every old local
handoff symptom forward as a verified current bug; the full historical list is
preserved in the snapshot below for targeted reproduction.

## Evidence and build identity

The shutdown-tested Windows executable has SHA256
`4EDE8767341A9FD6A243BD76FB16E88D73C6D1C27BA05C3A50C5F043D4E1BF21`.
It was built before commit `66bd97e00d`, so its embedded base revision is
`73864a817b`. It was installed to the owner's desktop on 2026-10-25 with the old
executable backed up. Check the actual installed checksum before relying on this
record. The build is not a new result from the documentation audit.

The preceding local optimization-tested editor has SHA256
`C15D6F3B64AC765F7BCCB95AC714CB369835BC5FAB030F2C3617526FAF756C74`.
Its source patch, before/after binaries, settings and regression results are
identified in the [optimization report](validation/amd_gi_optimization_2026_10_26/RESULTS.md).

The preceding local RT CPU optimization-tested editor has SHA256
`A4A921ED54AA6EE0E6E38E1DF649EA17631C7F616DCE9B9AAC78A11D3492A0CF`.
Its staged comparisons and correctness evidence are in the
[RT CPU report](validation/rt_cpu_optimization_2026_10_26/RESULTS.md).
This task left the desktop installation unchanged.

The preceding local GI CPU retention-tested editor has SHA256
`FC2B5242D2F9AB670E0B25C6B616653294118A50C13153E9A7243DB62BE25569`.
It is preserved in `.artifacts/rt-cpu-investigation-20261026/revised-binary/`; final/bypass comparisons,
independent contribution estimates and validation limits are in the
[GI CPU report](validation/gi_cpu_retention_2026_10_26/RESULTS.md).
The desktop installation remains unchanged.

The latest local CPU follow-up editor at `bin/godot.windows.editor.x86_64.exe`
has SHA256 `2497553BF8097CE6E71E76D9651782B7BD4A6601D39D03B2E3228D2C28918340`.
It compiled successfully and the owner subsequently tested it and reported that
it works, authorizing publication. No new agent-run regression suite or performance
claim is attached to this executable; the desktop installation remains unchanged.

Detailed logs, prior figures, proof limitations and deployment paths remain in
the [pre-audit implementation record](history/pre-streamline-2026-10-26/docs/AMD_GI_IMPLEMENTATION.md).
Older AMD experiments are indexed in [history](history/README.md). Local
`.artifacts/` paths in those records are not guaranteed to exist on another PC.
Portable regression fixtures are under `docs/validation/`; existence of a fixture
does not imply a passing run.
