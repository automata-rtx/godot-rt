# Regional lifecycle fixture

Actual build identities, results and remaining gates: [validation report](RESULTS.md).

The final resident stages hold ADS across an incompatible compositor, verify the ordinary scaled camera keeps drawing, then re-arm. Native unit tests separately inject lens and background DLSS callback results without needing an NVIDIA device.

Standalone generated geometry; no fps-proto assets or edits. This is a correctness
fixture, **not a benchmark**. PNG readbacks, material compilation, and readiness
waits deliberately interfere with timing.

Requires a HybridPiP build, Vulkan Forward+, hardware supporting the regional AMD
GI descriptor limits, and permission to launch the renderer. Run after the basic
regional image gate passes. Default: 640x360, no AA, base scale 1.0; native capacity
320x320, protected rectangle 128x128, octagonal clear aperture. A second pass with
`HYBRID_PIP_TAA=1` covers temporal history separately.

From the repository root in PowerShell, substitute the tested executable path:

```powershell
$fixtureEngine = 'C:\absolute\path\to\tested-godot.exe'
$env:GODOT_AMD_GI_VALIDATE_BINDINGS = '1'
$env:HYBRID_PIP_OUT = Join-Path $env:TEMP 'hybrid-pip-lifecycle-no-aa'
$env:HYBRID_PIP_TAA = '0'
New-Item -ItemType Directory -Force -Path $env:HYBRID_PIP_OUT | Out-Null
& $fixtureEngine --path docs/validation/hybrid_pip --script res://lifecycle.gd --rendering-method forward_plus --rendering-driver vulkan --windowed --resolution 640x360 --log-file (Join-Path $env:HYBRID_PIP_OUT 'engine.log')
```

For the second pass choose another output directory and set TAA to `1`.
Unset these process environment variables afterward if the same shell will run
other tests. The fixture's default output, without `HYBRID_PIP_OUT`, is its own
`user://hybrid_pip_lifecycle` directory.

The fixture checks actual ready/active states and render extents; six-frame
progress of shared GI diagnostics `batch.frame`/`batch.valid`; native GI progress during fallback;
visible, non-flat presentation and finite sampled presentation pixels; and color
separation between independent viewports. Stable prepared stages require the GI
frame delta to equal the renderer frame delta, checking one shared GI advance per
rendered frame rather than merely checking that GI advanced. Each readiness wait has a 120-second
limit. Failure exits nonzero and writes `lifecycle.json`; engine/validation-layer
errors also fail the run even if the script exits zero. A driver-level hang needs
an external watchdog because no script timer can run while rendering is blocked.

Covered transitions: prepared uniform to regional; repeated toggles; moving crop
and camera; blur on/off; shader replacement with SCREEN_UV/FRAGCOORD helper;
emissive and analytic-light zero crossings; moving MultiMesh instances and blend
shape geometry; odd 641x361 resize and reprepare; unsupported compositor callback
fallback and recovery; independent second viewport creation/destruction; complete
feature disable/reprepare; and final live-resource cleanup.

The image checks operate on presented output, not every intermediate HDR buffer.
Snapshots require visual review for seams, stale shadows, and ghosting. This does
not assert cache preservation, zero transition stalls, or deformation fidelity;
those require dedicated counters, timing, or geometric reference comparisons.

Validation on 2026-11-06: the no-AA and native-TAA lifecycle runs each completed
all 19 stages on the RTX 5090 with no reported failures or engine errors. Reviewed
captures cover toggles, movement, blur, resize, fallback/recovery, and independent
viewports. This confirms these lifecycle checks, not motion quality or performance.

## Live-owner shutdown check

Use the same command with `--script res://shutdown.gd` and a separate output
directory. First run with `HYBRID_PIP_INVALID_SHADER=0`, then another directory
with it set to `1`. Both prepare uniform rendering, activate regional rendering,
and quit with the viewport and presentation texture still live. The second run
replaces a material with a deliberately invalid shader, allows 30 rendered frames
to enter uniform fallback, and then quits. Reports retain the `lifecycle.json`
filename. These checks distinguish ordinary teardown from shader-failure teardown.

The valid variant permits no engine errors. The invalid variant permits only the
shader error naming `HYBRID_PIP_EXPECTED_INVALID_IDENTIFIER` and its immediately
associated shader-compilation error propagation. Do not blanket-ignore `ERROR:`:
invalid RID/free errors, device/validation errors, unrelated shader errors,
script assertion failures, or a nonzero exit code still fail either variant.
Review the complete process log after exit, since the fixture cannot observe
errors emitted by engine shutdown after its own final report.
Use `python verify_shader_failure.py <complete-stdout-log>` for the exact error
allowlist in the negative test, and separately require process exit 0. Engine
file logging may end before renderer teardown; retain redirected stdout/stderr.

## Combined GI queue checks

Run `res://queues.gd` with `GODOT_AMD_GI_VALIDATE_HITS=1`,
`GODOT_AMD_GI_VALIDATE_BOUNCES=1`, `GODOT_AMD_GI_VALIDATE_RESERVOIRS=1`, and
`HYBRID_PIP_LOG_FILE` set to the same absolute path passed to `--log-file`.
The environment variable is necessary because Godot consumes the log argument
before GDScript can inspect it. Eight stages cover all-hit caching and multibounce
on/off, each in uniform and regional mode. It requires positive live work,
actual secondary hits when enabled, fixed prepared capacity and one shared GI
frame advance per rendered frame. The enclosed generated room and continuation
probability 1 are test overrides, not recommended game settings.
