"""Extract actual firefly shader code and make a standalone GPU fixture.

This prepares files only. run_gpu_fixture.ps1 is the separately authorized launcher.
"""

import argparse
import hashlib
import json
import math
import shutil
import struct
from pathlib import Path

SOURCE = Path(__file__).resolve().parent
ROOT = next(parent for parent in SOURCE.parents if (parent / "SConstruct").is_file())
SHADERS = ROOT / "servers/rendering/renderer_rd/shaders/effects"


def function(source, signature):
    start = source.index(signature)
    end = source.index("{", start)
    depth = 1
    end += 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def record(roughness, distance, color):
    # StoredReflection std430 stride is64, including final8 bytes of alignment.
    return (
        struct.pack("<8f", 0, 0, 0, roughness, 0, 0, 1, distance)
        + struct.pack("<4e", 0, 0, 1, 0)
        + struct.pack("<4e", *color, 1)
        + struct.pack("<4e", 0, 0, 0, 0)
        + bytes(8)
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".artifacts/gi-opt-20261026/firefly/generated")
    args = parser.parse_args()
    output = args.output.resolve()
    if output == SOURCE or output.is_relative_to(ROOT / "docs"):
        parser.error("Generated shaders, inputs and engine cache belong outside tracked documentation.")
    output.mkdir(parents=True, exist_ok=True)
    for name in ["gpu_fixture.gd", "project.godot"]:
        shutil.copyfile(SOURCE / name, output / name)
    reflection = (SHADERS / "amd_gi_reflections_inc.glsl").read_text()
    base = (SHADERS / "amd_gi.glsl").read_text()
    cache = (SHADERS / "amd_gi_cache_inc.glsl").read_text()
    mark = function(reflection, "void mark_reflection_fireflies(")
    ordinary = "} else {\n\t\t\tfloat center_luma"
    shortcut = "} else if (frame.glossy.y != 0.0 || frame.glossy.z != 1.0) {\n\t\t\tfloat center_luma"
    assert mark.count(ordinary) + mark.count(shortcut) == 1
    baseline = mark.replace(shortcut, ordinary)
    optimized = baseline.replace(ordinary, shortcut)
    assert baseline != optimized
    types = reflection[
        reflection.index("struct ReflectionSample {") : reflection.index("StoredReflection pack_reflection")
    ]
    helper = "\n".join([
        function(cache, "vec4 gi_cache_unpack("),
        function(reflection, "ReflectionSample unpack_reflection("),
        function(reflection, "ivec2 reflection_size("),
        function(reflection, "uint reflection_index("),
        function(reflection, "ivec2 reflection_phase("),
        function(reflection, "ivec2 reflection_pixel("),
        function(base, "float luma("),
    ])
    preamble = """#version 450
layout(local_size_x=8, local_size_y=8, local_size_z=1) in;
layout(push_constant, std430) uniform FixtureParams {
    uvec2 size; uint stride; uint padding;
    float low; float high; uint radius; uint reserved;
} params;
struct FrameData { vec4 reflections; vec4 glossy; uvec4 reflection_options; };
FrameData frame;
"""
    bindings = """
layout(set=0, binding=0, std430) readonly buffer Samples { StoredReflection data[]; } reflection_samples;
layout(rgba16f, set=0, binding=1) uniform image2D reflection_filter_a;
"""
    entry = """
void main() {
    frame.reflections=vec4(float(params.stride),0.6,0,0);
    frame.glossy=vec4(0,params.low,params.high,0);
    frame.reflection_options=uvec4(0,0,params.radius,0);
    ivec2 pixel=ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(pixel, reflection_size()))) return;
    mark_reflection_fireflies(pixel, reflection_index(pixel));
}
"""
    emitted = {}
    for name, mark_body in [("baseline", baseline), ("optimized", optimized)]:
        shader = preamble + types + bindings + helper + "\n" + mark_body + entry
        (output / f"{name}.comp").write_text(shader, newline="\n")
        emitted[name] = hashlib.sha256(shader.encode()).hexdigest()

    colors = [0.0, -0.0, 0.125, 0.5, 1.0, -1.0, math.inf, -math.inf, math.nan]
    roughnesses = [-1.0, 0.0, 0.2, 0.6, 0.7, math.nan]
    distances = [-math.inf, -1.0, -0.0, 0.0, 1.0, math.inf, math.nan]
    samples = bytearray()
    for i in range(32 * 24):
        c = [colors[(i * p + i // 7) % len(colors)] for p in [1, 3, 5]]
        samples.extend(record(roughnesses[(i + i // 11) % 6], distances[(i + i // 13) % 7], c))
    (output / "samples.bin").write_bytes(samples)
    # The microbenchmark deliberately makes every pixel eligible. It measures
    # this pass, not a game scene or the whole GI renderer.
    tile = bytearray()
    for i in range(4096):
        tile.extend(record(0.25, 1.0, ((i % 29) / 29, (i % 47) / 47, (i % 71) / 71)))
    pixels = 1280 * 720
    (output / "bench_samples.bin").write_bytes((tile * ((pixels + 4095) // 4096))[: pixels * 64])
    manifest = {
        "source": "servers/rendering/renderer_rd/shaders/effects/amd_gi_reflections_inc.glsl",
        "source_sha256": hashlib.sha256(reflection.encode()).hexdigest(),
        "source_already_optimized": shortcut in mark,
        "shader_sha256": emitted,
        "baseline_function_sha256": hashlib.sha256(baseline.encode()).hexdigest(),
        "optimized_function_sha256": hashlib.sha256(optimized.encode()).hexdigest(),
        "method": "Actual production mark function, packed sample layout, unpack, luminance and pixel-coordinate helpers; minimal external bindings.",
        "timing_scope": "Synthetic isolated marking pass with every pixel eligible; not a game benchmark.",
    }
    (output / "fixture_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
