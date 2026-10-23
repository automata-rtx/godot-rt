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
	geometry)   RIG_RES=641x359 ;;
	material)   RIG_RES=641x359 ;;
	gi)         RIG_RES=641x359 ;;
	gi_compare) RIG_RES=641x359 ;;
	amd_gi)     RIG_RES=641x359 ;;
	amd_gi_sampling) RIG_RES=641x359 ;;
	amd_gi_cache) RIG_RES=641x359 ;;
	amd_gi_materials) RIG_RES=641x359 ;;
	amd_gi_dirty_materials) RIG_RES=641x359 ;;
	amd_gi_lights) RIG_RES=641x359 ;;
	amd_gi_bounces) RIG_RES=641x359 ;;
	amd_gi_feedback) RIG_RES=641x359 ;;
	amd_gi_hit_updates) RIG_RES=641x359 ;;
	amd_gi_sky) RIG_RES=641x359 ;;
	amd_gi_reflections) RIG_RES=641x359 ;;
	amd_gi_fsr2) RIG_RES=641x359 ;;
	amd_gi_dynamic_lighting) RIG_RES=641x359 ;;
	amd_gi_atlas) RIG_RES=641x359 ;;
	amd_gi_material_sharing) RIG_RES=641x359 ;;
	amd_gi_multimesh) RIG_RES=641x359 ;;
	amd_gi_overlays) RIG_RES=641x359 ;;
	amd_gi_opacity) RIG_RES=641x359 ;;
	amd_gi_material_density) RIG_RES=641x359 ;;
	amd_gi_scene_churn|amd_gi_flashlight) RIG_RES=321x181 ;;
	amd_gi_deformation) RIG_RES=641x359 ;;
	amd_gi_budget_compare) RIG_RES=641x359 ;;
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
	echo "no rig '$RIG' -- expected one of: probe field field_thin opacity geometry material gi gi_compare amd_gi amd_gi_sampling amd_gi_cache amd_gi_materials amd_gi_lights amd_gi_bounces amd_gi_sky amd_gi_reflections amd_gi_dirty_materials amd_gi_fsr2 amd_gi_dynamic_lighting amd_gi_atlas amd_gi_deformation amd_gi_budget_compare amd_gi_material_sharing" >&2
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
if [ "$RIG" = "geometry" ]; then
	export GODOT_RT_DEBUG=1
fi
if [ "$RIG" = "amd_gi_scene_churn" ] || [ "$RIG" = "amd_gi_flashlight" ]; then
	export GODOT_AMD_GI_TRACE_HISTORY=1
fi
if [ "$RIG" = "amd_gi_material_density" ] || [ "$RIG" = "amd_gi_sampling" ] || [ "$RIG" = "amd_gi_cache" ] || [ "$RIG" = "amd_gi_dynamic_lighting" ] || [ "$RIG" = "amd_gi_deformation" ] || [ "$RIG" = "amd_gi_budget_compare" ] || [ "$RIG" = "amd_gi_reflections" ] || [ "$RIG" = "amd_gi_multimesh" ] || [ "$RIG" = "amd_gi_overlays" ]; then
	# Synchronous diagnostic readback validates actual GPU scheduling/LRU state.
	# This rig is deliberately not a performance benchmark.
	export GODOT_AMD_GI_VALIDATE_CACHE=1
fi
if [ "$RIG" = "amd_gi_material_density" ] || [ "$RIG" = "amd_gi_materials" ] || [ "$RIG" = "amd_gi_dirty_materials" ] || [ "$RIG" = "amd_gi_material_sharing" ] || [ "$RIG" = "amd_gi_atlas" ] || [ "$RIG" = "amd_gi_deformation" ]; then
	export GODOT_AMD_GI_VALIDATE_MATERIALS=1
fi
if [ "$RIG" = "amd_gi_lights" ]; then
	export GODOT_AMD_GI_VALIDATE_RESERVOIRS=1
fi
if [ "$RIG" = "amd_gi_hit_updates" ]; then
	export GODOT_AMD_GI_VALIDATE_HITS=1
fi
if [ "$RIG" = "amd_gi_feedback" ]; then
	export GODOT_AMD_GI_VALIDATE_FEEDBACK=1
fi
if [ "$RIG" = "amd_gi_bounces" ]; then
	export GODOT_AMD_GI_VALIDATE_BOUNCES=1
fi
if [ "$RIG" = "amd_gi_reflections" ]; then
	export GODOT_AMD_GI_VALIDATE_REFLECTIONS=1
fi

# stdbuf keeps the per-stage prints flowing, so progress is visible mid-run
# rather than arriving in one 4 KB block at the end.
LOG="$OUT/run.log"
# --audio-driver Dummy: there is no sound card under Xvfb, and ALSA's failure
# prints an ERR_CANT_OPEN that looks exactly like a capture failing to save.
timeout "${SHADOW_TIMEOUT:-1800}" stdbuf -oL -eL "$BIN" --path "$HERE" \
	--rendering-driver vulkan --audio-driver Dummy --resolution "$RES" \
	"res://$RIG.tscn" > "$LOG" 2>&1
RENDER_STATUS=$?
echo "godot exit=$RENDER_STATUS"
if [ "$RENDER_STATUS" -ne 0 ]; then
	tail -n 30 "$LOG"
	exit "$RENDER_STATUS"
fi
grep -aE "^(===|saved|stage)" "$LOG"
grep -aiE "SCRIPT ERROR|ERROR: Condition|not provided" "$LOG" | head -5

