# HybridPiP validation — 2026-11-06

For the later resident DLSS scope and owner playtest, see [current status](../../STATUS.md). This dated report covers earlier builds.

**B3 results** cover the 720p build-order repeat and the completed 1080p native/regional comparison. [GPU measurements](B3_GPU_COMPARISON.md)
The dev8 report below is retained as historical evidence only.

**Functional experimental implementation; performance acceptance remains open.**
Subsequent [GI-access and blur changes](GPU_OPTIMIZATIONS.md) have been built and
checked offline. The runtime measurements below remain those of the earlier dev8
build; the newer editor has not been launched.

The 720p B3 test preserves native scope detail and renders the background at half
resolution per axis, but offers no meaningful measured GPU saving over native
rendering with the same blur. It costs additional CPU time and GPU memory. Keep
the feature off by default. No magnification or supersampling is implemented.

The owner resumed source-only work after restarting Codex and prohibited further
render runs. All runtime evidence below predates that restriction. No 1080p or
old-versus-new native performance result is claimed.

## Build and method

- Branch `HybridPiP`, uncommitted changes based on `91c24b8bd6ad8259e89c2a541c199316444982ed`.
- Final editor: optimized MSVC x86-64 development build, warnings-as-errors,
  tests enabled; SHA-256 `BC31FE8B112259CCEA80156FA2F7AE1647816D429AB386DBAAEF0FE628BD48D5`.
  The desktop shortcut targets this executable in the engine checkout. Actions
  artifacts were not replaced. No CI or packaged export-template result claimed.
- RTX 5090, Vulkan 1.4.357, Ryzen 7 7800X3D host. External Systems Sandbox B3
  harness; 1280×720, 35° vertical FOV, grass/AA/VRS/frame-generation off, scale 1.0.
  Native crop capacity 528×608, background 640×360. Protected rectangle 368×448;
  the extra crop covers filter guards, fractional pixel rounding and alignment.
- Feature cases use one logical GI world cache. The matched native blur uses the
  same composition/blur shader through an external compositor callback. This
  gives a useful GPU reference; its GDScript callback means CPU costs are not a
  perfectly identical engine path. The plain native comparison is also retained.
- Eight balanced windows (`native, blur, regional, uniform, uniform, regional,
  blur, native`), 240 warm frames and 600 unique GPU timestamp samples per window.
  No image or explicit diagnostic GPU readbacks during timing. Game Director
  coordination and process inspection preceded the measurements. CPU numbers are
  rendering submission spans, not total game CPU time or frame rate.

## Final 720p measurements

Pooled medians, 1200 samples per case. [Machine-readable summaries and window data](measurements_720.json)
retain percentiles, memory snapshots, binary identity and the raw-data SHA-256.

| Mode | GPU frame span | CPU render span |
| --- | ---: | ---: |
| Feature off, native, no scope blur | 2.173ms | 0.741ms |
| Native with matching scope blur | 2.449ms | 0.781ms |
| Regional with scope blur | 2.431ms | 0.949ms |
| Feature prepared, ADS inactive, no blur | 2.202ms | 0.772ms |

The matched GPU difference is only 0.019ms (under 1%), smaller than the spread
between the two native-blur window medians (2.423/2.475ms). Regional CPU increases
about 0.168ms versus that reference. This is not a useful demonstrated optimization
at 720p. Prepared regional resources add approximately 296.4MiB of RD-accounted
buffers/textures; this is neither process RAM nor complete physical VRAM usage.

Earlier stage profiling with a slightly smaller static crop found GI around
1.52 ms native versus 1.45ms regional, plus about 0.40ms for composition/blur.
Repeated regional raster/screen work consumed much of that small saving. Source
contains shared work that does not scale with screen pixels, but these aggregate
timings do not identify its exact fraction or prove which subpass to optimize.
Do not infer higher-resolution gains from reduced pixel count alone.

The subsequent [source-only GPU cost audit](GPU_COST_AUDIT.md) accounts for the
actual regional pixel budget, identifies excessive resource write declarations
and presentation sampling, and ranks follow-ups. It adds no rendered results.

## ADS transitions

