#!/bin/bash
# Software-Vulkan capture. Requires Xvfb and a ray-query-capable ICD.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
experiment="${1:-baseline}"
output="${2:?Pass an absolute output directory}"
rig="${GI_TEST_RIG:-amd_gi_improvements}"
resolution="${GI_TEST_RESOLUTION:-640x360}"
mkdir -p "$output" "$output/runtime/data" "$output/runtime/config" "$output/runtime/cache"
export XDG_DATA_HOME="$output/runtime/data"
export XDG_CONFIG_HOME="$output/runtime/config"
# Share explicitly selected shader cache across matched runs when desired.
export XDG_CACHE_HOME="${GI_TEST_CACHE:-$output/runtime/cache}"
export SHADOW_OUT_DIR="$output" GI_EXPERIMENT="$experiment"
export DISPLAY="${GI_TEST_DISPLAY:-:97}"
export GODOT_AMD_GI_TRACE_HISTORY=1
binary="${GODOT_BIN:-$repo/bin/godot.linuxbsd.editor.x86_64}"
"$binary" --headless --path "$repo/docs/validation/shadow_validation" --check-only --script "res://$rig.gd" > "$output/parse.log" 2>&1
if rg -q 'SCRIPT ERROR|Parse Error' "$output/parse.log"; then
    cat "$output/parse.log"
    exit 1
fi
"${XVFB_BIN:-Xvfb}" "$DISPLAY" -screen 0 "${resolution}x24" -nolisten tcp > "$output/display.log" 2>&1 &
display_pid=$!
trap 'kill "$display_pid" 2>/dev/null || true' EXIT
sleep 1
"$binary" --path "$repo/docs/validation/shadow_validation" --rendering-driver vulkan --audio-driver Dummy --windowed --resolution "$resolution" --fixed-fps 60 "res://$rig.tscn" > "$output/render.log" 2>&1
rg 'IMPROVEMENTS(_LIFECYCLE)? complete' "$output/render.log"
if rg -q 'ERROR:|SCRIPT ERROR|Shader compilation failed' "$output/render.log"; then
    rg 'ERROR:|SCRIPT ERROR|Shader compilation failed' "$output/render.log"
    exit 1
fi
sha256sum "$binary" > "$output/executable.sha256"
