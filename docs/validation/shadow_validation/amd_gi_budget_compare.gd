extends "res://amd_gi.gd"

# Matched runtime-history captures. Both budgets start from released GI resources,
# use exactly the same settle/capture sequence, and keep all filters enabled.
const GI := "rendering/global_illumination/amd_gi/"


func _run() -> void:
	ProjectSettings.set_setting(GI + "enabled", false)
	for feature in ["denoiser", "importance_sampling", "adaptive_sampling", "probe_cache", "light_resampling", "multibounce", "reflections/enabled", "reflections/half_resolution"]:
		ProjectSettings.set_setting(GI + feature, true)
	ProjectSettings.set_setting(GI + "max_distance", 20.0)
	ProjectSettings.set_setting(GI + "continuation_probability", 0.3)
	ProjectSettings.set_setting(GI + "reflections/filter_passes", 3)
	ProjectSettings.set_setting(GI + "reflections/probe_roughness_threshold", 0.6)
	await _settle(12)
	await _capture("budget_disabled")
	for spacing in [16, 8]:
		ProjectSettings.set_setting(GI + "probe_spacing", spacing)
		ProjectSettings.set_setting(GI + "enabled", true)
		print("stage budget: spacing=%d; 62 settle draws + 2 capture draws; denoiser ON" % spacing)
		await _settle(62)
		await _capture("budget_quarter" if spacing == 16 else "budget_one")
		ProjectSettings.set_setting(GI + "enabled", false)
		await _settle(12)
	await _capture("budget_disabled_after")
	print("AMD budget comparison finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
