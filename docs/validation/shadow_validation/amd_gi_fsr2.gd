extends "res://amd_gi.gd"


func _run() -> void:
	var viewport := get_viewport()
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	viewport.scaling_3d_scale = 0.5
	viewport.use_taa = false
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/denoiser", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/multibounce", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/reflections/enabled", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/max_distance", 20.0)
	var floor_material: StandardMaterial3D = get_node("Floor").mesh.material
	floor_material.metallic = 0.5
	floor_material.roughness = 0.25
	floor_material.metallic_specular = 1.0
	print("=== AMD GI + FSR2 performance: 641x359 display, truncated 320x179 internal, denoiser/reflections/multibounce ON ===")
	await _settle(64)
	await _capture("fsr2_disabled")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	await _settle(64)
	await _capture("fsr2_quarter")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 8)
	await _settle(64)
	await _capture("fsr2_one")
	var camera := viewport.get_camera_3d()
	var original := camera.transform
	for frame in 16:
		camera.position.x += 0.02
		await _settle(1)
	await _capture("fsr2_motion")
	camera.transform = original
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
	await _settle(64)
	await _capture("fsr2_restored")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	await _settle(64)
	await _capture("fsr2_disabled_after")
	print("AMD FSR2 capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
