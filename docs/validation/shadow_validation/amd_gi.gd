extends "res://gi.gd"

# Progress captures use the live sparse pipeline, with its denoiser enabled.
# No high-sample reference tracing or offline accumulation is used here.


func _settle(frames: int) -> void:
	for frame in frames:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw


func _run() -> void:
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/denoiser", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/importance_sampling", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/adaptive_sampling", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_cache", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/multibounce", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/max_distance", 20.0)
	print("=== AMD GI diffuse progress: 64 directions per 16x16 screen tile (~1/4 primary ray/pixel/frame), multibounce probability 0.3, probe filters and GI denoiser ON ===")
	await _settle(12)
	await _capture("amd_disabled")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	await _capture("amd_startup")
	await _settle(30)
	await _capture("amd_quarter_32")
	await _settle(30)
	await _capture("amd_quarter_64")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 8)
	print("stage AMD GI: 64 directions per 8x8 screen tile (~1 primary ray/pixel/frame); denoiser remains ON")
	await _settle(64)
	await _capture("amd_one_64")
	_light.light_indirect_energy = 0.0
	await _capture("amd_indirect_zero")
	_light.light_indirect_energy = 1.0
	await _settle(64)
	var wall_material := _green_wall.mesh.surface_get_material(0) as StandardMaterial3D
	wall_material.albedo_color = Color(0.12, 0.16, 0.7)
	await _settle(64)
	await _capture("amd_material_changed")
	wall_material.albedo_color = Color(0.12, 0.7, 0.16)
	var camera: Camera3D = get_viewport().get_camera_3d()
	var original := camera.transform
	camera.position.x += 1.2
	await _settle(8)
	await _capture("amd_camera_cut")
	camera.transform = original
	await _settle(64)
	await _capture("amd_camera_restored")
	for frame in 12:
		camera.position.x += 0.025
		await _settle(1)
	await _capture("amd_camera_motion")
	camera.transform = original
	var original_size := get_window().size
	get_window().size = Vector2i(637, 353)
	await _settle(16)
	await _capture("amd_resized")
	get_window().size = original_size
	await _settle(16)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	await _settle(12)
	await _capture("amd_disabled_after")
	print("AMD GI progress capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
