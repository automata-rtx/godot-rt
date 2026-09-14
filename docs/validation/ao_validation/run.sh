#!/bin/bash
# Render the occlusion captures under Xvfb + lavapipe.
#
#   ./run.sh room gtao          the room scene, ground truth estimator
#   ./run.sh room legacy        the same scene, the estimator Godot has always shipped
#   ./run.sh thin gtao          the louvre scene
#   ./run.sh "" gtao            the default solid-boxes scene
#
# Produces two captures per run into out/<scene>_<method>/:
#   noao.png    occlusion disabled -- the DIVISOR
#   ao.png      occlusion on
#
# ao_compare.py divides one by the other, undoing the sRGB transfer first, which
# recovers the occlusion term itself rather than something the shading has
# already mixed in. That division is the whole reason main.gd renders with
# ambient light only, a fully rough non-specular white material, and no direct
# light. See README.md.
#
# The CPU references are separate and slower; this script does not run them:
#   python3 ao_truth.py 1.0 truth.npz
#   python3 ao_screen_truth.py 1.0 0.3 screen.npz
#   python3 ao_compare.py truth.npz out/room_gtao/noao.png gtao=out/room_gtao/ao.png
set -u

SCENE="${1-}"
METHOD_NAME="${2:-gtao}"
case "$METHOD_NAME" in
	legacy) AO_METHOD=0 ;;
	gtao|ground_truth) AO_METHOD=1 ;;
	*) echo "method must be 'legacy' or 'gtao', not '$METHOD_NAME'" >&2; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${GODOT_BIN:-$HERE/../../../bin/godot.linuxbsd.editor.x86_64}"
DISP="${AO_DISPLAY:-:99}"
OUT="$HERE/out/${SCENE:-solid}_$METHOD_NAME"

if [ ! -x "$BIN" ]; then
	echo "no engine binary at $BIN -- build one, or set GODOT_BIN. See README.md." >&2
	exit 1
fi

# Parse-check headlessly first. A GDScript parse error otherwise leaves Godot
# sitting on an empty window until the timeout rather than exiting.
PARSE=$(timeout 120 "$BIN" --headless --path "$HERE" --check-only --script res://main.gd 2>&1 \
	| grep -iE "SCRIPT ERROR|Parse Error|error:")
if [ -n "$PARSE" ]; then echo "PARSE FAILED:"; echo "$PARSE"; exit 1; fi

mkdir -p "$OUT"
rm -f "$OUT"/*.png

# main.gd sizes the viewport itself -- the scenes are not all the same shape, and
# only a non-square one can catch an aspect-dependent defect -- so Xvfb just has
# to be at least as large as the largest of them.
Xvfb "$DISP" -screen 0 1600x1200x24 -nolisten tcp >/dev/null 2>&1 &
XVFB=$!
# Kill by PID. `pkill -f` matches this script's own command line.
trap 'kill $XVFB 2>/dev/null' EXIT
sleep 3

export DISPLAY="$DISP"
export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
export GODOT_SILENCE_ROOT_WARNING=1
export AO_SCENE="$SCENE" AO_METHOD

for pass in noao ao; do
	if [ "$pass" = "noao" ]; then export AO_OFF=1; else unset AO_OFF; fi
	RT_TEST_OUT="$OUT/$pass.png" timeout "${AO_TIMEOUT:-900}" "$BIN" --path "$HERE" \
		--rendering-driver vulkan --audio-driver Dummy > "$OUT/$pass.log" 2>&1
	echo "$pass: exit=$? $(grep -a '^AOREF' "$OUT/$pass.log" | tr '\n' ' ')"
done

ls -la "$OUT"/*.png 2>/dev/null || echo "NO CAPTURES -- see $OUT/*.log"