Twelve prepared switches produced 796 timing samples and no unready status
observations. All requests had matching active-state observations one engine-frame
index later. Texture accounting stayed at 503,702,528 bytes; buffer accounting
grew 1,856 bytes, not yet attributed. Stable totals do not exclude allocation/free
churn or driver first-use work.

Across the switch sequence: GPU p99/max 3.155/3.364ms; CPU p99/max 1.512/3.565ms;
host frame-interval median/p99/max 5.875/6.733/9.463ms. The first activation's
conservative timing neighborhood contained the CPU maximum and a 9.155ms host
interval. GPU-result, request and status frame IDs are separate streams; these
are not exact first-frame attribution. **Zero-spike ADS is not established.**

## Correctness evidence

Local artifacts are under `.artifacts/hybrid-pip/`; ignored captures/logs are not
distributed with a clone. [Fixtures and invocation rules](README.md) reproduce
the standalone tests without game assets.

| Check | Actual result and limit |
| --- | --- |
| Layout/projection tests | Five cases, 83 assertions passed; clipping, odd sizes, capacity, coordinate transforms and jitter |
| Offline shaders | 58 native  + 59 batch GI variants compiled; composition/blur and four Forward+ fragment variants passed. Does not establish driver execution |
| No-AA and TAA lifecycle | 19 stages each passed on dev4, before later narrow fixes; toggles, crop/camera, material/light/emitter changes, MultiMesh/blend shapes, odd resize, callback fallback, independent worlds and cleanup. Stable stages enforce one GI batch advance per rendered frame |
| Queue validators | dev6: eight all-hit/multibounce on/off uniform/regional combinations passed with positive primary, secondary and reservoir work |
| Native binding lifecycle | dev8 passed, including valid shader replacement, coordinate-helper material, texture mutation and viewport recreation |
| Live-owner shutdown | Valid scene passed; invalid-material test exposed an existing Forward+ double-free. Dev8 fix waits for pending pipeline work and clears cached pipelines before shader deletion. Negative regression: process 0, 95 expected parser/propagation errors, zero unexpected errors, completion marker present |
| B3 motion and AA | dev8: no-AA/FXAA/SMAA/TAA motion, blur and ADS captures completed; every motion frame required actual regional activity. Twenty motion snapshots and switch/blur images reviewed: no obvious seams, doubled geometry or stale trails. Peripheral text/edges remain coarse; TAA softens them. Sparse stills cannot exclude inter-frame flicker |
| Compilation | Full Windows MSVC development editor built; all ten directly changed renderer translation units compiled for release templates with development warnings-as-errors. Not a packaged-export test or Windows CI matrix |
| Static checks | `git diff --check`; clang-format 19.1.5 dry-run checks of changed/new C++ and GLSL passed; XML/Python syntax and new documentation links checked. Repository pins 22.1.5; complete pinned hooks remain pending before publication |

Discarded evidence: the first lifecycle shader illegally referenced stage builtins
inside a user helper (fixed by passing fragment arguments); an early reference
blur harness mishandled invalidated uniform sets (fixed); the first moving B3
capture silently fell back when its static crop capacity was exceeded. The final
motion harness adds alignment room and active-state assertions. Do not reuse
those earlier runs as acceptance evidence.

## Acceptance work recorded at dev8

1. The subsequent [1080p comparison](B3_GPU_COMPARISON.md) completed the B3 test
   with the same normalized scope, a 720×832 native crop and a 960×540 background.
2. Compare preserved pre-change and final binaries on the same native-only
   benchmark. Native visual/lifecycle checks passed, but that performance regression
   control is still missing. The external native harness is authored, not parsed/run.
3. Isolate the first-activation CPU outlier and remaining small buffer growth;
   record exact transition/driver-work attribution before any zero-hitch claim.
4. Obtain longer motion evidence and scene-specific quality acceptance before
   enabling gameplay integration. Fixed FOV tests do not certify an animated zoom.

FSR2/DLSS/DLAA, auto-exposure and frame generation use explicit uniform fallback.
Their regional integrations remain [separate unfinished work](../../plans/HYBRID_PIP_UPSCALERS.md).
The [feature guide](../../../GodotForkDocs/features/hybrid-pip.md) lists other
compatibility limits. Engine rendering is implemented; game ADS wiring is not.
