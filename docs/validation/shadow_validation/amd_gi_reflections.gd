extends "res://amd_gi.gd"


func _run() -> void:
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/denoiser", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/multibounce", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/max_distance", 30.0)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/reflections/enabled", false)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/reflections/half_resolution", true)
	var mirror: StandardMaterial3D = get_node("BackWall").mesh.material
	mirror.metallic = 1.0
	mirror.roughness = 0.02
	mirror.metallic_specular = 1.0
	var floor_material: StandardMaterial3D = get_node("Floor").mesh.material
	floor_material.metallic = 0.7
	floor_material.roughness = 0.22
	floor_material.metallic_specular = 1.0
	var emitter := _box("OffscreenEmitter", Vector3(-1.8, 2.3, 8.2), Vector3(1.3, 1.3, 0.1), Color.BLACK)
	var emitter_material: StandardMaterial3D = emitter.mesh.material
	emitter_material.emission_enabled = true
	emitter_material.emission = Color(1.0, 0.03, 0.01)
	emitter_material.emission_energy_multiplier = 3.0
	print("=== AMD reflections: 1/4 diffuse primary rays, half-resolution glossy rays, denoising ON, emitter behind camera ===")
	await _settle(64)
	await _capture("reflections_off")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/reflections/enabled", true)
	await _settle(64)
	await _capture("reflections_half")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/reflections/half_resolution", false)
	await _settle(64)
	await _capture("reflections_full")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/reflections/ray_compaction", false)
	await _settle(32)
	await _capture("reflections_uncompacted")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/reflections/ray_compaction", true)
	print("stage reflections: emitter motion")
	var emitter_origin := emitter.position
	for frame in 8:
		emitter.position.x += 0.1
		await _settle(1)
	await _capture("reflections_emitter_moved")
	emitter.position = emitter_origin
	await _settle(16)
	await _capture("reflections_emitter_restored")
	print("stage reflections: emitter motion finished")
	emitter_material.emission_energy_multiplier = 0.0
	await _settle(64)
	await _capture("reflections_no_emitter")
	var camera := get_viewport().get_camera_3d()
	var original := camera.transform
	for frame in 16:
		camera.position.x += 0.025
		await _settle(1)
	await _capture("reflections_motion")
	camera.transform = original
	emitter_material.emission_energy_multiplier = 3.0
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/reflections/half_resolution", true)
	await _settle(64)
	await _capture("reflections_restored")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/reflections/enabled", false)
	await _settle(64)
	await _capture("reflections_off_after")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	await _settle(12)
	await _capture("reflections_gi_disabled")
	print("AMD reflection capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
