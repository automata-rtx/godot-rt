extends "res://amd_gi.gd"

const GI := "rendering/global_illumination/amd_gi/"

func _run() -> void:
	ProjectSettings.set_setting(GI + "enabled", false)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	_light.visible = false
	var flashlight := SpotLight3D.new()
	flashlight.position = Vector3(0, 1.7, 2.4)
	flashlight.light_energy = 6.0
	flashlight.spot_range = 45.0
	flashlight.spot_angle = 26.0
	flashlight.light_size = 0.0
	add_child(flashlight)
	flashlight.look_at(Vector3(-1.7, 1.0, -2.4))
	await _settle(8)
	await _capture("flashlight_left_direct")
	ProjectSettings.set_setting(GI + "enabled", true)
	await _settle(64)
	await _capture("flashlight_left_gi")
	print("FLASHLIGHT stage: continuous movement")
	for step in 32:
		flashlight.position.x += 0.025
		flashlight.look_at(Vector3(lerpf(-1.7, 1.7, float(step + 1) / 32.0), 1.0, -2.4))
		await _settle(1)
	print("FLASHLIGHT stage: right settle")
	await _settle(64)
	await _capture("flashlight_right_gi")
	ProjectSettings.set_setting(GI + "enabled", false)
	await _settle(8)
	await _capture("flashlight_right_direct")
	ProjectSettings.set_setting(GI + "light_resampling", false)
	ProjectSettings.set_setting(GI + "enabled", true)
	await _settle(64)
	await _capture("flashlight_right_exhaustive")
	flashlight.visible = false
	await _settle(4)
	await _capture("flashlight_off_6")
	await _settle(18)
	await _capture("flashlight_off_gi")
	ProjectSettings.set_setting(GI + "enabled", false)
	await _settle(8)
	await _capture("flashlight_off_direct")
	get_tree().quit(1 if _failures else 0)
