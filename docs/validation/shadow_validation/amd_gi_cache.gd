extends "res://amd_gi.gd"


func _run() -> void:
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	await _settle(8)
	await _capture("cache_disabled")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_cache", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/denoiser", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/multibounce", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/max_distance", 20.0)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	await _settle(20)
	var camera: Camera3D = get_viewport().get_camera_3d()
	var original := camera.position
	var box: MeshInstance3D = get_node("ShortBox")
	var box_origin := box.position
	for step in range(16):
		camera.position.x += 0.06
		await _settle(1)
	for step in range(16):
		camera.position.x -= 0.06
		box.position.x += 0.02
		await _settle(1)
	camera.position = original
	box.position = box_origin
	await _settle(8)
	await _capture("cache_returned")
	await _settle(64)
	await _capture("cache_expired")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	await _settle(12)
	await _capture("cache_disabled_after")
	print("AMD cache capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
