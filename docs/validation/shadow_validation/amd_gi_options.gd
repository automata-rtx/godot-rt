extends "res://gi.gd"

# Isolated runtime integration matrix. Prepared only: running it needs explicit
# permission. Never loads or edits fps-proto. This is not a performance test.
const GI := "rendering/global_illumination/amd_gi/"
var _saved_settings: Dictionary = {}
var _records: Array[Dictionary] = []
var _output := ""


func _set_option(key: String, value: Variant) -> void:
	if not _saved_settings.has(key):
		_saved_settings[key] = ProjectSettings.get_setting(GI + key)
	ProjectSettings.set_setting(GI + key, value)


func _stage(label: String, capture: bool = false) -> Dictionary:
	for frame in 4:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	var info := RenderingServer.viewport_get_amd_gi_diagnostics(get_viewport().get_viewport_rid())
	print("AMD_GI_OPTIONS stage ", label, " ", JSON.stringify(info))
	_records.append({"stage": label, "diagnostics": info})
	if capture:
		var image := get_viewport().get_texture().get_image()
		if image.is_empty() or image.save_png(_output.path_join(label + ".png")) != OK:
			_failures += 1
	return info


func _expect(condition: bool, message: String) -> void:
	if not condition:
		push_error("AMD_GI_OPTIONS " + message)
		_failures += 1


func _run() -> void:
	_output = OS.get_environment("SHADOW_OUT_DIR")
	if _output.is_empty():
		push_error("AMD_GI_OPTIONS requires an external SHADOW_OUT_DIR capture directory")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_output)
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1281, 721)
	get_window().content_scale_size = Vector2i(1281, 721)
	# Open the room to an ordinary native sky and add glossy geometry. Grass is
	# absent. The test scene is deliberately independent from project materials.
	get_node("Ceiling").queue_free()
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_energy_multiplier = 1.0
	sky.sky_material = sky_material
	var environment := get_viewport().find_world_3d().environment
	environment.sky = sky
	environment.background_mode = Environment.BG_SKY
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 1.0
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var glossy := _box("Glossy", Vector3(0, 1.0, 1.0), Vector3(0.8, 1.0, 0.15), Color(0.8, 0.6, 0.1))
	var material := glossy.mesh.surface_get_material(0) as StandardMaterial3D
	material.metallic = 1.0
	material.roughness = 0.12
	material.metallic_specular = 0.5
	_set_option("enabled", true)
	_set_option("reflections/enabled", true)
	_set_option("debug/statistics", true)
	_set_option("debug/readback_interval", 1)
	_set_option("debug/exclusion_reports", true)
	_set_option("debug/view", 0)
	_set_option("probe_spacing", 16)
	_set_option("cache_bucket_exponent", 8)
	# Every combination is live, without restarting or saving project settings.
	# Mode changes alternate allocation dimensions and must clear incompatible
	# history. Diffuse and reflection denoisers must remain independent.
	for diffuse in [false, true]:
		_set_option("denoiser", diffuse)
		for half in [false, true]:
			_set_option("reflections/half_resolution", half)
			for mode in [0, 1, 2]:
				_set_option("reflections/denoiser", mode)
				for sampling in [0, 1, 2]:
					_set_option("sky_sampling", sampling)
					var label := "matrix_d%d_h%d_r%d_s%d" % [int(diffuse), int(half), mode, sampling]
					var info := await _stage(label)
					_expect(not info.is_empty(), label + " missing diagnostics (GI unavailable or preparation failed)")
					_expect(info.get("sky_sampling", -1) == sampling, label + " stale sky mode")
					_expect(info.get("reflection_denoiser", -1) == mode, label + " stale reflection mode")
					_expect(info.get("size", Vector2i.ZERO) == Vector2i(1281, 721), label + " unexpected render dimensions")
					var gpu: Dictionary = info.get("gpu", {})
					_expect(not gpu.is_empty(), label + " missing GPU statistics")
					if not gpu.is_empty():
						var histogram_total := 0
						for count in gpu.get("occupancy_histogram", PackedInt32Array()):
							histogram_total += count
						_expect(histogram_total == gpu.get("bucket_capacity", -1), label + " incomplete bucket histogram")
						_expect(gpu.get("occupied_tiles", -1) <= gpu.get("tile_capacity", -2), label + " tile capacity exceeded")
	# Capture each visualizer at the same settled state. PNGs and diagnostics
	# require review; successful dispatch is not proof of correct appearance.
	_set_option("denoiser", true)
	_set_option("reflections/denoiser", 1)
	_set_option("sky_sampling", 1)
	for view in 32:
		_set_option("debug/view", view)
		await _stage("view_%02d" % view, true)
	_set_option("debug/view", 7)
	for indirect in [false, true]:
		_set_option("debug/indirect_cache", indirect)
		for mip in 4:
			_set_option("debug/mip", mip)
			await _stage("cache_indirect_%d_mip_%d" % [int(indirect), mip], true)
	_set_option("debug/view", 28)
	for page in [0, 1, 65535]:
		_set_option("debug/atlas_page", page)
		await _stage("probe_cache_page_%d" % page)
	_set_option("debug/atlas_page", 0)
	_set_option("debug/view", 0)
	_set_option("reflections/denoiser", 0)
	for half in [true, false]:
		_set_option("reflections/half_resolution", half)
		var suffix := "half" if half else "full"
		for radius in [1, 11, 32]:
			_set_option("reflections/split_radius_" + suffix, radius)
			await _stage("split_%s_radius_%d" % [suffix, radius], true)
		for radius in [0, 16]:
			_set_option("reflections/firefly_mark_radius_" + suffix, radius)
			_set_option("reflections/firefly_cleanup_radius_" + suffix, radius)
			await _stage("fireflies_%s_radius_%d" % [suffix, radius])
	_set_option("sky_sampling", 2)
	for angle in [0.0, 0.7, -1.3]:
		environment.sky_rotation.y = angle
		await _stage("sky_rotation_%s" % str(angle))
	sky_material.sky_top_color = Color.BLACK
	sky_material.sky_horizon_color = Color.BLACK
	sky_material.ground_bottom_color = Color.BLACK
	sky_material.ground_horizon_color = Color.BLACK
	await _stage("black_sky_importance")
	_set_option("debug/statistics", false)
	var without_gpu := await _stage("cpu_diagnostics_only")
	_expect(not without_gpu.has("gpu"), "disabled GPU readback left stale GPU snapshot")
	_set_option("debug/exclusion_reports", false)
	var disabled := await _stage("diagnostics_disabled")
	_expect(disabled.is_empty(), "disabled diagnostics not empty")
	for key in _saved_settings:
		ProjectSettings.set_setting(GI + key, _saved_settings[key])
	var report := FileAccess.open(_output.path_join("amd_gi_options.json"), FileAccess.WRITE)
	if report:
		report.store_string(JSON.stringify({"failures": _failures, "stages": _records}, "\t"))
	else:
		_failures += 1
	print("AMD_GI_OPTIONS complete failures=", _failures)
	get_tree().quit(1 if _failures else 0)
