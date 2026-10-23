extends "res://amd_gi.gd"


func _run() -> void:
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/denoiser", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/multibounce", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/max_distance", 20.0)
	# Four identical lights have the same visibility and target distribution.
	# This isolates RIS normalization before the varied-light case below.
	_light.light_energy *= 0.25
	var lights: Array[Light3D] = [_light]
	for i in 3:
		var light := OmniLight3D.new()
		light.position = _light.position
		light.light_energy = _light.light_energy
		light.omni_range = _light.omni_range
		light.light_size = 0.0
		light.shadow_enabled = true
		add_child(light)
		lights.append(light)
	await _settle(12)
	await _capture("lights_disabled")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/light_resampling", false)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	await _settle(64)
	await _capture("lights_exhaustive")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/light_resampling", true)
	await _settle(64)
	await _capture("lights_resampled")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/light_resampling", false)
	await _settle(64)
	await _capture("lights_exhaustive_restored")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	lights[1].position += Vector3(1.5, -0.4, -1.0)
	lights[1].light_color = Color(0.2, 0.4, 1.0)
	lights[2].position += Vector3(-1.2, -0.5, 1.0)
	lights[2].light_color = Color(1.0, 0.3, 0.1)
	lights[3].position += Vector3(0.8, -1.5, -1.0)
	lights[3].light_energy *= 2.0
	# Six leaves exercise incomplete tree levels and all three analytic types.
	var spot := SpotLight3D.new()
	spot.position = Vector3(0.0, 1.8, 0.0)
	spot.rotation_degrees.x = -90.0
	spot.light_energy = 0.15
	spot.spot_range = 5.0
	spot.light_size = 0.0
	spot.shadow_enabled = true
	add_child(spot)
	lights.append(spot)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -25.0, 0.0)
	sun.light_energy = 0.015
	sun.light_angular_distance = 0.0
	add_child(sun)
	lights.append(sun)
	await _settle(12)
	await _capture("lights_varied_disabled")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	await _settle(64)
	await _capture("lights_varied_exhaustive")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/light_resampling", true)
	await _settle(64)
	await _capture("lights_varied_resampled")
	for light in lights:
		light.light_indirect_energy = 0.0
	await _settle(12)
	await _capture("lights_indirect_zero")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	await _settle(12)
	await _capture("lights_disabled_after")
	print("AMD light sampling capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
