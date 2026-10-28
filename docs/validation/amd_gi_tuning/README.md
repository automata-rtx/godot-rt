# Bounded tuning checks

Run from the engine root:

```sh
python3 docs/validation/amd_gi_tuning/check.py
python3 docs/validation/amd_gi_tuning/compile_shaders.py --compiler glslangValidator
```

The first compiles the production C++ input-sanitation lambda, checks reset and
cache-threshold wiring, and simulates response/default equivalence and quantized
cell-size transitions. It requires a C++17 compiler. The second expands shader
includes and compiles nine affected stages to Vulkan 1.2 SPIR-V using a constant
material stub. It validates shader syntax/layout declarations, not real materials
or GPU execution.

On 2026-10-27 both passed in the cloud Linux workspace against the working changes
based on 05983ca. The changed AMDGI and ProjectSettings C++ objects also compiled
with SCons (release-style Linux editor flags); FrameUniform's 544-byte assertion
passed. One existing shadowed-variable warning remains in AMDGI's dispatch code.
Python lint/format and diff whitespace checks passed. Class XML entries were
maintained manually and parsed, not regenerated with a newly linked editor.
No full editor link, Windows build, GPU runtime acceptance, visual comparison,
or performance measurement was performed for these tuning changes.

Remaining hardware acceptance for the game-project agent:
- Compare all-default appearance against the preceding build at identical settings.
- Change response controls with a stationary camera and a moving flashlight;
  check that histories continue, brightness settles correctly, and noise is acceptable.
- Change detail at near/mid/far surfaces; expect one history reset, no reallocation,
  then convergence. Reapplying the same effective value must not reset again.
- Exercise A/B switching, disable/re-enable GI, and multiple viewports; leave ray
  budget and resolution fixed, including an odd internal size. Check cache overflow.
- Measure GPU timings and VRAM before choosing a combined preset. Preserve AMD
  defaults until the owner accepts a tuned result.

## Scene-space debug views (2026-10-28)

Added capture/reset/range assertions to check.py. The same nine-pass SPIR-V test
covers pre-denoiser capture (INTERPOLATE), final display (DEBUG_VIEW), and the
intervening temporal/spatial passes. These checks passed with the changes based on
b3ee94d. AMDGI, Forward+ and ProjectSettings C++ objects compiled successfully.
No target-GPU editor/game visual acceptance has been performed. XML was maintained
manually, not generated from a newly linked binary.

Hardware acceptance: test views 32–37 and return to 0; check that view switches do
not reset history or feed visualization colors into GI. Compare 34/35 under repeatable
light toggles; test sky, odd viewport sizes, denoiser off, GI off, and reflections off.
At default detail, view 32 must be gray; lowering detail may turn only some regions
green due to cell quantization. Check editor perspective and orthographic separately.
