#!/bin/bash
# Render one of the shadow validation rigs under Xvfb + lavapipe and score it.
#
#   ./run.sh field                          the chunky-blade field, default variants
#   ./run.sh field_thin                     the same comparison at 2.2 x 0.4 cm
#   ./run.sh opacity                        is shadow_opacity linear on a raytraced sun
#   SHADOW_THICKNESS=0.0025,0.005,0.010 ./run.sh field --bands
#   SSS_HARDNESS=0.5 ./run.sh probe         one variant of the 20-prism rig
#
# Anything after the rig name is passed to score.py.
#
# Software rendering, deliberately, and the raytraced reference is REAL under it:
# lavapipe advertises ray query support, the fork takes it, and GODOT_RT_DEBUG=1
# shows the TLAS built and a mask slot granted and written. Do not be put off by
# the "OpTypeRayQueryKHR is not supported yet." line at startup -- it comes from
# the Mesa stack rather than from the engine, is printed once, and does not stop
# the trace: the opacity rig can tell the raytraced branch from the shadow-map
# branch, which is only possible if the mask is genuinely there.
#
# What software rendering cannot tell you is COST. Every timing under lavapipe is
# meaningless, so profile on hardware.
set -u

RIG="${1:-field}"
shift || true

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${GODOT_BIN:-$HERE/../../../bin/godot.linuxbsd.editor.x86_64}"
# Per rig, because each published table was measured at its own resolution and
# the resolution is not cosmetic here: it sets how many PIXELS wide a blade is,
# and the whole question `hardness` answers is what happens to an occluder
# narrower than the march's one-pixel sample spacing. Override with SHADOW_RES
# only when deliberately re-deriving rather than reproducing.
case "$RIG" in
	field)      RIG_RES=1600x900 ;;
	field_thin) RIG_RES=1280x720 ;;
	probe)      RIG_RES=1280x720 ;;
	opacity)    RIG_RES=800x450 ;;
	*)          RIG_RES=1280x720 ;;
esac
RES="${SHADOW_RES:-$RIG_RES}"
DISP="${SHADOW_DISPLAY:-:99}"
OUT="$HERE/out/$RIG"

if [ ! -x "$BIN" ]; then
	echo "no engine binary at $BIN -- build one, or set GODOT_BIN" >&2
	exit 1
fi
if [ ! -f "$HERE/$RIG.tscn" ]; then
	echo "no rig '$RIG' -- expected one of: probe field field_thin opacity" >&2
	exit 1
fi

# Parse-check headlessly FIRST. A GDScript parse error otherwise costs the whole
# render: Godot opens a window, fails to load the scene, and sits there until the
# timeout. That burned ten minutes once.
echo "--- parse check ---"
PARSE=$(timeout 120 "$BIN" --headless --path "$HERE" --check-only --script "res://$RIG.gd" 2>&1 \
	| grep -iE "SCRIPT ERROR|Parse Error|error:")
if [ -n "$PARSE" ]; then
	echo "PARSE FAILED:"
	echo "$PARSE"
	exit 1
fi
echo "parses clean"

mkdir -p "$OUT"
# Both, and before the run: the rig writes to res://out/, and a stale capture
# left there by a different rig would otherwise be swept into this rig's results
# by the move at the end and scored as if it belonged.
rm -f "$OUT"/*.png "$HERE/out"/*.png

Xvfb "$DISP" -screen 0 "${RES%x*}x${RES#*x}x24" -nolisten tcp >/dev/null 2>&1 &
XVFB=$!
# Do NOT pkill by pattern to clean up: the pattern matches this script's own
# command line and takes the run down with it. That happened twice.
trap 'kill $XVFB 2>/dev/null' EXIT
sleep 3

export DISPLAY="$DISP"
export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
export GODOT_SILENCE_ROOT_WARNING=1
export SHADOW_OUT_DIR="$OUT"

# stdbuf keeps the per-stage prints flowing, so progress is visible mid-run
# rather than arriving in one 4 KB block at the end.
LOG="$OUT/run.log"
# --audio-driver Dummy: there is no sound card under Xvfb, and ALSA's failure
# prints an ERR_CANT_OPEN that looks exactly like a capture failing to save.
timeout "${SHADOW_TIMEOUT:-1800}" stdbuf -oL -eL "$BIN" --path "$HERE" \
	--rendering-driver vulkan --audio-driver Dummy --resolution "$RES" \
	"res://$RIG.tscn" > "$LOG" 2>&1
echo "godot exit=$?"
grep -aE "^(===|saved|stage)" "$LOG"
grep -aiE "SCRIPT ERROR|ERROR: Condition|not provided" "$LOG" | head -5

# The rig writes to res://out/, which is the project directory, not $OUT.
mv "$HERE/out"/*.png "$OUT/" 2>/dev/null

echo
if [ "$RIG" = "opacity" ]; then
	python3 "$HERE/score_opacity.py" "$OUT" "$@"
else
	python3 "$HERE/score.py" "$OUT" "$@"
fi
