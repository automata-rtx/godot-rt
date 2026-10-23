extends "res://gi.gd"

# Reuse the transport rig verbatim. Only GI setup changes between captures.
# This is a still-image comparison, not a GPU benchmark or a ground-truth test.


func _settle(frames: int) -> void:
	for frame in frames:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw


func _settled_pair(label: String) -> void:
	await _settle(120)
	await _capture(label + "_early")
	await _settle(60)
	await _capture(label)


func _run() -> void:
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/denoiser", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/importance_sampling", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/multibounce", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/max_distance", 20.0)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
	var environment: Environment
	for child in get_children():
		if child is MeshInstance3D:
			child.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		elif child is WorldEnvironment:
			environment = child.environment
	_light.light_bake_mode = Light3D.BAKE_DYNAMIC
	RenderingServer.gi_set_use_half_resolution(false)
	RenderingServer.voxel_gi_set_quality(RenderingServer.VOXEL_GI_QUALITY_HIGH)
	RenderingServer.environment_set_sdfgi_ray_count(RenderingServer.ENV_SDFGI_RAY_COUNT_16)
	RenderingServer.environment_set_sdfgi_frames_to_converge(RenderingServer.ENV_SDFGI_CONVERGE_IN_30_FRAMES)
	RenderingServer.environment_set_sdfgi_frames_to_update_light(RenderingServer.ENV_SDFGI_UPDATE_LIGHT_IN_1_FRAME)
	print("=== GI comparison: full resolution; unchanged room, camera, light, materials and exposure ===")
	await _settle(12)
	await _capture("gi_disabled")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	print("stage AMD GI: ~1/4 primary ray/pixel/frame, multibounce and denoiser ON")
	await _settle(64)
	await _capture("amd_quarter")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 8)
	print("stage AMD GI: ~1 primary ray/pixel/frame, multibounce and denoiser ON")
	await _settle(64)
	await _capture("amd_one")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	await _settle(12)
	await _capture("gi_disabled_after_rt")

	var voxel := VoxelGI.new()
	voxel.position = Vector3(0, 1.5, 0)
	voxel.size = Vector3(6, 4, 6)
	voxel.subdiv = VoxelGI.SUBDIV_128
	add_child(voxel)
	await _settle(2)
	print("stage VoxelGI: baking 128 subdivisions, 6 x 4 x 6 bounds")
	voxel.bake(self)
	if voxel.data == null or voxel.data.get_data_cells().is_empty():
		push_error("VoxelGI bake produced no cells")
		get_tree().quit(1)
		return
	voxel.data.interior = true
	print("VoxelGI: cells=%s energy=%s propagation=%s two_bounces=%s bias=%s normal_bias=%s" % [voxel.data.get_octree_size(), voxel.data.energy, voxel.data.propagation, voxel.data.use_two_bounces, voxel.data.bias, voxel.data.normal_bias])
	await _settled_pair("voxel_128")
	voxel.subdiv = VoxelGI.SUBDIV_256
	print("stage VoxelGI: baking 256 subdivisions, same bounds and settings")
	voxel.bake(self)
	print("VoxelGI: cells=%s" % voxel.data.get_octree_size())
	await _settled_pair("voxel_256")
	# VoxelGIData documents this alternative for prioritizing diffuse quality.
	voxel.data.bias = 0.0
	voxel.data.normal_bias = 1.5
	print("stage VoxelGI: 256 subdivisions, bias 0, normal bias 1.5; same baked data")
	await _settled_pair("voxel_256_normal_bias")
	voxel.queue_free()
	await _settle(12)
	await _capture("gi_disabled_after_voxel")

	# No sky in the transport integrator; prevent an environment contribution here too.
	environment.sdfgi_read_sky_light = false
	print("stage SDFGI: default spatial settings, sky disabled, full resolution")
	print("SDFGI: cascades=%s min_cell_size=%s y_scale=%s feedback=%s energy=%s occlusion=%s normal_bias=%s probe_bias=%s" % [environment.sdfgi_cascades, environment.sdfgi_min_cell_size, environment.sdfgi_y_scale, environment.sdfgi_bounce_feedback, environment.sdfgi_energy, environment.sdfgi_use_occlusion, environment.sdfgi_normal_bias, environment.sdfgi_probe_bias])
	environment.sdfgi_enabled = true
	await _settled_pair("sdfgi_default")
	environment.sdfgi_min_cell_size = 0.1
	environment.sdfgi_use_occlusion = true
	print("stage SDFGI: 0.1 minimum cell size, occlusion enabled, other settings unchanged")
	await _settled_pair("sdfgi_fine_occlusion")
	environment.sdfgi_enabled = false
	await _settle(12)
	await _capture("gi_disabled_after_sdfgi")
	print("GI comparison capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
