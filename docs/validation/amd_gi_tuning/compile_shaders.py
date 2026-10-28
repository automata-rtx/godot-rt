"""Compile affected passes with a constant material stub; no GPU execution."""

import argparse
import re
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--compiler", default="glslangValidator")
args = parser.parse_args()
root = Path(__file__).resolve().parents[3] / "servers/rendering/renderer_rd/shaders/effects"


def expand(p):
    s = p.read_text()
    return re.sub(r'^#include "([^"]+)"', lambda m: expand(p.parent / m[1]), s, flags=re.M)


s = expand(root / "amd_gi.glsl").replace("#[compute]", "")
stub = """GISourceMaterial gi_source_material(uint instance, uint primitive, vec2 barycentrics, bool front_face, float lod) { return GISourceMaterial(vec4(1),vec4(0),vec4(1)); }
GISourceMaterial gi_source_material_filtered(uint instance, uint primitive, vec2 barycentrics, bool front_face, float lod, bool filtered) { return gi_source_material(instance, primitive, barycentrics, front_face, lod); }
"""
s = s.replace("#GLOBALS", stub)
temporary = tempfile.TemporaryDirectory()
folder = Path(temporary.name)
for stage in [1, 19, 27, 32, 40, 41, 42, 43, 57]:
    path = folder / "gi_tuning.comp"
    path.write_text(s.replace("#VERSION_DEFINES", f"#define AMD_GI_PASS {stage}"))
    r = subprocess.run(
        [
            args.compiler,
            "-V",
            "--target-env",
            "vulkan1.2",
            "-S",
            "comp",
            str(path),
            "-o",
            str(folder / "gi_tuning.spv"),
        ],
        capture_output=True,
        text=True,
    )
    if r.returncode:
        print(r.stdout, r.stderr)
        raise SystemExit(r.returncode)
print("PASS: nine affected GLSL passes compile to SPIR-V (constant material stub, no GPU execution)")

temporary.cleanup()