# The rig writes to res://out/, which is the project directory, not $OUT.
mv "$HERE/out"/*.png "$OUT/" 2>/dev/null

echo
if [ "$RIG" = "opacity" ]; then
	python3 "$HERE/score_opacity.py" "$OUT" "$@"
elif [ "$RIG" = "amd_gi_scene_churn" ] || [ "$RIG" = "amd_gi_flashlight" ]; then
	python3 "$HERE/score_$RIG.py" "$OUT"
elif [ "$RIG" = "amd_gi_material_density" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:|GI is suppressed' "$LOG" || ! grep -aq 'AMD material density capture finished: 0 failures' "$LOG"; then
		echo "GI material density validation failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi_material_density.py" "$OUT"
elif [ "$RIG" = "amd_gi_opacity" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:|GI is suppressed' "$LOG" || ! grep -aq 'AMD opacity capture finished: 0 failures' "$LOG"; then
		echo "GI opacity validation failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi_opacity.py" "$OUT"
elif [ "$RIG" = "amd_gi_overlays" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG"; then
		exit 1
	fi
	python3 "$HERE/score_amd_gi_overlays.py" "$OUT"
elif [ "$RIG" = "amd_gi_multimesh" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG"; then
		echo "AMD MultiMesh capture failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi_multimesh.py" "$OUT" "$@"
elif [ "$RIG" = "amd_gi_material_sharing" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'AMD material sharing capture finished: 0 failures' "$LOG"; then
		echo "AMD material sharing capture failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi_material_sharing.py" "$OUT"
elif [ "$RIG" = "amd_gi_atlas" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'AMD atlas capture finished: 0 failures' "$LOG"; then
		echo "AMD atlas capture failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi_atlas.py" "$OUT"
elif [ "$RIG" = "amd_gi_budget_compare" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'AMD budget comparison finished: 0 failures' "$LOG"; then
		echo "AMD budget comparison failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi_budget_compare.py" "$OUT"
elif [ "$RIG" = "amd_gi_deformation" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'AMD deformation capture finished: 0 failures' "$LOG"; then
		echo "AMD deformation capture failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi_deformation.py" "$OUT"
elif [ "$RIG" = "amd_gi_dynamic_lighting" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'AMD dynamic lighting capture finished: 0 failures' "$LOG"; then
		echo "AMD dynamic lighting capture failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi_dynamic_lighting.py" "$OUT"
elif [ "$RIG" = "amd_gi_fsr2" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'AMD FSR2 capture finished: 0 failures' "$LOG"; then
		echo "AMD FSR2 capture failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi_fsr2.py" "$OUT"
elif [ "$RIG" = "amd_gi_dirty_materials" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'AMD dirty material capture finished: 0 failures' "$LOG"; then
		echo "AMD dirty material capture failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi_dirty_materials.py" "$OUT"
elif [ "$RIG" = "amd_gi_reflections" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'AMD reflection capture finished: 0 failures' "$LOG"; then
		echo "AMD reflection capture failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi_reflections.py" "$OUT"
elif [ "$RIG" = "amd_gi_sky" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'AMD sky capture finished: 0 failures' "$LOG"; then
		echo "AMD sky capture failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi_sky.py" "$OUT"
elif [ "$RIG" = "amd_gi_hit_updates" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG"; then
		exit 1
	fi
	python3 "$HERE/score_amd_gi_hit_updates.py" "$OUT"
elif [ "$RIG" = "amd_gi_feedback" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG"; then
		exit 1
	fi
	python3 "$HERE/score_amd_gi_feedback.py" "$OUT"
elif [ "$RIG" = "amd_gi_bounces" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'AMD multibounce capture finished: 0 failures' "$LOG"; then
		echo "AMD multibounce capture failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi_bounces.py" "$OUT"
elif [ "$RIG" = "amd_gi_lights" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'AMD light sampling capture finished: 0 failures' "$LOG"; then
		echo "AMD light sampling failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi_lights.py" "$OUT"
elif [ "$RIG" = "amd_gi_materials" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'AMD material preparation capture finished: 0 failures' "$LOG"; then
		echo "AMD material preparation failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi_materials.py" "$OUT"
elif [ "$RIG" = "amd_gi_cache" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'AMD cache capture finished: 0 failures' "$LOG"; then
		echo "AMD cache capture failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi_cache.py" "$OUT"
elif [ "$RIG" = "amd_gi_sampling" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'AMD sampling capture finished: 0 failures' "$LOG"; then
		echo "AMD sampling capture failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi_sampling.py" "$OUT"
elif [ "$RIG" = "amd_gi" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'AMD GI progress capture finished: 0 failures' "$LOG"; then
		echo "AMD GI progress capture failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_amd_gi.py" "$OUT"
elif [ "$RIG" = "gi_compare" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'GI comparison capture finished: 0 failures' "$LOG"; then
		echo "GI comparison failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_gi_compare.py" "$OUT"
elif [ "$RIG" = "gi" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'GI validation capture finished: 0 failures' "$LOG"; then
		echo "GI validation failed; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score_gi.py" "$OUT"
elif [ "$RIG" = "material" ]; then
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG" || ! grep -aq 'material capture checks finished: 0 failures' "$LOG"; then
		echo "material capture validation failed; inspect $LOG" >&2
		exit 1
	fi
	echo "material capture analytical checks passed"
elif [ "$RIG" = "geometry" ]; then
	if ! grep -aqE 'RT_DEBUG pre_opaque: .*tlas=1' "$LOG"; then
		echo "geometry validation did not establish a traceable TLAS" >&2
		exit 1
	fi
	if grep -aqE 'SCRIPT ERROR|ERROR:' "$LOG"; then
		echo "geometry validation logged an error; inspect $LOG" >&2
		exit 1
	fi
	python3 "$HERE/score.py" "$OUT" --geometry "$@"
else
	python3 "$HERE/score.py" "$OUT" "$@"
fi
