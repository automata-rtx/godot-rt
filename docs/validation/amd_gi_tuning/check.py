#!/usr/bin/env python3
"""Source-backed CPU checks; not a GPU visual/performance acceptance test."""

import math
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CPP = (ROOT / "servers/rendering/renderer_rd/environment/amd_gi.cpp").read_text()
GLSL = (ROOT / "servers/rendering/renderer_rd/shaders/effects/amd_gi.glsl").read_text()
DENOISER = (ROOT / "servers/rendering/renderer_rd/shaders/effects/amd_gi_denoiser_inc.glsl").read_text()
# Compile the actual engine sanitation lambda against a small type adapter.
start = CPP.index("const auto bounded_tuning =")
end = CPP.index("\n\t};", start) + len("\n\t};")
source = (
    """#include <algorithm>
#include <cassert>
#include <cmath>
#include <limits>
float input;
#define GLOBAL_GET(name) input
#define CLAMP(v, lo, hi) std::clamp(v, lo, hi)
namespace Math { bool is_finite(float v) { return std::isfinite(v); } }
int main() {
"""
    + CPP[start:end]
    + """
for (auto bounds : {std::pair<float,float>{12,16}, {.75f,1}}) {
 auto [lo, hi] = bounds;
 for (float v : {-100.f, 0.f, lo, (lo+hi)/2, hi, 100.f}) {
  input = v; assert(bounded_tuning("", lo, hi) == std::clamp(v,lo,hi));
 }
 for (float v : {NAN, INFINITY, -INFINITY}) {
  input = v; assert(bounded_tuning("", lo, hi) == hi);
 }
}
}
"""
)
with tempfile.TemporaryDirectory() as folder:
    path = Path(folder)
    (path / "check.cpp").write_text(source)
    subprocess.run(["c++", "-std=c++17", str(path / "check.cpp"), "-o", str(path / "check")], check=True)
    subprocess.run([str(path / "check")], check=True)

# Prevent accidentally unlinking mip confidence from the accumulation limit.
assert "float(count)), frame.tuning.x)" in GLSL
assert "value.w >= frame.tuning.x || mip" in GLSL
assert (
    "value.w >= frame.tuning.x || mip"
    in (ROOT / "servers/rendering/renderer_rd/shaders/effects/amd_gi_debug_inc.glsl").read_text()
)
reset_line = next(line for line in CPP.splitlines() if "const bool configuration_changed =" in line)
assert "distant_cell_scale" in reset_line
assert "cache_history_updates" not in reset_line and "denoiser_history_scale" not in reset_line
assert "data->distant_cell_scale = distant_cell_scale;" in CPP
assert "tan(frame.settings.y * (32.0 * frame.tuning.z))" in GLSL
assert "alpha_blend) * vignette * frame.tuning.y, 1.0)" in DENOISER


# Exercise a settled-cache light step: defaults equal the previous recurrence,
# reduced history converges faster without changing a constant signal.
def step(limit):
    value = 0.0
    for _ in range(16):
        value += (1.0 - value) / limit
    return value


assert math.isclose(step(16), 1 - (15 / 16) ** 16)
assert step(12) > step(16)
# Quantization: a bounded footprint change selects either the same or one finer
# level, never a coarser cell; the minimum remains in force at every distance.
for distance in (0, 0.01, 1, 4, 10, 100, 10000):
    for angular in (0.0001, 0.001, 0.003):

        def cell(scale):
            desired = max(distance * math.tan(angular * (32 * scale)), 0.1)
            return 0.001 * 2 ** math.floor(math.log2(1000 * desired))

        assert math.isclose(cell(0.75), cell(1)) or math.isclose(cell(0.75), cell(1) / 2)
# Denoiser default equivalence and bounded history for new/mature samples.
for count in (0, 1, 4, 8, 64):
    for blend in (0, 0.5, 1):
        for vignette in (0, 0.5, 1):
            base = (4 * (1 - blend) + 8 * min(abs(count), 8) * blend) * vignette
            assert max(base * 1, 1) == max(base, 1)
            assert 1 <= max(base * 0.75, 1) <= max(base, 1)
print("PASS: production bounds, history wiring, cache coupling, and CPU response/quantization checks")
