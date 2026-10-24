extends "res://amd_gi_consequential.gd"


func _run() -> void:
	var gi := "rendering/global_illumination/amd_gi/"
	ProjectSettings.set_setting(gi + "enabled", true)
	ProjectSettings.set_setting(gi + "probe_spacing", 16)
	ProjectSettings.set_setting(gi + "denoiser", true)
	ProjectSettings.set_setting(gi + "reflections/enabled", true)
	var material: StandardMaterial3D = get_node("Floor").mesh.material
	material.metallic = 0.7
	material.roughness = 0.15
	var camera := get_viewport().get_camera_3d()
	var attributes := CameraAttributesPractical.new()
	camera.attributes = attributes
	await _settle(32)
	await _capture("exposure_manual")
	attributes.exposure_multiplier = 4.0
	await _settle(16)
	await _capture("exposure_bright")
	attributes.exposure_multiplier = 1.0
	attributes.auto_exposure_enabled = true
	attributes.auto_exposure_speed = 10.0
	await _settle(32)
	await _capture("exposure_auto")
	_light.light_energy = 0.1
	await _settle(24)
	await _capture("exposure_dark_adapted")
	attributes.auto_exposure_enabled = false
	_light.light_energy = 1.8
	await _settle(32)
	await _capture("exposure_restored")
	print("AMD exposure integration completed: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
