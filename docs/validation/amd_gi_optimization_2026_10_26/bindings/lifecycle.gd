extends SceneTree

# Standalone mutation test, not a performance benchmark. No fps-proto content.
# Engine errors/oracle mismatches in the log are failures even if this script exits 0.
const GI := "rendering/global_illumination/amd_gi/"
const SOURCE := """shader_type spatial;
uniform sampler2D source_map : filter_nearest, repeat_disable;
uniform vec4 tint : source_color = vec4(1.0);
void fragment() {
    ALBEDO = texture(source_map, UV).rgb * tint.rgb;
    ROUGHNESS = 0.2;
    METALLIC = 0.2;
}
"""
var _failures := 0
var _records: Array[Dictionary] = []
var _readiness_waits: Array[Dictionary] = []
var _views: Array[SubViewport] = []
var _environments: Array[Environment] = []
var _shader := Shader.new()
var _material := ShaderMaterial.new()
var _texture: ImageTexture
var _output := ""
var _center_colors: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		push_error("GI_BINDING_FIXTURE " + message)
		_failures += 1


func _box(parent: Node, position: Vector3, dimensions: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = dimensions
	mesh.material = material
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = position
	parent.add_child(node)
	return node


func _make_view(size: Vector2i) -> SubViewport:
	var view := SubViewport.new()
	view.size = size
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var world := Node3D.new()
	view.add_child(world)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.08, 0.1, 0.14)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.25, 0.25, 0.25)
	environment.ambient_light_energy = 0.4
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	world.add_child(world_environment)
	_environments.append(environment)
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color(0.5, 0.5, 0.5)
	floor_material.roughness = 0.9
	_box(world, Vector3(0, -0.1, 0), Vector3(8, 0.2, 8), floor_material)
	_box(world, Vector3(0, 0.8, 0), Vector3(1.4, 1.6, 0.8), _material)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -25, 0)
	light.light_energy = 2.0
	light.shadow_enabled = true
	world.add_child(light)
	var camera := Camera3D.new()
	camera.position = Vector3(0, 1.6, 4.5)
	world.add_child(camera)
	camera.look_at(Vector3(0, 0.8, 0))
	camera.current = true
	return view


func _center_color(image: Image) -> Vector3:
	var result := Vector3.ZERO
	var center := image.get_size() / 2
	for y in range(center.y - 4, center.y + 4):
		for x in range(center.x - 4, center.x + 4):
			var pixel := image.get_pixel(x, y)
			result += Vector3(pixel.r, pixel.g, pixel.b)
	return result / 64.0


func _stage(label: String, enabled: bool = true, frames: int = 8) -> void:
	print("GI_BINDING_FIXTURE stage ", label)
	for frame in frames:
		await process_frame
		await RenderingServer.frame_post_draw
	var stage_record := {"stage": label, "views": []}
	for index in _views.size():
		var view := _views[index]
		var info := RenderingServer.viewport_get_amd_gi_diagnostics(view.get_viewport_rid())
		if enabled:
			_expect(not info.is_empty(), label + " missing GI diagnostics for view " + str(index))
			_expect(info.get("size", Vector2i.ZERO) == view.size, label + " stale GI size for view " + str(index))
			_expect(int(info.get("frame", -1)) >= 1, label + " GI did not render for view " + str(index))
		var image := view.get_texture().get_image()
		_expect(not image.is_empty(), label + " empty viewport " + str(index))
		var center := Vector3.ZERO
		if not image.is_empty():
			center = _center_color(image)
		if index == 0:
			_center_colors[label] = center
		if not _output.is_empty() and not image.is_empty():
			_expect(image.save_png(_output.path_join(label + "_" + str(index) + ".png")) == OK, "capture write failed")
		stage_record.views.append({"size": str(view.size), "diagnostics": info, "center_rgb": [center.x, center.y, center.z]})
	_records.append(stage_record)


func _wait_for_gi(label: String) -> void:
	# Cold preparation and explicit fault injection use a wall-clock backoff.
	# Ordinary mutation stages still retain their fixed-frame assertions.
	var start := Time.get_ticks_msec()
	var deadline := start + 90000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		await RenderingServer.frame_post_draw
		var ready := true
		for view in _views:
			var info := RenderingServer.viewport_get_amd_gi_diagnostics(view.get_viewport_rid())
			ready = ready and int(info.get("frame", -1)) >= 1 and info.get("size", Vector2i.ZERO) == view.size
		if ready:
			_readiness_waits.append({"stage": label, "milliseconds": Time.get_ticks_msec() - start, "ready": true})
			return
	_readiness_waits.append({"stage": label, "milliseconds": Time.get_ticks_msec() - start, "ready": false})
	_expect(false, label + " GI preparation did not recover/become ready")


