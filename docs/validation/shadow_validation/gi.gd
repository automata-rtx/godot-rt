extends Node3D

# Controlled stills for the uncached RT diffuse transport validation integrator.
# This is an integration checkpoint, not the optimized AMD GI implementation.
var _failures := 0
var _green_wall: MeshInstance3D
var _light: OmniLight3D


func _box(label: String, position: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = label
	var mesh := BoxMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	material.metallic_specular = 0.0
	mesh.material = material
	node.mesh = mesh
	node.position = position
	add_child(node)
	return node


func _ready() -> void:
	ProjectSettings.set_setting("rendering/global_illumination/rt_validation/enabled", false)
	ProjectSettings.set_setting("rendering/global_illumination/rt_validation/max_distance", 20.0)
	var samples_text := OS.get_environment("RTGI_SAMPLES")
	var samples := 1 if samples_text.is_empty() else int(samples_text)
	ProjectSettings.set_setting("rendering/global_illumination/rt_validation/samples_per_pixel", samples)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.035, 0.035, 0.035)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.BLACK
	environment.ambient_light_energy = 0.0
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)
	var white := Color(0.78, 0.78, 0.78)
	_box("Floor", Vector3(0, -0.1, 0), Vector3(5.2, 0.2, 5.2), white)
	_box("BackWall", Vector3(0, 1.5, -2.6), Vector3(5.2, 3, 0.2), white)
	_box("RedWall", Vector3(-2.6, 1.5, 0), Vector3(0.2, 3, 5.2), Color(0.8, 0.12, 0.08))
	_green_wall = _box("GreenWall", Vector3(2.6, 1.5, 0), Vector3(0.2, 3, 5.2), Color(0.12, 0.7, 0.16))
	_green_wall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_box("Ceiling", Vector3(0, 3.1, 0), Vector3(5.2, 0.2, 5.2), white)
	var short_box := _box("ShortBox", Vector3(-0.9, 0.55, 0.45), Vector3(1.15, 1.1, 1.15), white)
	short_box.rotation_degrees.y = 18
	var tall_box := _box("TallBox", Vector3(0.8, 0.95, -0.9), Vector3(1.05, 1.9, 1.05), white)
	tall_box.rotation_degrees.y = -20
	var light := OmniLight3D.new()
	light.position = Vector3(-0.2, 2.75, 0.15)
	light.light_energy = 1.8
	light.omni_range = 9.0
	light.light_size = 0.0
	light.shadow_enabled = true
	add_child(light)
	_light = light
	var camera := Camera3D.new()
	camera.position = Vector3(0, 1.8, 7.4)
	camera.fov = 48
	add_child(camera)
	camera.look_at(Vector3(0, 1.35, -0.6))
	camera.current = true
	print("=== Room rig: uncached diagnostic setting %d samples/pixel (inactive unless explicitly enabled) ===" % samples)
	_run.call_deferred()


func _capture(label: String) -> void:
	# Two complete draws ensure that the live setting has reached the renderer.
	for frame in 2:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	var output := OS.get_environment("SHADOW_OUT_DIR")
	if output.is_empty():
		output = "res://out"
	var error := get_viewport().get_texture().get_image().save_png(output.path_join(label + ".png"))
	print("saved %s err=%d" % [label, error])
	print("GI memory %s: textures=%d buffers=%d" % [label, RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED), RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED)])
	if error != OK:
		_failures += 1


func _run() -> void:
	for frame in 12:
		await get_tree().process_frame
	await _capture("gi_disabled")
	ProjectSettings.set_setting("rendering/global_illumination/rt_validation/bounces", 1)
	ProjectSettings.set_setting("rendering/global_illumination/rt_validation/enabled", true)
	await _capture("gi_one_bounce")
	ProjectSettings.set_setting("rendering/global_illumination/rt_validation/bounces", 3)
	await _capture("gi_three_bounces")
	_light.light_indirect_energy = 0.0
	await _capture("gi_indirect_zero")
	_light.light_indirect_energy = 1.0
	var wall_material := _green_wall.mesh.surface_get_material(0) as StandardMaterial3D
	wall_material.albedo_color = Color(0.12, 0.16, 0.7)
	await _capture("gi_material_changed")
	wall_material.albedo_color = Color(0.12, 0.7, 0.16)
	ProjectSettings.set_setting("rendering/global_illumination/rt_validation/enabled", false)
	# Drain RenderingDevice's deferred destruction before reading memory counters.
	for frame in 12:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	await _capture("gi_disabled_after")
	print("GI validation capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
