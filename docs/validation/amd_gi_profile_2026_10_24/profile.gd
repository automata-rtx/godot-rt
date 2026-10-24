extends SceneTree

var samples: Array = []
var last_frame: int = -1

func _initialize():
	call_deferred("run_test")

func frames(count):
	for i in count:
		await process_frame
		await RenderingServer.frame_post_draw

func collect_gpu():
	var rd = RenderingServer.get_rendering_device()
	var frame = rd.get_captured_timestamps_frame()
	var row = {}
	for i in range(rd.get_captured_timestamps_count() - 1):
		var name = rd.get_captured_timestamp_name(i)
		if not name.begins_with("<") and not name.begins_with(">"):
			row[name] = (rd.get_captured_timestamp_gpu_time(i + 1) - rd.get_captured_timestamp_gpu_time(i)) / 1000000.0
	if rd.get_captured_timestamps_count() > 1:
		row["GPU total"] = (rd.get_captured_timestamp_gpu_time(rd.get_captured_timestamps_count() - 1) - rd.get_captured_timestamp_gpu_time(0)) / 1000000.0
	accept_sample.call_deferred(frame, row)

func accept_sample(frame, row):
	if frame != last_frame:
		last_frame = frame
		samples.append(row)

func run_test():
	seed(12345)
	change_scene_to_file("res://features/menu/main_menu.tscn")
	await frames(3)
	var level = int(OS.get_environment("GI_PROFILE_LEVEL")) if OS.has_environment("GI_PROFILE_LEVEL") else 5
	current_scene._select_level(level)
	current_scene._start()
	await frames(15)
	root.scaling_3d_mode = 0
	root.scaling_3d_scale = 1.0
	root.screen_space_aa = 0
	if OS.get_environment("GI_PROFILE_NO_EMITTERS") == "1":
		ProjectSettings.set_setting("rendering/global_illumination/amd_gi/emissive_sampling", false)
	if OS.has_environment("GI_PROFILE_SPACING"):
		ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", int(OS.get_environment("GI_PROFILE_SPACING")))
	if OS.get_environment("GI_PROFILE_NO_BOUNCE") == "1":
		ProjectSettings.set_setting("rendering/global_illumination/amd_gi/multibounce", false)
	await frames(100)
	print("DEEP_PROFILE_BEGIN mode=%s level=%d size=%s scale=%s camera=%s" % [OS.get_environment("GODOT_AMD_GI_PROFILE_MODE"), level, root.size, root.scaling_3d_scale, root.get_camera_3d().global_transform])
	for i in 90:
		await frames(1)
		RenderingServer.call_on_render_thread(collect_gpu)
	await frames(5)
	print("DEEP_PROFILE_SAMPLES " + JSON.stringify(samples))
	var materials = {}
	audit_materials(root, materials)
	for key in materials:
		print("PROFILE_AUTHORED_MATERIAL " + key + " surfaces=" + str(materials[key]))
	print("DEEP_PROFILE_END")
	await root.get_node("LevelState").return_to_menu()
	await frames(10)
	quit()

func audit_materials(node, result):
	var mesh: Mesh = null
	if node is MeshInstance3D:
		mesh = node.mesh
	elif node is MultiMeshInstance3D and node.multimesh:
		mesh = node.multimesh.mesh
	if mesh:
		for surface in mesh.get_surface_count():
			var material = node.get_active_material(surface) if node is MeshInstance3D else (node.material_override if node.material_override else mesh.surface_get_material(surface))
			if material is BaseMaterial3D and material.emission_enabled:
				var texture = material.emission_texture
				var key = "texture=%s rid=%s emission=%s energy=%s" % [texture.resource_path if texture else "none", texture.get_rid() if texture else RID(), material.emission, material.emission_energy_multiplier]
				result[key] = result.get(key, 0) + 1
	for child in node.get_children():
		audit_materials(child, result)
