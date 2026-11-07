# Current implementation and validation status

Source audit: [2026-11-06](DOCUMENTATION_AUDIT.md), `b3c0262131` plus local
working changes. Dated measurements below belong to their individual builds. This file distinguishes source
support from runtime evidence; it is not a benchmark or a claim that all optional
paths are certified. Controls: [portable guide](../GodotForkDocs/FORK_GUIDE.md).

| Area | Current source | Evidence / remaining limit |
| --- | --- | --- |
| Fork settings presentation | 20 setup/quality controls in General; 78 specialized controls in Advanced Fork Options; original keys/defaults retained | Windows editor built; isolated blank-project editor passed 26 UI/serialization/undo/override checks. [Audit](validation/FORK_PROJECT_SETTINGS_AUDIT.md#implemented-presentation-split-2026-11-06). Desktop copies not replaced by this change. |
| RT shadows | Local/directional tracing, denoising and shared RT geometry | Existing fixture history covers many cases; current shared-cache changes must be exercised alongside GI when porting |
| VBAO | Selectable visibility-bitmask ambient occlusion | Reference/scoring rigs exist; scene-dependent screen-space limitations remain |
| Screen-space shadows | Directional depth-based contact shadow with caster filtering | Existing analytic/RT comparisons; screen boundaries and depth-layer omissions are method limits |
| AMD GI core | Cached diffuse and glossy paths, light/sky proposals, multibounce, native material adapter | Runs in the owner's project; full AMD image parity and target performance are not certified |
| HybridPiP branch | Opt-in resident scope renderer, separate hip-fire upscaler, magnified DLSS lens, reconstructed periphery, regional GI and shadows. [Build and integration](../GodotForkDocs/features/hybrid-pip.md) | Owner confirmed smooth repeated ADS in the sandbox. The 3× headless check passed 12 toggles with unchanged preparation generation. Production weapon integration, export runtime verification and incremental resident VRAM remain open. [Earlier B3 comparison](validation/hybrid_pip/B3_GPU_COMPARISON.md) |
| GI scene/CPU hardening | Same-frame AS preparation, conditional refit, material/geometry reuse, ordinary MultiMesh, light/emitter update separation, preparation recovery | Scene metadata, MultiMesh/deformation image references, 21-stage binding/resource lifecycle and injected preparation recovery passed on RTX 5090. This does not certify every prepared fixture |
| GI optional controls | Three sky modes, alternative reflection filtering, debug views, statistics and exclusion reports | Runtime-options fixture passed with binding validation; visual acceptance of every visualizer in every project remains separate |
| GI preparation/reflection optimizations | MultiMesh placement reuse, per-update shared geometry preparation, validated descriptor reuse, exact-default firefly rank shortcut | Independent reviews, targeted GPU regressions and Live World benchmarks passed; approximately 4–5% less CPU renderer time in the measured view. [Evidence and limits](validation/amd_gi_optimization_2026_10_26/RESULTS.md) |
| RT shadow/shared submission CPU reuse | Shared MultiMesh expansion, current-update geometry preparation, retained instance hashes/native bytes and BLAS dependencies | Exact shadow captures, native queued-ray fixtures and GI lifecycle/deformation passed. Live World CPU render span improved about 5.7% beyond the preceding build; forced-rebuild stress has a small CPU tradeoff. [Evidence and limits](validation/rt_cpu_optimization_2026_10_26/RESULTS.md) |
| GI retained scene/command preparation | Stable surface/emitter groups, current resource refresh, per-render buffer-read groups with every original dependency | Targeted material/lifecycle/deformation/emitter and native GPU tests passed. Live World rendering CPU improved another 24–28%, with unchanged GPU time. Fully changing scenes can pay extra reconstruction cost; one legacy material-response scorer still fails on baseline and candidate. [Evidence and limits](validation/gi_cpu_retention_2026_10_26/RESULTS.md) |
| GI CPU follow-up | Current-update combined source Context reuse, changed-record ranges, retained collected MultiMesh blocks | Independently reviewed, built and owner-tested. Four coordinated Live World benchmark runs show another 16–17% lower rendering CPU versus the faster baseline; GPU time unchanged. New exhaustive regression suite remains pending. [Measurements and limits](validation/gi_cpu_retention_2026_10_26/FOLLOWUP_BENCHMARKS.md) |
| Streamline shutdown | SDK cleanup before Vulkan destruction, guarded repeats/partial init, local-device ownership | Three complete RTX 5090 runtime cases passed: enabled-unused, disabled, Live World with AMD GI+DLSS and local-device create/readback/destroy. Exit 0; no new Windows/SDK dumps |

## Open project observations

**Local build delivery (2026-11-07).** The standard desktop shortcut points to the
latest local HybridPiP development editor in the engine checkout, SHA-256
`E7013C88614305E0A5B013E49F54CCF7096418B8220920B555354133FEC82C19`.
Its regional feature remains off by default. See the branch's validation limits above.
Future successful local editor builds must update/verify this shortcut.
`Desktop/GodotRTGI` is now reserved for Actions downloads; its existing executable
was not replaced by this policy change. See [delivery rules](PROJECT_SCOPE.md#local-build-delivery).

**Flashlight bounce response (2026-11-06).** The owner remains dissatisfied with
bounce appearing/fading slowly and recalls an unsatisfactory `responsive_history`
trial. Preserve that feedback rather than recommending the disabled toggle as
untested. A [bounded flashlight-priority update proposal](AMD_GI_IMPROVEMENT_CANDIDATES.md#deferred-flashlight-prioritized-updates-2026-11-06)
is documented for later consideration, including prior test drawbacks and the
unresolved connection between the lit surface and bounce receivers. It is not
implemented or authorized for implementation/testing. The settings presentation cleanup does not implement this proposal.

**Combat Lab material stall (2026-11-05).** The captured draw took 12.038 s.
Replaying the saved third material combination synchronously spent 11.561 s in
driver pipeline creation. Nine of 58 enabled shaders changed and accounted for
11.557 s. An offline RTX 5090 replay with the fork's asynchronous preparation
methods and the same shader binaries took 11.305 s in the background. The
calling loop polled 2,556 times with a longest call of 12.78 ms. It also passed
superseded-revision, resident reuse, cleanup and injected-retry checks. This
test used reconstructed Vulkan layouts and an adapter for Godot's shader and
device objects. Subsequent local RTX 5090 rendered checks verified loading-screen
preparation in Combat Lab, with grass off at 1280×720. A first tested load spent
6.638 s preparing GI pipelines and 8.374 s under the loading cover; a separate
cached launch took 77.5 ms and 621 ms respectively. The paused encounter remained
at 0.0167 s/two events during preparation; gunfire did not request another GI set.
Both runs then exercised an unexpected new shader during combat and recovered GI.
Cold raster variant changes still produced up to 1.31 s draw gaps under the cover
and 1.24 s in the deliberate late-shader test; this is not universal hitch removal.
The cached late-shader test's maximum gap was 71.0 ms.

The same captured shader binaries, with distinct entry-point names to avoid
driver-cache contamination, took 13.498/7.516/5.080 s with 1/2/4 compilation
workers. Peak process memory was 581/811/1197 MiB in this isolated Vulkan test.
This supports the bounded four-worker default on this desktop, not a universal
speedup claim. Separate-process saved-cache runs took 10.6/7.1/3.6 ms.

Preparation fixtures passed hidden-material staging, reversed discovery order
(identical source hash), uniform changes without recompilation, scene supersession,
injected failure/retry, and shutdown with workers active. Backup-cache recovery
loaded 8.6 MiB and reached ready GI in 155 ms. Numerical source-material validation
passed 256 samples (maximum error 1.3e-7); the CPU preparation helper passed 141
checks. Class-reference API signatures were regenerated with the matching engine.
Logs: `.artifacts/gi-material-stall/`; MSVC editor SHA-256:
`63161B3F2FA7DC27021228C88766B1C7302AC8642A5C31362F95229EA041F030`.
At the owner's request on 2026-11-05, both desktop copies (`GodotRT` and `GodotRTGI`)
were replaced with that tested executable and their SHA-256 hashes verified.
Each previous executable has an adjacent `.before-gi-loading-20261105-221217.bak`
backup. The `GodotRTGI` filename retains `.llvm.exe` for path compatibility, but
this installed build uses MSVC. See [material preparation](internals/amd-gi.md)
and the [loading API](../GodotForkDocs/features/amd-gi-loading.md).

The owner-authorized three [GI improvement experiments](validation/amd_gi_improvements/README.md)
are implemented behind independent, default-off switches. Linux builds, shader
checks, and software-Vulkan response/coverage/lifecycle captures exist. The
[sequential FPS refinement](validation/amd_gi_improvements/FPS_REFINEMENT.md)
selects more responsive history after comparing five variants; scheduling and
cache-transition alternatives did not justify changes. Synthetic mixed-lighting,
flashlight, motion and polished-weapon tests expose the remaining noise tradeoff. This is not target-GPU
performance acceptance or a claim that the reported game artifacts are resolved.

- Reflections became more stable, but the owner still reports excessive blur and
  face-specific artifacts during forward/backward movement; strafing shows much
  less of the problem. Thin faces and the player-facing magazine were earlier
  trouble areas. Preserve detail as well as stability when investigating.
- AKMN handguard boiling: on the matched Building Sandbox yard route, raising
  `reflections/trace_roughness_threshold` from `0.30` to `0.45` reduced
  motion-tracked brightness fluctuation by 92% on the upper wood, 83% on the
  metal behind it and 44% on the receiver cover. The measure compares 3×3-pixel
  patch brightness against the same surface four frames earlier and later,
  excluding silhouettes and occlusions. Both wood and metal also
  improved against the dark scenario board, where the cover showed little
  difference. Both runs used full internal-resolution reflections and DLSS
  Performance (640×360 internal). The fraction of yard pixels eligible for
  reflection rays rose from 0.24% to 8.39% across five sampled frames.
  At 0.45 the measured median viewport GPU time rose by about 0.01 ms in
  Building Sandbox and Live World on the RTX 5090. [Profile and probe evidence](validation/AKMN_REFLECTION_PROFILE.md)
- Deferred texture-import fix: the RenderingDevice editor's roughness-hint range
  check in `MaterialStorage::MaterialData::update_textures` accepts unrelated
  hints. All six AKMN packed maps recorded import mode 8 instead of green (3).
  Correcting only the roughness mipmaps did not consistently reduce front-sight
  or muzzle shimmer in matched RTX 5090 captures. Track importer repair and
  reimport of stale settings separately from glossy reflection sampling.
- Firing/muzzle-flash overhead received source changes, but a clean shutdown test
  did not exercise or establish acceptance of that gameplay issue.
- General material/resource lifecycle coverage, shader-driven displacement,
  GPU-indirect MultiMesh transport, layered/multipass and other unsupported
  material cases are not made complete by the recent runtime-options work.

See the feature guides for current exclusions. Do not carry every old local
handoff symptom forward as a verified current bug; the full historical list is
preserved in the snapshot below for targeted reproduction.

## Historical build identities

These are dated delivery records, not the current contents of `bin/` or Desktop.
The latest settings-editor build is identified in the settings audit linked above.
Verify installed file hashes before assuming source and binary match.

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
That retention task did not replace the desktop installation; later deliveries above supersede it.

The earlier CPU follow-up editor, then at `bin/godot.windows.editor.x86_64.exe`,
has SHA256 `2497553BF8097CE6E71E76D9651782B7BD4A6601D39D03B2E3228D2C28918340`.
It compiled successfully and the owner subsequently tested it and reported that
it works, authorizing publication. The same executable was then installed in
`Desktop/GodotRT`, with the previous editor backed up. Four separately authorized
benchmark runs establish the CPU benefit above; see the
[delivery and benchmark record](validation/gi_cpu_retention_2026_10_26/FOLLOWUP_BENCHMARKS.md).

Detailed logs, prior figures, proof limitations and deployment paths remain in
the [pre-audit implementation record](history/pre-streamline-2026-10-26/docs/AMD_GI_IMPLEMENTATION.md).
Older AMD experiments are indexed in [history](history/README.md). Local
`.artifacts/` paths in those records are not guaranteed to exist on another PC.
Portable regression fixtures are under `docs/validation/`; existence of a fixture
does not imply a passing run.
