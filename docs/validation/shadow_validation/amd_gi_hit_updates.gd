extends "res://amd_gi.gd"

const GI := "rendering/global_illumination/amd_gi/"


func _run() -> void:
	ProjectSettings.set_setting(GI + "enabled", false)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	ProjectSettings.set_setting(GI + "denoiser", true)
	ProjectSettings.set_setting(GI + "multibounce", true)
	ProjectSettings.set_setting(GI + "max_distance", 20.0)
	await _settle(12)
	await _capture("hits_disabled")
	for stage in ["one", "all", "one_restored"]:
		ProjectSettings.set_setting(GI + "cache_all_hits", stage == "all")
		ProjectSettings.set_setting(GI + "enabled", true)
		await _settle(64)
		await _capture("hits_" + stage)
	ProjectSettings.set_setting(GI + "cache_all_hits", true)
	ProjectSettings.set_setting(GI + "multibounce", false)
	await _settle(64)
	await _capture("hits_all_single")
	ProjectSettings.set_setting(GI + "enabled", false)
	await _settle(12)
	await _capture("hits_disabled_after")
	print("AMD hit update capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