func _run() -> void:
	if OS.get_environment("GODOT_AMD_GI_VALIDATE_BINDINGS") != "1":
		push_error("GI_BINDING_FIXTURE requires GODOT_AMD_GI_VALIDATE_BINDINGS=1")
		quit(1)
		return
	_output = OS.get_environment("GI_BINDING_OUT")
	if not _output.is_empty():
		DirAccess.make_dir_recursive_absolute(_output)
	ProjectSettings.set_setting(GI + "debug/statistics", false)
	ProjectSettings.set_setting(GI + "debug/exclusion_reports", true)
	ProjectSettings.set_setting(GI + "reflections/half_resolution", true)
	_shader.code = SOURCE
	_material.shader = _shader
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.2, 0.7, 0.3))
	_texture = ImageTexture.create_from_image(image)
	_material.set_shader_parameter("source_map", _texture)
	_views.append(_make_view(Vector2i(321, 181)))
	await _wait_for_gi("initial")
	if _failures:
		quit(1)
		return
	await _stage("initial", true, 16)
	var initial: Vector3 = _center_colors["initial"]
	_expect(initial.y > initial.x + 0.01, "initial green source texture did not reach raster output")
	await _stage("both_history_parities")
	# Pixel update retains the resource identity and must remain immediately live.
	image.fill(Color(0.8, 0.15, 0.1))
	_texture.update(image)
	await _stage("same_texture_pixels")
	var red: Vector3 = _center_colors["same_texture_pixels"]
	_expect(red.x > red.y + 0.01, "same-resource pixel update did not become red")
	# Image replacement invalidates native descriptors at both same and new sizes.
	_texture.set_image(image)
	await _stage("same_size_texture_replacement")
	var larger := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	larger.fill(Color(0.1, 0.25, 0.9))
	_texture.set_image(larger)
	await _stage("resized_texture_replacement")
	var blue: Vector3 = _center_colors["resized_texture_replacement"]
	_expect(blue.z > blue.x + 0.01, "replacement native texture did not become blue")
	_material.set_shader_parameter("source_map", ImageTexture.create_from_image(image))
	_texture = null
	await _stage("binding_replacement_old_resource_freed")
	_material.set_shader_parameter("tint", Color(0.3, 0.7, 0.9))
	await _stage("uniform_bytes_same_descriptor")
	_shader.code = SOURCE.replace("ROUGHNESS = 0.2;", "ROUGHNESS = 0.35;")
	await _stage("shader_version_replacement")
	_views[0].size = Vector2i(333, 187)
	await _stage("odd_viewport_resize")
	ProjectSettings.set_setting(GI + "reflections/half_resolution", false)
	await _stage("full_resolution_reflections")
	ProjectSettings.set_setting(GI + "debug/view", 7)
	await _stage("debug_output_allocation")
	ProjectSettings.set_setting(GI + "debug/view", 0)
	await _stage("debug_output_release")
	ProjectSettings.set_setting(GI + "debug/statistics", true)
	ProjectSettings.set_setting(GI + "debug/readback_interval", 1)
	await _stage("counter_storage_growth", true, 4)
	ProjectSettings.set_setting(GI + "debug/statistics", false)
	await _stage("counter_storage_shrink")
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	_environments[0].sky = sky
	_environments[0].background_mode = Environment.BG_SKY
	_environments[0].ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	await _stage("sky_binding_replacement")
	ProjectSettings.set_setting(GI + "enabled", false)
	await _stage("gi_disabled", false)
	ProjectSettings.set_setting(GI + "enabled", true)
	if OS.get_environment("GODOT_AMD_GI_FAIL_MATERIAL_PIPELINE") == "once:last":
		# Disabling GI destroys AMDGI, so its per-instance once:last injection
		# fires again after re-enabling. Give that explicit retry its full budget.
		await _wait_for_gi("gi_reenabled")
	await _stage("gi_reenabled", true, 12)
	_views.append(_make_view(Vector2i(299, 169)))
	await _stage("two_independent_viewports", true, 16)
	_views[1].size = Vector2i(307, 177)
	await _stage("second_viewport_resize")
	_views[1].queue_free()
	_views.remove_at(1)
	await _stage("second_viewport_destroyed")
	_views.append(_make_view(Vector2i(301, 171)))
	await _stage("viewport_recreated", true, 12)
	if not _output.is_empty():
		var report := FileAccess.open(_output.path_join("lifecycle.json"), FileAccess.WRITE)
		if report:
			report.store_string(JSON.stringify({"failures": _failures, "stages": _records, "readiness_waits": _readiness_waits}, "\t"))
		else:
			_failures += 1
	print("GI_BINDING_FIXTURE complete failures=", _failures)
	quit(1 if _failures else 0)
