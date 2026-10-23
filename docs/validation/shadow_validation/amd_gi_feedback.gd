extends "res://amd_gi.gd"

const GI := "rendering/global_illumination/amd_gi/"


func _run() -> void:
	ProjectSettings.set_setting(GI + "enabled", false)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	ProjectSettings.set_setting(GI + "denoiser", true)
	ProjectSettings.set_setting(GI + "multibounce", true)
	ProjectSettings.set_setting(GI + "screen_feedback", true)
	ProjectSettings.set_setting(GI + "max_distance", 20.0)
	var environment := get_viewport().find_world_3d().environment
	var camera := get_viewport().get_camera_3d()
	var attributes := CameraAttributesPractical.new()
	camera.attributes = attributes
	await _settle(12)
	await _capture("feedback_disabled")
	for stage in ["plain", "fog", "exposure"]:
		environment.fog_enabled = stage == "fog"
		environment.fog_density = 0.12
		attributes.exposure_multiplier = 2.0 if stage == "exposure" else 1.0
		print("stage feedback: " + stage)
		ProjectSettings.set_setting(GI + "enabled", true)
		await _settle(62)
		await _capture("feedback_" + stage)
		ProjectSettings.set_setting(GI + "enabled", false)
		await _settle(12)
	environment.fog_enabled = false
	attributes.exposure_multiplier = 1.0
	ProjectSettings.set_setting(GI + "enabled", true)
	ProjectSettings.set_setting(GI + "screen_feedback", false)
	await _settle(64)
	await _capture("feedback_off")
	ProjectSettings.set_setting(GI + "screen_feedback", true)
	await _settle(64)
	await _capture("feedback_restored")
	_light.light_indirect_energy = 0.0
	await _settle(12)
	await _capture("feedback_indirect_zero")
	_light.light_indirect_energy = 1.0
	ProjectSettings.set_setting(GI + "enabled", false)
	await _settle(12)
	await _capture("feedback_disabled_after")
	print("AMD feedback capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
