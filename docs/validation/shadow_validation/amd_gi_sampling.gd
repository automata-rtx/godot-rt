extends "res://amd_gi.gd"

# Same camera and primary-ray budget for both sampling modes. Denoising stays on.
func _run() -> void:
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/denoiser", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/multibounce", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/adaptive_sampling", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_cache", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/max_distance", 20.0)
	var ceiling := get_node("Ceiling") as MeshInstance3D
	var emitter := ceiling.mesh.surface_get_material(0) as StandardMaterial3D
	emitter.emission_enabled = true
	emitter.emission = Color.WHITE
	emitter.emission_energy_multiplier = 0.0
	print("=== AMD sampling: ~1/4 primary ray/pixel/frame, multibounce and denoiser ON; fixed camera ===")
	await _settle(12)
	await _capture("sampling_disabled")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/importance_sampling", false)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	await _settle(64)
	await _capture("sampling_uniform")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/importance_sampling", true)
	await _settle(64)
	await _capture("sampling_guided")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/importance_sampling", false)
	await _settle(64)
	await _capture("sampling_uniform_restored")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/importance_sampling", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/adaptive_sampling", false)
	await _settle(64)
	await _capture("sampling_adaptive_off")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/adaptive_sampling", true)
	await _settle(64)
	await _capture("sampling_adaptive_on")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_cache", false)
	await _settle(64)
	await _capture("sampling_cache_off")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_cache", true)
	await _settle(64)
	await _capture("sampling_cache_on")
	# Exercise displaced surfaces without triggering the camera-cut reset.
	# Return before the cache's 50-frame expiry so reuse is observable.
	var camera: Camera3D = get_viewport().get_camera_3d()
	var original := camera.position
	for step in range(12):
		camera.position.x += 0.04
		await _settle(1)
	for step in range(12):
		camera.position.x -= 0.04
		await _settle(1)
	camera.position = original
	await _settle(8)
	await _capture("sampling_cache_motion_return")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 32)
	await _settle(64)
	await _capture("sampling_sixteenth")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
	_light.light_indirect_energy = 0.0
	await _settle(64)
	await _capture("sampling_dark")
	# Material uniform changes do not reset the scene revision. Discover new
	# radiance from a black CDF, then drain it without a reset or a camera cut.
	emitter.emission_energy_multiplier = 2.0
	await _settle(64)
	await _capture("sampling_emissive")
	emitter.emission_energy_multiplier = 0.0
	await _settle(64)
	await _capture("sampling_emission_removed")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	await _settle(12)
	await _capture("sampling_disabled_after")
	print("AMD sampling capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
